import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/l10n/app_locale.dart';

const _saveGreen = Color(0xFF22C55E);

/// Rectangular green check at the bottom of a page.
class BottomConfirmButton extends StatelessWidget {
  final bool dirty;
  final bool saving;
  final VoidCallback? onPressed;

  const BottomConfirmButton({
    super.key,
    required this.dirty,
    this.saving = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final canSave = dirty && !saving && onPressed != null;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(24, 6, 24, 10),
      child: Align(
        alignment: Alignment.center,
        heightFactor: 1,
        child: Material(
          color: canSave ? _saveGreen : Colors.grey.shade400,
          elevation: canSave ? 3 : 0,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: canSave
                ? () {
                    AppCommands.reactHappy();
                    onPressed!();
                  }
                : null,
            child: SizedBox(
              width: 168,
              height: 52,
              child: Center(
                child: saving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
                color: _saveGreen,
              ),
            )
          : Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dirty ? _saveGreen : Colors.white.withValues(alpha: 0.22),
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
