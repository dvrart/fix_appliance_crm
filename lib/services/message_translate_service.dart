import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';
import 'auth_service.dart';

/// Перевод переписки с клиентом: входящие EN→RU, исходящие RU→EN.
class MessageTranslateService {
  static final Map<String, String> _enCache = {};
  static final Map<String, String> _ruCache = {};
  // Запасной путь, когда сервер недоступен. Моделей, которых нет на нашем
  // ключе, тут быть не должно: каждая стоит таймаута перед живой
  // (gemini-3.6-flash и gemini-2.5-flash отвечали 404 и 429).
  static const _models = [
    'gemini-flash-lite-latest',
    'gemini-flash-latest',
  ];

  static final _cyrillic = RegExp(r'[А-Яа-яЁё]');
  static final _latin = RegExp(r'[A-Za-z]');
  static final _urlOrEmail = RegExp(
    r'https?://\S+|www\.\S+|\b\S+@\S+\.\S+\b',
    caseSensitive: false,
  );
  static final _ruFieldLabelWithCode = RegExp(
    r'(?:Модель|Серийный номер|Серийник|Бренд)\s*:\s*[A-Za-z0-9_./-]+',
    caseSensitive: false,
  );
  static final _ruBoilerplate = RegExp(
    r'(?:Модель|Серийный номер|Серийник|Бренд|Удобное время)\s*:?|\b(?:пн|вт|ср|чт|пт|сб|вс)\b',
    caseSensitive: false,
  );
  static final _codeToken = RegExp(r'\b[A-Za-z0-9_./-]*\d[A-Za-z0-9_./-]*\b');
  static final _brandToken = RegExp(
    r'\b(?:fixapplianceca|fixappliance|samsung|lg|ge|bosch|whirlpool|maytag|frigidaire|kitchenaid|electrolux|'
    r'kenmore|miele|amana|inglis|danby|haier|wolf|sub-zero|subzero|viking|'
    r'thermador|blomberg|fisher|paykel|panasonic|sharp|xiaomi|hisense|midea|'
    r'gaggenau|jenn-air|jennair|hotpoint|admiral|roper|crosley|avanti|koolmore|'
    r'bertazzoni|smeg|jbl|speed\s+queen|magic\s+chef|monogram|profile|bespoke)\b',
    caseSensitive: false,
  );
  static final _speakerPrefix = RegExp(
    r'^\s*(?:ИИ|AI|Assistant|Secretary|Секретарь|Me|Master|Мастер|Моё|Мое|Technician|FixApplianceCA|Клиент|Client|User|Caller|Customer)\s*:\s*',
    caseSensitive: false,
    multiLine: true,
  );
  static final _latinWord = RegExp(r"[A-Za-z][A-Za-z'’-]*");
  static final _lowerLatinWord = RegExp(r"\b[a-z][a-z'’-]+\b");

  static const _jobRuInstruction =
      'Ты переводишь и приводишь в порядок описание поломки в карточке заявки для мастера по ремонту бытовой техники в Онтарио.\n'
      'Переводи грамотным, естественным русским языком мастера, без машинного подстрочника. Английских слов в описании поломки остаться не должно.\n'
      'Латиницей оставляй ТОЛЬКО имена людей, названия городов и улиц, марки техники, номера моделей/серийников и коды ошибок (E15, F21).\n'
      'Правильные термины: timer knob / timer button — ручка таймера, door seal / gasket — уплотнитель дверцы, smooth top / glass cooktop / clear top — стеклокерамическая варочная панель, burner — конфорка, heating element / bake element — ТЭН (нагревательный элемент), igniter — свеча розжига, drain pump — сливной насос, float switch — поплавковый датчик, control board — плата управления, spray arm — коромысло (разбрызгиватель), drum — барабан, service call — выезд мастера.\n'
      'Учитывай род техники по-русски (сушилка, стиральная машина, посудомойка, плита, духовка — женский род; холодильник — мужской род).\n'
      'Если в тексте есть английские дубли в скобках вроде «Не запускается (Won\'t start)» — оставь только русский текст без скобок.\n'
      'Если одна и та же поломка повторена несколько раз разными словами в отдельных строках — объедини эти повторы в одну чёткую фразу, сохранив все детали, номер модели и строку «Удобное время: ...» (переведя английские пометки времени внутри неё на русский).\n'
      'Верни ТОЛЬКО готовый текст без кавычек и пояснений.';

  static bool hasCyrillic(String text) => _cyrillic.hasMatch(text);
  static bool hasLatin(String text) => _latin.hasMatch(text);

  static bool looksEnglish(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!hasLatin(t)) return false;
    return !hasCyrillic(t);
  }

  static bool looksRussian(String text) => hasCyrillic(text.trim());

  static String stripSpeakerLabels(String text) =>
      text.replaceAll(_speakerPrefix, '');

  static String _stripNonProseTokens(String text) {
    return text
        .replaceAll(_speakerPrefix, ' ')
        .replaceAll(_urlOrEmail, ' ')
        .replaceAll(_ruFieldLabelWithCode, ' ')
        .replaceAll(_ruBoilerplate, ' ')
        .replaceAll(_codeToken, ' ')
        .replaceAll(_brandToken, ' ');
  }

  /// Переведён ли уже разговор (или выжимка) на русский — без учёта
  /// русских меток «ИИ:» / «Клиент:», которые ставятся и поверх английской
  /// расшифровки, и без ложного срабатывания на английские имена и улицы.
  static bool isRussianDialog(String text) {
    final stripped = stripSpeakerLabels(text).trim();
    if (stripped.isEmpty) return false;
    final cleaned = _stripNonProseTokens(stripped).trim();
    final cyr = _cyrillic.allMatches(cleaned).length;
    if (cyr == 0) return false;
    final lat = _latin.allMatches(cleaned).length;
    if (cyr <= lat) return false;
    for (final rawLine in stripped.split('\n')) {
      final line = _stripNonProseTokens(rawLine).trim();
      if (line.isEmpty) continue;
      final lineCyr = _cyrillic.allMatches(line).length;
      if (lineCyr == 0 && _latinWord.allMatches(line).length >= 5) {
        return false;
      }
    }
    return true;
  }

  static bool needsRussianDialog(String text) {
    final stripped = stripSpeakerLabels(text).trim();
    if (skip(stripped)) return false;
    if (!hasLatin(stripped)) return false;
    return !isRussianDialog(text);
  }

  /// Есть ли в тексте непереведённый английский текст (даже если рядом уже есть
  /// русские подписи «Модель:», «Удобное время:» или отдельные русские строки).
  static bool prefersRussian(String text) {
    final t = text.trim();
    if (skip(t) || !hasLatin(t)) return false;
    if (!hasCyrillic(t)) return true;
    final cleaned = _stripNonProseTokens(t);
    if (!hasLatin(cleaned)) return false;
    if (!hasCyrillic(cleaned)) return true;
    if (_lowerLatinWord.hasMatch(cleaned)) return true;
    final words = _latinWord.allMatches(cleaned).length;
    if (words >= 2) return true;
    final cyr = _cyrillic.allMatches(cleaned).length;
    final lat = _latin.allMatches(cleaned).length;
    return lat > cyr;
  }

  static bool needsRussian(String text) {
    if (skip(text)) return false;
    if (looksRussian(text) && !hasLatin(text)) return false;
    return hasLatin(text);
  }

  static bool skip(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    if (t.length < 3 && !hasCyrillic(t)) return true;
    if (RegExp(r'^[\d\s.,:+\-/#]+$').hasMatch(t)) return true;
    return false;
  }

  static bool failedEnglish(String original, String translated) {
    final src = original.trim();
    final out = translated.trim();
    if (src.isEmpty || out.isEmpty) return true;
    if (!looksRussian(src)) return false;
    if (out == src) return true;
    final cyr = _cyrillic.allMatches(out).length;
    final lat = _latin.allMatches(out).length;
    if (lat == 0) return true;
    return cyr > lat;
  }

  static bool failedRussian(String original, String translated) {
    final src = original.trim();
    final out = translated.trim();
    if (src.isEmpty || out.isEmpty) return true;
    if (!needsRussian(src)) return false;
    if (out == src && prefersRussian(src)) return true;
    if (!hasCyrillic(out)) return true;
    final cleaned = _stripNonProseTokens(out);
    final cyr = _cyrillic.allMatches(cleaned).length;
    final lat = _latin.allMatches(cleaned).length;
    return cyr == 0 && lat > 0 || lat > cyr;
  }

  static Future<String> toEnglish(String text) async {
    final t = text.trim();
    if (t.isEmpty || !looksRussian(t)) return t;
    if (RegExp(r'^[\d\s.,:+\-/#]+$').hasMatch(t)) return t;
    final cached = _enCache[t];
    if (cached != null) return cached;
    final translated = await _translate(
      t,
      'en',
      'Translate the technician\'s message to the client into natural Canadian English. '
          'Keep names, addresses, model numbers, and URLs unchanged. '
          'Return ONLY the English translation, no quotes or notes.',
    );
    if (failedEnglish(t, translated)) return t;
    _enCache[t] = translated;
    return translated;
  }

  static Future<String> toRussian(String text) async {
    final t = text.trim();
    if (!needsRussian(t)) return t;
    final cached = _ruCache[t];
    if (cached != null) return cached;
    final translated = await _translate(
      t,
      'ru',
      'Переведи сообщение клиента мастеру на естественный русский. '
          'Имена, адреса, модели и ссылки не меняй. '
          'Верни ТОЛЬКО перевод, без кавычек и пояснений.',
    );
    if (failedRussian(t, translated)) return t;
    _ruCache[t] = translated;
    return translated;
  }

  /// Перевод описания неисправности во вкладке «Информация» с учётом техники.
  static Future<String> toRussianJob(
    String text, {
    String appliance = '',
  }) async {
    final t = text.trim();
    if (!needsRussian(t)) return t;
    final app = appliance.trim();
    final key = 'job:$app:$t';
    final cached = _ruCache[key];
    if (cached != null) return cached;
    final instruction = app.isEmpty
        ? _jobRuInstruction
        : '$_jobRuInstruction\nТехника в заявке: $app.';
    final translated = await _translate(
      t,
      'ru',
      instruction,
      mode: 'job',
      appliance: app.isEmpty ? null : app,
    );
    if (failedRussian(t, translated)) return t;
    _ruCache[key] = translated;
    return translated;
  }

  /// Перевод записи разговора. Идёт на сервер: там диалог переводится
  /// построчно и со сверкой количества реплик, поэтому реплики не пропадают.
  /// Локальная модель остаётся только на случай, когда сервер не ответил.
  static Future<String> toRussianDialog(
    String text, {
    String answeredBy = '',
  }) async {
    final t = text.trim();
    if (!needsRussianDialog(t)) return t;
    final speaker = answeredBy.trim();
    final cacheKey = 'dialog:$speaker:$t';
    final cached = _ruCache[cacheKey];
    if (cached != null) return cached;
    final cloud = await _fromCloud(
      t,
      'ru',
      mode: 'dialog',
      answeredBy: speaker.isEmpty ? null : speaker,
      timeoutSeconds: 110,
    );
    if (cloud != null &&
        cloud.trim().isNotEmpty &&
        isRussianDialog(cloud)) {
      _ruCache[cacheKey] = cloud.trim();
      return cloud.trim();
    }
    final translated = await _translate(
      t,
      'ru',
      'Переведи этот ПОЛНЫЙ телефонный разговор на русский. '
          'Сохрани каждую реплику и тот же порядок (ИИ: / Клиент: или Моё: / Клиент:). '
          'Ничего не сокращай и не выкидывай конец. Имена и адреса не меняй. '
          'Верни ТОЛЬКО перевод.',
      timeoutSeconds: 45,
      skipCloud: true,
    );
    if (translated.trim().isEmpty || !isRussianDialog(translated)) return t;
    _ruCache[cacheKey] = translated;
    return translated;
  }

  static String polishInstruction({
    required int variant,
    required String emoji,
    String previous = '',
  }) {
    const layouts = [
      'greeting on its own line, then one fact per line, then a short closing',
      'short punchy lines with a blank line between greeting, body, and thanks',
      'compact: greeting plus 2–3 fact lines, close with a short question',
      'friendly checklist: hello line, then hyphen facts, then a warm sign-off',
    ];
    final layout = layouts[(variant.abs() - 1) % layouts.length];
    final emojiRule = emoji == 'more'
        ? 'Use 6–8 emojis. Put them in the greeting, on several fact lines, and in the closing.'
        : emoji == 'less'
            ? 'Use exactly 2 emojis total — one in the greeting and one in the closing. No more.'
            : 'Use 3–5 emojis. Never fewer than 2.';
    final avoid = previous.trim().isEmpty
        ? ''
        : '\nDo NOT copy this previous version. Change line order, emoji placement, and wording while keeping the same facts:\n$previous\n';
    return 'Edit this technician draft into a client SMS. Keep the original language '
        '(Russian stays Russian, English stays English). '
        '$emojiRule '
        'Variation #$variant. Use this structure: $layout. '
        'Break the text into short structured lines. Use blank lines between blocks. '
        'Do not write one long paragraph. '
        'Do not change facts, names, addresses, times, model numbers, phone numbers, or URLs. '
        '$avoid'
        'Return ONLY the edited message.';
  }

  static Future<String> polish(
    String text, {
    int variant = 1,
    String emoji = 'normal',
    String previous = '',
  }) async {
    final t = text.trim();
    if (t.isEmpty) return t;
    final cloud = await _fromCloud(
      t,
      'ru',
      mode: 'polish',
      variant: variant,
      emoji: emoji,
      previous: previous,
    );
    if (cloud != null && cloud.trim().isNotEmpty) return cloud.trim();
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      return t;
    }
    final instruction = polishInstruction(
      variant: variant,
      emoji: emoji,
      previous: previous,
    );
    for (final name in _models) {
      try {
        final model = GenerativeModel(model: name, apiKey: kGeminiApiKey);
        final response = await model
            .generateContent([Content.text('$instruction\n\n$t')])
            .timeout(const Duration(seconds: 18));
        final out = (response.text ?? '').trim();
        if (out.isNotEmpty) return out;
      } catch (error) {
        debugPrint('MessagePolish $name: $error');
      }
    }
    return t;
  }

  static Future<String> _translate(
    String text,
    String to,
    String instruction, {
    String? mode,
    String? appliance,
    int timeoutSeconds = 18,
    bool skipCloud = false,
  }) async {
    if (!skipCloud) {
      final cloud = await _fromCloud(
        text,
        to,
        mode: mode,
        appliance: appliance,
      );
      if (cloud != null && cloud.trim().isNotEmpty) {
        final out = cloud.trim();
        if (to == 'en' && !failedEnglish(text, out)) return out;
        if (to == 'ru' && !failedRussian(text, out)) return out;
      }
    }
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      return text;
    }
    for (final name in _models) {
      try {
        final model = GenerativeModel(model: name, apiKey: kGeminiApiKey);
        final response = await model
            .generateContent([Content.text('$instruction\n\n$text')])
            .timeout(Duration(seconds: timeoutSeconds));
        final out = (response.text ?? '').trim();
        if (out.isEmpty) continue;
        if (to == 'en' && failedEnglish(text, out)) continue;
        if (to == 'ru' && failedRussian(text, out)) continue;
        return out;
      } catch (error) {
        debugPrint('MessageTranslate $name: $error');
      }
    }
    return text;
  }

  static Future<String?> _fromCloud(
    String text,
    String to, {
    String? mode,
    String? appliance,
    String? answeredBy,
    int? variant,
    String? emoji,
    String? previous,
    int timeoutSeconds = 20,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/translateMessage'),
            headers: await AuthService.headers(),
            body: json.encode({
              'text': text,
              'to': to,
              'mode': ?mode,
              'appliance': ?appliance,
              'answeredBy': ?answeredBy,
              'variant': ?variant,
              'emoji': ?emoji,
              'previous': ?previous,
            }),
          )
          .timeout(Duration(seconds: timeoutSeconds));
      if (response.statusCode != 200) {
        debugPrint('MessageTranslate cloud ${response.statusCode}: ${response.body}');
        return null;
      }
      final data = json.decode(response.body);
      final out = (data['polished'] ?? data['translated'] ?? '').toString().trim();
      return out.isEmpty ? null : out;
    } catch (error) {
      debugPrint('MessageTranslate cloud: $error');
      return null;
    }
  }
}
