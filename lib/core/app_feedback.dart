import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_locale.dart';
import 'ui_scale.dart';

/// Лёгкая вибрация и всплывающая подсказка «Скопировано».
class AppFeedback {
  static OverlayEntry? _entry;
  static Timer? _hide;

  static Future<void> copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    haptic();
    if (!context.mounted) return;
    toast(context, 'Скопировано'.tr);
  }

  static DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime? _muteUntil;
  static const _hapticGap = Duration(milliseconds: 90);

  static void muteHaptic([Duration duration = const Duration(milliseconds: 400)]) {
    _muteUntil = DateTime.now().add(duration);
  }

  static bool _canHaptic() {
    final now = DateTime.now();
    final mute = _muteUntil;
    if (mute != null && now.isBefore(mute)) return false;
    if (now.difference(_lastHapticAt) < _hapticGap) return false;
    _lastHapticAt = now;
    return true;
  }

  /// Soft tick for buttons, tabs, and left/right swipes.
  static void pleasant() {
    if (!AppUiSettings.instance.hapticOnPress) return;
    if (!_canHaptic()) return;
    HapticFeedback.selectionClick();
  }

  static void haptic() {
    pleasant();
  }

  static void light() {
    pleasant();
  }

  static void selection() {
    pleasant();
  }

  static void _remove(OverlayEntry entry) {
    _hide?.cancel();
    _hide = null;
    if (_entry == entry) {
      entry.remove();
      _entry = null;
    }
  }

  static void toast(BuildContext context, String message) {
    _hide?.cancel();
    _entry?.remove();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Dismissible(
              key: ValueKey(message),
              direction: DismissDirection.horizontal,
              onDismissed: (_) => _remove(entry),
              child: Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xE61A1A1A),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Color(0xFF81C784),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _hide = Timer(const Duration(seconds: 2), () => _remove(entry));
  }
}
