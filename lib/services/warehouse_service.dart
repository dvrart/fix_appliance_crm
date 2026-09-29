import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../core/app_commands.dart';
import 'firestore_service.dart';
import 'network_status_service.dart';
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
          .where((item) => !item.isDeleted)
          .toList();
    });
  }

  /// Удалённые позиции склада (корзина).
  static Stream<List<WarehouseItem>> streamTrashed() {
    return _ref.snapshots().map((snapshot) {
      final items = snapshot.docs
          .map((doc) => WarehouseItem.fromMap(
              doc.data() as Map<String, dynamic>, doc.id))
          .where((item) => item.isDeleted)
          .toList()
        ..sort(
          (a, b) => (b.deletedAt ?? b.createdAt ?? DateTime(0))
              .compareTo(a.deletedAt ?? a.createdAt ?? DateTime(0)),
        );
      return items;
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
    final item = WarehouseItem.fromMap(
      snapshot.docs.first.data() as Map<String, dynamic>,
      snapshot.docs.first.id,
    );
    return item.isDeleted ? null : item;
  }

  /// Создать товар. Id берём сами: без сети `add()` ждёт ответа сервера, и
  /// окно «Новая деталь» не закрывается.
  static Future<String> create(WarehouseItem item) async {
    final docRef = _ref.doc();
    await settleWrite(
      docRef.set({
        ...item.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      }),
    );
    return docRef.id;
  }

  /// Обновить товар
  static Future<void> update(String id, Map<String, dynamic> data) async {
    await settleWrite(
      _ref.doc(id).update({
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  /// Изменить количество (списание/приход).
  ///
  /// Только `FieldValue.increment`. Раньше здесь был read-modify-write
  /// (`getById`, потом `update` абсолютным числом) — два списания подряд, две
  /// машины или чтение из офлайн-кэша съедали одно из них, и склад расходился
  /// с реальностью. Инкремент складывается на сервере и копится в офлайне.
  ///
  /// Количество может уйти в минус, и это специально: минус означает «деталь
  /// поставили, а на складе её не числилось». Тихо прижать к нулю значило бы
  /// спрятать ошибку учёта — в списке такая позиция горит красным.
  static Future<void> adjustQuantity(String id, int delta) async {
    if (id.trim().isEmpty || delta == 0) return;
    await settleWrite(
      _ref.doc(id).update({
        'quantity': FieldValue.increment(delta),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
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
    if (!shouldApplyStock(doc, reverse: reverse)) return;
    final deltas = stockDeltas(doc, reverse: reverse);
    for (final entry in deltas.entries) {
      await adjustQuantity(entry.key, entry.value);
    }
    doc['stockApplied'] = !reverse;
  }

  /// Смета склад не двигает; списать дважды или вернуть неспи́санное нельзя.
  @visibleForTesting
  static bool shouldApplyStock(
    Map<String, dynamic> doc, {
    required bool reverse,
  }) {
    if ((doc['type'] ?? '') == 'Estimate') return false;
    if (doc['stockApplied'] == true && !reverse) return false;
    if (doc['stockApplied'] != true && reverse) return false;
    return true;
  }

  /// Сколько и с каких позиций склада снимает документ. Чистая функция:
  /// ошибка здесь тихо расходит склад с реальностью, поэтому закрыта тестом.
  /// Одна и та же деталь в двух строках счёта складывается в одну правку.
  @visibleForTesting
  static Map<String, int> stockDeltas(
    Map<String, dynamic> doc, {
    required bool reverse,
  }) {
    final out = <String, int>{};
    final items = doc['items'];
    if (items is! List) return out;
    for (final item in items) {
      if (item is! Map) continue;
      final id = (item['warehouseItemId'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final qty = _asQty(item['qty']);
      if (qty == 0) continue;
      out[id] = (out[id] ?? 0) + (reverse ? qty : -qty);
    }
    out.removeWhere((_, delta) => delta == 0);
    return out;
  }

  /// Количество в строке счёта. Пустое — одна штука, как в построителе счёта.
  static int _asQty(dynamic raw) {
    if (raw == null) return 1;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString().trim()) ?? 1;
  }

  /// В корзину на 30 дней
  static Future<void> delete(String id, {bool react = true}) async {
    if (react) AppCommands.reactAngry();
    await settleWrite(
      _ref.doc(id).update({
        'deletedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  static Future<void> restore(String id) async {
    await settleWrite(
      _ref.doc(id).update({
        'deletedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  static Future<void> deleteForever(String id) async {
    await settleWrite(_ref.doc(id).delete());
  }

  static Future<void> purgeExpiredTrash() async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: WarehouseItem.trashKeepDays));
    final snapshot = await _ref.get();
    for (final doc in snapshot.docs) {
      final item = WarehouseItem.fromMap(
        doc.data() as Map<String, dynamic>,
        doc.id,
      );
      if (item.deletedAt != null && item.deletedAt!.isBefore(cutoff)) {
        await deleteForever(item.id);
      }
    }
  }

  /// Товары с низким остатком
  static Future<List<WarehouseItem>> getLowStock() async {
    final snapshot = await _ref.get();
    return snapshot.docs
        .map((doc) =>
            WarehouseItem.fromMap(doc.data() as Map<String, dynamic>, doc.id))
        .where((item) => !item.isDeleted && item.needsReorder)
        .toList();
  }
}
