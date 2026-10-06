import 'package:flutter/material.dart';

/// Единые параметры анимаций: переходы между экранами, диалоги и нижние
/// шторки. Смысл один — убрать рывок в первых кадрах. Дефолтные кривые
/// Flutter (`Easing.legacyDecelerate` у шторки, `Curves.easeOut` за 150 мс у
/// диалога) стартуют почти мгновенно, поэтому окно «выстреливает», а не
/// появляется.
///
/// Левое боковое меню сюда **не входит**: у него свой контроллер и свой жест
/// (`_SideMenuLayer` в `features/main/main_screen.dart`). Его не трогаем.
class AppMotion {
  /// Появление: трогается мягко, без скачка.
  static const Curve enter = Curves.easeOutCubic;

  /// Исчезновение: так же мягко отпускает.
  static const Curve exit = Curves.easeInOutCubic;

  /// Переход между экранами. Скорость оставлена прежней — мягкость даёт
  /// кривая и уменьшенный сдвиг, а не замедление.
  static const Duration pageIn = Duration(milliseconds: 380);
  static const Duration pageOut = Duration(milliseconds: 320);

  /// Насколько новый экран выезжает сбоку (доля ширины). Было 0.055 —
  /// сдвиг заметно дёргал содержимое.
  static const double pageSlide = 0.03;

  /// Диалог. У Flutter по умолчанию 150 мс, и этого не хватает, чтобы глаз
  /// успел за появлением.
  ///
  /// `reverseDuration` здесь задавать бессмысленно: `RawDialogRoute` не
  /// принимает отдельную длительность закрытия и берёт `duration` в обе
  /// стороны. Мягкость закрытия задаёт `reverseCurve`.
  static const AnimationStyle dialog = AnimationStyle(
    duration: Duration(milliseconds: 240),
    curve: enter,
    reverseCurve: exit,
  );

  /// Нижняя шторка. По умолчанию 250/200 мс.
  static const AnimationStyle sheet = AnimationStyle(
    duration: Duration(milliseconds: 300),
    reverseDuration: Duration(milliseconds: 250),
    curve: enter,
    reverseCurve: exit,
  );
}

/// Переход между экранами: затухание плюс едва заметный сдвиг сбоку.
class SoftPageTransitionsBuilder extends PageTransitionsBuilder {
  const SoftPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.pageIn;

  @override
  Duration get reverseTransitionDuration => AppMotion.pageOut;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final incoming = CurvedAnimation(
      parent: animation,
      curve: AppMotion.enter,
      reverseCurve: AppMotion.exit,
    );
    // No secondary animation: the screen below stays still while the new
    // screen slides in. Prevents the background from drifting left when a
    // route is pushed on top (especially noticeable with opaque:false routes
    // like the call screen).
    return FadeTransition(
      opacity: incoming,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(AppMotion.pageSlide, 0),
          end: Offset.zero,
        ).animate(incoming),
        child: child,
      ),
    );
  }
}
