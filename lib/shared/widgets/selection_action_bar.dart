import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

/// Панель множественного выбора: снять, выделить все, удалить.
/// Чекбокс выбора без всплеска.
class SelectCheckbox extends StatelessWidget {
  final bool selected;

  const SelectCheckbox({super.key, required this.selected});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Checkbox(
        value: selected,
        onChanged: (_) {},
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        splashRadius: 0,
        side: const BorderSide(color: Color(0xFF14557F), width: 1.6),
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF14557F);
          }
          return Colors.white;
        }),
        checkColor: Colors.white,
      ),
    );
  }
}

/// Панель множественного выбора: снять, выделить все, копировать, удалить.
class SelectionActionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback? onSelectAll;
  final VoidCallback? onCopy;

  const SelectionActionBar({
    super.key,
    required this.count,
    required this.onCancel,
    required this.onDelete,
    this.onSelectAll,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Отмена'.tr,
                onPressed: onCancel,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
              Expanded(
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              if (onSelectAll != null)
                IconButton(
                  tooltip: 'Выбрать все'.tr,
                  onPressed: onSelectAll,
                  icon: const Icon(Icons.select_all, color: Colors.white),
                ),
              if (onCopy != null)
                IconButton(
                  tooltip: 'Копировать'.tr,
                  onPressed: count == 0 ? null : onCopy,
                  icon: Icon(
                    Icons.copy_rounded,
                    color: count == 0 ? Colors.white38 : Colors.white,
                  ),
                ),
              IconButton(
                tooltip: 'Удалить'.tr,
                style: IconButton.styleFrom(
                  highlightColor: Colors.transparent,
                  splashFactory: NoSplash.splashFactory,
                ),
                onPressed: count == 0
                    ? null
                    : () {
                        AppCommands.reactAngry();
                        onDelete();
                      },
                icon: Icon(
                  Icons.delete_outline,
                  color: count == 0 ? Colors.white38 : const Color(0xFFFF8A80),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
