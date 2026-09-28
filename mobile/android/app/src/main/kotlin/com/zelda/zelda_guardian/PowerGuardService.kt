package com.zelda.zelda_guardian

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
            registerReceiver(receiver, filter)
            Log.i(TAG, "power receiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "register failed: ${e.message}")
            receiver = null
        }
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
                    description = "Keeps 4x power-press SOS active even when the app is closed"
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
            .setContentText("Press power 4x in 6s to send SOS")
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
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("zelda_power_sos", true)
        }
        val pi = launch?.let {
            PendingIntent.getActivity(
                this, 1, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notif = NotificationCompat.Builder(this, "zelda_voice_protection")
            .setContentTitle("\uD83D\uDEA8 ZELDA SOS TRIGGERED")
            .setContentText("Power pressed 4x. Opening app to send SOS...")
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
