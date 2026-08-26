import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/app_commands.dart';
import 'firestore_service.dart';
import '../models/warehouse_item.dart';

/// Сервис для работы со складом
class WarehouseService {
  static final _ref = FirestoreService.warehouseRef;

  static CollectionReference get ref => _ref;

  /// Стрим всех товаров
  static Stream<List<WarehouseItem>> streamAll() {
    return _ref.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => WarehouseItem.fromMap(
              doc.data() as Map<String, dynamic>, doc.id))
          .toList();
    });
  }

  /// Стрим по категории
  static Stream<List<WarehouseItem>> streamByCategory(String category) {
    if (category == 'Все') return streamAll();

    return _ref
        .where('category', isEqualTo: category)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => WarehouseItem.fromMap(
              doc.data() as Map<String, dynamic>, doc.id))
          .toList();
    });
  }

  /// Получить товар по ID
  static Future<WarehouseItem?> getById(String id) async {
    final doc = await _ref.doc(id).get();
    if (!doc.exists) return null;
    return WarehouseItem.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  /// Поиск по part number
  static Future<WarehouseItem?> findByPartNumber(String partNumber) async {
    final snapshot = await _ref
        .where('partNumber', isEqualTo: partNumber.trim().toUpperCase())
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;
    return WarehouseItem.fromMap(
      snapshot.docs.first.data() as Map<String, dynamic>,
      snapshot.docs.first.id,
    );
  }

  /// Создать товар
  static Future<String> create(WarehouseItem item) async {
    final docRef = await _ref.add({
      ...item.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
  }

  /// Обновить товар
  static Future<void> update(String id, Map<String, dynamic> data) async {
    await _ref.doc(id).update({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Изменить количество (списание/приход)
  static Future<void> adjustQuantity(String id, int delta) async {
    final item = await getById(id);
    if (item == null) return;

    final newQuantity = (item.quantity + delta).clamp(0, 999999);
    await _ref.doc(id).update({
      'quantity': newQuantity,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Списать единицу (при добавлении в заявку)
  static Future<void> decrementQuantity(String id) async {
    await adjustQuantity(id, -1);
  }

  /// Добавить единицу (возврат)
  static Future<void> incrementQuantity(String id) async {
    await adjustQuantity(id, 1);
  }

  /// Списать/вернуть позиции счёта, у которых есть warehouseItemId.
  static Future<void> applyDocumentStock(
    Map<String, dynamic> doc, {
    required bool reverse,
  }) async {
    if ((doc['type'] ?? '') == 'Estimate') return;
    if (doc['stockApplied'] == true && !reverse) return;
    if (doc['stockApplied'] != true && reverse) return;
    final items = doc['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map) continue;
      final warehouseId = item['warehouseItemId'] as String?;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      final qty = (item['qty'] as num?)?.toInt() ?? 1;
      await adjustQuantity(warehouseId, reverse ? qty : -qty);
    }
    doc['stockApplied'] = !reverse;
  }

  /// Удалить товар
  static Future<void> delete(String id) async {
    AppCommands.reactAngry();
    await _ref.doc(id).delete();
  }

  /// Товары с низким остатком
  static Future<List<WarehouseItem>> getLowStock() async {
    final snapshot = await _ref.get();
    return snapshot.docs
        .map((doc) =>
            WarehouseItem.fromMap(doc.data() as Map<String, dynamic>, doc.id))
        .where((item) => item.needsReorder)
        .toList();
  }
}
