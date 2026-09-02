package com.twilio.twilio_voice.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.twilio.twilio_voice.R

/**
 * Incoming-call UI for a self-managed [android.telecom.PhoneAccount].
 *
 * Android will not show the system Phone / InCallService UI for self-managed
 * connections. The app must post a high-priority notification with a
 * full-screen intent (see [android.telecom.Connection.onShowIncomingCallUi]).
 */
object IncomingCallNotifier {

    const val EXTRA_INCOMING_CALL = "twilio_incoming_call"

    private const val TAG = "IncomingCallNotifier"
    private const val NOTIFICATION_ID = 1001
    private const val CHANNEL_ID_SUFFIX = "_incoming_voice"
    // Match the longest AI pickup delay (60s) plus a small buffer. Shorter
    // than this would hang up while Twilio is still ringing the master.
    private const val RING_TIMEOUT_MS = 75_000L

    private val handler = Handler(Looper.getMainLooper())
    private var timeoutGeneration = 0

    fun show(context: Context, callerName: String, callSid: String) {
        val appContext = context.applicationContext
        ensureChannel(appContext)

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launchIntent = (appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
            ?: Intent()).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                    Intent.FLAG_ACTIVITY_NO_USER_ACTION
            )
            putExtra(EXTRA_INCOMING_CALL, true)
        }
        val contentIntent = PendingIntent.getActivity(appContext, 0, launchIntent, flags)

        val answerIntent = Intent(appContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_ANSWER
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
        }
        val declineIntent = Intent(appContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_HANGUP
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
        }
        val answerPending = PendingIntent.getForegroundService(appContext, 1, answerIntent, flags)
        val declinePending = PendingIntent.getForegroundService(appContext, 2, declineIntent, flags)

        val title = appContext.getString(R.string.incoming_call_title)
        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val notification = NotificationCompat.Builder(appContext, channelId(appContext))
            .setSmallIcon(R.drawable.ic_microphone)
            .setContentTitle(title)
            .setContentText(callerName)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSound(ringtone)
            .setContentIntent(contentIntent)
            .setFullScreenIntent(contentIntent, true)
            .addAction(android.R.drawable.sym_action_call, appContext.getString(R.string.incoming_call_answer), answerPending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, appContext.getString(R.string.incoming_call_decline), declinePending)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
        notification.flags = notification.flags or Notification.FLAG_INSISTENT

        try {
            NotificationManagerCompat.from(appContext).notify(NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            Log.w(TAG, "Cannot show incoming call notification: ${error.message}")
        }

        val generation = ++timeoutGeneration
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({
            if (generation != timeoutGeneration) return@postDelayed
            Log.w(TAG, "incoming UI timed out for $callSid — dropping stale ring")
            cancel(appContext)
            val hangup = Intent(appContext, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext.startForegroundService(hangup)
                } else {
                    appContext.startService(hangup)
                }
            } catch (error: Exception) {
                Log.w(TAG, "Cannot hang up stale incoming: ${error.message}")
            }
        }, RING_TIMEOUT_MS)
    }

    fun cancel(context: Context) {
        timeoutGeneration++
        handler.removeCallbacksAndMessages(null)
        NotificationManagerCompat.from(context.applicationContext).cancel(NOTIFICATION_ID)
    }

    private fun channelId(context: Context) = "${context.packageName}$CHANNEL_ID_SUFFIX"

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val id = channelId(context)
        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val existing = manager.getNotificationChannel(id)
        if (existing != null) {
            val soundOk = existing.sound != null
            val importanceOk = existing.importance >= NotificationManager.IMPORTANCE_MAX
            if (soundOk && importanceOk) return
            manager.deleteNotificationChannel(id)
        }
        manager.createNotificationChannel(
            NotificationChannel(
                id,
                context.getString(R.string.incoming_call_channel_name),
                NotificationManager.IMPORTANCE_MAX,
            ).apply {
                description = context.getString(R.string.incoming_call_channel_name)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                setSound(ringtone, audioAttributes)
            }
        )
    }
}
