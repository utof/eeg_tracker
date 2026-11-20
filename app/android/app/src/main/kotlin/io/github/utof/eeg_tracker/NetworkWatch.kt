package io.github.utof.eeg_tracker

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Android's word that a Wi-Fi network came, went or changed its addresses (lib/share/network_watch.dart; DECISIONS
 * 676), so Share on Wi-Fi tells the paired laptop where this phone is at once instead of at its next 5-minute
 * announcement. "watch" registers a callback for Wi-Fi networks, "unwatch" lets it go; each change calls "changed"
 * on the same channel, at most once a second. Reads only; ACCESS_NETWORK_STATE is granted at install.
 */
object NetworkWatch {
    const val CHANNEL = "eeg_tracker/network"

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        val watcher = Watcher(app, channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "watch" -> try {
                    watcher.start()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("network", e.message ?: e.javaClass.simpleName, null)
                }
                "unwatch" -> {
                    watcher.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private class Watcher(private val context: Context, private val channel: MethodChannel) {
        private val main = Handler(Looper.getMainLooper())
        private var callback: ConnectivityManager.NetworkCallback? = null
        private val tell = Runnable {
            try {
                channel.invokeMethod("changed", null)
            } catch (_: Exception) {
                // the screen's engine is gone: nobody to tell
            }
        }

        private fun changed() {
            main.removeCallbacks(tell)
            main.postDelayed(tell, 1000) // a reconnect sends several callbacks: one word once they settle
        }

        fun start() {
            if (callback != null) return
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = changed()
                override fun onLost(network: Network) = changed()
                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = changed()
            }
            val wifi = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
            cm.registerNetworkCallback(wifi, cb, main)
            callback = cb
        }

        fun stop() {
            val cb = callback ?: return
            callback = null
            main.removeCallbacks(tell)
            try {
                context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
                // already let go
            }
        }
    }
}
