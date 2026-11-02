import 'dart:math';

import 'care_plan.dart';

/// Запись в истории паспорта, которую мастер ставит сам (плановое ТО).
/// Ремонты в истории берутся из заявок с этим паспортом (`applianceIds`).
///
/// [items] видит клиент на публичной странице — поэтому по-английски;
/// [note] — только для мастера.
class ServiceLogEntry {
  static const String kindMaintenance = 'maintenance';
  static const String kindRepair = 'repair';
  static const String kindInstall = 'install';

  final DateTime date;
  final String kind;
  final List<String> items;
  final String jobId;
  final String note;

  const ServiceLogEntry({
    required this.date,
    this.kind = kindMaintenance,
    this.items = const [],
    this.jobId = '',
    this.note = '',
  });

  factory ServiceLogEntry.fromMap(Map<String, dynamic> map) => ServiceLogEntry(
    date: CarePlan.parseDate(map['date']) ?? DateTime.now(),
    kind: (map['kind'] ?? kindMaintenance).toString(),
    items: map['items'] is List
        ? [for (final i in map['items'] as List) i.toString()]
        : const [],
    jobId: (map['jobId'] ?? '').toString(),
    note: (map['note'] ?? '').toString(),
  );

  Map<String, dynamic> toMap() => {
    'date': date.toIso8601String(),
    'kind': kind,
    'items': items,
    if (jobId.isNotEmpty) 'jobId': jobId,
    if (note.isNotEmpty) 'note': note,
  };
}

/// Цифровой паспорт одной единицы техники клиента.
///
/// `companies/{id}/appliances/{code}`: id документа — это и есть публичный
/// код с наклейки (`https://doc.fix-appliance.ca/a/<code>`). Страница по коду
/// не показывает ни имени, ни адреса, ни цен — только технику и историю.
class HomeAppliance {
  static const String statusActive = 'active';
  static const String statusRetired = 'retired';

  final String id;
  final String clientId;
  final String planId;
  final String type;
  final String brand;
  final String model;
  final String serialNumber;
  final String manufactureDate;
  final String placement;
  final String notes;
  final String nameplatePhotoUrl;
  final String status;
  final DateTime? createdAt;
  final DateTime? stickerPrintedAt;
  final List<ServiceLogEntry> serviceLog;

  const HomeAppliance({
    required this.id,
    required this.clientId,
    this.planId = '',
    this.type = '',
    this.brand = '',
    this.model = '',
    this.serialNumber = '',
    this.manufactureDate = '',
    this.placement = '',
    this.notes = '',
    this.nameplatePhotoUrl = '',
    this.status = statusActive,
    this.createdAt,
    this.stickerPrintedAt,
    this.serviceLog = const [],
  });

  bool get isActive => status != statusRetired;

  String get displayName =>
      [type, brand].where((part) => part.trim().isNotEmpty).join(' ');

  String get englishType => ApplianceEnglish.of(type);

  /// «LG Washer» — подпись на наклейке и на странице паспорта.
  String get englishTitle => [brand.trim(), englishType]
      .where((part) => part.isNotEmpty)
      .join(' ');

  factory HomeAppliance.fromMap(Map<String, dynamic> map, String id) =>
      HomeAppliance(
        id: id,
        clientId: (map['clientId'] ?? '').toString(),
        planId: (map['planId'] ?? '').toString(),
        type: (map['type'] ?? '').toString(),
        brand: (map['brand'] ?? '').toString(),
        model: (map['model'] ?? '').toString(),
        serialNumber: (map['serialNumber'] ?? '').toString(),
        manufactureDate: (map['manufactureDate'] ?? '').toString(),
        placement: (map['placement'] ?? '').toString(),
        notes: (map['notes'] ?? '').toString(),
        nameplatePhotoUrl: (map['nameplatePhotoUrl'] ?? '').toString(),
        status: (map['status'] ?? statusActive).toString(),
        createdAt: CarePlan.parseDate(map['createdAt']),
        stickerPrintedAt: CarePlan.parseDate(map['stickerPrintedAt']),
        serviceLog: map['serviceLog'] is List
            ? [
                for (final e in map['serviceLog'] as List)
                  if (e is Map) ServiceLogEntry.fromMap(Map<String, dynamic>.from(e)),
              ]
            : const [],
      );

  /// Поля паспорта, которые правит мастер. История (`serviceLog`) и отметка
  /// печати пишутся отдельно, чтобы правка не затёрла чужую запись.
  Map<String, dynamic> toMap() => {
    'code': id,
    'clientId': clientId,
    'planId': planId,
    'type': type,
    'brand': brand,
    'model': model,
    'serialNumber': serialNumber,
    'manufactureDate': manufactureDate,
    'placement': placement,
    'notes': notes,
    'nameplatePhotoUrl': nameplatePhotoUrl,
    'status': status,
  };

  HomeAppliance copyWith({
    String? planId,
    String? type,
    String? brand,
    String? model,
    String? serialNumber,
    String? manufactureDate,
    String? placement,
    String? notes,
    String? nameplatePhotoUrl,
    String? status,
  }) => HomeAppliance(
    id: id,
    clientId: clientId,
    planId: planId ?? this.planId,
    type: type ?? this.type,
    brand: brand ?? this.brand,
    model: model ?? this.model,
    serialNumber: serialNumber ?? this.serialNumber,
    manufactureDate: manufactureDate ?? this.manufactureDate,
    placement: placement ?? this.placement,
    notes: notes ?? this.notes,
    nameplatePhotoUrl: nameplatePhotoUrl ?? this.nameplatePhotoUrl,
    status: status ?? this.status,
    createdAt: createdAt,
    stickerPrintedAt: stickerPrintedAt,
    serviceLog: serviceLog,
  );
}

/// Английское название типа техники — для наклейки и публичной страницы
/// (каталог в приложении по-русски). Тот же словарь — в `functions/passport.js`.
class ApplianceEnglish {
  static String of(String type) {
    final t = type.trim().toLowerCase();
    if (t.isEmpty) return 'Appliance';
    if (t.contains('мороз') || t.contains('freezer')) return 'Freezer';
    if (t.contains('холод') || t.contains('fridge') || t.contains('refriger')) {
      return 'Refrigerator';
    }
    if (t.contains('посуд') || t.contains('dish')) return 'Dishwasher';
    if (t.contains('стирал') || t.contains('wash')) return 'Washer';
    if (t.contains('суш') || t.contains('dryer')) return 'Dryer';
    if (t.contains('микроволн') || t.contains('microwave')) return 'Microwave';
    if (t.contains('вароч') || t.contains('cooktop')) return 'Cooktop';
    if (t.contains('духов') || t.contains('oven')) {
      return t.contains('плит') ? 'Range' : 'Oven';
    }
    if (t.contains('плит') || t.contains('stove') || t.contains('range')) {
      return 'Range';
    }
    // Свой тип из каталога латиницей — как есть, кириллицу на наклейку не пускаем.
    return RegExp(r'^[\x20-\x7E]+$').hasMatch(type.trim())
        ? type.trim()
        : 'Appliance';
  }
}

/// Что входит в плановое ТО по типу техники. Строки попадают в публичную
/// историю паспорта, поэтому по-английски.
class MaintenanceChecklist {
  static List<String> forType(String type) {
    switch (ApplianceEnglish.of(type)) {
      case 'Washer':
        return const [
          'Drain pump filter cleaned',
          'Door gasket inspected and cleaned',
          'Inlet hoses checked for leaks',
          'Drum bearings and suspension checked',
          'Test cycle run',
        ];
      case 'Dryer':
        return const [
          'Lint screen and lint trap cleaned',
          'Exhaust vent duct cleaned',
          'Drum belt, rollers and idler checked',
          'Heating circuit and safety fuses checked',
          'Test cycle run',
        ];
      case 'Refrigerator':
        return const [
          'Condenser coils cleaned',
          'Door gaskets checked',
          'Defrost drain cleared',
          'Temperatures checked',
        ];
      case 'Freezer':
        return const [
          'Condenser coils cleaned',
          'Door gasket checked',
          'Temperature checked',
        ];
      case 'Dishwasher':
        return const [
          'Filter cleaned',
          'Spray arms cleaned',
          'Drain and door gasket checked',
          'Inlet valve and hoses checked for leaks',
          'Test cycle run',
        ];
      case 'Range':
      case 'Oven':
      case 'Cooktop':
        return const [
          'Elements / burners checked',
          'Oven temperature checked',
          'Door gasket and hinges checked',
          'Power connection checked',
        ];
      case 'Microwave':
        return const [
          'Door seal and interlocks checked',
          'Turntable and light checked',
          'Heating test',
        ];
      default:
        return const ['General inspection', 'Test run'];
    }
  }
}

/// Публичный код паспорта (он же id документа и хвост ссылки в QR).
///
/// Алфавит как у коротких ссылок: без 0/o/1/l/i, чтобы код можно было
/// продиктовать. 10 знаков из 31 — около 50 бит: перебором не найти.
class PassportCode {
  static const String alphabet = '23456789abcdefghjkmnpqrstuvwxyz';
  static const int length = 10;
  static final RegExp _valid = RegExp(r'^[2-9a-hjkmnp-z]{6,16}$');

  static String generate([Random? random]) {
    final rnd = random ?? Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
    ]);
  }

  static bool isValid(String code) => _valid.hasMatch(code);

  static String url(String base, String code) {
    final clean = base.trim().replaceAll(RegExp(r'/+$'), '');
    return '$clean/$code';
  }
}
