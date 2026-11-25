package io.github.utof.linkprobe.reader

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File

/** What the script asked for: a run id, the state label it set up, and who triggered it ("front" = reader's screen, "bg" = broadcast). */
class Meta(val run: String, val state: String, val mode: String)

object Probe {
    val ALL = listOf("provider", "service", "activity")

    /** Where results go: one JSON line each, in the app's external files folder (the script reads it with adb) and in logcat. */
    private fun file(ctx: Context): File = File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "results.jsonl")

    private fun emit(ctx: Context, line: JSONObject) {
        val s = line.toString()
        Log.i(TAG, "RESULT $s")
        try { file(ctx).appendText(s + "\n") } catch (e: Exception) { Log.w(TAG, "could not write the results file: $e") }
    }

    /** Runs the routes one after the other (off the main thread), reports each, then a "done" line. */
    fun runAll(ctx: Context, screen: MainActivity?, routes: List<String>, meta: Meta, show: (String) -> Unit) {
        for (r in routes) {
            val o = when (r) {
                "provider" -> Routes.provider(ctx)
                "service" -> Routes.service(ctx)
                "activity" -> screen?.activityRoute() ?: Outcome.failed(SystemClock.elapsedRealtime(), "skipped", "the activity route needs the reader's screen in front")
                else -> Outcome.failed(SystemClock.elapsedRealtime(), "unknown", "no such route: $r")
            }
            val line = o.toJson().put("run", meta.run).put("state", meta.state).put("mode", meta.mode).put("route", r)
                .put("readerPid", android.os.Process.myPid()).put("readerPkg", ctx.packageName).put("t", System.currentTimeMillis())
            emit(ctx, line)
            show("$r: ${if (o.ok) "worked" else "NOT (${o.kind})"} ${o.ms} ms ${o.detail}")
        }
        emit(ctx, JSONObject().put("run", meta.run).put("done", true).put("readerPkg", ctx.packageName))
    }
}
