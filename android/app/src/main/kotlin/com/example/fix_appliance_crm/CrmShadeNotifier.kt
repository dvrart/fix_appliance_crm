package com.example.fix_appliance_crm

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.util.Log
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Шторка как у Pinterest: три скруглённые картинки
 * (техника / имя / город) под системной шапкой приложения.
 */
object CrmShadeNotifier {
    private const val TAG = "CrmShadeNotifier"
    private const val NAVY = 0xFF14557F.toInt()
    private const val ACCENT = 0xFFFCC520.toInt()

    @JvmStatic
    fun showFromMap(
        context: Context,
        raw: Any?,
        titleHint: String?,
        bodyHint: String?,
    ) {
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
        show(context, data)
    }

    @JvmStatic
    fun show(context: Context, data: Map<String, String>) {
        AppColorsEnsure(context)
        val type = data["type"].orEmpty()
        val source = data["source"].orEmpty()
        val channelId = data["channelId"]?.takeIf { it.isNotBlank() } ?: channelFor(type, source)
        val title = data["title"]?.takeIf { it.isNotBlank() } ?: fallbackTitle(type)
        val body = data["body"]?.takeIf { it.isNotBlank() } ?: ""
        val tag = shadeTag(data)
        val appliance = data["applianceType"].orEmpty()
        val name = data["clientName"]?.takeIf { it.isNotBlank() }
            ?: guessName(title, data["from"].orEmpty())
        val city = data["city"]?.takeIf { it.isNotBlank() } ?: "—"

        val app = context.applicationContext
        val density = app.resources.displayMetrics.density
        val tileW = (112 * density).toInt().coerceIn(160, 280)
        val tileH = (72 * density).toInt().coerceIn(96, 180)
        val radius = 14f * density

        val applianceBmp = rounded(
            applianceTile(app, appliance, tileW, tileH),
            radius,
        )
        val nameBmp = rounded(textTile(name.ifBlank { "Клиент" }, tileW, tileH), radius)
        val cityBmp = rounded(textTile(city, tileW, tileH), radius)

        val collapsed = RemoteViews(app.packageName, R.layout.notification_shade_collapsed)
        collapsed.setImageViewBitmap(R.id.shade_tile_1, applianceBmp)
        collapsed.setImageViewBitmap(R.id.shade_tile_2, nameBmp)
        collapsed.setImageViewBitmap(R.id.shade_tile_3, cityBmp)

        val expanded = RemoteViews(app.packageName, R.layout.notification_shade_expanded)
        expanded.setImageViewBitmap(R.id.shade_tile_1, applianceBmp)
        expanded.setImageViewBitmap(R.id.shade_tile_2, nameBmp)
        expanded.setImageViewBitmap(R.id.shade_tile_3, cityBmp)
        expanded.setTextViewText(R.id.shade_title, title)
        expanded.setTextViewText(R.id.shade_body, body)
        expanded.setViewVisibility(
            R.id.shade_body,
            if (body.isBlank()) android.view.View.GONE else android.view.View.VISIBLE,
        )

        val launch = Intent().apply {
            setClassName(app.packageName, "${app.packageName}.MainActivity")
            action = "com.example.fix_appliance_crm.NOTIFICATION"
            addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK,
            )
            for ((key, value) in data) {
                putExtra(key, value)
            }
        }
        val pending = PendingIntent.getActivity(
            app,
            tag.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val iconId = app.resources.getIdentifier("ic_stat_notify", "drawable", app.packageName)
        val notification = NotificationCompat.Builder(app, channelId)
            .setSmallIcon(if (iconId != 0) iconId else android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(listOf(name, city).filter { it.isNotBlank() && it != "—" }.joinToString(" · "))
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
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(collapsed)
            .setCustomBigContentView(expanded)
            .setCustomHeadsUpContentView(collapsed)
            .build()

        try {
            val manager = NotificationManagerCompat.from(app)
            cancelRelated(manager, data, tag)
            manager.notify(tag, 0, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot show shade: ${e.message}")
        }
    }

    private fun last10(raw: String): String {
        val digits = raw.filter { it.isDigit() }
        return if (digits.length >= 10) digits.takeLast(10) else ""
    }

    private fun shadeTag(data: Map<String, String>): String {
        val from = data["from"].orEmpty().ifBlank { data["to"].orEmpty() }
        val phone = last10(from)
        if (phone.isNotEmpty()) return "crm_inbox_$phone".take(50)
        val email = when {
            from.contains('@') -> from.trim().lowercase()
            else -> ""
        }
        if (email.isNotEmpty()) return "crm_inbox_$email".take(50)
        val type = data["type"].orEmpty().ifBlank { "sms" }
        val key = data["callSid"].orEmpty().ifBlank {
            data["callId"].orEmpty().ifBlank {
                data["messageId"].orEmpty().ifBlank {
                    data["jobId"].orEmpty().ifBlank { "inbox" }
                }
            }
        }
        return "crm_${type}_$key".take(50)
    }

    private fun cancelRelated(
        manager: NotificationManagerCompat,
        data: Map<String, String>,
        keep: String,
    ) {
        val from = data["from"].orEmpty()
        val to = data["to"].orEmpty()
        val jobId = data["jobId"].orEmpty()
        val phone = last10(from.ifBlank { to })
        val variants = linkedSetOf(from, to, jobId, data["tag"].orEmpty())
        if (phone.isNotEmpty()) {
            variants.add(phone)
            variants.add("+1$phone")
            variants.add("1$phone")
            variants.add("+$phone")
            variants.add("crm_inbox_$phone")
        }
        val types = listOf("call", "job", "sms", "inbox")
        val tags = linkedSetOf<String>()
        for (type in types) {
            for (value in variants) {
                if (value.isBlank()) continue
                tags.add("crm_${type}_$value".take(50))
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

    private fun AppColorsEnsure(context: Context) {
        try {
            AppNotificationChannels.ensure(context)
        } catch (_: Throwable) {
        }
    }

    private fun channelFor(type: String, source: String): String {
        return when {
            type == "email" || type == "email_offer" || type == "shipment" ||
                (type == "job" && source == "email") -> AppNotificationChannels.EMAIL
            type == "visit_confirm" || type == "estimate_confirm" -> AppNotificationChannels.VISIT_CONFIRM
            type == "secretary_lesson" -> AppNotificationChannels.SECRETARY_LEARN
            type == "visit_soon" -> AppNotificationChannels.VISIT_SOON
            type == "on_the_way" || type == "leave_status" -> AppNotificationChannels.ON_WAY
            type == "morning" || type == "evening" -> AppNotificationChannels.MORNING
            type == "call" || type == "job" -> AppNotificationChannels.CALL
            else -> AppNotificationChannels.SMS
        }
    }

    private fun fallbackTitle(type: String): String {
        return when (type) {
            "email", "email_offer" -> "Новое письмо"
            "call" -> "Входящий звонок"
            "job" -> "Новая заявка"
            "visit_confirm", "estimate_confirm" -> "Заявка"
            else -> "Fix Appliance"
        }
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

    private fun applianceFile(type: String): String {
        val t = type.lowercase()
        return when {
            t.contains("мороз") || t.contains("freezer") -> "freezer.png"
            t.contains("холод") || t.contains("fridge") || t.contains("refrigerator") -> "fridge.png"
            t.contains("посуд") || t.contains("dish") -> "dishwasher.png"
            t.contains("стирал") || t.contains("washer") || t.contains("washing") -> "washer.png"
            t.contains("суш") || t.contains("dryer") -> "dryer.png"
            t.contains("вароч") || t.contains("cooktop") || t.contains("hob") || t.contains("конфорк") -> "cooktop.png"
            t.contains("плит") || t.contains("духов") || t.contains("stove") || t.contains("oven") || t.contains("range") -> "stove.png"
            t.contains("микроволн") || t.contains("microwave") -> "microwave.png"
            else -> "other.png"
        }
    }

    private fun applianceTile(context: Context, type: String, width: Int, height: Int): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.WHITE)
        val photo = loadAppliance(context, applianceFile(type))
        if (photo != null) {
            val pad = (width * 0.08f).toInt()
            val dst = android.graphics.Rect(pad, pad, width - pad, height - pad)
            val src = android.graphics.Rect(0, 0, photo.width, photo.height)
            val fit = fitCenter(src, dst)
            canvas.drawBitmap(photo, src, fit, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
            if (photo != bmp) photo.recycle()
        } else {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = NAVY
                style = Paint.Style.STROKE
                strokeWidth = width * 0.04f
            }
            canvas.drawRoundRect(
                RectF(width * 0.22f, height * 0.18f, width * 0.78f, height * 0.82f),
                16f,
                16f,
                paint,
            )
        }
        return bmp
    }

    private fun fitCenter(src: android.graphics.Rect, dst: android.graphics.Rect): android.graphics.Rect {
        val scale = minOf(dst.width().toFloat() / src.width(), dst.height().toFloat() / src.height())
        val w = (src.width() * scale).toInt()
        val h = (src.height() * scale).toInt()
        val left = dst.centerX() - w / 2
        val top = dst.centerY() - h / 2
        return android.graphics.Rect(left, top, left + w, top + h)
    }

    private fun loadAppliance(context: Context, file: String): Bitmap? {
        val paths = listOf(
            "flutter_assets/assets/appliances/$file",
            "assets/appliances/$file",
            file,
        )
        for (path in paths) {
            try {
                context.assets.open(path).use { stream ->
                    return BitmapFactory.decodeStream(stream)
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun textTile(text: String, width: Int, height: Int): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(NAVY)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            textAlign = Paint.Align.LEFT
            textSize = height * 0.26f
        }
        val label = text.trim().ifEmpty { "—" }
        val maxWidth = (width * 0.86f).toInt().coerceAtLeast(8)
        var layout = buildLayout(label, paint, maxWidth)
        while (layout.height > height * 0.78f && paint.textSize > height * 0.14f) {
            paint.textSize *= 0.9f
            layout = buildLayout(label, paint, maxWidth)
        }
        canvas.save()
        canvas.translate((width - maxWidth) / 2f, (height - layout.height) / 2f)
        layout.draw(canvas)
        canvas.restore()
        return bmp
    }

    private fun buildLayout(text: String, paint: TextPaint, width: Int): StaticLayout {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setMaxLines(2)
                .setEllipsize(TextUtils.TruncateAt.END)
                .setIncludePad(false)
                .build()
        } else {
            @Suppress("DEPRECATION")
            StaticLayout(text, paint, width, Layout.Alignment.ALIGN_CENTER, 1f, 0f, false)
        }
    }

    private fun rounded(src: Bitmap, radius: Float): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val rect = RectF(0f, 0f, src.width.toFloat(), src.height.toFloat())
        canvas.drawRoundRect(rect, radius, radius, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(src, 0f, 0f, paint)
        if (src != out) src.recycle()
        return out
    }
}
