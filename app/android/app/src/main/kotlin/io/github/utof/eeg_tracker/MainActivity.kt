package io.github.utof.eeg_tracker

import android.app.Activity
import android.content.Intent
import android.provider.Settings
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

    /** The sharp-hours question this Activity was opened from, until the Dart side takes it (SharpPrompts.kt). */
    private var sharpLaunch: Map<String, Any>? = null
    private var sharpChannel: MethodChannel? = null
    private var confirmChannel: MethodChannel? = null

    /** Pairing with a laptop (PairLinkActivity.kt): "take" hands over the link once, "open" says one arrived. */
    private var linkChannel: MethodChannel? = null

    /** The headband watcher's channel (AutoWatch.kt): pairing needs this Activity; a notification tap says "launch". */
    private var autoChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        PhoneChannel.register(messenger, applicationContext)
        AlarmChannel.register(messenger, applicationContext)
        AudioRoute.register(messenger, applicationContext) // where the sound goes (feedback sessions warn on Bluetooth)
        NetworkWatch.register(messenger, applicationContext) // Share on Wi-Fi tells the paired laptop at once (DECISIONS 676)
        AutoWatch.takeIntent(applicationContext, intent)
        autoChannel = AutoWatch.register(messenger, applicationContext, this)
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
        // ("headband", "microphone"), "release" ends it; Stop on the notification comes back as "stopTapped", the
        // session's own second button ("button", e.g. the work session's Back) as "buttonTapped", and the audio focus
        // (a call, another app's sound) as "focus" with "loss", "lossTransient", "duck" or "gain". "background": the
        // keep between sessions (Share on Wi-Fi), which is not a session.
        val session = MethodChannel(messenger, "eeg_tracker/session")
        session.setMethodCallHandler { call, result ->
            when (call.method) {
                "hold" -> SessionService.hold(
                    applicationContext,
                    call.argument<String>("title") ?: "Sound session",
                    call.argument<String>("text") ?: "",
                    call.argument<Boolean>("headband") == true,
                    call.argument<Boolean>("microphone") == true,
                    call.argument<Boolean>("focus") != false,
                    call.argument<String>("button"),
                    call.argument<Boolean>("background") == true,
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
        SessionService.onButtonTapped = { runOnUiThread { session.invokeMethod("buttonTapped", null) } }
        SessionService.onFocusChanged = { change -> runOnUiThread { session.invokeMethod("focus", change) } }
        // The sharp-hours questions (SharpPrompts.kt): "arm" keeps the moments ahead, "takeLaunch" hands over the
        // question a notification tap opened (once), "open" tells the Dart side a tap came while the app ran.
        takeSharpIntent(intent)
        sharpChannel = MethodChannel(messenger, "eeg_tracker/sharp").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "arm" -> {
                            val at = (call.argument<List<Number>>("at") ?: emptyList()).map { it.toLong() }
                            val test = call.argument<List<Boolean>>("test") ?: emptyList()
                            val kind = call.argument<List<String>>("kind") ?: emptyList()
                            SharpPrompts.arm(applicationContext, at, test, kind)
                            result.success(null)
                        }
                        "takeLaunch" -> {
                            result.success(sharpLaunch)
                            sharpLaunch = null
                        }
                        "status" -> result.success(
                            mapOf(
                                "notifications" to SharpPrompts.notificationsOn(applicationContext),
                                "studyNotifications" to SharpPrompts.notificationsOn(applicationContext, SharpPrompts.STUDY_CHANNEL),
                            ),
                        )
                        "openChannelSettings" -> {
                            SharpPrompts.channel(applicationContext)
                            startActivity(
                                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                    .putExtra(Settings.EXTRA_CHANNEL_ID, SharpPrompts.CHANNEL),
                            )
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("sharp", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
        // The confirmation questions (ConfirmPrompts.kt): "arm" keeps the batch and its moment, "answered" takes a
        // question answered in the app out of the notification, "open" tells the Dart side its notification was tapped.
        confirmChannel = MethodChannel(messenger, "eeg_tracker/confirm").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "arm" -> {
                            ConfirmPrompts.arm(
                                applicationContext,
                                call.argument<Number>("at")?.toLong() ?: 0L,
                                call.argument<List<String>>("ids") ?: emptyList(),
                                call.argument<List<String>>("texts") ?: emptyList(),
                                call.argument<List<String>>("cards") ?: emptyList(),
                            )
                            result.success(null)
                        }
                        "answered" -> {
                            ConfirmPrompts.answered(applicationContext, call.argument<String>("id") ?: "")
                            result.success(null)
                        }
                        "status" -> result.success(mapOf("notifications" to ConfirmPrompts.notificationsOn(applicationContext)))
                        "openChannelSettings" -> {
                            ConfirmPrompts.channel(applicationContext)
                            startActivity(
                                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                    .putExtra(Settings.EXTRA_CHANNEL_ID, ConfirmPrompts.CHANNEL),
                            )
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("confirm", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
        linkChannel = MethodChannel(messenger, "eeg_tracker/link").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> result.success(PairLinks.take())
                    else -> result.notImplemented()
                }
            }
        }
        PairLinks.onArrived = { runOnUiThread { linkChannel?.invokeMethod("open", null) } }
        // Meditation and the dream catcher keep the screen on while they run: they live in this Activity, and a
        // locked phone could freeze them (DECISIONS rows 75 and 110). The dream catcher also dims this window to
        // the lowest brightness while you lie in bed; "off" hands the brightness back to the phone's setting.
        MethodChannel(messenger, "eeg_tracker/window").setMethodCallHandler { call, result ->
            val on = call.argument<Boolean>("on") == true
            when (call.method) {
                "keepScreenOn" -> runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    // every session screen keeps the screen on: no question and no headband check then; sharing's
                    // first minutes and an export say they are not a session
                    if (call.argument<Boolean>("session") != false) SharpPrompts.screenHeld = on
                    result.success(null)
                }
                // the Share on Wi-Fi sheet shows the code: no screenshots, screen recordings or recent-apps preview of
                // this window while it is open (DECISIONS 754)
                "secure" -> runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
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

    /** A notification tap while the app runs (launchMode singleTop). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (takeSharpIntent(intent)) sharpChannel?.invokeMethod("open", null)
        if (intent.action == ConfirmPrompts.ACTION_OPEN) confirmChannel?.invokeMethod("open", null)
        if (AutoWatch.takeIntent(applicationContext, intent)) autoChannel?.invokeMethod("launch", null)
    }

    /** Keeps a sharp-hours question from [intent] for the Dart side; not when Android replays it from Recents. */
    private fun takeSharpIntent(intent: Intent?): Boolean {
        if (intent?.action != SharpPrompts.ACTION_OPEN || !intent.hasExtra(SharpPrompts.EXTRA_PLANNED)) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        sharpLaunch = mapOf(
            "planned" to intent.getLongExtra(SharpPrompts.EXTRA_PLANNED, 0L),
            "shown" to intent.getLongExtra(SharpPrompts.EXTRA_SHOWN, 0L),
            "test" to intent.getBooleanExtra(SharpPrompts.EXTRA_TEST, false),
            "kind" to (intent.getStringExtra(SharpPrompts.EXTRA_KIND) ?: SharpPrompts.Kind.SHARP.wire),
        )
        intent.removeExtra(SharpPrompts.EXTRA_PLANNED) // taken once, also if the Activity is made again
        return true
    }

    /** The sessions live in this Activity's Flutter engine: without it nothing is left to keep alive. */
    override fun onDestroy() {
        SharpPrompts.screenHeld = false
        sharpChannel = null
        confirmChannel = null
        PairLinks.onArrived = null
        linkChannel = null
        autoChannel = null
        AutoWatch.screenHolds = false // the Signal tab went with the screen
        SessionService.onStopTapped = null
        SessionService.onButtonTapped = null
        SessionService.onFocusChanged = null
        SessionService.release(applicationContext)
        // the app's own server between nights lived in this engine: its hold on Wi-Fi goes with it (DECISIONS 612)
        PhoneChannel.holdWifi(applicationContext, "screen", false)
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
        if (requestCode == AutoWatch.REQUEST_PAIR) {
            AutoWatch.onPairResult(applicationContext, resultCode, data)
            return
        }
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
