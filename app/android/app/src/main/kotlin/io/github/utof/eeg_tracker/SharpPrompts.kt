package io.github.utof.eeg_tracker

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The sharp-hours questions (DECISIONS rows 281-283): rings the moments the app's Dart side drew
 * (lib/sharp/schedule.dart) as a notification "How sharp do you feel?", and logs what happened to each moment in
 * files/sharp-hours/prompts.jsonl.
 *
 * - No exact-alarm permission. Each moment is armed twice: a window alarm (setWindow, 10 minutes: on time while
 *   the phone is in use) and a backup 10 minutes later that may ring in Doze (setAndAllowWhileIdle); whichever
 *   rings first asks, the other finds the moment handled and does nothing. (setAndAllowWhileIdle alone gets a
 *   window of up to an hour on Android 14: seen on the emulator, 2026-11-19.) A few minutes do not matter, since
 *   an answer is about the moment it is given. Only the next moment is armed: the moments ahead are kept in the
 *   app's preferences, and each ring arms the next. The app re-arms at every start and after a phone restart
 *   (SharpBootReceiver).
 * - A moment is skipped (and logged) while the night recorder runs, a sound session holds the phone, a session
 *   screen keeps the screen on, or notifications are off; dropped as "late" when it rings over an hour late
 *   (HyperOS can hold alarms back). The notification goes away by itself after an hour; "In 15 min" postpones it.
 * The same planning values are in lib/sharp/schedule.dart (SharpRule).
 */
object SharpPrompts {
    const val CHANNEL = "sharp_hours"
    private const val NOTIFICATION_ID = 4713
    const val ACTION_FIRE = "io.github.utof.eeg_tracker.sharp.FIRE"
    const val ACTION_SNOOZE = "io.github.utof.eeg_tracker.sharp.SNOOZE"
    const val ACTION_DISMISSED = "io.github.utof.eeg_tracker.sharp.DISMISSED"
    const val ACTION_OPEN = "io.github.utof.eeg_tracker.sharp.OPEN"
    const val EXTRA_PLANNED = "sharpPlanned"
    const val EXTRA_TEST = "sharpTest"
    const val EXTRA_SHOWN = "sharpShown"
    const val EXTRA_SNOOZED = "sharpSnoozed"
    private const val PREFS = "sharp_hours"
    private const val KEY_PLAN = "plan"
    private const val KEY_HANDLED = "handled"
    private const val LATE_MS = 60L * 60 * 1000
    private const val SNOOZE_MS = 15L * 60 * 1000
    private const val WINDOW_MS = 10L * 60 * 1000
    private const val RECORDER = "com.pravera.flutter_foreground_task.service.ForegroundService"
    private const val REQ_NEXT = 40
    private const val REQ_SNOOZED = 41
    private const val REQ_OPEN = 42
    private const val REQ_LATER = 43
    private const val REQ_GONE = 44
    private const val REQ_BACKUP = 45
    private val ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssxxx", Locale.ROOT)

    /** A session screen keeps the screen on (MainActivity's "keepScreenOn"): no question then. */
    @Volatile
    var screenHeld = false

    /** Keeps [at] (epoch ms) and whether each suggests the reaction test, and arms the first one ahead. */
    fun arm(context: Context, at: List<Long>, test: List<Boolean>) {
        val plan = at.indices.joinToString(",") { "${at[it]}:${if (test.getOrNull(it) == true) 1 else 0}" }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_PLAN, plan).apply()
        armNext(context)
    }

    private fun plan(context: Context): List<Pair<Long, Boolean>> {
        val s = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_PLAN, "") ?: ""
        return s.split(",").mapNotNull { item ->
            val p = item.split(":")
            val t = p.getOrNull(0)?.toLongOrNull() ?: return@mapNotNull null
            t to (p.getOrNull(1) == "1")
        }.sortedBy { it.first }
    }

    private fun fireIntent(context: Context, planned: Long, test: Boolean, snoozed: Boolean, request: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            request,
            Intent(context, SharpPromptReceiver::class.java)
                .setAction(ACTION_FIRE)
                .putExtra(EXTRA_PLANNED, planned)
                .putExtra(EXTRA_TEST, test)
                .putExtra(EXTRA_SNOOZED, snoozed),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** Arms the first kept moment after now (its window alarm and its Doze backup), or cancels both. */
    fun armNext(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val now = System.currentTimeMillis()
        val next = plan(context).firstOrNull { it.first > now }
        val main = fireIntent(context, next?.first ?: 0L, next?.second ?: false, false, REQ_NEXT)
        val backup = fireIntent(context, next?.first ?: 0L, next?.second ?: false, false, REQ_BACKUP)
        if (next == null) {
            am.cancel(main)
            am.cancel(backup)
            return
        }
        am.setWindow(AlarmManager.RTC_WAKEUP, next.first, WINDOW_MS, main)
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.first + WINDOW_MS, backup)
    }

    /** A moment rang (or its postponed copy): show it, skip it or drop it, log it, and arm the next. */
    fun fire(context: Context, planned: Long, test: Boolean, snoozed: Boolean) {
        val now = System.currentTimeMillis()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!snoozed) {
            // the window alarm or its backup already asked this moment: nothing more
            if (planned <= prefs.getLong(KEY_HANDLED, 0L)) return
            prefs.edit().putLong(KEY_HANDLED, planned).apply()
        }
        try {
            if (now - planned > LATE_MS) {
                log(context, planned, now, "late", null, test)
            } else {
                val busy = busyReason(context) ?: if (!notificationsOn(context)) "notifications off" else null
                if (busy != null) {
                    log(context, planned, now, "skipped", busy, test)
                } else {
                    show(context, planned, test, now)
                    log(context, planned, now, "shown", null, test)
                }
            }
            // moments that came due while this one waited (the phone held the alarm back): never rung, so late
            if (!snoozed) {
                for ((t, x) in plan(context)) if (t in (planned + 1)..now) log(context, t, now, "late", null, x)
            }
        } finally {
            if (!snoozed) armNext(context)
        }
    }

    /** "In 15 min": the notification goes and comes back once more in 15 minutes (or is dropped as late). */
    fun snooze(context: Context, planned: Long, test: Boolean) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        val now = System.currentTimeMillis()
        log(context, planned, now, "snoozed", null, test)
        context.getSystemService(AlarmManager::class.java)
            ?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, now + SNOOZE_MS, fireIntent(context, planned, test, true, REQ_SNOOZED))
    }

    fun dismissed(context: Context, planned: Long, test: Boolean) =
        log(context, planned, System.currentTimeMillis(), "dismissed", null, test)

    private fun busyReason(context: Context): String? = when {
        recorderRunning(context) -> "night recording"
        SessionService.running -> "sound session"
        screenHeld -> "session on screen"
        else -> null
    }

    /** The night recorder's service (flutter_foreground_task) runs: Android lists only this app's own services. */
    @Suppress("DEPRECATION")
    private fun recorderRunning(context: Context): Boolean = try {
        context.getSystemService(ActivityManager::class.java)?.getRunningServices(50)?.any { it.service.className == RECORDER } == true
    } catch (_: Exception) {
        false
    }

    fun notificationsOn(context: Context): Boolean {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!nm.areNotificationsEnabled()) return false // Android 13+: also when the permission was never given
        val c = nm.getNotificationChannel(CHANNEL)
        return c == null || c.importance != NotificationManager.IMPORTANCE_NONE
    }

    /** The questions' own channel: the owner can make it silent or louder in the phone's settings. */
    fun channel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val c = NotificationChannel(CHANNEL, "Sharp-hours questions", NotificationManager.IMPORTANCE_DEFAULT)
        c.description = "A few times a day: how sharp do you feel? (off unless switched on in Trends, Sharp hours)"
        c.setShowBadge(false)
        nm.createNotificationChannel(c)
    }

    private fun show(context: Context, planned: Long, test: Boolean, now: Long) {
        channel(context)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(
            context,
            REQ_OPEN,
            Intent(context, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .putExtra(EXTRA_PLANNED, planned)
                .putExtra(EXTRA_TEST, test)
                .putExtra(EXTRA_SHOWN, now)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        fun broadcast(action: String, request: Int) = PendingIntent.getBroadcast(
            context,
            request,
            Intent(context, SharpPromptReceiver::class.java).setAction(action).putExtra(EXTRA_PLANNED, planned).putExtra(EXTRA_TEST, test),
            flags,
        )
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_sharp)
            .setContentTitle("How sharp do you feel?")
            .setContentText(if (test) "One tap, then a 1-minute reaction test." else "One tap.")
            .setContentIntent(open)
            .setDeleteIntent(broadcast(ACTION_DISMISSED, REQ_GONE))
            .setAutoCancel(true)
            .setTimeoutAfter(LATE_MS)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_sharp), "In 15 min", broadcast(ACTION_SNOOZE, REQ_LATER)).build())
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, n)
    }

    private fun iso(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(ISO)

    private fun log(context: Context, planned: Long, at: Long, event: String, reason: String?, test: Boolean) {
        try {
            val dir = File(context.filesDir, "sharp-hours").apply { mkdirs() }
            val j = JSONObject().put("planned", iso(planned)).put("at", iso(at)).put("event", event)
            if (reason != null) j.put("reason", reason)
            if (test) j.put("test", true)
            File(dir, "prompts.jsonl").appendText("$j\n")
        } catch (_: Exception) {
            // a full disk must not stop the next question
        }
    }
}

/** The app's own alarms and notification buttons (explicit intents only). */
class SharpPromptReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val planned = intent.getLongExtra(SharpPrompts.EXTRA_PLANNED, 0L)
        val test = intent.getBooleanExtra(SharpPrompts.EXTRA_TEST, false)
        when (intent.action) {
            SharpPrompts.ACTION_FIRE -> SharpPrompts.fire(context, planned, test, intent.getBooleanExtra(SharpPrompts.EXTRA_SNOOZED, false))
            SharpPrompts.ACTION_SNOOZE -> SharpPrompts.snooze(context, planned, test)
            SharpPrompts.ACTION_DISMISSED -> SharpPrompts.dismissed(context, planned, test)
        }
    }
}

/** Alarms do not survive a restart or an update of the app: arm the next kept moment again. */
class SharpBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> SharpPrompts.armNext(context)
        }
    }
}
