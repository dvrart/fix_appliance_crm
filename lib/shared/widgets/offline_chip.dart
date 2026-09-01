import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../services/network_status_service.dart';

/// Значок «нет сети» в шапке. Не мешает работать: приложение читает и пишет
/// в локальную копию базы, а этот значок просто говорит, что данные ещё
/// не уехали на сервер.
class OfflineChip extends StatelessWidget {
  const OfflineChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NetworkStatusService.offline,
      builder: (context, offline, _) {
        return ValueListenableBuilder<int>(
          valueListenable: NetworkStatusService.pendingWrites,
          builder: (context, pending, _) {
            final show = offline || pending > 0;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              child: show
                  ? _pill(context, offline: offline, pending: pending)
                  : const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }

  Widget _pill(
    BuildContext context, {
    required bool offline,
    required int pending,
  }) {
    // Ждём отправки — жёлтый. Просто нет сети — серый: ничего не потеряно.
    final waiting = pending > 0;
    final color = waiting ? const Color(0xFFFFC107) : const Color(0xFFB0BAC9);
    final label = waiting
        ? '${context.tr('Отправлю', 'Will send')}: $pending'
        : context.tr('Нет сети', 'No network');
    return Tooltip(
      message: context.tr(
        'Всё сохраняется на телефон и уедет само, когда появится связь',
        'Everything is saved on the phone and will sync once you are back online',
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              waiting ? Icons.cloud_upload_outlined : Icons.cloud_off,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
