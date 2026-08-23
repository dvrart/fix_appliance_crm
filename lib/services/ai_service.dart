import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../core/api_keys.dart';

/// Результат извлечения данных из разговора
class ExtractedJobData {
  final String? clientName;
  final String? clientPhone;
  final String? clientEmail;
  final String? address;
  final String? city;
  final String? postalCode;
  final String? applianceType;
  final String? brand;
  final String? model;
  final String? problemDescription;
  final String? scheduledDate;
  final String? scheduledTime;
  final String? contactOnSiteName;
  final String? contactOnSitePhone;
  final bool hasJobSite;
  final String? notes;

  ExtractedJobData({
    this.clientName,
    this.clientPhone,
    this.clientEmail,
    this.address,
    this.city,
    this.postalCode,
    this.applianceType,
    this.brand,
    this.model,
    this.problemDescription,
    this.scheduledDate,
    this.scheduledTime,
    this.contactOnSiteName,
    this.contactOnSitePhone,
    this.hasJobSite = false,
    this.notes,
  });

  factory ExtractedJobData.fromJson(Map<String, dynamic> json) {
    return ExtractedJobData(
      clientName: _clean(json['client_name']),
      clientPhone: _clean(json['client_phone']),
      clientEmail: _clean(json['client_email']),
      address: _clean(json['address']),
      city: _clean(json['city']),
      postalCode: _clean(json['postal_code']),
      applianceType: _clean(json['appliance_type']),
      brand: _clean(json['brand']),
      model: _clean(json['model']),
      problemDescription: _clean(json['problem_description']),
      scheduledDate: _clean(json['scheduled_date']),
      scheduledTime: _clean(json['scheduled_time']),
      contactOnSiteName: _clean(json['contact_on_site_name']),
      contactOnSitePhone: _clean(json['contact_on_site_phone']),
      hasJobSite: json['has_job_site'] == true,
      notes: _clean(json['notes']),
    );
  }

  static String? _clean(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    return text;
  }

  Map<String, dynamic> toJson() {
    return {
      'client_name': clientName,
      'client_phone': clientPhone,
      'client_email': clientEmail,
      'address': address,
      'city': city,
      'postal_code': postalCode,
      'appliance_type': applianceType,
      'brand': brand,
      'model': model,
      'problem_description': problemDescription,
      'scheduled_date': scheduledDate,
      'scheduled_time': scheduledTime,
      'contact_on_site_name': contactOnSiteName,
      'contact_on_site_phone': contactOnSitePhone,
      'has_job_site': hasJobSite,
      'notes': notes,
    };
  }

  bool get isEmpty =>
      clientName == null &&
      clientPhone == null &&
      clientEmail == null &&
      address == null &&
      applianceType == null;
}

/// Сервис для работы с Gemini AI
class AiService {
  static const _models = [
    'gemini-2.5-flash',
    'gemini-flash-lite-latest',
    'gemini-flash-latest',
    'gemini-2.0-flash',
  ];

  static GenerativeModel? _model;

  static GenerativeModel get model {
    _model ??= GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: kGeminiApiKey,
    );
    return _model!;
  }

  static bool isBusyError(Object error) {
    final text = error.toString();
    return text.contains('503') ||
        text.contains('UNAVAILABLE') ||
        text.contains('high demand') ||
        text.contains('overloaded') ||
        text.contains('resource exhausted') ||
        text.contains('429');
  }

  static String friendlyError(Object error) {
    if (isBusyError(error)) {
      return 'ИИ сейчас перегружен. Напишите правку сами по тексту звонка.';
    }
    return 'ИИ не ответил. Напишите правку сами по тексту звонка.';
  }

  static Future<String> generateText(String prompt) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      throw Exception('Не настроен ключ Gemini');
    }
    Object? last;
    for (final name in _models) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final model = GenerativeModel(model: name, apiKey: kGeminiApiKey);
          final response = await model
              .generateContent([Content.text(prompt)])
              .timeout(const Duration(seconds: 22));
          final out = (response.text ?? '').trim();
          if (out.isNotEmpty) return out;
        } catch (error) {
          last = error;
          if (isBusyError(error)) {
            await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
      }
    }
    throw last ?? Exception('empty');
  }

  /// Разобрать речь, пока микрофон остаётся включённым.
  static Future<String> transcribeAudio(Uint8List wavBytes) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return '';
    }
    Object? last;
    for (final name in _models) {
      try {
        final model = GenerativeModel(model: name, apiKey: kGeminiApiKey);
        final response = await model
            .generateContent([
              Content.multi([
                TextPart(
                  'Транскрибируй речь мастера сервиса техники. '
                  'Русский или английский. Верни только текст, без кавычек.',
                ),
                DataPart('audio/wav', wavBytes),
              ]),
            ])
            .timeout(const Duration(seconds: 25));
        final out = (response.text ?? '').trim();
        if (out.isNotEmpty) return out;
      } catch (error) {
        last = error;
      }
    }
    if (last != null) throw last;
    return '';
  }

  /// Извлечь данные из текста разговора
  static Future<ExtractedJobData> extractJobData(String conversationText) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      throw Exception('Gemini API Key не настроен. Замените YOUR_GEMINI_API_KEY в lib/core/api_keys.dart');
    }

    final prompt = '''
Ты — ассистент для сервиса по ремонту бытовой техники в Канаде.
Извлеки информацию из описания разговора с клиентом и верни JSON.

Правила:
- Телефон форматируй как 10 цифр без пробелов (например: 4165551234)
- Дату форматируй как YYYY-MM-DD
- Время форматируй как HH:MM (24-часовой формат)
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Если клиент — владелец, а техника находится у арендатора, установи has_job_site: true
- Если что-то не упомянуто, поставь null

Формат JSON:
{
  "client_name": "Имя клиента (владельца)",
  "client_phone": "Телефон клиента",
  "address": "Улица и номер дома",
  "city": "Город",
  "postal_code": "Почтовый индекс",
  "appliance_type": "Тип техники",
  "brand": "Бренд",
  "model": "Модель",
  "problem_description": "Описание проблемы",
  "scheduled_date": "Дата визита",
  "scheduled_time": "Время визита",
  "contact_on_site_name": "Имя контакта на месте (арендатор)",
  "contact_on_site_phone": "Телефон контакта на месте",
  "has_job_site": false,
  "notes": "Дополнительные заметки"
}

Текст разговора:
$conversationText

Верни ТОЛЬКО JSON, без markdown и пояснений.
''';

    try {
      final response = await model.generateContent([Content.text(prompt)]);
      final text = response.text ?? '';

      // Извлекаем JSON из ответа
      String jsonStr = text.trim();
      
      // Убираем markdown обёртку если есть
      if (jsonStr.startsWith('```json')) {
        jsonStr = jsonStr.substring(7);
      } else if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.substring(3);
      }
      if (jsonStr.endsWith('```')) {
        jsonStr = jsonStr.substring(0, jsonStr.length - 3);
      }
      jsonStr = jsonStr.trim();

      final Map<String, dynamic> parsed = json.decode(jsonStr);
      return ExtractedJobData.fromJson(parsed);
    } catch (e) {
      throw Exception('Ошибка обработки ИИ: $e');
    }
  }

  /// Подсказка по запчастям на основе описания проблемы
  static Future<List<String>> suggestParts({
    required String applianceType,
    required String brand,
    required String problemDescription,
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return [];
    }

    final prompt = '''
Ты — опытный мастер по ремонту бытовой техники.
На основе описания проблемы, предложи список запчастей, которые могут понадобиться.

Техника: $applianceType $brand
Проблема: $problemDescription

Верни JSON массив с названиями запчастей на русском (максимум 5):
["Запчасть 1", "Запчасть 2"]

ТОЛЬКО JSON, без пояснений.
''';

    try {
      final response = await model.generateContent([Content.text(prompt)]);
      final text = response.text ?? '[]';

      String jsonStr = text.trim();
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll('```', '');
      }

      final List<dynamic> parsed = json.decode(jsonStr.trim());
      return parsed.map((e) => e.toString()).toList();
    } catch (e) {
      return [];
    }
  }

  static Map<String, dynamic>? _jsonObject(String text) {
    var jsonStr = text.trim();
    if (jsonStr.startsWith('```json')) jsonStr = jsonStr.substring(7);
    if (jsonStr.startsWith('```')) {
      jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll('```', '');
    }
    jsonStr = jsonStr.trim();
    final start = jsonStr.indexOf('{');
    final end = jsonStr.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final decoded = json.decode(jsonStr.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Разбор звонка секретаря: за что зацепился, что случилось, как исправить.
  static Future<Map<String, String>> reviewSecretaryCall({
    required String conversation,
    Map<String, dynamic>? extracted,
    String ownerNote = '',
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      throw Exception('Не настроен ключ Gemini');
    }
    final prompt = '''
Ты пишешь полный разбор ошибки телефонного секретаря для хозяина сервиса по ремонту техники в Канаде.
Пиши по-русски (кроме ruleEn). Конкретно, по этому звонку. Не выдумывай адреса и время.

1) whatHappenedRu — что произошло, 4–8 предложений.
2) clungToRu — за что зацепился секретарь (адрес из карточки, правило, callback, арендатор, раннее прощание, тишина, смешал два адреса и т.д.).
3) problemRu — в чём ошибка. Пусто только если звонок нормальный.
4) okRu — что сделал правильно.
5) suggestedFixRu — как действовать в такой ситуации в следующий раз.
6) ruleEn — одно повелительное предложение на английском для живого звонка. Пусто, если менять нечего.
7) titleRu — короткий заголовок.
8) evidence — короткая цитата.

${ownerNote.trim().isEmpty ? '' : 'Замечание хозяина: $ownerNote'}

Извлечённые поля: ${json.encode(extracted ?? {})}

Разговор:
$conversation

Верни ТОЛЬКО JSON:
{"titleRu":"","whatHappenedRu":"","clungToRu":"","problemRu":"","okRu":"","suggestedFixRu":"","ruleEn":"","severity":"issue","evidence":""}
''';
    final parsed = _jsonObject(await generateText(prompt));
    if (parsed == null) {
      throw Exception('Не удалось разобрать ответ ИИ');
    }
    String take(String key) => (parsed[key] ?? '').toString().trim();
    return {
      'titleRu': take('titleRu'),
      'whatHappenedRu': take('whatHappenedRu'),
      'clungToRu': take('clungToRu'),
      'problemRu': take('problemRu'),
      'okRu': take('okRu'),
      'suggestedFixRu': take('suggestedFixRu'),
      'ruleEn': take('ruleEn'),
      'severity': take('severity').isEmpty ? 'issue' : take('severity'),
      'evidence': take('evidence'),
    };
  }

  /// Хозяин написал по-русски, как вести себя дальше — одна фраза в скрипт.
  static Future<String> englishPhoneRule(String russian) async {
    final text = russian.trim();
    if (text.isEmpty) return '';
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return text;
    }
    try {
      final out = await generateText(
        'Turn this shop-owner instruction into ONE English imperative sentence '
        'for a live phone receptionist at an appliance-repair shop. No quotes, no extra lines.\n\n$text',
      );
      return out.replaceAll(RegExp(r'^"|"$'), '');
    } catch (_) {
      return text;
    }
  }

  /// Чат с хозяином: переписать, как секретарю вести входящие звонки.
  static Future<Map<String, String>> coachSecretaryTurn({
    required String ownerText,
    required String extraRules,
    required List<String> learnedRules,
    String pendingProblem = '',
  }) async {
    final prompt = '''
You help the shop owner rewrite how the live phone secretary answers incoming repair calls in Ontario.
The owner writes in Russian. You reply in Russian, short, as that secretary: confirm what you will do on the next call.
Do not talk about the in-app assistant. This is only the phone secretary.

Current extra rules:
${extraRules.trim().isEmpty ? '(none)' : extraRules.trim()}

Already learned:
${learnedRules.isEmpty ? '(none)' : learnedRules.map((line) => '- $line').join('\n')}

Pending mistake from a recent call (if any):
${pendingProblem.trim().isEmpty ? '(none)' : pendingProblem.trim()}

Owner:
$ownerText

Return JSON only:
{
  "replyRu": "your short Russian reply",
  "ruleEn": "one English imperative for the live call, or empty if they only asked a question",
  "rewriteExtraRules": "full replacement of extra rules if they asked to rewrite the script, else empty"
}
''';
    final parsed = _jsonObject(await generateText(prompt)) ?? const {};
    String take(String key) => (parsed[key] ?? '').toString().trim();
    var reply = take('replyRu');
    if (reply.isEmpty) {
      reply = 'Хорошо. Напишите ещё, как вести звонок — запомню.';
    }
    return {
      'replyRu': reply,
      'ruleEn': take('ruleEn'),
      'rewriteExtraRules': take('rewriteExtraRules'),
    };
  }
}
