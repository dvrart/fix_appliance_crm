package com.example.fix_appliance_crm

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Двойная короткая вибрация «клиент на линии» (просьба FIX, 27.10.2026).
 * У звонка через приложение её зовёт Flutter, когда поднялся звук или клиент
 * ответил; у звонка через SIM — пуш `call_connected` с сервера.
 */
object CallConnectedBuzz {
    private val pattern = longArrayOf(0, 110, 90, 110)

    @JvmStatic
    fun vibrate(context: Context) {
        try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator == null || !vibrator.hasVibrator()) return
            val effect = VibrationEffect.createWaveform(pattern, -1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                vibrator.vibrate(
                    effect,
                    VibrationAttributes.createForUsage(VibrationAttributes.USAGE_COMMUNICATION_REQUEST),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    effect,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
                        .build(),
                )
            }
        } catch (_: Exception) {
        }
    }
}
