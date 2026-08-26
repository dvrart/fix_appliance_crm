package com.twilio.twilio_voice.fcm

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VoiceFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "VoiceFirebaseMessagingService"

        /**
         * Action used with [EXTRA_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val ACTION_NEW_TOKEN = "ACTION_NEW_TOKEN"

        /**
         * Extra used with [ACTION_NEW_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val EXTRA_FCM_TOKEN = "token"

        /**
         * Extra used with [ACTION_NEW_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val EXTRA_TOKEN = "token"

        const val SMS_CHANNEL_ID = "sms_messages"
        const val EMAIL_CHANNEL_ID = "email_messages"
        const val CALL_CHANNEL_ID = "incoming_calls"
        const val MORNING_CHANNEL_ID = "morning_jobs"
        const val ON_WAY_CHANNEL_ID = "on_the_way"
        const val VISIT_CONFIRM_CHANNEL_ID = "visit_confirm"
        const val VISIT_SOON_CHANNEL_ID = "visit_soon"
        const val SECRETARY_CHANNEL_ID = "secretary_learn"

        fun ensureSmsChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val ringAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            upsertChannel(manager, CALL_CHANNEL_ID, "Incoming calls", "Incoming calls and when the secretary answers", ringtone, ringAttrs)
            upsertChannel(manager, SMS_CHANNEL_ID, "SMS", "Incoming SMS and photos from clients", sound, attrs)
            upsertChannel(manager, EMAIL_CHANNEL_ID, "Email", "Incoming client emails", sound, attrs)
            upsertChannel(manager, MORNING_CHANNEL_ID, "Jobs for the day", "7:00 and 19:00 job list and what to take", sound, attrs)
            upsertChannel(manager, ON_WAY_CHANNEL_ID, "On the way", "Prompt to text the next client", sound, attrs)
            upsertChannel(manager, VISIT_CONFIRM_CHANNEL_ID, "Visit confirmation", "Client confirmed, cancelled, or asked to reschedule", sound, attrs)
            upsertChannel(manager, VISIT_SOON_CHANNEL_ID, "Upcoming visit", "Alert 1.5 hours before the next job", sound, attrs)
            upsertChannel(manager, SECRETARY_CHANNEL_ID, "Secretary learning", "Phone secretary wants to learn — confirm first", sound, attrs)
        }

        private fun upsertChannel(
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
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                    setSound(sound, attrs)
                }
            )
        }
    }

    override fun onNewToken(token: String) {
        TwilioVoiceFcm.updateToken(applicationContext, token)
    }

    /**
     * Called when message is received.
     *
     * @param remoteMessage Object representing the message received from Firebase Cloud Messaging.
     */
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        Log.d(TAG, "Received onMessageReceived()")
        Log.d(TAG, "Bundle data: " + remoteMessage.data)
        Log.d(TAG, "From: " + remoteMessage.from)
        val handled = TwilioVoiceFcm.handleMessage(applicationContext, remoteMessage.data)
        if (!handled) {
            showSmsNotification(remoteMessage)
        }
    }

    private fun showSmsNotification(remoteMessage: RemoteMessage) {
        ensureSmsChannel(this)
        val data = remoteMessage.data
        val type = data["type"] ?: ""
        val source = data["source"] ?: ""
        val channelId = data["channelId"]?.takeIf { it.isNotBlank() } ?: when {
            type == "email" || type == "email_offer" || type == "shipment" ||
                (type == "job" && source == "email") -> EMAIL_CHANNEL_ID
            type == "visit_confirm" || type == "estimate_confirm" -> VISIT_CONFIRM_CHANNEL_ID
            type == "secretary_lesson" -> SECRETARY_CHANNEL_ID
            type == "visit_soon" -> VISIT_SOON_CHANNEL_ID
            type == "on_the_way" || type == "leave_status" -> ON_WAY_CHANNEL_ID
            type == "morning" || type == "evening" -> MORNING_CHANNEL_ID
            type == "call" || type == "job" -> CALL_CHANNEL_ID
            else -> SMS_CHANNEL_ID
        }
        val title = remoteMessage.notification?.title
            ?: data["title"]
            ?: when (type) {
                "email", "email_offer" -> "Новое письмо"
                "call" -> "Входящий звонок"
                "job" -> "Новая заявка"
                "visit_confirm", "estimate_confirm" -> "Заявка"
                else -> "Fix Appliance"
            }
        val body = remoteMessage.notification?.body
            ?: data["body"]
            ?: "Сообщение от клиента"
        val tag = data["tag"]
            ?: "crm_${if (type.isEmpty()) "sms" else type}_${data["from"] ?: data["jobId"] ?: ""}".take(50)

        val launch = Intent().apply {
            setClassName(packageName, "$packageName.MainActivity")
            action = "com.fixappliance.cloud.NOTIFICATION"
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            for ((key, value) in data) {
                putExtra(key, value)
            }
        }
        val pending = PendingIntent.getActivity(
            this,
            tag.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val iconId = resources.getIdentifier("ic_stat_notify", "drawable", packageName)
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(if (iconId != 0) iconId else android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(false)
            .setDefaults(android.app.Notification.DEFAULT_ALL)
            .setCategory(
                if (type == "call") NotificationCompat.CATEGORY_CALL
                else NotificationCompat.CATEGORY_MESSAGE
            )
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(pending)
            .build()

        try {
            NotificationManagerCompat.from(this).notify(tag, 0, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot show SMS notification: ${e.message}")
        }
    }
}
