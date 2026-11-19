package io.github.utof.eeg_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import java.io.File

/**
 * The smart alarm's ringer (DECISIONS 234-235): a foreground service of type mediaPlayback, started by the alarm
 * clock (WakeAlarm.kt) at the window's end, or earlier when the live sleep model brought it forward. It plays the
 * nap coach's three rising notes (files/alarm/wake-notes.wav, made by the app) on the alarm stream, a little louder
 * every 20 s; after 3 minutes without "I'm awake" the phone's own alarm sound, looping at full alarm volume, with
 * vibration; after 10 more minutes it gives up and leaves a notification. Its notification opens AlarmActivity over
 * the lock screen (a full-screen intent) and has "I'm awake". Nothing here depends on Flutter or the recorder.
 */
class WakeService : Service() {
    companion object {
        private const val TAG = "EegWake"
        private const val ACTION_RING = "io.github.utof.eeg_tracker.wake.RING"
        private const val NOTIFICATION_ID = 4713
        private const val GAVE_UP_ID = 4715
        const val CHANNEL = "wake_alarm"

        @Volatile
        private var instance: WakeService? = null

        val ringing: Boolean get() = instance != null

        fun ring(c: Context, by: String) {
            val i = Intent(c, WakeService::class.java).setAction(ACTION_RING).putExtra("by", by)
            c.startForegroundService(i)
        }

        fun stop(c: Context) {
            val s = instance
            if (s != null) {
                Handler(Looper.getMainLooper()).post { s.finish() }
            } else {
                c.stopService(Intent(c, WakeService::class.java))
            }
        }

        fun fullScreenIntent(c: Context): PendingIntent = PendingIntent.getActivity(
            c,
            2,
            Intent(c, AlarmActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        fun awakeAction(c: Context): Notification.Action {
            val awake = PendingIntent.getBroadcast(
                c,
                3,
                Intent(c, AlarmReceiver::class.java).setAction(WakeAlarm.ACTION_AWAKE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Action.Builder(Icon.createWithResource(c, R.drawable.ic_alarm), "I'm awake", awake).build()
        }

        /** The words under "Time to wake up": the live model's reason, or the window's end. */
        fun reasonText(c: Context): String {
            val p = WakeAlarm.prefs(c)
            val reason = p.getString("reason", null)
            if (reason != null && p.getString("ringBy", WakeAlarm.BY_SMART) != WakeAlarm.BY_END) return reason
            val end = p.getLong("endMs", 0)
            return if (end > 0) "The end of your window, ${WakeAlarm.hm(end)}." else "Your alarm."
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var notes: MediaPlayer? = null
    private var loud: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var sinceMs = 0L
    private var step = 0
    private var loudOn = false
    private var finished = false

    private val alarmAudio: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private val tick = object : Runnable {
        override fun run() {
            if (finished) return
            val p = WakeAlarm.prefs(this@WakeService)
            val loudAfter = p.getInt("loudAfterS", 180) * 1000L
            val giveUp = p.getInt("giveUpS", 600) * 1000L
            val every = p.getInt("everyS", 20).coerceAtLeast(1) * 1000L
            val t = WakeAlarm.now() - sinceMs
            when {
                t >= loudAfter + giveUp -> {
                    gaveUp()
                    return
                }
                t >= loudAfter -> if (!loudOn) startLoud()
                else -> {
                    val due = (t / every).toInt()
                    while (step <= due && !loudOn) {
                        playNote(step)
                        step++
                    }
                }
            }
            handler.postDelayed(this, 500)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // the foreground start comes first, always: Android allows 5 s after startForegroundService
        try {
            foreground()
        } catch (e: Exception) {
            Log.w(TAG, "foreground refused: $e")
            WakeAlarm.fallbackNotify(this, reasonText(this))
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_RING) {
            finish()
            return START_NOT_STICKY
        }
        val by = intent.getStringExtra("by") ?: WakeAlarm.BY_END
        val p = WakeAlarm.prefs(this)
        val end = p.getLong("endMs", 0)
        if (end == 0L || p.getLong("awakeMs", 0) > 0 || p.getLong("gaveUpMs", 0) > 0) {
            finish() // taken away or done meanwhile: a stale alarm
            return START_NOT_STICKY
        }
        instance = this
        if (sinceMs == 0L) {
            val earlier = p.getLong("ringingSinceMs", 0)
            if (earlier > 0) {
                sinceMs = earlier // a ringer that was killed: go on where it was
                loudOn = false
            } else {
                sinceMs = WakeAlarm.now()
                p.edit().putLong("ringingSinceMs", sinceMs).putString("ringBy", by).commit()
                WakeAlarm.event(this, end, "ring", "by" to by)
            }
            Log.i(TAG, "ringing ($by)")
            wakeLock = getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "eeg_tracker:wake")
                ?.apply {
                    setReferenceCounted(false)
                    acquire(20L * 60 * 1000)
                }
            handler.post(tick)
        }
        WakeAlarm.setClock(this, WakeAlarm.now() + WakeAlarm.BACKUP_MS, WakeAlarm.BY_BACKUP)
        return START_NOT_STICKY
    }

    private fun foreground() {
        channel()
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_alarm)
            .setContentTitle("Time to wake up")
            .setContentText(reasonText(this))
            .setCategory(Notification.CATEGORY_ALARM)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(fullScreenIntent(this))
            .setFullScreenIntent(fullScreenIntent(this), true)
            .addAction(awakeAction(this))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            n.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n.build())
        }
    }

    private fun channel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val c = NotificationChannel(CHANNEL, "Alarm", NotificationManager.IMPORTANCE_HIGH)
        c.description = "The smart alarm's wake-up, with I'm awake"
        c.setSound(null, null) // the ringer plays its own rising sound on the alarm stream
        c.enableVibration(false)
        c.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(c)
    }

    private fun volumes(): List<Float> = (WakeAlarm.prefs(this).getString("volumes", null) ?: "0.175")
        .split(",").mapNotNull { it.trim().toFloatOrNull()?.coerceIn(0f, 1f) }.ifEmpty { listOf(0.175f) }

    /** One step of the rising notes; without the notes file, the loud alarm at once (never silent). */
    private fun playNote(k: Int) {
        val v = volumes().let { it[minOf(k, it.size - 1)] }
        try {
            val mp = notes ?: MediaPlayer().apply {
                setAudioAttributes(alarmAudio)
                setDataSource(File(filesDir, "alarm/wake-notes.wav").path)
                prepare()
            }.also { notes = it }
            mp.setVolume(v, v)
            mp.seekTo(0)
            mp.start()
            Log.i(TAG, "note ${k + 1} at $v")
        } catch (e: Exception) {
            Log.w(TAG, "notes failed: $e")
            startLoud()
        }
    }

    private fun startLoud() {
        if (loudOn) return
        loudOn = true
        val p = WakeAlarm.prefs(this)
        if (p.getLong("loudSinceMs", 0) == 0L) {
            p.edit().putLong("loudSinceMs", WakeAlarm.now()).commit()
            WakeAlarm.event(this, p.getLong("endMs", 0), "loud")
        }
        notes?.let { if (it.isPlaying) it.pause() }
        val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        try {
            loud = MediaPlayer().apply {
                setAudioAttributes(alarmAudio)
                setDataSource(this@WakeService, uri)
                isLooping = true
                setVolume(1f, 1f)
                prepare()
                start()
            }
            Log.i(TAG, "loud: the phone's alarm sound")
        } catch (e: Exception) {
            Log.w(TAG, "alarm sound failed ($e); the notes, loud and looping")
            try {
                notes?.apply {
                    isLooping = true
                    setVolume(1f, 1f)
                    seekTo(0)
                    start()
                }
            } catch (_: Exception) {
            }
        }
        vibrate()
    }

    private fun vibrate() {
        try {
            val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Vibrator::class.java)
            }
            v?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 800, 800), 0), alarmAudio)
            vibrator = v
        } catch (_: Exception) {
        }
    }

    private fun gaveUp() {
        val p = WakeAlarm.prefs(this)
        val since = sinceMs
        p.edit().putLong("gaveUpMs", WakeAlarm.now()).commit()
        WakeAlarm.event(this, p.getLong("endMs", 0), "gave up")
        WakeAlarm.cancelClock(this)
        Log.i(TAG, "gave up")
        finish()
        val minutes = (WakeAlarm.now() - since) / 60000
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.notify(
            GAVE_UP_ID,
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_alarm)
                .setContentTitle("Alarm stopped")
                .setContentText("No \"I'm awake\" in $minutes minutes, so the alarm stopped.")
                .setCategory(Notification.CATEGORY_ALARM)
                .setContentIntent(
                    PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
                )
                .setAutoCancel(true)
                .build(),
        )
    }

    /** Stops every sound and the service (from "I'm awake", Alarm off, or giving up). */
    fun finish() {
        if (finished) return
        finished = true
        handler.removeCallbacks(tick)
        release()
        if (instance === this) instance = null
        AlarmActivity.closeAll()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun release() {
        for (mp in listOf(notes, loud)) {
            try {
                mp?.stop()
            } catch (_: Exception) {
            }
            mp?.release()
        }
        notes = null
        loud = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    override fun onDestroy() {
        if (!finished) {
            finished = true
            handler.removeCallbacks(tick)
            release()
            if (instance === this) instance = null
        }
        super.onDestroy()
    }
}
