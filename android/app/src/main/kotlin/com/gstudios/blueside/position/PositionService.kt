package com.gstudios.blueside.position

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.gstudios.blueside.R

// Keeps the app running out of the front while the app model says so; the fixes and the receiver stay in the app model.
// Started only from the front, where Android lets a location service begin. A start it refuses ends the service, not the app.
class PositionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            running = true
        } catch (e: Exception) {
            // Location permission taken away, or a start Android does not allow.
            Log.w("Blueside", "background position refused", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    // Shown without asking: with notifications off the service still runs.
    private fun notification(): Notification {
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Background position", NotificationManager.IMPORTANCE_LOW))
        // As the launcher opens it, and never a second map over the first, which would bring a second app model.
        val open = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE) }
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_mark)
            .setContentTitle("Blueside")
            .setContentText("Keeping position and traffic live")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "position"
        private const val NOTIFICATION = 1

        // True from the service going foreground until it ends. Observed, so the app lets go at once if it ends early,
        // since out of the front without it Android throttles the fixes that would otherwise tell.
        var running by mutableStateOf(false)
            private set

        // False when Android refuses the start.
        fun start(context: Context): Boolean =
            runCatching { context.startService(Intent(context, PositionService::class.java)) }.isSuccess

        fun stop(context: Context) {
            context.stopService(Intent(context, PositionService::class.java))
        }
    }
}
