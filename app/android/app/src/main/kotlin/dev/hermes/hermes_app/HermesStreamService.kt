package dev.hermes.hermes_app

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
import io.flutter.plugin.common.MethodChannel

/** Process-scoped tokens: one stream ending must not stop another stream. */
class HermesStreamService : Service() {
    companion object {
        private const val CHANNEL = "hermes_reply"
        private const val NOTIFICATION = 2301
        private val streams = mutableSetOf<Int>()
        private val pending = mutableMapOf<Int, MethodChannel.Result>()
        private val stopping = mutableListOf<MethodChannel.Result>()
        var reportError: (() -> Unit)? = null

        // In-process reference for locale update-in-place only (§6.5); no
        // broadcast, no service wakeup, cleared on destruction.
        @Volatile
        private var active: HermesStreamService? = null

        fun onLocaleChanged(context: Context) {
            val service = active
            if (service != null) {
                service.refreshLocalized()
                return
            }
            if (Build.VERSION.SDK_INT >= 26) {
                // Existing channel keeps importance/user settings; never
                // create or start anything just because the language changed.
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.getNotificationChannel(CHANNEL)?.let { existing ->
                    manager.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL,
                            NotificationLocale.channelName(context),
                            existing.importance,
                        )
                    )
                }
            }
        }

        fun start(context: Context, id: Int, result: MethodChannel.Result) {
            streams.add(id)
            pending[id] = result
            try {
                val intent = Intent(context, HermesStreamService::class.java).putExtra("stream", id)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (_: Exception) {
                streams.remove(id)
                pending.remove(id)?.error("fgs", "Cannot start stream service", null)
            }
        }

        fun stop(context: Context, id: Int, result: MethodChannel.Result) {
            streams.remove(id)
            if (streams.isEmpty() && context.stopService(Intent(context, HermesStreamService::class.java))) {
                // Reply after destruction so a queued new start cannot lose its token.
                stopping.add(result)
            } else result.success(null)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Rebuilds the SAME notification id/title channel under the new
     *  language; stream tokens and foreground state stay untouched. */
    private fun refreshLocalized() {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.getNotificationChannel(CHANNEL)?.let { existing ->
                    manager.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL,
                            NotificationLocale.channelName(this),
                            existing.importance,
                        )
                    )
                }
            }
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                else Notification.Builder(this)
            manager.notify(
                NOTIFICATION,
                builder
                    .setSmallIcon(R.drawable.ic_stream_notification)
                    .setContentTitle(NotificationLocale.activeTitle(this))
                    .setContentIntent(pendingIntent())
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setPriority(Notification.PRIORITY_LOW)
                    .build()
            )
        } catch (_: Exception) {
            // Language refresh must never break the running stream.
        }
    }

    private fun pendingIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        active = this
        val id = intent?.getIntExtra("stream", -1) ?: -1
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, NotificationLocale.channelName(this), NotificationManager.IMPORTANCE_LOW))
            }
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                else Notification.Builder(this)
            val notification = builder
                .setSmallIcon(R.drawable.ic_stream_notification)
                .setContentTitle(NotificationLocale.activeTitle(this))
                .setContentIntent(pendingIntent())
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(Notification.PRIORITY_LOW)
                .build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else startForeground(NOTIFICATION, notification)
            pending.remove(id)?.success(null)
            if (streams.isEmpty()) stopSelf()
        } catch (_: Exception) {
            // Also catch promotion failures, not just startForegroundService().
            pending.remove(id)?.error("fgs", "Cannot promote stream service", null)
            streams.remove(id)
            if (streams.isEmpty()) stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        streams.clear()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        reportError?.invoke()
        streams.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        active = null
        pending.values.forEach { it.error("fgs", "Stream service stopped", null) }
        pending.clear()
        streams.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopping.forEach { it.success(null) }
        stopping.clear()
        super.onDestroy()
    }
}
