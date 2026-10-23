package com.lib.flutter_pcm_sound;

import android.content.Context;
import android.os.Build;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.AudioAttributes;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import androidx.annotation.NonNull;

import java.util.Map;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.io.StringWriter;
import java.io.PrintWriter;
import java.nio.ByteBuffer;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * FlutterPcmSoundPlugin implements a "one pedal" PCM sound playback mechanism.
 * Playback starts automatically when samples are fed and stops when no more samples are available.
 */
public class FlutterPcmSoundPlugin implements
    FlutterPlugin,
    MethodChannel.MethodCallHandler
{
    private static final String CHANNEL_NAME = "flutter_pcm_sound/methods";
    private static final int MAX_FRAMES_PER_BUFFER = 200;

    private static final int[] COMMUNICATION_OUTPUT_PRIORITY = new int[] {
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
    };

    private static final int[] MEDIA_CAR_OUTPUT_PRIORITY = new int[] {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_AUX_LINE,
    };

    private Context mContext;
    private MethodChannel mMethodChannel;
    private Handler mainThreadHandler = new Handler(Looper.getMainLooper());
    private Thread playbackThread;
    private volatile boolean mShouldCleanup = false;
    private AudioDeviceCallback mAudioDeviceCallback;

    private AudioTrack mAudioTrack;
    private int mNumChannels;
    private int mMinBufferSize;
    private boolean mDidSetup = false;

    private long mFeedThreshold = 8000;
    private long mTotalFeeds = 0;
    private long mLastLowBufferFeed = 0;
    private long mLastZeroFeed = 0;

    // Thread-safe queue for storing audio samples
    private final LinkedBlockingQueue<ByteBuffer> mSamples = new LinkedBlockingQueue<>();

    // Log level enum (kept for potential future use)
    private enum LogLevel {
        NONE,
        ERROR,
        STANDARD,
        VERBOSE
    }

    private LogLevel mLogLevel = LogLevel.VERBOSE;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        mContext = binding.getApplicationContext();
        BinaryMessenger messenger = binding.getBinaryMessenger();
        mMethodChannel = new MethodChannel(messenger, CHANNEL_NAME);
        mMethodChannel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        mMethodChannel.setMethodCallHandler(null);
        cleanup();
        mContext = null;
    }

    @Override
    @SuppressWarnings("deprecation") // Needed for compatibility with Android < 23
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "setLogLevel": {
                    result.success(true);
                    break;
                }
                case "setup": {
                    int sampleRate = call.argument("sample_rate");
                    mNumChannels = call.argument("num_channels");

                    // Cleanup existing resources if any
                    if (mAudioTrack != null) {
                        cleanup();
                    }

                    int channelConfig = (mNumChannels == 2) ?
                        AudioFormat.CHANNEL_OUT_STEREO :
                        AudioFormat.CHANNEL_OUT_MONO;

                    mMinBufferSize = AudioTrack.getMinBufferSize(
                        sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT);

                    if (mMinBufferSize == AudioTrack.ERROR || mMinBufferSize == AudioTrack.ERROR_BAD_VALUE) {
                        result.error("AudioTrackError", "Invalid buffer size.", null);
                        return;
                    }

                    if (Build.VERSION.SDK_INT >= 23) { // Android 6 (Marshmallow) and above
                        boolean mediaOnlyCarOutput = isMediaOnlyCarOutputConnected();
                        int usage = mediaOnlyCarOutput
                            ? AudioAttributes.USAGE_MEDIA
                            : AudioAttributes.USAGE_VOICE_COMMUNICATION;
                        mAudioTrack = new AudioTrack.Builder()
                            .setAudioAttributes(new AudioAttributes.Builder()
                                    .setUsage(usage)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build())
                            .setAudioFormat(new AudioFormat.Builder()
                                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                    .setSampleRate(sampleRate)
                                    .setChannelMask(channelConfig)
                                    .build())
                            .setBufferSizeInBytes(mMinBufferSize)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .build();
                        applyPreferredOutputDevice(mAudioTrack);
                        registerOutputDeviceCallback();
                    } else {
                        mAudioTrack = new AudioTrack(
                            AudioManager.STREAM_VOICE_CALL,
                            sampleRate,
                            channelConfig,
                            AudioFormat.ENCODING_PCM_16BIT,
                            mMinBufferSize,
                            AudioTrack.MODE_STREAM);
                    }

                    if (mAudioTrack.getState() != AudioTrack.STATE_INITIALIZED) {
                        result.error("AudioTrackError", "AudioTrack initialization failed.", null);
                        mAudioTrack.release();
                        mAudioTrack = null;
                        return;
                    }

                    // reset
                    mSamples.clear();
                    mShouldCleanup = false;

                    // start playback thread
                    playbackThread = new Thread(this::playbackThreadLoop, "PCMPlaybackThread");
                    playbackThread.setPriority(Thread.MAX_PRIORITY);
                    playbackThread.start();

                    mDidSetup = true;

                    result.success(true);
                    break;
                }
                case "feed": {

                    // check setup (to match iOS behavior)
                    if (mDidSetup == false) {
                        result.error("Setup", "must call setup first", null);
                        return;
                    }

                    byte[] buffer = call.argument("buffer");

                    // Split for better performance
                    List<ByteBuffer> chunks = split(buffer, MAX_FRAMES_PER_BUFFER);

                    // Push samples
                    synchronized (mSamples) {
                        for (ByteBuffer chunk : chunks) {
                            mSamples.add(chunk);
                        }
                        mTotalFeeds += 1;
                    }

                    result.success(true);
                    break;
                }
                case "setFeedThreshold": {
                    long feedThreshold = ((Number) call.argument("feed_threshold")).longValue();

                    synchronized (mSamples) {
                        mFeedThreshold = feedThreshold;
                    }

                    result.success(true);
                    break;
                }
                case "release": {
                    cleanup();
                    result.success(true);
                    break;
                }
                default:
                    result.notImplemented();
                    break;
            }


        } catch (Exception e) {
            StringWriter sw = new StringWriter();
            PrintWriter pw = new PrintWriter(sw);
            e.printStackTrace(pw);
            String stackTrace = sw.toString();
            result.error("androidException", e.toString(), stackTrace);
            return;
        }
    }

    /**
     * Cleans up resources by stopping the playback thread and releasing AudioTrack.
     */
    private void cleanup() {
        unregisterOutputDeviceCallback();
        // stop playback thread
        if (playbackThread != null) {
            mShouldCleanup = true;
            playbackThread.interrupt();
            try {
                playbackThread.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            playbackThread = null;
            mDidSetup = false;
        }
    }

    private AudioManager getAudioManager() {
        if (mContext == null) return null;
        return (AudioManager) mContext.getSystemService(Context.AUDIO_SERVICE);
    }

    private AudioDeviceInfo findOutputByPriority(AudioDeviceInfo[] outputs, int[] priority) {
        if (outputs == null) return null;
        for (int type : priority) {
            for (AudioDeviceInfo info : outputs) {
                if (info.isSink() && info.getType() == type) {
                    return info;
                }
            }
        }
        return null;
    }

    private boolean isMediaOnlyCarOutputConnected() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false;
        AudioManager am = getAudioManager();
        if (am == null) return false;
        AudioDeviceInfo[] outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        AudioDeviceInfo commOut = findOutputByPriority(outputs, COMMUNICATION_OUTPUT_PRIORITY);
        if (commOut != null) return false;
        return findOutputByPriority(outputs, MEDIA_CAR_OUTPUT_PRIORITY) != null;
    }

    private void applyPreferredOutputDevice(AudioTrack track) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || track == null) return;
        AudioManager am = getAudioManager();
        if (am == null) return;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                AudioDeviceInfo commDevice = am.getCommunicationDevice();
                if (commDevice != null && commDevice.isSink()) {
                    track.setPreferredDevice(commDevice);
                    return;
                }
            }
            AudioDeviceInfo[] outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            AudioDeviceInfo preferred = findOutputByPriority(outputs, COMMUNICATION_OUTPUT_PRIORITY);
            if (preferred == null) {
                preferred = findOutputByPriority(outputs, MEDIA_CAR_OUTPUT_PRIORITY);
            }
            if (preferred == null) {
                preferred = findOutputByPriority(
                    outputs,
                    new int[] { AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                );
            }
            if (preferred != null) {
                track.setPreferredDevice(preferred);
            }
        } catch (Exception ignored) {
        }
    }

    private void registerOutputDeviceCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        unregisterOutputDeviceCallback();
        AudioManager am = getAudioManager();
        if (am == null) return;
        mAudioDeviceCallback = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
                applyPreferredOutputDevice(mAudioTrack);
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
                applyPreferredOutputDevice(mAudioTrack);
            }
        };
        try {
            am.registerAudioDeviceCallback(mAudioDeviceCallback, mainThreadHandler);
        } catch (Exception ignored) {
        }
    }

    private void unregisterOutputDeviceCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || mAudioDeviceCallback == null) return;
        AudioManager am = getAudioManager();
        try {
            if (am != null) {
                am.unregisterAudioDeviceCallback(mAudioDeviceCallback);
            }
        } catch (Exception ignored) {
        } finally {
            mAudioDeviceCallback = null;
        }
    }

    /**
     * Invokes the 'OnFeedSamples' callback with the number of remaining frames.
     */
    private void invokeFeedCallback(long remainingFrames) {
        Map<String, Object> response = new HashMap<>();
        response.put("remaining_frames", remainingFrames);
        mMethodChannel.invokeMethod("OnFeedSamples", response);
    }

    /**
     * The main loop of the playback thread.
     */
    private void playbackThreadLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);

        mAudioTrack.play();

        while (!mShouldCleanup) {
            ByteBuffer data = null;
            try {
                // blocks indefinitely until new data
                data = mSamples.take();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                continue;
            }

            // write
            mAudioTrack.write(data, data.remaining(), AudioTrack.WRITE_BLOCKING);

            long remainingFrames;
            long totalFeeds;
            long feedThreshold;

            // grab shared data
            synchronized (mSamples) {
                long totalBytes = 0;
                for (ByteBuffer sampleBuffer : mSamples) {
                    totalBytes += sampleBuffer.remaining();
                }
                remainingFrames = totalBytes / (2 * mNumChannels);
                totalFeeds = mTotalFeeds;
                feedThreshold = mFeedThreshold;
            }

            // check for events
            boolean isLowBufferEvent = (remainingFrames <= feedThreshold) && (mLastLowBufferFeed != totalFeeds);
            boolean isZeroCrossingEvent = (remainingFrames == 0) && (mLastZeroFeed != totalFeeds);

            // send events
            if (isLowBufferEvent || isZeroCrossingEvent) {
                if (isLowBufferEvent) {mLastLowBufferFeed = totalFeeds;}
                if (isZeroCrossingEvent) {mLastZeroFeed = totalFeeds;}
                mainThreadHandler.post(() -> invokeFeedCallback(remainingFrames));
            }
        }

        mAudioTrack.stop();
        mAudioTrack.flush();
        mAudioTrack.release();
        mAudioTrack = null;
    }


    private List<ByteBuffer> split(byte[] buffer, int maxSize) {
        List<ByteBuffer> chunks = new ArrayList<>();
        int offset = 0;
        while (offset < buffer.length) {
            int length = Math.min(buffer.length - offset, maxSize);
            ByteBuffer b = ByteBuffer.wrap(buffer, offset, length);
            chunks.add(b);
            offset += length;
        }
        return chunks;
    }
}
