import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';
import '../models/document_settings.dart';
import '../models/job.dart';
import 'firestore_service.dart';
import 'maps_service.dart';
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
      "Hi {name}! 🚗\nYour technician is on the way — about 30 minutes.";
  static const String defaultPartOrderedSms =
      'The part for your appliance is ordered. 🔧\nDelivery is usually 3–5 days.';
  static const String defaultJobDoneSms =
      'Repair complete! ✅\nThank you for choosing us.\n⭐ Please leave a review:\n{review}';
  static const String defaultBookingConfirmSms =
      'Hi {name}! ✅\n\n📅 Visit: {date}\n🕘 Time: {time}\n📍 {address}\n\nReply:\n1 ✅ confirm\n0 ❌ cancel\n5 🔁 another day';
  static const String defaultDayBeforeSms =
      'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}\n\nReply 1 ✅ to confirm this visit, 0 ❌ to cancel, 5 🔁 to pick another day.';
  static const String defaultCancelSaveSms =
      'Sorry you need to cancel, {name}. 😔\nWe can keep the visit with 10% off, or even 25% off, or move it to another day.\n\nReply:\n• a new day and time (example: Friday 11:00)\n• 1 — keep {date} at {time} with 10% off\n• 2 — keep it with 25% off\n• 0 — cancel';
  static const String defaultRescheduleAskSms =
      'No problem, {name}. 🔁\nWhat day and time should the technician come?\nExample: Thursday at 14:00';

  static Map<String, String> defaultSmsTemplates() => {
        'on_way': defaultOnWaySms,
        'part_ordered': defaultPartOrderedSms,
        'job_done': defaultJobDoneSms,
        'booking_confirm': defaultBookingConfirmSms,
        'day_before': defaultDayBeforeSms,
        'cancel_save': defaultCancelSaveSms,
        'reschedule_ask': defaultRescheduleAskSms,
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

  /// Клиентские SMS должны оставаться на английском даже при русском интерфейсе.
  static Future<void> ensureEnglishClientCopy() async {
    try {
      const legacySms = {
        'on_way': 'Здравствуйте, это мастер. Буду у вас через 30 минут.',
        'part_ordered':
            'Запчасть для вашей техники заказана. Ожидаем доставку 3-5 дней.',
        'job_done':
            'Ремонт завершен! Спасибо, что выбрали нас. Пожалуйста, оставьте отзыв. {review}',
        'booking_confirm':
            'Здравствуйте, {name}! Визит {date} в {time}. Адрес: {address}. Ответьте 1 — подтверждаю, 2 — перенос.',
        'day_before':
            'Напоминание: завтра {date} в {time}. Ответьте 1 — подтверждаю, 2 — перенос.',
      };
      const oldEnglishConfirm = {
        'booking_confirm':
            'Hi {name}! Visit {date} at {time}. Address: {address}. Reply 1 to confirm, 2 to reschedule.',
        'day_before':
            'Reminder: tomorrow {date} at {time}. Reply 1 to confirm, 2 to reschedule.',
      };
      const previousPlainEnglish = {
        'on_way':
            "Hi {name}, this is your technician. I'll be there in about 30 minutes.",
        'part_ordered':
            'The part for your appliance has been ordered. Delivery is usually 3-5 days.',
        'job_done':
            'Repair complete! Thank you for choosing us. Please leave a review: {review}',
        'booking_confirm':
            'Hi {name}! Visit {date} at {time}. Address: {address}. Reply 1 to confirm, 0 to cancel, 5 to reschedule.',
        'day_before':
            'Reminder: tomorrow {date} at {time}. Reply 1 to confirm, 0 to cancel, 5 to reschedule.',
      };
      final templates = await loadSmsTemplates();
      final next = Map<String, String>.from(templates);
      final defaults = defaultSmsTemplates();
      var smsChanged = false;
      for (final entry in legacySms.entries) {
        if ((next[entry.key] ?? '').trim() == entry.value) {
          next[entry.key] = defaults[entry.key]!;
          smsChanged = true;
        }
      }
      for (final entry in oldEnglishConfirm.entries) {
        if ((next[entry.key] ?? '').trim() == entry.value) {
          next[entry.key] = defaults[entry.key]!;
          smsChanged = true;
        }
      }
      for (final entry in previousPlainEnglish.entries) {
        if ((next[entry.key] ?? '').trim() == entry.value) {
          next[entry.key] = defaults[entry.key]!;
          smsChanged = true;
        }
      }
      const previousCancelSave = {
        'cancel_save':
            'Sorry you need to cancel, {name}. 😔\nWe can keep the visit with 10% off, or move it to another day.\n\nReply with a new day and time (example: Friday 11:00), 1 to keep {date} at {time} with the discount, or 0 again to cancel.',
      };
      for (final entry in previousCancelSave.entries) {
        if ((next[entry.key] ?? '').trim() == entry.value) {
          next[entry.key] = defaults[entry.key]!;
          smsChanged = true;
        }
      }
      if ((next['cancel_save'] ?? '').trim().isEmpty) {
        next['cancel_save'] = defaults['cancel_save']!;
        smsChanged = true;
      }
      if ((next['reschedule_ask'] ?? '').trim().isEmpty) {
        next['reschedule_ask'] = defaults['reschedule_ask']!;
        smsChanged = true;
      }
      for (final key in ['booking_confirm', 'day_before']) {
        final raw = (next[key] ?? '').trim();
        if (raw.isEmpty) continue;
        final cleaned = raw
            .replaceAll(RegExp(r'\n?🔧\s*\{appliance\}', caseSensitive: false), '')
            .replaceAll(
              RegExp(r'\n?This SMS is only for this address\.?', caseSensitive: false),
              '',
            )
            .replaceAll('{appliance}', '')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        if (cleaned != raw) {
          next[key] = cleaned;
          smsChanged = true;
        }
      }
      if (smsChanged) await saveSmsTemplates(next);

      final docs = await loadDocumentSettings();
      var invoiceSms = docs.invoiceSms;
      var estimateSms = docs.estimateSms;
      var receiptSms = docs.receiptSms;
      var docsChanged = false;
      if (invoiceSms.trim() ==
              'Счёт на оплату {total}. К оплате: {due}.\n{items}' ||
          invoiceSms.trim() ==
              'Invoice {total}. Amount due: {due}.\n{items}') {
        invoiceSms = DocumentSettings.defaults.invoiceSms;
        docsChanged = true;
      }
      if (estimateSms.trim() ==
              'Смета {total}. Действует {valid_days} дн.\n{items}' ||
          estimateSms.trim() ==
              'Estimate {total}. Valid for {valid_days} days.\n{items}' ||
          !estimateSms.contains('{url}')) {
        estimateSms = DocumentSettings.defaults.estimateSms;
        docsChanged = true;
      }
      if (receiptSms.trim() == 'Чек об оплате {total}. Спасибо, {name}!' ||
          receiptSms.trim() == 'Payment receipt {total}. Thank you, {name}!' ||
          !receiptSms.contains('{url}')) {
        receiptSms = DocumentSettings.defaults.receiptSms;
        docsChanged = true;
      }
      if (docs.smsHeader.trim().toLowerCase() == 'fixappliance.ca') {
        docsChanged = true;
      }
      if (docsChanged) {
        await saveDocumentSettings(
          docs.copyWith(
            invoiceSms: invoiceSms,
            estimateSms: estimateSms,
            receiptSms: receiptSms,
            smsHeader: docs.smsHeader.trim().toLowerCase() == 'fixappliance.ca'
                ? 'fix-appliance.ca'
                : docs.smsHeader,
          ),
        );
      }

      final config = await loadConfig();
      final wake = (config['assistantWakeWord'] as String?)?.trim() ?? '';
      final aliases = (config['assistantWakeAliases'] is String)
          ? (config['assistantWakeAliases'] as String).trim()
          : '';
      final oldWake = wake.toLowerCase();
      if (wake.isEmpty ||
          oldWake == 'фикс' ||
          oldWake == 'fix' ||
          oldWake == 'purish') {
        await updateConfig('assistantWakeWord', defaultAssistantWakeWord);
      }
      if (aliases.isEmpty || aliases.toLowerCase() == 'fix') {
        await updateConfig(
          'assistantWakeAliases',
          defaultAssistantWakeAliases,
        );
      }
      if (readAssistantEnabled(config) &&
          config['assistantWakeEnabled'] == false) {
        await updateConfig('assistantWakeEnabled', true);
      }
    } catch (_) {}
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

  static const reminderOffsetKeys = ['48h', '24h', 'morning', '2h'];

  static List<String> readReminderOffsets(Map<String, dynamic> config) {
    final raw = config['reminderOffsets'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((item) => item.toString())
          .where((item) => reminderOffsetKeys.contains(item))
          .toList();
    }
    return const ['24h'];
  }

  static int readConfigInt(
    Map<String, dynamic> config,
    String key,
    int fallback, {
    int min = 0,
    int max = 100000,
  }) {
    final value = config[key];
    int parsed = fallback;
    if (value is num) {
      parsed = value.round();
    } else if (value is String) {
      parsed = int.tryParse(value.trim()) ?? fallback;
    }
    return parsed.clamp(min, max);
  }

  static int readMorningBriefingHour(Map<String, dynamic> config) {
    return readConfigInt(config, 'morningBriefingHour', 7, min: 0, max: 23);
  }

  static int readEveningBriefingHour(Map<String, dynamic> config) {
    return readConfigInt(config, 'eveningBriefingHour', 19, min: 0, max: 23);
  }

  static int readReminderMorningHour(Map<String, dynamic> config) {
    return readConfigInt(config, 'reminderMorningHour', 8, min: 0, max: 23);
  }

  static int readOnTheWayMeters(Map<String, dynamic> config) {
    return readConfigInt(config, 'onTheWayMeters', 2000, min: 200, max: 20000);
  }

  static String readOnTheWayText(Map<String, dynamic> config) {
    return (config['onTheWayText'] ?? '').toString().trim();
  }

  static String readEmailIntakeTitle(Map<String, dynamic> config) {
    return (config['emailIntakeTitle'] ?? '').toString().trim();
  }

  static List<String> readWatchedEmailSenders(Map<String, dynamic> config) {
    final raw = config['watchedEmailSenders'];
    if (raw is! List) return const [];
    final seen = <String>{};
    final result = <String>[];
    for (final item in raw) {
      final email = item.toString().trim().toLowerCase();
      if (!email.contains('@') || !seen.add(email)) continue;
      result.add(email);
    }
    return result;
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

  static const String cardReaderPhone = 'phone';
  static const String cardReaderTerminal = 'terminal';

  static String readCardReader(Map<String, dynamic> config) {
    final value = (config['cardReader'] ?? cardReaderPhone).toString();
    if (value == cardReaderTerminal || value == 'bluetooth') {
      return cardReaderTerminal;
    }
    return cardReaderPhone;
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

  /// Начало рабочего дня: 07:00
  static const int defaultWorkStartMinutes = 7 * 60;

  /// Конец рабочего дня: 21:00
  static const int defaultWorkEndMinutes = 21 * 60;

  static const int defaultJobDurationMinutes = 60;
  static const int defaultTravelBufferMinutes = 20;
  static const String defaultCalendarView = 'week';
  static const List<String> calendarViewIds = [
    'day',
    'workWeek',
    'week',
    'month',
    'route',
    'list',
  ];

  static String calendarViewLabel(String id) {
    switch (id) {
      case 'day':
        return '1 день';
      case 'workWeek':
        return '5 дней';
      case 'week':
        return 'Неделя';
      case 'month':
        return 'Календарь';
      case 'route':
        return 'Маршрут';
      case 'list':
        return 'Список';
      default:
        return 'Неделя';
    }
  }

  static String readDefaultCalendarView(Map<String, dynamic> config) {
    final value = (config['defaultCalendarView'] ?? defaultCalendarView)
        .toString()
        .trim();
    if (calendarViewIds.contains(value)) return value;
    return defaultCalendarView;
  }

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

  static Future<String> takeNextDocumentNumber(String type) async {
    final current = await loadDocumentSettings();
    final isEstimate = type == 'Estimate';
    final next = isEstimate ? current.nextEstimateNumber : current.nextInvoiceNumber;
    final label = current.formattedNumber(next <= 0 ? 1 : next);
    await saveDocumentSettings(
      current.copyWith(
        nextInvoiceNumber: isEstimate ? current.nextInvoiceNumber : next + 1,
        nextEstimateNumber: isEstimate ? next + 1 : current.nextEstimateNumber,
      ),
    );
    return label;
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

    add(listAllFilter);
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
      if (def.id == JobStatuses.inProgress) continue;
      add(def.id);
    }
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

  static const String defaultAssistantWakeWord = 'purysh';
  static const String defaultAssistantWakeAliases =
      'purish, purush, parish, puresh, pirish, puris, purge, porish, пюриш, пуриш, пурыш, пуруш, пюришь';

  static const int defaultAiAnswerTimeoutSeconds = 20;
  static const int minAiAnswerTimeoutSeconds = 0;
  static const int maxAiAnswerTimeoutSeconds = 60;

  static const String assistantLanguageRu = 'ru';
  static const String assistantLanguageEn = 'en';

  static String readAssistantLanguage(Map<String, dynamic> config) {
    final value = (config['assistantLanguage'] as String?)?.trim().toLowerCase();
    if (value == assistantLanguageEn || value == assistantLanguageRu) {
      return value!;
    }
    return AppLocale.instance.isEn
        ? assistantLanguageEn
        : assistantLanguageRu;
  }

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
    return boolFlag(config, 'assistantWakeEnabled', defaultValue: true);
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

  static const int aiVoiceRulesVersion = 11;

  static const String defaultAiVoiceGreeting =
      "Hi, you've reached the shop. How can I help?";

  static const String defaultAiVoiceExtraRules =
      'Visits are Monday–Friday 7 a.m. to 9 p.m. Saturday and Sunday the technician does not visit. Still take the order for a weekday.\n'
      'Public holidays: take the order; the technician must agree.\n'
      'Price: do not mention \$99 unless they asked. If they asked: a service call is \$99. If they approve the repair after diagnosis, they do not pay the service call — only the repair.\n'
      'If the appliance is at another house: keep their home address, take the repair address, who will be there, and that person\'s phone.\n'
      'Near the end, if they can, they may text this number a photo or the text of the model-number sticker. Optional — do not stall the call.';

  static const String defaultAiVoiceInstructions =
      'Тон: дружелюбный и профессиональный. Сначала слушать. Не устраивать опрос.\n'
      '\n'
      'Короткие реплики: одно предложение, потом ждать. Не заполнять тишину лишними вопросами. Если клиент уже сказал — не спрашивать снова.\n'
      '\n'
      'Собрать по ходу разговора, не допытывая: что сломалось, вид техники и бренд, имя, куда ехать, день или время если записывают визит. Не допытывать модель, серийник и где стоит техника.\n'
      '\n'
      'Если сказали другой адрес ремонта — принять улицу, дом сохранить, продолжать говорить. Не класть трубку в этот момент.\n'
      '\n'
      'Если хотят, чтобы перезвонил мастер: не допытывать время визита. Передать данные.\n'
      '\n'
      'Не обещать цену.\n'
      '\n'
      'Если клиент злой: спокойно сказать, что в течение 30 минут свяжется сотрудник, разговор закончить.\n'
      '\n'
      'Язык: говорить только по-английски. Клиента понимать на любом языке, в том числе русском, но отвечать всегда по-английски.';

  static bool isStaleAiVoiceGreeting(String greeting) {
    final g = greeting.trim();
    if (g.isEmpty) return true;
    return g.contains("you've reached {company}") ||
        g.contains("technician's with a customer") ||
        g.contains('I can take your details') ||
        g.contains('How can I help you today') ||
        g.contains('Чем могу помочь') ||
        g == "Hi, you've reached FIX Appliance. How can I help?" ||
        g == 'Hi, FIX ApplianceCA. How can I help you?' ||
        g == 'Hi, FIX Appliance. How can I help you?' ||
        g == 'Hi, FIX Appliance. How can I help?';
  }

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
      'rulesVersion': aiVoiceRulesVersion,
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

  static Future<void> setAiVoiceExtraRules(String extraRules) async {
    final profile = await loadAiVoiceProfile();
    await saveAiVoiceProfile(
      AiVoiceProfile(
        enabled: profile.enabled,
        timeoutSeconds: profile.timeoutSeconds,
        greeting: profile.greeting,
        collectName: profile.collectName,
        collectAddress: profile.collectAddress,
        collectWhen: profile.collectWhen,
        collectAppliance: profile.collectAppliance,
        collectLocation: profile.collectLocation,
        collectPhoto: profile.collectPhoto,
        noPrice: profile.noPrice,
        serviceArea: profile.serviceArea,
        angryCallbackMinutes: profile.angryCallbackMinutes,
        extraRules: extraRules,
        instructions: profile.instructions,
        learnedRules: profile.learnedRules,
        learningEnabled: profile.learningEnabled,
      ),
    );
  }

  static Future<void> updateConfigMap(Map<String, dynamic> values) async {
    if (values.isEmpty) return;
    await FirestoreService.configRef.set(values, SetOptions(merge: true));
  }

  /// Текстовое описание зоны с карты «Зона обслуживания».
  static String describeServiceArea(Map<String, dynamic> config) {
    return (config['serviceAreaLabel'] ?? '').toString().trim();
  }

  static Future<void> syncSecretaryServiceArea() async {
    final profile = await loadAiVoiceProfile();
    await FirestoreService.aiVoiceRef.set({
      ...profile.toFirestore(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Если район уже нарисован, а подпись для секретаря ещё не сохранена — собрать её с карты.
  static Future<void> ensureServiceAreaLabel() async {
    try {
      final config = await loadConfig();
      if (describeServiceArea(config).isNotEmpty) return;
      final label = await MapsService.describeServiceAreaFromConfig(config);
      if (label.isEmpty) return;
      await updateConfig('serviceAreaLabel', label);
      await syncSecretaryServiceArea();
    } catch (_) {}
  }

  /// Пишет правила диспетчера в Firestore, если их ещё нет или это старая версия.
  static Future<void> ensureAiVoiceSettings() async {
    try {
      final doc = await FirestoreService.aiVoiceRef.get();
      final data = (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
      final greeting = (data['greeting'] ?? '').toString().trim();
      final staleGreeting = isStaleAiVoiceGreeting(greeting);
      final needBrief = data['briefVersion'] != 1;
      final needHoursPolicy = data['hoursPolicyVersion'] != 2;
      if (data['rulesVersion'] == aiVoiceRulesVersion &&
          !staleGreeting &&
          !needBrief &&
          !needHoursPolicy) {
        return;
      }
      final profile = await loadAiVoiceProfile();
      final extra = needBrief ||
              needHoursPolicy ||
              profile.extraRules.trim().isEmpty ||
              profile.extraRules.contains('Sunday is closed') ||
              profile.extraRules.contains('Saturday: do not')
          ? defaultAiVoiceExtraRules
          : profile.extraRules;
      await saveAiVoiceProfile(
        AiVoiceProfile(
          enabled: profile.enabled,
          timeoutSeconds: profile.timeoutSeconds,
          greeting: staleGreeting ? defaultAiVoiceGreeting : profile.greeting,
          collectName: profile.collectName,
          collectAddress: profile.collectAddress,
          collectWhen: profile.collectWhen,
          collectAppliance: profile.collectAppliance,
          collectLocation: profile.collectLocation,
          collectPhoto: profile.collectPhoto,
          noPrice: profile.noPrice,
          serviceArea: profile.serviceArea,
          angryCallbackMinutes: profile.angryCallbackMinutes,
          extraRules: extra,
          instructions: profile.instructions,
          learnedRules: profile.learnedRules,
          learningEnabled: profile.learningEnabled,
        ),
      );
    } catch (_) {}
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
    this.learnedRules = const [],
    this.learningEnabled = true,
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
  final List<String> learnedRules;
  final bool learningEnabled;

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
      collectLocation: _flag(voice, 'collectLocation', false),
      collectPhoto: _flag(voice, 'collectPhoto', false),
      noPrice: _flag(voice, 'noPrice'),
      serviceArea: SettingsService.describeServiceArea(config),
      angryCallbackMinutes: (angry is num
              ? angry.round()
              : defaultAngryCallbackMinutes)
          .clamp(5, 120),
      extraRules: extra,
      instructions: instructions.isEmpty
          ? SettingsService.defaultAiVoiceInstructions
          : instructions,
      learnedRules: _learnedLines(voice['learnedRules']),
      learningEnabled: voice['learningEnabled'] != false,
    );
  }

  static List<String> _learnedLines(dynamic raw) {
    if (raw is! List) return const [];
    final lines = <String>[];
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        lines.add(item.trim());
      } else if (item is Map) {
        final rule = (item['ruleEn'] ?? item['titleRu'] ?? '').toString().trim();
        if (rule.isNotEmpty) lines.add(rule);
      }
    }
    return lines;
  }

  static bool _flag(Map<String, dynamic> data, String key, [bool fallback = true]) {
    final value = data[key];
    if (value is bool) return value;
    return fallback;
  }

  String composeInstructions({bool includeLearned = false}) {
    final asks = <String>[];
    if (collectAppliance) {
      asks.add(
        '— сначала: что сломалось и как проявляется; затем вид техники и бренд. Не допытывать модель и серийник;',
      );
    }
    if (collectName) {
      asks.add(
        '— достаточно имени. Писать обычным именем (Artem), не фонетической транскрипцией;',
      );
    }
    if (collectAddress) asks.add('— адрес (улица и город);');
    if (collectWhen) {
      asks.add(
        '— и день, и точное время визита (например tomorrow 11:00). Записать оба;',
      );
    }
    if (collectLocation) {
      asks.add(
        '— где стоит техника — только если важно, не давить;',
      );
    }
    if (collectPhoto) {
      asks.add(
        '— в конце, если клиент может: пусть пришлёт на этот же номер текст или фото шильдика с Model Number. Это необязательно, звонок из-за этого не затягивать.',
      );
    }

    final buf = StringBuffer()
      ..writeln(
        'Тон: дружелюбный и профессиональный. Сначала слушать. Не устраивать опрос.',
      )
      ..writeln()
      ..writeln(
        'Короткие реплики: одно предложение, потом ждать. Не заполнять тишину лишними вопросами. Если клиент уже сказал — не спрашивать снова.',
      )
      ..writeln();
    if (asks.isNotEmpty) {
      buf.writeln('Собрать, не допытывая:');
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
        'Зона обслуживания (карта в настройках): $area. Если адрес вне этой зоны — вежливо сказать, что туда не выезжаем, заявку не создавать.',
      );
      buf.writeln();
    } else {
      buf.writeln(
        'Зона на карте не отмечена. Не отказывать по городам из памяти и не выдумывать список городов.',
      );
      buf.writeln();
    }
    buf.writeln(
      'Если клиент хочет поговорить с живым человеком или чтобы перезвонил мастер: не спрашивать адрес и время. Если ещё нет вида техники или бренда — спросить это одним вопросом. Затем сказать по-английски: "Okay, I\'ll pass your details along and a technician will call you back shortly." Заявку создать и разговор закончить.',
    );
    buf.writeln();
    buf.writeln(
      'Если клиент злой: спокойно сказать, что в течение $angryCallbackMinutes минут с ним свяжется сотрудник компании, разговор закончить. Заявку всё равно создать из того, что уже узнали.',
    );
    buf.writeln();
    buf.writeln(
      'Язык: говорить только по-английски. Клиента понимать на любом языке, в том числе русском, но отвечать всегда по-английски. Не переходить на русский и не спрашивать, на каком языке удобнее.',
    );
    final extra = extraRules.trim();
    if (extra.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(extra);
    }
    if (includeLearned && learnedRules.isNotEmpty) {
      buf.writeln();
      buf.writeln(
        'Только то, что мастер уже подтвердил (не выдумывать новое; если спор с правилами выше — правила выше важнее):',
      );
      for (final line in learnedRules) {
        buf.writeln('— $line');
      }
    }
    return buf.toString().trim();
  }

  Map<String, dynamic> toFirestore() {
    final greetingText = greeting.trim().isEmpty
        ? SettingsService.defaultAiVoiceGreeting
        : greeting.trim();
    return {
      'greeting': greetingText,
      'instructions': '',
      'rulesVersion': SettingsService.aiVoiceRulesVersion,
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
      'learningEnabled': learningEnabled,
      'briefVersion': 1,
      'hoursPolicyVersion': 2,
    };
  }
}
