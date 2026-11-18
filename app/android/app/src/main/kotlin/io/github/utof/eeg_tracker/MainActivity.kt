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

    /** Export data (DataExport.kt): the copier, and the call waiting for the folder picker. */
    private var dataExport: DataExport? = null
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        PhoneChannel.register(messenger, applicationContext)
        // Export needs this Activity for the system folder picker, so it lives here, not in PhoneChannel.
        val data = DataExport(applicationContext).also { dataExport = it }
        MethodChannel(messenger, NightExport.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "exportNight" -> startExport(call.argument<List<String>>("paths"), call.argument<String>("folder"), result)
                "pickFolder" -> pickFolder(result)
                "folderUsable" -> result.success(data.usable(call.argument<String>("uri") ?: ""))
                "open" -> data.run(result) { data.open(call.argument<String>("uri") ?: ""); null }
                "copy" -> data.run(result) { data.copy(call.argument<String>("source") ?: "", call.argument<String>("path") ?: "") }
                "write" -> data.run(result) { data.write(call.argument<String>("path") ?: "", call.argument<ByteArray>("bytes") ?: ByteArray(0)) }
                "close" -> data.run(result) { data.close(); null }
                else -> result.notImplemented()
            }
        }
        // Sound sessions with the phone locked (SessionService.kt): "hold" answers with what is kept
        // ("headband", "microphone"), "release" ends it; Stop on the notification comes back as "stopTapped".
        val session = MethodChannel(messenger, "eeg_tracker/session")
        session.setMethodCallHandler { call, result ->
            when (call.method) {
                "hold" -> SessionService.hold(
                    applicationContext,
                    call.argument<String>("title") ?: "Sound session",
                    call.argument<String>("text") ?: "",
                    call.argument<Boolean>("headband") == true,
                    call.argument<Boolean>("microphone") == true,
                ) { kept, error ->
                    runOnUiThread { if (kept != null) result.success(kept) else result.error("session", error, null) }
                }
                "release" -> {
                    SessionService.release(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        SessionService.onStopTapped = { runOnUiThread { session.invokeMethod("stopTapped", null) } }
        // Meditation and the dream catcher keep the screen on while they run: they live in this Activity, and a
        // locked phone could freeze them (DECISIONS rows 75 and 110). The dream catcher also dims this window to
        // the lowest brightness while you lie in bed; "off" hands the brightness back to the phone's setting.
        MethodChannel(messenger, "eeg_tracker/window").setMethodCallHandler { call, result ->
            val on = call.argument<Boolean>("on") == true
            when (call.method) {
                "keepScreenOn" -> runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                "dim" -> runOnUiThread {
                    val attrs = window.attributes
                    attrs.screenBrightness = if (on) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = attrs
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The sessions live in this Activity's Flutter engine: without it nothing is left to keep alive. */
    override fun onDestroy() {
        SessionService.onStopTapped = null
        SessionService.release(applicationContext)
        super.onDestroy()
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

    /** The system folder picker for Export data; the answer keeps the grant (DataExport.keep). */
    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "the folder picker is already open", null)
            return
        }
        try {
            pendingPick = result
            startActivityForResult(DataExport.pickIntent(), DataExport.REQUEST)
        } catch (e: Exception) {
            pendingPick = null
            result.error("export", e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DataExport.REQUEST) {
            val result = pendingPick ?: return
            pendingPick = null
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null) {
                result.success(null) // the owner closed the picker
                return
            }
            try {
                result.success(dataExport?.keep(tree))
            } catch (e: Exception) {
                result.error("folder", e.message ?: e.javaClass.simpleName, null)
            }
            return
        }
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
