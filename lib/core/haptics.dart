import 'package:flutter/services.dart';

/// Вибрация только для явных действий: кнопки и смена вкладок.
class AppHaptics {
  static void button() {
    HapticFeedback.lightImpact();
  }

  static void tab() {
    HapticFeedback.selectionClick();
  }
}
