package io.github.utof.eeg_tracker

import android.app.Activity
import android.app.ActivityManager
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.le.ScanResult
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.regex.Pattern

/**
 * The headband watcher of automatic recording (ROADMAP row 39, DECISIONS 600-609). The decisions are made in Dart
 * (lib/auto); this side does what only Android can:
 *
 * - Pairs the headband once through Android's companion pairing (CompanionDeviceManager, a name filter for "BB Black"
 *   and "BrainBit") and asks Android to watch for it (presence observing: the String overload on Android 12-15,
 *   ObservingDevicePresenceRequest on 16+). Android then binds HeadbandPresenceService when the headband comes near or
 *   goes, keeps the app ready while it is near, and lets it start a foreground service from the background
 *   (REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND). The pairing makes no connection of its own and
 *   starts no scan, so it sits beside BrainBit's SDK and our own connection.
 * - Without it (no pairing, an old Android), the battery exemption the app already asks for is the other legal way
 *   to start the check from the background; with neither, Android refuses and the app checks only when it is opened
 *   (the refusal is recorded and the settings page says so).
 * - Arms the bedtime checks (every 10 minutes inside the window Dart computed; inexact alarms that may ring in Doze)
 *   and starts the check service (AutoWatchService.kt) for a presence event, a bedtime check, the laptop's signal or
 *   the app opened. Never while the night recorder, a sound or work session, or a session screen holds the headband.
 * - Hands over the launches its notifications ask for (open the work page, the settings page).
 */
object AutoWatch {
    const val CHANNEL = "eeg_tracker/auto"
    private const val TAG = "AutoWatch"
    private const val PREFS = "auto_watch"
    const val ACTION_TICK = "io.github.utof.eeg_tracker.auto.TICK"
    const val ACTION_ANSWER = "io.github.utof.eeg_tracker.auto.ANSWER"
    const val ACTION_OPEN = "io.github.utof.eeg_tracker.auto.OPEN"
    const val EXTRA_ID = "autoId"
    const val EXTRA_ANSWER = "autoAnswer"
    const val EXTRA_LAUNCH = "autoLaunch"
    const val EXTRA_QUIET = "autoQuiet"
    const val EXTRA_LIMIT = "autoLimitMin"
    const val EXTRA_KIND = "autoKind"
    const val REQUEST_PAIR = 4720
    private const val REQ_TICK = 60
    private const val RECORDER = "com.pravera.flutter_foreground_task.service.ForegroundService"

    /** [busyReason]'s word while the recorder runs (lib/auto/controller.dart `recordingBusy`). */
    const val RECORDING_BUSY = "night recording"

    /** A presence event starts a check at most this often: our own connection can make the headband vanish and return. */
    private const val PRESENCE_EVERY_MS = 30L * 60 * 1000

    /** The headband names the pairing dialog offers ("BB Black" verified, lib/headband/own/protocol.dart). */
    private val NAMES: Pattern = Pattern.compile("^(BB Black|BrainBit).*")

    private const val K_ID = "association_id"
    private const val K_ADDRESS = "address"
    private const val K_NAME = "name"
    private const val K_OBSERVING = "observing"
    private const val K_PRESENCE = "presence"
    private const val K_PRESENCE_AT = "presence_at"
    private const val K_PRESENCE_CHECK_AT = "presence_check_at"
    private const val K_REFUSED_AT = "refused_at"
    private const val K_LAST_CHECK_AT = "last_check_at"
    private const val K_LAST_TRIGGER = "last_trigger"
    private const val K_BEDTIME = "bedtime"

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The pairing dialog's call, waiting for its answer. */
    private var pendingPair: MethodChannel.Result? = null

    /** What a notification tap opened the app for, until the Dart side takes it. */
    @Volatile
    private var launch: Map<String, Any?>? = null

    /** When the work page last took its launch (the check service waits for this before it asks instead). */
    @Volatile
    var workOpenedAt = 0L

    /**
     * The app's screen holds the headband with a connection that is neither a night nor a session (the Signal tab's
     * own, DECISIONS 595); cleared when the screen's Activity goes.
     */
    @Volatile
    var screenHolds = false

    /** When the screen last went off, as far as this process saw it (EegApp registers the receiver). */
    @Volatile
    private var screenOffAt = 0L

    fun trackScreen(context: Context) {
        try {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }
            context.registerReceiver(object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    screenOffAt = if (i.action == Intent.ACTION_SCREEN_OFF) System.currentTimeMillis() else 0L
                }
            }, filter)
        } catch (_: Exception) {
        }
    }

    /** The channel in the screen's engine ([activity] set: pairing works) and in the check service's. */
    fun register(messenger: BinaryMessenger, context: Context, activity: Activity?): MethodChannel {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(status(app))
                    "pair" -> if (activity == null) result.error("pair", "only from the app's screen", null) else pair(activity, result)
                    "forget" -> {
                        forget(app)
                        result.success(null)
                    }
                    "check" -> {
                        val reason = call.argument<String>("reason") ?: "opened"
                        requestCheck(app, reason, force = reason == "now")
                        result.success(null)
                    }
                    "release" -> AutoWatchService.release { result.success(null) }
                    "screenHolds" -> {
                        screenHolds = call.argument<Boolean>("on") == true
                        result.success(null)
                    }
                    "armBedtime" -> {
                        arm(app, (call.argument<List<Number>>("at") ?: emptyList()).map { it.toLong() })
                        result.success(null)
                    }
                    "takeLaunch" -> {
                        result.success(launch)
                        launch = null
                    }
                    "workOpened" -> {
                        workOpenedAt = System.currentTimeMillis()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("auto", e.message ?: e.javaClass.simpleName, null)
            }
        }
        return channel
    }

    // ---- what the phone allows -------------------------------------------------------------------------------------

    private fun companionSupported(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)

    private fun cdm(context: Context): CompanionDeviceManager? =
        if (companionSupported(context)) context.getSystemService(CompanionDeviceManager::class.java) else null

    /** The headband is still associated with the app (Android may drop an association, or the owner in settings). */
    @Suppress("DEPRECATION")
    private fun associated(context: Context): Boolean {
        val cdm = cdm(context) ?: return false
        val address = prefs(context).getString(K_ADDRESS, null) ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                cdm.myAssociations.any { it.deviceMacAddress?.toString().equals(address, ignoreCase = true) }
            } else {
                cdm.associations.any { it.equals(address, ignoreCase = true) }
            }
        } catch (_: Exception) {
            false
        }
    }

    fun status(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val paired = associated(context)
        val nm = context.getSystemService(NotificationManager::class.java)
        val channel = nm?.getNotificationChannel(AutoWatchService.CHANNEL)
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "companion" to companionSupported(context),
            "presence" to (companionSupported(context) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S),
            "paired" to paired,
            "observing" to (paired && p.getBoolean(K_OBSERVING, false)),
            "name" to p.getString(K_NAME, null),
            "presence_state" to p.getString(K_PRESENCE, null),
            "presence_at" to p.getLong(K_PRESENCE_AT, 0L),
            "batteryExempt" to (context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true),
            "notifications" to (nm?.areNotificationsEnabled() != false && channel?.importance != NotificationManager.IMPORTANCE_NONE),
            "xiaomi" to (getprop("ro.mi.os.version.name") ?: getprop("ro.miui.ui.version.name")),
            "refused_at" to p.getLong(K_REFUSED_AT, 0L),
            "last_check_at" to p.getLong(K_LAST_CHECK_AT, 0L),
            "last_trigger" to p.getString(K_LAST_TRIGGER, null),
            "next_bedtime" to (bedtime(context).firstOrNull { it > System.currentTimeMillis() } ?: 0L),
        )
    }

    private fun getprop(key: String): String? = try {
        val p = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        out.ifEmpty { null }
    } catch (_: Exception) {
        null
    }

    /** Charging, screen, Do Not Disturb and the next alarm clock, for the rules (lib/auto/rules.dart). */
    fun context(context: Context): Map<String, Any?> {
        val bm = context.getSystemService(BatteryManager::class.java)
        val pm = context.getSystemService(PowerManager::class.java)
        val nm = context.getSystemService(NotificationManager::class.java)
        val screenOn = pm?.isInteractive != false
        return mapOf(
            "charging" to (bm?.isCharging == true),
            "screenOn" to screenOn,
            "screenOffAt" to if (screenOn) 0L else screenOffAt,
            "dnd" to ((nm?.currentInterruptionFilter ?: NotificationManager.INTERRUPTION_FILTER_ALL) > NotificationManager.INTERRUPTION_FILTER_ALL),
            "nextAlarm" to (context.getSystemService(AlarmManager::class.java)?.nextAlarmClock?.triggerTime ?: 0L),
        )
    }

    /**
     * The headband must not be touched: the night recorder, a sound or work session, a session screen, or the Signal
     * tab's own connection holds it. (Share on Wi-Fi's keep between nights is not a session; the night's sleep scoring
     * reads files and never the headband.)
     */
    fun busyReason(context: Context): String? = when {
        recorderRunning(context) -> RECORDING_BUSY
        SessionService.sessionRunning -> "session"
        SharpPrompts.screenHeld -> "session on screen"
        screenHolds -> "signal on screen"
        else -> null
    }

    @Suppress("DEPRECATION")
    private fun recorderRunning(context: Context): Boolean = try {
        context.getSystemService(ActivityManager::class.java)?.getRunningServices(50)?.any { it.service.className == RECORDER } == true
    } catch (_: Exception) {
        false
    }

    /** Every kind is "Do nothing" in files/auto-start/settings.json (lib/auto/store.dart): no check at all. */
    private fun allOff(context: Context): Boolean = try {
        val f = File(context.filesDir, "auto-start/settings.json")
        if (!f.exists()) {
            false
        } else {
            val choices = JSONObject(f.readText()).optJSONObject("choices")
            choices != null && listOf("night", "work", "other").all { choices.optString(it, "ask") == "nothing" }
        }
    } catch (_: Exception) {
        false
    }

    // ---- checks ------------------------------------------------------------------------------------------------------

    /**
     * Starts a check for [reason] unless the headband is busy or every kind is off; the laptop's word also during a
     * recording (DECISIONS 1107). [fake]: debug builds only.
     */
    fun requestCheck(context: Context, reason: String, force: Boolean = false, fake: String? = null) {
        if (!force && allOff(context)) return
        val busy = busyReason(context)
        // the laptop's work word is the one trigger taken while the recorder runs: the watcher then touches no
        // headband and only starts or offers the work session on that recording (lib/auto/controller.dart, 7)
        val onRecording = reason == "laptop" && busy == RECORDING_BUSY
        if (busy != null && !onRecording) {
            Log.i(TAG, "no check for $reason: $busy")
            return
        }
        val now = System.currentTimeMillis()
        prefs(context).edit().putLong(K_LAST_CHECK_AT, now).putString(K_LAST_TRIGGER, reason).apply()
        val trigger = mapOf<String, Any?>("reason" to reason, "force" to force, "fake" to fake)
        if (!AutoWatchService.start(context, trigger)) prefs(context).edit().putLong(K_REFUSED_AT, now).apply()
    }

    /** Android says the headband came near ([near]) or went. A check when it came near, at most every 30 minutes. */
    fun onPresence(context: Context, near: Boolean, fake: String? = null) {
        val p = prefs(context)
        val now = System.currentTimeMillis()
        p.edit().putString(K_PRESENCE, if (near) "near" else "away").putLong(K_PRESENCE_AT, now).apply()
        if (!near) return
        if (fake == null && now - p.getLong(K_PRESENCE_CHECK_AT, 0L) < PRESENCE_EVERY_MS) return
        p.edit().putLong(K_PRESENCE_CHECK_AT, now).apply()
        requestCheck(context, "presence", fake = fake)
    }

    /** An answer from a notification button, or from the work page's launch. */
    fun answer(context: Context, id: String, answer: String) {
        AutoWatchService.answer(context, id, answer)
    }

    // ---- bedtime checks ------------------------------------------------------------------------------------------

    private fun bedtime(context: Context): List<Long> =
        (prefs(context).getString(K_BEDTIME, "") ?: "").split(",").mapNotNull { it.toLongOrNull() }.sorted()

    /** Keeps [at] (epoch ms, the next 24 hours) and arms the first one ahead. */
    fun arm(context: Context, at: List<Long>) {
        prefs(context).edit().putString(K_BEDTIME, at.joinToString(",")).apply()
        armNext(context)
    }

    fun armNext(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val tick = PendingIntent.getBroadcast(
            context,
            REQ_TICK,
            Intent(context, AutoReceiver::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val next = bedtime(context).firstOrNull { it > System.currentTimeMillis() }
        if (next == null) {
            am.cancel(tick)
            return
        }
        // inexact, and allowed in Doze: a few minutes late does not matter, and no exact-alarm permission is needed
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, tick)
    }

    fun onTick(context: Context) {
        try {
            requestCheck(context, "bedtime")
        } finally {
            armNext(context)
        }
    }

    fun onBoot(context: Context) {
        armNext(context)
        startObserving(context)
    }

    // ---- pairing ---------------------------------------------------------------------------------------------------

    private fun request(): AssociationRequest = AssociationRequest.Builder()
        .addDeviceFilter(BluetoothLeDeviceFilter.Builder().setNamePattern(NAMES).build())
        .setSingleDevice(true)
        .build()

    /** Opens the system's pairing dialog; the answer comes through [onAssociated] or [onPairResult]. */
    @Suppress("DEPRECATION")
    private fun pair(activity: Activity, result: MethodChannel.Result) {
        val cdm = cdm(activity)
        if (cdm == null) {
            result.success("this phone cannot let Android watch for the headband")
            return
        }
        pendingPair?.success("replaced by a newer try")
        pendingPair = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            cdm.associate(request(), activity.mainExecutor, object : CompanionDeviceManager.Callback() {
                override fun onAssociationPending(intentSender: IntentSender) = show(activity, intentSender)
                override fun onAssociationCreated(associationInfo: AssociationInfo) = onAssociated(activity, associationInfo)
                override fun onFailure(error: CharSequence?) = answerPair(error?.toString() ?: "Android would not start watching")
            })
        } else {
            cdm.associate(request(), object : CompanionDeviceManager.Callback() {
                @Deprecated("Android 12 and lower")
                override fun onDeviceFound(intentSender: IntentSender) = show(activity, intentSender)
                override fun onFailure(error: CharSequence?) = answerPair(error?.toString() ?: "no headband found")
            }, null)
        }
    }

    private fun show(activity: Activity, sender: IntentSender) {
        try {
            activity.startIntentSenderForResult(sender, REQUEST_PAIR, null, 0, 0, 0)
        } catch (e: Exception) {
            answerPair(e.message ?: "Android's own dialog did not open")
        }
    }

    private fun answerPair(answer: String) {
        val r = pendingPair ?: return
        pendingPair = null
        r.success(answer)
    }

    private fun onAssociated(context: Context, info: AssociationInfo) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val address = info.deviceMacAddress?.toString()?.uppercase()
        prefs(context).edit()
            .putInt(K_ID, info.id)
            .putString(K_ADDRESS, address)
            .putString(K_NAME, info.displayName?.toString())
            .apply()
        startObserving(context)
        answerPair("ok")
    }

    /** The dialog's answer (MainActivity.onActivityResult). Android 13+ answers through the callback as well. */
    @Suppress("DEPRECATION")
    fun onPairResult(context: Context, resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK) {
            answerPair("cancelled")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return // onAssociationCreated has it
        val scan = data?.getParcelableExtra<ScanResult>(CompanionDeviceManager.EXTRA_DEVICE)
        val address = scan?.device?.address
        if (address == null) {
            answerPair("no headband was chosen")
            return
        }
        prefs(context).edit().putString(K_ADDRESS, address.uppercase()).putString(K_NAME, scan.scanRecord?.deviceName).apply()
        startObserving(context)
        answerPair("ok")
    }

    /** Asks Android to watch for the paired headband (Android 12+). Harmless to repeat. */
    @Suppress("DEPRECATION")
    fun startObserving(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val cdm = cdm(context) ?: return
        val p = prefs(context)
        val address = p.getString(K_ADDRESS, null) ?: return
        val ok = try {
            if (Build.VERSION.SDK_INT >= 36) {
                val id = p.getInt(K_ID, -1)
                if (id >= 0) {
                    cdm.startObservingDevicePresence(ObservingDevicePresenceRequest.Builder().setAssociationId(id).build())
                } else {
                    cdm.startObservingDevicePresence(address)
                }
            } else {
                cdm.startObservingDevicePresence(address)
            }
            true
        } catch (_: Exception) {
            false
        }
        p.edit().putBoolean(K_OBSERVING, ok).apply()
    }

    @Suppress("DEPRECATION")
    private fun forget(context: Context) {
        val cdm = cdm(context)
        val p = prefs(context)
        val address = p.getString(K_ADDRESS, null)
        val id = p.getInt(K_ID, -1)
        try {
            if (cdm != null && address != null) {
                if (Build.VERSION.SDK_INT >= 36 && id >= 0) {
                    cdm.stopObservingDevicePresence(ObservingDevicePresenceRequest.Builder().setAssociationId(id).build())
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    cdm.stopObservingDevicePresence(address)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && id >= 0) cdm.disassociate(id) else cdm.disassociate(address)
            }
        } catch (_: Exception) {
        }
        p.edit().remove(K_ID).remove(K_ADDRESS).remove(K_NAME).remove(K_OBSERVING).remove(K_PRESENCE).remove(K_PRESENCE_AT).apply()
    }

    // ---- launches ----------------------------------------------------------------------------------------------

    /** Keeps the launch a notification tap asked for ([ACTION_OPEN]) and passes its answer on. Not from Recents. */
    fun takeIntent(context: Context, intent: Intent?): Boolean {
        if (intent?.action != ACTION_OPEN || !intent.hasExtra(EXTRA_LAUNCH)) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        launch = mapOf(
            "action" to intent.getStringExtra(EXTRA_LAUNCH),
            "quiet" to intent.getBooleanExtra(EXTRA_QUIET, true),
            "limitMin" to intent.getIntExtra(EXTRA_LIMIT, 0),
            "kind" to intent.getStringExtra(EXTRA_KIND),
        )
        val id = intent.getStringExtra(EXTRA_ID)
        val answer = intent.getStringExtra(EXTRA_ANSWER)
        if (id != null && answer != null) answer(context, id, answer)
        intent.removeExtra(EXTRA_LAUNCH) // taken once, also if the Activity is made again
        return true
    }
}

/** The bedtime checks' alarms and the notification buttons (explicit intents only). */
class AutoReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            AutoWatch.ACTION_TICK -> AutoWatch.onTick(context)
            AutoWatch.ACTION_ANSWER -> AutoWatch.answer(
                context,
                intent.getStringExtra(AutoWatch.EXTRA_ID) ?: "",
                intent.getStringExtra(AutoWatch.EXTRA_ANSWER) ?: "none",
            )
        }
    }
}

/** Alarms do not survive a restart or an update: arm the next bedtime check and the presence watch again. */
class AutoBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> AutoWatch.onBoot(context)
        }
    }
}
