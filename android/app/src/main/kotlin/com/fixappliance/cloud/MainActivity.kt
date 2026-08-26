package com.fixappliance.cloud

import android.Manifest
import android.app.KeyguardManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import kotlin.math.max
import kotlin.math.sin
import android.util.SparseIntArray
import com.twilio.twilio_voice.service.IncomingCallNotifier
import com.twilio.twilio_voice.service.TVConnectionService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val savedBeepVolumes = SparseIntArray()
    private var deviceChannel: MethodChannel? = null
    @Volatile private var ringbackPlaying = false
    private var ringbackTrack: AudioTrack? = null
    private var ringbackThread: Thread? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fix_appliance/device")
            .also { deviceChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBluetoothOn" -> result.success(bluetoothAdapter()?.isEnabled == true)
                    "hasCarAudio" -> result.success(hasCarAudio())
                    "playOutgoingRingback" -> {
                        playOutgoingRingback()
                        result.success(true)
                    }
                    "stopOutgoingRingback" -> {
                        stopOutgoingRingback()
                        result.success(true)
                    }
                    "requestBluetooth" -> {
                        val adapter = bluetoothAdapter()
                        if (adapter == null) {
                            result.error("unavailable", "Bluetooth unavailable", null)
                        } else if (adapter.isEnabled) {
                            result.success(true)
                        } else {
                            startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                            result.success(false)
                        }
                    }
                    "openNotificationSettings" -> {
                        val intent = Intent().apply {
                            action = android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS
                            putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations())
                    }
                    "muteRecognitionBeeps" -> {
                        muteRecognitionBeeps(call.arguments == true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        notifyNotificationTap(intent)
    }

    private fun muteRecognitionBeeps(mute: Boolean) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val streams = intArrayOf(
            AudioManager.STREAM_SYSTEM,
            AudioManager.STREAM_NOTIFICATION,
        )
        for (stream in streams) {
            try {
                if (mute) {
                    savedBeepVolumes.put(stream, am.getStreamVolume(stream))
                    if (Build.VERSION.SDK_INT >= 23) {
                        am.adjustStreamVolume(stream, AudioManager.ADJUST_MUTE, 0)
                    } else {
                        @Suppress("DEPRECATION")
                        am.setStreamMute(stream, true)
                    }
                } else {
                    if (Build.VERSION.SDK_INT >= 23) {
                        am.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
                    } else {
                        @Suppress("DEPRECATION")
                        am.setStreamMute(stream, false)
                    }
                    val saved = savedBeepVolumes.get(stream, -1)
                    if (saved >= 0) {
                        am.setStreamVolume(stream, saved, 0)
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun hasCarAudio(): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            return am.isBluetoothScoOn || am.isBluetoothA2dpOn || am.isWiredHeadsetOn
        }
        val types = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BUS,
            AudioDeviceInfo.TYPE_DOCK,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
        )
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in types }
    }

    private fun notifyResumeActiveCall() {
        val want = intent?.getBooleanExtra("resume_active_call", false) == true
        if (!want) return
        intent?.removeExtra("resume_active_call")
        fun send() {
            deviceChannel?.invokeMethod("resumeActiveCall", null)
        }
        send()
        window.decorView.postDelayed({ send() }, 600)
        window.decorView.postDelayed({ send() }, 1600)
    }

    private fun playOutgoingRingback() {
        stopOutgoingRingback()
        ringbackPlaying = true
        val sampleRate = 16000
        val onSamples = sampleRate * 2
        val offSamples = sampleRate * 4
        val cycle = ShortArray(onSamples + offSamples)
        val twoPi = 2.0 * Math.PI
        for (i in 0 until onSamples) {
            val t = i / sampleRate.toDouble()
            val mixed = 0.52 * sin(twoPi * 440.0 * t) + 0.48 * sin(twoPi * 480.0 * t)
            cycle[i] = (mixed * 0.26 * Short.MAX_VALUE).toInt().toShort()
        }
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val track = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setBufferSizeInBytes(max(minBuf, cycle.size * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        ringbackTrack = track
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (_: Exception) {
        }
        track.play()
        ringbackThread = Thread {
            while (ringbackPlaying) {
                var offset = 0
                while (ringbackPlaying && offset < cycle.size) {
                    val written = track.write(cycle, offset, minOf(1024, cycle.size - offset))
                    if (written <= 0) break
                    offset += written
                }
            }
        }.also { it.start() }
    }

    private fun stopOutgoingRingback() {
        ringbackPlaying = false
        try {
            ringbackTrack?.pause()
            ringbackTrack?.flush()
            ringbackTrack?.stop()
        } catch (_: Exception) {
        }
        try {
            ringbackTrack?.release()
        } catch (_: Exception) {
        }
        ringbackTrack = null
        ringbackThread = null
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        return getSystemService(BluetoothManager::class.java)?.adapter
    }

    override fun onDestroy() {
        stopOutgoingRingback()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Launcher / notification can otherwise spawn a second recents card
        // on top of an already running task (Samsung especially).
        if (!isTaskRoot &&
            intent?.action == Intent.ACTION_MAIN &&
            intent?.hasCategory(Intent.CATEGORY_LAUNCHER) == true
        ) {
            finish()
            return
        }
        super.onCreate(savedInstanceState)
        AppNotificationChannels.ensure(this)
        requestPostNotifications()
        maybeShowOverLockscreen(intent)
        notifyNotificationTap(intent)
    }

    private fun requestPostNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 71)
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(PowerManager::class.java) ?: return false
        if (pm.isIgnoringBatteryOptimizations(packageName)) return true
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun notifyNotificationTap(source: Intent?) {
        val data = HashMap<String, String>()
        val extras = source?.extras ?: return
        for (key in extras.keySet()) {
            val value = extras.getString(key) ?: continue
            if (value.isNotEmpty()) data[key] = value
        }
        if (data["type"].isNullOrEmpty() && data["jobId"].isNullOrEmpty() && data["from"].isNullOrEmpty()) {
            return
        }
        fun send() {
            deviceChannel?.invokeMethod("notificationTap", data)
        }
        send()
        window.decorView.postDelayed({ send() }, 600)
        window.decorView.postDelayed({ send() }, 1600)
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // Never finish the CRM from the system Back key. Flutter PopScope
        // shows «Хотите выйти?» and only then calls SystemNavigator.pop().
        val engine = flutterEngine
        if (engine != null) {
            engine.navigationChannel.popRoute()
        }
    }

    override fun onResume() {
        super.onResume()
        notifyResumeActiveCall()
        if (TVConnectionService.getIncomingCallHandle() == null) {
            IncomingCallNotifier.cancel(this)
            clearLockscreenFlags()
        }
    }

    override fun onPause() {
        super.onPause()
        if (TVConnectionService.getIncomingCallHandle() == null) {
            clearLockscreenFlags()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeShowOverLockscreen(intent)
        notifyResumeActiveCall()
        notifyNotificationTap(intent)
    }

    private fun clearLockscreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        }
    }

    private fun maybeShowOverLockscreen(intent: Intent?) {
        if (intent?.getBooleanExtra("twilio_incoming_call", false) != true) {
            if (TVConnectionService.getIncomingCallHandle() == null) {
                clearLockscreenFlags()
            }
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        val keyguard = getSystemService(KeyguardManager::class.java)
        keyguard?.requestDismissKeyguard(this, null)
    }
}
