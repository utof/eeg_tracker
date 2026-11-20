package io.github.utof.eeg_tracker

/**
 * Who wants the phone's Wi-Fi kept awake (PhoneChannel.kt keeps one Wi-Fi lock for the process). Each Flutter engine
 * asks under its own name: "screen" for the app's own server between nights, "recorder" for the recorder's service
 * during a night (Share on Wi-Fi, the DIY board's datagrams). The lock is held while anyone asks, so the hand-over at
 * a night's start or Stop, where the two overlap or come in either order, never drops it (DECISIONS 612). Before,
 * one "off" from either side let go of the other's lock. Pure Kotlin, for the JVM test.
 */
class WifiHolders {
    private val holders = LinkedHashSet<String>()

    /** [who] asks ([on]) or lets go; true when the lock should be held afterwards. */
    @Synchronized
    fun set(who: String, on: Boolean): Boolean {
        if (on) holders.add(who) else holders.remove(who)
        return holders.isNotEmpty()
    }

    @Synchronized
    fun names(): List<String> = holders.toList()
}

/** The words and the plausibility checks of the night's Wi-Fi line (lib/recorder/wifi_watch.dart), without Android. */
object WifiFacts {
    /**
     * The default network's transports ("wifi", "cell", "vpn", "ethernet", ...) in the line's words. Null: Android
     * has no default network for the app (none at all, or the app's network is blocked).
     */
    fun route(transports: Set<String>?): String {
        if (transports == null) return "none"
        val base = when {
            "wifi" in transports -> "wifi"
            "cell" in transports -> "cell"
            "ethernet" in transports -> "ethernet"
            else -> null
        }
        return when {
            "vpn" in transports -> if (base != null) "vpn over $base" else "vpn"
            else -> base ?: "other"
        }
    }

    /** WifiInfo's link speed; -1 is "unknown". */
    fun linkMbps(v: Int): Int? = v.takeIf { it > 0 }

    /** WifiInfo's signal; -127 is "invalid". */
    fun rssi(v: Int): Int? = v.takeIf { it in -126..-1 }

    fun freqMhz(v: Int): Int? = v.takeIf { it > 0 }

    /** Settings.Global.WIFI_SLEEP_POLICY: 0 sleeps with the screen off, 1 not while charging, 2 never; else unset. */
    fun sleepPolicy(v: Int): Int? = v.takeIf { it in 0..2 }
}
