package io.github.utof.eeg_tracker

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** The export waiting for the folder picker; at most one at a time. */
    private var pendingExport: NightExport? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        PhoneChannel.register(messenger, applicationContext)
        // Export needs this Activity for the system folder picker, so it lives here, not in PhoneChannel.
        MethodChannel(messenger, NightExport.CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "exportNight") startExport(call.argument<List<String>>("paths"), call.argument<String>("folder"), result)
            else result.notImplemented()
        }
    }

    private fun startExport(paths: List<String>?, folder: String?, result: MethodChannel.Result) {
        if (pendingExport != null) {
            result.error("busy", "an export is already waiting for a folder", null)
            return
        }
        try {
            val files = NightExport.checkedFiles(applicationContext, paths ?: emptyList())
            pendingExport = NightExport(files, folder ?: "eeg-night", result)
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), NightExport.REQUEST)
        } catch (e: Exception) {
            pendingExport = null
            result.error("export", e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != NightExport.REQUEST) return
        val export = pendingExport ?: return
        pendingExport = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            export.result.success(null) // the owner closed the picker
            return
        }
        export.copyInBackground(applicationContext, tree)
    }
}
