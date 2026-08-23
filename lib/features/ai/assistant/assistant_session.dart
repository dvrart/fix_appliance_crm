import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../../core/app_commands.dart';
import '../../../core/haptics.dart';
import '../../../services/ai_service.dart';

enum AssistantPhase { idle, listening, thinking }

/// Одна сессия микрофона: не дёргаем start/stop по кругу.
class AssistantSession extends ChangeNotifier {
  AssistantSession._();
  static final AssistantSession instance = AssistantSession._();

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _silenceTimer;

  AssistantPhase phase = AssistantPhase.idle;
  double soundLevel = 0;
  String lastHeard = '';
  String? errorText;
  bool _wantListen = false;
  bool _speaking = false;
  final BytesBuilder _pcm = BytesBuilder(copy: false);

  static const _sampleRate = 16000;
  static const _channels = 1;

  bool get isListening => phase == AssistantPhase.listening;
  bool get isActive => phase != AssistantPhase.idle;

  Future<void> toggle() async {
    AppHaptics.button();
    if (isListening || phase == AssistantPhase.thinking) {
      await stop();
    } else {
      await start();
    }
  }

  Future<void> start() async {
    if (_wantListen && isListening) return;
    errorText = null;
    lastHeard = '';
    _wantListen = true;
    _speaking = false;
    _pcm.clear();

    final allowed = await _recorder.hasPermission();
    if (!allowed) {
      _wantListen = false;
      errorText = 'Нет доступа к микрофону';
      phase = AssistantPhase.idle;
      notifyListeners();
      _toast(errorText!);
      return;
    }

    phase = AssistantPhase.listening;
    soundLevel = 0.15;
    notifyListeners();

    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: _channels,
    );

    try {
      final stream = await _recorder.startStream(config);
      _pcmSub = stream.listen(_onPcm, onError: (_) {});
    } catch (_) {
      _wantListen = false;
      phase = AssistantPhase.idle;
      errorText = 'Не удалось начать слушать';
      notifyListeners();
      _toast(errorText!);
    }
  }

  Future<void> stop() async {
    _wantListen = false;
    _silenceTimer?.cancel();
    await _pcmSub?.cancel();
    _pcmSub = null;
    Uint8List? leftover;
    if (_pcm.length > _sampleRate) {
      leftover = Uint8List.fromList(_pcm.takeBytes());
    }
    _pcm.clear();
    try {
      await _recorder.stop();
    } catch (_) {}
    soundLevel = 0;
    phase = leftover != null && leftover.isNotEmpty
        ? AssistantPhase.thinking
        : AssistantPhase.idle;
    notifyListeners();
    if (leftover != null && leftover.isNotEmpty) {
      await _transcribe(leftover);
    }
    if (!_wantListen) {
      phase = AssistantPhase.idle;
      notifyListeners();
    }
  }

  void _onPcm(Uint8List chunk) {
    if (!_wantListen) return;
    _pcm.add(chunk);
    final level = _rms(chunk);
    soundLevel = math.max(0, math.min(1, level * 6));
    notifyListeners();

    final loud = soundLevel > 0.12;
    if (loud) {
      _speaking = true;
      _silenceTimer?.cancel();
      _silenceTimer = null;
      return;
    }
    if (_speaking && _silenceTimer == null) {
      _silenceTimer = Timer(const Duration(milliseconds: 1600), () {
        _silenceTimer = null;
        _speaking = false;
        unawaited(_flushUtterance());
      });
    }
  }

  Future<void> _flushUtterance() async {
    if (!_wantListen || _pcm.length < _sampleRate) return;
    final bytes = Uint8List.fromList(_pcm.takeBytes());
    _pcm.clear();
    await _transcribe(bytes);
  }

  Future<void> _transcribe(Uint8List pcm) async {
    try {
      final wav = _pcm16ToWav(pcm, sampleRate: _sampleRate, channels: _channels);
      final text = await AiService.transcribeAudio(wav);
      if (text.trim().isEmpty) return;
      lastHeard = text.trim();
      notifyListeners();
      _toast(lastHeard);
    } catch (_) {
      // Слушаем дальше — без окна и без перезапуска микрофона.
    }
  }

  static double _rms(Uint8List pcm) {
    if (pcm.length < 4) return 0;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final sample = pcm[i] | (pcm[i + 1] << 8);
      final signed = sample >= 0x8000 ? sample - 0x10000 : sample;
      sum += signed * signed;
      n++;
    }
    if (n == 0) return 0;
    return math.sqrt(sum / n) / 32768.0;
  }

  static Uint8List _pcm16ToWav(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
  }) {
    final dataSize = pcm.length;
    final header = ByteData(44);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        header.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataSize, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataSize, Endian.little);
    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(pcm);
    return out.takeBytes();
  }

  void _toast(String text) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
