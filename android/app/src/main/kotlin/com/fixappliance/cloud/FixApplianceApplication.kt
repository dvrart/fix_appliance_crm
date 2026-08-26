package com.fixappliance.cloud

import android.app.Application

class FixApplianceApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            AppNotificationChannels.ensure(this)
        } catch (_: Throwable) {
        }
        try {
            val tapToPay = Class.forName("com.stripe.stripeterminal.taptopay.TapToPay")
            val inProcess = tapToPay.getMethod("isInTapToPayProcess").invoke(null) as? Boolean
            if (inProcess == true) return
        } catch (_: Throwable) {
            // Плагин Stripe Terminal ещё не в classpath этого процесса
        }
        try {
            val delegate = Class.forName("com.stripe.stripeterminal.TerminalApplicationDelegate")
            delegate.getMethod("onCreate", Application::class.java).invoke(null, this)
        } catch (_: Throwable) {
            // TerminalApplicationDelegate вызывается ещё и из Flutter-плагина
        }
    }
}
