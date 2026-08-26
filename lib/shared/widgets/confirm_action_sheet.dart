import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../unsaved_navigation_gate.dart';

enum UnsavedChangesAction { save, discard, cancel }

/// Bottom yes/no (and optional discard) row: green check, yellow square, red cross.
Future<UnsavedChangesAction> showConfirmActionSheet(
  BuildContext context, {
  required String title,
  String? message,
  bool showDiscard = false,
  String? saveLabel,
  String? stayLabel,
  String? discardLabel,
}) async {
  final host = UnsavedNavigationGate.dialogHost;
  final sheetContext = (host != null && host.mounted) ? host : context;
  final result = await showModalBottomSheet<UnsavedChangesAction>(
    context: sheetContext,
    useRootNavigator: true,
    isScrollControlled: false,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14557F),
                ),
              ),
              if (message != null && message.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _LabeledAction(
                    color: const Color(0xFF22C55E),
                    icon: Icons.check_rounded,
                    label: saveLabel ?? 'Сохранить'.tr,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      AppCommands.reactHappy();
                      Navigator.pop(context, UnsavedChangesAction.save);
                    },
                  ),
                  if (showDiscard)
                    _LabeledAction(
                      color: const Color(0xFFFCC520),
                      square: true,
                      label: stayLabel ?? 'Остаться'.tr,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context, UnsavedChangesAction.cancel);
                      },
                    ),
                  _LabeledAction(
                    color: const Color(0xFFE53935),
                    icon: Icons.close_rounded,
                    label: discardLabel ?? 'Без сохранения'.tr,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.pop(context, UnsavedChangesAction.discard);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
  return result ?? UnsavedChangesAction.cancel;
}

/// Two buttons for this action only: green check confirms, yellow square cancels.
Future<bool> showConfirmCancelSheet(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmLabel,
  String? cancelLabel,
}) async {
  final host = UnsavedNavigationGate.dialogHost;
  final sheetContext = (host != null && host.mounted) ? host : context;
  final result = await showModalBottomSheet<bool>(
    context: sheetContext,
    useRootNavigator: true,
    isScrollControlled: false,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14557F),
                ),
              ),
              if (message != null && message.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _LabeledAction(
                    color: const Color(0xFF22C55E),
                    icon: Icons.check_rounded,
                    label: confirmLabel ?? 'Удалить'.tr,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      Navigator.pop(context, true);
                    },
                  ),
                  _LabeledAction(
                    color: const Color(0xFFFCC520),
                    square: true,
                    label: cancelLabel ?? 'Отмена'.tr,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.pop(context, false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
  return result == true;
}

/// Red exit button at the bottom. Returns true if the user chose to leave.
Future<bool> showExitAppSheet(BuildContext context) async {
  final host = UnsavedNavigationGate.dialogHost;
  final sheetContext = (host != null && host.mounted) ? host : context;
  final result = await showModalBottomSheet<bool>(
    context: sheetContext,
    useRootNavigator: true,
    isScrollControlled: false,
    isDismissible: true,
    enableDrag: false,
    backgroundColor: Colors.white,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocale.instance.t('Хотите выйти?', 'Do you want to leave?'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14557F),
                ),
              ),
              const SizedBox(height: 22),
              RoundActionButton(
                color: const Color(0xFFE53935),
                icon: Icons.exit_to_app_rounded,
                tooltip: AppLocale.instance.t('Выйти', 'Leave'),
                onTap: () {
                  HapticFeedback.mediumImpact();
                  Navigator.pop(context, true);
                },
              ),
              const SizedBox(height: 8),
              Text(
                AppLocale.instance.t('Выйти', 'Leave'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE53935),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
  return result == true;
}

class _LabeledAction extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool square;

  const _LabeledAction({
    required this.color,
    required this.label,
    required this.onTap,
    this.icon,
    this.square = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundActionButton(
          color: color,
          icon: icon,
          tooltip: label,
          onTap: onTap,
          square: square,
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

class RoundActionButton extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final Color iconColor;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool square;

  const RoundActionButton({
    super.key,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.iconColor = Colors.white,
    this.size = 64,
    this.square = false,
  });

  @override
  Widget build(BuildContext context) {
    final shape = square
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))
        : const CircleBorder();
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        shape: shape,
        elevation: 3,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: _mark()),
          ),
        ),
      ),
    );
  }

  Widget _mark() {
    if (icon != null) {
      return Icon(icon, color: iconColor, size: size * 0.53);
    }
    if (!square) return const SizedBox.shrink();
    final inner = size * 0.34;
    return Container(
      width: inner,
      height: inner,
      decoration: BoxDecoration(
        color: iconColor,
        borderRadius: BorderRadius.circular(inner * 0.22),
      ),
    );
  }
}
