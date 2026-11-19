package io.github.utof.eeg_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * The smart alarm's broadcasts (DECISIONS 234): the alarm clock going off (the window's end, an early ring brought
 * forward by the live model, or the re-ring of a killed ringer), "I'm awake" from the notification, and a reboot
 * or app update, after which the alarm is set again.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        when (i.action) {
            WakeAlarm.ACTION_RING -> {
                val by = i.getStringExtra("by") ?: WakeAlarm.BY_END
                try {
                    WakeService.ring(c, by) // an exact alarm may start a foreground service from the background
                } catch (e: Exception) {
                    Log.w("EegWake", "ringer refused ($e); the fallback notification")
                    WakeAlarm.fallbackNotify(c, WakeService.reasonText(c))
                }
            }
            WakeAlarm.ACTION_AWAKE -> WakeAlarm.awake(c)
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> WakeAlarm.restore(c)
        }
    }
}
