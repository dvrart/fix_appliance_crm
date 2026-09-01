import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../../core/api_keys.dart';
import '../../../services/assistant_audio_service.dart';

/// Ловит wake-слово (FIX-Appliance / фикс).
/// Основной путь — Android STT (быстро и надёжно для короткого имени).
/// PCM+Gemini — запасной, если STT недоступен.
class WakeWordService extends ChangeNotifier {
  static const _probeModels = [
    'gemini-2.5-flash',
    'gemini-3.6-flash',
    'gemini-2.0-flash',
  ];

  final _recorder = AudioRecorder();
  final _stt = stt.SpeechToText();

  bool _enabled = false;
  bool _starting = false;
  bool _probing = false;
  bool _waking = false;
  bool _sttReady = false;
  bool _sttListening = false;
  bool _useStt = true;
  bool isArmed = false;
  int _epoch = 0;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _reconnectTimer;
  DateTime _nextProbeAt = DateTime.fromMillisecondsSinceEpoch(0);

  final List<int> _preRoll = [];
  final BytesBuilder _utterance = BytesBuilder();
  int _loudChunks = 0;
  int _quietChunks = 0;
  bool _capturing = false;

  static const _preRollBytes = 9600;
  static const _speechRms = 0.0028;
  static const _silenceRms = 0.0018;
  static const _loudChunksNeeded = 1;
  static const _quietChunksNeeded = 3;
  static const _minUtteranceBytes = 6400;
  static const _readyToProbeBytes = 9600;
  static const _maxUtteranceBytes = 48000;

  void Function()? onWake;
  void Function(String reason)? onBlocked;

  String _wakeWord = 'FIX-Appliance';
  List<String> _aliases = const [];

  void applyPhrases({required String word, List<String> aliases = const []}) {
    final trimmed = word.trim();
    _wakeWord = trimmed.isEmpty ? 'FIX-Appliance' : trimmed;
    _aliases = aliases;
  }

  static String normalizePhrase(String raw) {
    return raw
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll('š', 'sh')
        .replaceAll('č', 'ch')
        .replaceAll('ž', 'zh')
        .replaceAll('ć', 'c')
        .replaceAll('đ', 'd')
        .replaceAll(RegExp(r'[^\wа-я]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static const _cyrToLat = {
    'а': 'a',
    'б': 'b',
    'в': 'v',
    'г': 'g',
    'д': 'd',
    'е': 'e',
    'ж': 'zh',
    'з': 'z',
    'и': 'i',
    'й': 'y',
    'к': 'k',
    'л': 'l',
    'м': 'm',
    'н': 'n',
    'о': 'o',
    'п': 'p',
    'р': 'r',
    'с': 's',
    'т': 't',
    'у': 'u',
    'ф': 'f',
    'х': 'h',
    'ц': 'ts',
    'ч': 'ch',
    'ш': 'sh',
    'щ': 'sch',
    'ь': '',
    'ъ': '',
    'ы': 'y',
    'э': 'e',
    'ю': 'yu',
    'я': 'ya',
  };

  static String _toLatin(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_cyrToLat[char] ?? char);
    }
    return buffer.toString().replaceAll('yu', 'u');
  }

  Set<String> get _phrases {
    final phrases = <String>{};
    void add(String raw) {
      final value = normalizePhrase(raw);
      if (value.isEmpty) return;
      phrases.add(value);
      phrases.add(_toLatin(value));
    }

    add(_wakeWord);
    for (final alias in _aliases) {
      add(alias);
    }
    add('fix appliance');
    add('fix-appliance');
    add('fixappliance');
    add('фикс апплаенс');
    add('фикс');
    add('fix');
    add('fiks');
    add('feeks');
    add('фик');
    add('fixes');
    phrases.removeWhere((item) => item.isEmpty);
    return phrases;
  }

  static int _distance(String a, String b) {
    if (a == b) return 0;
    if ((a.length - b.length).abs() > 2) return 99;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      var last = prev[0];
      prev[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final next = last;
        last = prev[j];
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        prev[j] = math.min(math.min(prev[j] + 1, prev[j - 1] + 1), next + cost);
      }
    }
    return prev[b.length];
  }

  bool _tokenMatches(String word, Set<String> phrases) {
    if (word.length < 3) return false;
    if (phrases.contains(word)) return true;
    final latin = _toLatin(word);
    if (phrases.contains(latin)) return true;
    for (final phrase in phrases) {
      if (phrase.length < 3) continue;
      final maxDist = phrase.length <= 4 ? 1 : 2;
      if (_distance(word, phrase) <= maxDist) return true;
      if (_distance(latin, _toLatin(phrase)) <= maxDist) return true;
    }
    return false;
  }

  bool _probeSaysYes(String raw) {
    final folded = raw
        .trim()
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^\wа-я]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (folded.isEmpty) return false;
    if (folded == 'yes' ||
        folded == 'y' ||
        folded == 'да' ||
        folded == 'yeah' ||
        folded == 'yep') {
      return true;
    }
    final first = folded.split(' ').first;
    return first == 'yes' || first == 'да';
  }

  bool matchesWake(String raw) {
    final cleaned = normalizePhrase(raw);
    if (cleaned.isEmpty || cleaned == 'empty' || cleaned == 'noise') {
      return false;
    }
    final phrases = _phrases;
    final compact = cleaned.replaceAll(' ', '');
    final latinCompact = _toLatin(compact);
    const needles = [
      'fixappliance',
      'fix appliance',
      'fix',
      'fiks',
      'feeks',
      'fixes',
      'фикс',
      'фик',
    ];
    for (final needle in needles) {
      if (compact.contains(needle) || latinCompact.contains(_toLatin(needle))) {
        return true;
      }
    }
    if (_tokenMatches(compact, phrases)) return true;
    final words =
        cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty || words.length > 16) return false;
    return words.any((word) => _tokenMatches(word, phrases));
  }

  static double pcmRms(Uint8List bytes) {
    if (bytes.length < 4) return 0;
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final sample = bytes[i] | (bytes[i + 1] << 8);
      final signed = sample >= 32768 ? sample - 65536 : sample;
      sum += signed * signed;
      count++;
    }
    if (count == 0) return 0;
    return math.sqrt(sum / count) / 32768.0;
  }

  Future<void> start() async {
    if (_waking || _starting) return;
    if (_enabled && isArmed) return;
    _enabled = true;
    if (_useStt) {
      await _listenStt();
    } else {
      await _listenPcm();
    }
  }

  Future<void> stop() async {
    _epoch++;
    _enabled = false;
    _waking = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _capturing = false;
    _loudChunks = 0;
    _quietChunks = 0;
    _preRoll.clear();
    _utterance.clear();
    await _stopStt();
    await _tearDown();
    _starting = false;
    _setArmed(false);
  }

  Future<void> _stopStt() async {
    _sttListening = false;
    try {
      if (_stt.isListening) await _stt.stop();
    } catch (_) {}
    await AssistantAudioService.muteRecognitionBeeps(false);
  }

  Future<void> _tearDown() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
  }

  void _setArmed(bool value) {
    if (isArmed == value) return;
    isArmed = value;
    notifyListeners();
  }

  Future<void> _listenStt() async {
    if (!_enabled || _starting || _waking) return;
    _starting = true;
    final epoch = _epoch;
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted || !_enabled || epoch != _epoch) {
        if (!mic.isGranted && _enabled && epoch == _epoch) {
          onBlocked?.call(
            'Нет доступа к микрофону — слово «$_wakeWord» не услышит. '
            'Разрешите микрофон для приложения.',
          );
        }
        return;
      }

      if (!_sttReady) {
        _sttReady = await _stt.initialize(
          onStatus: _onSttStatus,
          onError: (error) {
            debugPrint('WakeWord STT error: ${error.errorMsg}');
            _sttListening = false;
            _scheduleSttReconnect();
          },
        );
      }
      if (!_sttReady || !_enabled || epoch != _epoch) {
        debugPrint('WakeWord: STT недоступен, PCM fallback');
        _useStt = false;
        await _listenPcm();
        return;
      }

      await AssistantAudioService.muteRecognitionBeeps(true);
      _setArmed(true);
      debugPrint('WakeWord: STT слушаю «$_wakeWord»');
      await _startSttSession(epoch);
    } catch (e) {
      debugPrint('WakeWord STT start failed: $e');
      _useStt = false;
      await _listenPcm();
    } finally {
      _starting = false;
    }
  }

  Future<String?> _pickSttLocale() async {
    try {
      final locales = await _stt.locales();
      for (final id in ['ru_RU', 'ru-RU', 'en_US', 'en-US']) {
        if (locales.any((l) => l.localeId == id)) return id;
      }
      if (locales.isNotEmpty) return locales.first.localeId;
    } catch (_) {}
    return null;
  }

  Future<void> _startSttSession(int epoch) async {
    if (!_enabled || _waking || epoch != _epoch) return;
    if (_sttListening || _stt.isListening) return;
    _sttListening = true;
    final localeId = await _pickSttLocale();
    try {
      await _stt.listen(
        onResult: (result) {
          if (!_enabled || _waking || epoch != _epoch) return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          debugPrint(
            'WakeWord STT: "$words" final=${result.finalResult}',
          );
          if (matchesWake(words)) {
            unawaited(_fireWake());
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.search,
          partialResults: true,
          cancelOnError: false,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 2),
          localeId: localeId,
        ),
      );
    } catch (e) {
      debugPrint('WakeWord STT listen failed: $e');
      _sttListening = false;
      _scheduleSttReconnect();
    }
  }

  void _onSttStatus(String status) {
    if (!_enabled || _waking) return;
    debugPrint('WakeWord STT status: $status');
    if (status == 'done' || status == 'notListening') {
      _sttListening = false;
      _scheduleSttReconnect();
    }
  }

  void _scheduleSttReconnect() {
    if (!_enabled || _waking || _starting) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(milliseconds: 450), () {
      if (_enabled && !_waking && !_sttListening) {
        unawaited(_startSttSession(_epoch));
      }
    });
  }

  Future<void> _listenPcm() async {
    if (!_enabled || _starting || _waking) return;
    if (_micSub != null) {
      _setArmed(true);
      return;
    }
    _starting = true;
    final epoch = _epoch;
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted || !_enabled || epoch != _epoch) {
        if (!mic.isGranted && _enabled && epoch == _epoch) {
          onBlocked?.call(
            'Нет доступа к микрофону — слово «$_wakeWord» не услышит. '
            'Разрешите микрофон для приложения.',
          );
        }
        return;
      }
      if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
        debugPrint('WakeWord: нет ключа Gemini');
        onBlocked?.call('Не настроен ключ Gemini — wake-слово не работает.');
        return;
      }

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: false,
          noiseSuppress: false,
          autoGain: true,
          audioInterruption: AudioInterruptionMode.none,
          androidConfig: AndroidRecordConfig(
            manageBluetooth: false,
            audioSource: AndroidAudioSource.mic,
            speakerphone: false,
            audioManagerMode: AudioManagerMode.modeNormal,
          ),
        ),
      );
      if (!_enabled || epoch != _epoch) {
        await _recorder.stop();
        return;
      }
      _loudChunks = 0;
      _quietChunks = 0;
      _capturing = false;
      _preRoll.clear();
      _utterance.clear();
      _micSub = stream.listen(
        (chunk) {
          if (!_enabled || epoch != _epoch || _waking) return;
          _onPcm(chunk);
        },
        onError: (error) {
          debugPrint('WakeWord: mic error $error');
          unawaited(_onStreamDead());
        },
        onDone: () => unawaited(_onStreamDead()),
      );
      _setArmed(true);
      debugPrint('WakeWord: PCM слушаю «$_wakeWord» (fallback)');
    } catch (e) {
      debugPrint('WakeWord: start failed $e');
      _setArmed(false);
      _schedulePcmReconnect();
    } finally {
      _starting = false;
    }
  }

  Future<void> _onStreamDead() async {
    _micSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
    _setArmed(false);
    _schedulePcmReconnect();
  }

  void _schedulePcmReconnect() {
    if (!_enabled || _waking || _starting) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 8), () {
      if (_enabled && !_waking && _micSub == null) {
        unawaited(_listenPcm());
      }
    });
  }

  void _onPcm(Uint8List chunk) {
    if (_waking) return;
    _preRoll.addAll(chunk);
    if (_preRoll.length > _preRollBytes) {
      _preRoll.removeRange(0, _preRoll.length - _preRollBytes);
    }

    final rms = pcmRms(chunk);
    if (!_capturing) {
      if (rms >= _speechRms) {
        _loudChunks++;
        if (_loudChunks >= _loudChunksNeeded) {
          _capturing = true;
          _quietChunks = 0;
          _utterance.clear();
          _utterance.add(Uint8List.fromList(_preRoll));
        }
      } else {
        _loudChunks = 0;
      }
      return;
    }

    _utterance.add(chunk);
    if (rms < _silenceRms) {
      _quietChunks++;
    } else {
      _quietChunks = 0;
    }

    final size = _utterance.length;
    if (!_probing &&
        size >= _readyToProbeBytes &&
        DateTime.now().isAfter(_nextProbeAt)) {
      var snap = Uint8List.fromList(_utterance.toBytes());
      if (snap.length > 32000) {
        snap = Uint8List.fromList(snap.sublist(snap.length - 32000));
      }
      unawaited(_probeWakeWord(snap));
    }

    final ended = _quietChunks >= _quietChunksNeeded;
    final tooLong = size >= _maxUtteranceBytes;
    if (!ended && !tooLong) return;

    var pcm = _utterance.takeBytes();
    _capturing = false;
    _loudChunks = 0;
    _quietChunks = 0;
    if (_probing || pcm.length < _minUtteranceBytes) return;
    if (pcm.length > 32000) {
      pcm = Uint8List.fromList(pcm.sublist(pcm.length - 32000));
    }
    unawaited(_probeWakeWord(pcm));
  }

  Future<void> _probeWakeWord(Uint8List pcm) async {
    if (!_enabled || _probing || _waking) return;
    if (DateTime.now().isBefore(_nextProbeAt)) return;
    _probing = true;
    _nextProbeAt = DateTime.now().add(const Duration(milliseconds: 420));
    final epoch = _epoch;
    try {
      final result = await _analyzeUtterance(pcm);
      if (epoch != _epoch || !_enabled || _waking) return;
      debugPrint('WakeWord probe: ${result.text} wake=${result.wake}');
      if (result.wake || matchesWake(result.text)) {
        await _fireWake();
      }
    } catch (e) {
      debugPrint('WakeWord probe failed: $e');
    } finally {
      _probing = false;
    }
  }

  Future<({String text, bool wake})> _analyzeUtterance(Uint8List pcm) async {
    final wav = _pcm16ToWav(pcm, 16000);
    Object? last;
    for (final name in _probeModels) {
      try {
        final model = GenerativeModel(
          model: name,
          apiKey: kGeminiApiKey,
        );
        final response = await model.generateContent([
          Content.multi([
            TextPart(
              'The wake name is FIX-Appliance (sounds like fix appliance, фикс апплаенс). '
              'Transcribe the clip, then say if that name was spoken. '
              'Reply exactly:\n'
              'T: <spoken words or EMPTY>\n'
              'W: YES or NO',
            ),
            DataPart('audio/wav', wav),
          ]),
        ]).timeout(const Duration(milliseconds: 4500));
        final raw = (response.text ?? '').trim();
        if (raw.isEmpty) continue;
        return _parseWakeReply(raw);
      } catch (e) {
        last = e;
        debugPrint('WakeWord $name failed: $e');
      }
    }
    if (last != null) throw last;
    return (text: '', wake: false);
  }

  ({String text, bool wake}) _parseWakeReply(String raw) {
    var text = '';
    var wake = false;
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('t:')) {
        text = trimmed.substring(2).trim();
      } else if (lower.startsWith('w:')) {
        wake = _probeSaysYes(trimmed.substring(2));
      }
    }
    if (text.isEmpty) {
      text = raw
          .replaceAll(RegExp(r'w:\s*(yes|no|da|net)', caseSensitive: false), '')
          .replaceAll(RegExp(r't:', caseSensitive: false), '')
          .trim();
    }
    if (!wake) {
      wake = matchesWake(text);
    }
    return (text: text, wake: wake);
  }

  Future<void> _fireWake() async {
    if (!_enabled || _waking) return;
    _waking = true;
    debugPrint('WakeWord: FIRE');
    _enabled = false;
    _reconnectTimer?.cancel();
    await _stopStt();
    await _tearDown();
    _setArmed(false);
    await Future<void>.delayed(const Duration(milliseconds: 280));
    onWake?.call();
  }

  static Uint8List _pcm16ToWav(Uint8List pcm, int sampleRate) {
    final header = ByteData(44);
    final dataLen = pcm.length;
    header.setUint32(0, 0x52494646, Endian.big);
    header.setUint32(4, 36 + dataLen, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big);
    header.setUint32(12, 0x666d7420, Endian.big);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big);
    header.setUint32(40, dataLen, Endian.little);
    final out = Uint8List(44 + dataLen);
    out.setAll(0, header.buffer.asUint8List());
    out.setAll(44, pcm);
    return out;
  }

  @override
  void dispose() {
    stop();
    _recorder.dispose();
    super.dispose();
  }
}
