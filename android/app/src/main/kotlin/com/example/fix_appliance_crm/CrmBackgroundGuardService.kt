package com.example.fix_appliance_crm

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
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Держит процесс живым, чтобы FCM (SMS, почта, Twilio) доходили
 * без открытия приложения. Тихая постоянная шторка — требование Android
 * для foreground-сервиса.
 */
class CrmBackgroundGuardService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        start(applicationContext)
    }

    private fun startAsForeground() {
        ensureChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (_: Exception) {
            try {
                startForeground(NOTIF_ID, notification)
            } catch (_: Exception) {
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Background",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps SMS, email and call alerts working when the app is closed"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            },
        )
    }

    private fun buildNotification(): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val iconId = resources.getIdentifier("ic_stat_notify", "drawable", packageName)
        val colorId = resources.getIdentifier("notification_accent", "color", packageName)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (iconId != 0) iconId else android.R.drawable.ic_dialog_info)
            .setContentTitle("Fix Appliance")
            .setContentText("Уведомления работают в фоне")
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .apply {
                if (colorId != 0) {
                    color = ContextCompat.getColor(this@CrmBackgroundGuardService, colorId)
                }
            }
            .build()
    }

    companion object {
        const val CHANNEL_ID = "crm_background"
        const val NOTIF_ID = 41

        fun start(context: Context) {
            val app = context.applicationContext
            val intent = Intent(app, CrmBackgroundGuardService::class.java)
            try {
                ContextCompat.startForegroundService(app, intent)
            } catch (_: Exception) {
            }
        }
    }
}
