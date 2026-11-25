package io.github.utof.linkprobe.reader

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * The reader's one screen: a button per route and "Run all", with a log. The script starts it with
 * `am start -n .../MainActivity --es run ID --es state NAME --es routes provider,service,activity`.
 */
class MainActivity : Activity() {
    private lateinit var log: TextView
    private val resultWaiter = AtomicReference<((Int, Intent?) -> Unit)?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        log = TextView(this).apply { typeface = Typeface.MONOSPACE; textSize = 12f }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 40, 24, 24)
            addView(TextView(this@MainActivity).apply { text = "Probe reader"; textSize = 18f })
            for ((label, routes) in listOf("Provider" to listOf("provider"), "Service" to listOf("service"), "Activity" to listOf("activity"), "Run all" to Probe.ALL)) {
                addView(Button(this@MainActivity).apply { text = label; setOnClickListener { start(routes, Meta("tap-" + System.currentTimeMillis(), "manual", "front")) } })
            }
            addView(ScrollView(this@MainActivity).apply { addView(log) })
        }
        setContentView(col)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(i: Intent) {
        val routes = i.getStringExtra("routes")?.split(",")?.filter { it.isNotBlank() } ?: return
        start(routes, Meta(i.getStringExtra("run") ?: "adb", i.getStringExtra("state") ?: "?", "front"))
    }

    private fun start(routes: List<String>, meta: Meta) {
        Thread { Probe.runAll(this, this, routes, meta) { line -> runOnUiThread { log.append(line + "\n") } } }.start()
    }

    /** Route 3, called from a worker thread: opens the source's result screen and waits for what it hands back. */
    fun activityRoute(): Outcome {
        val t0 = SystemClock.elapsedRealtime()
        val latch = CountDownLatch(1)
        val out = AtomicReference<Outcome>()
        runOnUiThread {
            resultWaiter.set { code, data ->
                val ms = SystemClock.elapsedRealtime() - t0
                out.set(
                    when {
                        code == RESULT_OK && data != null -> Outcome(
                            true, ms, "ok", rows = JSONArray(data.getStringExtra("rows_json") ?: "[]").length(),
                            seq = data.getLongExtra("seq", 0), srcPid = data.getIntExtra("pid", 0), srcStartMs = data.getLongExtra("startMs", 0),
                        )
                        data?.hasExtra("refused") == true -> Outcome(false, ms, "refused", data.getStringExtra("refused") ?: "")
                        else -> Outcome(false, ms, "cancelled", "result code $code, no data")
                    },
                )
                latch.countDown()
            }
            try {
                val i = Intent("io.github.utof.linkprobe.source.GET_BATCH").setPackage(SRC).putExtra("after", 0L)
                @Suppress("DEPRECATION")
                startActivityForResult(i, REQ)
            } catch (e: Throwable) {
                out.set(Outcome.failed(t0, e))
                latch.countDown()
            }
        }
        if (!latch.await(ACTIVITY_WAIT_SECONDS, TimeUnit.SECONDS)) {
            out.compareAndSet(null, Outcome.failed(t0, "timeout", "no result in $ACTIVITY_WAIT_SECONDS s (look at the phone's screen for a prompt)"))
        }
        resultWaiter.set(null)
        return out.get()
    }

    @Deprecated("the plain API is the smallest way to get a result back")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ) resultWaiter.get()?.invoke(resultCode, data)
    }

    companion object {
        private const val REQ = 77
        private const val ACTIVITY_WAIT_SECONDS = 20L
    }
}
