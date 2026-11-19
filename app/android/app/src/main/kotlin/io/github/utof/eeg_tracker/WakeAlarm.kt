package io.github.utof.eeg_tracker

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The smart alarm's phone side (DECISIONS 233-236): a plain Android alarm clock (AlarmManager.setAlarmClock) at
 * the window's end, set from the screen at Start. It rings even if the app was closed by the phone in the night;
 * the live sleep model in the night recorder can only bring it forward ([bringForward]), never take it away.
 * While it rings it is set again 5 minutes ahead, so a ringer killed with the app rings again. Its state is kept
 * in SharedPreferences ("eeg_alarm"); every event is appended to files/alarms/rings.jsonl for the morning report.
 * Used from both Flutter engines through AlarmChannel, and from AlarmReceiver.
 */
object WakeAlarm {
    const val ACTION_RING = "io.github.utof.eeg_tracker.alarm.RING"
    const val ACTION_AWAKE = "io.github.utof.eeg_tracker.alarm.AWAKE"
    const val BY_END = "window end"
    const val BY_SMART = "smart"
    const val BY_BACKUP = "backup"
    private const val PREFS = "eeg_alarm"
    private const val REQ_RING = 4720
    private const val FALLBACK_ID = 4714
    const val SOUND_CHANNEL = "wake_alarm_sound"

    /** While it rings, the alarm is set again this far ahead: a ringer killed with the app rings again. */
    const val BACKUP_MS = 5L * 60 * 1000

    fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun now() = System.currentTimeMillis()

    /** Sets the alarm at [endMs] (replacing any earlier one) and how it will ring. */
    @Synchronized
    fun schedule(
        c: Context,
        endMs: Long,
        startMs: Long,
        volumes: List<Double>,
        everyS: Int,
        loudAfterS: Int,
        giveUpS: Int,
    ) {
        WakeService.stop(c) // a ringer still going from an earlier alarm
        prefs(c).edit().clear()
            .putLong("endMs", endMs)
            .putLong("startMs", startMs)
            .putLong("setMs", now())
            .putString("volumes", volumes.joinToString(","))
            .putInt("everyS", everyS)
            .putInt("loudAfterS", loudAfterS)
            .putInt("giveUpS", giveUpS)
            .commit()
        setClock(c, endMs, BY_END)
        event(c, endMs, "set", "windowMin" to ((endMs - startMs) / 60000).toInt())
    }

    /** Takes the alarm away (and stops it if it rings). */
    @Synchronized
    fun cancel(c: Context) {
        val p = prefs(c)
        val end = p.getLong("endMs", 0)
        alarmManager(c)?.cancel(ringIntent(c, BY_END))
        if (end > 0 && p.getLong("awakeMs", 0) == 0L && p.getLong("gaveUpMs", 0) == 0L) event(c, end, "cancel")
        p.edit().clear().commit()
        WakeService.stop(c)
        AlarmActivity.closeAll()
    }

    /**
     * The live model found a good moment: ring now. False when there is nothing to bring forward (no alarm, already
     * ringing, or already awake). Through the alarm clock as well, because an exact alarm may start the ringer's
     * foreground service from the background (Android 12+); without exact alarms the ringer is started directly.
     */
    @Synchronized
    fun bringForward(c: Context, reason: String): Boolean {
        val p = prefs(c)
        if (p.getLong("endMs", 0) == 0L || p.getLong("awakeMs", 0) > 0 || p.getLong("ringingSinceMs", 0) > 0) return false
        p.edit().putString("reason", reason).commit()
        if (canExact(c)) {
            setClock(c, now() + 300, BY_SMART)
        } else {
            WakeService.ring(c, BY_SMART)
        }
        return true
    }

    /** "I'm awake": the sound stops and the alarm is gone. */
    @Synchronized
    fun awake(c: Context) {
        val p = prefs(c)
        val end = p.getLong("endMs", 0)
        alarmManager(c)?.cancel(ringIntent(c, BY_END))
        if (end > 0 && p.getLong("awakeMs", 0) == 0L) {
            p.edit().putLong("awakeMs", now()).commit()
            event(c, end, "awake")
        }
        WakeService.stop(c)
        c.getSystemService(NotificationManager::class.java)?.cancel(FALLBACK_ID)
        AlarmActivity.closeAll()
    }

    /** After a reboot (once unlocked) or an app update: the alarm again, or the ring again if it was ringing. */
    fun restore(c: Context) {
        val p = prefs(c)
        val end = p.getLong("endMs", 0)
        if (end == 0L || p.getLong("awakeMs", 0) > 0 || p.getLong("gaveUpMs", 0) > 0) return
        if (p.getLong("ringingSinceMs", 0) > 0) {
            setClock(c, now() + 1000, BY_BACKUP)
        } else if (end > now()) {
            setClock(c, end, BY_END)
        }
    }

    fun setClock(c: Context, atMs: Long, by: String) {
        val am = alarmManager(c) ?: return
        val pi = ringIntent(c, by)
        if (canExact(c)) {
            val show = PendingIntent.getActivity(
                c,
                1,
                Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            am.setAlarmClock(AlarmManager.AlarmClockInfo(atMs, show), pi)
        } else {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pi) // may come minutes late; the screen says so
        }
    }

    fun cancelClock(c: Context) {
        alarmManager(c)?.cancel(ringIntent(c, BY_END))
    }

    private fun ringIntent(c: Context, by: String): PendingIntent = PendingIntent.getBroadcast(
        c,
        REQ_RING,
        Intent(c, AlarmReceiver::class.java).setAction(ACTION_RING).putExtra("by", by),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun alarmManager(c: Context) = c.getSystemService(AlarmManager::class.java)

    fun canExact(c: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager(c)?.canScheduleExactAlarms() == true

    fun canFullScreen(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return c.getSystemService(NotificationManager::class.java)?.canUseFullScreenIntent() != false
    }

    fun state(c: Context): Map<String, Any?> {
        val p = prefs(c)
        val audio = c.getSystemService(AudioManager::class.java)
        val nm = c.getSystemService(NotificationManager::class.java)
        val m = HashMap<String, Any?>()
        for (k in listOf("endMs", "startMs", "setMs", "ringingSinceMs", "loudSinceMs", "awakeMs", "gaveUpMs")) {
            m[k] = p.getLong(k, 0)
        }
        m["ringBy"] = p.getString("ringBy", null)
        m["reason"] = p.getString("reason", null)
        m["exact"] = canExact(c)
        m["fullScreen"] = canFullScreen(c)
        m["notifications"] = nm?.areNotificationsEnabled() != false
        m["alarmVolume"] = audio?.getStreamVolume(AudioManager.STREAM_ALARM)
        m["alarmVolumeMax"] = audio?.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        return m
    }

    /** One line of files/alarms/rings.jsonl; never throws. */
    fun event(c: Context, endMs: Long, event: String, vararg extra: Pair<String, Any?>) {
        try {
            val dir = File(c.filesDir, "alarms").apply { mkdirs() }
            val o = JSONObject().put("endMs", endMs).put("event", event).put("atMs", now())
            for ((k, v) in extra) o.put(k, v)
            File(dir, "rings.jsonl").appendText(o.toString() + "\n")
        } catch (_: Exception) {
        }
    }

    /** "06:30" for the notification's text. */
    fun hm(ms: Long): String = SimpleDateFormat("HH:mm", Locale.US).format(Date(ms))

    /**
     * Last resort when Android refuses the ringer's foreground service: a notification on a channel with the
     * phone's alarm sound, repeating until it is opened or "I'm awake" is tapped.
     */
    fun fallbackNotify(c: Context, text: String) {
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(SOUND_CHANNEL) == null) {
            val ch = NotificationChannel(SOUND_CHANNEL, "Alarm (fallback)", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "The alarm when the app cannot play its own sound"
            ch.setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
            )
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            nm.createNotificationChannel(ch)
        }
        val n = Notification.Builder(c, SOUND_CHANNEL)
            .setSmallIcon(R.drawable.ic_alarm)
            .setContentTitle("Time to wake up")
            .setContentText(text)
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(WakeService.fullScreenIntent(c))
            .setFullScreenIntent(WakeService.fullScreenIntent(c), true)
            .addAction(WakeService.awakeAction(c))
            .build()
        n.flags = n.flags or Notification.FLAG_INSISTENT
        nm.notify(FALLBACK_ID, n)
    }
}
