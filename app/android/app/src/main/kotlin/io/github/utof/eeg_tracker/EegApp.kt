package io.github.utof.eeg_tracker

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Runs in every app process, including one Android starts only to restart the recorder service.
 * It gives the service's own Flutter engine the same "eeg_tracker/phone" and "eeg_tracker/alarm" channels as the
 * screen's.
 */
class EegApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AutoWatch.trackScreen(this) // when the screen went off, for the headband watcher's rules
        ReconnectHints.trackActivities(this) // "the app came to the front", for the reconnect ladder (DECISIONS 943)
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(object : FlutterForegroundTaskLifecycleListener {
            override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                flutterEngine?.let {
                    PhoneChannel.register(it.dartExecutor.binaryMessenger, this@EegApp)
                    // the smart alarm's live model brings the alarm forward from the recorder's engine
                    AlarmChannel.register(it.dartExecutor.binaryMessenger, this@EegApp)
                    // the reconnect ladder's hints: unlock, Bluetooth on, the app in front, "Reconnect now"
                    ReconnectHints.register(it.dartExecutor.binaryMessenger, this@EegApp)
                    // the laptop's work word reaches the recorder's own Share on Wi-Fi server while it records: it asks
                    // the headband watcher for a check from here (DECISIONS 1107; no pairing from this engine)
                    AutoWatch.register(it.dartExecutor.binaryMessenger, this@EegApp, null)
                }
            }

            override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

            override fun onTaskRepeatEvent() {}

            override fun onTaskDestroy() {}

            // the recorder's engine ends: its hold on Wi-Fi (Share on Wi-Fi, the DIY board) goes with it (DECISIONS 612)
            override fun onEngineWillDestroy() {
                PhoneChannel.holdWifi(this@EegApp, "recorder", false)
                ReconnectHints.forgetAll(this@EegApp)
            }
        })
    }
}
