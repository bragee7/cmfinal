package com.zelda.zelda_guardian

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "zelda/power_sos"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
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
                    else -> result.notImplemented()
                }
            }
    }
}
