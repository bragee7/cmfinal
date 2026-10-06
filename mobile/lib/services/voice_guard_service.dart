import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'keyword_model_manager.dart';
import 'sos_executor.dart';

class VoiceGuardService {
  static const _detectionEvent = 'keyword_detected';
  static const _statusEvent = 'service_status';
  static const _errorEvent = 'service_error';

  static const notificationChannelId = 'zelda_voice_protection';
  static const notificationChannelName = 'ZELDA Voice Protection';
  static const notificationChannelDescription =
      '24/7 background listening for the emergency trigger word';
  static const fgsNotificationId = 256;
  static const alarmNotificationId = 257;

  /// Default trigger word. The user can add their own words from the
  /// dashboard — they are persisted and the listener rebuilds for them.
  static const List<String> defaultTriggerWords = ['Help me'];

  /// The trigger words that fire an SOS. Display-cased for the UI; the
  /// background engine uppercases them into BPE tokens for the spotter.
  static List<String> keywords = ['Help me'];

  /// Replace the trigger phrases with a new list (empty lists are rejected).
  static void setKeywords(List<String> list) {
    final cleaned =
        list.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (cleaned.isEmpty) return;
    keywords = cleaned;
  }

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final _detectionController = StreamController<String>.broadcast();
  static final _statusController = StreamController<bool>.broadcast();
  // Sticky copy of the last ENGINE-UP state. Broadcast controllers drop
  // events with zero listeners, so a running:true fired before anyone
  // subscribed (fast cached-model boot, activity recreation) would be lost
  // forever — the watchdog seeds from this and re-queries the live engine.
  static bool _lastRunning = false;
  static final _errorController = StreamController<String>.broadcast();
  static final _sosStateController =
      StreamController<Map<String, Object?>>.broadcast();
  static final _appRecordingController = StreamController<void>.broadcast();

  /// Fire-and-forget invoke on the BG isolate (no-op when it is not
  /// running — callers that need certainty check isRunning() first).
  static void serviceInvoke(String event, [Map<String, dynamic>? args]) {
    try {
      _service.invoke(event, args);
    } catch (_) {}
  }

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

  /// Dedupe window: stops the SAME utterance from firing twice (spotter
  /// emits the hit on consecutive frames of one "help me"). A new utterance
  /// after this window, or after a cancel/reset, triggers again with no limit.
  static const _dedupeWindow = Duration(seconds: 2);

  static const _enabledPrefKey = 'zelda_voice_guard_enabled';
  static const _triggerWordsPrefKey = 'zelda_trigger_words';
  static const _resetCooldownEvent = 'reset_cooldown';
  static const _setForegroundEvent = 'set_foreground';
  static const _serviceReadyEvent = 'service_ready';
  /// Public alias of [_resetCooldownEvent] for the BG SOS executor
  /// (separate library; the private name is not visible there).
  static const String resetCooldownEventName = 'reset_cooldown';
  static const _pendingTriggerKey = 'zelda_pending_sos_trigger';
  // Main-isolate mic verdict (reliable — has an Activity). The BG isolate's
  // record.hasPermission() lies (returns false on MIUI despite OS grant), so
  // the BG engine trusts this flag instead of its own check.
  static const _micGrantedMainKey = 'zelda_voice_mic_granted_main';
  // Boot-stage marker shared main<->BG via prefs (see markStage): the BG
  // engine stamps each startup step so a stall/crash names the exact step.
  static const _stageKey = 'zelda_voice_boot_stage';
  static const _stageTimeKey = 'zelda_voice_boot_stage_at';

  static bool _appInForeground = true;

  /// Reset the trigger dedupe in the background isolate so a NEW utterance of
  /// the keyword can trigger SOS again immediately (after cancel/finish).
  /// Best-effort: even if this cross-isolate event is ever lost, the short
  /// [_dedupeWindow] self-heals within a few seconds.
  static void resetDetectionCooldown() {
    _service.invoke(_resetCooldownEvent);
  }

  /// Record that a trigger word was detected by the background isolate so
  /// that if the app is woken from the full-screen notification the SOS can be
  /// triggered even if the detection event itself was lost while the main
  /// isolate was dead/paused.
  static Future<void> _markPendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _pendingTriggerKey, DateTime.now().millisecondsSinceEpoch);
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
    // Timeout-guarded: on some HyperOS builds the prefs channel can stall;
    // a stall here must never wedge the toggle silently (best-effort write).
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setBool(_enabledPrefKey, enabled)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      developer.log('setEnabledPref failed (best-effort): $e',
          name: 'VoiceGuard', level: 1000);
    }
  }

  /// Trigger words persisted by the custom-word setup (shared by the main
  /// and background isolates via prefs — statics are per-isolate).
  static Future<List<String>> getTriggerWords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_triggerWordsPrefKey);
    if (raw == null || raw.isEmpty) return List.of(defaultTriggerWords);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final words = decoded
            .whereType<String>()
            .map((w) => w.trim())
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) return words;
      }
    } catch (_) {}
    return List.of(defaultTriggerWords);
  }

  static Future<void> _persistTriggerWords(List<String> words) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_triggerWordsPrefKey, jsonEncode(words));
  }

  /// Save custom trigger words from the dashboard setup. Pre-validates
  /// against the on-device token set when the model bundle is already
  /// downloaded (unsupported words are dropped with a clear message, never
  /// saved silently). Restarts the listener so the spotter rebuilds with
  /// the new words immediately.
  static Future<({bool ok, List<String> words, String message})>
      setTriggerWords(List<String> words) async {
    final cleaned =
        words.map((w) => w.trim()).where((w) => w.isNotEmpty).toList();
    if (cleaned.isEmpty) {
      return (ok: false, words: await getTriggerWords(), message: 'Enter at least one word.');
    }
    // Keep the list small — every extra word costs spotter CPU on every frame.
    final limited = cleaned.take(3).toList();

    // Pre-validate when the bundle is already on disk (first run downloads
    // it in the background isolate instead — which validates again there).
    List<String> accepted = limited;
    List<String> dropped = const [];
    final tokenSet = await _cachedTokenSet();
    if (tokenSet != null) {
      accepted = [];
      dropped = [];
      for (final w in limited) {
        if (_wordSupported(w, tokenSet)) {
          accepted.add(w);
        } else {
          dropped.add(w);
        }
      }
      if (accepted.isEmpty) {
        return (
          ok: false,
          words: await getTriggerWords(),
          message:
              '"${dropped.join(', ')}" is not supported by the on-device listener. Try a common English word.',
        );
      }
    }

    await _persistTriggerWords(accepted);
    keywords = List.of(accepted);

    // Restart the engine so the spotter rebuilds with the new words now
    // (a running service would otherwise keep the old keywords until the
    // next toggle). NOT stop(): that would clear the enabled pref — invoke
    // the isolate's stop listener directly, wait, then start fresh.
    if (await _service
        .isRunning()
        .timeout(const Duration(seconds: 3))
        .catchError((_) => false)) {
      try {
        _service.invoke('stop');
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
      await start();
    }

    final note = dropped.isEmpty
        ? ''
        : ' Skipped unsupported: "${dropped.join(', ')}".';
    final names = accepted.map((w) => '"$w"').join(', ');
    return (
      ok: true,
      words: List.of(accepted),
      message: 'Trigger saved: $names.$note Voice protection restarted — say it to test.',
    );
  }

  /// Tokens file from a previous download, if present (null on first run
  /// before the background isolate downloads the bundle).
  static Future<Set<String>?> _cachedTokenSet() async {
    try {
      final paths = await KeywordModelManager.cachedPaths();
      if (paths == null) return null;
      return KeywordModelManager.loadTokenSet(paths.tokens);
    } catch (_) {
      return null;
    }
  }

  /// Every whitespace-separated part must exist as a BPE token (▁PART).
  static bool _wordSupported(String word, Set<String> tokenSet) {
    final parts = word.toUpperCase().split(RegExp(r'\s+'));
    if (parts.isEmpty) return false;
    for (final part in parts) {
      if (part.isEmpty) continue;
      if (!tokenSet.contains('▁$part')) return false;
    }
    return true;
  }

  static Stream<String> get detections => _detectionController.stream;
  static Stream<bool> get statusStream => _statusController.stream;
  static Stream<String> get errors => _errorController.stream;
  /// Live SOS executor snapshots (BG authority): state, remaining, source,
  /// busy/cancelled/sent flags. The dashboard mirrors these — it never runs
  /// its own timers while a BG engine is alive.
  static Stream<Map<String, Object?>> get sosStateStream =>
      _sosStateController.stream;
  /// The BG executor asks the open app to run its CameraController recording
  /// (only fires while the app is foregrounded at countdown end).
  static Stream<void> get appRecordingRequests =>
      _appRecordingController.stream;

  static bool _configured = false;

  static Future<void> initialize() async {
    try {
      await _ensureNotificationsInitialized()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      await flog('init', 'notifications init failed (continuing): $e');
    }

    WidgetsBinding.instance.addObserver(_LifecycleObserver());

    // Main-isolate copy of the persisted trigger words (background isolate
    // loads its own copy from the same pref key). Timeout-guarded: a prefs
    // stall must never wedge app startup (runApp waits on initialize()).
    try {
      keywords = await getTriggerWords()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      await flog('init', 'getTriggerWords failed (using defaults): $e');
      keywords = List.of(defaultTriggerWords);
    }

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
        initialNotificationContent: 'Listening for trigger word',
        foregroundServiceNotificationId: fgsNotificationId,
        // microphone: KWS listener. location: the BG SOS executor takes the
        // fresh SOS fix + live tracking from this same isolate (background
        // location needs the location FGS type + ACCESS_BACKGROUND_LOCATION).
        foregroundServiceTypes: [
          AndroidForegroundType.microphone,
          AndroidForegroundType.location,
        ],
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
        _lastRunning = event['running'] as bool;
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
    // BG SOS executor snapshots (SosExecutor.sosStateEvent). The dashboard
    // mirrors these so an app opened mid-SOS shows the LIVE countdown.
    _service.on('sos_state').listen((event) {
      if (event == null) return;
      try {
        _sosStateController.add(Map<String, Object?>.from(event as Map));
      } catch (_) {}
    });
    // BG asks the open app to record with the CameraController pipeline
    // (SosExecutor.sosStartAppRecording); the controller reports back via
    // SosExecutor.onAppRecordingDone.
    _service.on('sos_start_app_recording').listen((_) {
      if (!_appRecordingController.isClosed) _appRecordingController.add(null);
    });
  }

  static Future<void> start() async {
    // Main-isolate verdict (reliable — has an Activity). Stash it for the BG
    // isolate, whose own record.hasPermission() is untrustworthy (MIUI
    // returns false there despite the OS grant).
    // Every await here is timeout-guarded: on HyperOS a permission prompt
    // (notably ignoreBatteryOptimizations) or the prefs channel can hang
    // forever, which used to leave the dashboard toggle fake-ON with zero
    // error surfacing. Timeouts turn a silent hang into a loud failure.
    await flog('main', 'start() entry');
    var micGranted = false;
    try {
      final micStatus = await Permission.microphone
          .request()
          .timeout(const Duration(seconds: 10));
      micGranted = micStatus.isGranted;
      await flog('main', 'mic request done granted=$micGranted');
    } catch (e) {
      await flog('main', 'mic request stalled: $e');
      developer.log('mic permission request stalled: $e',
          name: 'VoiceGuard', level: 1000);
    }
    try {
      await Permission.notification
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'notification request done');
    } catch (e) {
      await flog('main', 'notification request stalled: $e');
    }
    try {
      await Permission.ignoreBatteryOptimizations
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'battery-opt request done');
    } catch (e) {
      await flog('main', 'battery-opt request stalled: $e');
    }
    // Background SOS needs a background location fix for the case payload
    // + live tracking. Best-effort: denial only degrades the fix to the
    // last-known/foreground position, never blocks voice protection.
    try {
      final loc = await Permission.locationAlways
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'locationAlways request done granted=${loc.isGranted}');
    } catch (e) {
      await flog('main', 'locationAlways request stalled: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setBool(_micGrantedMainKey, micGranted)
          .timeout(const Duration(seconds: 5));
      await flog('main', 'mic verdict stashed granted=$micGranted');
    } catch (e) {
      await flog('main', 'mic verdict stash failed: $e');
      developer.log('mic verdict stash failed (best-effort): $e',
          name: 'VoiceGuard', level: 1000);
    }
    // startService() on an already-running service is a harmless no-op, so
    // re-init calls never disturb a healthy engine. A failed service is
    // revived by toggle OFF (the 'stop' listener below is registered first
    // thing in _onStart, so it always exists) followed by toggle ON.
    // Stamp the boot attempt so the watchdog can tell "isolate never ran"
    // apart from "isolate died mid-boot" (BG stamps overwrite this).
    await markStage('main-start');
    // startService() itself is NOT optional — it must always run so the
    // watchdog below can verify the engine actually started.
    await flog('main', 'calling startService()');
    await _service.startService().timeout(const Duration(seconds: 15));
    await flog('main', 'startService() returned');

    // Watchdog: the dashboard toggle used to stay fake-ON when the native
    // service never came up. Wait for the engine-up signal (statusEvent
    // running:true, sent after the mic loop is live) instead of just
    // isRunning(): a first run downloads ~13 MB before the engine is up,
    // which takes far longer than any fixed short poll. Distinguishes three
    // outcomes: (1) service never starts — battery/permission kill;
    // (2) service starts then dies — native crash during boot;
    // (3) service alive but engine never ready — download/spotter/mic stall,
    // with the last BG stage marker naming the exact step.
    // Sticky seed + live re-query: ENGINE-UP may have fired before this
    // isolate subscribed (fast cached-model boot beats main to it; or the
    // activity was recreated while BG kept running). Broadcast drops events
    // with zero listeners, so without this the watchdog waits 90 s for an
    // event that already happened, then raises a false STALL. A dead engine
    // simply never replies and the poll loop below reports the true state.
    var engineUp = _lastRunning;
    final statusSub = _statusController.stream.listen((running) {
      _lastRunning = running;
      if (running) engineUp = true;
    });
    VoiceGuardService.serviceInvoke('query_status');
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      final fastFailAt = deadline.subtract(const Duration(seconds: 75));
      var runningSeen = false;
      var polls = 0;
      while (DateTime.now().isBefore(deadline)) {
        if (engineUp) {
          await flog('main', 'watchdog: engineUp signal received, success');
          return;
        }
        var running = false;
        try {
          running =
              await _service.isRunning().timeout(const Duration(seconds: 3));
        } catch (_) {
          // Poll timeout/channel error counts as "not running yet".
        }
        if (running) {
          runningSeen = true;
          if (polls % 10 == 0) {
            await flog('main', 'watchdog: service running, engineUp=$engineUp');
          }
        } else if (runningSeen) {
          await flog('main', 'watchdog: DIED-AFTER-RUNNING stage=${await readStage()}');
          throw StateError(
              'Voice engine died during startup (background service stopped). '
              'Last stage: ${await readStage()}. Try again; if it repeats, '
              'the on-device listener is crashing on this phone.');
        } else if (DateTime.now().isAfter(fastFailAt)) {
          await flog('main', 'watchdog: FAST-FAIL never-started stage=${await readStage()}');
          throw StateError(
              'Voice engine did not start (background service not running after 15 s). '
              'Set battery to Unrestricted for ZELDA, then toggle again.');
        }
        await Future.delayed(const Duration(seconds: 1));
        polls++;
      }
      if (engineUp) {
        await flog('main', 'watchdog: engineUp at deadline, success');
        return;
      }
      await flog('main', 'watchdog: 90s STALL stage=${await readStage()}');
      throw StateError(
          'Voice engine is starting but not ready after 90 s. '
          'Last stage: ${await readStage()}. '
          'Check internet for the one-time ~13 MB model download, then toggle again.');
    } finally {
      await statusSub.cancel();
    }
  }

  static Future<void> stop() async {
    await setEnabledPref(false);
    // Unconditional: invoking a non-running service is harmless, and gating
    // on isRunning() risks skipping a genuine stop. Delivery to a live
    // service may queue behind engine work, but it is never lost.
    try {
      _service.invoke('stop');
    } catch (_) {}
  }

  static Future<bool> isRunning() =>
      _service.isRunning().timeout(const Duration(seconds: 3)).catchError((_) => false);

  /// File-based debug log (voice-debug.log in the app documents dir).
  /// Logcat carries zero Flutter lines on MIUI, and main-side prefs writes
  /// vanish on this phone, so stages are ALSO appended here — readable via
  /// run-as + cat with no app cooperation needed. Best-effort, never throws.
  static Future<void> flog(String tag, String msg) async {
    try {
      final dir = await getApplicationDocumentsDirectory()
          .timeout(const Duration(seconds: 5));
      final f = File('${dir.path}/voice-debug.log');
      await f
          .writeAsString(
            '${DateTime.now().toIso8601String()} [$tag] $msg\n',
            mode: FileMode.append,
            flush: true,
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Best-effort boot-stage marker shared between the main and background
  /// isolates via prefs. The BG engine stamps each startup step; if the
  /// service dies or stalls, the watchdog reads the last stamp so the
  /// failure names the EXACT step instead of a blind "did not start".
  static Future<void> markStage(String stage) async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setString(_stageKey, stage)
          .timeout(const Duration(seconds: 5));
      await prefs
          .setInt(_stageTimeKey, DateTime.now().millisecondsSinceEpoch)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<String> readStage() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final stage = prefs.getString(_stageKey) ?? 'none (isolate never booted)';
      final at = prefs.getInt(_stageTimeKey);
      if (at == null) return stage;
      final age =
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
      return '$stage (${age.inSeconds}s ago)';
    } catch (_) {
      return 'unreadable';
    }
  }

  /// Restart the background service if the user previously enabled voice
  /// protection (used when the OS kills the process/isolate while backgrounded).
  static Future<void> restartIfNeeded() async {
    if (!await wasEnabled()) return;
    if (await isRunning()) return;
    await start();
  }

  /// Post a high-priority notification with full-screen intent so the app is
  /// brought to the foreground when a trigger word is detected while the
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
  await VoiceGuardService.flog('bg', 'isolate booted');

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
  AudioRecorder? recorder;
  StreamSubscription<List<int>>? pcmSub;
  // Live ENGINE-UP state for the main isolate's query_status round-trip
  // (a state the watchdog can ask for, not an event it might have missed).
  var engineRunning = false;

  // Register the stop handler FIRST — before any fallible engine work.
  // If model/mic setup throws, _onStart returns early via catch; a late
  // registration would leave a failed service unstoppable (toggle OFF =
  // no-op, toggle ON = silent no-op on the already-running service).
  service.on('stop').listen((_) async {
    // Unconditional: the ONLY senders of 'stop' are stop() (genuine user
    // off) and setTriggerWords() (restart — start() follows within ~1 s),
    // so every stop is honored. No pref reads (no cross-engine staleness),
    // no gates that can skip a genuine stop.
    // Immediate feedback FIRST: the notification text changes within ~1 s
    // even if the teardown below is slow, and the mic is released FIRST
    // so the green dot drops fast. Then free the native spotter sessions
    // (no memory leaks) and stopSelf().
    note('Turning off…');
    await pcmSub?.cancel();
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {}
    }
    kwsStream?.free();
    spotter?.free();
    service.stopSelf();
  });

  // The main isolate asks for the CURRENT running state on every start():
  // ENGINE-UP is a state, not an event — a broadcast fired before main
  // subscribed is dropped, so main re-queries instead of trusting its luck.
  // No-op when the engine is dead (the watchdog then reports the true state).
  service.on('query_status').listen((_) {
    service.invoke(VoiceGuardService._statusEvent, {'running': engineRunning});
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
  await VoiceGuardService.markStage('isolate-booted');

  // ── BG SOS executor boots FIRST, unconditionally ──
  // Cheap (prefs + timers only): power-button triggers get a live executor
  // even when voice listening is disabled, and the 5s countdown no longer
  // waits for the app to open. The spotter/mic below only starts when voice
  // protection is enabled.
  await SosExecutor.onBoot(service, () => appInForeground);
  await VoiceGuardService.markStage('executor-up');
  await VoiceGuardService.flog('bg', 'executor-up');

  bool voiceOn = true;
  try {
    voiceOn = await VoiceGuardService.wasEnabled()
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    await VoiceGuardService.flog('bg', 'enabled-pref unreadable, attempting mic: $e');
  }
  if (!voiceOn) {
    note('SOS guard standby');
    await VoiceGuardService.markStage('engine-standby');
    await VoiceGuardService.flog('bg', 'STANDBY (voice off, executor only)');
    service.invoke(VoiceGuardService._statusEvent, {'running': false});
    Timer.periodic(const Duration(seconds: 10), (_) {
      service.invoke('heartbeat');
    });
    return;
  }

  // ── Keyword-spotter engine (KWS only, no speech-to-text stage) ──
  // The Zipformer spotter hears trigger WORDS straight from the mic stream,
  // so there is no transcription step: hits fire directly (low latency),
  // the download stays small (~13 MB, cached after first run), and the
  // per-frame cost is a fraction of a full recognizer. Custom words from
  // the dashboard are validated against the bundle's tokens below — a word
  // the bundle cannot tokenize could never fire, so it falls back to the
  // default with a clear error instead of silently never working.
  // Same downstream path as before: dedupe + pending-trigger +
  // full-screen alarm in fireKeyword, so app-off hits still wake the phone.
  try {
    await VoiceGuardService.markStage('engine-start');
    await VoiceGuardService.flog('bg', 'engine-start');
    initBindings();
    await VoiceGuardService.markStage('bindings-ok');
    await VoiceGuardService.flog('bg', 'bindings-ok');
    await VoiceGuardService.markStage('download-start');
    await VoiceGuardService.flog('bg', 'download-start');
    late final KwsModelPaths paths;
    try {
      paths = await KeywordModelManager.ensureBundle(
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
      await VoiceGuardService.flog('bg', 'DOWNLOAD-FAILED: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Voice model unavailable: $e'},
      );
      return;
    }
    debugPrint('VoiceGuard KWS models ready');
    note('Models ready, loading listener…');
    await VoiceGuardService.markStage('models-ready');
    await VoiceGuardService.flog('bg', 'models-ready');

    // Trigger words (persisted custom setup, default "Help me") into the
    // BPE-keyword buffer the native spotter expects: every word uppercased,
    // whitespace-separated parts each prefixed with ▁ (U+2581), one phrase
    // per line. keywordsBufSize MUST be the UTF-8 byte length of the buffer:
    // native treats a size-0 buffer as zero registered keywords and refuses
    // to create the spotter ("Failed to create kws").
    final persisted = await VoiceGuardService.getTriggerWords();
    final tokenSet = await KeywordModelManager.loadTokenSet(paths.tokens);
    final validWords = persisted
        .where((w) => VoiceGuardService._wordSupported(w, tokenSet))
        .toList();
    if (validWords.isEmpty) {
      debugPrint('[VoiceGuard] no supported trigger words, using default');
      service.invoke(
        VoiceGuardService._errorEvent,
        {
          'error':
              'Trigger "${persisted.join(', ')}" is not supported by the on-device listener — using "Help me".'
        },
      );
    }
    final activeWords =
        validWords.isEmpty ? List.of(VoiceGuardService.defaultTriggerWords) : validWords;
    final bufLines = activeWords.map((w) {
      final parts = w.toUpperCase().split(RegExp(r'\s+'));
      return parts.map((p) => '▁$p').join(' ');
    }).toList();
    final keywordsBuf = bufLines.join('\n');
    // KWS result echoes the matched buffer line — map it back to the
    // display-cased word for the SOS dialog ("Heard help me").
    final displayByBufLine = <String, String>{
      for (int i = 0; i < bufLines.length; i++) bufLines[i]: activeWords[i],
    };

    spotter = KeywordSpotter(
      KeywordSpotterConfig(
        model: OnlineModelConfig(
          transducer: OnlineTransducerModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            joiner: paths.joiner,
          ),
          tokens: paths.tokens,
          numThreads: 2,
        ),
        keywordsBuf: keywordsBuf,
        keywordsBufSize: utf8.encode(keywordsBuf).length,
      ),
    );
    kwsStream = spotter.createStream();
    debugPrint('VoiceGuard KWS spotter created for: ${activeWords.join(', ')}');
    await VoiceGuardService.markStage('spotter-created');
    await VoiceGuardService.flog(
        'bg', 'spotter-created words=${activeWords.join('|')}');

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
      // BG executor is authoritative: the 5s cancel window starts HERE, in
      // this isolate, whether the app is open or not.
      unawaited(SosExecutor.onTrigger('voice:$keyword'));
      service.invoke(VoiceGuardService._detectionEvent, {'keyword': keyword});
      if (!appInForeground) {
        await VoiceGuardService._markPendingTrigger();
        // Single native full-screen alarm (SosAlarmActivity over home/lock
        // screen), posted by the persistent PowerGuardService poller — the
        // old Dart FSI notification is replaced by it (no duplicates).
        await SosExecutor.requestNativeAlarm();
      }
    }

    final mic = AudioRecorder();
    recorder = mic;

    Future<void> stopMicLoop() async {
      try {
        await pcmSub?.cancel();
      } catch (_) {}
      pcmSub = null;
      if (recorder != null) {
        try {
          await recorder.stop();
        } catch (_) {}
      }
      await VoiceGuardService.flog('bg', 'mic loop paused by executor');
    }

    // (Re)starts the mic stream + KWS chunk loop. Idempotent: a live loop
    // is left alone. Returns false when the mic genuinely cannot start.
    Future<bool> startMicLoop() async {
    // Attempt-first mic open: the MAIN-isolate verdict stash lives in
    // FlutterSharedPreferences, which is ABSENT on this ROM (writes vanish),
    // and record.hasPermission() inside this BG isolate lies on MIUI (false
    // despite the OS grant). So just TRY startStream — a real denial throws
    // here and maps to the same permission-denied error below. The stash is
    // only logged for diagnostics.
    final bgPrefs = await SharedPreferences.getInstance();
    final mainSideGranted =
        bgPrefs.getBool(VoiceGuardService._micGrantedMainKey) ?? false;
    await VoiceGuardService.flog(
        'bg', 'mic-gate stash=$mainSideGranted, trying startStream');
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
      await VoiceGuardService.flog('bg', 'MIC-STREAM-FAILED: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Microphone permission denied'},
      );
      return false;
    }

    // IMPORTANT: keep the per-chunk path light. The full-screen alarm +
    // pending-trigger write happen in fireKeyword without stalling the mic
    // loop (fired unawaited). The spot is reset on every hit so the SAME
    // utterance cannot re-fire on consecutive frames.
    pcmSub = pcm.listen((List<int> c) {
      final Uint8List chunk = c is Uint8List ? c : Uint8List.fromList(c);
      final int n = chunk.length ~/ 2;
      final Float32List samples = Float32List(n);
      for (int i = 0; i < n; i++) {
        int v = chunk[2 * i] | (chunk[2 * i + 1] << 8);
        if (v >= 32768) v -= 65536;
        samples[i] = v / 32768.0;
      }
      final spot = spotter;
      final stream = kwsStream;
      if (spot == null || stream == null) return;
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      while (spot.isReady(stream)) {
        spot.decode(stream);
      }
      final hit = spot.getResult(stream).keyword;
      if (hit.isEmpty) return;
      spot.reset(stream);
      final display = displayByBufLine[hit] ?? activeWords.first;
      debugPrint('[VoiceGuard] trigger word heard: $display');
      unawaited(fireKeyword(display));
    }, onError: (Object e) {
      debugPrint('[VoiceGuard] mic stream error: $e');
    });
      await VoiceGuardService.flog('bg', 'mic loop (re)started');
      return true;
    }

    SosExecutor.bindMicHooks(onPause: stopMicLoop, onResume: startMicLoop);
    if (!await startMicLoop()) return;

    debugPrint('VoiceGuard KWS engine started, listening');
    note('Listening for "${activeWords.first.toLowerCase()}"');
    await VoiceGuardService.markStage('engine-up');
    await VoiceGuardService.flog('bg', 'ENGINE-UP listening');
    engineRunning = true;
    service.invoke(VoiceGuardService._statusEvent, {'running': true});
  } catch (e, s) {
    await VoiceGuardService.flog('bg', 'BG-CATCH: $e');
    developer.log(
      'BG service failed: $e\n$s',
      name: 'VoiceGuard',
      level: 1000,
    );
    debugPrint('VoiceGuard BG service failed: $e\n$s');
    note('Voice guard error — open app for details');
    service.invoke(VoiceGuardService._errorEvent, {'error': '$e'});
    engineRunning = false;
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
