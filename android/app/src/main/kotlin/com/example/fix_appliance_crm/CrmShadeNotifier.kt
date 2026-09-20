package com.example.fix_appliance_crm

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.util.Log
import java.security.MessageDigest
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Шторка в стиле Pinterest:
 *   [иконка приложения] | Fix Appliance          10:30  [иконка типа кругом]
 *                       | Входящий звонок
 *                       | +1 (416) 555-0199
 *
 * Левый круг One UI рисует сам — значок приложения. Слот «картинки»
 * (тамбнейл справа в свёрнутом виде) — это largeIcon: большой эмодзи типа:
 *   📞 — звонок / заявка с телефона
 *   💬 — SMS
 *   ✉️ — email
 *   🔔 — напоминание / визит / брифинг
 *   🔕 — спам
 *
 * BigPictureStyle не используем: на One UI его картинка в свёрнутом виде
 * не показывается, а в развёрнутом растягивается на всю ширину.
 *
 * Данные приходят двумя путями:
 *   • из FCM в фоне: VoiceFirebaseMessagingService → showFromMap
 *   • из приложения: MethodChannel showShadeNotification → show
 */
object CrmShadeNotifier {
    private const val TAG = "CrmShadeNotifier"
    private const val ACCENT = 0xFFFCC520.toInt()

    @JvmStatic
    fun showFromMap(
        context: Context,
        raw: Any?,
        titleHint: String?,
        bodyHint: String?,
    ): Boolean {
        val data = HashMap<String, String>()
        val map = raw as? java.util.Map<*, *>
        if (map != null) {
            val keyIt = map.keySet().iterator()
            while (keyIt.hasNext()) {
                val key = keyIt.next() ?: continue
                data[key.toString()] = map[key]?.toString() ?: ""
            }
        }
        if (!titleHint.isNullOrBlank()) data["title"] = titleHint
        if (!bodyHint.isNullOrBlank()) data["body"] = bodyHint
        return show(context, data)
    }

    @JvmStatic
    @Synchronized
    fun show(context: Context, data: Map<String, String>): Boolean {
        val app = context.applicationContext
        val manager = NotificationManagerCompat.from(app)
        if (!manager.areNotificationsEnabled()) return true
        val eventId = eventIdFor(data)
        val prefs = app.getSharedPreferences("crm_shade_events", Context.MODE_PRIVATE)
        val eventKey = if (eventId.isBlank()) "" else digest(eventId)
        if (eventKey.isNotEmpty() && prefs.contains(eventKey)) return true
        try {
            AppNotificationChannels.ensure(context)
        } catch (_: Throwable) {
        }

        val type = data["type"].orEmpty()
        val source = data["source"].orEmpty()
        val spam = data["spam"] == "1"
        val channelId = data["channelId"]?.takeIf { it.isNotBlank() } ?: channelFor(type, source)
        val title = data["title"]?.takeIf { it.isNotBlank() } ?: fallbackTitle(type)
        val body = data["body"]?.takeIf { it.isNotBlank() } ?: ""
        val tag = shadeTag(data)
        // Сервер шлёт appliance, старые уведомления — applianceType.
        val appliance = data["appliance"]?.takeIf { it.isNotBlank() }
            ?: data["applianceType"].orEmpty()
        val name = data["clientName"]?.takeIf { it.isNotBlank() }
            ?: guessName(title, peerOf(data))

        // «Картинка» — большой эмодзи типа; иконку приложения One UI
        // рисует сама в левом круге.
        val badge = buildTypeBadge(app, type, source, spam)

        // Маленькая иконка в статусбаре — всегда значок приложения.
        val appIconId = app.resources.getIdentifier("ic_stat_notify", "drawable", app.packageName)
        val smallIconId = if (appIconId != 0) appIconId else android.R.drawable.ic_dialog_info

        // Краткий текст: имя · техника (или первая строка тела).
        val subText = listOf(name, appliance)
            .filter { it.isNotBlank() && it != "—" }
            .joinToString(" · ")
        val previewText = subText.ifBlank {
            body.lines().firstOrNull { it.isNotBlank() }?.trim().orEmpty()
        }

        val launch = Intent().apply {
            setClassName(app.packageName, "${app.packageName}.MainActivity")
            action = "com.example.fix_appliance_crm.NOTIFICATION"
            addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK,
            )
            for ((key, value) in data) putExtra(key, value)
        }
        val pending = PendingIntent.getActivity(
            app,
            tag.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(app, channelId)
            .setSmallIcon(smallIconId)
            .setContentTitle(title)
            .setContentText(previewText)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(if (body.isNotBlank()) body else subText),
            )
            .setColor(ACCENT)
            .setColorized(false)
            .setAutoCancel(false)
            .setDefaults(android.app.Notification.DEFAULT_ALL)
            .setCategory(
                if (type == "call") NotificationCompat.CATEGORY_CALL
                else NotificationCompat.CATEGORY_MESSAGE,
            )
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setNumber(1)
            .setContentIntent(pending)

        if (badge != null) builder.setLargeIcon(badge)

        try {
            cancelRelated(manager, data, tag)
            manager.notify(tag, 0, builder.build())
            if (eventKey.isNotEmpty()) {
                val now = System.currentTimeMillis()
                val editor = prefs.edit().putLong(eventKey, now)
                prefs.all.entries.sortedByDescending { (it.value as? Long) ?: 0L }
                    .forEachIndexed { index, entry ->
                        if (index >= 999 || ((entry.value as? Long) ?: 0L) < now - 7 * 86_400_000L) {
                            editor.remove(entry.key)
                        }
                    }
                editor.apply()
            }
            return true
        } catch (e: Exception) {
            Log.w(TAG, "Cannot show shade: ${e.message}")
            return false
        }
    }

    // ─── Большой эмодзи типа как «картинка» ─────────────────────────────────

    /**
     * Эмодзи типа уведомления (📞/💬/✉️/🔔) крупно на прозрачном Bitmap.
     * Векторные drawable на части прошивок молча не рисуются на Canvas —
     * текст эмодзи надёжнее и читается сразу.
     */
    private fun buildTypeBadge(
        context: Context,
        type: String,
        source: String,
        spam: Boolean,
    ): Bitmap? {
        return try {
            val density = context.resources.displayMetrics.density
            val size = (72 * density).toInt().coerceIn(128, 256)
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            drawTypeBadge(Canvas(bmp), size / 2f, size / 2f, size / 2f, type, source, spam)
            bmp
        } catch (e: Exception) {
            Log.w(TAG, "buildTypeBadge: ${e.message}")
            null
        }
    }

    /** Рисует эмодзи типа крупно по центру (cx, cy), бюджет — круг радиуса [r]. */
    private fun drawTypeBadge(
        canvas: Canvas,
        cx: Float,
        cy: Float,
        r: Float,
        type: String,
        source: String,
        spam: Boolean,
    ) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = r * 1.5f
            textAlign = Paint.Align.CENTER
        }
        val y = cy - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(typeEmoji(type, source, spam), cx, y, paint)
    }

    /**
     * Тот же значок типа в PNG — для flutter_local_notifications fallback
     * (MethodChannel typeBadgeBytes), чтобы бейдж не пропадал, когда
     * нативный путь недоступен или уведомление запланировано заранее.
     */
    @JvmStatic
    fun badgePng(
        context: Context,
        type: String,
        source: String,
        spam: Boolean,
    ): ByteArray? {
        val bmp = buildTypeBadge(context, type, source, spam) ?: return null
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    /** Эмодзи по типу уведомления (📞/✉️/�/💬/�). */
    private fun typeEmoji(type: String, source: String, spam: Boolean): String = when {
        spam -> "🔕"
        type == "email" || type == "email_offer" || type == "shipment" ||
            (type == "job" && (source == "email" || source == "website")) -> "✉️"
        type == "call" || (type == "job" && source !in setOf("email", "website", "sms")) -> "📞"
        type == "visit_confirm" || type == "estimate_confirm" ||
            type == "visit_soon" || type == "on_the_way" ||
            type == "leave_status" || type == "morning" ||
            type == "evening" || type == "secretary_lesson" -> "🔔"
        else -> "💬"
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private fun last10(raw: String): String {
        val digits = raw.filter { it.isDigit() }
        return if (digits.length >= 10) digits.takeLast(10) else ""
    }

    /**
     * Номер собеседника. FCM запрещает ключ `from` в данных и отклоняет всё
     * сообщение целиком, поэтому сервер шлёт его как `peer`. Старые локальные
     * уведомления из приложения всё ещё кладут `from` — читаем оба.
     */
    private fun peerOf(data: Map<String, String>): String =
        data["peer"]?.takeIf { it.isNotBlank() } ?: data["from"].orEmpty()

    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }

    private fun boundedTag(value: String): String =
        if (value.length <= 50) value else "${value.take(16)}_${digest(value).take(32)}"

    fun shadeTag(data: Map<String, String>): String {
        val from = peerOf(data).ifBlank { data["to"].orEmpty() }.trim()
        if (from.contains('@')) return boundedTag("crm_inbox_${from.lowercase()}")
        val phone = last10(from)
        if (phone.isNotEmpty()) return "crm_inbox_$phone"
        data["tag"]?.takeIf { it.isNotBlank() }?.let { return boundedTag(it) }
        val type = data["type"].orEmpty().ifBlank { "sms" }
        val key = listOf("callSid", "callId", "messageId", "jobId")
            .firstNotNullOfOrNull { data[it]?.takeIf { value -> value.isNotBlank() } } ?: "inbox"
        return boundedTag("crm_${type}_$key")
    }

    fun eventIdFor(data: Map<String, String>): String {
        data["eventId"]?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        val type = data["type"].orEmpty()
        val source = data["source"].orEmpty()
        val callId = listOf("callSid", "callId", "sourceCallId")
            .firstNotNullOfOrNull { data[it]?.takeIf { value -> value.isNotBlank() } }
        if (type == "call" && callId != null) return "call:$callId"
        val messageId = listOf("messageId", "sourceEmailId", "sourceSmsId")
            .firstNotNullOfOrNull { data[it]?.takeIf { value -> value.isNotBlank() } }
        if (messageId != null) {
            val email = type == "email" || type == "email_offer" || source == "email" || source == "website"
            return "${if (email) "email" else "sms"}:$messageId"
        }
        if (type == "job" && callId != null) return "call:$callId"
        if (type == "job" && !data["jobId"].isNullOrBlank()) return "job:${data["jobId"]}"
        return ""
    }

    private fun cancelRelated(
        manager: NotificationManagerCompat,
        data: Map<String, String>,
        keep: String,
    ) {
        val from = peerOf(data)
        val to = data["to"].orEmpty()
        val jobId = data["jobId"].orEmpty()
        val phone = last10(from.ifBlank { to })
        val variants = linkedSetOf(from, to, jobId, data["tag"].orEmpty())
        if (phone.isNotEmpty()) {
            variants += setOf(phone, "+1$phone", "1$phone", "+$phone", "crm_inbox_$phone")
        }
        val tags = linkedSetOf<String>()
        for (t in listOf("call", "job", "sms", "inbox")) {
            for (v in variants) {
                if (v.isBlank()) continue
                tags.add("crm_${t}_$v".take(50))
            }
        }
        tags.add(keep)
        for (old in tags) {
            if (old.isBlank() || old == keep) continue
            try {
                manager.cancel(old, 0)
            } catch (_: Exception) {
            }
        }
    }

    private fun channelFor(type: String, source: String): String = when {
        type == "email" || type == "email_offer" || type == "shipment" ||
            (type == "job" && (source == "email" || source == "website")) -> AppNotificationChannels.EMAIL
        type == "visit_confirm" || type == "estimate_confirm" -> AppNotificationChannels.VISIT_CONFIRM
        type == "secretary_lesson" -> AppNotificationChannels.SECRETARY_LEARN
        type == "visit_soon" -> AppNotificationChannels.VISIT_SOON
        type == "on_the_way" || type == "leave_status" -> AppNotificationChannels.ON_WAY
        type == "morning" || type == "evening" -> AppNotificationChannels.MORNING
        type == "call" || (type == "job" && source != "sms") -> AppNotificationChannels.CALL
        else -> AppNotificationChannels.SMS
    }

    private fun fallbackTitle(type: String): String = when (type) {
        "email", "email_offer" -> "Новое письмо"
        "call" -> "Входящий звонок"
        "job" -> "Новая заявка"
        "visit_confirm", "estimate_confirm" -> "Заявка"
        else -> "Fix Appliance"
    }

    private fun guessName(title: String, from: String): String {
        val prefixes = listOf(
            "SMS от ",
            "Письмо от ",
            "Письмо о ремонте",
            "Заявка с почты",
            "Заявка с телефона",
            "Заявка из SMS",
            "Заявка с SMS",
            "Входящий звонок",
            "ИИ взял звонок",
        )
        var raw = title.trim()
        for (prefix in prefixes) {
            if (raw.startsWith(prefix, ignoreCase = true)) {
                raw = raw.substring(prefix.length).trim()
                break
            }
        }
        if (raw.isNotBlank() && raw != title.trim()) return raw
        return from.ifBlank { "Клиент" }
    }
}
