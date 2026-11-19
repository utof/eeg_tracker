package io.github.utof.eeg_tracker

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Where the phone's media sound goes now (lib/sound/audio_route.dart; DECISIONS 424): "eeg_tracker/audio_route"
 * answers "current" with {route, type, device}, and "eeg_tracker/audio_route/changes" sends the same map whenever it
 * changes while someone listens. Feedback sessions warn and record it: Bluetooth sound comes 0.25-0.5 s late.
 *
 * From Android 13 the phone says itself which device media plays on (getAudioDevicesForAttributes). Before that,
 * the connected output Android's media routing prefers: Bluetooth, then wired or USB, then the speaker. Reads
 * only; nothing here changes the route or needs a permission.
 */
object AudioRoute {
    const val CHANNEL = "eeg_tracker/audio_route"
    const val EVENTS = "eeg_tracker/audio_route/changes"

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> try {
                    result.success(current(app))
                } catch (e: Exception) {
                    result.error("audio_route", e.message ?: e.javaClass.simpleName, null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENTS).setStreamHandler(Watcher(app))
    }

    fun current(context: Context): Map<String, Any?> {
        val am = context.getSystemService(AudioManager::class.java) ?: return mapOf("route" to "unknown")
        val device = mediaDevice(am) ?: return mapOf("route" to "unknown")
        return mapOf(
            "route" to kind(device.type),
            "type" to typeName(device.type),
            "device" to (device.productName?.toString() ?: ""),
        )
    }

    private fun mediaDevice(am: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
            am.getAudioDevicesForAttributes(media).firstOrNull()?.let { return it }
        }
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).minByOrNull { rank(it.type) }
    }

    private val bluetooth = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_HEARING_AID,
    )

    // LE Audio (Android 12+): the constants are compile-time numbers, harmless on older phones
    private val bluetoothLe = setOf(
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST,
        33, // TYPE_BLE_HEARING_AID (Android 15)
    )

    private val wired = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        AudioDeviceInfo.TYPE_AUX_LINE,
        AudioDeviceInfo.TYPE_DOCK,
        31, // TYPE_DOCK_ANALOG (Android 12)
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        29, // TYPE_HDMI_EARC (Android 12)
    )

    private val speaker = setOf(
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
    )

    private fun kind(type: Int): String = when (type) {
        in bluetoothLe -> "bluetoothLe"
        in bluetooth -> "bluetooth"
        in wired -> "wired"
        in speaker -> "speaker"
        else -> "other"
    }

    /** Lower is preferred for media when several outputs are connected (before Android 13). */
    private fun rank(type: Int): Int = when {
        type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 4 // calls, not media
        type in bluetooth || type in bluetoothLe -> 0
        type in wired -> 1
        type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER || type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> 2
        type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 3
        else -> 5
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "sco"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble_headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble_speaker"
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> "ble_broadcast"
        33 -> "ble_hearing_aid"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb_device"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb_accessory"
        AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL, AudioDeviceInfo.TYPE_AUX_LINE -> "line"
        AudioDeviceInfo.TYPE_DOCK, 31 -> "dock"
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, 29 -> "hdmi"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> "type_$type"
    }

    /**
     * Sends the route while someone listens: at once, after a device comes or goes (once it has settled), and every
     * 5 s (the media output switcher can move the sound without a device coming or going). Only changes are sent.
     */
    private class Watcher(private val context: Context) : EventChannel.StreamHandler {
        private val main = Handler(Looper.getMainLooper())
        private var sink: EventChannel.EventSink? = null
        private var last: Map<String, Any?>? = null
        private val check = Runnable { send() }
        private val poll = object : Runnable {
            override fun run() {
                send()
                main.postDelayed(this, 5000)
            }
        }
        private val devices = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = settle()
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = settle()
        }

        private fun settle() {
            main.removeCallbacks(check)
            main.postDelayed(check, 400)
        }

        private fun send() {
            val s = sink ?: return
            val now = try {
                current(context)
            } catch (e: Exception) {
                mapOf("route" to "unknown")
            }
            if (now == last) return
            last = now
            s.success(now)
        }

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
            last = null
            send()
            context.getSystemService(AudioManager::class.java)?.registerAudioDeviceCallback(devices, main)
            main.postDelayed(poll, 5000)
        }

        override fun onCancel(arguments: Any?) {
            context.getSystemService(AudioManager::class.java)?.unregisterAudioDeviceCallback(devices)
            main.removeCallbacks(check)
            main.removeCallbacks(poll)
            sink = null
        }
    }
}
