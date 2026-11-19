package io.github.utof.eeg_tracker

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "eeg_tracker/alarm" (lib/alarm/bell.dart): the smart alarm's phone side for both Flutter engines. The screen
 * sets and takes away the alarm and taps "I'm awake"; the night recorder's live model brings it forward.
 */
class AlarmChannel private constructor(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val NAME = "eeg_tracker/alarm"

        fun register(messenger: BinaryMessenger, context: Context) {
            MethodChannel(messenger, NAME).setMethodCallHandler(AlarmChannel(context.applicationContext))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "schedule" -> {
                    val end = call.argument<Number>("endMs")?.toLong() ?: throw IllegalArgumentException("endMs")
                    val start = call.argument<Number>("startMs")?.toLong() ?: end
                    WakeAlarm.schedule(
                        context,
                        end,
                        start,
                        call.argument<List<Number>>("volumes")?.map { it.toDouble() } ?: listOf(0.175),
                        call.argument<Number>("everyS")?.toInt() ?: 20,
                        call.argument<Number>("loudAfterS")?.toInt() ?: 180,
                        call.argument<Number>("giveUpS")?.toInt() ?: 600,
                    )
                    result.success(WakeAlarm.state(context))
                }
                "cancel" -> {
                    WakeAlarm.cancel(context)
                    result.success(WakeAlarm.state(context))
                }
                "awake" -> {
                    WakeAlarm.awake(context)
                    result.success(WakeAlarm.state(context))
                }
                "state" -> result.success(WakeAlarm.state(context))
                "bringForward" -> result.success(WakeAlarm.bringForward(context, call.argument<String>("reason") ?: ""))
                "openSetting" -> {
                    openSetting(call.argument<String>("page") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("alarm", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun openSetting(page: String) {
        val pkg = Uri.parse("package:${context.packageName}")
        val intent = when {
            page == "exact" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg)
            page == "fullScreen" && Build.VERSION.SDK_INT >= 34 ->
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkg)
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg)
        }
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
