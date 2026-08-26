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
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
    this.createdAt,
    this.updatedAt,
  });

  /// Маржа на единицу
  double? get margin => costPrice != null ? price - costPrice! : null;

  /// Процент маржи
  double? get marginPercent =>
      costPrice != null && costPrice! > 0 ? (margin! / costPrice!) * 100 : null;

  /// Нужен заказ (ниже минимума)
  bool get needsReorder => minQuantity != null && quantity < minQuantity!;

  factory WarehouseItem.fromMap(Map<String, dynamic> map, String docId) {
    return WarehouseItem(
      id: docId,
      name: map['name'] ?? '',
      partNumber: map['partNumber'] ?? '',
      modelNumber: map['modelNumber'],
      barcode: map['barcode'],
      category: map['category'] ?? 'Универсальное',
      price: (map['price'] ?? 0).toDouble(),
      costPrice: map['costPrice']?.toDouble(),
      quantity: map['quantity'] ?? 0,
      minQuantity: map['minQuantity'],
      imageUrl: map['imageUrl'],
      other: map['other'],
      createdAt: map['createdAt'] != null
          ? (map['createdAt'] as Timestamp).toDate()
          : null,
      updatedAt: map['updatedAt'] != null
          ? (map['updatedAt'] as Timestamp).toDate()
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
    DateTime? createdAt,
    DateTime? updatedAt,
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
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
