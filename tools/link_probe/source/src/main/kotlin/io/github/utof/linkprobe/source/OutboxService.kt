package io.github.utof.linkprobe.source

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel

/**
 * Route 2: a bound service with the same answer. Transaction 1 = rows after N (long in); 2 = ack N (long in).
 * Reply: no exception, or a SecurityException when the caller is refused.
 */
class OutboxService : Service() {
    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != GET && code != ACK) return super.onTransact(code, data, reply, flags)
            reply ?: return true
            val v = Guard.checkUid(this@OutboxService, Binder.getCallingUid(), "service.$code")
            if (!v.ok) {
                reply.writeException(Guard.refusal(v))
                return true
            }
            data.enforceInterface(DESCRIPTOR)
            val n = data.readLong()
            reply.writeNoException()
            if (code == GET) {
                val rows = Outbox.rowsAfter(n)
                reply.writeInt(rows.size)
                for (r in rows) {
                    reply.writeLong(r.n)
                    reply.writeString(r.kind)
                    reply.writeString(r.text)
                }
                Outbox.countServed(this@OutboxService)
            } else {
                reply.writeLong(Outbox.ack(this@OutboxService, n))
            }
            reply.writeLong(Outbox.seq)
            reply.writeInt(Outbox.pid)
            reply.writeLong(Outbox.startedAtMs)
            return true
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    companion object {
        const val DESCRIPTOR = "io.github.utof.linkprobe.OUTBOX"
        const val GET = 1
        const val ACK = 2
    }
}
