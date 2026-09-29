import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/secretary_lesson.dart';
import '../../../services/secretary_learn_service.dart';
import '../../calls/call_review_page.dart';
import '../widgets/settings_ui.dart';

/// Экран разбора ошибок телефонного секретаря.
/// Вкладки: Новые · Разобранные · Не ошибки · Все.
class SecretaryLearnPage extends StatefulWidget {
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
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  State<SecretaryLearnPage> createState() => _SecretaryLearnPageState();
}

class _SecretaryLearnPageState extends State<SecretaryLearnPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SecretaryLesson>>(
      stream: SecretaryLearnService.streamAll(),
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <SecretaryLesson>[];
        final allIssues = all
            .where(
              (item) =>
                  item.isIssue ||
                  item.status == SecretaryLesson.approved ||
                  item.status == SecretaryLesson.rejected,
            )
            .toList();

        final pendingList =
            allIssues.where((item) => item.isPending).toList();
        final approvedList = allIssues
            .where((item) => item.status == SecretaryLesson.approved)
            .toList();
        final rejectedList = allIssues
            .where((item) => item.status == SecretaryLesson.rejected)
            .toList();

        return SettingsPageScaffold(
          title: context.tr('Ошибки секретаря', 'Secretary errors'),
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: AppColors.accent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(
                text: pendingList.isNotEmpty
                    ? '${context.tr('Новые', 'New')} (${pendingList.length})'
                    : context.tr('Новые', 'New'),
              ),
              Tab(
                text: approvedList.isNotEmpty
                    ? '${context.tr('Разобранные', 'Reviewed')} (${approvedList.length})'
                    : context.tr('Разобранные', 'Reviewed'),
              ),
              Tab(
                text: rejectedList.isNotEmpty
                    ? '${context.tr('Не ошибки', 'Not errors')} (${rejectedList.length})'
                    : context.tr('Не ошибки', 'Not errors'),
              ),
              Tab(
                text: allIssues.isNotEmpty
                    ? '${context.tr('Все', 'All')} (${allIssues.length})'
                    : context.tr('Все', 'All'),
              ),
            ],
          ),
          body: !snapshot.hasData
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _LessonListTab(
                      items: pendingList,
                      description: context.tr(
                        'Звонки, требующие вашего внимания. Подтвердите ошибку, чтобы скопировать её для правки сервера, или отметьте «Не ошибка», чтобы секретарь знала такое поведение.',
                        'Calls requiring your review. Confirm an error to copy it for server fix, or mark "Not an error" so the secretary knows this behavior.',
                      ),
                      emptyText: context.tr(
                        'Нет новых ошибок. Все звонки разобраны!',
                        'No new errors. All calls are reviewed!',
                      ),
                      emptyIcon: Icons.check_circle_outline,
                    ),
                    _LessonListTab(
                      items: approvedList,
                      description: context.tr(
                        'Подтверждённые ошибки. Скопируйте карточку и отправьте в чат — правку внесут на сервере в системный промпт или код.',
                        'Confirmed errors. Copy the card and send it in chat — changes are applied on the server to the system prompt or code.',
                      ),
                      emptyText: context.tr(
                        'Пока нет подтверждённых ошибок.',
                        'No confirmed errors yet.',
                      ),
                      emptyIcon: Icons.task_alt,
                    ),
                    _LessonListTab(
                      items: rejectedList,
                      description: context.tr(
                        'Звонки, отмеченные как нормальные. Сервер запомнил ваш выбор и больше не будет предлагать такие замечания.',
                        'Calls marked as normal. The server remembers your choice and will not suggest these remarks again.',
                      ),
                      emptyText: context.tr(
                        'Пока нет звонков, отмеченных как «Не ошибка».',
                        'No calls marked as "Not an error" yet.',
                      ),
                      emptyIcon: Icons.thumb_up_alt_outlined,
                    ),
                    _LessonListTab(
                      items: allIssues,
                      description: context.tr(
                        'Полная история разборов звонков телефонного секретаря.',
                        'Complete history of telephone secretary call reviews.',
                      ),
                      emptyText: context.tr(
                        'Пока нет записей разбора звонков.',
                        'No call review records yet.',
                      ),
                      emptyIcon: Icons.history,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _LessonListTab extends StatelessWidget {
  final List<SecretaryLesson> items;
  final String description;
  final String emptyText;
  final IconData emptyIcon;

  const _LessonListTab({
    required this.items,
    required this.description,
    required this.emptyText,
    required this.emptyIcon,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(emptyIcon, size: 48, color: Colors.black26),
              const SizedBox(height: 16),
              Text(
                emptyText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 20, color: Colors.blueGrey),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  description,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${context.tr('Всего', 'Total')}: ${items.length}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.black54,
                fontSize: 13,
              ),
            ),
            TextButton.icon(
              onPressed: () async {
                final pack =
                    items.map((item) => item.agentPack()).join('\n\n---\n\n');
                await SecretaryLearnPage.copyPack(context, pack);
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: Text(context.tr('Скопировать все', 'Copy all')),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final lesson in items) _ErrorCard(lesson: lesson),
      ],
    );
  }
}

class _ErrorCard extends StatefulWidget {
  final SecretaryLesson lesson;

  const _ErrorCard({required this.lesson});

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  bool _showTranscript = false;
  bool _busy = false;

  Future<void> _approve() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.approve(widget.lesson);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Ошибка подтверждена. Скопируйте карточку и отправьте в чат для исправления.',
              'Error confirmed. Copy the card and send it in chat for fixing.',
            ),
          ),
          action: SnackBarAction(
            label: context.tr('Скопировать', 'Copy'),
            textColor: Colors.yellow,
            onPressed: () => SecretaryLearnPage.copyPack(
              context,
              widget.lesson.agentPack(),
            ),
          ),
          duration: const Duration(seconds: 5),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.reject(widget.lesson);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Отмечено как «Не ошибка». Сервер запомнил.',
              'Marked as "Not an error". The server saved this preference.',
            ),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetToPending() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.resetToPending(widget.lesson);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Возвращено в «Новые».',
              'Moved back to "New".',
            ),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('Удалить запись?', 'Delete record?')),
        content: Text(
          context.tr(
            'Удалить эту запись разбора звонка?',
            'Delete this call review record?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr('Отмена', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.tr('Удалить', 'Delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await SecretaryLearnService.delete(widget.lesson);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildStatusBadge(BuildContext context) {
    final status = widget.lesson.status;
    if (status == SecretaryLesson.approved) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: Text(
          context.tr('Ошибка подтверждена', 'Confirmed error'),
          style: TextStyle(
            color: Colors.green.shade800,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    if (status == SecretaryLesson.rejected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.blueGrey.shade300),
        ),
        child: Text(
          context.tr('Не ошибка', 'Not an error'),
          style: TextStyle(
            color: Colors.blueGrey.shade800,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Text(
        context.tr('Ожидает разбора', 'Needs review'),
        style: TextStyle(
          color: Colors.orange.shade900,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSeverityBadge(BuildContext context) {
    final isFail = widget.lesson.severity == 'fail';
    final isOk = widget.lesson.severity == 'ok';
    final color = isFail
        ? const Color(0xFFC62828)
        : isOk
            ? const Color(0xFF2E7D32)
            : const Color(0xFFE65100);
    final label = isFail
        ? context.tr('Критично', 'Critical')
        : isOk
            ? context.tr('В норме', 'Normal')
            : context.tr('Замечание', 'Issue');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lesson = widget.lesson;
    final when = lesson.createdAt;
    final stamp = when == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(when.toLocal());
    final phone = lesson.fromNumber.trim();
    final problem = lesson.problemRu.trim().isNotEmpty
        ? lesson.problemRu.trim()
        : lesson.titleRu.trim();
    final happened = lesson.whatHappenedRu.trim();
    final clungTo = lesson.clungToRu.trim();
    final fix = lesson.suggestedFixRu.trim();
    final rule = lesson.ruleEn.trim();
    final transcript = lesson.transcriptExcerpt.trim();
    final isPending = lesson.isPending;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isPending ? Colors.orange.shade200 : Colors.black12,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Верхняя строка: дата, телефон, статус, важность, меню
            Row(
              children: [
                _buildSeverityBadge(context),
                const SizedBox(width: 6),
                _buildStatusBadge(context),
                const Spacer(),
                if (stamp.isNotEmpty)
                  Text(
                    stamp,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  tooltip: context.tr('Меню', 'Menu'),
                  onSelected: (val) {
                    if (val == 'delete') {
                      _delete();
                    } else if (val == 'copy_transcript' &&
                        transcript.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: transcript));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            context.tr('Текст разговора скопирован', 'Transcript copied'),
                          ),
                        ),
                      );
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (transcript.isNotEmpty)
                      PopupMenuItem(
                        value: 'copy_transcript',
                        child: Row(
                          children: [
                            const Icon(Icons.chat_bubble_outline, size: 18),
                            const SizedBox(width: 8),
                            Text(context.tr('Скопировать разговор', 'Copy transcript')),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                          const SizedBox(width: 8),
                          Text(
                            context.tr('Удалить', 'Delete'),
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (phone.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.phone, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  Text(
                    phone,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // Проблема
            Text(
              problem.isNotEmpty ? problem : context.tr('Разбор звонка', 'Call review'),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                height: 1.3,
                fontSize: 15,
              ),
            ),
            // Что произошло
            if (happened.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                happened,
                style: const TextStyle(
                  height: 1.35,
                  fontSize: 13,
                  color: Colors.black87,
                ),
              ),
            ],
            // Зацепилась
            if (clungTo.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFE082)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.anchor, size: 16, color: Color(0xFFF57F17)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${context.tr('Зацепилась за', 'Stuck on')}: $clungTo',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFE65100),
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Как надо было
            if (fix.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFA5D6A7)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, size: 16, color: Color(0xFF2E7D32)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${context.tr('Как надо было', 'Suggested fix')}: $fix',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1B5E20),
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Правило для сервера
            if (rule.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                child: Text(
                  '${context.tr('Правило (EN)', 'Rule (EN)')}: $rule',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.grey.shade800,
                    height: 1.3,
                  ),
                ),
              ),
            ],
            // Отрывок разговора (разворачиваемый)
            if (transcript.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => setState(() => _showTranscript = !_showTranscript),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        _showTranscript
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: Colors.blueGrey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showTranscript
                            ? context.tr('Скрыть отрывок разговора', 'Hide conversation excerpt')
                            : context.tr('Показать отрывок разговора', 'Show conversation excerpt'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.blueGrey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showTranscript) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FA),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: SelectableText(
                    transcript,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // Кнопки разбора (Это ошибка / Не ошибка / Вернуть)
            if (isPending) ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _approve,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        context.tr('Это ошибка', 'Real error'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _reject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        side: BorderSide(color: Colors.red.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(
                        context.tr('Не ошибка', 'Not an error'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ] else ...[
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _busy ? null : _resetToPending,
                    icon: const Icon(Icons.undo, size: 16),
                    label: Text(
                      context.tr('Вернуть в новые', 'Move to new'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],

            // Вспомогательные кнопки: Скопировать для правки + Звонок
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      SecretaryLearnPage.copyPack(context, lesson.agentPack()),
                  icon: const Icon(Icons.copy_all_outlined, size: 17),
                  label: Text(
                    context.tr('Скопировать для правки', 'Copy for fix'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const Spacer(),
                if (lesson.callSid.trim().isNotEmpty)
                  TextButton.icon(
                    onPressed: () => CallReviewPage.open(
                      context,
                      callId: lesson.callSid,
                    ),
                    icon: const Icon(Icons.play_circle_outline, size: 17),
                    label: Text(
                      context.tr('Звонок', 'Call'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
