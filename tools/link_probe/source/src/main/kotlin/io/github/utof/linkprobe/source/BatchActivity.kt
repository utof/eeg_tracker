package io.github.utof.linkprobe.source

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Route 3: started for a result by the reader; checks the calling package, returns the same batch (or refuses), and closes. */
class BatchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val v = Guard.checkPackage(this, callingPackage, "activity")
        if (v.ok) {
            val after = intent.getLongExtra("after", 0L)
            Outbox.countServed(this)
            setResult(
                RESULT_OK,
                Intent()
                    .putExtra("rows_json", Outbox.rowsJson(after))
                    .putExtra("seq", Outbox.seq)
                    .putExtra("pid", Outbox.pid)
                    .putExtra("startMs", Outbox.startedAtMs),
            )
        } else {
            setResult(RESULT_CANCELED, Intent().putExtra("refused", v.why))
        }
        finish()
    }
}
