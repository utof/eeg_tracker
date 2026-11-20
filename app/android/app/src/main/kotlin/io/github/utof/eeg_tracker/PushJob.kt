package io.github.utof.eeg_tracker

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The push (lib/share/push/, DECISIONS 840-849): Android's own scheduler runs this about every 15 minutes while the
 * phone is on Wi-Fi, and once soon after a recording ends. It starts a Flutter engine of its own (`pushMain`), which
 * sends the paired laptop what it lacks and says "done". A plain job: no foreground service, no notification.
 * Android stops a job after about ten minutes; whatever was sent by then stays on the laptop and the next one goes on.
 */
class PushJobService : JobService() {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var task: MethodChannel? = null
    private var running: JobParameters? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (running != null || busy) return false // one push at a time; the other job's next turn comes
        busy = true
        running = params
        val soon = params.jobId == SOON_ID
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            if (running !== params) return@ensureInitializationCompleteAsync
            try {
                val e = FlutterEngine(applicationContext)
                val messenger = e.dartExecutor.binaryMessenger
                PhoneChannel.register(messenger, applicationContext)
                task = MethodChannel(messenger, "eeg_tracker/push_task").apply {
                    setMethodCallHandler { call, result ->
                        when (call.method) {
                            "soon" -> result.success(soon)
                            "done" -> {
                                result.success(null)
                                main.post { finish(params, again = false) }
                            }
                            else -> result.notImplemented()
                        }
                    }
                }
                engine = e
                e.dartExecutor.executeDartEntrypoint(
                    // in main.dart: an entry point outside the libraries main reaches is left out of the build
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "pushMain"),
                )
            } catch (_: Throwable) {
                finish(params, again = false)
            }
        }
        return true // the work goes on after this returns
    }

    /** Android ends the job early (its time is up, Wi-Fi went): the one after a recording is tried again. */
    override fun onStopJob(params: JobParameters): Boolean {
        val mine = running === params
        if (mine) stopEngine()
        return mine && params.jobId == SOON_ID
    }

    private fun finish(params: JobParameters, again: Boolean) {
        if (running !== params) return
        stopEngine()
        try {
            jobFinished(params, again)
        } catch (_: Throwable) {
        }
    }

    private fun stopEngine() {
        task?.setMethodCallHandler(null)
        task = null
        try {
            engine?.destroy()
        } catch (_: Throwable) {
        }
        engine = null
        running = null
        busy = false
    }

    override fun onDestroy() {
        stopEngine()
        super.onDestroy()
    }

    companion object {
        private const val REGULAR_ID = 877201
        private const val SOON_ID = 877202
        private const val EVERY_MS = 15 * 60 * 1000L

        @Volatile
        private var busy = false

        private fun scheduler(context: Context) = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler

        private fun builder(context: Context, id: Int) =
            JobInfo.Builder(id, ComponentName(context, PushJobService::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED) // Wi-Fi; the Dart side asks for the home one

        /** Arms the regular job (kept over a restart of the phone), or ends both jobs. Arming again changes nothing. */
        fun schedule(context: Context, on: Boolean) {
            val js = scheduler(context)
            if (!on) {
                js.cancel(REGULAR_ID)
                js.cancel(SOON_ID)
                return
            }
            if (js.getPendingJob(REGULAR_ID) != null) return
            js.schedule(builder(context, REGULAR_ID).setPeriodic(EVERY_MS).setPersisted(true).build())
        }

        /** One push as soon as the phone is on Wi-Fi (a recording just ended). */
        fun soon(context: Context) {
            val js = scheduler(context)
            if (js.getPendingJob(REGULAR_ID) == null) return // not armed: sharing is off or no laptop is paired
            js.schedule(builder(context, SOON_ID).setMinimumLatency(2000).setOverrideDeadline(60 * 60 * 1000L).build())
        }
    }
}
