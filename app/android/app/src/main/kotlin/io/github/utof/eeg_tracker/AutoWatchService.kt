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
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The headband watcher's check (DECISIONS 600): a short foreground service of type connectedDevice ("Checking whether
 * the headband is on") that runs lib/auto/task.dart in a Flutter engine of its own, so a check works with the app
 * closed. It takes the triggers AutoWatch.kt queues, gives the Dart side the phone's context, and shows the watcher's
 * one quiet notification: while it asks, the service's own notification becomes the question with its buttons
 * ("Start the night" / "Not now"; a work start opens the app's work page from the tap itself, as Android allows only
 * that). It ends when the Dart side has nothing left, and after 20 minutes at the latest. It holds no wake lock: the
 * check takes seconds, and a question waits on the person.
 */
class AutoWatchService : Service() {
    companion object {
        const val CHANNEL = "auto_start"
        private const val NOTIFICATION_ID = 4715
        private const val NOTICE_ID = 4716
        private const val OFFER_ID = 4717
        private const val ACTION_CHECK = "io.github.utof.eeg_tracker.auto.CHECK"
        private const val MAX_MS = 20L * 60 * 1000
        private const val REQ_ANSWER = 70
        private const val REQ_OPEN = 80

        @Volatile
        var instance: AutoWatchService? = null
            private set

        private val queue = ArrayDeque<Map<String, Any?>>()

        /**
         * Queues [trigger] and starts the service; a running check takes it after the one it is on. False when Android
         * refused the start.
         */
        fun start(context: Context, trigger: Map<String, Any?>): Boolean {
            synchronized(queue) {
                queue.addLast(trigger)
                val running = instance
                if (running != null && !running.ending) return true
            }
            return try {
                context.startForegroundService(Intent(context, AutoWatchService::class.java).setAction(ACTION_CHECK))
                true
            } catch (e: Exception) {
                // Android 12+: ForegroundServiceStartNotAllowedException without the pairing or the battery exemption
                synchronized(queue) { queue.clear() }
                false
            }
        }

        private fun take(): Map<String, Any?>? = synchronized(queue) { queue.removeFirstOrNull() }

        /** A start by hand needs the headband: the Dart side lets go of it, then [done] runs (at once without a check). */
        fun release(done: () -> Unit) {
            val s = instance
            val t = s?.task
            if (s == null || t == null) {
                done()
                return
            }
            var answered = false
            val once = {
                if (!answered) {
                    answered = true
                    done()
                }
            }
            s.main.post {
                t.invokeMethod("release", null, object : MethodChannel.Result {
                    override fun success(result: Any?) = once()
                    override fun error(code: String, message: String?, details: Any?) = once()
                    override fun notImplemented() = once()
                })
            }
            s.main.postDelayed(once, 8000)
        }

        /** An answer to the question; dropped (with the notification) when no check is waiting for it any more. */
        fun answer(context: Context, id: String, answer: String) {
            val s = instance
            val t = s?.task
            if (s == null || t == null) {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
                return
            }
            s.main.post { t.invokeMethod("answer", mapOf("id" to id, "answer" to answer)) }
        }

        fun channel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL) != null) return
            val c = NotificationChannel(CHANNEL, "Headband on", NotificationManager.IMPORTANCE_LOW)
            c.description = "Quiet: the check whether the headband is on, and \"Start the night?\" (Settings, When I put the headband on)"
            c.setShowBadge(false)
            nm.createNotificationChannel(c)
        }
    }

    val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    var task: MethodChannel? = null
        private set
    private val stopLater = Runnable { end() }
    private val endNow = Runnable { end() }

    /** The Dart side has finished; a start that comes now begins a new engine. Changed under the queue's lock. */
    @Volatile
    var ending = false
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            foreground(base("Checking whether the headband is on", "A few seconds; nothing is recorded."))
        } catch (_: Exception) {
            end()
            return START_NOT_STICKY
        }
        main.removeCallbacks(stopLater)
        main.postDelayed(stopLater, MAX_MS)
        val restart = synchronized(queue) {
            val was = ending
            ending = false
            was
        }
        if (restart) {
            // the Dart side had finished its run: a fresh engine takes the new trigger
            main.removeCallbacks(endNow)
            stopEngine()
        }
        if (engine == null) startEngine()
        return START_NOT_STICKY
    }

    private fun foreground(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun base(title: String, text: String): Notification {
        channel(this)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_headband)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            if (instance !== this || engine != null) return@ensureInitializationCompleteAsync
            val e = FlutterEngine(applicationContext)
            val messenger = e.dartExecutor.binaryMessenger
            PhoneChannel.register(messenger, applicationContext)
            AutoWatch.register(messenger, applicationContext, null)
            task = MethodChannel(messenger, "eeg_tracker/auto_task").apply { setMethodCallHandler(::onTaskCall) }
            engine = e
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:eeg_tracker/auto/task.dart", "autoWatchMain"),
            )
        }
    }

    private fun onTaskCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "takeTrigger" -> result.success(take())
                "context" -> result.success(AutoWatch.context(this))
                "busy" -> result.success(AutoWatch.busyReason(this))
                "ask" -> {
                    ask(call)
                    result.success(null)
                }
                "withdraw" -> {
                    foreground(base("Checking whether the headband is on", "Nothing is recorded."))
                    result.success(null)
                }
                "notice" -> {
                    notice(NOTICE_ID, call.argument<String>("title") ?: "", call.argument<String>("text") ?: "", null)
                    result.success(null)
                }
                "offer" -> {
                    notice(OFFER_ID, call.argument<String>("title") ?: "", call.argument<String>("text") ?: "", openIntent("settings", call.argument<String>("kind")))
                    result.success(null)
                }
                "openWork" -> openWork(call.argument<Boolean>("quiet") != false, call.argument<Number>("limitMin")?.toInt() ?: 0, result)
                "finish" -> {
                    val done = synchronized(queue) {
                        if (call.argument<Boolean>("force") != true && queue.isNotEmpty()) {
                            false
                        } else {
                            ending = true
                            true
                        }
                    }
                    result.success(done)
                    if (done) main.post(endNow)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("auto", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun openIntent(launch: String, kind: String?, quiet: Boolean = true, limitMin: Int = 0, id: String? = null, answer: String? = null): PendingIntent =
        PendingIntent.getActivity(
            this,
            REQ_OPEN + (if (launch == "work") 1 else 0),
            Intent(this, MainActivity::class.java)
                .setAction(AutoWatch.ACTION_OPEN)
                .putExtra(AutoWatch.EXTRA_LAUNCH, launch)
                .putExtra(AutoWatch.EXTRA_KIND, kind)
                .putExtra(AutoWatch.EXTRA_QUIET, quiet)
                .putExtra(AutoWatch.EXTRA_LIMIT, limitMin)
                .putExtra(AutoWatch.EXTRA_ID, id)
                .putExtra(AutoWatch.EXTRA_ANSWER, answer)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** The question, as this service's own notification: answers go back to the Dart side; a work start opens the app. */
    private fun ask(call: MethodCall) {
        val id = call.argument<String>("id") ?: ""
        val kind = call.argument<String>("kind") ?: "night"
        val actions = call.argument<List<String>>("actions") ?: emptyList()
        val labels = call.argument<List<String>>("labels") ?: emptyList()
        val quiet = call.argument<Boolean>("workQuiet") != false
        val limit = call.argument<Number>("workLimitMin")?.toInt() ?: 0
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_headband)
            .setContentTitle(call.argument<String>("title") ?: "Headband on")
            .setContentText(call.argument<String>("text") ?: "")
            .setStyle(Notification.BigTextStyle().bigText(call.argument<String>("text") ?: ""))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent("settings", kind))
        actions.forEachIndexed { i, a ->
            val work = a == "work" || (a == "yes" && kind == "work")
            val pi = if (work) {
                openIntent("work", "work", quiet, limit, id, a)
            } else {
                PendingIntent.getBroadcast(
                    this,
                    REQ_ANSWER + i,
                    Intent(this, AutoReceiver::class.java)
                        .setAction(AutoWatch.ACTION_ANSWER)
                        .putExtra(AutoWatch.EXTRA_ID, id)
                        .putExtra(AutoWatch.EXTRA_ANSWER, a),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }
            b.addAction(Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_headband), labels.getOrNull(i) ?: a, pi).build())
        }
        foreground(b.build())
    }

    private fun notice(id: Int, title: String, text: String, open: PendingIntent?) {
        channel(this)
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_headband)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setTimeoutAfter(6L * 60 * 60 * 1000)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        if (open != null) b.setContentIntent(open)
        getSystemService(NotificationManager::class.java)?.notify(id, b.build())
    }

    /**
     * An automatic work session: the app's work page opens and starts it. Android lets an app paired with a companion
     * device open its page from the background; otherwise the start is silently refused. The answer is whether the
     * page took the launch within 8 seconds.
     */
    private fun openWork(quiet: Boolean, limitMin: Int, result: MethodChannel.Result) {
        val asked = System.currentTimeMillis()
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(AutoWatch.ACTION_OPEN)
                    .putExtra(AutoWatch.EXTRA_LAUNCH, "work")
                    .putExtra(AutoWatch.EXTRA_KIND, "work")
                    .putExtra(AutoWatch.EXTRA_QUIET, quiet)
                    .putExtra(AutoWatch.EXTRA_LIMIT, limitMin)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        } catch (_: Exception) {
            result.success(false)
            return
        }
        var tries = 0
        val poll = object : Runnable {
            override fun run() {
                if (AutoWatch.workOpenedAt >= asked) {
                    result.success(true)
                } else if (++tries >= 32) {
                    result.success(false)
                } else {
                    main.postDelayed(this, 250)
                }
            }
        }
        main.postDelayed(poll, 250)
    }

    private fun end() {
        main.removeCallbacks(stopLater)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopEngine() {
        task?.setMethodCallHandler(null)
        task = null
        engine?.destroy()
        engine = null
    }

    override fun onDestroy() {
        main.removeCallbacks(stopLater)
        main.removeCallbacks(endNow)
        if (instance === this) instance = null
        stopEngine()
        super.onDestroy()
    }
}
