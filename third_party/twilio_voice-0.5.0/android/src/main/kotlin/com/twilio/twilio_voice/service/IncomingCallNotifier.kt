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
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.twilio.twilio_voice.R

/**
 * Incoming-call UI for a self-managed [android.telecom.PhoneAccount].
 *
 * Android will not show the system Phone / InCallService UI for self-managed
 * connections. The app must post a high-priority notification with a
 * full-screen intent (see [android.telecom.Connection.onShowIncomingCallUi]).
 *
 * The expanded / heads-up view shows a custom layout loaded from the host-app
 * resources: `notification_incoming_call.xml`. That layout provides a green
 * "Ответить" button and a red "Отклонить" button. If the host-app resource is
 * not found, the notification falls back to standard action buttons.
 */
object IncomingCallNotifier {

    const val EXTRA_INCOMING_CALL = "twilio_incoming_call"

    private const val TAG = "IncomingCallNotifier"
    private const val NOTIFICATION_ID = TVConnectionService.FOREGROUND_NOTIFICATION_ID
    private const val CHANNEL_ID_SUFFIX = "_incoming_voice"
    // Match the longest AI pickup delay (60s) plus a small buffer. Shorter
    // than this would hang up while Twilio is still ringing the master.
    private const val RING_TIMEOUT_MS = 75_000L

    private val handler = Handler(Looper.getMainLooper())
    private var timeoutGeneration = 0
    private var activeCallSid: String? = null
    var currentNotification: Notification? = null
        private set

    fun show(context: Context, callerName: String, callSid: String) {
        if (activeCallSid == callSid && currentNotification != null) return
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
            action = TVConnectionService.ACTION_DECLINE_INCOMING
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
        }
        val answerPending = PendingIntent.getForegroundService(appContext, 1, answerIntent, flags)
        val declinePending = PendingIntent.getForegroundService(appContext, 2, declineIntent, flags)

        val title = appContext.getString(R.string.incoming_call_title)
        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        // Полный экран при входящем звонке требует USE_FULL_SCREEN_INTENT.
        // На Android 14+ разрешение может быть отозвано — логируем это.
        if (Build.VERSION.SDK_INT >= 34) {
            val nm = appContext.getSystemService(NotificationManager::class.java)
            if (nm != null && !nm.canUseFullScreenIntent()) {
                Log.w(
                    TAG,
                    "USE_FULL_SCREEN_INTENT denied — call shows as heads-up only. " +
                        "Enable in Settings → Apps → FIX → Full-screen notifications",
                )
            }
        }

        // Кастомные виды с зелёной «Ответить» и красной «Отклонить» кнопками.
        // Ресурсы лежат в приложении — грузим по имени через getIdentifier.
        val expandedView = buildCustomCallView(
            appContext, "notification_incoming_call",
            callerName, answerPending, declinePending,
        )
        val collapsedView = buildCustomCallView(
            appContext, "notification_incoming_call_collapsed",
            callerName, answerPending, declinePending,
        )

        val builder = NotificationCompat.Builder(appContext, channelId(appContext))
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
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        if (expandedView != null) {
            // Кастомный вид: зелёная и красная кнопки через RemoteViews.
            builder.setStyle(NotificationCompat.DecoratedCustomViewStyle())
                .setCustomBigContentView(expandedView)
                .setCustomHeadsUpContentView(expandedView)
            if (collapsedView != null) {
                builder.setCustomContentView(collapsedView)
            }
        } else {
            // Fallback: стандартные action-кнопки.
            builder.addAction(
                android.R.drawable.sym_action_call,
                appContext.getString(R.string.incoming_call_answer),
                answerPending,
            )
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                appContext.getString(R.string.incoming_call_decline),
                declinePending,
            )
        }

        val notification = builder.build()
        notification.flags = notification.flags or Notification.FLAG_INSISTENT
        activeCallSid = callSid
        currentNotification = notification

        try {
            NotificationManagerCompat.from(appContext).cancel(1001)
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

    fun cancel(context: Context, callSid: String? = null) {
        if (callSid != null && callSid != activeCallSid) return
        NotificationManagerCompat.from(context.applicationContext).cancel(1001)
        if (currentNotification == null) return
        activeCallSid = null
        currentNotification = null
        timeoutGeneration++
        handler.removeCallbacksAndMessages(null)
        NotificationManagerCompat.from(context.applicationContext).cancel(NOTIFICATION_ID)
    }

    /**
     * Строит RemoteViews из кастомного layout приложения (notification_incoming_call.xml).
     * Ресурсы приложения загружаются по имени (getIdentifier), чтобы избежать
     * compile-time зависимости между плагином и приложением.
     * Возвращает null, если ресурс не найден или произошла ошибка.
     */
    private fun buildCustomCallView(
        context: Context,
        layoutName: String,
        callerName: String,
        answerPending: PendingIntent,
        declinePending: PendingIntent,
    ): RemoteViews? {
        return try {
            val pkg = context.packageName
            val res = context.resources

            val layoutId = res.getIdentifier(layoutName, "layout", pkg)
            if (layoutId == 0) {
                Log.w(TAG, "$layoutName layout not found in $pkg")
                return null
            }

            val views = RemoteViews(pkg, layoutId)

            val callerViewId = res.getIdentifier("call_caller", "id", pkg)
            val answerBtnId = res.getIdentifier("btn_answer", "id", pkg)
            val declineBtnId = res.getIdentifier("btn_decline", "id", pkg)

            if (callerViewId != 0 && callerName.isNotBlank()) {
                views.setTextViewText(callerViewId, callerName)
            }
            if (answerBtnId != 0) {
                views.setOnClickPendingIntent(answerBtnId, answerPending)
            }
            if (declineBtnId != 0) {
                views.setOnClickPendingIntent(declineBtnId, declinePending)
            }

            views
        } catch (e: Exception) {
            Log.w(TAG, "buildCustomCallView failed: ${e.message}")
            null
        }
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
        if (existing != null) return
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
