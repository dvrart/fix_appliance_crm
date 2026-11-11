import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../services/app_time_service.dart';
import '../../services/error_log_service.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../services/sms_service.dart';
import '../../services/status_service.dart';
import '../../services/technician_service.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/job_agenda_card.dart';
import '../../shared/widgets/job_status_filter_bar.dart';
import '../../shared/widgets/technician_filter_bar.dart';
import 'basket_screen.dart';
import 'job_details/job_details_screen.dart';

/// All jobs that are not done or cancelled — no split by day.
/// `ActiveJobsScreen.today()` показывает только визиты на сегодня.
class ActiveJobsScreen extends StatelessWidget {
  final DateTime? day;

  const ActiveJobsScreen({super.key}) : day = null;

  ActiveJobsScreen.today({super.key}) : day = DateTime.now();

  static int _compare(Job a, Job b) {
    final aAt = a.scheduledAt;
    final bAt = b.scheduledAt;
    if (aAt == null && bAt == null) return b.createdAt.compareTo(a.createdAt);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return aAt.compareTo(bAt);
  }

  @override
  Widget build(BuildContext context) {
    final target = day;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(target == null ? 'Активные'.tr : 'Сегодня'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          const TechnicianFilterBar(),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: TechnicianFilterState.selected,
              builder: (context, techFilter, _) {
                return StreamBuilder<List<Job>>(
                  stream: JobService.streamAll(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Center(
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                        ),
                      );
                    }
                    final jobs =
                        snapshot.data!
                            .where(
                              (job) =>
                                  TechnicianFilterState.matches(
                                    job,
                                    techFilter,
                                  ) &&
                                  (target == null
                                      ? !JobStatuses.isClosed(job.status)
                                      : job.hasVisitOn(target)),
                            )
                            .toList()
                          ..sort(_compare);

                    if (jobs.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            target == null
                                ? 'Нет активных заявок'.tr
                                : 'На сегодня визитов нет'.tr,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.inkMuted,
                              height: 1.35,
                            ),
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                      itemCount: jobs.length,
                      itemBuilder: (context, index) {
                        final job = jobs[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: JobAgendaCard(
                            job: job,
                            forceCompact: true,
                            visit: target == null
                                ? job.latestVisit
                                : (job.visitOn(target) ?? job.latestVisit),
                            onTap: () {
                              AppNav.openCard(
                                context,
                                key: AppNav.jobKey(job.id),
                                builder: (_) => JobDetailsScreen(
                                  jobId: job.id,
                                  clientId: job.clientId,
                                  jobData: job.toMap(),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Единый сплошной список всех визитов подряд по датам.
class AllVisitsScreen extends StatefulWidget {
  final Stream<List<Job>>? jobsStream;
  final Stream<List<JobStatusDef>>? statusesStream;
  final Stream<List<SmsMessage>>? unreadMessagesStream;
  final Stream<List<SmsMessage>>? awaitingApprovalStream;
  final DateTime? referenceNow;
  final bool showStatusFilters;

  /// Экран живёт в правой шторке, у которой нет своего навигатора: «Назад»
  /// и любой переход в карточку должны сначала закрыть шторку, иначе
  /// карточка откроется под ней. Пусто — экран открыт как обычный маршрут.
  final VoidCallback? onLeave;

  /// Контекст хозяина шторки. Закрытая шторка уходит из дерева вместе со
  /// своим `context`, поэтому навигация после [onLeave] идёт по нему.
  final BuildContext? hostContext;

  /// Зовётся, когда карточку, открытую отсюда, закрыли кнопкой «Назад»:
  /// шторка возвращается на место, а не оставляет пользователя на вкладке,
  /// которая лежала под ней.
  final VoidCallback? onReturn;

  const AllVisitsScreen({
    super.key,
    this.jobsStream,
    this.statusesStream,
    this.unreadMessagesStream,
    this.awaitingApprovalStream,
    this.referenceNow,
    this.showStatusFilters = true,
    this.onLeave,
    this.hostContext,
    this.onReturn,
  });

  @override
  State<AllVisitsScreen> createState() => _AllVisitsScreenState();
}

class _AllVisitsScreenState extends State<AllVisitsScreen> {
  /// Шторку пересобирают при каждом открытии (так устроен `DrawerController`),
  /// поэтому место в списке помнит сам экран: вернувшись из карточки, видишь
  /// ту же строку, а не начало списка. Только для шторки — обычный маршрут и
  /// тесты открываются с нуля.
  static double _shadeOffset = 0;

  late final ScrollController _scrollController = ScrollController(
    initialScrollOffset: widget.onLeave == null ? 0 : _shadeOffset,
  );
  final GlobalKey _todayKey = GlobalKey();
  String _selectedFilter = SettingsService.listAllFilter;
  late final Stream<List<Job>> _jobsStream =
      widget.jobsStream ?? JobService.streamAll();
  late final Stream<List<JobStatusDef>> _statusesStream =
      widget.statusesStream ?? StatusService.streamDefs();
  StreamSubscription<List<SmsMessage>>? _unreadSub;
  StreamSubscription<List<SmsMessage>>? _approvalSub;
  List<SmsMessage> _unreadMessages = const [];
  List<SmsMessage> _awaitingApproval = const [];

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Все визиты');
    if (widget.onLeave != null) {
      _scrollController.addListener(_rememberOffset);
    }
    _bindMessageStreams();
  }

  /// Запоминать место в `dispose` поздно: список размонтируется раньше
  /// экрана, и контроллер к этому моменту уже отцеплен.
  void _rememberOffset() {
    if (_scrollController.hasClients) _shadeOffset = _scrollController.offset;
  }

  void _bindMessageStreams() {
    if (TechnicianService.isTechnician) return;
    try {
      final unreadStream =
          widget.unreadMessagesStream ??
          (widget.jobsStream == null
              ? SmsService.streamUnreadInbound()
              : const Stream<List<SmsMessage>>.empty());
      _unreadSub = unreadStream.listen((items) {
        if (!mounted) return;
        setState(() => _unreadMessages = items);
      }, onError: (_) {});

      final approvalStream =
          widget.awaitingApprovalStream ??
          (widget.jobsStream == null
              ? SmsService.streamAwaitingApproval()
              : const Stream<List<SmsMessage>>.empty());
      _approvalSub = approvalStream.listen((items) {
        if (!mounted) return;
        setState(() => _awaitingApproval = items);
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _unreadSub?.cancel();
    _approvalSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  DateTime get _now => widget.referenceNow ?? DateTime.now();

  DateTime get _companyToday {
    final wall = AppTimeService.wallClock(_now);
    return DateTime(wall.year, wall.month, wall.day);
  }

  DateTime _dayOfVisit(DateTime startAt) {
    final wall = AppTimeService.wallClock(startAt);
    return DateTime(wall.year, wall.month, wall.day);
  }

  void _scrollToToday() {
    AppFeedback.pleasant();
    final todayCtx = _todayKey.currentContext;
    if (todayCtx != null) {
      Scrollable.ensureVisible(
        todayCtx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Закрывает шторку, ждёт конца её анимации и отдаёт контекст, по
  /// которому можно открывать экраны. Без закрытия карточка открылась бы
  /// под шторкой, а свой `context` к этому моменту уже мёртв.
  Future<BuildContext?> _leaveHost() async {
    final leave = widget.onLeave;
    if (leave == null) return mounted ? context : null;
    leave();
    await Future<void>.delayed(const Duration(milliseconds: 280));
    final host = widget.hostContext;
    if (host != null && host.mounted) return host;
    return mounted ? context : null;
  }

  Future<void> _openJob(Job job) async {
    AppFeedback.pleasant();
    final host = await _leaveHost();
    if (host == null) return;
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
      back: widget.onReturn,
    );
  }

  bool _messageMatchesJob(SmsMessage message, Job job) {
    final msgJobId = (message.jobId ?? '').trim();
    if (msgJobId.isNotEmpty) {
      return msgJobId == job.id;
    }
    final jobClientId = job.clientId.trim();
    final msgClientId = (message.clientId ?? '').trim();
    if (jobClientId.isNotEmpty && msgClientId == jobClientId) {
      return true;
    }
    final phones = <String>{
      if (SmsService.normalizePhone(job.clientPhone).length >= 10)
        SmsService.normalizePhone(job.clientPhone),
      if (SmsService.normalizePhone(job.jobSitePhone ?? '').length >= 10)
        SmsService.normalizePhone(job.jobSitePhone ?? ''),
    };
    if (phones.isNotEmpty) {
      final fromPhone = SmsService.normalizePhone(message.from);
      final toPhone = SmsService.normalizePhone(message.to);
      if (phones.contains(fromPhone) || phones.contains(toPhone)) {
        return true;
      }
    }
    final emails = <String>{
      if ((job.clientEmail ?? '').trim().contains('@'))
        SmsService.normalizeEmail(job.clientEmail!),
      if ((job.jobSiteEmail ?? '').trim().contains('@'))
        SmsService.normalizeEmail(job.jobSiteEmail!),
    };
    if (emails.isNotEmpty && message.isEmail) {
      final peerEmail = SmsService.normalizeEmail(message.counterpartEmail);
      if (emails.contains(peerEmail)) {
        return true;
      }
    }
    return false;
  }

  int _unreadCountForJob(Job job) {
    if (_unreadMessages.isEmpty) return 0;
    var count = 0;
    for (final m in _unreadMessages) {
      if (_messageMatchesJob(m, job)) count++;
    }
    return count;
  }

  int _pendingApprovalCountForEntry(_VisitAgendaEntry entry) {
    var count = 0;
    for (final m in _awaitingApproval) {
      if (_messageMatchesJob(m, entry.job)) count++;
    }
    if (entry.visit.bookingSmsState == 'pending') {
      count = math.max(count, 1);
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final today = _companyToday;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(context.tr('Все визиты', 'All visits')),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _scrollToToday,
            child: Text(
              'Сегодня'.tr,
              style: TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Назад'.tr,
            icon: Icon(
              widget.onLeave == null
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_right,
              size: 28,
            ),
            onPressed: () {
              AppFeedback.pleasant();
              final leave = widget.onLeave;
              if (leave != null) {
                leave();
                return;
              }
              Navigator.maybePop(context);
            },
          ),
        ],
      ),
      body: StreamBuilder<List<JobStatusDef>>(
        stream: _statusesStream,
        builder: (context, _) {
          return Column(
            children: [
              if (widget.showStatusFilters)
                JobStatusFilterBar(
                  selectedId: _selectedFilter,
                  onSelected: (next) {
                    if (_selectedFilter == next) return;
                    AppFeedback.pleasant();
                    setState(() => _selectedFilter = next);
                  },
                ),
              Expanded(
                child: StreamBuilder<List<Job>>(
                  stream: _jobsStream,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text('Ошибка загрузки списка работ'.tr),
                      );
                    }
                    if (!snapshot.hasData) {
                      return Center(
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                        ),
                      );
                    }

                    final allJobs = snapshot.data ?? const <Job>[];
                    final filteredJobs = allJobs
                        .where(
                          (job) =>
                              !job.isDeleted &&
                              SettingsService.jobMatchesListFilter(
                                job,
                                _selectedFilter,
                              ),
                        )
                        .toList();

                    var unscheduledCount = 0;
                    final byDay = <DateTime, List<_VisitAgendaEntry>>{};
                    for (final job in filteredJobs) {
                      if (job.isUnscheduled) {
                        unscheduledCount++;
                        continue;
                      }
                      final visit = job.latestVisit;
                      if (visit == null) continue;
                      final day = _dayOfVisit(visit.startAt);
                      byDay
                          .putIfAbsent(day, () => <_VisitAgendaEntry>[])
                          .add(_VisitAgendaEntry(job: job, visit: visit));
                    }

                    for (final list in byDay.values) {
                      list.sort(
                        (a, b) => a.visit.startAt.compareTo(b.visit.startAt),
                      );
                    }

                    final days = byDay.keys.toList()
                      ..sort((a, b) => b.compareTo(a));
                    if (days.isEmpty && unscheduledCount == 0) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _selectedFilter == SettingsService.listAllFilter
                                ? context.tr(
                                    'Нет назначенных визитов',
                                    'No scheduled visits',
                                  )
                                : 'Нет работ с таким статусом'.tr,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.inkMuted,
                              fontSize: 16,
                              height: 1.35,
                            ),
                          ),
                        ),
                      );
                    }

                    return CustomScrollView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (unscheduledCount > 0)
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                            sliver: SliverToBoxAdapter(
                              child: _buildUnscheduledBanner(unscheduledCount),
                            ),
                          ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            10,
                            unscheduledCount > 0 ? 0 : 8,
                            10,
                            88,
                          ),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final day = days[index];
                                return _buildDaySection(
                                  key: day == today ? _todayKey : null,
                                  day: day,
                                  entries: byDay[day]!,
                                  today: today,
                                );
                              },
                              childCount: days.length,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildUnscheduledBanner(int unscheduledCount) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            final host = await _leaveHost();
            if (host == null) return;
            // Через навигатор вкладки, как и карточка: по корневому экран
            // накрывал бы нижнюю панель, и возвращать шторку было бы некуда.
            final navigator = AppNav.navigatorOf(host);
            await PanelReturn.open(
              navigator,
              push: () => navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => const UnscheduledJobsScreen(),
                ),
              ),
              back: widget.onReturn,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.event_busy, size: 18, color: Colors.blue.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$unscheduledCount ${context.tr('без даты визита', 'unscheduled')}',
                    style: TextStyle(
                      color: Colors.blue.shade900,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: Colors.blue.shade800),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDaySection({
    Key? key,
    required DateTime day,
    required List<_VisitAgendaEntry> entries,
    required DateTime today,
  }) {
    final isToday = day == today;
    var completedCount = 0;
    for (final entry in entries) {
      if (JobStatuses.isCompletedStatus(entry.job.status)) {
        completedCount++;
      }
    }
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDayHeader(
            day: day,
            today: today,
            count: entries.length,
            completedCount: completedCount,
          ),
          const SizedBox(height: 5),
          ..._timelineRows(entries, isToday),
        ],
      ),
    );
  }

  String _formatDayTitle(DateTime day, DateTime today) {
    final loc = AppLocale.instance.dateLocale;
    final pattern = day.year == today.year ? 'EEE, d MMM' : 'EEE, d MMM y';
    String title;
    try {
      title = DateFormat(pattern, loc).format(day).replaceAll('.', '');
    } catch (_) {
      title = DateFormat(pattern).format(day).replaceAll('.', '');
    }
    if (title.isNotEmpty) {
      title = '${title[0].toUpperCase()}${title.substring(1)}';
    }
    return title;
  }

  Widget _buildDayHeader({
    required DateTime day,
    required DateTime today,
    required int count,
    required int completedCount,
  }) {
    final title = _formatDayTitle(day, today);
    final isToday = day == today;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isToday ? AppColors.primary : AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isToday ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.event,
            size: 14,
            color: isToday ? AppColors.accent : AppColors.primaryOnCard,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: isToday ? Colors.white : AppColors.primaryOnCard,
              ),
            ),
          ),
          if (completedCount > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '${context.tr('Завершено', 'Completed')}: $completedCount',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: isToday ? Colors.white70 : AppColors.inkMuted,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _timelineRows(List<_VisitAgendaEntry> entries, bool isToday) {
    final now = _now;
    var nowShown = !isToday;
    final rows = <Widget>[];
    // Идём сверху вниз от самых поздних визитов к самым ранним —
    // так шкала времени читается снизу вверх: раннее время внизу,
    // позднее наверху. Линия «сейчас» встаёт на границе между
    // будущими (выше) и прошедшими (ниже) визитами.
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (!nowShown && !entry.visit.startAt.isAfter(now)) {
        // Переход от будущих (выше) к прошедшим (ниже) — линия «сейчас»
        // встаёт над первым уже начавшимся визитом.
        rows.add(_nowRow(now));
        nowShown = true;
      }
      rows.add(_timelineEntry(entry, isLast: i == 0));
    }
    if (!nowShown) rows.add(_nowRow(now));
    return rows;
  }

  Widget _timelineEntry(_VisitAgendaEntry entry, {required bool isLast}) {
    final unreadCount = _unreadCountForJob(entry.job);
    final pendingCount = _pendingApprovalCountForEntry(entry);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 5),
      child: JobAgendaCard(
        job: entry.job,
        visit: entry.visit,
        forceCompact: true,
        showWorkState: true,
        showTime: true,
        unreadSmsCount: unreadCount,
        pendingSmsCount: pendingCount,
        onTap: () => _openJob(entry.job),
      ),
    );
  }

  Widget _nowRow(DateTime now) {
    const red = Color(0xFFE53935);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: SizedBox(
        height: 14,
        child: Row(
          children: [
            Text(
              Formatters.formatTime(now),
              style: const TextStyle(
                color: red,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: red,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(child: Container(height: 1.5, color: red)),
          ],
        ),
      ),
    );
  }
}

class _VisitAgendaEntry {
  final Job job;
  final JobVisit visit;

  const _VisitAgendaEntry({required this.job, required this.visit});
}

