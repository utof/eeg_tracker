package io.github.utof.eeg_tracker

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Pairing with a laptop by one scan (DECISIONS rows 530-539): the laptop's QR code page opens
 * `eegtracker://pair?h=...&p=...&s=...&n=...`. This activity has no window. It keeps the link for the Flutter side
 * and brings the app's own task to the front exactly as the launcher icon does, so a link never starts a second copy
 * of the app beside a running night. The Dart side asks before anything is sent (lib/ui/pair_dialog.dart).
 */
class PairLinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PairLinks.offer(intent)
        try {
            packageManager.getLaunchIntentForPackage(packageName)?.let { startActivity(it) }
        } catch (_: Exception) {
            // nothing to bring forward: the link waits until the app is opened
        }
        finish()
    }
}

/** The pair link waiting for the Dart side ("eeg_tracker/link": "take"); [onArrived] tells a running app. */
object PairLinks {
    @Volatile
    private var pending: String? = null

    /** Set by MainActivity while its Flutter engine runs. */
    var onArrived: (() -> Unit)? = null

    fun offer(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val data = intent.data ?: return
        if (data.scheme != "eegtracker" || data.host != "pair") return
        val text = data.toString()
        if (text.length > 512) return
        pending = text
        onArrived?.invoke()
    }

    /** The link, once. */
    fun take(): String? {
        val text = pending
        pending = null
        return text
    }
}
