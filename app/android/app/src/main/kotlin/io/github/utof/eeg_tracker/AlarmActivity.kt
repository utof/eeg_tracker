package io.github.utof.eeg_tracker

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/**
 * The wake-up over the lock screen (DECISIONS 235): opened by the ringer's full-screen notification. Plain Android,
 * no Flutter engine to start, and only this one action over the lock screen: a screen-wide "I'm awake" that stops
 * the sound (the night keeps recording until Stop in the app). Night-watch colours from DESIGN.md: the warm black
 * ground, parchment ink, the deep green of the Start button.
 */
class AlarmActivity : Activity() {
    companion object {
        @Volatile
        private var current: WeakReference<AlarmActivity>? = null

        fun closeAll() {
            Handler(Looper.getMainLooper()).post { current?.get()?.finish() }
        }
    }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        current = WeakReference(this)

        val ink = Color.parseColor("#DCCDB6")
        val muted = Color.parseColor("#A99A84")
        val pad = dp(24f).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#100D0B"))
            setPadding(pad, dp(32f).toInt(), pad, pad)
        }
        val title = TextView(this).apply {
            text = "Time to wake up"
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 36f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        val reason = TextView(this).apply {
            text = WakeService.reasonText(this@AlarmActivity)
            setTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setLineSpacing(0f, 1.4f)
            setPadding(0, dp(10f).toInt(), 0, 0)
        }
        val still = TextView(this).apply {
            text = "The night is still recording. Stop it in the app when you get up."
            setTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setLineSpacing(0f, 1.4f)
            setPadding(0, dp(6f).toInt(), 0, dp(28f).toInt())
        }
        val awake = Button(this).apply {
            text = "I'm awake"
            isAllCaps = false
            setTextColor(Color.parseColor("#E8F3EC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#2E6B4B"))
                cornerRadius = dp(16f)
            }
            stateListAnimator = null
            setOnClickListener {
                WakeAlarm.awake(this@AlarmActivity)
                finish()
            }
        }
        root.addView(title)
        root.addView(reason)
        root.addView(still)
        // one target almost as big as the screen, as the nap coach's wake face
        root.addView(awake, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        // nothing ringing any more ("I'm awake" from the notification, Alarm off): nothing to show
        if (!WakeService.ringing) finish()
    }

    override fun onDestroy() {
        if (current?.get() === this) current = null
        super.onDestroy()
    }
}
