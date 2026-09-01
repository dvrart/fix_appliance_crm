import 'package:flutter/material.dart';

/// Высота, которая остаётся на экране после клавиатуры и статус-бара.
double keyboardAvoidingMaxHeight(
  BuildContext context, {
  double fraction = 1,
}) {
  final media = MediaQuery.of(context);
  final available =
      media.size.height - media.viewInsets.bottom - media.padding.top;
  if (available <= 160) return available.clamp(0, 160);
  return (available * fraction).clamp(160.0, available);
}

/// Bottom sheet / панель, которая сжимается вместе с клавиатурой
/// и не рисует жёлто-чёрный overflow.
class KeyboardAvoidingSheet extends StatelessWidget {
  final Widget child;
  final double fraction;
  final EdgeInsetsGeometry padding;

  const KeyboardAvoidingSheet({
    super.key,
    required this.child,
    this.fraction = 0.92,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ).add(padding),
      child: SizedBox(
        height: keyboardAvoidingMaxHeight(context, fraction: fraction),
        width: double.infinity,
        child: child,
      ),
    );
  }
}
