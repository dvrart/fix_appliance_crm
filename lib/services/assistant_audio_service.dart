import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlaybackMicrophoneGuard extends ChangeNotifier {
  final Set<Object> _owners = {};
  Future<void>? _suspending;
  Future<void> Function()? suspendMicrophone;

  bool get isActive => _owners.isNotEmpty;

  Future<void> acquire(Object owner) async {
    if (_owners.add(owner) && _owners.length == 1) notifyListeners();
    final pending = _suspending ??= Future<void>.sync(() async {
      await suspendMicrophone?.call();
    });
    try {
      await pending;
    } catch (_) {
      release(owner);
      rethrow;
    } finally {
      if (identical(_suspending, pending)) _suspending = null;
    }
  }

  void release(Object owner) {
    if (_owners.remove(owner) && _owners.isEmpty) notifyListeners();
  }
}

@immutable
class AssistantAudioState {
  final bool mediaPlaying;
  final bool carConnected;
  final bool callActive;
  final bool available;

  const AssistantAudioState({
    this.mediaPlaying = false,
    this.carConnected = false,
    this.callActive = false,
    this.available = true,
  });

  factory AssistantAudioState.fromMap(Map<dynamic, dynamic>? value) {
    if (value == null ||
        value['mediaPlaying'] is! bool ||
        value['carConnected'] is! bool ||
        value['callActive'] is! bool) {
      return const AssistantAudioState(available: false);
    }
    return AssistantAudioState(
      mediaPlaying: value['mediaPlaying'] == true,
      carConnected: value['carConnected'] == true,
      callActive: value['callActive'] == true,
    );
  }

  bool get blocksWake =>
      !available || mediaPlaying || carConnected || callActive;
}

/// Нативное управление звуком для голосового ассистента (машина / Bluetooth).
class AssistantAudioService {
  static const _channel = MethodChannel('fix_appliance/device');
  static const _events = EventChannel('fix_appliance/audio_state');
  static final playback = PlaybackMicrophoneGuard();

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<AssistantAudioState> watchState() {
    if (!_android) return Stream.value(const AssistantAudioState());
    return _events.receiveBroadcastStream().map(
      (value) => AssistantAudioState.fromMap(value is Map ? value : null),
    );
  }

  static Future<AssistantAudioState> readState() async {
    if (!_android) return const AssistantAudioState();
    try {
      return AssistantAudioState.fromMap(
        await _channel.invokeMapMethod<String, dynamic>('assistantAudioState'),
      );
    } catch (_) {
      return const AssistantAudioState(available: false);
    }
  }

  static Future<bool> canListenForWake() async {
    if (playback.isActive) return false;
    final state = await readState();
    return !playback.isActive && !state.blocksWake;
  }

  static Future<bool> requestFocus() async {
    if (playback.isActive) return false;
    if (!_android) return true;
    try {
      return await _channel.invokeMethod<bool>('requestAssistantAudioFocus') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> releaseFocus() async {
    try {
      await _channel.invokeMethod('releaseAssistantAudioFocus');
    } catch (_) {}
  }

  static Future<void> muteRecognitionBeeps(bool mute) async {
    try {
      await _channel.invokeMethod('muteRecognitionBeeps', mute);
    } catch (_) {}
  }

  static Future<bool> hasCarAudio() async {
    try {
      return await _channel.invokeMethod<bool>('hasCarAudio') ?? false;
    } catch (_) {
      return false;
    }
  }
}
