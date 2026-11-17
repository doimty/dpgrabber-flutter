package com.doimty.dpgrabber

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service holding the Flutter process alive while the
 * Dart [ListenEngine] polls (PORTING_CONTRACT §1.7).
 *
 * Ported from the reference `ListenService.kt`, adapted to Flutter:
 * the reference service *ran* the Kotlin engine itself; here the
 * engine runs in Dart (main isolate), so this service only
 *  - goes foreground with a persistent notification, and
 *  - shows the latest listen status in that notification.
 * It never touches the network or the credentials.
 *
 * Lifecycle: [MainActivity] starts it via the `keep_alive` channel
 * when listening starts and stops it when listening stops (or on a
 * successful grab, when the engine auto-stops). `START_STICKY` asks
 * the system to restart it if the process is killed.
 *
 * Notification updates are throttled to one per 2 s (reference
 * behaviour): the engine can log several times a second while
 * polling, and updating the notification that often wastes battery.
 */
class ListenService : Service() {

    companion object {
        const val ACTION_START = "com.doimty.dpgrabber.action.START"
        const val ACTION_STOP = "com.doimty.dpgrabber.action.STOP"
        const val ACTION_UPDATE_NOTIFICATION =
            "com.doimty.dpgrabber.action.UPDATE_NOTIFICATION"
        const val EXTRA_TEXT = "text"
        const val CHANNEL_ID = "dpgrabber_listen"
        const val NOTIFICATION_ID = 1001
        private const val NOTIFICATION_MIN_INTERVAL_MS = 2000L

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, ListenService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ListenService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun updateNotification(context: Context, text: String) {
            val intent = Intent(context, ListenService::class.java).apply {
                action = ACTION_UPDATE_NOTIFICATION
                putExtra(EXTRA_TEXT, text)
            }
            context.startService(intent)
        }
    }

    private var lastNotificationMs: Long = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                isRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                if (isRunning) return START_STICKY
                startForegroundWithType(buildNotification("正在启动…"))
                isRunning = true
                return START_STICKY
            }
            ACTION_UPDATE_NOTIFICATION -> {
                if (isRunning) {
                    updateNotificationThrottled(
                        intent.getStringExtra(EXTRA_TEXT) ?: ""
                    )
                }
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun startForegroundWithType(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notification_channel_desc)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun updateNotificationThrottled(text: String) {
        if (text.isEmpty()) return
        val now = System.currentTimeMillis()
        if (now - lastNotificationMs < NOTIFICATION_MIN_INTERVAL_MS) return
        lastNotificationMs = now
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
