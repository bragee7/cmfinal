package com.zelda.zelda_guardian

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Full-screen SOS cancel UI shown over the home screen and lock screen.
 * Reference: Android Emergency SOS style — title, live 5..1 countdown in a
 * coral ring, swipe-to-cancel pill at the bottom. The SOS is ALREADY
 * triggered: there is no "start" action, only cancel.
 *
 * State is owned by whoever runs the SOS (Dart SosExecutor when alive, else
 * the native coordinator in PowerGuardService), mirrored in
 * FlutterSharedPreferences. This activity only DISPLAYS the mirror and
 * writes a cancel command — cancelling works without opening ZELDA.
 */
class SosAlarmActivity : Activity() {

    companion object {
        private const val TAG = "SosAlarm"
        private const val PREFS = "FlutterSharedPreferences"
        private const val STATE = "flutter.zelda_sos_state"
        private const val REMAINING = "flutter.zelda_sos_remaining"
        private const val COMMAND = "flutter.zelda_sos_command"

        @Volatile
        var isShowing = false
            private set

        private fun dp(c: Context, v: Int): Int =
            TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), c.resources.displayMetrics
            ).toInt()
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var countText: TextView
    private lateinit var subtitleText: TextView
    private val ui = Handler(Looper.getMainLooper())
    private var finished = false
    // Sticky display (flicker fix): last time an ACTIVE sos state was seen,
    // and the last countdown number shown. This screen only closes on user
    // cancel or when the SOS has been over (inactive state) for the full
    // grace window — transient prefs gaps must never unmount it.
    private var lastActiveTs = System.currentTimeMillis()
    private var lastCount = "5"
    // One-shot guard: the window-over branch must finish exactly once.
    // Without this the 250 ms refresher can call finish() again after a
    // config change / slow destroy — each extra finish() is one more
    // `f}}}` record in the task (the duplicate `auto-dismissing` logs).
    // Display only — SOS state untouched.
    private var windowOver = false

    /** Inactive states tolerated this long before closing. */
    private val INACTIVE_GRACE_MS = 8000L

    private val refresher = object : Runnable {
        override fun run() {
            if (finished) return
            refresh()
            ui.postDelayed(this, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        isShowing = true
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Show over the lock screen and turn the screen on.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // System-SOS style handoff: when the keyguard is a non-secure
        // (swipe/none) lock, dismiss it behind this screen so the lock
        // hands off to the cancel UI. On secure locks the system keeps
        // the credential gate — never bypassed. Display only.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val km = getSystemService(KeyguardManager::class.java)
                if (km != null && km.isKeyguardLocked) {
                    km.requestDismissKeyguard(this, null)
                }
            }
        } catch (_: Exception) {}

        setContentView(buildUi())
        ui.post(refresher)
    }

    override fun onResume() {
        super.onResume()
        // Re-request the keyguard handoff: if onCreate ran while the screen
        // was off or the activity was still behind the keyguard, the first
        // request may not have taken effect. Same call, display only.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val km = getSystemService(KeyguardManager::class.java)
                if (km != null && km.isKeyguardLocked) {
                    km.requestDismissKeyguard(this, null)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        finished = true
        ui.removeCallbacks(refresher)
        isShowing = false
        super.onDestroy()
    }

    // ── UI (built programmatically to keep the screen in one file) ──

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            val p = dp(this@SosAlarmActivity, 24)
            setPadding(p, dp(this@SosAlarmActivity, 48), p, dp(this@SosAlarmActivity, 32))
        }

        // Title row: "Zelda Emergency SOS" + decorative gear.
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val title = TextView(this).apply {
            text = "Zelda Emergency SOS"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val gear = TextView(this).apply {
            text = "\u2699"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
        }
        titleRow.addView(title)
        titleRow.addView(gear)
        root.addView(titleRow)

        val will = TextView(this).apply {
            text = "Your phone will:"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
            setPadding(0, dp(this@SosAlarmActivity, 16), 0, 0)
        }
        root.addView(will)

        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(this@SosAlarmActivity, 12), 0, 0)
        }
        val check = TextView(this).apply {
            text = "\u2713   "
            setTextColor(Color.parseColor("#34A853"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val action = TextView(this).apply {
            text = "Send SOS + record evidence"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f)
        }
        actionRow.addView(check)
        actionRow.addView(action)
        root.addView(actionRow)

        // Center: coral ring with the live countdown number.
        val center = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
            ).apply { gravity = Gravity.CENTER }
        }
        val ringSize = dp(this@SosAlarmActivity, 260)
        val ringBg = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.TRANSPARENT)
            setStroke(dp(this@SosAlarmActivity, 9), Color.parseColor("#F0716A"))
        }
        val ring = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(ringSize, ringSize, Gravity.CENTER)
            background = ringBg
        }
        countText = TextView(this).apply {
            text = "5"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 96f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        }
        ring.addView(countText)
        center.addView(ring)
        root.addView(center)

        subtitleText = TextView(this).apply {
            text = "SOS sends automatically — swipe to cancel"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(this@SosAlarmActivity, 20))
        }
        root.addView(subtitleText)

        // Bottom: swipe-to-cancel pill (thumb slides right; release past
        // 55% cancels). Tapping "Cancel" also cancels (accessibility).
        root.addView(buildCancelPill())
        return root
    }

    private fun buildCancelPill(): View {
        val h = dp(this@SosAlarmActivity, 76)
        val pillBg = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = h / 2f
            setColor(Color.parseColor("#2A2A2A"))
        }
        val pill = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, h
            )
            background = pillBg
        }
        val thumbSize = dp(this@SosAlarmActivity, 60)
        val thumbBg = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor("#DADCE0"))
        }
        val thumb = TextView(this).apply {
            text = "\u2715"
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#7A1F1A"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = thumbBg
            layoutParams = FrameLayout.LayoutParams(thumbSize, thumbSize).apply {
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                leftMargin = dp(this@SosAlarmActivity, 8)
            }
        }
        val label = TextView(this).apply {
            text = "Cancel"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f)
            gravity = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            // Must NOT be clickable: a clickable full-pill child consumes
            // DOWN before the pill's touch listener runs, which is exactly
            // what broke swipe-to-cancel (swipes starting on the label never
            // moved the thumb; only the tap path survived via click). All
            // touch is owned by the pill listener below — a plain tap
            // anywhere on the pill cancels there too.
            isClickable = false
            isFocusable = false
        }
        pill.addView(label)
        pill.addView(thumb)

        // The pill itself is the accessible click target (TalkBack
        // double-tap → performClick → cancel, independent of touch routing).
        pill.isClickable = true
        pill.contentDescription = "Cancel SOS. Activate to cancel the SOS."
        pill.setOnClickListener { cancelSos() }

        val slop = ViewConfiguration.get(this).scaledTouchSlop
        var downX = 0f
        var dragging = false
        var moved = false
        pill.setOnTouchListener { v, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.x
                    dragging = true
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (dragging) {
                        val max = (v.width - thumbSize - dp(this@SosAlarmActivity, 16)).coerceAtLeast(1)
                        val dx = (ev.x - downX).coerceIn(0f, max.toFloat())
                        if (dx > slop) {
                            moved = true
                            thumb.translationX = dx
                            if (dx >= max * 0.55f) {
                                dragging = false
                                cancelSos()
                            }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        dragging = false
                        if (!moved) {
                            // Plain tap anywhere on the pill cancels.
                            cancelSos()
                        } else {
                            thumb.animate().translationX(0f).setDuration(150).start()
                        }
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    thumb.animate().translationX(0f).setDuration(150).start()
                    true
                }
                else -> true
            }
        }
        return pill
    }

    // ── state sync ──

    private fun refresh() {
        val state = try {
            prefs.getString(STATE, "idle") ?: "idle"
        } catch (_: Exception) { "idle" }
        // remaining is written as Long by Flutter's SharedPreferences plugin
        // (Dart setInt → putLong) but as Int by the native drive flow
        // (putInt). getInt throws ClassCastException on a Long entry, which
        // used to freeze the digit at its initial "5" — read type-tolerantly.
        val remaining = try {
            when (val v = prefs.all[REMAINING]) {
                is Number -> v.toInt()
                is String -> v.toString().toIntOrNull() ?: 0
                else -> 0
            }
        } catch (_: Exception) { 0 }

        when (state) {
            "cancelWindow", "countdown" -> {
                lastActiveTs = System.currentTimeMillis()
                if (remaining >= 1) {
                    lastCount = remaining.toString()
                    countText.text = lastCount
                } else {
                    // Transient gap between tick writes — keep last number.
                    countText.text = lastCount
                }
                subtitleText.text = "SOS sends automatically — swipe to cancel"
            }
            "recording", "sending", "sent" -> {
                // Cancel window is over — the SOS (recording/upload) continues on
                // its own in the service/executor. This Activity is only the
                // cancel-window display, so dismiss WITHOUT writing any cancel
                // command and WITHOUT stopping anything. One-shot: the 250 ms
                // refresher must not re-finish after a config change / slow
                // destroy (each extra finish() is a duplicate task record).
                if (!windowOver) {
                    windowOver = true
                    isShowing = false
                    finish()
                }
            }
            else -> {
                // Idle/listening/transient: close only once the SOS is
                // genuinely over (inactive for the full grace window).
                // Finishing on any gap caused the flicker loop
                // (finish → dashboard revealed → guarded relaunch).
                if (System.currentTimeMillis() - lastActiveTs > INACTIVE_GRACE_MS) {
                    finish()
                }
            }
        }
    }

    private fun cancelSos() {
        if (finished) return
        try {
            prefs.edit().putString(COMMAND, "cancel").apply()
        } catch (_: Exception) {}
        finish()
    }
}
