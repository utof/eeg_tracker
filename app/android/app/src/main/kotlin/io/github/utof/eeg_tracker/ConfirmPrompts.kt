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
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The confirmation questions as a notification (DECISIONS 860-869): "Did you walk 19:08-21:14?" with Yes, No and
 * Not sure. The app's Dart side picks the batch, its words and its moment (lib/confirm/); this side rings it and takes
 * the answers while the app is closed. Each tap writes one line to files/confirm/answers.jsonl (the file the app's own
 * card writes) and shows the batch's next question, so several are answered without opening anything.
 *
 * - The batch is kept in the app's preferences and armed like a sharp-hours moment: a window alarm and a backup that
 *   may ring in Doze; no exact-alarm permission. Re-armed after a restart or an update (SharpBootReceiver).
 * - Held back 15 minutes at a time while a sound session holds the phone, a session screen keeps the screen on, or a
 *   recording runs with the screen off (you may be asleep: asked the next time the phone is in use). Dropped when over
 *   6 hours late; the questions stay on the app's card.
 * - What happened to each batch goes to files/confirm/asks.jsonl (`shown`, `held`, `late`, `skipped`, `dismissed`).
 */
object ConfirmPrompts {
    const val CHANNEL = "confirm_questions"
    private const val NOTIFICATION_ID = 4720
    const val ACTION_FIRE = "io.github.utof.eeg_tracker.confirm.FIRE"
    const val ACTION_ANSWER = "io.github.utof.eeg_tracker.confirm.ANSWER"
    const val ACTION_DISMISSED = "io.github.utof.eeg_tracker.confirm.DISMISSED"
    const val ACTION_OPEN = "io.github.utof.eeg_tracker.confirm.OPEN"
    const val EXTRA_AT = "confirmAt"
    const val EXTRA_ID = "confirmId"
    const val EXTRA_ANSWER = "confirmAnswer"
    private const val PREFS = "confirm_questions"
    private const val KEY_BATCH = "batch" // waiting for its moment
    private const val KEY_SHOWN = "shown" // in the notification now
    private const val KEY_HANDLED = "handled"
    private const val LATE_MS = 6L * 60 * 60 * 1000
    private const val HOLD_MS = 15L * 60 * 1000
    private const val WINDOW_MS = 10L * 60 * 1000
    private const val RECORDER = "com.pravera.flutter_foreground_task.service.ForegroundService"
    private const val REQ_NEXT = 60
    private const val REQ_BACKUP = 61
    private const val REQ_HELD = 62
    private const val REQ_OPEN = 63
    private const val REQ_GONE = 64
    private const val REQ_YES = 65
    private const val REQ_NO = 66
    private const val REQ_SKIP = 67
    private val ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssxxx", Locale.ROOT)

    /** One question of the kept batch: the estimate's id and the words to show. */
    data class Question(val id: String, val text: String)

    data class Batch(val at: Long, val questions: List<Question>)

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun batch(context: Context, key: String = KEY_BATCH): Batch? = try {
        val j = JSONObject(prefs(context).getString(key, "") ?: "")
        val q = j.getJSONArray("questions")
        Batch(j.getLong("at"), (0 until q.length()).map { Question(q.getJSONObject(it).getString("id"), q.getJSONObject(it).getString("text")) })
    } catch (_: Exception) {
        null
    }

    private fun keep(context: Context, b: Batch?, key: String = KEY_BATCH) {
        val e = prefs(context).edit()
        if (b == null || b.questions.isEmpty()) {
            e.remove(key)
        } else {
            val q = JSONArray()
            for (x in b.questions) q.put(JSONObject().put("id", x.id).put("text", x.text))
            e.putString(key, JSONObject().put("at", b.at).put("questions", q).toString())
        }
        e.apply()
    }

    /**
     * Keeps the batch for [at] (epoch ms) and arms it; an empty batch cancels the alarm. A batch already in the
     * notification stays until answered or replaced by the next one shown.
     */
    fun arm(context: Context, at: Long, ids: List<String>, texts: List<String>) {
        val questions = ids.indices.map { Question(ids[it], texts.getOrElse(it) { "" }) }.filter { it.text.isNotEmpty() }
        keep(context, if (questions.isEmpty()) null else Batch(at, questions))
        rearm(context)
    }

    private fun fireIntent(context: Context, at: Long, request: Int): PendingIntent = PendingIntent.getBroadcast(
        context,
        request,
        Intent(context, ConfirmPromptReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_AT, at),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** Arms the kept batch when its moment is still ahead (or not yet handled), or cancels the alarms. */
    fun rearm(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val b = batch(context)
        val main = fireIntent(context, b?.at ?: 0L, REQ_NEXT)
        val backup = fireIntent(context, b?.at ?: 0L, REQ_BACKUP)
        if (b == null || b.at <= prefs(context).getLong(KEY_HANDLED, 0L)) {
            am.cancel(main)
            am.cancel(backup)
            return
        }
        if (b.at <= System.currentTimeMillis()) { // its moment is now: no alarm window to wait for
            am.cancel(main)
            am.cancel(backup)
            fire(context, b.at, false)
            return
        }
        val at = b.at
        am.setWindow(AlarmManager.RTC_WAKEUP, at, WINDOW_MS, main)
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at + WINDOW_MS, backup)
    }

    /** The batch's moment came (or its held-back copy): show it, hold it back or drop it, and log which. */
    fun fire(context: Context, at: Long, held: Boolean) {
        val b = batch(context) ?: return
        if (b.at != at) return // replaced by a newer batch since this alarm was set
        val now = System.currentTimeMillis()
        if (!held) {
            if (at <= prefs(context).getLong(KEY_HANDLED, 0L)) return // the window alarm or its backup already came
            prefs(context).edit().putLong(KEY_HANDLED, at).apply()
        }
        val busy = busyReason(context)
        when {
            now - at > LATE_MS -> {
                log(context, at, "late", null)
                keep(context, null)
            }
            !notificationsOn(context) -> {
                log(context, at, "skipped", "notifications off")
                keep(context, null)
            }
            busy != null -> {
                if (!held) log(context, at, "held", busy)
                context.getSystemService(AlarmManager::class.java)
                    ?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, now + HOLD_MS, heldIntent(context, at))
            }
            else -> {
                keep(context, null)
                keep(context, b, KEY_SHOWN)
                show(context, b)
                log(context, at, "shown", null)
            }
        }
    }

    private fun heldIntent(context: Context, at: Long): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQ_HELD,
        Intent(context, ConfirmPromptReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_AT, at).putExtra("held", true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** A button of the notification: write the answer, then the next question or nothing. */
    fun answer(context: Context, id: String, answer: String) {
        try {
            val dir = File(context.filesDir, "confirm").apply { mkdirs() }
            val j = JSONObject().put("estimate_id", id).put("answer", answer).put("at", iso(System.currentTimeMillis())).put("via", "notification")
            File(dir, "answers.jsonl").appendText("$j\n")
        } catch (_: Exception) {
            // a full disk: the question stays open on the app's card
        }
        answered(context, id)
    }

    /** [id] was answered (here or in the app): it leaves the notification, which shows its next question or goes. */
    fun answered(context: Context, id: String) {
        val waiting = batch(context)
        if (waiting != null && waiting.questions.any { it.id == id }) {
            keep(context, Batch(waiting.at, waiting.questions.filter { it.id != id }))
            rearm(context)
        }
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val shown = batch(context, KEY_SHOWN)
        val rest = shown?.let { Batch(it.at, it.questions.filter { q -> q.id != id }) }
        if (rest == null || rest.questions.isEmpty()) {
            keep(context, null, KEY_SHOWN)
            nm.cancel(NOTIFICATION_ID)
            return
        }
        if (rest.questions.size == shown.questions.size) return
        keep(context, rest, KEY_SHOWN)
        if (nm.activeNotifications.any { it.id == NOTIFICATION_ID }) show(context, rest)
    }

    fun dismissed(context: Context, at: Long) {
        keep(context, null, KEY_SHOWN)
        log(context, at, "dismissed", null)
    }

    private fun busyReason(context: Context): String? = when {
        SessionService.sessionRunning -> "sound session"
        SharpPrompts.screenHeld -> "session on screen"
        recorderRunning(context) && context.getSystemService(PowerManager::class.java)?.isInteractive == false -> "recording, screen off"
        else -> null
    }

    /** The recorder's service (flutter_foreground_task) runs: Android lists only this app's own services. */
    @Suppress("DEPRECATION")
    private fun recorderRunning(context: Context): Boolean = try {
        context.getSystemService(ActivityManager::class.java)?.getRunningServices(50)?.any { it.service.className == RECORDER } == true
    } catch (_: Exception) {
        false
    }

    fun notificationsOn(context: Context): Boolean = SharpPrompts.notificationsOn(context, CHANNEL)

    /** The questions' own channel: the owner can make it silent or switch it off in the phone's settings. */
    fun channel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val c = NotificationChannel(CHANNEL, "Quick checks", NotificationManager.IMPORTANCE_DEFAULT)
        c.description = "A few times a day: did you sleep, did you walk? Yes, No or Not sure (More, Quick checks)"
        c.setShowBadge(false)
        nm.createNotificationChannel(c)
    }

    private fun show(context: Context, b: Batch) {
        channel(context)
        val q = b.questions.firstOrNull() ?: return
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(
            context,
            REQ_OPEN,
            Intent(context, MainActivity::class.java).setAction(ACTION_OPEN).putExtra(EXTRA_AT, b.at).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        fun button(word: String, answer: String, request: Int) = Notification.Action.Builder(
            Icon.createWithResource(context, R.drawable.ic_sharp),
            word,
            PendingIntent.getBroadcast(
                context,
                request,
                Intent(context, ConfirmPromptReceiver::class.java).setAction(ACTION_ANSWER).putExtra(EXTRA_ID, q.id).putExtra(EXTRA_ANSWER, answer),
                flags,
            ),
        ).build()
        val more = b.questions.size - 1
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_sharp)
            .setContentTitle(q.text)
            .setContentText(if (more > 0) "One tap. Then $more more." else "One tap.")
            .setContentIntent(open)
            .setDeleteIntent(
                PendingIntent.getBroadcast(
                    context,
                    REQ_GONE,
                    Intent(context, ConfirmPromptReceiver::class.java).setAction(ACTION_DISMISSED).putExtra(EXTRA_AT, b.at),
                    flags,
                ),
            )
            .setOnlyAlertOnce(true) // the next question of the batch comes without a second sound
            .setTimeoutAfter(LATE_MS)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(button("Yes", "yes", REQ_YES))
            .addAction(button("No", "no", REQ_NO))
            .addAction(button("Not sure", "skip", REQ_SKIP))
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, n)
    }

    private fun iso(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(ISO)

    private fun log(context: Context, at: Long, event: String, reason: String?) {
        try {
            val dir = File(context.filesDir, "confirm").apply { mkdirs() }
            val j = JSONObject().put("at", iso(System.currentTimeMillis())).put("event", event).put("batch", iso(at))
            if (reason != null) j.put("reason", reason)
            File(dir, "asks.jsonl").appendText("$j\n")
        } catch (_: Exception) {
            // a full disk must not stop the question
        }
    }
}

/** The app's own alarm and the notification's buttons (explicit intents only). */
class ConfirmPromptReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ConfirmPrompts.ACTION_FIRE -> ConfirmPrompts.fire(context, intent.getLongExtra(ConfirmPrompts.EXTRA_AT, 0L), intent.getBooleanExtra("held", false))
            ConfirmPrompts.ACTION_ANSWER -> {
                val id = intent.getStringExtra(ConfirmPrompts.EXTRA_ID) ?: return
                val answer = intent.getStringExtra(ConfirmPrompts.EXTRA_ANSWER) ?: return
                ConfirmPrompts.answer(context, id, answer)
            }
            ConfirmPrompts.ACTION_DISMISSED -> ConfirmPrompts.dismissed(context, intent.getLongExtra(ConfirmPrompts.EXTRA_AT, 0L))
        }
    }
}
