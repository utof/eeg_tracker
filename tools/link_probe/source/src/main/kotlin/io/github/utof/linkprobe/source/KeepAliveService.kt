package io.github.utof.linkprobe.source

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** A foreground service that does nothing: the state "running with a foreground service", as eeg is while it records. */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("probe", "Probe", NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, "probe")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Probe source is running")
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        return START_STICKY
    }
}
