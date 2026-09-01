import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// Очередь PCM 16-bit / 24 kHz для голоса Gemini Live.
class PcmPlaybackQueue {
  static const _sampleRate = 24000;

  final Queue<int> _samples = Queue<int>();
  bool _ready = false;
  bool _pumping = false;
  int _remainingMs = 0;
  DateTime _clock = DateTime.fromMillisecondsSinceEpoch(0);

  void _tick() {
    final now = DateTime.now();
    if (_clock.millisecondsSinceEpoch == 0) {
      _clock = now;
      return;
    }
    final elapsed = now.difference(_clock).inMilliseconds;
    _clock = now;
    if (elapsed > 0) {
      _remainingMs = (_remainingMs - elapsed).clamp(0, 120000);
    }
  }

  Future<void> ensureStarted() async {
    if (_ready) return;
    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(1200);
    FlutterPcmSound.setFeedCallback((_) {
      unawaited(_pump());
    });
    _ready = true;
  }

  Future<void> addPcm16Bytes(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await ensureStarted();
    final byteData = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      _samples.add(byteData.getInt16(i, Endian.little));
    }
    _tick();
    _remainingMs += (n * 1000 / _sampleRate).round();
    await _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_samples.isNotEmpty) {
        final take = _samples.length.clamp(1, 4800);
        final frame = List<int>.filled(take, 0);
        for (var i = 0; i < take; i++) {
          frame[i] = _samples.removeFirst();
        }
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(frame));
      }
    } catch (_) {
      _ready = false;
    } finally {
      _pumping = false;
    }
  }

  void clear() {
    _samples.clear();
    _remainingMs = 0;
    _clock = DateTime.now();
  }

  Future<void> stop() async {
    clear();
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    _ready = false;
  }

  bool get isPlaying {
    _tick();
    return _samples.isNotEmpty || _remainingMs > 80;
  }
}
