package io.github.utof.linkprobe.reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** The reader run in the background: routes 1 and 2 only (a screen cannot be opened from here). `am broadcast -n .../TriggerReceiver`. */
class TriggerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val meta = Meta(intent.getStringExtra("run") ?: "bg", intent.getStringExtra("state") ?: "?", "bg")
        val routes = (intent.getStringExtra("routes") ?: "provider,service").split(",").filter { it.isNotBlank() }
        val pending = goAsync()
        val app = context.applicationContext
        Thread {
            try { Probe.runAll(app, null, routes, meta) {} } finally { pending.finish() }
        }.start()
    }
}
