package io.github.utof.eeg_tracker

import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Reasons to try for a lost headband right now (lib/headband/reconnect_ladder.dart, DECISIONS 943): the phone was
 * unlocked, Bluetooth was switched on, the app came to the front, "Reconnect now" was tapped on the headband-lost
 * notice. Each engine that asks ("watch" on "eeg_tracker/hints"; today the recorder's) hears every hint as "hint"
 * with its name, until "unwatch"; "screenOn" says whether the screen is on. A hint only cuts a wait short in Dart:
 * nothing here touches Bluetooth, and nothing is registered while nobody watches.
 *
 * The hook for Android's companion-device "appeared" (not sent in this build, DECISIONS 944): call
 * `ReconnectHints.hint("cameNear")` from HeadbandPresenceService.
 */
object ReconnectHints {
    const val CHANNEL = "eeg_tracker/hints"

    /** The broadcast of the notice's "Reconnect now" button; only this app can send it (the receiver is not exported). */
    const val ACTION_RECONNECT_NOW = "io.github.utof.eeg_tracker.RECONNECT_NOW"

    private val main = Handler(Looper.getMainLooper())
    private val watchers = CopyOnWriteArraySet<MethodChannel>()
    private var receiver: BroadcastReceiver? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "watch" -> {
                    watchers.add(channel)
                    listen(app)
                    result.success(true)
                }
                "unwatch" -> {
                    forget(app, channel)
                    result.success(null)
                }
                "screenOn" -> result.success(app.getSystemService(PowerManager::class.java)?.isInteractive == true)
                else -> result.notImplemented()
            }
        }
    }

    /** The engine behind [messenger]'s channel is going away. */
    fun forgetAll(context: Context) {
        watchers.clear()
        unlisten(context.applicationContext)
    }

    /** Tells every watching engine; safe from any thread, and when nobody watches. */
    fun hint(what: String) {
        if (watchers.isEmpty()) return
        Log.i("eeg_tracker", "reconnect hint: $what")
        main.post {
            for (c in watchers) {
                try {
                    c.invokeMethod("hint", what)
                } catch (_: Exception) {
                    // that engine is gone
                }
            }
        }
    }

    /** Whether "Reconnect now" would reach anyone: the notice shows the button only then. */
    fun watched(): Boolean = watchers.isNotEmpty()

    /** The notice's button: a broadcast to this app only. */
    fun reconnectNowIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        4722,
        Intent(ACTION_RECONNECT_NOW).setPackage(context.packageName),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** The app's screen came to the front (EegApp registers this once per process). */
    fun trackActivities(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                if (activity is MainActivity) hint("appOpened")
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    @Synchronized
    private fun listen(app: Context) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_USER_PRESENT -> hint("unlocked")
                    BluetoothAdapter.ACTION_STATE_CHANGED ->
                        if (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_ON) {
                            hint("bluetoothOn")
                        }
                    ACTION_RECONNECT_NOW -> hint("reconnectNow")
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(ACTION_RECONNECT_NOW)
        }
        // the system's own broadcasts still arrive at a receiver that other apps cannot reach
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            app.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(r, filter)
        }
        receiver = r
    }

    private fun forget(app: Context, channel: MethodChannel) {
        watchers.remove(channel)
        if (watchers.isEmpty()) unlisten(app)
    }

    @Synchronized
    private fun unlisten(app: Context) {
        val r = receiver ?: return
        receiver = null
        try {
            app.unregisterReceiver(r)
        } catch (_: Exception) {
            // already let go
        }
    }
}
