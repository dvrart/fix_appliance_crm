import 'package:cloud_firestore/cloud_firestore.dart';

/// Запчасть / товар на складе
class WarehouseItem {
  final String id;
  final String name;
  final String partNumber;
  final String? modelNumber;
  final String? barcode;
  final String category;
  final double price;
  final double? costPrice;
  final int quantity;
  final int? minQuantity;
  final String? imageUrl;
  final String? other; // доп. информация
  final bool isUsed; // б/у или новая

  /// Номера деталей, которые эта деталь заменяет. Ищем по ним в счёте,
  /// чтобы предложить замену, когда нужного номера на складе нет.
  final List<String> interchange;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  WarehouseItem({
    required this.id,
    required this.name,
    required this.partNumber,
    this.modelNumber,
    this.barcode,
    this.category = 'Универсальное',
    required this.price,
    this.costPrice,
    this.quantity = 0,
    this.minQuantity,
    this.imageUrl,
    this.other,
    this.isUsed = false,
    this.interchange = const [],
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  static const trashKeepDays = 30;

  DateTime? get trashExpiresAt =>
      deletedAt?.add(const Duration(days: trashKeepDays));

  int get trashDaysLeft {
    final exp = trashExpiresAt;
    if (exp == null) return 0;
    final days = exp.difference(DateTime.now()).inDays;
    if (days < 0) return 0;
    return days;
  }

  /// Маржа на единицу
  double? get margin => costPrice != null ? price - costPrice! : null;

  /// Процент маржи
  double? get marginPercent =>
      costPrice != null && costPrice! > 0 ? (margin! / costPrice!) * 100 : null;

  /// Нужен заказ (ниже минимума)
  bool get needsReorder => minQuantity != null && quantity < minQuantity!;

  /// Заменяет ли эта деталь номер [partNumber].
  bool replaces(String partNumber) {
    final wanted = normalizePart(partNumber);
    if (wanted.isEmpty) return false;
    return interchange.any((item) => normalizePart(item) == wanted);
  }

  /// Номера пишут по-разному: 285753A, 285753-A, WP285753 A. Для сравнения
  /// оставляем только буквы и цифры.
  static String normalizePart(String value) {
    return value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  /// Частые пары Whirlpool без сети: WPW10311524 ↔ W10311524, WP285753 ↔ 285753.
  static List<String> localSupersessions(String part) {
    final n = normalizePart(part);
    if (n.isEmpty) return const [];
    final out = <String>{};
    if (n.startsWith('WPW') && n.length > 5) {
      out.add(n.substring(2));
    } else if (RegExp(r'^WP\d').hasMatch(n) && n.length > 4) {
      out.add(n.substring(2));
    }
    if (RegExp(r'^W\d').hasMatch(n)) {
      out.add('WP$n');
    }
    out.remove(n);
    return out.toList();
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }

  static int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static List<String> parseInterchange(dynamic raw) {
    final out = <String>[];
    void add(String value) {
      final clean = value.trim().toUpperCase();
      if (clean.isEmpty || out.contains(clean)) return;
      out.add(clean);
    }

    if (raw is List) {
      for (final item in raw) {
        add(item.toString());
      }
    } else if (raw is String) {
      for (final part in raw.split(RegExp(r'[,;\n]'))) {
        add(part);
      }
    }
    return out;
  }

  factory WarehouseItem.fromMap(Map<String, dynamic> map, String docId) {
    return WarehouseItem(
      id: docId,
      name: map['name'] ?? '',
      partNumber: map['partNumber'] ?? '',
      modelNumber: map['modelNumber'],
      barcode: map['barcode'],
      category: map['category'] ?? 'Универсальное',
      price: _asDouble(map['price']),
      costPrice: map['costPrice'] == null ? null : _asDouble(map['costPrice']),
      quantity: _asInt(map['quantity']),
      minQuantity: map['minQuantity'] == null ? null : _asInt(map['minQuantity']),
      imageUrl: map['imageUrl'],
      other: map['other'],
      isUsed: map['isUsed'] == true,
      interchange: parseInterchange(map['interchange']),
      createdAt: map['createdAt'] is Timestamp
          ? (map['createdAt'] as Timestamp).toDate()
          : null,
      updatedAt: map['updatedAt'] is Timestamp
          ? (map['updatedAt'] as Timestamp).toDate()
          : null,
      deletedAt: map['deletedAt'] is Timestamp
          ? (map['deletedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'partNumber': partNumber,
      'modelNumber': modelNumber,
      'barcode': barcode,
      'category': category,
      'price': price,
      'costPrice': costPrice,
      'quantity': quantity,
      'minQuantity': minQuantity,
      'imageUrl': imageUrl,
      'other': other,
      'isUsed': isUsed,
      'interchange': interchange,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  WarehouseItem copyWith({
    String? id,
    String? name,
    String? partNumber,
    String? modelNumber,
    String? barcode,
    String? category,
    double? price,
    double? costPrice,
    int? quantity,
    int? minQuantity,
    String? imageUrl,
    String? other,
    bool? isUsed,
    List<String>? interchange,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return WarehouseItem(
      id: id ?? this.id,
      name: name ?? this.name,
      partNumber: partNumber ?? this.partNumber,
      modelNumber: modelNumber ?? this.modelNumber,
      barcode: barcode ?? this.barcode,
      category: category ?? this.category,
      price: price ?? this.price,
      costPrice: costPrice ?? this.costPrice,
      quantity: quantity ?? this.quantity,
      minQuantity: minQuantity ?? this.minQuantity,
      imageUrl: imageUrl ?? this.imageUrl,
      other: other ?? this.other,
      isUsed: isUsed ?? this.isUsed,
      interchange: interchange ?? this.interchange,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
