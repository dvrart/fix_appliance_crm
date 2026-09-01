import 'package:flutter/services.dart';

/// Нативное управление звуком для голосового ассистента (машина / Bluetooth).
class AssistantAudioService {
  static const _channel = MethodChannel('fix_appliance/device');

  static Future<bool> requestFocus() async {
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
