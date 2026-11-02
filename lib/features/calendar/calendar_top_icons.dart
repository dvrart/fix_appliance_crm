import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../shared/app_nav.dart';
import '../care_plan/care_plan_attention.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/parts_queue_screen.dart';

/// Верхний правый блок шапки календаря (место бывшего колокольчика).
///
/// * «Ждём запчасть» — видна только пока есть заявки в статусе «Ожидание
///   запчасти», жёлтый кружок с числом таких заявок; открывает экран
///   очереди запчастей.
/// * «Без даты визита» — видна только пока есть открытые заявки без даты
///   визита; открывает нижний лист со списком этих заявок.
class CalendarTopIcons extends StatefulWidget {
  final Color color;
  final double iconSize;

  const CalendarTopIcons({
    super.key,
    required this.color,
    this.iconSize = 28,
  });

  @override
  State<CalendarTopIcons> createState() => _CalendarTopIconsState();
}

class _CalendarTopIconsState extends State<CalendarTopIcons> {
  /// Поток создаётся один раз на `State`: переподписка на каждом
  /// перестроении подводит `runtime_performance_test`.
  late final _jobs = JobService.streamAll();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: _jobs,
      builder: (context, snapshot) {
        var parts = 0;
        var overdue = 0;
        var noDate = 0;
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        for (final job in snapshot.data ?? const <Job>[]) {
          if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
          if (job.status == JobStatuses.waitingPart) {
            parts++;
            final promised = job.promisedPartAt;
            if (promised != null && promised.isBefore(today)) overdue++;
          }
          if (job.isUnscheduled) noDate++;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Care Plan: пора ТО / платёж не прошёл. Своей подписки на
            // Firestore у значка нет — он читает общий индекс CarePlanService.
            CarePlanAttentionButton(
              color: widget.color,
              iconSize: widget.iconSize,
            ),
            if (parts > 0)
              _headerButton(
                icon: Icons.local_shipping,
                count: parts,
                // Красный грузовик — кому-то обещанный срок уже прошёл.
                alert: overdue > 0,
                tooltip: overdue > 0
                    ? context.tr(
                        'Срок обещания прошёл',
                        'A promised date has passed',
                      )
                    : context.tr('Ждём запчасть', 'Waiting for a part'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  unawaited(
                    AppNav.openCard(
                      context,
                      key: 'card:parts-queue',
                      builder: (_) => const PartsQueueScreen(),
                    ),
                  );
                },
              ),
            if (noDate > 0)
              _headerButton(
                icon: Icons.event_busy,
                count: noDate,
                tooltip: context.tr('Без даты визита', 'No visit date'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  UnscheduledJobsSheet.show(context, _jobs);
                },
              ),
          ],
        );
      },
    );
  }

  Widget _headerButton({
    required IconData icon,
    required int count,
    required String tooltip,
    required VoidCallback onTap,
    bool alert = false,
  }) {
    final red = const Color(0xFFD32F2F);
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
      onPressed: onTap,
      icon: Badge(
        backgroundColor: alert ? red : AppColors.accent,
        textColor: alert ? Colors.white : Colors.black,
        label: Text('$count'),
        child: Icon(
          icon,
          color: alert ? red : widget.color,
          size: widget.iconSize,
        ),
      ),
    );
  }
}

/// Нижний лист со всеми заявками без даты визита.
class UnscheduledJobsSheet extends StatelessWidget {
  final BuildContext hostContext;
  final BuildContext sheetContext;
  final Stream<List<Job>> jobs;
  final ScrollController? scrollController;

  const UnscheduledJobsSheet({
    super.key,
    required this.hostContext,
    required this.sheetContext,
    required this.jobs,
    this.scrollController,
  });

  static Future<void> show(
    BuildContext hostContext,
    Stream<List<Job>> jobs,
  ) {
    return showModalBottomSheet<void>(
      context: hostContext,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.52,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return UnscheduledJobsSheet(
              hostContext: hostContext,
              sheetContext: sheetContext,
              jobs: jobs,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }

  void _openJob(Job job) {
    final host = hostContext;
    unawaited(() async {
      if (Navigator.of(sheetContext).canPop()) {
        Navigator.pop(sheetContext);
      }
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!host.mounted) return;
      await PanelReturn.open(
        AppNav.navigatorOf(host),
        push: () => AppNav.openCard(
          host,
          key: AppNav.jobKey(job.id),
          builder: (_) => JobDetailsScreen(
            jobId: job.id,
            clientId: job.clientId,
            jobData: job.toMap(),
          ),
        ),
        back: () {
          if (host.mounted) unawaited(show(host, jobs));
        },
      );
    }());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: jobs,
      builder: (context, snapshot) {
        final items = <Job>[
          for (final job in snapshot.data ?? const <Job>[])
            if (job.isUnscheduled) job,
        ];
        items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('Без даты визита', 'No visit date'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    if (items.isNotEmpty)
                      Text(
                        '${items.length}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: AppColors.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 12),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          context.tr(
                            'Все заявки с датой визита',
                            'Every job has a visit date',
                          ),
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 15,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final job = items[index];
                          return _JobRow(job: job, onTap: () => _openJob(job));
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  final Job job;
  final VoidCallback onTap;

  static const _color = Color(0xFF1565C0);

  const _JobRow({required this.job, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = job.contactName.trim().isNotEmpty
        ? job.contactName.trim()
        : (job.clientName.trim().isNotEmpty
            ? job.clientName.trim()
            : (job.contactPhone.trim().isNotEmpty
                ? job.contactPhone.trim()
                : context.tr('Клиент', 'Client')));
    final appliance =
        (job.primaryAppliance?.displayName ?? job.applianceType).trim();
    final detail = job.description.trim().isNotEmpty
        ? job.description.trim()
        : job.workAddress.trim();
    final subtitle = [
      if (appliance.isNotEmpty) appliance,
      if (detail.isNotEmpty) detail,
    ].join(' · ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _color.withValues(alpha: 0.4)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.event_busy,
                      size: 17,
                      color: _color,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  height: 1.15,
                                  color: AppColors.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              DateFormat(
                                'd MMM',
                                AppLocale.instance.dateLocale,
                              ).format(job.createdAt.toLocal()),
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.inkMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.2,
                              fontWeight: FontWeight.w500,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
