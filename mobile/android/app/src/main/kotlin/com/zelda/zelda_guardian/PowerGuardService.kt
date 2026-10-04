package com.zelda.zelda_guardian

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Lightweight always-on foreground service that owns the SCREEN_ON/OFF
 * receiver. This is what keeps 4x-power-press working when the app is
 * swiped away / fully killed: the service is START_STICKY with
 * stopWithTask=false so the OS restarts it.
 */
class PowerGuardService : Service() {

    companion object {
        private const val TAG = "PowerGuard"
        private const val CHANNEL_ID = "zelda_power_guard"
        private const val NOTIF_ID = 258
        const val ACTION_TRIGGER = "com.zelda.zelda_guardian.POWER_SOS_TRIGGER"
        private const val ALARM_NOTIF_ID = 259

        fun start(context: Context) {
            val intent = Intent(context, PowerGuardService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "start failed: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, PowerGuardService::class.java))
            } catch (_: Exception) {}
        }
    }

    private var receiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        registerPowerReceiver()
        startCoordinator()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        if (intent?.action == ACTION_TRIGGER ||
            intent?.action == PowerPressReceiver.toString()) {
            postAlarmNotification()
        }
        // When the trigger intent arrives via startForegroundService(trigger),
        // its action is ACTION_TRIGGER — post the loud alarm too.
        if (intent?.action == "com.zelda.zelda_guardian.POWER_SOS_TRIGGER") {
            postAlarmNotification()
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away: restart so the guard keeps running while killed.
        val restart = Intent(applicationContext, PowerGuardService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restart)
            } else {
                startService(restart)
            }
        } catch (e: Exception) {
            Log.w(TAG, "restart failed: ${e.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopCoordinator()
        try {
            receiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {}
        receiver = null
        super.onDestroy()
    }

    private fun registerPowerReceiver() {
        if (receiver != null) return
        receiver = PowerPressReceiver()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        try {
            // API 33+ throws SecurityException without an explicit exported
            // flag. System broadcasts must use NOT_EXPORTED.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
            Log.i(TAG, "power receiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "register failed: ${e.message}")
            receiver = null
        }
    }

    // ── native SOS coordinator ──────────────────────────────
    // Owns the emergency flow ONLY when no Dart executor is alive (every
    // Flutter isolate dead). When Dart is alive it already claimed the SOS
    // in prefs — here we only surface the SosAlarmActivity display.
    // Prefs contract (FlutterSharedPreferences, flutter.-prefixed):
    //   state/remaining/source/started_at/command/case/video/audio/audioOnly,
    //   native_command (stop/start_recording), native_done, alarm_request/handled.
    private var coordThread: HandlerThread? = null
    private var coordHandler: Handler? = null

    // Native-owned flow runtime.
    private var nativeActive = false
    private var nativePhase = ""
    private var nativeRemaining = 0
    private var lastTickMs = 0L
    private var pendingAlarmTs = 0L
    private var dartRecordingStarted = false

    private fun sosPrefs() =
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    private fun startCoordinator() {
        if (coordThread != null) return
        coordThread = HandlerThread("sos-coordinator").apply { start() }
        coordHandler = Handler(coordThread!!.looper)
        coordHandler?.post(coordinatorTick)
        Log.i(TAG, "SOS coordinator started")
    }

    private fun stopCoordinator() {
        coordHandler?.removeCallbacks(coordinatorTick)
        coordHandler = null
        coordThread?.quitSafely()
        coordThread = null
        nativeActive = false
    }

    private val coordinatorTick = object : Runnable {
        override fun run() {
            try {
                tickOnce()
            } catch (e: Exception) {
                Log.w(TAG, "coordinator tick failed: ${e.message}")
            }
            coordHandler?.postDelayed(this, 500)
        }
    }

    private fun tickOnce() {
        val prefs = sosPrefs()
        val now = System.currentTimeMillis()

        // 1. New alarm request (voice keyword or power 3x while Dart dead).
        val alarmTs = try {
            prefs.getLong("flutter.zelda_sos_alarm_request", 0)
        } catch (_: Exception) { 0 }
        val handled = try {
            prefs.getLong("flutter.zelda_sos_alarm_handled", 0)
        } catch (_: Exception) { 0 }
        if (alarmTs > 0 && alarmTs != handled && now - alarmTs < 60000) {
            try {
                prefs.edit().putLong("flutter.zelda_sos_alarm_handled", alarmTs).apply()
            } catch (_: Exception) {}
            pendingAlarmTs = alarmTs
            if (!isAppForeground()) launchAlarmUi()
        }

        val state = try {
            prefs.getString("flutter.zelda_sos_state", "") ?: ""
        } catch (_: Exception) { "" }
        val startedAt = try {
            prefs.getLong("flutter.zelda_sos_started_at", 0)
        } catch (_: Exception) { 0 }
        val dartOwns = state in setOf("cancelWindow", "countdown", "recording", "sending") &&
            now - startedAt < 180000

        // 2. Dart-owned flow asking for native recording (app-recording no-show).
        if (!nativeActive) {
            val cmd = try {
                prefs.getString("flutter.zelda_sos_native_command", "") ?: ""
            } catch (_: Exception) { "" }
            if (cmd == "start_recording" && !dartRecordingStarted) {
                dartRecordingStarted = true
                SosRecordingService.start(this, 30)
            }
            if (cmd != "start_recording") dartRecordingStarted = false
        }

        // 3. Display: active flow but alarm UI not up and app not open.
        if (dartOwns && !nativeActive) {
            pendingAlarmTs = 0L // Dart owns this SOS; alarm consumed.
            if (!SosAlarmActivity.isShowing && !isAppForeground()) launchAlarmUi()
            return
        }

        // 4. Claim a native-owned flow after the grace window (Dart never came).
        if (!nativeActive && !dartOwns) {
            if (pendingAlarmTs > 0 && now - pendingAlarmTs > 3000 &&
                now - pendingAlarmTs < 60000 && !isAppForeground()
            ) {
                claimNativeFlow(prefs)
                // Claimed (or Dart took it meanwhile) — never re-claim.
                pendingAlarmTs = 0L
            }
            return
        }

        // 5. Drive the native-owned flow.
        if (nativeActive) driveNativeFlow(prefs, now)
    }

    private fun isAppForeground(): Boolean {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val procs = am.runningAppProcesses ?: return false
            procs.any { it.processName == packageName &&
                it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND }
        } catch (_: Exception) { false }
    }

    private fun launchAlarmUi() {
        // Full-screen intent: the one mechanism allowed to appear over the
        // home/lock screen from the background.
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel("zelda_voice_protection") == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    "zelda_voice_protection",
                    "ZELDA Voice Protection",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val alarm = Intent(this, SosAlarmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 2, alarm,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(this, "zelda_voice_protection")
            .setContentTitle("\uD83D\uDEA8 ZELDA SOS TRIGGERED")
            .setContentText("Swipe to cancel — recording starts automatically…")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(ALARM_NOTIF_ID, notif)
        } catch (e: Exception) {
            Log.w(TAG, "alarm FSI failed: ${e.message}")
            // Last resort: direct launch attempt (usually blocked, best effort).
            try {
                startActivity(alarm)
            } catch (_: Exception) {}
        }
    }

    private fun claimNativeFlow(prefs: android.content.SharedPreferences) {
        // Re-check under the same rules (avoid double-claim with Dart).
        val now = System.currentTimeMillis()
        val state = try {
            prefs.getString("flutter.zelda_sos_state", "") ?: ""
        } catch (_: Exception) { "" }
        val startedAt = try {
            prefs.getLong("flutter.zelda_sos_started_at", 0)
        } catch (_: Exception) { 0 }
        if (state in setOf("cancelWindow", "countdown", "recording", "sending") &&
            now - startedAt < 180000
        ) {
            return // Dart claimed it after all.
        }
        val source = try {
            prefs.getString("flutter.zelda_sos_source", "") ?: ""
        } catch (_: Exception) { "" }
        nativeActive = true
        nativePhase = "cancelWindow"
        nativeRemaining = 5
        lastTickMs = now
        try {
            prefs.edit()
                .putString("flutter.zelda_sos_state", nativePhase)
                .putInt("flutter.zelda_sos_remaining", nativeRemaining)
                .putString("flutter.zelda_sos_source",
                    source.ifEmpty { "power-button" })
                .putLong("flutter.zelda_sos_started_at", now)
                .putString("flutter.zelda_sos_command", "")
                .remove("flutter.zelda_sos_case_id")
                .remove("flutter.zelda_sos_video_path")
                .remove("flutter.zelda_sos_audio_path")
                .putBoolean("flutter.zelda_sos_audio_only", false)
                .remove("flutter.zelda_sos_native_done")
                .apply()
        } catch (_: Exception) {}
        Log.i(TAG, "native SOS flow claimed (Dart dead)")
        if (!SosAlarmActivity.isShowing && !isAppForeground()) launchAlarmUi()
    }

    private fun driveNativeFlow(prefs: android.content.SharedPreferences, now: Long) {
        // Cancel lands via prefs (alarm activity or a later Dart boot).
        val cmd = try {
            prefs.getString("flutter.zelda_sos_command", "") ?: ""
        } catch (_: Exception) { "" }
        if (cmd.trim() == "cancel") {
            cancelNativeFlow(prefs, "alarm-activity cancel")
            return
        }
        // A live Dart executor re-claiming mid-flow: stand down, it owns send.
        val state = try {
            prefs.getString("flutter.zelda_sos_state", "") ?: ""
        } catch (_: Exception) { "" }
        if (state == "sending" || state == "sent") {
            nativeActive = false // Dart took over the tail; display follows mirror.
            return
        }
        if (state == "listening" || state == "idle") {
            nativeActive = false // Cancelled/completed elsewhere.
            return
        }

        if (nativePhase == "recording") {
            // Recording service reports via native_done; keep watching cancel.
            val done = try {
                prefs.contains("flutter.zelda_sos_native_done")
            } catch (_: Exception) { false }
            if (done) {
                // Evidence secured. Send/upload needs the auth token, which
                // only Dart can read — park here; the Dart executor (BG or
                // app-open pickup) completes the chain from these prefs.
                Log.i(TAG, "native recording done — awaiting Dart send")
                nativeActive = false
            }
            return
        }

        if (now - lastTickMs < 1000) return
        lastTickMs = now
        nativeRemaining -= 1
        if (nativeRemaining > 0) {
            try {
                prefs.edit()
                    .putInt("flutter.zelda_sos_remaining", nativeRemaining)
                    .putLong("flutter.zelda_sos_started_at", now)
                    .apply()
            } catch (_: Exception) {}
            return
        }
        if (nativePhase == "cancelWindow") {
            nativePhase = "countdown"
            nativeRemaining = 3
            try {
                prefs.edit()
                    .putString("flutter.zelda_sos_state", nativePhase)
                    .putInt("flutter.zelda_sos_remaining", nativeRemaining)
                    .apply()
            } catch (_: Exception) {}
            return
        }
        // Countdown elapsed → record natively (CameraX, audio fallback).
        nativePhase = "recording"
        try {
            prefs.edit()
                .putString("flutter.zelda_sos_state", "recording")
                .putInt("flutter.zelda_sos_remaining", 30)
                .apply()
        } catch (_: Exception) {}
        SosRecordingService.start(this, 30)
    }

    private fun cancelNativeFlow(prefs: android.content.SharedPreferences, reason: String) {
        nativeActive = false
        try {
            prefs.edit()
                .putString("flutter.zelda_sos_state", "listening")
                .putInt("flutter.zelda_sos_remaining", 0)
                .putString("flutter.zelda_sos_command", "")
                .putString("flutter.zelda_sos_native_command", "stop")
                .apply()
        } catch (_: Exception) {}
        SosRecordingService.stop(this)
        Log.i(TAG, "native SOS CANCELLED ($reason)")
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "ZELDA Power-button Guard",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps 3x power-press SOS active even when the app is closed"
                }
            )
        }
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ZELDA SOS guard active")
            .setContentText("Press power 3x in 6s to send SOS")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentIntent(launch)
            .setOngoing(true)
            .build()
    }

    private fun postAlarmNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel("zelda_voice_protection") == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    "zelda_voice_protection",
                    "ZELDA Voice Protection",
                    NotificationManager.IMPORTANCE_HIGH,
                )
            )
        }
        val launch = Intent(this, SosAlarmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 1, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(this, "zelda_voice_protection")
            .setContentTitle("\uD83D\uDEA8 ZELDA SOS TRIGGERED")
            .setContentText("Power pressed 3x. Opening app to send SOS...")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(ALARM_NOTIF_ID, notif)
        } catch (e: Exception) {
            Log.w(TAG, "alarm notify failed: ${e.message}")
        }
    }
}
