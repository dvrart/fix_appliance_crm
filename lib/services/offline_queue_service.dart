import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_log_service.dart';
import 'firestore_service.dart';

/// Очередь изменений заявок и фото, если запись в Firestore не прошла.
///
/// Обычный офлайн Firestore переживает сам: запись ложится в локальный кэш и
/// уезжает при первой связи. Эта очередь — для жёстких отказов: сервер отверг
/// запись, фото не влезло в тайм-аут загрузки. Отсюда три правила, которые
/// нельзя откатывать:
///
/// * **Массив никогда не досылается целиком.** Раньше не отправленное вложение
///   уходило как `update({'attachments': [одно фото]})` и стирало все
///   остальные снимки заявки. Для массивов есть отдельная операция
///   `jobArrayUnion` с `FieldValue.arrayUnion`.
/// * **Типы сохраняются.** `jsonEncode` превращал `Timestamp` в строку, и дата
///   визита приезжала в базу строкой. Даты пакуются в `{'__ts': мс}` и
///   восстанавливаются перед отправкой.
/// * **Половину записи не отправляем.** `FieldValue` (serverTimestamp, delete,
///   arrayUnion) в JSON не сериализуется. Раньше такие поля молча выбрасывались
///   и в базу уезжал огрызок. Теперь операция не ставится в очередь вовсе, а
///   владелец видит запись в «Настройки → Данные → Ошибки».
class OfflineQueueService {
  static const _key = 'offline_ops_v2';
  static const _legacyKey = 'offline_ops_v1';

  /// Сколько раз пробуем операцию. Запись, которую сервер отвергает всегда
  /// (заявку удалили, поле не то), иначе висит вечно и держит жёлтое
  /// «Отправлю: N» зажжённым.
  static const maxAttempts = 5;

  static const _tsTag = '__ts';

  static bool _flushing = false;
  static int _seq = 0;

  // ------------------------------------------------ постановка в очередь

  static Future<void> enqueueJobUpdate(
    String jobId,
    Map<String, dynamic> data,
  ) async {
    if (jobId.trim().isEmpty || data.isEmpty) return;
    if (hasUnsendableValue(data)) {
      // Лучше честно потерять запись и сказать об этом, чем дослать огрызок.
      ErrorLogService.record(
        'Правка заявки $jobId не встала в очередь: поля '
        '${unsendableKeys(data).join(', ')} нельзя сохранить на телефоне',
        null,
        kind: 'offline_queue',
      );
      return;
    }
    await _add({
      'type': 'jobUpdate',
      'jobId': jobId,
      'data': encodeData(data),
    });
  }

  /// Добавить элементы в массив заявки, не затрагивая уже лежащие там.
  static Future<void> enqueueJobArrayUnion(
    String jobId,
    String field,
    List<Map<String, dynamic>> items,
  ) async {
    if (jobId.trim().isEmpty || field.trim().isEmpty || items.isEmpty) return;
    await _add({
      'type': 'jobArrayUnion',
      'jobId': jobId,
      'field': field,
      'items': [for (final item in items) encodeData(item)],
    });
  }

  static Future<void> enqueuePhoto({
    required String jobId,
    required String localPath,
    required String fileName,
  }) async {
    await _add({
      'type': 'photo',
      'jobId': jobId,
      'localPath': localPath,
      'fileName': fileName,
    });
  }

  // ------------------------------------------------ отправка

  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacy(prefs);
      final batch = _read(prefs);
      if (batch.isEmpty) return;

      final done = <String>{};
      final attempts = <String, int>{};
      final dropped = <Map<String, dynamic>>[];
      for (final op in batch) {
        final id = (op['id'] ?? '').toString();
        if (await _run(op)) {
          done.add(id);
          continue;
        }
        final next = ((op['attempts'] as num?)?.toInt() ?? 0) + 1;
        if (next >= maxAttempts) {
          done.add(id);
          dropped.add(op);
        } else {
          attempts[id] = next;
        }
      }

      // Перечитываем: пока отправляли, могли добавиться новые операции.
      final current = _read(prefs);
      await prefs.setString(
        _key,
        jsonEncode(planRemaining(current, done: done, attempts: attempts)),
      );
      for (final op in dropped) {
        ErrorLogService.record(
          'Отложенная операция ${op['type']} по заявке ${op['jobId']} '
          'не прошла $maxAttempts раз и снята с очереди',
          null,
          kind: 'offline_queue',
        );
      }
    } catch (error, stack) {
      ErrorLogService.record(error, stack, kind: 'offline_queue');
    } finally {
      _flushing = false;
    }
  }

  /// Что остаётся в очереди после прохода. Чистая функция: `done` — успешно
  /// отправленные или снятые, `attempts` — новое число попыток для упавших.
  @visibleForTesting
  static List<Map<String, dynamic>> planRemaining(
    List<Map<String, dynamic>> current, {
    required Set<String> done,
    required Map<String, int> attempts,
  }) {
    final remaining = <Map<String, dynamic>>[];
    for (final op in current) {
      final id = (op['id'] ?? '').toString();
      if (done.contains(id)) continue;
      final next = attempts[id];
      remaining.add(next == null ? op : {...op, 'attempts': next});
    }
    return remaining;
  }

  static Future<bool> _run(Map<String, dynamic> op) async {
    try {
      switch (op['type']) {
        case 'jobUpdate':
          final data = decodeData(
            Map<String, dynamic>.from(op['data'] as Map),
          );
          if (data.isEmpty) return true;
          await FirestoreService.jobsRef.doc(op['jobId'] as String).update({
            ...data,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return true;
        case 'jobArrayUnion':
          final items = [
            for (final item in (op['items'] as List? ?? const []))
              if (item is Map) decodeData(Map<String, dynamic>.from(item)),
          ];
          if (items.isEmpty) return true;
          await FirestoreService.jobsRef.doc(op['jobId'] as String).update({
            (op['field'] as String): FieldValue.arrayUnion(items),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return true;
        case 'photo':
          return await _runPhoto(op);
      }
    } catch (e) {
      debugPrint('OfflineQueue: операция ${op['type']} не прошла: $e');
    }
    return false;
  }

  static Future<bool> _runPhoto(Map<String, dynamic> op) async {
    final jobId = op['jobId'] as String;
    final localPath = op['localPath'] as String;
    final fileName = op['fileName'] as String;
    final file = File(localPath);
    if (!file.existsSync()) {
      debugPrint('OfflineQueue: фото удалено с телефона, пропускаем: $localPath');
      ErrorLogService.record(
        'Фото из офлайн-очереди не найдено — файл удалён: $fileName',
        null,
        kind: 'offline_queue',
      );
      return true; // починить нечем, снимаем с очереди
    }
    final storageRef = FirebaseStorage.instance
        .ref()
        .child('jobs/$jobId/attachments/$fileName');
    await storageRef.putFile(file);
    final url = await storageRef.getDownloadURL();
    // Транзакция, а не arrayUnion: у заявки уже лежит запись этого снимка с
    // локальным путём. Её надо дописать, иначе в карточке останутся два фото,
    // одно из которых на другом телефоне не открывается.
    final doc = FirestoreService.jobsRef.doc(jobId);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(doc);
      final data = snap.data() as Map<String, dynamic>?;
      tx.update(doc, {
        'attachments': applyUploadedPhoto(
          data?['attachments'],
          fileName: fileName,
          url: url,
        ),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return true;
  }

  /// Дописывает ссылку в уже лежащую запись снимка (по имени файла), а если
  /// такой записи нет — добавляет новую. Никогда не теряет остальные вложения.
  @visibleForTesting
  static List<Map<String, dynamic>> applyUploadedPhoto(
    dynamic existing, {
    required String fileName,
    required String url,
  }) {
    final out = <Map<String, dynamic>>[];
    var patched = false;
    if (existing is List) {
      for (final item in existing) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (!patched && (map['name'] ?? '').toString() == fileName) {
          map['url'] = url;
          map.remove('localPath');
          map.remove('pendingUpload');
          patched = true;
        }
        out.add(map);
      }
    }
    if (!patched) {
      out.add({
        'url': url,
        'name': fileName,
        'uploadedAt': DateTime.now().toIso8601String(),
      });
    }
    return out;
  }

  // ------------------------------------------------ хранение

  static List<Map<String, dynamic>> _read(SharedPreferences prefs) {
    return _decodeList(prefs.getString(_key));
  }

  static List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _add(Map<String, dynamic> op) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacy(prefs);
    final list = _read(prefs)
      ..add({
        ...op,
        'id': _newId(),
        'attempts': 0,
        'queuedAt': DateTime.now().toIso8601String(),
      });
    await prefs.setString(_key, jsonEncode(list));
  }

  static String _newId() {
    _seq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_seq';
  }

  /// Со старой очереди переносим только фото: правки заявок там лежат с
  /// испорченными типами, дописывать их в базу нельзя.
  static Future<void> _migrateLegacy(SharedPreferences prefs) async {
    final raw = prefs.getString(_legacyKey);
    if (raw == null) return;
    final legacy = _decodeList(raw);
    final kept = <Map<String, dynamic>>[];
    var skipped = 0;
    for (final op in legacy) {
      if (op['type'] == 'photo') {
        kept.add({
          ...op,
          'id': _newId(),
          'attempts': 0,
          'queuedAt': DateTime.now().toIso8601String(),
        });
      } else {
        skipped += 1;
      }
    }
    if (kept.isNotEmpty) {
      await prefs.setString(_key, jsonEncode([..._read(prefs), ...kept]));
    }
    await prefs.remove(_legacyKey);
    if (skipped > 0) {
      ErrorLogService.record(
        'Из старой офлайн-очереди снято $skipped правок заявок: '
        'их типы данных повреждены прежней версией',
        null,
        kind: 'offline_queue',
      );
    }
  }

  // ------------------------------------------------ упаковка значений

  /// Готовит данные к `jsonEncode`, не теряя даты.
  @visibleForTesting
  static Map<String, dynamic> encodeData(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((key, value) => out[key] = encodeValue(value));
    return out;
  }

  @visibleForTesting
  static dynamic encodeValue(dynamic value) {
    if (value is DateTime) return {_tsTag: value.millisecondsSinceEpoch};
    if (value is Timestamp) {
      return {_tsTag: value.toDate().millisecondsSinceEpoch};
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): encodeValue(entry.value),
      };
    }
    if (value is List) return [for (final item in value) encodeValue(item)];
    return value;
  }

  /// Обратное преобразование перед записью в Firestore.
  @visibleForTesting
  static Map<String, dynamic> decodeData(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((key, value) => out[key] = decodeValue(value));
    return out;
  }

  @visibleForTesting
  static dynamic decodeValue(dynamic value) {
    if (value is Map) {
      final millis = value[_tsTag];
      if (value.length == 1 && millis is num) {
        return Timestamp.fromMillisecondsSinceEpoch(millis.toInt());
      }
      return {
        for (final entry in value.entries)
          entry.key.toString(): decodeValue(entry.value),
      };
    }
    if (value is List) return [for (final item in value) decodeValue(item)];
    return value;
  }

  /// Есть ли в данных то, что нельзя положить на телефон и честно дослать.
  @visibleForTesting
  static bool hasUnsendableValue(Map<String, dynamic> data) {
    return unsendableKeys(data).isNotEmpty;
  }

  @visibleForTesting
  static List<String> unsendableKeys(Map<String, dynamic> data) {
    final keys = <String>[];
    data.forEach((key, value) {
      if (_containsFieldValue(value)) keys.add(key);
    });
    return keys;
  }

  static bool _containsFieldValue(dynamic value) {
    if (value is FieldValue) return true;
    if (value is Map) return value.values.any(_containsFieldValue);
    if (value is List) return value.any(_containsFieldValue);
    return false;
  }
}
