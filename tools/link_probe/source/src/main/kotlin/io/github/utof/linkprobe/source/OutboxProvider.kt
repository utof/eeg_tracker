package io.github.utof.linkprobe.source

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle

/** Route 1: a read-only ContentProvider. query(...?after=N) gives the rows after N; call("ack", "N") records N; call("info"). */
class OutboxProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun guard(via: String) {
        val v = Guard.checkUid(context!!, Binder.getCallingUid(), via)
        if (!v.ok) throw Guard.refusal(v)
    }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor {
        guard("provider.query")
        val after = uri.getQueryParameter("after")?.toLongOrNull() ?: 0L
        val c = MatrixCursor(arrayOf("n", "kind", "text"))
        for (r in Outbox.rowsAfter(after)) c.addRow(arrayOf<Any>(r.n, r.kind, r.text))
        c.extras = Bundle().apply {
            putLong("seq", Outbox.seq)
            putInt("pid", Outbox.pid)
            putLong("startMs", Outbox.startedAtMs)
            putLong("served", Outbox.countServed(context!!))
        }
        return c
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        guard("provider.call.$method")
        val ctx = context!!
        return Bundle().apply {
            when (method) {
                "ack" -> putLong("acked", Outbox.ack(ctx, arg?.toLongOrNull() ?: 0L))
                "info" -> putLong("acked", Outbox.acked(ctx))
                else -> throw IllegalArgumentException("unknown method $method")
            }
            putLong("seq", Outbox.seq)
            putInt("pid", Outbox.pid)
            putLong("startMs", Outbox.startedAtMs)
        }
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri = throw UnsupportedOperationException("read-only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = throw UnsupportedOperationException("read-only")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int =
        throw UnsupportedOperationException("read-only")
}
