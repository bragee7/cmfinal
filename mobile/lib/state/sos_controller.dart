import 'dart:async';

import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/sos_case.dart';
import '../services/location_service.dart';
import '../services/sos_executor.dart';
import '../services/sos_service.dart';
import '../services/voice_guard_service.dart';
import '../services/power_sos_service.dart';

enum SosStatus {
  idle,
  listening,
  cancelWindow,
  countdown,
  recording,
  sending,
  sent,
}

class SosController extends ChangeNotifier {
  final SosService _sosService = SosService();

  SosStatus _status = SosStatus.idle;
  int? _cancelTimer;
  int? _countdown;
  int _recordingTime = 30;
  String _error = '';
  String _success = '';

  AppLocation? _location;
  String _locationLink = '';

  bool _isTracking = false;

  String? _recordedVideoPath;
  String? _recordedAudioPath;
  bool _showPreview = false;

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraInitialized = false;
  CameraLensDirection _selectedLens = CameraLensDirection.back;

  Timer? _cancelTimerRef;
  Timer? _countdownRef;
  Timer? _recordingTimerRef;
  Timer? _trackingRef;
  StreamSubscription<AppLocation>? _watchSub;
  StreamSubscription<String>? _detectionSub;
  StreamSubscription<bool>? _statusSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _powerSub;
  StreamSubscription<Map<String, Object?>>? _mirrorSub;
  StreamSubscription<void>? _appRecSub;
  Timer? _mirrorTimer;
  /// True while a BG executor owns the SOS: the UI only renders snapshots,
  /// never runs local timers (single authoritative state, no duplicates).
  bool _mirroring = false;
  /// True once this open app adopted a native-owned recording (evidence
  /// file + nativeDone in the mirror) and took over the send. Reset when
  /// the flow ends so a later SOS can adopt again. Prevents double-send
  /// from the 1s mirror timer re-firing on the same snapshot.
  bool _adoptedNative = false;
  bool _voiceEnabled = false;
  bool _powerSosEnabled = true;
  bool _initialized = false;

  SosStatus get status => _status;
  int? get cancelTimer => _cancelTimer;
  int? get countdown => _countdown;
  int get recordingTime => _recordingTime;
  String get error => _error;
  String get success => _success;
  AppLocation? get location => _location;
  String get locationLink => _locationLink;
  bool get isTracking => _isTracking;
  String? get recordedVideoPath => _recordedVideoPath;
  String? get recordedAudioPath => _recordedAudioPath;
  bool get showPreview => _showPreview;
  CameraController? get cameraController => _cameraController;
  bool get cameraInitialized => _cameraInitialized;
  CameraLensDirection get selectedLens => _selectedLens;
  bool get voiceEnabled => _voiceEnabled;
  bool get powerSosEnabled => _powerSosEnabled;

  bool get isBusy =>
      _status != SosStatus.idle && _status != SosStatus.listening;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _watchSub = LocationService.watchPosition().listen((loc) {
      _location = loc;
      _locationLink = loc.googleMapsLink;
      notifyListeners();
    });

    _detectionSub = VoiceGuardService.detections.listen((keyword) {
      // Route every detection through triggerSOS — it shows
      // "SOS already in progress" when busy instead of dropping silently.
      triggerSOS(triggerKeyword: keyword);
    });

    _statusSub = VoiceGuardService.statusStream.listen((running) {
      if (_voiceEnabled != running) {
        _voiceEnabled = running;
        notifyListeners();
      }
    });

    _errorSub = VoiceGuardService.errors.listen((error) {
      _error = error;
      _voiceEnabled = false;
      notifyListeners();
    });

    try {
      _cameras = await availableCameras();
    } catch (_) {
      _cameras = [];
    }

    _voiceEnabled = await VoiceGuardService.isRunning();
    // 3x power-press: same triggerSOS path => same 5s cancel window.
    _powerSub = PowerSosService.detections.listen((_) {
      // Same triggerSOS path (with busy feedback) as voice detections.
      triggerSOS(triggerKeyword: 'power-button');
    });
    _powerSosEnabled = await PowerSosService.isEnabled();
    await PowerSosService.initialize();

    // BG executor observer: live snapshots (BG authority) + app-recording
    // requests (open app records with CameraController for the executor).
    _mirrorSub = VoiceGuardService.sosStateStream.listen(_applySnapshot);
    _appRecSub =
        VoiceGuardService.appRecordingRequests.listen((_) => recordForExecutor());
    _mirrorTimer?.cancel();
    _mirrorTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _syncFromExecutor());
    // Opening the app mid-SOS must show the LIVE state, never restart it.
    await _syncFromExecutor();
    notifyListeners();
  }

  /// One-way sync from the BG executor mirror. Never starts timers, never
  /// creates an SOS — purely renders the authoritative background state.
  Future<void> _syncFromExecutor() async {
    try {
      final snap = await SosExecutor.readSnapshot();
      _applySnapshot(snap);
    } catch (_) {}
  }

  void _applySnapshot(Map<String, Object?> snap) {
    final raw = (snap['state'] as String?) ?? 'idle';
    final mapped = _mapExecutorState(raw);
    final remaining = (snap['remaining'] as int?) ?? 0;

    if (raw == 'idle' || raw == 'listening') {
      if (_mirroring) {
        // Executor finished/cancelled: release the mirror, show its message.
        _mirroring = false;
        _adoptedNative = false;
        _cancelTimerRef?.cancel();
        _cancelTimerRef = null;
        _countdownRef?.cancel();
        _countdownRef = null;
        _status = mapped;
        _cancelTimer = null;
        _countdown = null;
      } else {
        return; // nothing active anywhere — leave local UI alone
      }
    } else {
      // Authoritative BG state: take it over, kill any local timers so the
      // countdown can never run twice (which would double-record/double-send).
      _mirroring = true;
      _cancelTimerRef?.cancel();
      _cancelTimerRef = null;
      _countdownRef?.cancel();
      _countdownRef = null;
      _status = mapped;
      if (mapped == SosStatus.cancelWindow) {
        _cancelTimer = remaining;
        _countdown = null;
      } else if (mapped == SosStatus.countdown) {
        _countdown = remaining;
        _cancelTimer = null;
      } else if (mapped == SosStatus.recording) {
        _recordingTime = remaining;
        // Native-owned flow finished recording while the app was closed
        // (evidence path + nativeDone in the mirror): adopt the file and
        // complete the send exactly once through the existing pipeline.
        // Skipped when the BG executor is alive — it owns the send then.
        if ((snap['nativeDone'] == true) && !_adoptedNative) {
          _adoptedNative = true;
          unawaited(_adoptNativeDone(snap));
        }
      }
    }

    if (snap['busy'] == true) {
      _success = (snap['message'] as String?) ?? 'SOS already in progress';
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        if (_success == 'SOS already in progress') {
          _success = '';
          notifyListeners();
        }
      });
      return;
    }
    if (snap['cancelled'] == true) {
      _success = (snap['message'] as String?) ?? 'SOS alert cancelled';
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        _success = '';
        notifyListeners();
      });
      return;
    }
    if (snap['sent'] == true) {
      _success = (snap['message'] as String?) ??
          'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.';
      _showPreview = false;
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      return;
    }
    if (snap['failed'] == true) {
      _error = (snap['message'] as String?) ??
          'Failed to send emergency alert. Please check your connection and try again.';
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  /// Adopt a native-owned recording (app was closed when evidence finished):
  /// take the file path(s) from the mirror and run the existing send
  /// pipeline exactly once. Yields to a live BG executor (it owns the send
  /// then) and to an already-running local send.
  Future<void> _adoptNativeDone(Map<String, Object?> snap) async {
    try {
      if (await VoiceGuardService.isRunning()) {
        _adoptedNative = false; // BG executor alive: it sends, we mirror.
        return;
      }
    } catch (_) {}
    if (_status == SosStatus.sending || _status == SosStatus.sent) {
      _adoptedNative = false;
      return;
    }
    final video = (snap['videoPath'] as String?) ?? '';
    final audio = (snap['audioPath'] as String?) ?? '';
    if (video.isEmpty && audio.isEmpty) {
      _adoptedNative = false;
      return;
    }
    _recordedVideoPath = video.isNotEmpty ? video : null;
    _recordedAudioPath = audio;
    await sendEmergencyData();
  }

  SosStatus _mapExecutorState(String raw) {
    switch (raw) {
      case 'cancelWindow':
        return SosStatus.cancelWindow;
      case 'countdown':
        return SosStatus.countdown;
      case 'recording':
        return SosStatus.recording;
      case 'sending':
        return SosStatus.sending;
      case 'sent':
        return SosStatus.sent;
      case 'listening':
        return SosStatus.listening;
      case 'idle':
      default:
        return SosStatus.idle;
    }
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    _voiceEnabled = enabled;
    notifyListeners();
    if (enabled) {
      try {
        await VoiceGuardService.setEnabledPref(true);
        await VoiceGuardService.start();
      } catch (e) {
        _voiceEnabled = false;
        _error = 'Failed to start voice protection: $e';
        notifyListeners();
      }
    } else {
      await VoiceGuardService.stop();
    }
  }

  Future<void> setPowerSosEnabled(bool enabled) async {
    _powerSosEnabled = enabled;
    notifyListeners();
    await PowerSosService.setEnabled(enabled);
  }

  void playAlertSound() {
    SystemSound.play(SystemSoundType.alert);
  }

  void setCameraLens(CameraLensDirection lens) {
    if (lens == _selectedLens) return;
    _selectedLens = lens;
    notifyListeners();
  }

  Future<void> triggerSOS({String? triggerKeyword}) async {
    // BG executor first: when a BG engine is alive it owns the SOS (same
    // 5s window, works app-closed). The live snapshot renders the UI.
    // Only when NO bg engine runs (voice protection off) does the legacy
    // local path below run — manual SOS behavior is unchanged in that case.
    try {
      if (await SosExecutor.requestTrigger(triggerKeyword ?? 'manual')) {
        return;
      }
    } catch (_) {}
    if (isBusy) {
      // A trigger (voice / power button / SOS button) arrived while an SOS
      // is already in flight (cancel window, countdown, recording, sending).
      // Tell the user instead of silently ignoring it — silent ignores are
      // perceived as "voice recognition broken" on the second utterance.
      _success = 'SOS already in progress';
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        if (_success == 'SOS already in progress') {
          _success = '';
          notifyListeners();
        }
      });
      return;
    }

    playAlertSound();
    _status = SosStatus.cancelWindow;
    _cancelTimer = 5;
    _error = '';
    _success = '';
    notifyListeners();

    _cancelTimerRef?.cancel();
    _cancelTimerRef = Timer.periodic(const Duration(seconds: 1), (timer) {
      _cancelTimer = (_cancelTimer ?? 5) - 1;
      if (_cancelTimer! <= 0) {
        timer.cancel();
        _cancelTimerRef = null;
        _cancelTimer = null;
        startCountdown();
      }
      notifyListeners();
    });
  }

  Future<void> cancelSOS() async {
    // Tell the BG executor first (invoke + prefs command: covers open app,
    // backgrounded app, and the native alarm activity alike). The local
    // teardown below keeps the open-app UI correct either way.
    await SosExecutor.requestCancel();
    if (_mirroring) {
      // The app was recording on the executor's behalf: report the abort so
      // the BG chain does not wait out its no-show fallback (its active flag
      // is already cleared by the cancel above, so this is just a no-op ping
      // if the cancel already landed).
      VoiceGuardService.serviceInvoke(
        SosExecutor.sosAppRecordingDone,
        {'error': 'cancelled by user'},
      );
    }
    // the recording leaks (camera/mic held, file never finalized). Gated on
    // recording status so an idle preview/selector controller is untouched.
    if (_status == SosStatus.recording && _cameraController != null) {
      try {
        if (_cameraController!.value.isRecordingVideo) {
          await _cameraController!.stopVideoRecording();
        }
      } catch (_) {}
      try {
        await _cameraController?.dispose();
      } catch (_) {}
      _cameraController = null;
      _cameraInitialized = false;
    }
    _cancelTimerRef?.cancel();
    _cancelTimerRef = null;
    _cancelTimer = null;
    _countdownRef?.cancel();
    _countdownRef = null;
    _countdown = null;
    _status = SosStatus.listening;
    _success = 'SOS alert cancelled';
    VoiceGuardService.resetDetectionCooldown();
    notifyListeners();
    Future.delayed(const Duration(seconds: 3), () {
      _success = '';
      notifyListeners();
    });
  }

  void startCountdown() {
    _status = SosStatus.countdown;
    _countdown = 3;
    notifyListeners();

    _countdownRef?.cancel();
    _countdownRef = Timer.periodic(const Duration(seconds: 1), (timer) {
      _countdown = (_countdown ?? 3) - 1;
      if (_countdown! <= 0) {
        timer.cancel();
        _countdownRef = null;
        _countdown = null;
        startRecording();
      }
      notifyListeners();
    });
  }

  /// Record the 30s evidence clip ON BEHALF of the BG executor (app is open
  /// at countdown end). Mirrors startRecording's camera handling but does
  /// NOT send: the clip path is reported back and the BG chain continues
  /// (GPS → submit → upload → tracking) without duplicating anything.
  Future<void> recordForExecutor() async {
    _status = SosStatus.recording;
    _recordingTime = 30;
    notifyListeners();
    String? videoPath;
    String? failure;
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        failure = 'No camera available on this device';
      } else {
        final camera = _cameras.firstWhere(
          (c) => c.lensDirection == _selectedLens,
          orElse: () => _cameras.first,
        );
        await _cameraController?.dispose();
        _cameraController =
            CameraController(camera, ResolutionPreset.medium, enableAudio: true);
        await _cameraController!.initialize();
        _cameraInitialized = true;
        notifyListeners();
        await _cameraController!.startVideoRecording();
        final start = DateTime.now();
        _recordingTimerRef?.cancel();
        _recordingTimerRef =
            Timer.periodic(const Duration(milliseconds: 250), (timer) {
          final elapsed = DateTime.now().difference(start).inMilliseconds;
          final remaining = ((30000 - elapsed) / 1000).ceil();
          _recordingTime = remaining > 0 ? remaining : 0;
          if (elapsed >= 30000) timer.cancel();
          notifyListeners();
        });
        await Future.delayed(const Duration(seconds: 30));
        _recordingTimerRef?.cancel();
        _recordingTimerRef = null;
        try {
          if (_cameraController != null &&
              _cameraController!.value.isRecordingVideo) {
            videoPath = (await _cameraController!.stopVideoRecording()).path;
          }
        } catch (e) {
          failure = '$e';
        }
      }
    } catch (e) {
      failure = '$e';
    }
    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    _cameraInitialized = false;
    _recordedVideoPath = videoPath;
    _showPreview = false; // the BG chain owns the send; no local preview
    VoiceGuardService.serviceInvoke(
      SosExecutor.sosAppRecordingDone,
      {'videoPath': videoPath ?? '', 'error': failure ?? ''},
    );
    notifyListeners();
  }

  Future<void> startRecording() async {
    _status = SosStatus.recording;
    _recordingTime = 30;
    notifyListeners();

    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        _error = 'No camera available on this device';
        _status = SosStatus.idle;
        notifyListeners();
        return;
      }

      final camera = _cameras.firstWhere(
        (c) => c.lensDirection == _selectedLens,
        orElse: () => _cameras.first,
      );

      _cameraController?.dispose();
      _cameraController = CameraController(camera, ResolutionPreset.medium, enableAudio: true);
      await _cameraController!.initialize();
      _cameraInitialized = true;
      notifyListeners();

      await _cameraController!.startVideoRecording();

      final start = DateTime.now();
      _recordingTimerRef?.cancel();
      _recordingTimerRef = Timer.periodic(const Duration(milliseconds: 250), (timer) {
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        final remaining = ((30000 - elapsed) / 1000).ceil();
        _recordingTime = remaining > 0 ? remaining : 0;
        if (elapsed >= 30000) {
          timer.cancel();
          stopRecordingAndSend();
        }
        notifyListeners();
      });
    } catch (e) {
      _error = 'Unable to access camera/microphone. Please grant permissions.';
      _status = SosStatus.idle;
      notifyListeners();
    }
  }

  Future<void> stopRecordingAndSend() async {
    _recordingTimerRef?.cancel();
    _recordingTimerRef = null;

    XFile? videoFile;
    try {
      if (_cameraController != null &&
          _cameraController!.value.isRecordingVideo) {
        videoFile = await _cameraController!.stopVideoRecording();
      }
    } catch (_) {}

    await _cameraController?.dispose();
    _cameraController = null;
    _cameraInitialized = false;

    _recordedVideoPath = videoFile?.path;
    _recordedAudioPath = '';

    await sendEmergencyData();
  }

  Future<void> sendEmergencyData() async {
    _status = SosStatus.sending;
    _error = '';
    notifyListeners();

    try {
      final freshLocation = await LocationService.getCurrent(fresh: true);
      if (freshLocation != null) {
        _location = freshLocation;
        _locationLink = freshLocation.googleMapsLink;
      }

      final videoPath = _recordedVideoPath ?? '';
      final audioPath = _recordedAudioPath ?? '';
      final locationLink = _locationLink;
      final latitude = _location?.latitude.toString() ?? '';
      final longitude = _location?.longitude.toString() ?? '';

      SosCase? caseData;
      try {
        caseData = await _sosService.createCase(
          videoPath: videoPath,
          audioPath: audioPath,
          locationLink: locationLink,
          latitude: latitude,
          longitude: longitude,
          notes: 'SOS Alert at ${DateTime.now().toLocal()}',
        );
      } on DioException catch (e) {
        final isConnectionDrop =
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown ||
            e.type == DioExceptionType.receiveTimeout ||
            e.error.toString().contains('Connection reset by peer') ||
            e.error.toString().contains('SocketException') ||
            e.error.toString().contains('Connection closed');

        if (isConnectionDrop) {
          caseData ??= await _verifyCaseDelivered();
          caseData ??= await _sosService.createCase(
              videoPath: videoPath,
              audioPath: audioPath,
              locationLink: locationLink,
              latitude: latitude,
              longitude: longitude,
              notes: 'SOS Alert at ${DateTime.now().toLocal()}',
            );
        } else {
          rethrow;
        }
      }

      playAlertSound();
      _status = SosStatus.sent;
      _showPreview = videoPath.isNotEmpty;
      _success = 'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.';
      notifyListeners();

      startLocationTracking(caseData.id);

      VoiceGuardService.resetDetectionCooldown();

      Future.delayed(const Duration(seconds: 5), () {
        _status = SosStatus.listening;
        _success = '';
        notifyListeners();
      });
    } catch (e) {
      _error = 'Failed to send emergency alert. Please check your connection and try again.';
      _status = SosStatus.idle;
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
    }
  }

  Future<SosCase?> _verifyCaseDelivered() async {
    try {
      final cases = await _sosService.getCases();
      if (cases.isEmpty) return null;
      final newest = cases.first;
      final createdAt = newest.createdAt ?? newest.timestamp;
      if (createdAt == null) return null;
      final age = DateTime.now().toUtc().difference(createdAt.toUtc());
      if (age.inSeconds <= 60) return newest;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> startLocationTracking(String caseId) async {
    _isTracking = true;
    notifyListeners();

    Future<void> sendUpdate() async {
      final loc = await LocationService.getCurrent(fresh: true);
      if (loc == null) return;
      _location = loc;
      _locationLink = loc.googleMapsLink;
      notifyListeners();
      try {
        await _sosService.updateLocation(
          caseId,
          latitude: loc.latitude.toString(),
          longitude: loc.longitude.toString(),
          locationLink: loc.googleMapsLink,
        );
      } catch (_) {}
    }

    await sendUpdate();
    _trackingRef?.cancel();
    _trackingRef = Timer.periodic(const Duration(seconds: 30), (_) => sendUpdate());
  }

  void stopLocationTracking() {
    _trackingRef?.cancel();
    _trackingRef = null;
    _isTracking = false;
    notifyListeners();
  }

  void dismissError() {
    _error = '';
    notifyListeners();
  }

  void dismissSuccess() {
    _success = '';
    notifyListeners();
  }

  void dismissPreview() {
    _showPreview = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelTimerRef?.cancel();
    _countdownRef?.cancel();
    _recordingTimerRef?.cancel();
    _trackingRef?.cancel();
    _mirrorTimer?.cancel();
    _watchSub?.cancel();
    _detectionSub?.cancel();
    _powerSub?.cancel();
    _statusSub?.cancel();
    _errorSub?.cancel();
    _mirrorSub?.cancel();
    _appRecSub?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }
}
