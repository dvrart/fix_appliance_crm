import 'package:flutter/widgets.dart';

/// Пока открыта карточка с несохранёнными правками, меню и вкладки
/// спрашивают то же «Сохранить?», что и системная кнопка Назад.
class UnsavedNavigationGate {
  UnsavedNavigationGate._();

  static final List<Future<bool> Function()> _handlers = [];

  /// Кто из открытых экранов прямо сейчас с правками. Нужно тем, кто снимает
  /// экраны молча (лимит глубины, сброс вкладки): пока правки есть — не трогаем.
  static final Map<Future<bool> Function(), bool Function()> _unsaved = {};

  /// Контекст верхней оболочки (нижнее меню), чтобы диалог не открывался
  /// на скрытой вкладке и не блокировал переключение.
  static BuildContext? dialogHost;

  static void push(
    Future<bool> Function() handler, {
    required bool Function() unsaved,
  }) {
    _handlers.add(handler);
    _unsaved[handler] = unsaved;
  }

  static void pop(Future<bool> Function() handler) {
    _handlers.remove(handler);
    _unsaved.remove(handler);
  }

  static bool get hasHandler => _handlers.isNotEmpty;

  /// Хоть где-то есть несохранённые правки.
  static bool get hasUnsavedWork {
    for (final handler in _handlers) {
      final unsaved = _unsaved[handler];
      if (unsaved == null || unsaved()) return true;
    }
    return false;
  }

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
