package com.example.fix_appliance_crm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

object AppNotificationChannels {
    const val SMS = "sms_messages"
    const val EMAIL = "email_messages"
    const val CALL = "incoming_calls"
    const val MORNING = "morning_jobs"
    const val ON_WAY = "on_the_way"
    const val VISIT_CONFIRM = "visit_confirm"
    const val VISIT_SOON = "visit_soon"
    const val SECRETARY_LEARN = "secretary_learn"

    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val notificationSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val ringAttrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        upsert(manager, CALL, "Incoming calls", "Incoming calls and when the secretary answers", ringtone, ringAttrs)
        upsert(manager, SMS, "SMS", "Incoming SMS and photos from clients", notificationSound, attrs)
        upsert(manager, EMAIL, "Email", "Incoming client emails", notificationSound, attrs)
        upsert(manager, MORNING, "Jobs for the day", "7:00 and 19:00 job list and what to take", notificationSound, attrs)
        upsert(manager, ON_WAY, "On the way", "Prompt to text the next client", notificationSound, attrs)
        upsert(manager, VISIT_CONFIRM, "Visit confirmation", "Client confirmed, cancelled, or asked to reschedule", notificationSound, attrs)
        upsert(manager, VISIT_SOON, "Upcoming visit", "Alert 1.5 hours before the next job", notificationSound, attrs)
        upsert(manager, SECRETARY_LEARN, "Secretary learning", "Phone secretary wants to learn — confirm first", notificationSound, attrs)
    }

    private fun upsert(
        manager: NotificationManager,
        id: String,
        name: String,
        description: String,
        sound: android.net.Uri,
        attrs: AudioAttributes,
    ) {
        val existing = manager.getNotificationChannel(id)
        if (existing != null) return
        manager.createNotificationChannel(
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_MAX).apply {
                this.description = description
                enableVibration(true)
                enableLights(true)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(sound, attrs)
            }
        )
    }
}
