import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_service.dart';
import 'network_status_service.dart';

/// Справочники «Тип техники» и «Бренд» — используются в форме создания
/// заявки как выпадающий список с возможностью добавить новое значение,
/// если нужного нет. Списки редактируются в Настройках.
class CatalogService {
  static DocumentReference get _ref =>
      FirestoreService.settingsRef.doc('catalog');

  static const List<String> defaultApplianceTypes = [
    'Холодильник',
    'Стиральная машина',
    'Сушилка',
    'Плита/Духовка',
    'Посудомойка',
    'Микроволновка',
    'Морозильник',
  ];

  static const List<String> defaultBrands = [
    'Samsung',
    'LG',
    'Whirlpool',
    'GE',
    'Maytag',
    'KitchenAid',
    'Bosch',
    'Frigidaire',
    'Electrolux',
    'Kenmore',
    'Amana',
  ];

  static const List<String> defaultLeadSources = [
    'Google',
    'Рекомендация',
    'Повторный клиент',
    'Листовка',
    'Другое',
  ];

  /// Один раз заполняет документ значениями по умолчанию, если он ещё пуст,
  /// чтобы дальнейшие добавления пользователя просто дополняли этот список.
  static Future<void>? _seedFuture;

  static Future<void> _ensureSeeded() {
    _seedFuture ??= _seed();
    return _seedFuture!;
  }

  static Future<void> _seed() async {
    try {
      final snap = await _ref.get();
      final data = snap.data() as Map<String, dynamic>?;
      final updates = <String, dynamic>{};
      if (data == null || data['applianceTypes'] == null) {
        updates['applianceTypes'] = defaultApplianceTypes;
      }
      if (data == null || data['brands'] == null) {
        updates['brands'] = defaultBrands;
      }
      if (data == null || data['leadSources'] == null) {
        updates['leadSources'] = defaultLeadSources;
      } else {
        final sources = List<String>.from(data['leadSources'] as List);
        if (sources.any((s) => s.toLowerCase() == 'facebook')) {
          updates['leadSources'] = sources
              .where((s) => s.toLowerCase() != 'facebook')
              .toList();
        }
      }
      if (updates.isNotEmpty) {
        await _ref.set(updates, SetOptions(merge: true));
      }
    } catch (_) {}
  }

  static Future<List<String>> loadList(String field) async {
    await _ensureSeeded();
    final snap = await _ref.get();
    final data = snap.data() as Map<String, dynamic>?;
    final defaults = switch (field) {
      'applianceTypes' => defaultApplianceTypes,
      'brands' => defaultBrands,
      'leadSources' => defaultLeadSources,
      _ => const <String>[],
    };
    final raw = data?[field];
    final result = raw is List
        ? List<String>.from(raw.map((e) => e.toString()))
        : List<String>.from(defaults);
    if (field == 'leadSources') {
      result.removeWhere((s) => s.toLowerCase() == 'facebook');
    }
    if (field == 'applianceTypes' || field == 'brands') {
      result.sort();
    }
    return result;
  }

  static Future<void> replaceList(String field, List<String> items) async {
    await _ensureSeeded();
    var next = [
      for (final item in items)
        if (item.trim().isNotEmpty) item.trim(),
    ];
    if (field == 'leadSources') {
      next = [
        for (final item in next)
          if (item.toLowerCase() != 'facebook') item,
      ];
    }
    await settleWrite(_ref.set({field: next}, SetOptions(merge: true)));
  }

  static Stream<List<String>> streamApplianceTypes() {
    _ensureSeeded();
    return _ref.snapshots().map((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      final list = data?['applianceTypes'];
      final result = list != null
          ? List<String>.from(list)
          : List<String>.from(defaultApplianceTypes);
      result.sort();
      return result;
    });
  }

  static Stream<List<String>> streamBrands() {
    _ensureSeeded();
    return _ref.snapshots().map((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      final list = data?['brands'];
      final result = list != null
          ? List<String>.from(list)
          : List<String>.from(defaultBrands);
      result.sort();
      return result;
    });
  }

  static Stream<List<String>> streamLeadSources() {
    _ensureSeeded();
    return _ref.snapshots().map((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      final list = data?['leadSources'];
      final result = list != null
          ? List<String>.from(list)
          : List<String>.from(defaultLeadSources);
      result.removeWhere((s) => s.toLowerCase() == 'facebook');
      return result;
    });
  }

  static Future<void> addLeadSource(String source) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.toLowerCase() == 'facebook') return;
    await _ensureSeeded();
    await _ref.set({
      'leadSources': FieldValue.arrayUnion([trimmed]),
    }, SetOptions(merge: true));
  }

  static Future<void> removeLeadSource(String source) async {
    await _removeFromList('leadSources', source);
  }

  static Future<void> addApplianceType(String type) async {
    final trimmed = type.trim();
    if (trimmed.isEmpty) return;
    await _ensureSeeded();
    await _ref.set({
      'applianceTypes': FieldValue.arrayUnion([trimmed]),
    }, SetOptions(merge: true));
  }

  static Future<void> addBrand(String brand) async {
    final trimmed = brand.trim();
    if (trimmed.isEmpty) return;
    await _ensureSeeded();
    await _ref.set({
      'brands': FieldValue.arrayUnion([trimmed]),
    }, SetOptions(merge: true));
  }

  static Future<void> removeApplianceType(String type) async {
    await _removeFromList('applianceTypes', type);
  }

  static Future<void> removeBrand(String brand) async {
    await _removeFromList('brands', brand);
  }

  /// Читаем список и пишем без выбранных — надёжнее, чем arrayRemove.
  static Future<void> _removeFromList(String field, String value) async {
    await _ensureSeeded();
    final snap = await _ref.get();
    final data = snap.data() as Map<String, dynamic>?;
    final raw = data?[field];
    final current = raw is List
        ? List<String>.from(raw.map((e) => e.toString()))
        : <String>[];
    final next = [
      for (final item in current)
        if (item != value) item,
    ];
    await _ref.set({field: next}, SetOptions(merge: true));
  }

  static Future<void> removeMany(String field, Iterable<String> values) async {
    await _ensureSeeded();
    final remove = values.toSet();
    if (remove.isEmpty) return;
    final snap = await _ref.get();
    final data = snap.data() as Map<String, dynamic>?;
    final raw = data?[field];
    final current = raw is List
        ? List<String>.from(raw.map((e) => e.toString()))
        : <String>[];
    final next = [
      for (final item in current)
        if (!remove.contains(item)) item,
    ];
    await _ref.set({field: next}, SetOptions(merge: true));
  }

  static Stream<List<PricebookItem>> streamPricebook() {
    _ensureSeeded();
    return _ref.snapshots().map((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      final list = data?['pricebook'];
      if (list is! List) return const <PricebookItem>[];
      return list
          .whereType<Map>()
          .map((item) => PricebookItem.fromMap(Map<String, dynamic>.from(item)))
          .toList();
    });
  }

  static Future<List<PricebookItem>> loadPricebook() async {
    await _ensureSeeded();
    final snap = await _ref.get();
    final data = snap.data() as Map<String, dynamic>?;
    final list = data?['pricebook'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((item) => PricebookItem.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  static Future<void> savePricebook(List<PricebookItem> items) async {
    await _ensureSeeded();
    await _ref.set({
      'pricebook': items.map((item) => item.toMap()).toList(),
    }, SetOptions(merge: true));
  }

  static Future<void> upsertPricebookItem(PricebookItem item) async {
    final items = [...await loadPricebook()];
    final idx = items.indexWhere((entry) => entry.id == item.id);
    if (idx >= 0) {
      items[idx] = item;
    } else {
      items.add(item);
    }
    await savePricebook(items);
  }

  static Future<void> removePricebookItem(String id) async {
    final items = (await loadPricebook()).where((item) => item.id != id).toList();
    await savePricebook(items);
  }
}

class PricebookItem {
  final String id;
  final String name;
  final String applianceType;
  final double good;
  final double better;
  final double best;
  final String notes;

  const PricebookItem({
    required this.id,
    required this.name,
    this.applianceType = '',
    this.good = 0,
    this.better = 0,
    this.best = 0,
    this.notes = '',
  });

  factory PricebookItem.create({
    required String name,
    String applianceType = '',
    double good = 0,
    double better = 0,
    double best = 0,
    String notes = '',
  }) {
    return PricebookItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      applianceType: applianceType,
      good: good,
      better: better,
      best: best,
      notes: notes,
    );
  }

  factory PricebookItem.fromMap(Map<String, dynamic> map) {
    return PricebookItem(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      applianceType: (map['applianceType'] ?? '').toString(),
      good: (map['good'] as num?)?.toDouble() ?? 0,
      better: (map['better'] as num?)?.toDouble() ?? 0,
      best: (map['best'] as num?)?.toDouble() ?? 0,
      notes: (map['notes'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'applianceType': applianceType,
      'good': good,
      'better': better,
      'best': best,
      'notes': notes,
    };
  }
}
