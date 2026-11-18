package io.github.utof.eeg_tracker

import android.app.Activity
import android.content.Intent
import android.view.WindowManager
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
        // The meditation keeps the screen on while it runs: it lives in this Activity, and a locked phone
        // could freeze it (DECISIONS row 75).
        MethodChannel(messenger, "eeg_tracker/window").setMethodCallHandler { call, result ->
            if (call.method != "keepScreenOn") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val on = call.argument<Boolean>("on") == true
            runOnUiThread {
                if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(null)
            }
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
