import 'package:flutter/material.dart';
import '../../core/app_commands.dart';
import '../../core/utils/app_date_picker.dart';
import 'package:intl/intl.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../services/services.dart';
import '../../models/job.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/job_agenda_card.dart';
import '../../shared/widgets/job_status_filter_bar.dart';
import 'job_details/job_details_screen.dart';
import 'basket_screen.dart';
import 'route_map_view.dart';
import '../../services/error_log_service.dart';

class JobsScreen extends StatefulWidget {
  final bool? showRouteMap;
  final DateTime? routeDate;
  final ValueChanged<DateTime>? onRouteDateChanged;
  final bool hideRouteDateBar;
  final ValueChanged<RouteMapChrome?>? onRouteChromeChanged;
  final String selectedFilter;
  final ValueChanged<String> onFilterChanged;
  final bool showStatusFilters;

  const JobsScreen({
    super.key,
    this.showRouteMap,
    this.routeDate,
    this.onRouteDateChanged,
    this.hideRouteDateBar = false,
    this.onRouteChromeChanged,
    this.selectedFilter = SettingsService.listAllFilter,
    required this.onFilterChanged,
    this.showStatusFilters = true,
  });

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  static const int _pageCenter = 10000;

  bool _showRouteMap = false;
  late DateTime _origin;
  late DateTime _routeDate;
  late final PageController _pageController;
  late final Stream<List<Job>> _jobsStream = JobService.streamAll();
  late final _statusesStream = StatusService.streamDefs();
  bool _suppressPageSync = false;

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Заявки');
    _origin = _companyToday;
    _routeDate = _origin;
    _syncFromParent();
    _pageController = PageController(initialPage: _pageOf(_routeDate));
    if (widget.onRouteDateChanged != null) {
      AppCommands.calendarTodayTick.addListener(_onCalendarTodayTick);
    }
  }

  void _onCalendarTodayTick() {
    if (!mounted) return;
    _goToDay(_companyToday);
  }

  @override
  void dispose() {
    AppCommands.calendarTodayTick.removeListener(_onCalendarTodayTick);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(JobsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousDay = _dateOnly(_routeDate);
    final wasMap = _showRouteMap;
    _syncFromParent();
    if (_suppressPageSync) {
      _suppressPageSync = false;
      return;
    }
    final dayChanged = _dateOnly(_routeDate) != previousDay;
    final leftMap = wasMap && !_showRouteMap;
    final enteredMap = !wasMap && _showRouteMap;
    if (_showRouteMap && !enteredMap && !dayChanged) return;
    if (!_showRouteMap && !dayChanged && !leftMap) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPageToSelectedDay();
    });
  }

  DateTime get _companyToday {
    final now = AppTimeService.wallClock(DateTime.now());
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  int _pageOf(DateTime day) =>
      _pageCenter + _dateOnly(day).difference(_origin).inDays;

  DateTime _dayOf(int page) => _origin.add(Duration(days: page - _pageCenter));

  bool _isSameDay(DateTime startAt, DateTime day) {
    final a = AppTimeService.wallClock(startAt);
    return a.year == day.year && a.month == day.month && a.day == day.day;
  }

  void _syncFromParent() {
    if (widget.showRouteMap != null) _showRouteMap = widget.showRouteMap!;
    if (widget.routeDate != null) _routeDate = _dateOnly(widget.routeDate!);
  }

  void _syncPageToSelectedDay() {
    if (!_pageController.hasClients) return;
    final page = _pageOf(_routeDate);
    if (_pageController.page?.round() == page) return;
    _pageController.jumpToPage(page);
  }

  void _setRouteDate(DateTime value) {
    final next = _dateOnly(value);
    _suppressPageSync = true;
    widget.onRouteDateChanged?.call(next);
    setState(() => _routeDate = next);
  }

  void _goToDay(DateTime day, {bool animate = true}) {
    final next = _dateOnly(day);
    final page = _pageOf(next);
    _setRouteDate(next);
    if (!_pageController.hasClients) return;
    if (animate) {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(page);
    }
  }

  void _onPageChanged(int page) {
    final day = _dayOf(page);
    if (_dateOnly(_routeDate) == day) return;
    AppFeedback.pleasant();
    _setRouteDate(day);
  }

  List<Job> _activeJobsForDate(List<Job> jobs, DateTime date) {
    return JobService.activeForDay(
      jobs
          .where(
            (job) => SettingsService.jobMatchesListFilter(
              job,
              widget.selectedFilter,
            ),
          )
          .toList(),
      date,
      includeClosed: true,
    );
  }

  String _formatRouteDate(DateTime date) {
    return DateFormat(
      'd MMM',
      AppLocale.instance.isEn ? 'en' : 'ru',
    ).format(date).replaceAll('.', '');
  }

  Future<void> _pickRouteDate() async {
    final picked = await showAppDateSheet(
      context: context,
      initial: _routeDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      _goToDay(picked, animate: false);
    }
  }

  void _nudgeRouteDay(int delta) {
    if (delta == 0) return;
    _goToDay(_routeDate.add(Duration(days: delta)));
  }

  Widget _buildRouteDateBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 260) return;
        _nudgeRouteDay(velocity < 0 ? 1 : -1);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            _dateArrow(
              icon: Icons.chevron_left,
              onPressed: () => _nudgeRouteDay(-1),
            ),
            Expanded(
              child: GestureDetector(
                onTap: _pickRouteDate,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.calendar_today,
                      size: 14,
                      color: AppColors.primaryOnCard,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatRouteDate(_routeDate),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _dateArrow(
              icon: Icons.chevron_right,
              onPressed: () => _nudgeRouteDay(1),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<JobStatusDef>>(
        stream: _statusesStream,
        builder: (context, _) {
          return Column(
            children: [
              if (_showRouteMap) ...[
                if (!widget.hideRouteDateBar) _buildRouteDateBar(),
                Expanded(
                  child: StreamBuilder<List<Job>>(
                    stream: _jobsStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return Center(
                          child: CircularProgressIndicator(
                            color: AppColors.accent,
                          ),
                        );
                      }
                      final allJobs = snapshot.data ?? [];
                      return PageView.builder(
                        controller: _pageController,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, page) {
                          final day = _dayOf(page);
                          if (_dateOnly(day) != _dateOnly(_routeDate)) {
                            return _routeNeighborPage(allJobs, day);
                          }
                          return RouteMapView(
                            key: ValueKey(
                              '${day.year}-${day.month}-${day.day}',
                            ),
                            jobs: _activeJobsForDate(allJobs, day),
                            day: day,
                            onChromeChanged: widget.onRouteChromeChanged,
                          );
                        },
                      );
                    },
                  ),
                ),
              ] else ...[
                if (widget.showStatusFilters)
                  JobStatusFilterBar(
                    selectedId: widget.selectedFilter,
                    onSelected: widget.onFilterChanged,
                  ),
                _buildDayHeader(),

                // Один день на экран, горизонтальный свайп листает дни.
                Expanded(
                  child: StreamBuilder<List<Job>>(
                    stream: _jobsStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return Center(
                          child: CircularProgressIndicator(
                            color: AppColors.accent,
                          ),
                        );
                      }

                      if (snapshot.hasError) {
                        return Center(
                          child: Text('Ошибка загрузки списка работ'.tr),
                        );
                      }

                      final allJobs = snapshot.data ?? [];
                      if (allJobs.isEmpty) {
                        return _buildEmptyState();
                      }

                      final filteredJobs = allJobs
                          .where(
                            (job) => SettingsService.jobMatchesListFilter(
                              job,
                              widget.selectedFilter,
                            ),
                          )
                          .toList();

                      if (filteredJobs.isEmpty) {
                        return Center(
                          child: Text('Нет работ с таким статусом'.tr),
                        );
                      }

                      return PageView.builder(
                        controller: _pageController,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, page) {
                          return _buildDayList(filteredJobs, _dayOf(page));
                        },
                      );
                    },
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _routeNeighborPage(List<Job> allJobs, DateTime day) {
    final count = _activeJobsForDate(allJobs, day).length;
    return ColoredBox(
      color: AppColors.surface,
      child: Center(
        child: Text(
          '${_formatRouteDate(day)}\n$count',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.primaryOnCard,
            fontWeight: FontWeight.w800,
            fontSize: 18,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.build_circle_outlined,
            size: 80,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            'Нет активных работ.\nСоздайте их кнопкой ниже.'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _dateArrow({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    final arrow = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Icon(icon, color: AppColors.primaryOnCard, size: 28),
      ),
    );
    if (tooltip == null || tooltip.isEmpty) return arrow;
    return Tooltip(message: tooltip, child: arrow);
  }

  Widget _buildDayHeader() {
    final day = _dateOnly(_routeDate);
    final today = _companyToday;
    final loc = AppLocale.instance.dateLocale;
    var title = DateFormat('EEEE, d MMMM', loc).format(day);
    if (title.isNotEmpty) {
      title = '${title[0].toUpperCase()}${title.substring(1)}';
    }
    final isToday = day == today;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          _dateArrow(
            tooltip: 'Предыдущий день'.tr,
            icon: Icons.chevron_left,
            onPressed: () => _goToDay(day.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: GestureDetector(
              onTap: _pickRouteDate,
              child: Column(
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                  if (isToday)
                    Text(
                      'Сегодня'.tr,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.inkMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!isToday)
            TextButton(
              onPressed: () => _goToDay(today),
              child: Text('Сегодня'.tr),
            ),
          _dateArrow(
            tooltip: 'Следующий день'.tr,
            icon: Icons.chevron_right,
            onPressed: () => _goToDay(day.add(const Duration(days: 1))),
          ),
        ],
      ),
    );
  }

  Widget _buildDayList(List<Job> jobs, DateTime day) {
    final entries = <_AgendaEntry>[];
    final isToday = day == _companyToday;
    var unscheduledCount = 0;
    for (final job in jobs) {
      if (job.isUnscheduled) {
        unscheduledCount++;
        continue;
      }
      final visits = job.coalescedVisits;
      for (final visit in visits) {
        if (_isSameDay(visit.startAt, day)) {
          entries.add(_AgendaEntry(job: job, visit: visit));
        }
      }
    }
    entries.sort((a, b) => a.visit.startAt.compareTo(b.visit.startAt));
    final dateOnlyEntries = [
      for (final entry in entries)
        if (!entry.visit.hasTime) entry,
    ];
    final timedEntries = [
      for (final entry in entries)
        if (entry.visit.hasTime) entry,
    ];

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (unscheduledCount > 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Material(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UnscheduledJobsScreen(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.event_busy, color: Colors.blue.shade800),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '$unscheduledCount ${context.tr('без даты визита', 'unscheduled')}',
                            style: TextStyle(
                              color: Colors.blue.shade900,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: Colors.blue.shade800),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (dateOnlyEntries.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              14,
              10,
              14,
              timedEntries.isEmpty ? 88 : 4,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                for (var i = 0; i < dateOnlyEntries.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == dateOnlyEntries.length - 1 ? 0 : 8,
                    ),
                    child: JobAgendaCard(
                      job: dateOnlyEntries[i].job,
                      visit: dateOnlyEntries[i].visit,
                      showTime: false,
                      onTap: () => _openJob(dateOnlyEntries[i].job),
                    ),
                  ),
              ]),
            ),
          ),
        if (entries.isEmpty && unscheduledCount == 0)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                isToday
                    ? 'Сегодня нет заявок'.tr
                    : 'Нет заявок на этот день'.tr,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
              ),
            ),
          )
        else if (timedEntries.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 14, 88),
            sliver: SliverList(
              delegate: SliverChildListDelegate(
                _timelineRows(timedEntries, isToday),
              ),
            ),
          ),
      ],
    );
  }

  DateTime _entryEnd(_AgendaEntry entry) {
    final minutes = entry.visit.durationMinutes > 0
        ? entry.visit.durationMinutes
        : entry.job.durationMinutes;
    return entry.visit.startAt.add(Duration(minutes: minutes.clamp(15, 480)));
  }

  /// Шкала времени слева: начало и конец визита, свободные окна между
  /// визитами и красная черта «сейчас» на сегодняшнем дне.
  List<Widget> _timelineRows(List<_AgendaEntry> entries, bool isToday) {
    final now = DateTime.now();
    var nowShown = !isToday;
    final rows = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!nowShown && entry.visit.startAt.isAfter(now)) {
        rows.add(_nowRow(now));
        nowShown = true;
      }
      if (i > 0) {
        final gap = entry.visit.startAt.difference(_entryEnd(entries[i - 1]));
        if (gap.inMinutes >= 60) rows.add(_gapRow(gap));
      }
      rows.add(_timelineEntry(entry, isLast: i == entries.length - 1));
    }
    if (!nowShown) rows.add(_nowRow(now));
    return rows;
  }

  static const double _gutter = 64;

  Widget _timelineEntry(_AgendaEntry entry, {required bool isLast}) {
    final color = StatusService.colorOf(
      entry.job.displayStatusForVisit(entry.visit),
    );
    final line = Colors.grey.shade300;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _gutter,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, right: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          entry.visit.hasTime
                              ? Formatters.formatTime(entry.visit.startAt)
                              : '—',
                          maxLines: 1,
                          style: TextStyle(
                            color: AppColors.primaryOnCard,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                            height: 1.1,
                          ),
                        ),
                        if (entry.visit.hasTime)
                          Text(
                            Formatters.formatTime(_entryEnd(entry)),
                            maxLines: 1,
                            style: TextStyle(
                              color: AppColors.inkMuted,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 12,
                  child: Stack(
                    alignment: Alignment.topCenter,
                    children: [
                      Positioned(
                        top: 0,
                        bottom: 0,
                        child: Container(width: 2, color: line),
                      ),
                      Positioned(
                        top: 6,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
              child: JobAgendaCard(
                job: entry.job,
                visit: entry.visit,
                showTime: false,
                onTap: () => _openJob(entry.job),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gutterLine({double height = 28, Widget? child}) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: _gutter,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 2,
                margin: const EdgeInsets.only(right: 5),
                color: Colors.grey.shade300,
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (child != null) Expanded(child: child),
        ],
      ),
    );
  }

  Widget _gapRow(Duration gap) {
    final hours = gap.inMinutes ~/ 60;
    final minutes = gap.inMinutes % 60;
    final label = minutes == 0
        ? '$hours ${'ч'.tr}'
        : '$hours ${'ч'.tr} $minutes ${'мин'.tr}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _gutterLine(
        child: Row(
          children: [
            Icon(Icons.free_breakfast_outlined,
                size: 16, color: Colors.grey.shade500),
            const SizedBox(width: 6),
            Text(
              '${'Свободно'.tr} · $label',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nowRow(DateTime now) {
    const red = Color(0xFFE53935);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 16,
        child: Row(
          children: [
            SizedBox(
              width: _gutter - 12,
              child: Text(
                Formatters.formatTime(now),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: red,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: red,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(child: Container(height: 2, color: red)),
          ],
        ),
      ),
    );
  }

  Future<void> _openJob(Job job) async {
    AppFeedback.pleasant();
    await AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (context) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
      ),
    );
    if (!mounted) return;
    await JobService.getById(job.id);
  }

}

class _AgendaEntry {
  final Job job;
  final JobVisit visit;
  _AgendaEntry({required this.job, required this.visit});
}
