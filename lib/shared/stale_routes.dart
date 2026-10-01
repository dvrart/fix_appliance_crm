import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

/// Карточки, привязанные к записи в базе (заявка, клиент). Запись ушла в
/// корзину или удалена — все её карточки снимаются со всех стеков, чтобы
/// «Назад» не возвращал туда, чего уже нет. Под ними остаётся живой экран,
/// а если живых нет — корень вкладки (главный экран).
class StaleRoutes {
  StaleRoutes._();

  static final Map<String, Set<State>> _open = {};

  static String _key(String kind, String id) => '$kind:${id.trim()}';

  static void watchJob(String id, State state) => _watch('job', id, state);
  static void unwatchJob(String id, State state) => _unwatch('job', id, state);
  static void watchClient(String id, State state) =>
      _watch('client', id, state);
  static void unwatchClient(String id, State state) =>
      _unwatch('client', id, state);

  static void dropJob(String id) => _drop('job', id);
  static void dropClient(String id) => _drop('client', id);

  /// Запись в корзине. Пока `serverTimestamp` не подтверждён сервером,
  /// локальный снимок отдаёт `deletedAt: null` — смотрим на ожидающую запись.
  static bool isTrashed(Map<String, dynamic> data, SnapshotMetadata meta) {
    return data['deletedAt'] != null ||
        (data.containsKey('deletedAt') && meta.hasPendingWrites);
  }

  static void _watch(String kind, String id, State state) {
    if (id.trim().isEmpty) return;
    _open.putIfAbsent(_key(kind, id), () => <State>{}).add(state);
  }

  static void _unwatch(String kind, String id, State state) {
    final key = _key(kind, id);
    final set = _open[key];
    if (set == null) return;
    set.remove(state);
    if (set.isEmpty) _open.remove(key);
  }

  static void _drop(String kind, String id) {
    if (id.trim().isEmpty) return;
    final routes = <Route<dynamic>>[];
    for (final state in [...?_open[_key(kind, id)]]) {
      if (!state.mounted) continue;
      final route = ModalRoute.of(state.context);
      if (route == null || !route.isActive || route.isFirst) continue;
      if (!routes.contains(route)) routes.add(route);
    }
    // Сначала тихо убираем копии из глубины стека, потом закрываем верхнюю
    // с обычной анимацией.
    for (final route in routes.where((r) => !r.isCurrent)) {
      route.navigator?.removeRoute(route);
    }
    for (final route in routes.where((r) => r.isActive && r.isCurrent)) {
      route.navigator?.pop();
    }
  }
}
