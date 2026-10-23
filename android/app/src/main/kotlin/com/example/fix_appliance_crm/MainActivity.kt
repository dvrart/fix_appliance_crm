package com.example.fix_appliance_crm

import android.Manifest
import android.app.AppOpsManager
import android.app.KeyguardManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import kotlin.math.max
import kotlin.math.sin
import com.twilio.twilio_voice.service.IncomingCallNotifier
import com.twilio.twilio_voice.service.TVConnectionService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity, а не FlutterActivity: androidx BiometricPrompt
// (замок на вход по отпечатку) работает только внутри FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var deviceChannel: MethodChannel? = null
    private var notificationEventsReady = false
    private var pendingNotificationTap: Map<String, String>? = null
    private var pendingResumeActiveCall = false
    @Volatile private var ringbackPlaying = false
    private var ringbackTrack: AudioTrack? = null
    private var ringbackThread: Thread? = null

    private var assistantFocusRequest: AudioFocusRequest? = null
    private var assistantFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var assistantOwnsAudioFocus = false
    private var assistantOwnsAudioMode = false
    private var assistantOwnsBluetoothSco = false
    private var wakeOwnsCarAudio = false
    private val delayedWakeCarAudioRelease = Runnable {
        if (!assistantOwnsAudioFocus && !wakeOwnsCarAudio) {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            tearDownCarCommunicationMode(am)
        }
    }

    private val carOutputDeviceTypes = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BUS,
        AudioDeviceInfo.TYPE_DOCK,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_DEVICE,
    )

    private val carCommunicationDevicePriority = listOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BUS,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_DOCK,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
    )

    private val carInputDevicePriority = listOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BUS,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_DOCK,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
    )

    private var audioStateChannel: EventChannel? = null
    private var audioStateSink: EventChannel.EventSink? = null
    private var lastAudioState: Map<String, Boolean>? = null
    private val audioStateHandler = Handler(Looper.getMainLooper())
    private val audioPlaybackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (wakeOwnsCarAudio && !assistantOwnsAudioFocus &&
                (am.isMusicActive || hasActiveCall(am))
            ) {
                releaseWakeCarAudio(immediate = true)
            }
            emitAssistantAudioState()
        }
    }
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (assistantOwnsAudioFocus && !hasActiveCall(am)) {
                applyAssistantCommunicationRoute(am, forWake = false)
            } else if (wakeOwnsCarAudio && !hasActiveCall(am) && !am.isMusicActive) {
                applyAssistantCommunicationRoute(am, forWake = true)
            }
            emitAssistantAudioState()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (assistantOwnsAudioFocus && !hasActiveCall(am)) {
                applyAssistantCommunicationRoute(am, forWake = false)
            } else if (wakeOwnsCarAudio && !hasCarAudio()) {
                releaseWakeCarAudio(immediate = true)
            }
            emitAssistantAudioState()
        }
    }
    private val audioStatePoll = object : Runnable {
        override fun run() {
            if (audioStateSink == null) return
            emitAssistantAudioState()
            audioStateHandler.postDelayed(this, 1000)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fix_appliance/device")
            .also { deviceChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "notificationEventsReady" -> {
                        notificationEventsReady = true
                        deliverPendingDeviceEvents()
                        result.success(null)
                    }
                    "isBluetoothOn" -> result.success(bluetoothAdapter()?.isEnabled == true)
                    "hasCarAudio" -> result.success(hasCarAudio())
                    "assistantAudioState" -> result.success(assistantAudioState())
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
                    "areNotificationsEnabled" -> {
                        result.success(
                            androidx.core.app.NotificationManagerCompat.from(this)
                                .areNotificationsEnabled(),
                        )
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations())
                    }
                    "canOverlayCalls" -> {
                        result.success(canOverlayCalls())
                    }
                    "requestCallOverlayPermission" -> {
                        result.success(requestCallOverlayPermission())
                    }
                    "startBackgroundGuard" -> {
                        CrmBackgroundGuardService.start(this)
                        result.success(true)
                    }
                    "showShadeNotification" -> {
                        val raw = call.arguments
                        val data = HashMap<String, String>()
                        if (raw is Map<*, *>) {
                            for ((key, value) in raw) {
                                if (key == null) continue
                                data[key.toString()] = value?.toString() ?: ""
                            }
                        }
                        result.success(CrmShadeNotifier.show(this, data))
                    }
                    "typeBadgeBytes" -> {
                        // PNG круглого значка типа для fallback-уведомлений
                        // flutter_local_notifications и запланированных.
                        val a = call.arguments as? Map<*, *>
                        val bytes = CrmShadeNotifier.badgePng(
                            this,
                            a?.get("type")?.toString() ?: "",
                            a?.get("source")?.toString() ?: "",
                            a?.get("spam")?.toString().let {
                                it == "1" || it == "true"
                            },
                        )
                        result.success(bytes)
                    }
                    "testIncomingCallNotification" -> {
                        // Тестовый входящий звонок: показывает шторку с кнопками
                        // «Ответить»/«Отклонить». Нажатие безопасно — сервис
                        // просто гасит уведомление для неизвестного callSid.
                        IncomingCallNotifier.show(
                            this,
                            "Amelia · +1 (416) 555-0199",
                            "test_call_${System.currentTimeMillis()}",
                        )
                        window.decorView.postDelayed(
                            { IncomingCallNotifier.cancel(this) },
                            15_000,
                        )
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "muteRecognitionBeeps" -> {
                        muteRecognitionBeeps(call.arguments == true)
                        result.success(true)
                    }
                    "requestAssistantAudioFocus" -> {
                        result.success(requestAssistantAudioFocus())
                    }
                    "releaseAssistantAudioFocus" -> {
                        releaseAssistantAudioFocus()
                        result.success(true)
                    }
                    "preferredAssistantInputDevice" -> {
                        val args = call.arguments as? Map<*, *>
                        val forWake = args?.get("forWake") == true
                        waitForAssistantInputDevice(forWake, result)
                    }
                    "releaseWakeCarAudio" -> {
                        releaseWakeCarAudio(immediate = false)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        stopAudioStateObservation()
        audioStateChannel?.setStreamHandler(null)
        audioStateChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fix_appliance/audio_state",
        ).also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    startAudioStateObservation(events)
                }

                override fun onCancel(arguments: Any?) {
                    stopAudioStateObservation()
                }
            })
        }
        notifyNotificationTap(intent)
    }

    private fun hasActiveCall(am: AudioManager): Boolean {
        val mode = am.mode
        return TVConnectionService.hasActiveCalls() ||
            TVConnectionService.getIncomingCallHandle() != null ||
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_RINGTONE ||
            (mode == AudioManager.MODE_IN_COMMUNICATION && !assistantOwnsAudioMode)
    }

    private fun assistantAudioState(): Map<String, Boolean> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return mapOf(
            "mediaPlaying" to am.isMusicActive,
            "carConnected" to hasCarAudio(),
            "callActive" to hasActiveCall(am),
        )
    }

    private fun emitAssistantAudioState() {
        val sink = audioStateSink ?: return
        val state = assistantAudioState()
        if (state == lastAudioState) return
        lastAudioState = state
        sink.success(state)
    }

    private fun startAudioStateObservation(sink: EventChannel.EventSink) {
        stopAudioStateObservation()
        audioStateSink = sink
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            am.registerAudioPlaybackCallback(audioPlaybackCallback, audioStateHandler)
        } catch (_: Exception) {
        }
        try {
            am.registerAudioDeviceCallback(audioDeviceCallback, audioStateHandler)
        } catch (_: Exception) {
        }
        audioStatePoll.run()
    }

    private fun stopAudioStateObservation() {
        audioStateHandler.removeCallbacks(audioStatePoll)
        lastAudioState = null
        if (audioStateSink == null) return
        audioStateSink = null
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            am.unregisterAudioPlaybackCallback(audioPlaybackCallback)
        } catch (_: Exception) {
        }
        try {
            am.unregisterAudioDeviceCallback(audioDeviceCallback)
        } catch (_: Exception) {
        }
    }

    private fun requestAssistantAudioFocus(): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioStateHandler.removeCallbacks(delayedWakeCarAudioRelease)
        return try {
            if (hasActiveCall(am)) {
                releaseAssistantAudioFocus()
                return false
            }
            if (assistantOwnsAudioFocus) {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                assistantOwnsAudioMode = true
                volumeControlStream = AudioManager.STREAM_VOICE_CALL
                applyAssistantCommunicationRoute(am, forWake = false)
                return true
            }
            val listener = object : AudioManager.OnAudioFocusChangeListener {
                override fun onAudioFocusChange(focusChange: Int) {
                    if (assistantFocusListener === this &&
                        focusChange == AudioManager.AUDIOFOCUS_LOSS
                    ) {
                        releaseAssistantAudioFocus()
                    }
                }
            }
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(listener, audioStateHandler)
                .setWillPauseWhenDucked(true)
                .build()
            if (am.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                return false
            }
            assistantFocusRequest = request
            assistantFocusListener = listener
            assistantOwnsAudioFocus = true
            if (hasActiveCall(am)) {
                releaseAssistantAudioFocus()
                return false
            }
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            assistantOwnsAudioMode = true
            volumeControlStream = AudioManager.STREAM_VOICE_CALL
            applyAssistantCommunicationRoute(am, forWake = false)
            true
        } catch (_: Exception) {
            releaseAssistantAudioFocus()
            false
        }
    }

    private fun releaseAssistantAudioFocus() {
        audioStateHandler.removeCallbacks(delayedWakeCarAudioRelease)
        val ownedFocus = assistantOwnsAudioFocus
        val request = assistantFocusRequest
        assistantOwnsAudioFocus = false
        assistantFocusRequest = null
        assistantFocusListener = null
        volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
        try {
            if (!ownedFocus) {
                if (!wakeOwnsCarAudio) {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    tearDownCarCommunicationMode(am)
                }
                return
            }
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                request?.let { am.abandonAudioFocusRequest(it) }
            } catch (_: Exception) {
            }
            if (!wakeOwnsCarAudio) {
                tearDownCarCommunicationMode(am)
            }
        } catch (_: Exception) {
        }
    }

    private fun acquireWakeCarAudio(am: AudioManager) {
        audioStateHandler.removeCallbacks(delayedWakeCarAudioRelease)
        wakeOwnsCarAudio = true
        assistantOwnsAudioMode = true
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        applyAssistantCommunicationRoute(am, forWake = true)
    }

    private fun releaseWakeCarAudio(immediate: Boolean) {
        wakeOwnsCarAudio = false
        audioStateHandler.removeCallbacks(delayedWakeCarAudioRelease)
        if (assistantOwnsAudioFocus) return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (immediate || hasActiveCall(am) || am.isMusicActive || !hasCarAudio()) {
            tearDownCarCommunicationMode(am)
        } else {
            audioStateHandler.postDelayed(delayedWakeCarAudioRelease, 550L)
        }
    }

    private fun tearDownCarCommunicationMode(am: AudioManager) {
        try {
            stopAssistantBluetoothSco(am)
            if (!hasActiveCall(am)) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        am.clearCommunicationDevice()
                    } catch (_: Exception) {
                    }
                } else {
                    @Suppress("DEPRECATION")
                    am.isSpeakerphoneOn = false
                }
            }
            if (assistantOwnsAudioMode &&
                am.mode == AudioManager.MODE_IN_COMMUNICATION &&
                !hasActiveCall(am)
            ) {
                am.mode = AudioManager.MODE_NORMAL
            }
        } catch (_: Exception) {
        } finally {
            assistantOwnsAudioMode = false
        }
    }

    private fun applyAssistantCommunicationRoute(am: AudioManager, forWake: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val available = am.availableCommunicationDevices
                val carCommDevice = carCommunicationDevicePriority.firstNotNullOfOrNull { type ->
                    available.firstOrNull { it.type == type }
                }
                if (carCommDevice != null) {
                    val applied = if (am.communicationDevice?.id == carCommDevice.id) {
                        true
                    } else {
                        am.setCommunicationDevice(carCommDevice)
                    }
                    if (!applied && carCommDevice.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
                        startAssistantBluetoothSco(am)
                    }
                    return
                }
                stopAssistantBluetoothSco(am)
                if (!forWake && !hasCarAudio()) {
                    val speaker = available.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speaker != null) {
                        if (am.communicationDevice?.id != speaker.id) {
                            am.setCommunicationDevice(speaker)
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        am.isSpeakerphoneOn = true
                    }
                } else {
                    try {
                        am.clearCommunicationDevice()
                    } catch (_: Exception) {
                    }
                }
                return
            }

            val hasBtSco = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                }
            if (hasBtSco || (am.isBluetoothScoAvailableOffCall && hasCarAudio())) {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
                startAssistantBluetoothSco(am)
            } else if (hasCarAudio()) {
                stopAssistantBluetoothSco(am)
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
            } else if (!forWake) {
                stopAssistantBluetoothSco(am)
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
            }
        } catch (_: Exception) {
        }
    }

    @Suppress("DEPRECATION")
    private fun startAssistantBluetoothSco(am: AudioManager) {
        try {
            if (!am.isBluetoothScoOn) {
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
                assistantOwnsBluetoothSco = true
            }
        } catch (_: Exception) {
        }
    }

    @Suppress("DEPRECATION")
    private fun stopAssistantBluetoothSco(am: AudioManager) {
        if (!assistantOwnsBluetoothSco) return
        assistantOwnsBluetoothSco = false
        try {
            if (am.isBluetoothScoOn) {
                am.isBluetoothScoOn = false
            }
            am.stopBluetoothSco()
        } catch (_: Exception) {
        }
    }

    private fun findCarInputDevice(am: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val inputs = am.getDevices(AudioManager.GET_DEVICES_INPUTS).filter { it.isSource }
        return carInputDevicePriority.firstNotNullOfOrNull { type ->
            inputs.firstOrNull { it.type == type }
        }
    }

    @Suppress("DEPRECATION")
    private fun isScoRouteReady(am: AudioManager): Boolean {
        if (am.isBluetoothScoOn) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return am.communicationDevice?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        }
        return false
    }

    private fun waitForAssistantInputDevice(
        forWake: Boolean,
        result: MethodChannel.Result,
        attempt: Int = 0,
    ) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (hasActiveCall(am)) {
            result.success(null)
            return
        }
        if (forWake) {
            if (!hasCarAudio() || am.isMusicActive) {
                result.success(null)
                return
            }
            acquireWakeCarAudio(am)
        } else if (assistantOwnsAudioFocus) {
            applyAssistantCommunicationRoute(am, forWake = false)
        }
        val input = findCarInputDevice(am)
        val needsScoWait = input != null &&
            input.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO &&
            !isScoRouteReady(am) &&
            attempt < 10
        if (needsScoWait) {
            if (attempt == 4) {
                startAssistantBluetoothSco(am)
            }
            audioStateHandler.postDelayed(
                { waitForAssistantInputDevice(forWake, result, attempt + 1) },
                40L,
            )
            return
        }
        if (input == null) {
            result.success(null)
        } else {
            result.success(
                mapOf(
                    "id" to input.id.toString(),
                    "label" to input.productName.toString(),
                    "type" to input.type,
                ),
            )
        }
    }

    /**
     * Звук входящих важнее «бипа» распознавания.
     *
     * Раньше тут на время каждой сессии слова-будильника глушились
     * STREAM_SYSTEM и STREAM_NOTIFICATION, а возвращались они в onDestroy.
     * Это стоило мастеру входящих звонков: на HyperOS (и не только)
     * **STREAM_SYSTEM — псевдоним STREAM_RING**, `dumpsys audio` так и
     * пишет: «STREAM_SYSTEM (aliased to: STREAM_RING)». То есть глушился
     * звонок целиком. А прежняя громкость жила только в памяти процесса:
     * приложение убили, переустановили или onDestroy не пришёл — и телефон
     * молчит на входящие, пока кто-нибудь вручную не двинет ползунок.
     *
     * Именно в таком виде телефон и нашёлся 12.10.2026: громкость звонка
     * 0 из 15, `Muted: true`, Telecom писал `SKIP_RINGING (Inaudible:
     * isVolumeOverZero=false)`. Слово-будильник слушает почти непрерывно,
     * поэтому мьют был практически постоянным.
     *
     * Теперь не глушим ничего. Функция оставлена, чтобы снимать мьют,
     * доставшийся от прежних сборок, — его же снимает [unmuteBeepStreams]
     * при старте.
     */
    private fun muteRecognitionBeeps(mute: Boolean) {
        if (mute) return
        unmuteBeepStreams()
    }

    private fun unmuteBeepStreams() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        for (stream in intArrayOf(AudioManager.STREAM_SYSTEM, AudioManager.STREAM_NOTIFICATION)) {
            try {
                if (Build.VERSION.SDK_INT >= 23) {
                    am.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
                } else {
                    @Suppress("DEPRECATION")
                    am.setStreamMute(stream, false)
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
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type in carOutputDeviceTypes
        }
    }

    private fun notifyResumeActiveCall() {
        val want = intent?.getBooleanExtra("resume_active_call", false) == true
        if (!want) return
        intent?.removeExtra("resume_active_call")
        pendingResumeActiveCall = true
        deliverPendingDeviceEvents()
    }

    private fun deliverPendingDeviceEvents() {
        val channel = deviceChannel ?: return
        if (!notificationEventsReady) return
        pendingNotificationTap?.let { data ->
            pendingNotificationTap = null
            channel.invokeMethod("notificationTap", data)
        }
        if (pendingResumeActiveCall) {
            pendingResumeActiveCall = false
            channel.invokeMethod("resumeActiveCall", null)
        }
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
        stopAudioStateObservation()
        audioStateChannel?.setStreamHandler(null)
        audioStateChannel = null
        releaseWakeCarAudio(immediate = true)
        releaseAssistantAudioFocus()
        muteRecognitionBeeps(false)
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
        // Снимаем мьют звонка, если его оставила прежняя сборка (см.
        // muteRecognitionBeeps). Без этого телефон молчал бы и дальше.
        unmuteBeepStreams()
        requestPostNotifications()
        CrmBackgroundGuardService.start(this)
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

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(PowerManager::class.java)
        return pm?.isIgnoringBatteryOptimizations(packageName) == true
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val ignoring = isIgnoringBatteryOptimizations()
        val samsung = Build.MANUFACTURER.equals("samsung", ignoreCase = true)
        val intents = mutableListOf<Intent>()
        if (!ignoring) {
            intents += Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = packageUri()
            }
        }
        if (samsung) {
            intents += samsungNeverSleepingIntent()
            intents += appBatterySettingsIntent()
            intents += samsungAppBatteryIntent()
        } else {
            intents += appBatterySettingsIntent()
        }
        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = packageUri()
        }
        for (intent in intents) {
            if (launchSettings(intent)) return ignoring
        }
        return ignoring
    }

    private fun isMiui(): Boolean {
        val m = Build.MANUFACTURER.orEmpty()
        val b = Build.BRAND.orEmpty()
        return m.equals("Xiaomi", ignoreCase = true) ||
            b.equals("Xiaomi", ignoreCase = true) ||
            b.equals("Redmi", ignoreCase = true) ||
            b.equals("POCO", ignoreCase = true)
    }

    /**
     * HyperOS / MIUI держит отдельную галочку «Открывать новые окна во
     * время работы в фоновом режиме» (AppOps 10021). Без неё `startActivity`
     * из фона блокируется даже при выданном `SYSTEM_ALERT_WINDOW`.
     */
    private fun isMiuiBackgroundPopupAllowed(): Boolean {
        if (!isMiui()) return true
        return try {
            val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            val mode = method.invoke(ops, 10021, applicationInfo.uid, packageName) as? Int
            mode == null || mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Throwable) {
            true
        }
    }

    private fun canOverlayCalls(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return Settings.canDrawOverlays(this) && isMiuiBackgroundPopupAllowed()
    }

    private fun requestCallOverlayPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val overlayOk = Settings.canDrawOverlays(this)
        val miuiOk = isMiuiBackgroundPopupAllowed()
        val intents = mutableListOf<Intent>()
        if (!overlayOk) {
            intents += Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri())
        }
        if (isMiui() && (!miuiOk || overlayOk)) {
            intents += miuiPermissionsIntent()
        }
        intents += Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri())
        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri())
        for (intent in intents) {
            if (launchSettings(intent)) break
        }
        return overlayOk && miuiOk
    }

    private fun miuiPermissionsIntent(): Intent {
        return Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
            )
            putExtra("extra_pkgname", packageName)
        }
    }

    private fun samsungNeverSleepingIntent(): Intent {
        return Intent().setComponent(
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.battery.ui.BatteryActivity",
            ),
        )
    }

    private fun packageUri(): Uri = Uri.parse("package:$packageName")

    private fun appBatterySettingsIntent(): Intent {
        return Intent("android.settings.APP_BATTERY_SETTINGS").apply {
            data = packageUri()
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            putExtra("android.provider.extra.APP_PACKAGE", packageName)
            putExtra("package", packageName)
            putExtra("packageName", packageName)
            putExtra("uid", applicationInfo.uid)
        }
    }

    private fun samsungAppBatteryIntent(): Intent {
        return Intent().setComponent(
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.battery.ui.usage.AppBatteryUsageActivity",
            ),
        ).apply {
            putExtra("package", packageName)
            putExtra("packageName", packageName)
            putExtra("extra_package_name", packageName)
            putExtra("uid", applicationInfo.uid)
        }
    }

    private fun launchSettings(intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(packageManager) == null) return false
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun notifyNotificationTap(source: Intent?) {
        val data = HashMap<String, String>()
        val extras = source?.extras ?: return
        for (key in extras.keySet()) {
            val value = extras.get(key) as? String ?: continue
            if (value.isNotEmpty()) data[key] = value
        }
        if (data["type"].isNullOrEmpty() && data["jobId"].isNullOrEmpty() &&
            data["from"].isNullOrEmpty() && data["peer"].isNullOrEmpty()) return
        pendingNotificationTap = data
        for (key in data.keys) source.removeExtra(key)
        deliverPendingDeviceEvents()
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
