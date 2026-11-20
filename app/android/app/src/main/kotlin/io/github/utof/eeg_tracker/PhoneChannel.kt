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
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import com.pravera.flutter_foreground_task.service.RestartReceiver
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Small phone facts and settings shortcuts for the screen and the recorder service ("eeg_tracker/phone"). */

/** An IPv4 address, for keeping addresses out of logcat. */
private val IPV4 = Regex("""\b\d{1,3}(\.\d{1,3}){3}\b""")
class PhoneChannel private constructor(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val NAME = "eeg_tracker/phone"

        /** Notification channel of the recorder (recorder_service.dart). */
        const val RECORDING_CHANNEL = "night_recording"

        fun register(messenger: BinaryMessenger, context: Context) {
            MethodChannel(messenger, NAME).setMethodCallHandler(PhoneChannel(context.applicationContext))
        }

        /**
         * Share on Wi-Fi (lib/share/isolate.dart) and the DIY board's datagrams: one Wi-Fi lock for the whole
         * process, held while any engine asks ([WifiHolders]: "screen" between nights, "recorder" during a night,
         * DECISIONS 612). Android drops it by itself when the process ends; an engine that ends lets go of its own.
         *
         * The mode (DECISIONS 610): WIFI_MODE_FULL_HIGH_PERF is the only mode that ever counted with the screen off
         * (Wi-Fi out of power save while connected). From Android 14 the platform turns it into
         * WIFI_MODE_FULL_LOW_LATENCY by default (AOSP WifiLockManager, device config wifi/high_perf_lock_deprecated,
         * default true), which only counts while the app is in front with the screen on. No app-held lock keeps
         * Android 14's Wi-Fi out of power save with the screen off; on Android 10-13 this one still does, and on 14
         * it helps while the app is open. Wi-Fi itself stays connected with the screen off unless a phone setting
         * turns it off (README "Share on Wi-Fi": the settings to check).
         */
        private var wifiLock: WifiManager.WifiLock? = null
        private val holders = WifiHolders()

        /** Every change of who holds it goes to logcat (tag eeg_tracker): a handful of lines a night. */
        @Synchronized
        fun holdWifi(context: Context, who: String, on: Boolean) {
            val before = holders.names()
            val want = holders.set(who, on)
            if (holders.names() != before) {
                Log.i("eeg_tracker", "wifi lock: $who ${if (on) "on" else "off"}, held for [${holders.names().joinToString()}]")
            }
            if (want) {
                if (wifiLock?.isHeld == true) return
                val wm = context.applicationContext.getSystemService(WifiManager::class.java) ?: return
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

        /** The last "no Wi-Fi address" note written to logcat, so a minute's look writes it only when it changes. */
        @Volatile
        private var lastNoWifi: String? = null

        /** Where the recorder writes; only an explicit Export copies anything out (NightExport.kt). */
        fun recordingsFolder(context: Context): File = File(context.filesDir, "recordings")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "recordingsDir" -> result.success(recordingsDir())
                "snapshot" -> result.success(snapshot())
                "battery" -> result.success(battery())
                "processAge" -> result.success(processAgeMs())
                "openSettings" -> result.success(openSettings(call.argument<String>("page") ?: "appDetails"))
                "exitReasons" -> result.success(exitReasons(call.argument<Number>("sinceMs")?.toLong() ?: 0L))
                "wifiLock" -> {
                    holdWifi(context, call.argument<String>("who") ?: "recorder", call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "wifiState" -> result.success(wifiState())
                "restartProcess" -> {
                    restartProcess(call.argument<Number>("delayMs")?.toInt() ?: 5000)
                    result.success(null)
                }
                "playCue" -> result.success(
                    playCue(call.argument<String>("path") ?: "", call.argument<Number>("gain")?.toFloat() ?: 0f),
                )
                "mediaVolume" -> result.success(mediaVolume())
                "inCall" -> result.success(inCall())
                "wifiNets" -> result.success(wifiNets())
                "storageSpace" -> result.success(storageSpace())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("phone", e.message, null)
        }
    }

    /** The storage the app's files live on: its size and what is free (the Storage page's context, DECISIONS 690-699). */
    private fun storageSpace(): Map<String, Long> {
        val fs = StatFs(context.filesDir.path)
        return mapOf("total" to fs.totalBytes, "free" to fs.availableBytes)
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

    /**
     * A call holds the phone's sound: Android's audio mode is not normal while a call rings, during a phone call, and
     * during a voice or video call in another app. The work session's chime waits meanwhile (DECISIONS 495). Needs no
     * permission, unlike the phone state.
     */
    private fun inCall(): Boolean? {
        val am = context.getSystemService(AudioManager::class.java) ?: return null
        return am.mode != AudioManager.MODE_NORMAL
    }

    /**
     * Share on Wi-Fi (lib/share/isolate.dart, DECISIONS rows 560-562): this phone's IPv4 addresses on Wi-Fi as
     * `192.168.1.5/24`, from Android's own view of its networks. Dart's interface list found none on the owner's
     * Xiaomi (HyperOS, Android 14) with a VPN on; ConnectivityManager knows the Wi-Fi network whatever a VPN does. A
     * VPN's network also lists TRANSPORT_WIFI (the network under it), so TRANSPORT_VPN is left out. WifiManager's
     * address (deprecated, no prefix) is the second source. `note` says what each source returned; when neither has
     * an address it also goes to logcat (tag eeg_tracker), once per change.
     */
    private fun wifiNets(): Map<String, Any?> {
        val nets = LinkedHashSet<String>()
        val seen = ArrayList<String>()
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            @Suppress("DEPRECATION")
            val all = cm?.allNetworks ?: emptyArray()
            if (all.isEmpty()) seen.add("no networks")
            for (n in all) {
                val caps = cm?.getNetworkCapabilities(n)
                val lp = cm?.getLinkProperties(n)
                val v4 = lp?.linkAddresses.orEmpty()
                    .filter { it.address is Inet4Address }
                    .map { "${it.address.hostAddress}/${it.prefixLength}" }
                val vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                val wifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                val kind = when {
                    vpn -> "vpn"
                    wifi -> "wifi"
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cell"
                    else -> "other"
                }
                seen.add("$kind ${lp?.interfaceName ?: "?"} ${if (v4.isEmpty()) "no IPv4" else v4.joinToString(" ")}")
                if (wifi && !vpn) nets.addAll(v4)
            }
        } catch (e: Exception) {
            seen.add("connectivity failed: ${e.javaClass.simpleName} ${e.message}")
        }
        if (nets.isEmpty()) {
            try {
                val wm = context.getSystemService(WifiManager::class.java)
                @Suppress("DEPRECATION")
                val ip = wm?.connectionInfo?.ipAddress ?: 0
                if (ip != 0) {
                    val a = "${ip and 0xff}.${(ip shr 8) and 0xff}.${(ip shr 16) and 0xff}.${(ip shr 24) and 0xff}"
                    nets.add(a)
                    seen.add("wifi manager $a")
                } else {
                    seen.add("wifi manager none")
                }
            } catch (e: Exception) {
                seen.add("wifi manager failed: ${e.javaClass.simpleName} ${e.message}")
            }
        }
        val note = seen.joinToString("; ")
        if (nets.isEmpty()) {
            // logcat keeps no network addresses (DECISIONS 757): the note says which source saw what kind of address
            if (note != lastNoWifi) Log.w("eeg_tracker", "share: no Wi-Fi IPv4 address from Android: ${note.replace(IPV4, "#.#.#.#")}")
            lastNoWifi = note
        } else {
            lastNoWifi = null
        }
        return mapOf("nets" to nets.toList(), "note" to note)
    }

    /**
     * The phone's Wi-Fi now, for the night's log (lib/recorder/wifi_watch.dart, DECISIONS 611), read every 10 s by
     * the recorder: switched on, on a Wi-Fi network (not a VPN over it), link speed, signal and frequency, which
     * network the default route uses ("none" also when Android blocks the app's network), the screen, Doze and this
     * process's Wi-Fi lock. The network's name and address are never read (no location permission is needed or used).
     */
    private fun wifiState(): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        val wm = context.getSystemService(WifiManager::class.java)
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val pm = context.getSystemService(PowerManager::class.java)
        m["enabled"] = try {
            wm?.isWifiEnabled
        } catch (e: Exception) {
            null
        }
        var connected = false
        var info: WifiInfo? = null
        try {
            @Suppress("DEPRECATION")
            for (n in cm?.allNetworks ?: emptyArray()) {
                val caps = cm?.getNetworkCapabilities(n) ?: continue
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                connected = true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info = caps.transportInfo as? WifiInfo
                break
            }
            val default = cm?.let { c -> c.activeNetwork?.let { c.getNetworkCapabilities(it) } }
            m["route"] = WifiFacts.route(default?.let { transports(it) })
        } catch (e: Exception) {
            m["route"] = "?"
        }
        if (connected) {
            val wi = info ?: try {
                @Suppress("DEPRECATION")
                wm?.connectionInfo
            } catch (e: Exception) {
                null
            }
            if (wi != null) {
                m["linkMbps"] = WifiFacts.linkMbps(wi.linkSpeed)
                m["rssi"] = WifiFacts.rssi(wi.rssi)
                m["freqMhz"] = WifiFacts.freqMhz(wi.frequency)
            }
        }
        m["connected"] = connected
        m["screenOn"] = pm?.isInteractive
        m["idle"] = pm?.isDeviceIdleMode
        m["lock"] = wifiLock?.isHeld == true
        return m
    }

    private fun transports(c: NetworkCapabilities): Set<String> = buildSet {
        if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("wifi")
        if (c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("cell")
        if (c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("vpn")
        if (c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("ethernet")
        if (c.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) add("bluetooth")
    }

    /** A VPN applies to this app (its Always-on and lockdown settings cannot be read by an app since Android 12). */
    private fun vpnActive(): Boolean? = try {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        @Suppress("DEPRECATION")
        (cm?.allNetworks ?: emptyArray()).any { cm?.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
    } catch (e: Exception) {
        null
    }

    /**
     * Android's old Wi-Fi sleep policy (0: Wi-Fi sleeps with the screen off, 1: not while charging, 2: never); the
     * platform no longer uses it, Xiaomi's "Keep Wi-Fi on during sleep" may still write it (not verified). Null when
     * the phone does not have it.
     */
    private fun wifiSleepPolicy(): Int? = try {
        @Suppress("DEPRECATION")
        WifiFacts.sleepPolicy(Settings.Global.getInt(context.contentResolver, Settings.Global.WIFI_SLEEP_POLICY, -1))
    } catch (e: Exception) {
        null
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
        m["targetSdk"] = context.applicationInfo.targetSdkVersion
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
        m["wifiSleepPolicy"] = wifiSleepPolicy()
        m["vpnActive"] = vpnActive()
        return m
    }

    /**
     * The phone battery for the night's `.log`, read once a minute by the recorder, and for the battery samples of
     * the Battery page (lib/logs/metrics.dart, DECISIONS 715). Two cheap reads of BatteryManager plus the sticky
     * ACTION_BATTERY_CHANGED intent (no receiver is registered, so nothing is held or woken). A property the phone
     * does not support comes back as Integer.MIN_VALUE and is sent as null. CURRENT_NOW has a different sign on
     * different phones; the app only logs it. Also the screen (interactive or not), Doze, the voltage and this
     * process's CPU time in ms (Process.getElapsedCpuTime: every thread of every engine of the app).
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
            val mv = sticky.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)
            if (mv > 0) m["voltageMv"] = mv
            if (m["percent"] == null) {
                val level = sticky.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = sticky.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) m["percent"] = level * 100 / scale
            }
        }
        val pm = context.getSystemService(PowerManager::class.java)
        m["screenOn"] = pm?.isInteractive
        m["idle"] = pm?.isDeviceIdleMode
        m["cpuMs"] = Process.getElapsedCpuTime()
        return m
    }

    /** How long ago Android started this process, in ms (the app's start-up time, lib/logs/engine.dart). */
    private fun processAgeMs(): Long = SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()

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
            "wifi" -> listOf(Intent(Settings.ACTION_WIFI_SETTINGS))
            "vpn" -> listOf(Intent(Settings.ACTION_VPN_SETTINGS))
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
