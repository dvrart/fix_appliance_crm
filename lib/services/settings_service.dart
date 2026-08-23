import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';
import '../models/document_settings.dart';
import '../models/job.dart';
import 'firestore_service.dart';
import '../core/l10n/app_locale.dart';
import 'status_service.dart';

/// Сервис для работы с настройками
class SettingsService {
  /// Загрузить конфигурацию
  static Future<Map<String, dynamic>> loadConfig() async {
    try {
      final doc = await FirestoreService.configRef.get();
      if (doc.exists && doc.data() != null) {
        return doc.data() as Map<String, dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return {};
  }

  /// Сохранить настройку
  static Future<void> updateConfig(String key, dynamic value) async {
    await FirestoreService.configRef.set(
      {key: value},
      SetOptions(merge: true),
    );
  }

  static const String defaultOnWaySms =
      'Здравствуйте, это мастер. Буду у вас через 30 минут.';
  static const String defaultPartOrderedSms =
      'Запчасть для вашей техники заказана. Ожидаем доставку 3-5 дней.';
  static const String defaultJobDoneSms =
      'Ремонт завершен! Спасибо, что выбрали нас. Пожалуйста, оставьте отзыв. {review}';
  static const String defaultBookingConfirmSms =
      'Здравствуйте, {name}! Визит {date} в {time}. Адрес: {address}. Ответьте 1 — подтверждаю, 2 — перенос.';
  static const String defaultDayBeforeSms =
      'Напоминание: завтра {date} в {time}. Ответьте 1 — подтверждаю, 2 — перенос.';

  static Map<String, String> defaultSmsTemplates() => {
        'on_way': defaultOnWaySms,
        'part_ordered': defaultPartOrderedSms,
        'job_done': defaultJobDoneSms,
        'booking_confirm': defaultBookingConfirmSms,
        'day_before': defaultDayBeforeSms,
      };

  /// Загрузить SMS-шаблоны
  static Future<Map<String, String>> loadSmsTemplates() async {
    final defaults = defaultSmsTemplates();
    try {
      final doc = await FirestoreService.smsTemplatesRef.get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          for (final key in defaults.keys)
            key: (data[key] ?? defaults[key]!).toString(),
        };
      }
    } catch (e) {
      // ignore
    }
    return defaults;
  }

  /// Сохранить SMS-шаблоны
  static Future<void> saveSmsTemplates(Map<String, String> templates) async {
    await FirestoreService.smsTemplatesRef.set(
      templates,
      SetOptions(merge: true),
    );
  }

  static bool readBookingSmsEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'bookingSmsEnabled');
  }

  static bool readReminderSmsEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'reminderSmsEnabled');
  }

  static bool readAutoReviewSmsEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'autoReviewSmsEnabled');
  }

  static String readGoogleReviewUrl(Map<String, dynamic> config) {
    return (config['googleReviewUrl'] ?? '').toString().trim();
  }

  static double readPartsMarkupPercent(Map<String, dynamic> config) {
    final value = config['partsMarkupPercent'];
    if (value is num) return value.toDouble().clamp(0, 300);
    return 0;
  }

  static const String taxHst = 'hst';
  static const String taxGst = 'gst';
  static const String taxNone = 'none';

  /// Проверить настройку HST
  static Future<bool> isHstEnabled() async {
    final config = await loadConfig();
    return readDefaultTax(config) != taxNone;
  }

  static String readDefaultTax(Map<String, dynamic> config) {
    final raw = config['defaultTax'] as String?;
    if (raw == taxGst || raw == taxNone || raw == taxHst) return raw!;
    if (config['applyHST'] == false) return taxNone;
    return taxHst;
  }

  static double readDefaultTaxRate(Map<String, dynamic> config) {
    switch (readDefaultTax(config)) {
      case taxGst:
        return 0.05;
      case taxNone:
        return 0.0;
      default:
        return 0.13;
    }
  }

  static Future<void> setDefaultTax(String tax) async {
    final value = tax == taxGst || tax == taxNone ? tax : taxHst;
    await updateConfig('defaultTax', value);
    await updateConfig('applyHST', value != taxNone);
  }

  /// Получить первый день недели (для календаря)
  static Future<int> getFirstDayOfWeek() async {
    final config = await loadConfig();
    return config['firstDayOfWeek'] ?? 1;
  }

  /// Начало рабочего дня: 09:00
  static const int defaultWorkStartMinutes = 9 * 60;

  /// Конец рабочего дня: 19:00
  static const int defaultWorkEndMinutes = 19 * 60;

  static const int defaultJobDurationMinutes = 60;
  static const int defaultTravelBufferMinutes = 20;

  static int _readMinutes(Map<String, dynamic> config, String key, int fallback) {
    final value = config[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static int readWorkStartMinutes(Map<String, dynamic> config) {
    return _readMinutes(config, 'workStartMinutes', defaultWorkStartMinutes)
        .clamp(0, 24 * 60);
  }

  static int readWorkEndMinutes(Map<String, dynamic> config) {
    return _readMinutes(config, 'workEndMinutes', defaultWorkEndMinutes)
        .clamp(0, 24 * 60);
  }

  static int readJobDurationMinutes(Map<String, dynamic> config) {
    return _readMinutes(config, 'defaultJobDurationMinutes', defaultJobDurationMinutes)
        .clamp(15, 8 * 60);
  }

  static int readTravelBufferMinutes(Map<String, dynamic> config) {
    return _readMinutes(config, 'travelBufferMinutes', defaultTravelBufferMinutes)
        .clamp(0, 3 * 60);
  }

  static String formatWorkMinutes(int minutes) {
    final clamped = minutes.clamp(0, 24 * 60);
    if (clamped >= 24 * 60) return '24:00';
    final hour = clamped ~/ 60;
    final minute = clamped % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  static String workHoursLabel(int startMinutes, int endMinutes) {
    return '${formatWorkMinutes(startMinutes)} – ${formatWorkMinutes(endMinutes)}';
  }

  static const String timeSourceManual = 'manual';
  static const String timeSourceGeolocation = 'geolocation';

  static String readTimeSource(Map<String, dynamic> config) {
    return config['timeSource'] == timeSourceGeolocation
        ? timeSourceGeolocation
        : timeSourceManual;
  }

  static String timeSourceLabel(String source, {String? zoneName}) {
    if (source == timeSourceGeolocation) {
      if (zoneName != null && zoneName.isNotEmpty) {
        return '${'По геолокации'.tr} · $zoneName';
      }
      return 'По геолокации'.tr;
    }
    return 'Вручную · время телефона'.tr;
  }

  static DocumentSettings? _documentSettingsCache;

  static Future<DocumentSettings> loadDocumentSettings({bool force = false}) async {
    if (!force && _documentSettingsCache != null) return _documentSettingsCache!;
    try {
      final doc = await FirestoreService.documentSettingsRef.get();
      if (doc.exists) {
        _documentSettingsCache =
            DocumentSettings.fromMap(doc.data() as Map<String, dynamic>?);
        return _documentSettingsCache!;
      }
    } catch (_) {
      // defaults
    }
    _documentSettingsCache = DocumentSettings.defaults;
    return _documentSettingsCache!;
  }

  static Future<void> saveDocumentSettings(DocumentSettings settings) async {
    await FirestoreService.documentSettingsRef.set(settings.toMap());
    _documentSettingsCache = settings;
  }

  static Future<void> updateCompanyName(String name) async {
    final current = await loadDocumentSettings();
    final trimmed = name.trim().isEmpty
        ? DocumentSettings.defaults.companyName
        : name.trim();
    await saveDocumentSettings(current.copyWith(companyName: trimmed));
  }

  static Future<void> updateSmsHeader(String header) async {
    final current = await loadDocumentSettings();
    await saveDocumentSettings(
      current.copyWith(smsHeader: DocumentSettings.sanitizeSmsHeader(header.trim(), companyName: current.companyName)),
    );
  }

  static Future<void> updateCompanyPhone(String phone) async {
    final current = await loadDocumentSettings();
    await saveDocumentSettings(current.copyWith(companyPhone: phone.trim()));
  }

  static Future<void> updateCompanyEmail(String email) async {
    final current = await loadDocumentSettings();
    await saveDocumentSettings(current.copyWith(companyEmail: email.trim()));
  }

  static Future<void> updateCompanyAddress(String address) async {
    final current = await loadDocumentSettings();
    await saveDocumentSettings(current.copyWith(companyAddress: address.trim()));
  }

  static Future<void> updateHstNumber(String number) async {
    final current = await loadDocumentSettings();
    await saveDocumentSettings(current.copyWith(hstNumber: number.trim()));
  }

  static Stream<DocumentSettings> watchDocumentSettings() {
    return FirestoreService.documentSettingsRef.snapshots().map((doc) {
      final settings = DocumentSettings.fromMap(
        doc.data() as Map<String, dynamic>?,
      );
      _documentSettingsCache = settings;
      return settings;
    });
  }

  static Stream<Map<String, dynamic>> watchConfig() {
    return FirestoreService.configRef.snapshots().map((doc) {
      return (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
    });
  }

  static const String listAllFilter = 'Все';
  static const String listUnpaidFilter = 'Неоплачено';
  static const List<String> defaultListQuickFilters = [
    listUnpaidFilter,
    'Вызов',
    'Завершено',
  ];

  static List<String> readListQuickFilters(Map<String, dynamic> config) {
    final raw = config['listQuickFilters'];
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final id = item.toString().trim();
        if (id.isEmpty || id == listAllFilter) continue;
        if (!ids.contains(id)) ids.add(id);
        if (ids.length == 3) break;
      }
    }
    for (final fallback in defaultListQuickFilters) {
      if (ids.length >= 3) break;
      if (!ids.contains(fallback)) ids.add(fallback);
    }
    return ids.take(3).toList();
  }

  static String listFilterLabel(String id) {
    if (id == listAllFilter) return 'Показать все';
    if (id == listUnpaidFilter) return 'Неоплаченные';
    if (id == 'Завершено') {
      final label = StatusService.labelOf(id);
      return label == 'Завершено' ? 'Сделано' : label;
    }
    return StatusService.labelOf(id);
  }

  static List<({String id, String label})> buildJobListFilters(
    List<JobStatusDef> defs,
    List<String> quick,
  ) {
    final known = {for (final def in defs) def.id};
    final filters = <({String id, String label})>[];
    final used = <String>{};

    void add(String id, [String? label]) {
      if (id.isEmpty || !used.add(id)) return;
      filters.add((id: id, label: label ?? listFilterLabel(id)));
    }

    if (known.contains(JobStatuses.call) || defs.isEmpty) {
      add(JobStatuses.call);
    }
    for (final id in quick) {
      if (id == listAllFilter || id == JobStatuses.call) continue;
      if (id != listUnpaidFilter && !known.contains(id)) continue;
      add(id);
    }
    for (final def in defs) {
      if (def.id == JobStatuses.call) continue;
      add(def.id);
    }
    add(listAllFilter);
    return filters;
  }

  static bool jobMatchesListFilter(Job job, String filter) {
    if (filter == listAllFilter) return true;
    if (filter == listUnpaidFilter) return job.isUnpaid;
    return job.status == filter;
  }

  static bool boolFlag(
    Map<String, dynamic> config,
    String key, {
    bool defaultValue = true,
  }) {
    final value = config[key];
    if (value is bool) return value;
    return defaultValue;
  }

  static bool menuFlag(Map<String, dynamic> config, String key) {
    return boolFlag(config, key);
  }

  static const String defaultAssistantWakeWord = 'фикс';
  static const String defaultAssistantWakeAliases = 'fix';

  static const int defaultAiAnswerTimeoutSeconds = 20;
  static const int minAiAnswerTimeoutSeconds = 8;
  static const int maxAiAnswerTimeoutSeconds = 60;

  static bool readAssistantEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'assistantEnabled');
  }

  static bool readAiAnswerEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'aiAnswerEnabled');
  }

  static int readAiAnswerTimeoutSeconds(Map<String, dynamic> config) {
    final value = config['aiAnswerTimeoutSeconds'];
    final seconds = value is num
        ? value.round()
        : defaultAiAnswerTimeoutSeconds;
    return seconds.clamp(
      minAiAnswerTimeoutSeconds,
      maxAiAnswerTimeoutSeconds,
    );
  }

  static bool readAssistantWakeEnabled(Map<String, dynamic> config) {
    return boolFlag(config, 'assistantWakeEnabled');
  }

  static String readAssistantWakeWord(Map<String, dynamic> config) {
    final value = (config['assistantWakeWord'] as String?)?.trim();
    if (value == null || value.isEmpty) return defaultAssistantWakeWord;
    return value;
  }

  static String readAssistantWakeAliasesRaw(Map<String, dynamic> config) {
    final value = config['assistantWakeAliases'];
    if (value is String) return value;
    return defaultAssistantWakeAliases;
  }

  static List<String> readAssistantWakeAliases(Map<String, dynamic> config) {
    return readAssistantWakeAliasesRaw(config)
        .split(RegExp(r'[,;\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static DocumentReference get gmailSettingsRef =>
      FirestoreService.settingsRef.doc('gmail');

  static Future<Map<String, dynamic>> loadGmailSettings() async {
    try {
      final doc = await gmailSettingsRef.get();
      return (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> saveGmailSettings({
    required String user,
    String? appPassword,
  }) async {
    final data = <String, dynamic>{
      'user': user.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (appPassword != null && appPassword.trim().isNotEmpty) {
      data['appPassword'] = appPassword.trim();
    }
    await gmailSettingsRef.set(data, SetOptions(merge: true));
  }

  static const String defaultAiVoiceGreeting =
      "Hi, you've reached {company}. How can I help?";

  static const String defaultAiVoiceInstructions =
      'Тон: дружелюбный и профессиональный.\n'
      '\n'
      'Обязательно узнать:\n'
      '— полное имя;\n'
      '— адрес (улица и город);\n'
      '— удобный день и время, когда может приехать мастер;\n'
      '— что сломалось и как проявляется поломка;\n'
      '— где стоит техника, если это важно;\n'
      '— может ли клиент прислать модель SMS-кой (фото шильдика) на этот же номер.\n'
      '\n'
      'Не обещать цену и точное время приезда. Мастер перезвонит подтвердить.\n'
      '\n'
      'Зона: Brant (Brantford, Paris, Scotland), Norfolk (Tillsonburg, Delhi, Port Dover, Norwich) и резервация у Tillsonburg. Если адрес вне зоны — вежливо сказать, что туда не выезжаем, заявку не создавать.\n'
      '\n'
      'Если клиент злой: спокойно сказать, что в течение 30 минут с ним свяжется сотрудник компании, разговор закончить. Заявку всё равно создать из того, что уже узнали.';

  static Future<Map<String, String>> loadAiVoiceSettings() async {
    final profile = await loadAiVoiceProfile();
    return {
      'greeting': profile.greeting,
      'instructions': profile.instructions,
    };
  }

  static Future<AiVoiceProfile> loadAiVoiceProfile() async {
    final config = await loadConfig();
    Map<String, dynamic> voice = <String, dynamic>{};
    try {
      final doc = await FirestoreService.aiVoiceRef.get();
      voice = (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
    } catch (_) {}
    return AiVoiceProfile.fromMaps(config: config, voice: voice);
  }

  static Future<void> saveAiVoiceSettings({
    required String greeting,
    required String instructions,
  }) async {
    await FirestoreService.aiVoiceRef.set({
      'greeting': greeting.trim(),
      'instructions': instructions.trim(),
      'rulesVersion': 3,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> saveAiVoiceProfile(AiVoiceProfile profile) async {
    final timeout = profile.timeoutSeconds.clamp(
      minAiAnswerTimeoutSeconds,
      maxAiAnswerTimeoutSeconds,
    );
    await updateConfig('aiAnswerEnabled', profile.enabled);
    await updateConfig('aiAnswerTimeoutSeconds', timeout);
    await FirestoreService.aiVoiceRef.set({
      ...profile.toFirestore(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Пишет правила диспетчера в Firestore, если их ещё нет или это старая версия.
  static Future<void> ensureAiVoiceSettings() async {
    try {
      final doc = await FirestoreService.aiVoiceRef.get();
      final data = (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
      if (data['rulesVersion'] == 3) return;
      final greeting = (data['greeting'] ?? '').toString().trim();
      final instructions = (data['instructions'] ?? '').toString().trim();
      final staleGreeting = greeting.isEmpty ||
          greeting.contains("technician's with a customer") ||
          greeting.contains('I can take your details');
      await saveAiVoiceSettings(
        greeting: staleGreeting ? defaultAiVoiceGreeting : greeting,
        instructions:
            instructions.isEmpty ? defaultAiVoiceInstructions : instructions,
      );
    } catch (_) {}
  }

  static Future<void> updateConfigMap(Map<String, dynamic> values) async {
    await FirestoreService.configRef.set(values, SetOptions(merge: true));
  }

  static String readEmailIntakeTitle(Map<String, dynamic> config) {
    return (config['emailIntakeTitle'] ?? '').toString();
  }

  static List<String> readWatchedEmailSenders(Map<String, dynamic> config) {
    final raw = config['watchedEmailSenders'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item.toString().trim().contains('@')) item.toString().trim().toLowerCase(),
    ];
  }

  static const List<String> reminderOffsetKeys = ['48h', '24h', 'morning', '2h'];

  static List<String> readReminderOffsets(Map<String, dynamic> config) {
    final raw = config['reminderOffsets'];
    if (raw is List && raw.isNotEmpty) {
      return [for (final item in raw) item.toString()];
    }
    return const ['24h'];
  }

  static int readMorningBriefingHour(Map<String, dynamic> config) {
    final value = config['morningBriefingHour'];
    return (value is num ? value.round() : 7).clamp(5, 11);
  }

  static int readEveningBriefingHour(Map<String, dynamic> config) {
    final value = config['eveningBriefingHour'];
    return (value is num ? value.round() : 19).clamp(16, 23);
  }

  static int readReminderMorningHour(Map<String, dynamic> config) {
    final value = config['reminderMorningHour'];
    return (value is num ? value.round() : 8).clamp(6, 11);
  }

  static int readOnTheWayMeters(Map<String, dynamic> config) {
    final value = config['onTheWayMeters'];
    return (value is num ? value.round() : 2000).clamp(200, 20000);
  }

  static String readOnTheWayText(Map<String, dynamic> config) {
    return (config['onTheWayText'] ?? '').toString();
  }
}

/// Критерии телефонного секретаря (Twilio), не ассистента «Фикс» в приложении.
class AiVoiceProfile {
  const AiVoiceProfile({
    required this.enabled,
    required this.timeoutSeconds,
    required this.greeting,
    required this.collectName,
    required this.collectAddress,
    required this.collectWhen,
    required this.collectAppliance,
    required this.collectLocation,
    required this.collectPhoto,
    required this.noPrice,
    required this.serviceArea,
    required this.angryCallbackMinutes,
    required this.extraRules,
    required this.instructions,
  });

  final bool enabled;
  final int timeoutSeconds;
  final String greeting;
  final bool collectName;
  final bool collectAddress;
  final bool collectWhen;
  final bool collectAppliance;
  final bool collectLocation;
  final bool collectPhoto;
  final bool noPrice;
  final String serviceArea;
  final int angryCallbackMinutes;
  final String extraRules;
  final String instructions;

  static const String defaultServiceArea =
      'Brant (Brantford, Paris, Scotland), Norfolk (Tillsonburg, Delhi, Port Dover, Norwich) и резервация у Tillsonburg';

  static const int defaultAngryCallbackMinutes = 30;

  factory AiVoiceProfile.fromMaps({
    required Map<String, dynamic> config,
    required Map<String, dynamic> voice,
  }) {
    final greeting = (voice['greeting'] ?? '').toString().trim();
    final instructions = (voice['instructions'] ?? '').toString().trim();
    final structured = voice['criteriaVersion'] == 1 ||
        voice.containsKey('collectName');
    final extra = structured
        ? (voice['extraRules'] ?? '').toString()
        : (instructions.isNotEmpty &&
                instructions != SettingsService.defaultAiVoiceInstructions
            ? instructions
            : '');
    final area = (voice['serviceArea'] ?? '').toString().trim();
    final angry = voice['angryCallbackMinutes'];
    return AiVoiceProfile(
      enabled: SettingsService.readAiAnswerEnabled(config),
      timeoutSeconds: SettingsService.readAiAnswerTimeoutSeconds(config),
      greeting: greeting.isEmpty
          ? SettingsService.defaultAiVoiceGreeting
          : greeting,
      collectName: _flag(voice, 'collectName'),
      collectAddress: _flag(voice, 'collectAddress'),
      collectWhen: _flag(voice, 'collectWhen'),
      collectAppliance: _flag(voice, 'collectAppliance'),
      collectLocation: _flag(voice, 'collectLocation'),
      collectPhoto: _flag(voice, 'collectPhoto'),
      noPrice: _flag(voice, 'noPrice'),
      serviceArea: area.isEmpty ? defaultServiceArea : area,
      angryCallbackMinutes: (angry is num
              ? angry.round()
              : defaultAngryCallbackMinutes)
          .clamp(5, 120),
      extraRules: extra,
      instructions: instructions.isEmpty
          ? SettingsService.defaultAiVoiceInstructions
          : instructions,
    );
  }

  static bool _flag(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is bool) return value;
    return true;
  }

  String composeInstructions() {
    final asks = <String>[];
    if (collectName) asks.add('— полное имя;');
    if (collectAddress) asks.add('— адрес (улица и город);');
    if (collectWhen) {
      asks.add('— удобный день и время, когда может приехать мастер;');
    }
    if (collectAppliance) {
      asks.add('— что сломалось и как проявляется поломка;');
    }
    if (collectLocation) {
      asks.add('— где стоит техника, если это важно;');
    }
    if (collectPhoto) {
      asks.add(
        '— может ли клиент прислать модель SMS-кой (фото шильдика) на этот же номер.',
      );
    }

    final buf = StringBuffer()
      ..writeln('Тон: дружелюбный и профессиональный.')
      ..writeln();
    if (asks.isNotEmpty) {
      buf.writeln('Обязательно узнать:');
      for (final line in asks) {
        buf.writeln(line);
      }
      buf.writeln();
    }
    if (noPrice) {
      buf.writeln(
        'Не обещать цену и точное время приезда. Мастер перезвонит подтвердить.',
      );
      buf.writeln();
    }
    final area = serviceArea.trim();
    if (area.isNotEmpty) {
      buf.writeln(
        'Зона: $area. Если адрес вне зоны — вежливо сказать, что туда не выезжаем, заявку не создавать.',
      );
      buf.writeln();
    }
    buf.writeln(
      'Если клиент злой: спокойно сказать, что в течение $angryCallbackMinutes минут с ним свяжется сотрудник компании, разговор закончить. Заявку всё равно создать из того, что уже узнали.',
    );
    final extra = extraRules.trim();
    if (extra.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(extra);
    }
    return buf.toString().trim();
  }

  Map<String, dynamic> toFirestore() {
    final greetingText = greeting.trim().isEmpty
        ? SettingsService.defaultAiVoiceGreeting
        : greeting.trim();
    return {
      'greeting': greetingText,
      'instructions': composeInstructions(),
      'rulesVersion': 3,
      'criteriaVersion': 1,
      'collectName': collectName,
      'collectAddress': collectAddress,
      'collectWhen': collectWhen,
      'collectAppliance': collectAppliance,
      'collectLocation': collectLocation,
      'collectPhoto': collectPhoto,
      'noPrice': noPrice,
      'serviceArea': serviceArea.trim(),
      'angryCallbackMinutes': angryCallbackMinutes.clamp(5, 120),
      'extraRules': extraRules.trim(),
    };
  }
}
