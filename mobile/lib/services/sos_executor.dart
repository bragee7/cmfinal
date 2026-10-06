import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import 'location_service.dart';
import 'sos_service.dart';
import 'voice_guard_service.dart';

/// Authoritative SOS state machine that runs in the BACKGROUND isolate
/// (the flutter_background_service engine, already kept alive as a
/// microphone foreground service while voice protection is on, and booted
/// on-demand into executor-standby mode for power-button triggers).
///
/// Why this exists: every SOS timer (5s cancel window, 3s countdown,
/// 30s recording, 30s live tracking) used to live in the main-isolate
/// SosController, which is only born when the dashboard mounts. A voice or
/// power trigger fired while the app was closed could therefore only stash
/// a pending pref and wait for the user to open ZELDA. This executor owns
/// the whole countdown → recording → GPS → submit → upload → tracking chain
/// in the background isolate, mirrors every transition into prefs + a
/// broadcast event, and the Flutter UI only OBSERVES/synchronizes.
///
/// Single active SOS: a trigger arriving while one is in flight is answered
/// with a busy signal (surfaced as "SOS already in progress"), never a
/// second case.
class SosExecutor {
  SosExecutor._();

  // ── prefs mirror (consumed by native alarm/recording + Flutter UI) ──
  static const stateKey = 'zelda_sos_state';
  static const remainingKey = 'zelda_sos_remaining';
  static const sourceKey = 'zelda_sos_source';
  static const startedAtKey = 'zelda_sos_started_at';
  static const commandKey = 'zelda_sos_command';
  static const caseIdKey = 'zelda_sos_case_id';
  static const videoPathKey = 'zelda_sos_video_path';
  static const audioPathKey = 'zelda_sos_audio_path';
  static const audioOnlyKey = 'zelda_sos_audio_only';
  static const nativeCommandKey = 'zelda_sos_native_command';
  static const nativeDoneKey = 'zelda_sos_native_done';
  static const alarmRequestKey = 'zelda_sos_alarm_request';
  static const alarmHandledKey = 'zelda_sos_alarm_handled';

  // ── cross-isolate invoke protocol (BG <-> main) ──
  static const sosStateEvent = 'sos_state';
  static const sosTriggerInvoke = 'sos_trigger';
  static const sosCancelInvoke = 'sos_cancel';
  static const sosStartAppRecording = 'sos_start_app_recording';
  static const sosAppRecordingDone = 'sos_app_recording_done';

  static const states = [
    'idle',
    'listening',
    'cancelWindow',
    'countdown',
    'recording',
    'sending',
    'sent',
  ];

  // ── BG-isolate runtime (per-isolate statics, touched only in BG) ──
  static ServiceInstance? _bgService;
  static bool Function()? _isForeground;
  static Timer? _tick;
  static Timer? _trackingTimer;
  static String _trackingCaseId = '';

  /// Mic pause/resume hooks (bound by the voice engine in _onStart). The
  /// native background recording needs the microphone, so the executor
  /// pauses the KWS loop first and resumes it after the SOS send.
  static Future<void> Function()? onPauseMic;
  static Future<void> Function()? onResumeMic;

  static void bindMicHooks({
    required Future<void> Function() onPause,
    required Future<void> Function() onResume,
  }) {
    onPauseMic = onPause;
    onResumeMic = onResume;
  }

  static Future<void> _resumeMicBestEffort(String why) async {
    try {
      await onResumeMic?.call().timeout(const Duration(seconds: 15));
      await VoiceGuardService.flog('sosexec', 'mic resumed ($why)');
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'mic resume failed ($why): $e');
    }
  }

  static bool _active = false;
  static String _phase = 'idle';
  static int _remaining = 0;
  static String _source = '';
  static int _busyNotifiedAt = 0;

  /// Boot the executor inside the BG isolate. Cheap and infallible by
  /// design (prefs + timers only) — call FIRST in _onStart, before any
  /// mic/spotter work, so power-button triggers get a live executor even
  /// when voice listening is disabled.
  static Future<void> onBoot(
    ServiceInstance service,
    bool Function() isForeground,
  ) async {
    _bgService = service;
    _isForeground = isForeground;

    service.on(sosTriggerInvoke).listen((event) async {
      final source = (event?['source'] as String?)?.trim();
      await onTrigger(source == null || source.isEmpty ? 'app' : source);
    });
    service.on(sosCancelInvoke).listen((_) async {
      await onCancel(fromInvoke: true);
    });
    service.on(sosAppRecordingDone).listen((event) async {
      final path = (event?['videoPath'] as String?) ?? '';
      final err = (event?['error'] as String?) ?? '';
      await onAppRecordingDone(
          path.isEmpty ? null : path, err.isEmpty ? null : err);
    });
    service.on(VoiceGuardService.resetCooldownEventName).listen((_) {
      // Cooldown reset doubles as "new utterance allowed" — if no SOS is
      // active there is nothing to do; the dedupe timestamps live in the
      // voice engine itself.
    });

    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll());
    });
    await VoiceGuardService.flog('sosexec', 'executor loop started');
    // BG isolate rebooted mid-SOS (OS kill + restart): a native-owned flow
    // may have finished recording while we were dead. Resume the send
    // instead of stranding the evidence until the app opens.
    unawaited(_resumeInterrupted());
  }

  static Future<void> _resumeInterrupted() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      if ((prefs.getString(stateKey) ?? '') != 'recording') return;
      if (!prefs.containsKey(nativeDoneKey)) return;
      if ((prefs.getString(caseIdKey) ?? '').isNotEmpty) return;
      if (_active) return;
      _active = true;
      _phase = 'recording';
      _remaining = 0;
      _source = prefs.getString(sourceKey) ?? '';
      final video = prefs.getString(videoPathKey) ?? '';
      final audioOnly = prefs.getBool(audioOnlyKey) ?? false;
      await VoiceGuardService.flog(
          'sosexec', 'resuming interrupted SOS audioOnly=$audioOnly');
      await _sendFromBackground(videoPath: video, audioOnly: audioOnly);
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'resume check failed: $e');
    }
  }

  /// A trigger arrived (voice word, power button, manual button, pending).
  /// Safe to call from EITHER isolate: in BG it runs directly; the main
  /// isolate should prefer [requestTrigger] (invoke when BG is alive).
  static Future<void> onTrigger(String source) async {
    if (_bgService == null) return; // main isolate without BG: caller falls back
    if (_active) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _busyNotifiedAt > 3000) {
        _busyNotifiedAt = now;
        _broadcast(extra: {'busy': true, 'message': 'SOS already in progress'});
      }
      return;
    }
    _active = true;
    _phase = 'cancelWindow';
    _remaining = 5;
    _source = source;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(stateKey, _phase);
    await prefs.setInt(remainingKey, _remaining);
    await prefs.setString(sourceKey, _source);
    await prefs.setInt(startedAtKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(commandKey, '');
    await prefs.remove(caseIdKey);
    await prefs.remove(videoPathKey);
    await prefs.remove(audioPathKey);
    await prefs.setBool(audioOnlyKey, false);
    await prefs.setString(nativeCommandKey, '');
    await prefs.remove(nativeDoneKey);
    // Native alarm (full-screen cancel UI over home/lock screen). The
    // persistent PowerGuardService polls this key and posts the FSI
    // notification — no platform channel needed from the BG isolate.
    final ts = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(alarmRequestKey, ts);
    await VoiceGuardService.flog('sosexec', 'TRIGGER source=$source');
    _broadcast();
  }

  /// Cancel the in-flight SOS. Safe from either isolate; the BG loop also
  /// polls [commandKey] so a native cancel (alarm activity) lands here too.
  static Future<void> onCancel({bool fromInvoke = false}) async {
    if (_bgService == null) {
      // Main isolate with no BG engine: leave a cancel command the BG loop
      // (or a later boot) will honor, and let the legacy local path finish.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(commandKey, 'cancel');
      } catch (_) {}
      return;
    }
    if (!_active) return;
    await _doCancel('user cancel');
  }

  static Future<void> _doCancel(String reason) async {
    _active = false;
    _phase = 'listening';
    _remaining = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(stateKey, _phase);
      await prefs.setInt(remainingKey, 0);
      await prefs.setString(commandKey, '');
      await prefs.setString(nativeCommandKey, 'stop');
    } catch (_) {}
    _stopTracking();
    await VoiceGuardService.flog('sosexec', 'CANCELLED ($reason)');
    await _resumeMicBestEffort('cancelled');
    _broadcast(extra: {'cancelled': true, 'message': 'SOS alert cancelled'});
  }

  /// 1s heartbeat: power-trigger poll, cancel-command poll, countdown ticks.
  static Future<void> _poll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Same cross-isolate coherency as readSnapshot: the power trigger is
      // stashed by the native receiver and cancels arrive from the main
      // isolate / native alarm activity. Reload so this BG-side read sees
      // their writes instead of the boot-time cache.
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}

      // Power-button path: native receiver stashed a trigger while we run.
      final powerTs = prefs.getInt('zelda_power_sos_trigger');
      if (powerTs != null) {
        final age = DateTime.now().millisecondsSinceEpoch - powerTs;
        await prefs.remove('zelda_power_sos_trigger');
        if (age >= 0 && age <= 60000) {
          await VoiceGuardService.flog('sosexec', 'power trigger polled');
          await onTrigger('power-button');
          return;
        }
      }

      if (!_active) return;

      // Native cancel (alarm activity) lands via prefs.
      if ((prefs.getString(commandKey) ?? '').trim() == 'cancel') {
        await _doCancel('alarm-activity cancel');
        return;
      }

      _remaining -= 1;
      if (_remaining > 0) {
        await prefs.setInt(remainingKey, _remaining);
        _broadcast();
        return;
      }

      if (_phase == 'cancelWindow') {
        _phase = 'countdown';
        _remaining = 3;
        await prefs.setString(stateKey, _phase);
        await prefs.setInt(remainingKey, _remaining);
        await VoiceGuardService.flog('sosexec', 'window elapsed → countdown');
        _broadcast();
        return;
      }

      if (_phase == 'countdown') {
        await _beginRecording(prefs);
        return;
      }
      // recording/sending/sent phases are event-driven (see below), the
      // tick only keeps the poll alive for cancel + power triggers.
      _broadcast();
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'poll error: $e');
    }
  }

  static Future<void> _beginRecording(SharedPreferences prefs) async {
    _phase = 'recording';
    _remaining = 30;
    await prefs.setString(stateKey, _phase);
    await prefs.setInt(remainingKey, _remaining);
    _broadcast();
    final fg = _isForeground?.call() ?? false;
    await VoiceGuardService.flog('sosexec', 'countdown elapsed → recording fg=$fg');

    if (fg) {
      // App is open: the main isolate records with the existing
      // CameraController pipeline and reports back the file path.
      try {
        _bgService?.invoke(sosStartAppRecording);
      } catch (_) {}
      // Fallback: if the main isolate never reports back (killed between
      // the check and the invoke), go native after 45 s instead of hanging.
      unawaited(_appRecordingFallback());
      return;
    }
    await _beginNativeRecording(prefs);
  }

  static Future<void> _appRecordingFallback() async {
    await Future.delayed(const Duration(seconds: 45));
    if (!_active || _phase != 'recording') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(videoPathKey) != null) return; // main reported in
    } catch (_) {}
    await VoiceGuardService.flog('sosexec', 'app recording no-show → native');
    try {
      final prefs = await SharedPreferences.getInstance();
      await _beginNativeRecording(prefs);
    } catch (_) {}
  }

  /// Called (via invoke) by the main isolate when its CameraController
  /// recording finishes. Continues the chain in the background.
  static Future<void> onAppRecordingDone(String? videoPath, String? error) async {
    if (!_active || _phase != 'recording') return;
    // A cancel may have landed between the report and this handler.
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString(commandKey) ?? '') == 'cancel') {
        await _doCancel('cancel before app-recording report');
        return;
      }
    } catch (_) {}
    if (videoPath == null || videoPath.isEmpty) {
      await VoiceGuardService.flog('sosexec', 'app recording failed ($error) → native');
      try {
        final prefs = await SharedPreferences.getInstance();
        await _beginNativeRecording(prefs);
      } catch (_) {}
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(videoPathKey, videoPath);
    } catch (_) {}
    await _sendFromBackground(videoPath: videoPath, audioOnly: false);
  }

  static Future<void> _beginNativeRecording(SharedPreferences prefs) async {
    // The KWS mic loop holds the microphone — release it first so the
    // native recorder (CameraX audio / MediaRecorder) can claim it.
    try {
      await onPauseMic?.call().timeout(const Duration(seconds: 10));
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'mic pause failed: $e');
    }
    await prefs.setString(nativeCommandKey, 'start_recording');
    await VoiceGuardService.flog('sosexec', 'native recording requested');
    // Wait for SosRecordingService to finish (30 s clip + margin), while
    // still honoring cancel via the normal tick.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (!_active || _phase != 'recording') return; // cancelled meanwhile
      SharedPreferences p;
      try {
        p = await SharedPreferences.getInstance();
        // Native recorder + alarm activity write from outside this isolate:
        // reload each iteration so cancel/done are seen promptly.
        try {
          await p.reload().timeout(const Duration(seconds: 3));
        } catch (_) {}
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      if ((p.getString(commandKey) ?? '') == 'cancel') {
        await _doCancel('cancel during native recording');
        return;
      }
      if (p.containsKey(nativeDoneKey)) {
        final video = p.getString(videoPathKey) ?? '';
        final audioOnly = p.getBool(audioOnlyKey) ?? false;
        await VoiceGuardService.flog(
            'sosexec', 'native recording done audioOnly=$audioOnly');
        await _sendFromBackground(videoPath: video, audioOnly: audioOnly);
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    await VoiceGuardService.flog('sosexec', 'native recording timeout → send anyway');
    await _sendFromBackground(videoPath: '', audioOnly: true);
  }

  static Future<void> _sendFromBackground({
    required String videoPath,
    required bool audioOnly,
  }) async {
    if (!_active) return;
    _phase = 'sending';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(stateKey, _phase);
    } catch (_) {}
    _broadcast();

    String lat = '';
    String lng = '';
    String link = '';
    try {
      final loc = await LocationService.getCurrent(fresh: true)
          .timeout(const Duration(seconds: 20));
      if (loc != null) {
        lat = loc.latitude.toString();
        lng = loc.longitude.toString();
        link = loc.googleMapsLink;
      }
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'BG location failed: $e');
    }

    try {
      // Auth rides per-request from secure storage (ApiClient interceptor
      // reads the same Android Keystore entry in this isolate). Pre-check
      // so a logged-out phone fails loudly instead of sending a 401.
      String token = '';
      try {
        token = await ApiClient.getToken()
                .timeout(const Duration(seconds: 10)) ??
            '';
      } catch (e) {
        await VoiceGuardService.flog('sosexec', 'BG token read failed: $e');
      }
      if (token.isEmpty) throw StateError('not logged in (no auth token)');
      // Audio-only fallback (native recording without camera) rides the
      // audio field; the server accepts audio without video.
      String audioPath = '';
      try {
        final prefs = await SharedPreferences.getInstance();
        if (audioOnly) audioPath = prefs.getString(audioPathKey) ?? '';
      } catch (_) {}
      final svc = SosService();
      final caseData = await svc
          .createCase(
            videoPath: videoPath,
            audioPath: audioPath,
            locationLink: link,
            latitude: lat,
            longitude: lng,
            notes: 'SOS Alert ($_source) at ${DateTime.now().toLocal()}',
          )
          .timeout(const Duration(minutes: 3));
      _phase = 'sent';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(stateKey, _phase);
        await prefs.setString(caseIdKey, caseData.id);
      } catch (_) {}
      await VoiceGuardService.flog('sosexec', 'SENT case=${caseData.id}');
      _broadcast(extra: {
        'sent': true,
        'message':
            'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.'
      });
      _active = false; // new triggers allowed; tracking continues by caseId
      _startTracking(caseData.id);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(stateKey, 'listening');
      } catch (_) {}
      await _resumeMicBestEffort('sent');
    } catch (e) {
      _active = false;
      _phase = 'idle';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(stateKey, _phase);
      } catch (_) {}
      await VoiceGuardService.flog('sosexec', 'SEND FAILED: $e');
      await _resumeMicBestEffort('send-failed');
      _broadcast(extra: {
        'failed': true,
        'message': 'Failed to send emergency alert. Please check your connection and try again.'
      });
    }
  }

  static void _startTracking(String caseId) {
    _trackingTimer?.cancel();
    _trackingCaseId = caseId;
    _trackingTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final loc = await LocationService.getCurrent(fresh: true)
            .timeout(const Duration(seconds: 20));
        if (loc == null) return;
        await SosService()
            .updateLocation(
              _trackingCaseId,
              latitude: loc.latitude.toString(),
              longitude: loc.longitude.toString(),
              locationLink: loc.googleMapsLink,
            )
            .timeout(const Duration(seconds: 30));
      } catch (_) {}
    });
  }

  static void _stopTracking() {
    _trackingTimer?.cancel();
    _trackingTimer = null;
    _trackingCaseId = '';
  }

  /// Live snapshot broadcast for the Flutter UI (observer).
  static void _broadcast({Map<String, Object?>? extra}) {
    final payload = <String, Object?>{
      'state': _phase,
      'remaining': _remaining,
      'source': _source,
      'active': _active,
    };
    if (extra != null) payload.addAll(extra);
    try {
      _bgService?.invoke(sosStateEvent, payload);
    } catch (_) {}
  }

  // ── main-isolate API ──

  /// Ask the BG executor to start an SOS. Returns true when a live BG
  /// engine accepted it; false when the caller must run the legacy local
  /// path instead (BG service not running, e.g. voice protection off).
  static Future<bool> requestTrigger(String source) async {
    try {
      final running = await VoiceGuardService.isRunning()
          .timeout(const Duration(seconds: 3));
      if (!running) return false;
      VoiceGuardService.serviceInvoke(sosTriggerInvoke, {'source': source});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ask the BG executor to cancel (invoke + prefs command belt & braces).
  static Future<void> requestCancel() async {
    try {
      VoiceGuardService.serviceInvoke(sosCancelInvoke);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setString(commandKey, 'cancel')
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Ask the native layer to post the full-screen SOS alarm
  /// (SosAlarmActivity over home/lock screen). The persistent
  /// PowerGuardService polls [alarmRequestKey] and posts it — no platform
  /// channel is available from the BG isolate, so prefs are the bridge.
  static Future<void> requestNativeAlarm() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          alarmRequestKey, DateTime.now().millisecondsSinceEpoch);
      await VoiceGuardService.flog('sosexec', 'native alarm requested');
    } catch (_) {}
  }
  static Future<Map<String, Object?>> readSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      // Cross-isolate coherency: the BG executor (and native services)
      // write these keys from another isolate/process-side writer while the
      // UI reads them here every second. SharedPreferences caches per
      // isolate, so without reload() this poll would forever return the
      // values fetched at app start (stale 'idle') and fight the live
      // broadcast snapshots — the SOS UI flicker. Reload from disk first.
      try {
        await prefs.reload().timeout(const Duration(seconds: 5));
      } catch (_) {}
      return {
        'state': prefs.getString(stateKey) ?? 'idle',
        'remaining': prefs.getInt(remainingKey) ?? 0,
        'source': prefs.getString(sourceKey) ?? '',
        'caseId': prefs.getString(caseIdKey) ?? '',
      'videoPath': prefs.getString(videoPathKey) ?? '',
      'audioPath': prefs.getString(audioPathKey) ?? '',
      'audioOnly': prefs.getBool(audioOnlyKey) ?? false,
      'nativeDone': prefs.containsKey(nativeDoneKey),
      'command': prefs.getString(commandKey) ?? '',
      'startedAt': prefs.getInt(startedAtKey) ?? 0,
    };
    } catch (_) {
      return {'state': 'idle', 'remaining': 0, 'source': '', 'caseId': ''};
    }
  }

  /// Clears a stale/orphaned BG mirror so the UI (and future triggers) are
  /// not haunted by a dead owner's frozen state. Keeps finished evidence and
  /// the delivered case id intact for adoption.
  static Future<void> resetMirror() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs.setString(stateKey, 'idle');
      await prefs.setInt(remainingKey, 0);
      await prefs.remove(commandKey);
      await prefs.remove(nativeDoneKey);
    } catch (_) {}
  }
}
