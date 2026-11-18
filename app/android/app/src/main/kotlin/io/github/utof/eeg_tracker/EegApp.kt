package io.github.utof.eeg_tracker

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Runs in every app process, including one Android starts only to restart the recorder service.
 * It gives the service's own Flutter engine the same "eeg_tracker/phone" channel as the screen's.
 */
class EegApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(object : FlutterForegroundTaskLifecycleListener {
            override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                flutterEngine?.let { PhoneChannel.register(it.dartExecutor.binaryMessenger, this@EegApp) }
            }

            override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

            override fun onTaskRepeatEvent() {}

            override fun onTaskDestroy() {}

            override fun onEngineWillDestroy() {}
        })
    }
}
