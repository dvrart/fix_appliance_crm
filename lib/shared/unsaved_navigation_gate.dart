import 'package:flutter/widgets.dart';

/// Пока открыта карточка с несохранёнными правками, меню и вкладки
/// спрашивают то же «Сохранить?», что и системная кнопка Назад.
class UnsavedNavigationGate {
  UnsavedNavigationGate._();

  static final List<Future<bool> Function()> _handlers = [];

  /// Контекст верхней оболочки (нижнее меню), чтобы диалог не открывался
  /// на скрытой вкладке и не блокировал переключение.
  static BuildContext? dialogHost;

  static void push(Future<bool> Function() handler) {
    _handlers.add(handler);
  }

  static void pop(Future<bool> Function() handler) {
    _handlers.remove(handler);
  }

  static bool get hasHandler => _handlers.isNotEmpty;

  static Future<bool> allowLeave({BuildContext? host}) async {
    dialogHost = host;
    try {
      if (_handlers.isEmpty) return true;
      return await _handlers.last();
    } catch (_) {
      return true;
    } finally {
      dialogHost = null;
    }
  }
}
