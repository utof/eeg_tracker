package io.github.utof.linkprobe.source

import android.content.Context
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject

data class Row(val n: Long, val kind: String, val text: String)

/** The few rows every route serves, the running number (the last row's number), and the ack. */
object Outbox {
    const val TAG = "LINKPROBE"

    /** When this process started and its id: a reader that sees a new pair knows the call started the source. */
    val startedAtMs: Long = System.currentTimeMillis()
    val pid: Int = Process.myPid()

    private val all = listOf(
        Row(1, "answer", "Yes"),
        Row(2, "estimate", "slept 7.2 h"),
        Row(3, "span", "walk 08:10-08:40"),
        Row(4, "night", "night 2026-11-24"),
        Row(5, "daily", "calm 0.62"),
    )

    val seq: Long get() = all.last().n

    fun rowsAfter(after: Long): List<Row> = all.filter { it.n > after }

    fun rowsJson(after: Long): String {
        val a = JSONArray()
        for (r in rowsAfter(after)) a.put(JSONObject().put("n", r.n).put("kind", r.kind).put("text", r.text))
        return a.toString()
    }

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences("outbox", Context.MODE_PRIVATE)

    fun acked(ctx: Context): Long = prefs(ctx).getLong("acked", 0)

    /** The reader says it has everything up to n. Kept on disk, so it shows after a restart of this process. */
    fun ack(ctx: Context, n: Long): Long {
        prefs(ctx).edit().putLong("acked", n).commit()
        return n
    }

    /** Counts the calls this app has answered (on disk). */
    fun countServed(ctx: Context): Long {
        val p = prefs(ctx)
        val n = p.getLong("served", 0) + 1
        p.edit().putLong("served", n).commit()
        return n
    }

    fun served(ctx: Context): Long = prefs(ctx).getLong("served", 0)
}
