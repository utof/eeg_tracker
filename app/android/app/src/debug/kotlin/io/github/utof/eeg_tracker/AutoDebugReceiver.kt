package io.github.utof.eeg_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Debug builds only (src/debug): a faked "headband came near" for the emulator smoke test, which has no BrainBit.
 * `adb shell am broadcast -n io.github.utof.eeg_tracker/.AutoDebugReceiver -a io.github.utof.eeg_tracker.auto.DEBUG_PRESENCE
 * --es fake worn` (or `off`; `--ez force true` for a forced check): the check then uses a simulated headband
 * (lib/auto/task.dart, SimulatedCheck).
 */
class AutoDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "io.github.utof.eeg_tracker.auto.DEBUG_PRESENCE") return
        val fake = intent.getStringExtra("fake") ?: "worn"
        // `--ez force true`: a forced check ("Check now"), past the quiet time a "Not now" set
        if (intent.getBooleanExtra("force", false)) AutoWatch.requestCheck(context, "now", force = true, fake = fake)
        else AutoWatch.onPresence(context, true, fake)
    }
}
