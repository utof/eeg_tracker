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
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock

/**
 * Keeps a sound session alive while the phone is locked (DECISIONS rows 190-196): sound for states, meditation,
 * alpha-theta, the dream catcher and the work session (DECISIONS 447). The session itself (sound engine, headband, timers) stays in the screen's
 * Flutter engine; this service only tells Android the app is playing sound (type mediaPlayback, plus
 * connectedDevice with the headband and microphone for the dream catcher), holds a partial wake lock and shows a
 * media notification with Stop. It is not the night recorder's service (flutter_foreground_task) and never
 * touches it. Started only from the open screen; never restarted by Android (the session would be gone).
 *
 * It also asks for the sound (audio focus, DECISIONS row 468) unless the session says not to (the nap, which plays
 * nothing until its wake): other apps' sound pauses, and a call or another app taking the sound, or giving it back,
 * reaches the session as "loss", "lossTransient", "duck" or "gain", so it can go quiet instead of playing through a
 * call. Android lowers the session's sound by itself for a short sound ("duck").
 */
class SessionService : Service() {
    companion object {
        const val CHANNEL = "sound_session"
        private const val NOTIFICATION_ID = 4712
        private const val ACTION_HOLD = "io.github.utof.eeg_tracker.session.HOLD"
        private const val ACTION_STOP_TAP = "io.github.utof.eeg_tracker.session.STOP_TAP"
        private const val CUSTOM_STOP = "stop"

        /** The longest a session may hold the wake lock without holding again (the work session re-holds). */
        private const val WAKE_LOCK_MS = 3L * 60 * 60 * 1000

        /** Stop was tapped on the notification or the lock screen; set by the screen's Activity. */
        @Volatile
        var onStopTapped: (() -> Unit)? = null

        /** The audio focus changed ("loss", "lossTransient", "duck", "gain"); set by the screen's Activity. */
        @Volatile
        var onFocusChanged: ((String) -> Unit)? = null

        /** Answer to the last [hold]: what is kept ("headband", "microphone"), or the error. */
        @Volatile
        private var pending: ((List<String>?, String?) -> Unit)? = null

        @Volatile
        var running = false
            private set

        /**
         * Starts (or updates) the service from the visible app. [done] gets the extras that are kept, or an error.
         * A plain startService: the app is on screen, and unlike startForegroundService it has no 5 s deadline
         * that would crash the app if the foreground start is refused.
         */
        fun hold(
            context: Context,
            title: String,
            text: String,
            headband: Boolean,
            microphone: Boolean,
            focus: Boolean,
            done: (List<String>?, String?) -> Unit,
        ) {
            pending?.invoke(null, "replaced by a newer request")
            pending = done
            try {
                context.startService(
                    Intent(context, SessionService::class.java)
                        .setAction(ACTION_HOLD)
                        .putExtra("title", title)
                        .putExtra("text", text)
                        .putExtra("headband", headband)
                        .putExtra("microphone", microphone)
                        .putExtra("focus", focus),
                )
            } catch (e: Exception) {
                pending = null
                done(null, e.message ?: e.javaClass.simpleName)
            }
        }

        fun release(context: Context) {
            context.stopService(Intent(context, SessionService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var session: MediaSession? = null
    private var focusRequest: AudioFocusRequest? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_TAP -> {
                val tapped = onStopTapped
                if (tapped != null) tapped() else stopSelf() // no screen left to stop: just go
            }
            ACTION_HOLD -> hold(intent)
            else -> stopSelf() // a restart without its session
        }
        return START_NOT_STICKY
    }

    private fun hold(intent: Intent) {
        val title = intent.getStringExtra("title") ?: "Sound session"
        val text = intent.getStringExtra("text") ?: ""
        val headband = intent.getBooleanExtra("headband", false)
        val microphone = intent.getBooleanExtra("microphone", false)
        val answer = pending
        pending = null
        try {
            channel()
            val media = mediaSession(title, text)
            val notification = notification(title, text, media)
            // Asked types first; if Android refuses one (a permission taken back), the sound alone.
            val kept = ArrayList<String>()
            try {
                foreground(notification, headband, microphone)
                if (headband) kept.add("headband")
                if (microphone) kept.add("microphone")
            } catch (e: SecurityException) {
                if (!headband && !microphone) throw e
                foreground(notification, false, false)
            }
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "eeg_tracker:session")
                    ?.apply { setReferenceCounted(false) }
            }
            // Every hold (re)arms the lock's timeout: a work session holds again every 20 minutes and can
            // run a whole day (DECISIONS 447); the others hold once and are released long before.
            wakeLock?.acquire(WAKE_LOCK_MS)
            if (intent.getBooleanExtra("focus", true)) askFocus() else dropFocus()
            running = true
            answer?.invoke(kept, null)
        } catch (e: Exception) {
            answer?.invoke(null, e.message ?: e.javaClass.simpleName)
            stopSelf()
        }
    }

    /** Asks for the sound once per session; a refusal (a call already running) leaves the session as it was. */
    private fun askFocus() {
        if (focusRequest != null) return
        val am = getSystemService(AudioManager::class.java) ?: return
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setOnAudioFocusChangeListener({ change -> onFocusChanged?.invoke(focusWord(change)) }, Handler(Looper.getMainLooper()))
            .build()
        if (am.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_FAILED) focusRequest = request
    }

    private fun dropFocus() {
        val request = focusRequest ?: return
        focusRequest = null
        try {
            getSystemService(AudioManager::class.java)?.abandonAudioFocusRequest(request)
        } catch (_: Exception) {
        }
    }

    private fun focusWord(change: Int): String = when (change) {
        AudioManager.AUDIOFOCUS_LOSS -> "loss"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "lossTransient"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "duck"
        AudioManager.AUDIOFOCUS_GAIN -> "gain"
        else -> "other"
    }

    private fun foreground(notification: Notification, headband: Boolean, microphone: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        if (headband) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if (microphone && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        startForeground(NOTIFICATION_ID, notification, types)
    }

    private fun channel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val c = NotificationChannel(CHANNEL, "Sound session", NotificationManager.IMPORTANCE_LOW)
        c.description = "Shown while a sound session runs, with Stop"
        c.setShowBadge(false)
        nm.createNotificationChannel(c)
    }

    /** A media session, so the lock screen shows the session as playing sound, with Stop. */
    private fun mediaSession(title: String, text: String): MediaSession {
        val s = session ?: MediaSession(this, "eeg_tracker session").also {
            it.setCallback(object : MediaSession.Callback() {
                override fun onStop() = tapped()

                override fun onCustomAction(action: String, extras: Bundle?) {
                    if (action == CUSTOM_STOP) tapped()
                }
                // Play / pause from a headset do nothing: a session cannot pause, and a button pressed in
                // bed by accident must not end it.
            })
            session = it
        }
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, text.ifEmpty { "EEG Tracker" })
                .build(),
        )
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_STOP)
                .addCustomAction(PlaybackState.CustomAction.Builder(CUSTOM_STOP, "Stop", R.drawable.ic_session_stop).build())
                .setState(PlaybackState.STATE_PLAYING, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f, SystemClock.elapsedRealtime())
                .build(),
        )
        s.isActive = true
        return s
    }

    private fun tapped() {
        val t = onStopTapped
        if (t != null) t() else stopSelf()
    }

    private fun notification(title: String, text: String, media: MediaSession): Notification {
        val immutable = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            immutable,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, SessionService::class.java).setAction(ACTION_STOP_TAP),
            immutable,
        )
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_session)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(
                Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_session_stop), "Stop", stop).build(),
            )
            .setStyle(Notification.MediaStyle().setMediaSession(media.sessionToken).setShowActionsInCompactView(0))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return b.build()
    }

    override fun onDestroy() {
        running = false
        dropFocus()
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        super.onDestroy()
    }
}
