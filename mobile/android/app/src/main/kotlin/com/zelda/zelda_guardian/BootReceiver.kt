package com.zelda.zelda_guardian

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Restart the power-button guard after reboot / update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == Intent.ACTION_PACKAGE_REPLACED
        ) {
            // Only restart if the user left power-SOS enabled (default on).
            if (!PowerPressReceiver.isEnabled(context)) return
            try {
                Log.i("BootReceiver", "restarting PowerGuardService after $action")
                PowerGuardService.start(context)
            } catch (e: Exception) {
                Log.w("BootReceiver", "start failed: ${e.message}")
            }
        }
    }
}
