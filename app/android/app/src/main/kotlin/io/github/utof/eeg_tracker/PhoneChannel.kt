package io.github.utof.eeg_tracker

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
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
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "recordingsDir" -> result.success(recordingsDir())
                "snapshot" -> result.success(snapshot())
                "openSettings" -> result.success(openSettings(call.argument<String>("page") ?: "appDetails"))
                "exitReasons" -> result.success(exitReasons(call.argument<Number>("sinceMs")?.toLong() ?: 0L))
                "restartProcess" -> {
                    restartProcess(call.argument<Number>("delayMs")?.toInt() ?: 5000)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("phone", e.message, null)
        }
    }

    /** Android/media/<applicationId>/recordings: no storage permission needed, visible to adb and Syncthing. */
    @Suppress("DEPRECATION")
    private fun recordingsDir(): String? {
        val media = context.externalMediaDirs.firstOrNull { it != null } ?: return null
        val dir = File(media, "recordings")
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
