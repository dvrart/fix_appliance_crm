package com.twilio.twilio_voice.service

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
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
    // Канал без звука и вибрации: звонит только startRinging. Старый канал
    // `_incoming_voice` играл рингтон сам (FLAG_INSISTENT), и вместе с
    // startRinging выходило два рингтона разом. Звук канала после создания
    // не меняется, поэтому новый id, а старый канал удаляем.
    private const val CHANNEL_ID_SUFFIX = "_incoming_voice_silent"
    private const val LEGACY_CHANNEL_ID_SUFFIX = "_incoming_voice"
    // Match the longest AI pickup delay (60s) plus a small buffer. Shorter
    // than this would hang up while Twilio is still ringing the master.
    private const val RING_TIMEOUT_MS = 75_000L

    // Дольше звонить незачем: секретарь забирает звонок через несколько
    // секунд, и если отмена почему-то не дошла, рингтон обязан замолчать сам.
    private const val RINGER_GUARD_MS = 90_000L
    private const val RINGER_WATCHDOG_MS = 3_000L

    private val handler = Handler(Looper.getMainLooper())
    private val ringHandler = Handler(Looper.getMainLooper())
    private var timeoutGeneration = 0
    private var activeCallSid: String? = null
    private var ringtone: Ringtone? = null
    private var ringingSid: String? = null
    private var screenWakeLock: PowerManager.WakeLock? = null
    var currentNotification: Notification? = null
        private set

    fun isTestCall(): Boolean = activeCallSid?.startsWith("test_call_") == true

    fun show(context: Context, callerName: String, callSid: String) {
        val appContext = context.applicationContext
        wakeUpScreen(appContext)
        prepareHostActivityForCall(appContext)
        startRinging(appContext, callSid)
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
        if (activeCallSid == callSid && currentNotification != null) {
            openCallScreen(appContext, launchIntent, callSid)
            return
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
        val planLabel = carePlanLabel(appContext, callerName)
        val shownCaller = if (planLabel.isBlank()) callerName else "$callerName · $planLabel"

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
            shownCaller, answerPending, declinePending,
        )
        val collapsedView = buildCustomCallView(
            appContext, "notification_incoming_call_collapsed",
            shownCaller, answerPending, declinePending,
        )

        val builder = NotificationCompat.Builder(appContext, channelId(appContext))
            .setSmallIcon(R.drawable.ic_microphone)
            .setContentTitle(title)
            .setContentText(shownCaller)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
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
        activeCallSid = callSid
        currentNotification = notification

        try {
            NotificationManagerCompat.from(appContext).cancel(1001)
            NotificationManagerCompat.from(appContext).notify(NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            Log.w(TAG, "Cannot show incoming call notification: ${error.message}")
        }

        openCallScreen(appContext, launchIntent, callSid)

        val generation = ++timeoutGeneration
        handler.removeCallbacksAndMessages(null)
        if (!isPowerInteractive(appContext) || isKeyguardLocked(appContext)) {
            handler.postDelayed({
                if (generation != timeoutGeneration || activeCallSid != callSid) return@postDelayed
                wakeUpScreen(appContext)
                prepareHostActivityForCall(appContext)
                try {
                    appContext.startActivity(Intent(launchIntent))
                } catch (error: Exception) {
                    Log.w(TAG, "openCallScreen retry: ${error.message}")
                }
            }, 300L)
        }
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

    /**
     * Зажигает экран и открывает окно входящего звонка поверх блокировки
     * и других приложений.
     */
    private fun openCallScreen(context: Context, launch: Intent, callSid: String) {
        try {
            wakeUpScreen(context)
            prepareHostActivityForCall(context)
            context.startActivity(Intent(launch))
        } catch (error: Exception) {
            Log.w(TAG, "openCallScreen($callSid): ${error.message}")
        }
    }

    private fun isPowerInteractive(context: Context): Boolean {
        val power = context.getSystemService(PowerManager::class.java)
        return power?.isInteractive != false
    }

    private fun isKeyguardLocked(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        return keyguard?.isKeyguardLocked == true
    }

    @Suppress("DEPRECATION")
    private fun wakeUpScreen(context: Context) {
        try {
            val pm = context.getSystemService(PowerManager::class.java) ?: return
            val existing = screenWakeLock
            if (existing != null && existing.isHeld) {
                existing.acquire(30_000L)
                return
            }
            screenWakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "fixappliance:incoming_call_screen",
            ).apply {
                setReferenceCounted(false)
                acquire(30_000L)
            }
        } catch (error: Exception) {
            Log.w(TAG, "wakeUpScreen: ${error.message}")
        }
    }

    private fun releaseScreenWakeLock() {
        val wl = screenWakeLock ?: return
        screenWakeLock = null
        try {
            if (wl.isHeld) wl.release()
        } catch (_: Exception) {
        }
    }

    private fun prepareHostActivityForCall(context: Context) {
        try {
            Class.forName("${context.packageName}.MainActivity")
                .getMethod("prepareForIncomingCall")
                .invoke(null)
        } catch (_: Throwable) {
        }
    }

    fun cancel(context: Context, callSid: String? = null) {
        // Рингтон глушим раньше всех проверок: он мог начаться и без
        // уведомления (см. startRinging), и тогда activeCallSid пуст.
        stopRinging(context, callSid)
        if (callSid != null && activeCallSid != null && callSid != activeCallSid) return
        NotificationManagerCompat.from(context.applicationContext).cancel(1001)
        if (currentNotification == null) return
        activeCallSid = null
        currentNotification = null
        timeoutGeneration++
        handler.removeCallbacksAndMessages(null)
        NotificationManagerCompat.from(context.applicationContext).cancel(NOTIFICATION_ID)
    }

    /**
     * Звонок вслух.
     *
     * Для self-managed [android.telecom.PhoneAccount] система рингтон **не
     * играет**: телефонного UI у таких звонков нет, и звук — обязанность
     * приложения. Раньше вся надежда была на звук канала уведомления, а он у
     * foreground-уведомления службы не срабатывает: экран входящего
     * появлялся, а телефон молчал (проверено на HyperOS 12.10.2026).
     *
     * Запускается из двух мест, потому что ни на одно нельзя положиться
     * в одиночку: [show] вызывается из `onShowIncomingCallUi`, который
     * Telecom зовёт не на всех прошивках, а [TVConnectionService] зовёт это
     * сразу после `setRinging()`. Второй вызов для того же звонка —
     * пустышка.
     *
     * Режим звонка уважаем: беззвучный — молчим, вибро — только вибрируем.
     */
    fun startRinging(context: Context, callSid: String) {
        if (callSid.isNotBlank() && ringingSid == callSid) return
        val appContext = context.applicationContext
        stopRinging(appContext)
        val audio = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val mode = audio?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        if (mode == AudioManager.RINGER_MODE_SILENT) {
            Log.i(TAG, "startRinging: телефон беззвучный, звонок только на экране")
            return
        }
        ringingSid = callSid

        if (mode == AudioManager.RINGER_MODE_NORMAL) {
            try {
                val uri = RingtoneManager.getActualDefaultRingtoneUri(
                    appContext,
                    RingtoneManager.TYPE_RINGTONE,
                ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                val tone = RingtoneManager.getRingtone(appContext, uri)
                tone.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) tone.isLooping = true
                tone.play()
                ringtone = tone
            } catch (error: Exception) {
                Log.w(TAG, "startRinging: рингтон не запустился: ${error.message}")
            }
        }

        vibrator(appContext)?.let { device ->
            try {
                device.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 700, 900), 0),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            } catch (error: Exception) {
                Log.w(TAG, "startRinging: вибрация не запустилась: ${error.message}")
            }
        }

        // Сторож: на части прошивок Ringtone замолкает после одного проигрыша,
        // а до Android 9 зацикливать его вообще нечем.
        ringHandler.removeCallbacksAndMessages(null)
        val sid = callSid
        val watchdog = object : Runnable {
            override fun run() {
                if (ringingSid != sid) return
                val tone = ringtone
                if (tone != null && !tone.isPlaying) {
                    try {
                        tone.play()
                    } catch (_: Exception) {
                    }
                }
                ringHandler.postDelayed(this, RINGER_WATCHDOG_MS)
            }
        }
        ringHandler.postDelayed(watchdog, RINGER_WATCHDOG_MS)
        ringHandler.postDelayed({
            if (ringingSid != sid) return@postDelayed
            Log.w(TAG, "startRinging: отмена так и не пришла, глушим рингтон сами")
            stopRinging(appContext)
        }, RINGER_GUARD_MS)
    }

    fun stopRinging(context: Context, callSid: String? = null) {
        if (callSid != null && ringingSid != null && callSid != ringingSid) return
        ringingSid = null
        ringHandler.removeCallbacksAndMessages(null)
        releaseScreenWakeLock()
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            vibrator(context.applicationContext)?.cancel()
        } catch (_: Exception) {
        }
    }

    private fun vibrator(context: Context): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
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

    /**
     * Звонит клиент на Care Plan — подписываем шторку («· CARE PLAN»), чтобы
     * мастер видел гарантийный вызов ещё до ответа. Номера ведёт приложение
     * (`CarePlanService`, ключ `care_plan_callers` в FlutterSharedPreferences):
     * сеть здесь не нужна, а любая ошибка — просто звонок без подписи.
     */
    private fun carePlanLabel(context: Context, caller: String): String {
        return try {
            val digits = caller.filter { it.isDigit() }
            if (digits.length < 10) return ""
            val raw = context
                .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.care_plan_callers", null)
                ?: return ""
            org.json.JSONObject(raw).optString(digits.takeLast(10), "")
        } catch (error: Exception) {
            Log.w(TAG, "carePlanLabel: ${error.message}")
            ""
        }
    }

    private fun channelId(context: Context) = "${context.packageName}$CHANNEL_ID_SUFFIX"

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val id = channelId(context)
        val legacy = "${context.packageName}$LEGACY_CHANNEL_ID_SUFFIX"
        if (manager.getNotificationChannel(legacy) != null) {
            manager.deleteNotificationChannel(legacy)
        }
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
                enableVibration(false)
                setSound(null, null)
            }
        )
    }
}
