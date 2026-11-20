package io.github.utof.eeg_tracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * The phone's own hardware step counter (Sensor.TYPE_STEP_COUNTER: steps since the phone booted), for the night
 * recorder's once-a-minute `phone steps` line (lib/recorder/phone_steps.dart, DECISIONS 800-809). Used from the recorder's
 * Flutter engine through PhoneChannel.kt; the latest value is kept here, the recorder asks for it every 10 seconds.
 */
object StepCounter : SensorEventListener {
    @Volatile
    private var latest: Long? = null
    private var manager: SensorManager? = null

    /** Registers the listener; `on`, `no permission` (Android 10+ without Physical activity) or `no sensor`. */
    @Synchronized
    fun start(context: Context): String {
        if (Build.VERSION.SDK_INT >= 29 &&
            context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED
        ) {
            return "no permission"
        }
        stop()
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return "no sensor"
        val sensor = sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return "no sensor"
        latest = null
        val ok = try {
            sm.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL, Handler(Looper.getMainLooper()))
        } catch (e: SecurityException) {
            return "no permission"
        }
        if (!ok) return "no sensor"
        manager = sm
        return "on"
    }

    /** Steps since boot as of the last sensor event; null before the first one. */
    fun read(): Long? = latest

    @Synchronized
    fun stop() {
        manager?.unregisterListener(this)
        manager = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.values.isNotEmpty()) latest = event.values[0].toLong()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
