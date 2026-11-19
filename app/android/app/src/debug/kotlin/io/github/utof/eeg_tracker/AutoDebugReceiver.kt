package io.github.utof.eeg_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Debug builds only (src/debug): a faked "headband came near" for the emulator smoke test, which has no BrainBit.
 * `adb shell am broadcast -n io.github.utof.eeg_tracker/.AutoDebugReceiver -a io.github.utof.eeg_tracker.auto.DEBUG_PRESENCE
 * --es fake worn` (or `off`): the check then uses a simulated headband (lib/auto/task.dart, SimulatedCheck).
 */
class AutoDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "io.github.utof.eeg_tracker.auto.DEBUG_PRESENCE") return
        AutoWatch.onPresence(context, true, intent.getStringExtra("fake") ?: "worn")
    }
}
