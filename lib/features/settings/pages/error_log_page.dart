import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/error_log_service.dart';
import '../widgets/settings_ui.dart';

/// Что в приложении ломалось. Список нужен не FIX, а тому, кто чинит код:
/// кнопка «Копировать всё» отдаёт готовый текст для агента в Cursor.
class ErrorLogPage extends StatelessWidget {
  const ErrorLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Ошибки', 'Errors'),
      body: StreamBuilder<List<AppErrorEntry>>(
        stream: ErrorLogService.watch(),
        builder: (context, snapshot) {
          final items = snapshot.data;
          if (items == null) {
            return Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 56,
                      color: Colors.green,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.tr('Ошибок нет', 'No errors'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.tr(
                        'Здесь появляются вылеты и сбои. Если что-то сломалось — '
                        'зайдите сюда и нажмите «Копировать всё».',
                        'Crashes and failures show up here. If something breaks, '
                        'come here and tap Copy all.',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black54,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            children: [
              SettingsGroup(
                children: [
                  SettingsRow(
                    title: context.tr('Копировать всё', 'Copy all'),
                    subtitle: context.tr(
                      'Отправьте текст тому, кто правит приложение',
                      'Send the text to whoever fixes the app',
                    ),
                    icon: Icons.copy_all,
                    iconColor: AppColors.primary,
                    onTap: () => _copyAll(context, items),
                  ),
                  SettingsRow(
                    title: context.tr('Очистить', 'Clear'),
                    subtitle: '${items.length} ${context.tr('записей', 'records')}',
                    icon: Icons.delete_outline,
                    iconColor: Colors.redAccent,
                    showDivider: false,
                    onTap: () => _clear(context),
                  ),
                ],
              ),
              for (final item in items) _card(context, item),
            ],
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, AppErrorEntry item) {
    final locale = AppLocale.instance.isEn ? 'en' : 'ru';
    final when = DateFormat('d MMMM, HH:mm', locale).format(item.at);
    final accent = item.isCrash ? Colors.redAccent : Colors.orange.shade700;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                item.isCrash ? Icons.dangerous : Icons.warning_amber_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.screen.isEmpty ? item.kind : '${item.screen} · ${item.kind}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: accent,
                  ),
                ),
              ),
              Text(
                when,
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            item.message,
            style: const TextStyle(fontSize: 13, height: 1.3),
          ),
          if (item.stack.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.stack,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: Colors.black45,
                height: 1.25,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copyAll(
    BuildContext context,
    List<AppErrorEntry> items,
  ) async {
    final text = items.map((item) => item.asText).join('\n---\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Скопировано', 'Copied'))),
    );
  }

  Future<void> _clear(BuildContext context) async {
    await ErrorLogService.clearAll();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Очищено', 'Cleared'))),
    );
  }
}
