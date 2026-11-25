package io.github.utof.linkprobe.reader

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.os.Parcel
import android.os.SystemClock
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

const val SRC = "io.github.utof.linkprobe.source"
const val TAG = "LINKPROBE"

/**
 * What one route did. kind: ok | refused (the source answered "no") | null_cursor | bind_false | null_binding | binding_died |
 * timeout | cancelled | exception (detail = the exception's class and text).
 */
class Outcome(
    val ok: Boolean,
    val ms: Long,
    val kind: String,
    val detail: String = "",
    val rows: Int = 0,
    val seq: Long = 0,
    val srcPid: Int = 0,
    val srcStartMs: Long = 0,
    val ackOk: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("ok", ok).put("ms", ms).put("kind", kind).put("detail", detail)
        .put("rows", rows).put("seq", seq).put("srcPid", srcPid).put("srcStartMs", srcStartMs).put("ackOk", ackOk ?: JSONObject.NULL)

    companion object {
        fun failed(t0: Long, e: Throwable): Outcome {
            val text = "${e.javaClass.simpleName}: ${e.message}"
            val refused = e is SecurityException && e.message?.contains("linkprobe-refused") == true
            return Outcome(false, SystemClock.elapsedRealtime() - t0, if (refused) "refused" else "exception", text)
        }

        fun failed(t0: Long, kind: String, detail: String) = Outcome(false, SystemClock.elapsedRealtime() - t0, kind, detail)
    }
}

object Routes {
    private const val DESCRIPTOR = "io.github.utof.linkprobe.OUTBOX"
    private const val BIND_WAIT_SECONDS = 8L

    /** Route 1: ContentResolver.query for the rows, then call("ack"). */
    fun provider(ctx: Context): Outcome {
        val t0 = SystemClock.elapsedRealtime()
        return try {
            val uri = Uri.parse("content://$SRC.outbox/rows").buildUpon().appendQueryParameter("after", "0").build()
            val c = ctx.contentResolver.query(uri, null, null, null, null)
                ?: return Outcome.failed(t0, "null_cursor", "query returned null: Android found no provider, or its start was refused")
            val (rows, ex) = c.use { it.count to it.extras }
            val ms = SystemClock.elapsedRealtime() - t0
            val seq = ex?.getLong("seq") ?: 0L
            val ack = try {
                ctx.contentResolver.call(Uri.parse("content://$SRC.outbox"), "ack", seq.toString(), null)?.getLong("acked") == seq
            } catch (e: Exception) {
                false
            }
            Outcome(true, ms, "ok", rows = rows, seq = seq, srcPid = ex?.getInt("pid") ?: 0, srcStartMs = ex?.getLong("startMs") ?: 0, ackOk = ack)
        } catch (e: Throwable) {
            Outcome.failed(t0, e)
        }
    }

    /** Route 2: bindService to the source's service, one transaction for the rows and one for the ack. Run it off the main thread. */
    fun service(ctx: Context): Outcome {
        val t0 = SystemClock.elapsedRealtime()
        val app = ctx.applicationContext
        val latch = CountDownLatch(1)
        var binder: IBinder? = null
        var why: String? = null
        val conn = object : android.content.ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) { binder = service; latch.countDown() }
            override fun onServiceDisconnected(name: ComponentName) {}
            override fun onNullBinding(name: ComponentName) { why = "null_binding"; latch.countDown() }
            override fun onBindingDied(name: ComponentName) { why = "binding_died"; latch.countDown() }
        }
        val intent = Intent().setComponent(ComponentName(SRC, "$SRC.OutboxService"))
        try {
            val bound = app.bindService(intent, conn, Context.BIND_AUTO_CREATE)
            if (!bound) return Outcome.failed(t0, "bind_false", "bindService returned false")
            if (!latch.await(BIND_WAIT_SECONDS, TimeUnit.SECONDS)) {
                return Outcome.failed(t0, "timeout", "no onServiceConnected in $BIND_WAIT_SECONDS s")
            }
            val b = binder ?: return Outcome.failed(t0, why ?: "null_binding", "the service gave no binder")
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            try {
                data.writeInterfaceToken(DESCRIPTOR)
                data.writeLong(0)
                b.transact(1, data, reply, 0)
                reply.readException()
                val rows = reply.readInt()
                repeat(rows) { reply.readLong(); reply.readString(); reply.readString() }
                val seq = reply.readLong()
                val pid = reply.readInt()
                val start = reply.readLong()
                val ms = SystemClock.elapsedRealtime() - t0
                val data2 = Parcel.obtain()
                val reply2 = Parcel.obtain()
                val ack = try {
                    data2.writeInterfaceToken(DESCRIPTOR)
                    data2.writeLong(seq)
                    b.transact(2, data2, reply2, 0)
                    reply2.readException()
                    reply2.readLong() == seq
                } catch (e: Exception) {
                    false
                } finally {
                    data2.recycle(); reply2.recycle()
                }
                return Outcome(true, ms, "ok", rows = rows, seq = seq, srcPid = pid, srcStartMs = start, ackOk = ack)
            } finally {
                data.recycle(); reply.recycle()
            }
        } catch (e: Throwable) {
            return Outcome.failed(t0, e)
        } finally {
            try { app.unbindService(conn) } catch (_: Exception) {}
        }
    }
}
