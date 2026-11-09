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
///
/// Основной путь — **непрерывный PCM + Gemini**. Android STT остаётся
/// запасным: он сам закрывает сессию после `pauseFor` тишины, и каждый
/// перезапуск — это щелчок включения/выключения микрофона и мигающая
/// зелёная точка в шторке (жалоба FIX, 12.10.2026). PCM-поток открывает
/// микрофон один раз и держит его, пока ассистент включён.
class WakeWordService extends ChangeNotifier {
  static const _probeModels = [
    'gemini-3.1-flash-lite',
    'gemini-3.1-flash-lite-preview',
    'gemini-flash-lite-latest',
    'gemini-flash-latest',
  ];

  @visibleForTesting
  static const blindTranscribePrompt =
      'Transcribe the spoken words in this audio clip verbatim in Russian '
      '(Cyrillic) or English.\n'
      'If there is no clear human speech (only silence, background noise, '
      'hum, clicks, rustling, breathing, coughs, or unintelligible mumbles), '
      'reply ONLY: EMPTY\n'
      'Do not guess, invent, or autocomplete words. Do not add pronouns or '
      'words that were not spoken. Reply with the transcript only.';

  /// [preferStt] — начать сразу с запасного Android STT. В бою этого делать
  /// не надо (он и щёлкает микрофоном); параметр нужен тестам, чтобы
  /// проверять запасной путь, не завися от ключа Gemini.
  /// [_analyzer] — подмена разбора PCM для тестов без сети.
  WakeWordService({
    AudioRecorder? recorder,
    stt.SpeechToText? speech,
    bool preferStt = false,
    this._analyzer,
  })  : _recorder = recorder ?? AudioRecorder(),
        _stt = speech ?? stt.SpeechToText(),
        _useStt = preferStt;

  final AudioRecorder _recorder;
  final stt.SpeechToText _stt;
  final Future<({String text, bool wake})> Function(Uint8List pcm)? _analyzer;

  bool _enabled = false;
  bool _starting = false;
  bool _probing = false;
  bool _waking = false;
  bool _sttReady = false;
  bool _sttListening = false;
  bool _carConnected = false;
  bool _usingCarMic = false;

  /// Микрофон не должен щёлкать: PCM держит его открытым, STT — нет.
  bool _useStt;
  bool isArmed = false;
  bool _disposed = false;
  int _epoch = 0;
  Future<void> _transition = Future<void>.value();
  StreamSubscription<Uint8List>? _micSub;
  Timer? _reconnectTimer;
  Timer? _wakeTimer;

  final List<int> _preRoll = [];
  final BytesBuilder _utterance = BytesBuilder();
  int _loudBytes = 0;
  int _quietBytes = 0;
  int _speechBytes = 0;
  double _noiseFloor = 0.005;
  double _peakRms = 0;
  bool _capturing = false;
  bool _awaitingSilence = false;
  Uint8List? _pendingPcm;
  final Map<String, DateTime> _modelCooldownUntil = {};

  static const _preRollBytes = 12800; // 400 мс пре-ролла (16 кГц PCM16)
  static const _minSpeechRms = 0.015;
  static const _minSilenceRms = 0.006;
  static const _minPeakRms = 0.026;
  static const _triggerLoudBytes = 1920; // ~60 мс голоса для начала захвата
  static const _endSilenceBytes = 14400; // 450 мс паузы = конец фразы
  static const _minSpeechBytes = 12800; // минимум 400 мс живой речи («Фикс-аплаянс» ~0,8–1,3 с)
  static const _minUtteranceBytes = 25600;
  static const _maxUtteranceBytes = 86400; // 2,7 с с начала обращения

  void Function()? onWake;
  void Function(String reason)? onBlocked;

  /// Что именно услышано перед последним пробуждением и каким путём
  /// (`pcm` — Gemini по потоку, `stt` — Android). Ассистент открывался сам
  /// (жалобы FIX 13.10 и 18.10.2026), а по чему — было не видно: в релизе
  /// debugPrint не читается. Хост показывает это в снэкбаре и пишет в журнал.
  String lastHeard = '';
  String lastHeardSource = '';

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
    add('fx appliance');
    add('fx alliance');
    add('fix alliance');
    add('fx up lines');
    add('fx supplies');
    add('fx plajens');
    add('effix a players');
    add('efix appliance');
    add('фикс-аплаянс');
    add('фикс аплаянс');
    add('фиксаплаянс');
    add('фикс аплайанс');
    add('эфикс аплаянс');
    add('эфикс аплайанс');
    add('фикс альянс');
    add('фикс-апплаянс');
    add('фикс апплаянс');
    add('фикс апплаенс');
    add('фиксапплаенс');
    add('фикс аплаенс');
    add('фикс эплаянс');
    add('фикс эплаенс');
    add('фикс аплайнс');
    phrases.removeWhere((item) => item.isEmpty);
    return phrases;
  }

  /// Слишком короткий вариант имени, чтобы включать по нему ассистента.
  ///
  /// Одно «fix» мастер произносит по двадцать раз на дню («fixed it», «fix
  /// the dryer», «фиксирую»), и ассистент открывался сам (жалоба FIX,
  /// 13.10.2026). Включаем только по полному имени: «FIX-Appliance».
  static bool _tooShortToWake(String phrase) {
    return phrase.replaceAll(' ', '').length < 8;
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

  static const _nonNameStartWords = {
    'это',
    'эта',
    'эти',
    'этого',
    'этой',
    'этом',
    'из',
    'от',
    'да',
    'нет',
    'алло',
    'але',
    'ало',
    'здравствуйте',
    'здрасьте',
    'компания',
    'фирма',
    'мастер',
    'я',
    'мы',
    'вы',
    'он',
    'она',
    'они',
    'eto',
    'eta',
    'eti',
    'iz',
    'ot',
    'da',
    'net',
    'allo',
    'ale',
    'alo',
    'this',
    'that',
    'it',
    'is',
    'from',
    'at',
    'in',
    'we',
    'i',
    'you',
    'the',
  };

  /// Имя прозвучало целиком и почти без опечаток.
  ///
  /// Сравниваем подряд идущие слова, склеенные в одно, с самим именем:
  /// «fiks appliance» из расшифровки дотягивает, «fixed the dryer» — нет.
  /// Склейка всегда начинается с начала слова и с той же буквы, что и имя,
  /// иначе «six appliance stores» отличалось бы от «fix appliance» на одну
  /// букву и будило ассистента.
  /// Возвращает границы совпавших слов (start..end включительно).
  static ({int start, int end})? _matchSpan(List<String> words, String needle) {
    if (needle.isEmpty) return null;
    final maxDist = needle.length >= 10 ? 2 : 1;
    for (var i = 0; i < words.length; i++) {
      if (_nonNameStartWords.contains(words[i])) continue;
      var joined = '';
      for (var j = i; j < words.length; j++) {
        joined += words[j];
        if (joined.length > needle.length + 2) break;
        if (joined == needle) return (start: i, end: j);
        if (joined.isEmpty || joined[0] != needle[0]) break;
        if (joined.length + 2 < needle.length) continue;
        if (_distance(joined, needle) <= maxDist) return (start: i, end: j);
      }
    }
    return null;
  }

  /// Имя — это обращение к ассистенту, а не упоминание фирмы в разговоре с
  /// клиентом. Допускаем перед именем не более одного слова-оклика
  /// («эй», «слушай», «окей», «hey», «ok»), но НЕ предлоги и не представление
  /// компании («это фикс-аплаянс», «из фикс-аплаянс», «алло, фикс-аплаянс»,
  /// «компания фикс-аплаянс», «I fix appliances»).
  static const _maxWordsBeforeName = 1;

  static const _vocativePrefixes = {
    'hey',
    'hi',
    'ok',
    'okay',
    'yo',
    'ay',
    'eh',
    'эй',
    'хей',
    'окей',
    'ок',
    'слушай',
    'привет',
    'ey',
    'okey',
    'slushay',
    'privet',
  };

  static bool _isVocativePrefix(String word) {
    return _vocativePrefixes.contains(word) ||
        _vocativePrefixes.contains(_toLatin(word));
  }

  static const _companyTailFirstWords = {
    'здравствуйте',
    'здрасьте',
    'алло',
    'але',
    'слушаю',
    'говорите',
    'это',
    'работает',
    'ремонтирует',
    'чинит',
    'занимается',
    'дает',
    'находится',
    'speaking',
    'hello',
    'here',
    'repairs',
    'fixes',
    'works',
    'is',
  };

  static bool _isCompanyMentionTail(List<String> tail) {
    if (tail.isEmpty) return false;
    final first = tail[0];
    final firstLat = _toLatin(first);
    if (_companyTailFirstWords.contains(first) ||
        _companyTailFirstWords.contains(firstLat)) {
      return true;
    }
    if (tail.length >= 2) {
      final pair = '${tail[0]} ${tail[1]}';
      final pairLat = _toLatin(pair);
      const companyPairs = {
        'добрый день',
        'доброе утро',
        'добрый вечер',
        'чем могу',
        'меня зовут',
        'мы находимся',
        'мы работаем',
        'мы ремонтируем',
        'мы чиним',
        'у нас',
        'good morning',
        'good afternoon',
        'good evening',
        'this is',
        'my name',
        'how can',
        'how may',
        'we are',
        'we repair',
        'we fix',
      };
      if (companyPairs.contains(pair) || companyPairs.contains(pairLat)) {
        return true;
      }
    }
    return false;
  }

  static bool _spanIsDirectCall(
    List<String> words,
    ({int start, int end}) span,
  ) {
    if (span.start > _maxWordsBeforeName) return false;
    if (span.start == 1 && !_isVocativePrefix(words[0])) return false;
    final tail = words.sublist(span.end + 1);
    if (tail.length > 5) return false;
    if (_isCompanyMentionTail(tail)) return false;
    return true;
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

  /// Прозвучало ли слово-будильник как прямое обращение к ассистенту.
  ///
  /// Только полное имя («Фикс-аплаянс», «FIX-Appliance») и те варианты из
  /// настроек, что не короче восьми букв. Одиночное «fix» / «фикс» не будит,
  /// как и упоминание фирмы в разговоре с клиентом.
  bool matchesWake(String raw) {
    final cleaned = normalizePhrase(raw);
    if (cleaned.isEmpty || cleaned == 'empty' || cleaned == 'noise') {
      return false;
    }
    final words =
        cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty || words.length > 40) return false;
    final latinWords = words.map(_toLatin).toList();
    for (final phrase in _phrases) {
      final needle = phrase.replaceAll(' ', '');
      if (_tooShortToWake(phrase)) {
        final idx = words.indexOf(phrase);
        final latIdx = latinWords.indexOf(_toLatin(phrase));
        final at = idx >= 0 ? idx : latIdx;
        if (at >= 0 &&
            _spanIsDirectCall(words, (start: at, end: at))) {
          return true;
        }
        continue;
      }
      final span =
          _matchSpan(words, needle) ?? _matchSpan(latinWords, _toLatin(needle));
      if (span != null && _spanIsDirectCall(words, span)) {
        return true;
      }
    }
    return false;
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

  bool get isRunning =>
      !_disposed && (_enabled || _starting || isArmed || _waking);

  bool _isCurrent(int epoch) =>
      !_disposed && _enabled && !_waking && epoch == _epoch;

  bool _canStart(int epoch) =>
      _isCurrent(epoch) && !AssistantAudioService.playback.isActive;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _transition.then((_) => action());
    _transition = next.catchError((Object error) {
      debugPrint('WakeWord transition failed: $error');
    });
    return next;
  }

  Future<void> start() {
    if (_disposed || _waking || (_enabled && (_starting || isArmed))) {
      return _transition;
    }
    _enabled = true;
    return _listen(_epoch);
  }

  Future<void> stop() {
    _epoch++;
    _enabled = false;
    _waking = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _capturing = false;
    _awaitingSilence = false;
    _loudBytes = 0;
    _quietBytes = 0;
    _speechBytes = 0;
    _peakRms = 0;
    _pendingPcm = null;
    _preRoll.clear();
    _utterance.clear();
    return _disposed ? _transition : _serialize(_stopNative);
  }

  Future<void> refreshAudioRoute() async {
    if (_disposed || !_enabled || _waking) return;
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _serialize(_stopNative);
    if (_isCurrent(epoch)) {
      await _listen(epoch);
    }
  }

  Future<void> _stopNative() async {
    await _stopStt();
    await _tearDown();
    _setArmed(false);
  }

  Future<void> _stopStt() async {
    _sttListening = false;
    try {
      await _stt.cancel();
    } catch (_) {}
    await AssistantAudioService.muteRecognitionBeeps(false);
    if (_usingCarMic) {
      _usingCarMic = false;
      await AssistantAudioService.releaseWakeCarAudio();
    }
  }

  Future<void> _tearDown() async {
    final sub = _micSub;
    _micSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
    if (_usingCarMic) {
      _usingCarMic = false;
      await AssistantAudioService.releaseWakeCarAudio();
    }
  }

  void _setArmed(bool value) {
    if (isArmed == value) return;
    isArmed = value;
    if (!_disposed) notifyListeners();
  }

  Future<bool> _allowListening(int epoch) async {
    if (!_isCurrent(epoch)) return false;
    if (AssistantAudioService.playback.isActive) {
      await _stopNative();
      if (_isCurrent(epoch)) _scheduleReconnect(epoch);
      return false;
    }
    final state = await AssistantAudioService.readState();
    if (!_isCurrent(epoch)) return false;
    _carConnected = state.carConnected;
    if (!state.blocksWake && !AssistantAudioService.playback.isActive) {
      return true;
    }
    await _stopNative();
    if (_isCurrent(epoch)) _scheduleReconnect(epoch);
    return false;
  }

  Future<void> _listen(int epoch) => _serialize(() async {
        if (!_isCurrent(epoch)) return;
        if (_useStt && (_sttListening || _stt.isListening)) return;
        if (!_useStt && _micSub != null) return;
        _starting = true;
        try {
          if (!await _allowListening(epoch) || !_canStart(epoch)) return;
          if (_useStt) {
            await _listenStt(epoch);
          } else {
            await _listenPcm(epoch);
          }
        } finally {
          _starting = false;
          if (!_canStart(epoch)) {
            await _stopNative();
            if (_isCurrent(epoch)) _scheduleReconnect(epoch);
          }
        }
      });

  Future<void> _listenStt(int epoch) async {
    if (!_canStart(epoch)) return;
    try {
      final mic = await Permission.microphone.request();
      if (!_canStart(epoch)) return;
      if (!mic.isGranted) {
        onBlocked?.call(
          'Нет доступа к микрофону — слово «$_wakeWord» не услышит. '
          'Разрешите микрофон для приложения.',
        );
        return;
      }

      if (!_sttReady) {
        _sttReady = await _stt.initialize(
          onStatus: _onSttStatus,
          onError: (error) {
            if (!_isCurrent(_epoch) || !_useStt || !_sttListening) return;
            debugPrint('WakeWord STT error: ${error.errorMsg}');
            _sttListening = false;
            _setArmed(false);
            _scheduleReconnect(_epoch);
          },
        );
        if (!_canStart(epoch)) return;
      }
      if (!_sttReady) {
        // PCM сюда уже не возвращаемся: в него и упирается запасной путь.
        debugPrint('WakeWord: STT недоступен');
        await _stopStt();
        _setArmed(false);
        if (_isCurrent(epoch)) _scheduleReconnect(epoch);
        return;
      }

      await _startSttSession(epoch);
    } catch (e) {
      debugPrint('WakeWord STT start failed: $e');
      await _stopStt();
      _setArmed(false);
      if (_isCurrent(epoch)) _scheduleReconnect(epoch);
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
    if (!_canStart(epoch) || _sttListening || _stt.isListening) return;
    final localeId = await _pickSttLocale();
    if (!_canStart(epoch)) return;
    await AssistantAudioService.muteRecognitionBeeps(true);
    if (!_canStart(epoch)) return;
    if (!await _allowListening(epoch) || !_canStart(epoch)) return;
    if (_carConnected) {
      await AssistantAudioService.preferredInputDevice(forWake: true);
      if (!_canStart(epoch)) {
        await AssistantAudioService.releaseWakeCarAudio();
        return;
      }
      _usingCarMic = true;
    }
    _sttListening = true;
    debugPrint('WakeWord: STT слушаю «$_wakeWord»');
    try {
      await _stt.listen(
        onResult: (result) {
          if (!_canStart(epoch)) return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          debugPrint(
            'WakeWord STT: "$words" final=${result.finalResult}',
          );
          if (matchesWake(words)) {
            lastHeard = words;
            lastHeardSource = 'stt';
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
      if (!_canStart(epoch)) return;
      if (!await _allowListening(epoch) || !_canStart(epoch)) return;
      _setArmed(_sttListening);
      if (!_sttListening) _scheduleReconnect(epoch);
    } catch (e) {
      debugPrint('WakeWord STT listen failed: $e');
      await _stopStt();
      _setArmed(false);
      if (_isCurrent(epoch)) _scheduleReconnect(epoch);
    }
  }

  void _onSttStatus(String status) {
    if (!_isCurrent(_epoch) || !_useStt || !_sttListening) return;
    debugPrint('WakeWord STT status: $status');
    if (status == 'done' || status == 'notListening') {
      _sttListening = false;
      _setArmed(false);
      _scheduleReconnect(_epoch);
    }
  }

  void _scheduleReconnect(int epoch) {
    if (!_isCurrent(epoch)) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      _useStt
          ? const Duration(milliseconds: 450)
          : const Duration(seconds: 8),
      () {
        _reconnectTimer = null;
        if (_isCurrent(epoch)) unawaited(_listen(epoch));
      },
    );
  }

  Future<void> _listenPcm(int epoch) async {
    if (!_canStart(epoch)) return;
    try {
      final mic = await Permission.microphone.request();
      if (!_canStart(epoch)) return;
      if (!mic.isGranted) {
        onBlocked?.call(
          'Нет доступа к микрофону — слово «$_wakeWord» не услышит. '
          'Разрешите микрофон для приложения.',
        );
        return;
      }
      if (_analyzer == null &&
          (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY')) {
        // Без ключа разбирать поток нечем — остаётся STT, пусть и со щелчком.
        debugPrint('WakeWord: нет ключа Gemini, STT fallback');
        await _fallbackToStt(epoch);
        return;
      }
      if (!await _allowListening(epoch) || !_canStart(epoch)) return;
      InputDevice? carInput;
      if (_carConnected) {
        carInput = await AssistantAudioService.preferredInputDevice(
          forWake: true,
        );
        if (!_canStart(epoch)) {
          await AssistantAudioService.releaseWakeCarAudio();
          return;
        }
      }
      _usingCarMic = carInput != null || _carConnected;

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          device: carInput,
          echoCancel: carInput != null,
          noiseSuppress: true,
          autoGain: true,
          audioInterruption: AudioInterruptionMode.none,
          androidConfig: AndroidRecordConfig(
            manageBluetooth: false,
            audioSource: carInput != null
                ? AndroidAudioSource.voiceCommunication
                : AndroidAudioSource.mic,
            speakerphone: false,
            audioManagerMode: AudioManagerMode.modeNormal,
          ),
        ),
      );
      if (!_canStart(epoch)) return;
      if (!await _allowListening(epoch) || !_canStart(epoch)) return;
      _loudBytes = 0;
      _quietBytes = 0;
      _speechBytes = 0;
      _peakRms = 0;
      _noiseFloor = 0.005;
      _capturing = false;
      _awaitingSilence = false;
      _pendingPcm = null;
      _preRoll.clear();
      _utterance.clear();
      late final StreamSubscription<Uint8List> sub;
      sub = stream.listen(
        (chunk) {
          if (!_canStart(epoch)) return;
          _onPcm(chunk);
        },
        onError: (error) {
          debugPrint('WakeWord: mic error $error');
          unawaited(_onStreamDead(epoch, sub));
        },
        onDone: () => unawaited(_onStreamDead(epoch, sub)),
      );
      _micSub = sub;
      _setArmed(true);
      debugPrint('WakeWord: PCM слушаю «$_wakeWord»');
    } catch (e) {
      debugPrint('WakeWord: start failed $e');
      await _tearDown();
      _setArmed(false);
      await _fallbackToStt(epoch);
    }
  }

  /// Микрофон потоком не открылся. Лучше щёлкающий STT, чем глухой ассистент.
  Future<void> _fallbackToStt(int epoch) async {
    if (_useStt) {
      if (_isCurrent(epoch)) _scheduleReconnect(epoch);
      return;
    }
    _useStt = true;
    if (!_canStart(epoch)) return;
    await _listenStt(epoch);
  }

  Future<void> _onStreamDead(
    int epoch,
    StreamSubscription<Uint8List> sub,
  ) => _serialize(() async {
        if (!_isCurrent(epoch) || _micSub != sub) return;
        await _tearDown();
        _setArmed(false);
        if (_isCurrent(epoch)) _scheduleReconnect(epoch);
      });

  void _onPcm(Uint8List chunk) {
    if (_waking || chunk.isEmpty) return;
    _preRoll.addAll(chunk);
    if (_preRoll.length > _preRollBytes) {
      _preRoll.removeRange(0, _preRoll.length - _preRollBytes);
    }

    final rms = pcmRms(chunk);
    final speechRms = math.max(_minSpeechRms, _noiseFloor * 3.0);
    final silenceRms = math.max(_minSilenceRms, _noiseFloor * 1.6);

    if (_awaitingSilence) {
      if (rms < silenceRms) {
        _quietBytes += chunk.length;
        _noiseFloor = (_noiseFloor * 0.94 + rms * 0.06).clamp(0.002, 0.040);
        if (_quietBytes >= _endSilenceBytes) {
          _awaitingSilence = false;
          _quietBytes = 0;
          _loudBytes = 0;
        }
      } else {
        _quietBytes = 0;
        _noiseFloor = (_noiseFloor * 0.985 + rms * 0.015).clamp(0.002, 0.040);
      }
      return;
    }

    if (!_capturing) {
      if (rms >= speechRms) {
        _loudBytes += chunk.length;
        if (_loudBytes >= _triggerLoudBytes) {
          _capturing = true;
          _quietBytes = 0;
          _speechBytes = _loudBytes;
          _peakRms = rms;
          _utterance.clear();
          _utterance.add(Uint8List.fromList(_preRoll));
        }
      } else {
        _loudBytes = 0;
        _noiseFloor = (_noiseFloor * 0.92 + rms * 0.08).clamp(0.002, 0.040);
      }
      return;
    }

    _utterance.add(chunk);
    if (rms > _peakRms) _peakRms = rms;
    if (rms >= speechRms) {
      _quietBytes = 0;
      _speechBytes += chunk.length;
    } else if (rms < silenceRms) {
      _quietBytes += chunk.length;
    } else {
      _quietBytes += chunk.length ~/ 2;
    }

    final ended = _quietBytes >= _endSilenceBytes;
    final tooLong = _utterance.length >= _maxUtteranceBytes;
    if (!ended && !tooLong) return;

    final pcm = _utterance.takeBytes();
    final spoken = _speechBytes;
    final peak = _peakRms;
    _capturing = false;
    _loudBytes = 0;
    _quietBytes = 0;
    _speechBytes = 0;
    _peakRms = 0;
    if (tooLong && !ended) {
      // Длинная непрерывная речь (>2,7 с без паузы): проверяем её начало, а
      // остаток того же предложения не режем на новые куски до паузы.
      _awaitingSilence = true;
    }
    final minPeak = math.max(_minPeakRms, _noiseFloor * 3.5);
    if (spoken < _minSpeechBytes ||
        pcm.length < _minUtteranceBytes ||
        peak < minPeak) {
      return;
    }
    debugPrint(
      'WakeWord capture: ${(pcm.length / 32000).toStringAsFixed(2)}s '
      'speech=${(spoken / 32000).toStringAsFixed(2)}s '
      'peak=${peak.toStringAsFixed(4)} floor=${_noiseFloor.toStringAsFixed(4)}',
    );
    if (_probing) {
      _pendingPcm = pcm;
      return;
    }
    unawaited(_probeWakeWord(pcm));
  }

  Future<void> _probeWakeWord(Uint8List pcm) async {
    if (!_enabled || _probing || _waking) return;
    _probing = true;
    var currentPcm = pcm;
    try {
      while (_enabled && !_waking) {
        final epoch = _epoch;
        try {
          final analyze = _analyzer ?? _analyzeUtterance;
          final result = await analyze(currentPcm);
          if (epoch != _epoch || !_enabled || _waking) return;
          debugPrint('WakeWord probe: ${result.text} wake=${result.wake}');
          // Нужны оба голоса: и «да» модели, и само имя в расшифровке.
          if (result.wake && matchesWake(result.text)) {
            _pendingPcm = null;
            lastHeard = result.text;
            lastHeardSource = 'pcm';
            await _fireWake();
            return;
          }
        } catch (e) {
          debugPrint('WakeWord probe failed: $e');
        }
        final next = _pendingPcm;
        _pendingPcm = null;
        if (next == null) break;
        currentPcm = next;
      }
    } finally {
      _probing = false;
    }
  }

  Future<({String text, bool wake})> _analyzeUtterance(Uint8List pcm) async {
    final wav = _pcm16ToWav(pcm, 16000);
    final now = DateTime.now();
    final activeModels = _probeModels
        .where((m) => (_modelCooldownUntil[m] ?? now).isBefore(now))
        .toList();
    final candidates = activeModels.isNotEmpty ? activeModels : _probeModels;
    Object? last;
    for (final name in candidates) {
      try {
        final model = GenerativeModel(
          model: name,
          apiKey: kGeminiApiKey,
          generationConfig: GenerationConfig(
            temperature: 0,
            maxOutputTokens: 64,
          ),
        );
        final response = await model.generateContent([
          Content.multi([
            TextPart(blindTranscribePrompt),
            DataPart('audio/wav', wav),
          ]),
        ]).timeout(const Duration(milliseconds: 4500));
        final raw = (response.text ?? '').trim();
        if (raw.isEmpty) continue;
        return _parseWakeReply(raw);
      } catch (e) {
        last = e;
        final msg = e.toString().toLowerCase();
        if (msg.contains('429') ||
            msg.contains('quota') ||
            msg.contains('resource_exhausted')) {
          _modelCooldownUntil[name] =
              DateTime.now().add(const Duration(minutes: 15));
        }
        debugPrint('WakeWord $name failed: $e');
      }
    }
    if (last != null) throw last;
    return (text: '', wake: false);
  }

  ({String text, bool wake}) _parseWakeReply(String raw) {
    var text = '';
    bool? explicitWake;
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('t:')) {
        text = trimmed.substring(2).trim();
      } else if (lower.startsWith('w:')) {
        explicitWake = _probeSaysYes(trimmed.substring(2));
      }
    }
    if (text.isEmpty) {
      text = raw
          .replaceAll(RegExp(r'w:\s*(yes|no|da|net)', caseSensitive: false), '')
          .replaceAll(RegExp(r't:', caseSensitive: false), '')
          .trim();
    }
    final upper = text.toUpperCase();
    if (upper == 'EMPTY' || upper == 'NOISE' || upper == 'NONE') {
      return (text: 'EMPTY', wake: false);
    }
    final matched = matchesWake(text);
    return (text: text, wake: (explicitWake ?? true) && matched);
  }

  Future<void> _fireWake() async {
    if (!_canStart(_epoch)) return;
    final cleanup = stop();
    final epoch = _epoch;
    _waking = true;
    debugPrint('WakeWord: FIRE');
    await cleanup;
    if (_disposed || !_waking || epoch != _epoch) return;
    _wakeTimer = Timer(const Duration(milliseconds: 280), () async {
      _wakeTimer = null;
      if (_disposed || !_waking || epoch != _epoch) return;
      final allowed = await AssistantAudioService.canListenForWake();
      if (_disposed || !_waking || epoch != _epoch) return;
      if (!allowed || AssistantAudioService.playback.isActive) {
        _waking = false;
        return;
      }
      _waking = false;
      onWake?.call();
    });
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
    if (_disposed) return;
    unawaited(stop());
    _disposed = true;
    unawaited(_serialize(_recorder.dispose));
    super.dispose();
  }
}
