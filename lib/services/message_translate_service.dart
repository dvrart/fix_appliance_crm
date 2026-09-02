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
  static const _models = [
    'gemini-3.6-flash',
    'gemini-2.5-flash',
    'gemini-flash-latest',
    'gemini-flash-lite-latest',
  ];

  static final _cyrillic = RegExp(r'[А-Яа-яЁё]');
  static final _latin = RegExp(r'[A-Za-z]');

  static bool hasCyrillic(String text) => _cyrillic.hasMatch(text);
  static bool hasLatin(String text) => _latin.hasMatch(text);

  static bool looksEnglish(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!hasLatin(t)) return false;
    return !hasCyrillic(t);
  }

  static bool looksRussian(String text) => hasCyrillic(text.trim());

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
    if (translated.trim().isEmpty) return t;
    _ruCache[t] = translated;
    return translated;
  }

  static Future<String> toRussianDialog(String text) async {
    final t = text.trim();
    if (!needsRussian(t)) return t;
    final cached = _ruCache['dialog:$t'];
    if (cached != null) return cached;
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
    if (translated.trim().isEmpty) return t;
    _ruCache['dialog:$t'] = translated;
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
    int timeoutSeconds = 18,
    bool skipCloud = false,
  }) async {
    if (!skipCloud) {
      final cloud = await _fromCloud(text, to);
      if (cloud != null && cloud.trim().isNotEmpty) return cloud.trim();
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
        if (to == 'ru' && looksEnglish(out) && looksEnglish(text)) continue;
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
    int? variant,
    String? emoji,
    String? previous,
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
              'variant': ?variant,
              'emoji': ?emoji,
              'previous': ?previous,
            }),
          )
          .timeout(const Duration(seconds: 20));
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
