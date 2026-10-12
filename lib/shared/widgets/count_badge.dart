import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Красный кружок с числом поверх иконки нижнего меню.
///
/// Считает не виджет: он подписан на готовый [ValueListenable], поэтому
/// цифра на вкладке «Связь» и цифры на её подвкладках берутся из одного
/// источника и не могут разойтись.
class CountBadge extends StatelessWidget {
  final ValueListenable<int> count;
  final Widget child;
  final AlignmentGeometry alignment;

  const CountBadge({
    super.key,
    required this.count,
    required this.child,
    this.alignment = Alignment.topRight,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: count,
      child: child,
      builder: (context, value, child) {
        return Badge(
          isLabelVisible: value > 0,
          alignment: alignment,
          backgroundColor: const Color(0xFFE11D48),
          // Трёхзначные счётчики закрывают саму иконку, а разницы между
          // «99» и «137» непрочитанных для решения нет.
          label: Text(
            value > 99 ? '99+' : '$value',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          child: child,
        );
      },
    );
  }
}
