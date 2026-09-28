import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'sherpa_model_manager.dart';

class VoiceGuardService {
  static const _detectionEvent = 'keyword_detected';
  static const _statusEvent = 'service_status';
  static const _errorEvent = 'service_error';

  static const notificationChannelId = 'zelda_voice_protection';
  static const notificationChannelName = 'ZELDA Voice Protection';
  static const notificationChannelDescription =
      '24/7 background listening for the emergency phrase';
  static const fgsNotificationId = 256;
  static const alarmNotificationId = 257;

  /// The phrases that trigger an SOS. Configurable at runtime.
  static List<String> keywords = ['help me'];

  /// Replace the trigger phrases with a new list (empty lists are rejected).
  static void setKeywords(List<String> list) {
    final cleaned = list
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) return;
    keywords = cleaned;
  }

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final _detectionController = StreamController<String>.broadcast();
  static final _statusController = StreamController<bool>.broadcast();
  static final _errorController = StreamController<String>.broadcast();

  static bool _notificationsReady = false;

  /// Ensure the local notifications plugin is initialized in the CURRENT
  /// isolate (statics are per-isolate, so the background isolate needs its own
  /// init before it can post notifications).
  static Future<void> _ensureNotificationsInitialized() async {
    if (_notificationsReady) return;
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            notificationChannelId,
            notificationChannelName,
            description: notificationChannelDescription,
            importance: Importance.high,
          ),
        );
    _notificationsReady = true;
  }

  static DateTime _lastTriggeredAt = DateTime.fromMillisecondsSinceEpoch(0);
  static String? _lastTriggeredKeyword;

  /// Dedupe window: stops the SAME utterance from firing twice (partial result
  /// then final result of one "help me"). A new utterance after this window, or
  /// after a cancel/reset, triggers again with no limit.
  static const _dedupeWindow = Duration(seconds: 2);

  static const _enabledPrefKey = 'zelda_voice_guard_enabled';
  static const _resetCooldownEvent = 'reset_cooldown';
  static const _setForegroundEvent = 'set_foreground';
  static const _serviceReadyEvent = 'service_ready';
  static const _pendingTriggerKey = 'zelda_pending_sos_trigger';
  // Main-isolate mic verdict (reliable — has an Activity). The BG isolate's
  // record.hasPermission() lies (returns false on MIUI despite OS grant), so
  // the BG engine trusts this flag instead of its own check.
  static const _micGrantedMainKey = 'zelda_voice_mic_granted_main';

  static bool _appInForeground = true;

  /// Reset the trigger dedupe in the background isolate so a NEW utterance of
  /// the keyword can trigger SOS again immediately (after cancel/finish).
  /// Best-effort: even if this cross-isolate event is ever lost, the short
  /// [_dedupeWindow] self-heals within a few seconds.
  static void resetDetectionCooldown() {
    _service.invoke(_resetCooldownEvent);
  }

  /// Record that an emergency phrase was detected by the background isolate so
  /// that if the app is woken from the full-screen notification the SOS can be
  /// triggered even if the detection event itself was lost while the main
  /// isolate was dead/paused.
  static Future<void> _markPendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pendingTriggerKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<void> _clearPendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTriggerKey);
  }

  /// Consume a pending SOS trigger (set by the background isolate) if it is
  /// still fresh. Returns true when a trigger was fired. Called after the UI
  /// has subscribed to [detections] so the event is not lost on cold start.
  static Future<bool> consumePendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_pendingTriggerKey);
    if (ts == null) return false;
    await _clearPendingTrigger();
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age < 0 || age > 60000) return false; // stale
    developer.log(
      'Firing pending SOS trigger from background',
      name: 'VoiceGuard',
    );
    _detectionController.add(VoiceGuardService.keywords.first);
    return true;
  }

  static Future<void> _firePendingTriggerIfRecent() async {
    await consumePendingTrigger();
  }

  static Future<bool> wasEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledPrefKey) ?? false;
  }

  static Future<void> setEnabledPref(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPrefKey, enabled);
  }

  static Stream<String> get detections => _detectionController.stream;
  static Stream<bool> get statusStream => _statusController.stream;
  static Stream<String> get errors => _errorController.stream;

  static bool _configured = false;

  static Future<void> initialize() async {
    await _ensureNotificationsInitialized();

    WidgetsBinding.instance.addObserver(_LifecycleObserver());

    if (_configured) return;
    _configured = true;

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'ZELDA Voice Protection',
        initialNotificationContent: 'Listening for emergency phrases...',
        foregroundServiceNotificationId: fgsNotificationId,
        foregroundServiceTypes: [AndroidForegroundType.microphone],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );

    _service.on(_detectionEvent).listen((event) {
      if (event != null && event['keyword'] != null) {
        developer.log(
          'Keyword detected: ${event['keyword']}',
          name: 'VoiceGuard',
        );
        _detectionController.add(event['keyword'] as String);
      }
    });
    _service.on(_statusEvent).listen((event) {
      if (event != null && event['running'] != null) {
        developer.log(
          'Service status: running=${event['running']}',
          name: 'VoiceGuard',
        );
        _statusController.add(event['running'] as bool);
      }
    });
    _service.on(_errorEvent).listen((event) {
      if (event != null && event['error'] != null) {
        developer.log(
          'Service error: ${event['error']}',
          name: 'VoiceGuard',
          level: 1000,
        );
        _errorController.add(event['error'] as String);
      }
    });
    _service.on(_serviceReadyEvent).listen((_) {
      // Background isolate is up; tell it whether the app is in the foreground
      // so it knows whether to wake the UI on a keyword detection.
      _service.invoke(
        _setForegroundEvent,
        {'foreground': _appInForeground},
      );
    });
  }

  static Future<void> start() async {
    // Main-isolate verdict (reliable — has an Activity). Stash it for the BG
    // isolate, whose own record.hasPermission() is untrustworthy (MIUI
    // returns false there despite the OS grant).
    final micStatus = await Permission.microphone.request();
    await Permission.notification.request();
    await Permission.ignoreBatteryOptimizations.request();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_micGrantedMainKey, micStatus.isGranted);
    // Ordered restart: stop the running service FIRST (awaited, NO timeout)
    // and only then start fresh. A fire-and-forget stop with a timeout does
    // NOT cancel the pending invoke — it can deliver AFTER startService()
    // no-op'd on the already-running service and kill it with no restart
    // (permanent silent death). Skip entirely when nothing is running.
    if (await _service.isRunning()) {
      // invoke() returns void (no completion future), so TRUE ordering comes
      // from polling: only start fresh after the service actually reports
      // stopped. Bounded (20 s) so a dead channel can never hang the toggle.
      try {
        _service.invoke('stop', {'force': true});
      } catch (_) {}
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          if (!await _service.isRunning()) break;
        } catch (_) {
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    await _service.startService();
  }

  static Future<void> stop() async {
    await setEnabledPref(false);
    // Ordered like start(): no fire-and-forget. The pref is already false,
    // so the BG 'stop' guard lets this through; skip when nothing runs.
    if (await _service.isRunning()) {
      try {
        _service.invoke('stop');
      } catch (_) {}
    }
  }

  static Future<bool> isRunning() => _service.isRunning();

  /// Restart the background service if the user previously enabled voice
  /// protection (used when the OS kills the process/isolate while backgrounded).
  static Future<void> restartIfNeeded() async {
    if (!await wasEnabled()) return;
    if (await _service.isRunning()) return;
    await start();
  }

  /// Post a high-priority notification with full-screen intent so the app is
  /// brought to the foreground when an emergency phrase is detected while the
  /// app is in the background.
  static Future<void> showEmergencyNotification({required String keyword}) async {
    await _ensureNotificationsInitialized();
    await _notifications.show(
      id: alarmNotificationId,
      title: '🚨 ZELDA SOS TRIGGERED',
      body: 'Heard "$keyword". Opening app to send SOS...',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          notificationChannelName,
          channelDescription: notificationChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      ),
    );
  }

  /// Show the emergency notification FROM the background isolate. The plugin
  /// instance and initialization are per-isolate, so this ensures the
  /// notification channel is ready in the current isolate before posting.
  static Future<void> showEmergencyNotificationFromBackground({
    required String keyword,
  }) async {
    await _ensureNotificationsInitialized();
    await _notifications.show(
      id: alarmNotificationId,
      title: '🚨 ZELDA SOS TRIGGERED',
      body: 'Heard "$keyword". Opening app to send SOS...',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          notificationChannelName,
          channelDescription: notificationChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      ),
    );
  }
}

@pragma('vm:entry-point')
Future<void> _onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint('VoiceGuard BG isolate started');

  // Stage updates on the FGS notification text — observable on-device via
  // dumpsys even when Flutter logs never reach logcat (seen on Redmi).
  void note(String stage) {
    if (service is AndroidServiceInstance) {
      unawaited(
        service.setForegroundNotificationInfo(
          title: 'Voice Protection',
          content: stage,
        ),
      );
    }
  }

  note('Starting voice guard…');

  KeywordSpotter? spotter;
  OnlineStream? kwsStream;
  OfflineRecognizer? stt;
  AudioRecorder? recorder;
  StreamSubscription<List<int>>? pcmSub;
  // 8 s ring buffer @16 kHz mono — feeds the Moonshine confirm step.
  final Float32List ring = Float32List(8 * 16000);
  int ringPos = 0;
  int ringCount = 0;
  bool confirming = false;

  // Register the stop handler FIRST — before any fallible engine work.
  // If KWS/STT/mic setup throws, _onStart returns early via catch; a late
  // registration would leave a failed service unstoppable (toggle OFF =
  // no-op, toggle ON = silent no-op on the already-running service).
    service.on('stop').listen((event) async {
      // Guard against STALE stops: start()'s old fire-and-forget stop-first
      // (and any reordered invoke) must not kill a service the user still
      // wants. start() passes {'force': true} for a genuine ordered restart;
      // stop() flips the enabled pref to false BEFORE invoking, so a stop
      // that arrives while the pref is still true is stale → ignore it.
      final bool force = event != null && event['force'] == true;
      if (!force) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(VoiceGuardService._enabledPrefKey) ?? false) {
          return; // stale stop → ignore, voice still wanted
        }
      }
      await pcmSub?.cancel();
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {}
    }
    kwsStream?.free();
    spotter?.free();
    stt?.free();
    service.stopSelf();
  });

  var appInForeground = false;

  service.on(VoiceGuardService._resetCooldownEvent).listen((_) {
    VoiceGuardService._lastTriggeredAt =
        DateTime.fromMillisecondsSinceEpoch(0);
    VoiceGuardService._lastTriggeredKeyword = null;
    developer.log('Trigger dedupe reset by UI', name: 'VoiceGuard');
  });

  service.on(VoiceGuardService._setForegroundEvent).listen((event) {
    if (event != null && event['foreground'] != null) {
      appInForeground = event['foreground'] as bool;
      developer.log(
        'App foreground=$appInForeground',
        name: 'VoiceGuard',
      );
    }
  });

  // Tell the main isolate we are listening so it can reply with the current
  // foreground state. If the app process was killed (recents) the main isolate
  // is gone and we correctly keep appInForeground = false.
  service.invoke(VoiceGuardService._serviceReadyEvent);

  // ── Sherpa-ONNX two-stage engine (replaces Vosk) ──
  // Stage 1 (always-on): Zipformer KWS spots the trigger phrase from the
  // mic stream. Stage 2 (confirm): Moonshine offline STT transcribes the
  // last ~5 s of a ring buffer; only a transcript that still contains the
  // phrase fires — same dedupe + pending-trigger + full-screen alarm path.
  // Models download on first run (APK stays small); everything lives in
  // this BG isolate.
  try {
    initBindings();
    late final SherpaModelPaths paths;
    try {
      paths = await SherpaModelManager.ensureModels(
        onProgress: (stage, done, total) {
          debugPrint(
            '[VoiceGuard] model $stage '
            '${(done / 1024 / 1024).toStringAsFixed(1)} / '
            '${(total / 1024 / 1024).toStringAsFixed(1)} MB',
          );
          note(
            'Models $stage '
            '${(done / 1024 / 1024).toStringAsFixed(0)} / '
            '${(total / 1024 / 1024).toStringAsFixed(0)} MB',
          );
        },
      );
    } catch (e) {
      debugPrint('[VoiceGuard] model download failed: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Voice model unavailable: $e'},
      );
      return;
    }
    debugPrint('VoiceGuard Sherpa models ready');
    note('Models ready, loading KWS…');

    const kwsKeywords = '▁HELP ▁ME';
    spotter = KeywordSpotter(
      KeywordSpotterConfig(
        model: OnlineModelConfig(
          transducer: OnlineTransducerModelConfig(
            encoder: paths.kwsEncoder,
            decoder: paths.kwsDecoder,
            joiner: paths.kwsJoiner,
          ),
          tokens: paths.kwsTokens,
          numThreads: 2,
        ),
        // BPE-tokenized with the bundle's bpe.model ("HELP ME" -> 401 70).
        // keywordsBufSize MUST be the UTF-8 byte length of keywordsBuf:
        // native treats a size-0 buffer as zero registered keywords and
        // refuses to create the spotter ("Failed to create kws").
        keywordsBuf: kwsKeywords,
        keywordsBufSize: utf8.encode(kwsKeywords).length,
      ),
    );
    kwsStream = spotter.createStream();
    debugPrint('VoiceGuard KWS spotter created');
    note('KWS ready, loading STT…');

    stt = OfflineRecognizer(
      OfflineRecognizerConfig(
        model: OfflineModelConfig(
          moonshine: OfflineMoonshineModelConfig(
            preprocessor: paths.sttPreprocessor,
            encoder: paths.sttEncoder,
            uncachedDecoder: paths.sttUncachedDecoder,
            cachedDecoder: paths.sttCachedDecoder,
          ),
          tokens: paths.sttTokens,
          numThreads: 2,
        ),
      ),
    );
    debugPrint('VoiceGuard Moonshine recognizer created');
    note('STT ready, opening mic…');

    String normalize(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

    bool phraseMatches(String text, String keyword) {
      final normalized = normalize(text);
      // Lowercase BOTH sides: keywords list is display-cased ('Help Me')
      // but the transcript is normalized to lowercase. Without this, every
      // non-empty STT result was rejected and only empty transcripts fired.
      final escaped = RegExp.escape(keyword.toLowerCase());
      return RegExp(r'(^|\W)' + escaped + r'($|\W)').hasMatch(normalized);
    }

    Future<void> fireKeyword(String keyword) async {
      final now = DateTime.now();
      final isDuplicate =
          now.difference(VoiceGuardService._lastTriggeredAt) <
              VoiceGuardService._dedupeWindow &&
          VoiceGuardService._lastTriggeredKeyword == keyword;
      if (isDuplicate) {
        developer.log(
          'Keyword "$keyword" already triggered recently, ignoring',
          name: 'VoiceGuard',
        );
        return;
      }
      VoiceGuardService._lastTriggeredAt = now;
      VoiceGuardService._lastTriggeredKeyword = keyword;
      developer.log('Keyword confirmed: $keyword', name: 'VoiceGuard');
      service.invoke(VoiceGuardService._detectionEvent, {'keyword': keyword});
      if (!appInForeground) {
        await VoiceGuardService._markPendingTrigger();
        await VoiceGuardService.showEmergencyNotificationFromBackground(
          keyword: keyword,
        );
      }
    }

    // (Diagnostics note: earlier builds exposed KWS hit counts in the FGS
    // notification text for on-device debugging; now back to debugPrint only.)

    Future<void> confirmAndFire() async {
      if (confirming) return;
      confirming = true;
      try {
        final recognizer = stt;
        if (recognizer == null) return;
        final int take = ringCount < 5 * 16000 ? ringCount : 5 * 16000;
        if (take < 16000) return; // need >= 1 s of audio to confirm
        final Float32List tail = Float32List(take);
        int start = (ringPos - take) % ring.length;
        if (start < 0) start += ring.length;
        for (int i = 0; i < take; i++) {
          tail[i] = ring[(start + i) % ring.length];
        }
        String transcript = '';
        try {
          final OfflineStream s = recognizer.createStream();
          s.acceptWaveform(samples: tail, sampleRate: 16000);
          recognizer.decode(s);
          transcript = recognizer.getResult(s).text;
          s.free();
        } catch (e) {
          debugPrint('[VoiceGuard] moonshine confirm failed: $e');
        }
        final String text = transcript.toLowerCase().trim();
        if (text.isEmpty) {
          // STT came back empty (or failed): fail OPEN on the KWS hit —
          // missing a real cry for help is worse than a false alarm, and
          // the user still gets the 5 s cancel window.
          debugPrint('[VoiceGuard] KWS hit, STT empty — firing on KWS');
          await fireKeyword(VoiceGuardService.keywords.first);
          return;
        }
        for (final keyword in VoiceGuardService.keywords) {
          if (phraseMatches(text, keyword)) {
            debugPrint('[VoiceGuard] KWS hit confirmed by STT: "$text"');
            await fireKeyword(keyword);
            return;
          }
        }
        debugPrint('[VoiceGuard] KWS hit rejected by STT: "$text"');
      } finally {
        confirming = false;
      }
    }

    final mic = AudioRecorder();
    recorder = mic;
    // Trust the MAIN-isolate verdict (stashed by start(), reliable — has an
    // Activity). record.hasPermission() inside this BG isolate lies on MIUI
    // (returns false despite the OS grant), so it is only a fallback. A real
    // denial still surfaces as a startStream failure below and maps to the
    // same permission-denied error.
    final bgPrefs = await SharedPreferences.getInstance();
    final mainSideGranted =
        bgPrefs.getBool(VoiceGuardService._micGrantedMainKey) ?? false;
    if (!mainSideGranted && !await mic.hasPermission()) {
      debugPrint('[VoiceGuard] mic permission denied');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Microphone permission denied'},
      );
      return;
    }
    late final Stream<List<int>> pcm;
    try {
      pcm = await mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
    } catch (e) {
      debugPrint('[VoiceGuard] mic startStream failed: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Microphone permission denied'},
      );
      return;
    }

    // IMPORTANT: keep the per-chunk path light. The Moonshine confirm +
    // full-screen alarm + pending-trigger write happen in confirmAndFire /
    // fireKeyword without stalling the mic loop.
    pcmSub = pcm.listen((List<int> c) {
      final Uint8List chunk = c is Uint8List ? c : Uint8List.fromList(c);
      final int n = chunk.length ~/ 2;
      final Float32List samples = Float32List(n);
      for (int i = 0; i < n; i++) {
        int v = chunk[2 * i] | (chunk[2 * i + 1] << 8);
        if (v >= 32768) v -= 65536;
        final double f = v / 32768.0;
        samples[i] = f;
        ring[ringPos] = f;
        ringPos = (ringPos + 1) % ring.length;
        if (ringCount < ring.length) ringCount++;
      }
      final spot = spotter;
      final stream = kwsStream;
      if (spot == null || stream == null) return;
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      while (spot.isReady(stream)) {
        spot.decode(stream);
      }
      if (spot.getResult(stream).keyword.isEmpty) return;
      // Reset so the SAME utterance cannot re-fire while confirming.
      debugPrint('[VoiceGuard] KWS hit, confirming with STT');
      spot.reset(stream);
      unawaited(confirmAndFire());
    }, onError: (Object e) {
      debugPrint('[VoiceGuard] mic stream error: $e');
    });

    debugPrint('VoiceGuard Sherpa engine started, listening');
    note('Listening for "help me"');
    service.invoke(VoiceGuardService._statusEvent, {'running': true});
  } catch (e, s) {
    developer.log(
      'BG service failed: $e\n$s',
      name: 'VoiceGuard',
      level: 1000,
    );
    debugPrint('VoiceGuard BG service failed: $e\n$s');
    note('Voice guard error — open app for details');
    service.invoke(VoiceGuardService._errorEvent, {'error': '$e'});
    service.invoke(VoiceGuardService._statusEvent, {'running': false});
    return;
  }

  Timer.periodic(const Duration(seconds: 10), (_) {
    service.invoke('heartbeat');
  });
}

class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = VoiceGuardService._appInForeground;
    final foreground = state == AppLifecycleState.resumed;
    VoiceGuardService._appInForeground = foreground;
    VoiceGuardService._service.invoke(
      VoiceGuardService._setForegroundEvent,
      {'foreground': foreground},
    );
    if (foreground && !wasForeground) {
      // App is coming back to the foreground after being backgrounded; fire any
      // SOS trigger that was detected while the main isolate was paused.
      VoiceGuardService._firePendingTriggerIfRecent();
    }
  }
}
