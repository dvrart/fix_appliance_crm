import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'offline_queue_service.dart';

/// Есть ли связь с базой. Спрашиваем не у радиомодуля, а у самого Firestore:
/// `isFromCache` становится true, как только SDK теряет сервер, и обратно —
/// когда достучался. Wi-Fi без интернета так тоже ловится.
class NetworkStatusService {
  /// true — сервер недоступен, работаем по локальной копии.
  static final ValueNotifier<bool> offline = ValueNotifier<bool>(false);

  /// Сколько изменений ещё не доехало до сервера.
  static final ValueNotifier<int> pendingWrites = ValueNotifier<int>(0);

  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _probe;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _jobs;
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    final db = FirebaseFirestore.instance;
    final company = db.collection('companies').doc(kCompanyId);

    // Лёгкий документ: снимок с метаданными приходит на каждое изменение связи.
    _probe = company
        .collection('settings')
        .doc('config')
        .snapshots(includeMetadataChanges: true)
        .listen(
      (snapshot) => _setOffline(snapshot.metadata.isFromCache),
      onError: (Object error) => debugPrint('NetworkStatus probe: $error'),
    );

    // Заявки — единственное, что мастер правит в поле, поэтому считаем именно их.
    _jobs = company
        .collection('jobs')
        .snapshots(includeMetadataChanges: true)
        .listen(
      (snapshot) {
        var pending = 0;
        for (final doc in snapshot.docs) {
          if (doc.metadata.hasPendingWrites) pending++;
        }
        if (pendingWrites.value != pending) pendingWrites.value = pending;
      },
      onError: (Object error) => debugPrint('NetworkStatus jobs: $error'),
    );
  }

  static void _setOffline(bool value) {
    if (offline.value == value) return;
    offline.value = value;
    if (!value) {
      // Связь вернулась — досылаем фото и правки, которые не влезли в Firestore.
      unawaited(OfflineQueueService.flush());
    }
  }

  static void dispose() {
    _probe?.cancel();
    _jobs?.cancel();
    _probe = null;
    _jobs = null;
    _started = false;
  }
}

/// Запись в Firestore офлайн уходит в локальный кэш сразу, но её `Future`
/// не завершится, пока сервер не ответит. Ждать его в UI нельзя — кнопка
/// «Сохранить» крутилась бы вечно. Ждём чуть-чуть и отпускаем: данные уже
/// в кэше, SDK сам довезёт их при первой связи.
Future<void> settleWrite(
  Future<void> write, {
  Duration wait = const Duration(seconds: 3),
}) async {
  try {
    await write.timeout(wait);
  } on TimeoutException {
    // Нормальный офлайн: запись лежит в кэше и уедет позже.
    unawaited(write.catchError((Object error) {
      debugPrint('Отложенная запись не прошла: $error');
    }));
  }
}

/// То же самое для записи, возвращающей значение.
Future<T?> settleWriteValue<T>(
  Future<T> write, {
  Duration wait = const Duration(seconds: 3),
}) async {
  try {
    return await write.timeout(wait);
  } on TimeoutException {
    unawaited(write.then<void>((_) {}).catchError((Object error) {
      debugPrint('Отложенная запись не прошла: $error');
    }));
    return null;
  }
}
