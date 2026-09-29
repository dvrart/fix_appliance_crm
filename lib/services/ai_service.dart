import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../core/api_keys.dart';
import '../models/warehouse_item.dart';

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

/// Что ИИ разобрал на фото запчасти или её этикетки.
class PartStickerScan {
  final String? partNumber;
  final String? name;
  final String? brand;
  final String? modelNumber;
  final String? barcode;
  final String? category;
  final String? purpose;
  final List<String> interchange;

  const PartStickerScan({
    this.partNumber,
    this.name,
    this.brand,
    this.modelNumber,
    this.barcode,
    this.category,
    this.purpose,
    this.interchange = const [],
  });

  bool get isEmpty =>
      (partNumber ?? '').isEmpty &&
      (name ?? '').isEmpty &&
      (modelNumber ?? '').isEmpty &&
      (barcode ?? '').isEmpty;

  /// Название для карточки: бренд + имя, если бренд ещё не в имени.
  String? get displayName {
    final n = name?.trim();
    if (n == null || n.isEmpty) return null;
    final b = brand?.trim();
    if (b == null || b.isEmpty) return n;
    if (n.toLowerCase().contains(b.toLowerCase())) return n;
    return '$b $n';
  }
}

/// Сервис для работы с Gemini AI
class AiService {
  static const _models = [
    'gemini-3.6-flash',
    'gemini-2.5-flash',
    'gemini-flash-lite-latest',
    'gemini-flash-latest',
  ];

  static GenerativeModel? _model;

  static GenerativeModel get model {
    _model ??= GenerativeModel(
      model: 'gemini-3.6-flash',
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

  static Future<String> generateText(String prompt) =>
      _generate(Content.text(prompt), timeout: const Duration(seconds: 22));

  /// Один запрос к Gemini с перебором моделей и повтором при перегрузке.
  /// [content] может содержать и текст, и картинку.
  static Future<String> _generate(
    Content content, {
    required Duration timeout,
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      throw Exception('Не настроен ключ Gemini');
    }
    Object? last;
    for (final name in _models) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final model = GenerativeModel(model: name, apiKey: kGeminiApiKey);
          final response =
              await model.generateContent([content]).timeout(timeout);
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
- Адрес, улицу, город и индекс оставляй как сказал клиент, по-английски. Не переводи на русский (King Street, не Кинг-стрит).
- Имя клиента оставляй по-английски, как сказано.
- problem_description — только поломка и модель, не весь разговор.

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

  /// К какой технике относится запчасть. Нужно, когда по названию не понять,
  /// а есть только артикул вроде W10130913. Возвращает одну из [categories]
  /// или null, если ИИ не уверен.
  static Future<String?> guessPartCategory({
    required String partNumber,
    required String name,
    required String model,
    required List<String> categories,
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return null;
    }
    if (partNumber.trim().isEmpty && name.trim().isEmpty) return null;

    final prompt =
        '''
You are an appliance parts counter specialist in Canada.

Part number: ${partNumber.isEmpty ? '(none)' : partNumber}
Part name: ${name.isEmpty ? '(none)' : name}
Fits model: ${model.isEmpty ? '(none)' : model}

Which appliance is this part for? Answer with exactly one line from this list,
copied character for character:
${categories.join('\n')}

Rules:
- Answer only if you know the part. A guess sends the wrong part to a job.
- A part used on several appliances, or one you do not recognise, is "unknown".
- No explanation, no quotes, just the one line or the word unknown.
''';

    try {
      final answer = (await generateText(prompt)).trim();
      final clean = answer.split('\n').first.trim();
      for (final category in categories) {
        if (clean.toLowerCase() == category.toLowerCase()) return category;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Разобрать фото запчасти / её этикетки / коробки: что за деталь, номер,
  /// для какой техники. Возвращает null, если ИИ не ответил или на фото
  /// ничего не разобрать — тогда зовём офлайн-OCR.
  static Future<PartStickerScan?> readPartSticker({
    required Uint8List imageBytes,
    required List<String> categories,
    String mime = 'image/jpeg',
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return null;
    }
    if (imageBytes.isEmpty) return null;

    final prompt =
        '''
You are an appliance parts counter specialist in Canada. The photo shows a
spare part for a household appliance and/or its label, sticker, bag or box.

Read everything printed and identify the part. Return ONLY JSON, no prose:
{
  "part_number": "the OEM part number as printed (e.g. W10130913, DC97-16350C, WR57X10032, 5304475102), or null",
  "name": "short English part name with brand, e.g. \\"Whirlpool Water Inlet Valve\\", or null",
  "brand": "manufacturer brand, or null",
  "model_number": "appliance model the part fits, if printed, or null",
  "barcode": "UPC/EAN digits under the barcode, if printed, or null",
  "category": "exactly one line from the list below, copied character for character, or null",
  "purpose": "one short sentence in Russian: what this part is and what it does, e.g. \\"Впускной клапан воды стиральной машины — подаёт воду в бак.\\"",
  "interchange": ["other part numbers printed as replaces / supersedes / substitutes / also fits"]
}

Category list:
${categories.join('\n')}

Rules:
- Copy numbers character for character. Never invent a part number: if it is
  not printed and you do not recognise the part for sure, use null.
- Part number is the manufacturer part number, not the UPC, not the appliance
  model, not a date or lot code.
- Category: pick one only when you are sure which appliance the part is for.
  A part used on several appliances is "${categories.contains('Универсальное') ? 'Универсальное' : 'null'}".
- If you can see the part itself, use its shape to help name it (pump, valve,
  belt, board, thermostat, heating element, door gasket, knob, etc).
- Unknown fields are null. Do not add fields.
''';

    try {
      final text = await _generate(
        Content.multi([TextPart(prompt), DataPart(mime, imageBytes)]),
        timeout: const Duration(seconds: 45),
      );
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final decoded = json.decode(text.substring(start, end + 1));
      if (decoded is! Map) return null;

      String? str(String key) {
        final raw = decoded[key];
        if (raw == null) return null;
        final value = raw.toString().trim();
        if (value.isEmpty || value.toLowerCase() == 'null') return null;
        return value;
      }

      final categoryRaw = str('category');
      String? category;
      if (categoryRaw != null) {
        for (final c in categories) {
          if (c.toLowerCase() == categoryRaw.toLowerCase()) category = c;
        }
      }

      final interchange = <String>[];
      final rawList = decoded['interchange'];
      if (rawList is List) {
        for (final row in rawList) {
          final clean = row.toString().trim().toUpperCase();
          if (clean.isEmpty || interchange.contains(clean)) continue;
          interchange.add(clean);
          if (interchange.length >= 8) break;
        }
      }

      final scan = PartStickerScan(
        partNumber: str('part_number')
            ?.toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9\-/]'), ''),
        name: str('name'),
        brand: str('brand'),
        modelNumber: str('model_number')
            ?.toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9\-/]'), ''),
        barcode: str('barcode')?.replaceAll(RegExp(r'[^0-9A-Z]'), ''),
        category: category,
        purpose: str('purpose'),
        interchange: interchange,
      );
      return scan.isEmpty ? null : scan;
    } catch (_) {
      return null;
    }
  }

  /// Выбрать из найденных в интернете снимков тот, что годится в карточку.
  ///
  /// Возвращает номер снимка (1..n) и короткое пояснение; 0 — все негодные.
  /// Узнать деталь «в лицо» по номеру модель не может, и когда её об этом
  /// просили, она честно отвечала 0 на каждый запрос. Совпадение номера даёт
  /// сам поиск, а у ИИ спрашиваем другое: где нормальное фото детали, а где
  /// схема, текст, логотип или целая машина.
  static Future<(int, String)> pickPartPhoto({
    required List<Uint8List> images,
    required String partNumber,
    required String name,
    String brand = '',
  }) async {
    if (images.isEmpty) return (0, '');
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return (0, '');
    }

    final prompt =
        '''
You pick photos for an appliance-parts shop inventory card.

All ${images.length} pictures below were found by a web search for this spare part:
part number ${partNumber.isEmpty ? '(unknown)' : partNumber}, name ${name.isEmpty ? '(unknown)' : name}, brand ${brand.isEmpty ? '(unknown)' : brand}.
The search already matched the number, so do NOT try to verify the number yourself.
Your only job is to throw out junk pictures and pick the best product photo.

Reject a picture if it is:
- a wiring diagram, schematic or exploded parts drawing;
- a page of text, a table, a screenshot or a web page;
- only a logo, a watermark or a brand banner;
- the whole appliance instead of the part;
- a person, or an installation scene where the part is not clear;
- a collage of many different parts;
- too blurry or too dark to see the part.

Among the rest pick the clearest single part, preferably on a plain background.
Answer 0 only if every picture must be rejected.

Return ONLY JSON, no prose:
{"best": <1-${images.length} or 0>, "why": "<до 4 слов по-русски: что на фото>"}
''';

    try {
      final parts = <Part>[TextPart(prompt)];
      for (var i = 0; i < images.length; i++) {
        parts.add(TextPart('Picture ${i + 1}:'));
        parts.add(DataPart('image/jpeg', images[i]));
      }
      final text = await _generate(
        Content.multi(parts),
        timeout: const Duration(seconds: 45),
      );
      final map = _jsonObject(text);
      if (map == null) return (0, '');
      final best = int.tryParse('${map['best']}') ?? 0;
      final why = '${map['why'] ?? ''}'.trim();
      if (best < 1 || best > images.length) return (0, why);
      return (best, why);
    } catch (_) {
      return (0, '');
    }
  }

  /// Другие артикулы той же детали: OEM supersession, WP-префикс, aftermarket.
  /// Пусто, если ИИ не уверен — лучше пустое поле, чем выдуманный номер.
  static Future<List<String>> guessInterchangeNumbers({
    required String partNumber,
    required String name,
    required String model,
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return const [];
    }
    final part = partNumber.trim().toUpperCase();
    if (part.length < 4) return const [];

    final prompt =
        '''
You are an appliance parts counter specialist in Canada.

Part number: $part
Part name: ${name.isEmpty ? '(none)' : name}
Fits model: ${model.isEmpty ? '(none)' : model}

List genuine interchange / supersession numbers for THIS same physical part:
OEM supersessions, the same OEM number with a WP / W / PS / AP prefix, or a
known aftermarket equivalent sold as the same part.

Hard rules:
- Only numbers you actually know. Guessing sends the wrong part to a job.
- Do not repeat $part itself.
- At most 8 numbers.
- If you are not sure, return [].

Return ONLY JSON, no prose:
["W10311524","WPW10311524"]
''';

    try {
      final text = await generateText(prompt);
      var jsonStr = text.trim();
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr
            .replaceAll(RegExp(r'^```\w*\n?'), '')
            .replaceAll('```', '');
      }
      final start = jsonStr.indexOf('[');
      final end = jsonStr.lastIndexOf(']');
      if (start < 0 || end <= start) return const [];
      final decoded = json.decode(jsonStr.substring(start, end + 1));
      if (decoded is! List) return const [];
      final skip = WarehouseItem.normalizePart(part);
      final out = <String>[];
      for (final row in decoded) {
        final clean = row.toString().trim().toUpperCase();
        if (clean.isEmpty) continue;
        if (WarehouseItem.normalizePart(clean) == skip) continue;
        if (out.contains(clean)) continue;
        out.add(clean);
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Какие детали со склада заменяют номер [wantedPart].
  ///
  /// [stock] — то, что реально лежит на складе: `id`, `partNumber`, `name`,
  /// `modelNumber`. Возвращаем id тех, что подходят, и короткую причину.
  /// Пусто — если ИИ не уверен: лучше ничего, чем неверная деталь в счёте.
  static Future<Map<String, String>> findInterchangeableParts({
    required String wantedPart,
    required List<Map<String, String>> stock,
  }) async {
    if (kGeminiApiKey == 'YOUR_GEMINI_API_KEY' || kGeminiApiKey.isEmpty) {
      return {};
    }
    if (wantedPart.trim().isEmpty || stock.isEmpty) return {};

    final lines = stock
        .map(
          (item) =>
              '${item['id']} | ${item['partNumber']} | ${item['name']}'
              '${(item['modelNumber'] ?? '').isEmpty ? '' : ' | fits ${item['modelNumber']}'}',
        )
        .join('\n');

    final prompt =
        '''
You are an appliance parts counter specialist in Canada.

The technician needs part number: $wantedPart
It is NOT in stock. Below is what IS in stock, one per line:
id | part number | name | fits model

$lines

Which of these in-stock parts is a genuine interchange / supersession for
$wantedPart — the same physical part sold under another number (OEM
supersession, a different brand of the same OEM part, or a known aftermarket
equivalent)?

Hard rules:
- Only answer if you actually know the interchange. Guessing costs a wasted trip.
- A part that merely looks similar or fits the same appliance is NOT a match.
- Return at most 3.
- If you are not sure about any of them, return an empty array.

Return ONLY JSON, no prose:
[{"id": "<id from the list>", "why": "<max 6 words, English>"}]
''';

    try {
      final text = await generateText(prompt);
      var jsonStr = text.trim();
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr
            .replaceAll(RegExp(r'^```\w*\n?'), '')
            .replaceAll('```', '');
      }
      final start = jsonStr.indexOf('[');
      final end = jsonStr.lastIndexOf(']');
      if (start < 0 || end <= start) return {};
      final decoded = json.decode(jsonStr.substring(start, end + 1));
      if (decoded is! List) return {};

      final known = {for (final item in stock) item['id']};
      final out = <String, String>{};
      for (final row in decoded) {
        if (row is! Map) continue;
        final id = (row['id'] ?? '').toString();
        if (id.isEmpty || !known.contains(id)) continue;
        out[id] = (row['why'] ?? '').toString().trim();
        if (out.length >= 3) break;
      }
      return out;
    } catch (_) {
      return {};
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
}
