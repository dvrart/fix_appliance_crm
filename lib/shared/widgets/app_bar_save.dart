import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/l10n/app_locale.dart';

/// Save lives only in the app-bar: a green check logo, not the word «Сохранить».
class AppBarSaveButton extends StatelessWidget {
  final bool dirty;
  final bool saving;
  final VoidCallback? onPressed;
  final String? label;

  const AppBarSaveButton({
    super.key,
    required this.dirty,
    this.saving = false,
    this.onPressed,
    this.label,
  });

  static const _green = Color(0xFF22C55E);

  @override
  Widget build(BuildContext context) {
    final canSave = dirty && !saving && onPressed != null;
    return IconButton(
      tooltip: saving ? 'Сохранение...'.tr : (label ?? 'Сохранить'.tr),
      onPressed: canSave
          ? () {
              AppCommands.reactHappy();
              onPressed!();
            }
          : null,
      icon: saving
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: _green,
              ),
            )
          : Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dirty ? _green : Colors.white.withValues(alpha: 0.22),
              ),
              child: Icon(
                Icons.check_rounded,
                size: 22,
                color: dirty ? Colors.white : Colors.white70,
              ),
            ),
    );
  }
}
