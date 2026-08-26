package com.twilio.twilio_voice.types

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import java.util.Locale
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.content.PermissionChecker
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.types.ContextExtension.appName
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneNumbersPermission
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneStatePermission
import com.twilio.twilio_voice.call.TVParameters

object TelecomManagerExtension {

    /**
     *  Register a phone account with the system telecom manager
     *  @param ctx application context
     *  @param phoneAccountHandle The handle for the phone account
     *  @param label The label for the phone account
     *  @param shortDescription The short description for the phone account
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.registerPhoneAccount(ctx: Context, phoneAccountHandle: PhoneAccountHandle) {
        val existing = getPhoneAccount(phoneAccountHandle)
        if (existing != null && !existing.hasCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)) {
            // A system-managed CALL_PROVIDER account makes Android's Phone / InCallService
            // own the incoming UI (native dialer, call log, dual ring). Replace it with a
            // self-managed account so the CRM shows its own call screen.
            Log.i("TelecomManager", "registerPhoneAccount: replacing system-managed PhoneAccount with self-managed")
            unregisterPhoneAccount(phoneAccountHandle)
        }

        val label = hostString(ctx, "phone_account_name").ifEmpty { ctx.appName }
        val description = hostString(ctx, "phone_account_desc").ifEmpty {
            "Calls in $label"
        }

        val extras = Bundle().apply {
            putBoolean(PhoneAccount.EXTRA_ALWAYS_USE_VOIP_AUDIO_MODE, true)
            putBoolean(PhoneAccount.EXTRA_LOG_SELF_MANAGED_CALLS, false)
        }

        // Self-managed: the app owns incoming/in-call UI. Must not be combined with
        // CAPABILITY_CALL_PROVIDER (that surfaces calls in the system Phone app).
        val phoneAccount = PhoneAccount.builder(phoneAccountHandle, label)
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setShortDescription(description)
            .setIcon(Icon.createWithResource(ctx, ctx.applicationInfo.icon))
            .setExtras(extras)
            .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
            .build()

        registerPhoneAccount(phoneAccount)
    }

    fun TelecomManager.openPhoneAccountSettings(activity: Activity) {
        val handle = getPhoneAccountHandle(activity)
        try {
            registerPhoneAccount(activity, handle)
        } catch (error: Exception) {
            Log.w("TelecomManager", "openPhoneAccountSettings: register failed: ${error.message}")
        }

        val packageManager = activity.packageManager
        val candidateIntents = buildList {
            add(
                Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
                    putExtra(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                },
            )
            add(
                Intent(TelecomManager.ACTION_CONFIGURE_PHONE_ACCOUNT).apply {
                    putExtra(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                },
            )
            addAll(manufacturerSpecificIntents(activity))
            add(Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS))
        }

        candidateIntents.forEach { baseIntent ->
            val intent = Intent(baseIntent).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }

            if (canHandleIntent(packageManager, intent)) {
                try {
                    activity.startActivity(intent)
                    return
                } catch (error: Exception) {
                    Log.w("TelecomManager", "openPhoneAccountSettings: failed to launch ${intent.action}: ${error.message}")
                }
            }
        }

        Log.e("TelecomManager", "openPhoneAccountSettings: Unable to find compatible settings activity.")
    }

    private fun hostString(ctx: Context, name: String): String {
        val id = ctx.resources.getIdentifier(name, "string", ctx.packageName)
        if (id == 0) {
            val pluginId = ctx.resources.getIdentifier(name, "string", "com.twilio.twilio_voice")
            if (pluginId == 0) return ""
            return ctx.getString(pluginId).trim()
        }
        return ctx.getString(id).trim()
    }

    private fun manufacturerSpecificIntents(activity: Activity): List<Intent> {
        val manufacturer = Build.MANUFACTURER?.lowercase(Locale.US).orEmpty()
        val brand = Build.BRAND?.lowercase(Locale.US).orEmpty()

        if (manufacturer !in setOf("oppo", "realme") && brand !in setOf("oppo", "realme")) {
            return emptyList()
        }

        val components = listOf(
            ComponentName("com.android.settings", "com.android.settings.Settings\$DefaultAppSettingsActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppManagerActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppListActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppEntryActivity")
        )

        val explicitIntents = components.map { componentName ->
            Intent(Intent.ACTION_VIEW).apply { component = componentName }
        }

        val packagedDefaultAppsIntent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS).apply {
            `package` = "com.android.settings"
        }

        return explicitIntents + packagedDefaultAppsIntent
    }

    private fun resolveSystemComponent(packageManager: PackageManager, intent: Intent): ComponentName? {
        val matches = packageManager.queryIntentActivities(intent, 0)
        val preferred = matches.firstOrNull { resolveInfo ->
            resolveInfo.activityInfo?.applicationInfo?.flags?.and(ApplicationInfo.FLAG_SYSTEM) != 0
        } ?: matches.firstOrNull()

        return preferred?.activityInfo?.let { activityInfo ->
            ComponentName(activityInfo.packageName, activityInfo.name)
        }
    }

    private fun canHandleIntent(packageManager: PackageManager, intent: Intent): Boolean {
        return intent.resolveActivity(packageManager) != null
    }


    /**
     * Check if a phone account has been registered with the system telecom manager
     * @param ctx application context
     * @param name The name of the componentName Class (i.e. ConnectionService)
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.hasCallCapableAccount(ctx: Context, name: String): Boolean {
        val handle = getPhoneAccountHandle(ctx)
        if (handle.componentName.className != name) return false
        // Self-managed accounts are not listed in [TelecomManager.getCallCapablePhoneAccounts]
        // (that API only returns CAPABILITY_CALL_PROVIDER accounts). Check our handle directly.
        try {
            val account = getPhoneAccount(handle)
            if (account != null && account.isEnabled) return true
        } catch (error: SecurityException) {
            Log.w("TelecomManager", "hasCallCapableAccount: ${error.message}")
        }
        if (!canReadPhoneState(ctx)) return false
        return callCapablePhoneAccounts.any { it.componentName.className == name }
    }

    /**
     * Get the [PhoneAccountHandle] for the app
     * @param ctx application context
     * @return PhoneAccountHandle The phone account handle for the app
     */
    fun TelecomManager.getPhoneAccountHandle(ctx: Context): PhoneAccountHandle {
        val componentName = ComponentName(ctx, TVConnectionService::class.java)
        // Stable id: package name. Display label must not be the handle id,
        // otherwise renaming the app registers a second account.
        val id = ctx.applicationInfo.packageName
        Log.d(TVConnectionService.TAG, "getPhoneAccountHandle: id=$id component=$componentName")
        return PhoneAccountHandle(componentName, id)
    }

    /**
     * Check if the app has the READ_PHONE_STATE permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_STATE permission
     */
    fun TelecomManager.canReadPhoneState(ctx: Context): Boolean {
        return ctx.hasReadPhoneStatePermission()
    }

    /**
     * Check if the app has the READ_PHONE_NUMBERS permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_NUMBERS permission
     */
    fun TelecomManager.canReadPhoneNumbers(ctx: Context): Boolean {
        return ctx.hasReadPhoneNumbersPermission()
    }

    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.isOnCall(ctx: Context): Boolean {
        if (!canReadPhoneState(ctx)) return false
        // isInManagedCall is false for self-managed connections; isInCall includes them.
        return isInCall
    }
}