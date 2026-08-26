import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/l10n/app_locale.dart';
import '../../../models/secretary_lesson.dart';
import '../../../services/secretary_learn_service.dart';
import '../../calls/call_review_page.dart';
import '../widgets/settings_ui.dart';

/// Папка ошибок телефонного секретаря: отчёты для мастера, чтобы прислать агенту.
class SecretaryLearnPage extends StatelessWidget {
  const SecretaryLearnPage({super.key});

  static Future<void> copyPack(BuildContext context, String pack) async {
    await Clipboard.setData(ClipboardData(text: pack));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            'Скопировано. Пришлите это в чат, чтобы исправить.',
            'Copied. Send this in chat so it can be fixed.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Ошибки секретаря', 'Secretary errors'),
      body: StreamBuilder<List<SecretaryLesson>>(
        stream: SecretaryLearnService.streamAll(),
        builder: (context, snapshot) {
          final items = (snapshot.data ?? const <SecretaryLesson>[])
              .where((item) => item.isIssue)
              .toList();
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.tr(
                    'Пока нет ошибок. После звонка через секретаря отчёт появится здесь.',
                    'No errors yet. After a secretary call, the report will appear here.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              Text(
                context.tr(
                  'Здесь коды ошибок и текст звонка. Скопируйте карточку и пришлите в чат — по ней можно исправить секретаря. Из приложения правила больше не меняются.',
                  'Error codes and call text live here. Copy a card and send it in chat so the secretary can be fixed. The app no longer changes her rules.',
                ),
                style: const TextStyle(color: Colors.black54, height: 1.35),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final pack =
                        items.map((item) => item.agentPack()).join('\n\n---\n\n');
                    await copyPack(context, pack);
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: Text(
                    context.tr('Скопировать все', 'Copy all'),
                  ),
                ),
              ),
              for (final lesson in items) _ErrorCard(lesson: lesson),
            ],
          );
        },
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final SecretaryLesson lesson;

  const _ErrorCard({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final when = lesson.createdAt;
    final stamp = when == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(when.toLocal());
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (stamp.isNotEmpty) stamp,
                if (lesson.fromNumber.trim().isNotEmpty) lesson.fromNumber,
                if (lesson.severity.trim().isNotEmpty) lesson.severity,
              ].join(' · '),
              style: const TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              lesson.problemRu.trim().isNotEmpty
                  ? lesson.problemRu.trim()
                  : lesson.titleRu,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                height: 1.3,
                fontSize: 15,
              ),
            ),
            if (lesson.whatHappenedRu.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                lesson.whatHappenedRu.trim(),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.35, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      SecretaryLearnPage.copyPack(context, lesson.agentPack()),
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(context.tr('Скопировать', 'Copy')),
                ),
                if (lesson.callSid.trim().isNotEmpty)
                  TextButton.icon(
                    onPressed: () => CallReviewPage.open(
                      context,
                      callId: lesson.callSid,
                    ),
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: Text(context.tr('Звонок', 'Call')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
