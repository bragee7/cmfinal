package com.zelda.zelda_guardian

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "zelda/power_sos"
        private const val EXTRA_POWER_SOS = "zelda_power_sos"
    }

    private var channel: MethodChannel? = null

    // Set when a trigger intent arrives before Dart registered its handler;
    // flushed when Dart calls "notifyReady".
    private var pendingPush = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startGuard" -> {
                        try {
                            PowerGuardService.start(this)
                            PowerPressReceiver.setEnabled(this, true)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                    "stopGuard" -> {
                        PowerPressReceiver.setEnabled(this, false)
                        PowerGuardService.stop(this)
                        result.success(true)
                    }
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        PowerPressReceiver.setEnabled(this, enabled)
                        if (enabled) PowerGuardService.start(this)
                        else PowerGuardService.stop(this)
                        result.success(enabled)
                    }
                    "isEnabled" -> result.success(PowerPressReceiver.isEnabled(this))
                    "notifyReady" -> {
                        if (pendingPush) {
                            pendingPush = false
                            pushTrigger()
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Cold start launched by the receiver carries the trigger extra.
        checkPowerSosIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Warm path: app already alive, receiver fires trigger while running.
        checkPowerSosIntent(intent)
    }

    private fun checkPowerSosIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_POWER_SOS, false) == true) {
            intent.removeExtra(EXTRA_POWER_SOS)
            pushTrigger()
        }
    }

    private fun pushTrigger() {
        try {
            channel?.invokeMethod("onPowerSosTrigger", null)
        } catch (e: Exception) {
            // Dart handler not registered yet — retry on notifyReady.
            pendingPush = true
        }
    }
}
