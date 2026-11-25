package io.github.utof.linkprobe.source

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** The source's one screen: its process id, the counters, and a switch for the foreground service. `--ez fgs true` starts it. */
class MainActivity : Activity() {
    private lateinit var info: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        info = TextView(this).apply { typeface = Typeface.MONOSPACE; textSize = 14f }
        val start = Button(this).apply {
            text = "Start the foreground service"
            setOnClickListener { startForegroundService(Intent(this@MainActivity, KeepAliveService::class.java)); refresh() }
        }
        val stop = Button(this).apply {
            text = "Stop the foreground service"
            setOnClickListener { stopService(Intent(this@MainActivity, KeepAliveService::class.java)); refresh() }
        }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 48, 32, 32)
            addView(info, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(start)
            addView(stop)
        }
        setContentView(col)
        if (intent.getBooleanExtra("fgs", false)) startForegroundService(Intent(this, KeepAliveService::class.java))
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        info.text = "Probe source\n\npid ${Outbox.pid}\nrows 1..${Outbox.seq}\nacked ${Outbox.acked(this)}\nanswered ${Outbox.served(this)} calls"
    }
}
