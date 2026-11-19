package io.github.utof.eeg_tracker

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import com.pravera.flutter_foreground_task.service.RestartReceiver
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Small phone facts and settings shortcuts for the screen and the recorder service ("eeg_tracker/phone"). */
class PhoneChannel private constructor(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val NAME = "eeg_tracker/phone"

        /** Notification channel of the recorder (recorder_service.dart). */
        const val RECORDING_CHANNEL = "night_recording"

        fun register(messenger: BinaryMessenger, context: Context) {
            MethodChannel(messenger, NAME).setMethodCallHandler(PhoneChannel(context.applicationContext))
        }

        /**
         * Share on Wi-Fi during a night (lib/share/isolate.dart): one Wi-Fi lock for the whole process, so
         * Wi-Fi keeps answering the laptop while the screen is off. Not counted: "on" twice is held once, "off"
         * always lets go. Android drops it by itself when the process ends.
         */
        private var wifiLock: WifiManager.WifiLock? = null

        @Synchronized
        fun holdWifi(context: Context, on: Boolean) {
            if (on) {
                if (wifiLock?.isHeld == true) return
                val wm = context.applicationContext.getSystemService(WifiManager::class.java) ?: return
                // HIGH_PERF is the one mode that also counts with the screen off; Android 14 marks it deprecated
                // and some builds treat it as LOW_LATENCY (screen on only). Harmless either way.
                @Suppress("DEPRECATION")
                val lock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "eeg_tracker:share")
                lock.setReferenceCounted(false)
                lock.acquire()
                wifiLock = lock
            } else {
                wifiLock?.let { if (it.isHeld) it.release() }
                wifiLock = null
            }
        }

        /** Where the recorder writes; only an explicit Export copies anything out (NightExport.kt). */
        fun recordingsFolder(context: Context): File = File(context.filesDir, "recordings")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "recordingsDir" -> result.success(recordingsDir())
                "snapshot" -> result.success(snapshot())
                "battery" -> result.success(battery())
                "openSettings" -> result.success(openSettings(call.argument<String>("page") ?: "appDetails"))
                "exitReasons" -> result.success(exitReasons(call.argument<Number>("sinceMs")?.toLong() ?: 0L))
                "wifiLock" -> {
                    holdWifi(context, call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "restartProcess" -> {
                    restartProcess(call.argument<Number>("delayMs")?.toInt() ?: 5000)
                    result.success(null)
                }
                "playCue" -> result.success(
                    playCue(call.argument<String>("path") ?: "", call.argument<Number>("gain")?.toFloat() ?: 0f),
                )
                "mediaVolume" -> result.success(mediaVolume())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("phone", e.message, null)
        }
    }

    /**
     * Plays a short sound file once on the media stream at [gain] (0-1 of the media volume) and releases the player
     * when it ends: the lucid dream cue (lucid/bell.dart), from the screen's engine in the evening practice and from
     * the recorder service's engine at night, so both are the same sound at the same loudness. False when the file is
     * missing or the player refused it.
     */
    private fun playCue(path: String, gain: Float): Boolean {
        if (path.isEmpty() || !File(path).isFile) return false
        val g = gain.coerceIn(0f, 1f)
        val mp = MediaPlayer()
        return try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            mp.setDataSource(path)
            mp.setVolume(g, g)
            mp.setOnCompletionListener { it.release() }
            mp.setOnErrorListener { p, _, _ ->
                p.release()
                true
            }
            mp.prepare()
            mp.start()
            true
        } catch (e: Exception) {
            mp.release()
            false
        }
    }

    /** The media stream's volume step and its largest step (the cue plays as a share of it). */
    private fun mediaVolume(): Map<String, Any?> {
        val am = context.getSystemService(AudioManager::class.java)
        return mapOf(
            "volume" to am?.getStreamVolume(AudioManager.STREAM_MUSIC),
            "max" to am?.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
        )
    }

    /** The app's private folder (filesDir/recordings): other apps cannot read it, Android encrypts it. */
    private fun recordingsDir(): String? {
        val dir = recordingsFolder(context)
        dir.mkdirs()
        return if (dir.isDirectory) dir.absolutePath else null
    }

    private fun snapshot(): Map<String, Any?> {
        val pm = context.getSystemService(PowerManager::class.java)
        val m = HashMap<String, Any?>()
        m["sdkInt"] = Build.VERSION.SDK_INT
        m["ignoringBatteryOptimizations"] = pm?.isIgnoringBatteryOptimizations(context.packageName)
        m["powerSaveMode"] = pm?.isPowerSaveMode
        m["deviceIdle"] = pm?.isDeviceIdleMode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            m["backgroundRestricted"] = context.getSystemService(ActivityManager::class.java)?.isBackgroundRestricted
            m["standbyBucket"] = context.getSystemService(UsageStatsManager::class.java)?.appStandbyBucket
        }
        m["notificationsEnabled"] = notificationsEnabled()
        m["bluetoothOn"] = bluetoothOn()
        m["hyperOs"] = getprop("ro.mi.os.version.name")
        m["miui"] = getprop("ro.miui.ui.version.name")
        return m
    }

    /**
     * The phone battery for the night's `.log`, read once a minute by the recorder. Two cheap reads of
     * BatteryManager plus the sticky ACTION_BATTERY_CHANGED intent (no receiver is registered, so nothing
     * is held or woken). A property the phone does not support comes back as Integer.MIN_VALUE and is sent
     * as null. CURRENT_NOW has a different sign on different phones; the app only logs it.
     */
    private fun battery(): Map<String, Any?> {
        val bm = context.getSystemService(BatteryManager::class.java)
        fun prop(id: Int): Int? = bm?.getIntProperty(id)?.takeIf { it != Int.MIN_VALUE }
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val m = HashMap<String, Any?>()
        m["percent"] = prop(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 }
        m["chargeUah"] = prop(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        m["currentUa"] = prop(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        if (sticky != null) {
            val plugged = sticky.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            m["plugged"] = when {
                plugged and BatteryManager.BATTERY_PLUGGED_AC != 0 -> "ac"
                plugged and BatteryManager.BATTERY_PLUGGED_USB != 0 -> "usb"
                plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS != 0 -> "wireless"
                plugged != 0 -> "dock"
                else -> "no"
            }
            val tenths = sticky.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            if (tenths != Int.MIN_VALUE) m["tempC"] = tenths / 10.0
            if (m["percent"] == null) {
                val level = sticky.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = sticky.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) m["percent"] = level * 100 / scale
            }
        }
        return m
    }

    private fun notificationsEnabled(): Boolean {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return true
        if (!nm.areNotificationsEnabled()) return false
        val channel = nm.getNotificationChannel(RECORDING_CHANNEL) ?: return true // made on the first start
        return channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun bluetoothOn(): Boolean? = try {
        context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled
    } catch (e: SecurityException) {
        null
    }

    private fun getprop(key: String): String? = try {
        val p = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        out.ifEmpty { null }
    } catch (e: Exception) {
        null
    }

    private fun openSettings(page: String): Boolean {
        val pkg = context.packageName
        val packageUri = Uri.parse("package:$pkg")
        val candidates = when (page) {
            "batteryOptimization" -> listOf(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            )
            "notifications" -> listOf(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, pkg),
            )
            "bluetooth" -> listOf(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
            "batterySaver" -> listOf(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
            // Xiaomi screens: component names from open-source helpers, not checked on HyperOS (research note 5).
            "xiaomiAutostart" -> listOf(
                Intent().setComponent(
                    ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
                ),
                Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
            )
            "xiaomiBatterySaver" -> listOf(
                Intent().setComponent(
                    ComponentName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"),
                ).putExtra("package_name", pkg).putExtra("package_label", "EEG Tracker"),
            )
            else -> emptyList()
        } + Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                return true
            } catch (e: Exception) {
                // try the next screen
            }
        }
        return false
    }

    private fun exitReasons(sinceMs: Long): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        return am.getHistoricalProcessExitReasons(context.packageName, 0, 20)
            .filter { it.timestamp >= sinceMs }
            .map {
                val desc = it.description?.let { d -> " ($d)" } ?: ""
                "${fmt.format(Date(it.timestamp))} ${reasonName(it.reason)} status ${it.status} " +
                    "importance ${it.importance}$desc"
            }
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit-self"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low-memory"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash-native"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission-change"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive-resource-usage"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user-requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user-stopped"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency-died"
        ApplicationExitInfo.REASON_OTHER -> "other"
        else -> "reason-$reason"
    }

    /**
     * The recorder found the BrainBit SDK wedged (a call blocked). Like the laptop recorder, the cure is a
     * fresh process: arm the foreground-task plugin's restart alarm, then end this process.
     */
    private fun restartProcess(delayMs: Int) {
        RestartReceiver.setRestartAlarm(context, delayMs)
        Handler(Looper.getMainLooper()).postDelayed({ Process.killProcess(Process.myPid()) }, 300)
    }
}
