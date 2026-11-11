import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../models/calendar_event.dart';
import '../../models/job.dart';
import '../../services/calendar_event_service.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';
import '../../services/app_time_service.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/create_job_screen.dart';
import '../jobs/jobs_screen.dart';
import '../care_plan/care_plan_widgets.dart';
import 'calendar_top_icons.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../../shared/widgets/calendar_hatch.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import 'calendar_card_shape.dart';
import 'visit_link_overlay.dart';
import 'now_time_overlay.dart';
import 'calendar_event_sheet.dart';
import '../../services/error_log_service.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> with UiSettingsAware {
  final CalendarController _calendarController = CalendarController();
  final VisitLinkHub _visitLinkHub = VisitLinkHub();
  final NowLineController _nowLine = NowLineController();
  final GlobalKey _visitLinkOverlayKey = GlobalKey();
  StreamSubscription? _configSub;
  StreamSubscription? _eventsSub;
  List<CalendarEvent> _events = const [];

  static const String _visitLinksPrefKey = 'calendarShowVisitLinks';
  static const double _calendarHeaderHeight = 24;
  static const double _calendarViewHeaderHeight = 42;
  static const double _timeRulerWidth = 52;
  static const int _kBasePage = 1200;

  int _firstDayOfWeek = 1; // 1 = Понедельник
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  int _defaultDurationMinutes = SettingsService.defaultJobDurationMinutes;
  Map<String, dynamic> _scheduleConfig = const {};
  bool _isLoadingSettings = true;
  bool _showList = true;
  bool _showRouteMap = false;
  bool _appliedDefaultView = false;
  bool _showVisitLinks = true;
  VisitLinkCatalog? _linkCatalog;
  String _defaultViewMode = SettingsService.defaultCalendarView;

  DateTime? _lastDragSnap;
  DateTime _focusDate = DateTime.now();
  DateTime _pageOriginDate = DateTime.now();
  int _currentPageIndex = _kBasePage;
  int _pagerGeneration = 0;
  PageController _pageController = PageController(initialPage: _kBasePage);
  double? _savedVerticalOffset;
  late final Stream<QuerySnapshot> _jobsSnap;
  late final _statusesStream = StatusService.streamDefs();
  double _calendarViewHeight = 600;
  List<TimeRegion> _cachedRegions = const [];
  int _regionsStamp = 0;

  static Color get _nonWorkingHourColor => AppColors.nonWorkingHour;
  static Color get _dayOffColor =>
      AppColors.isDark ? AppColors.nonWorkingHour : const Color(0xFFEBEDF1);

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Календарь');
    _calendarController.view = CalendarView.week;
    _jobsSnap = FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('jobs')
        .snapshots();
    _listenCalendarSettings();
    _eventsSub = CalendarEventService.stream().listen((events) {
      if (!mounted) return;
      setState(() => _events = events);
    });
    _loadVisitLinksPref();
    AppCommands.calendarMode.addListener(_onCalendarCommand);
    AppCommands.calendarTodayTick.addListener(_onJumpCalendarToday);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishHomeState();
    });
  }

  void _publishHomeState() {
    final atHome = _currentViewMode == _defaultViewMode;
    if (AppCommands.calendarAtHome.value != atHome) {
      AppCommands.calendarAtHome.value = atHome;
    }
  }

  void _onCalendarCommand() {
    final mode = AppCommands.calendarMode.value;
    if (mode == null || !mounted) return;
    AppCommands.calendarMode.value = null;
    _selectCalendarMode(mode);
  }

  void _onJumpCalendarToday() {
    if (!mounted) return;
    final today = _todayDate();
    setState(() {
      _focusDate = today;
      if (_showList) return;
      _calendarController.displayDate = DateTime(
        today.year,
        today.month,
        today.day,
        2,
      );
      _resetHourlyPager(today);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_showList && _calendarController.view != CalendarView.month) {
        _scrollWorkHoursIntoView();
      }
      if (_visitLinksEnabled) _visitLinkHub.bump();
      _nowLine.bump();
    });
  }

  void _listenCalendarSettings() {
    _configSub = FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('settings')
        .doc('config')
        .snapshots()
        .listen(
          (doc) {
            if (!mounted) return;
            final data = doc.data() ?? <String, dynamic>{};
            AppTimeService.applyConfig(data);
            final defaultView = SettingsService.readDefaultCalendarView(data);
            setState(() {
              _scheduleConfig = data;
              _firstDayOfWeek = (data['firstDayOfWeek'] as num?)?.toInt() ?? 1;
              _workStartMinutes = SettingsService.readWorkStartMinutes(data);
              _workEndMinutes = SettingsService.readWorkEndMinutes(data);
              _defaultDurationMinutes = SettingsService.readJobDurationMinutes(
                data,
              );
              _defaultViewMode = defaultView;
              // Неделя и 5 дней — отдельные виды. Не схлопывать week в workWeek.
              _isLoadingSettings = false;
            });
            if (!_appliedDefaultView) {
              _appliedDefaultView = true;
              _selectCalendarMode(defaultView);
            } else {
              _publishHomeState();
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_showList) _scrollWorkHoursIntoView();
            });
          },
          onError: (e) {
            debugPrint('Ошибка загрузки настроек: $e');
            if (mounted) setState(() => _isLoadingSettings = false);
          },
        );
  }

  @override
  void dispose() {
    AppCommands.calendarMode.removeListener(_onCalendarCommand);
    AppCommands.calendarTodayTick.removeListener(_onJumpCalendarToday);
    _configSub?.cancel();
    _eventsSub?.cancel();
    _pageController.dispose();
    _visitLinkHub.dispose();
    _nowLine.dispose();
    _calendarController.dispose();
    super.dispose();
  }

  bool get _visitLinksViewOk {
    final view = _calendarController.view;
    // Месяц нужен для пункта 10: связанные заявки через неделю, две или три
    // месяца в режиме недели просто не попадают на экран вместе, и линию
    // между ними нарисовать физически нельзя. В месяце обе карточки видны.
    return !_showList &&
        (view == CalendarView.week ||
            view == CalendarView.workWeek ||
            view == CalendarView.month);
  }

  bool get _visitLinksEnabled => _visitLinksViewOk && _showVisitLinks;

  /// В часовых видах рисуем квадратные карточки: 37×37 в 5 днях / неделе
  /// и 50×50 в виде на 1 день, с адаптивным раздвижением часа по высоте.
  bool get _squareCardView {
    final view = _calendarController.view;
    return view == CalendarView.day ||
        view == CalendarView.week ||
        view == CalendarView.workWeek;
  }

  double get _currentCardSide =>
      _calendarController.view == CalendarView.day
          ? kCalendarDayCardSide
          : kCalendarCardSide;

  int _cardMinutes(int realMinutes) => _squareCardView ? 60 : realMinutes;

  bool get _nowLineViewOk {
    final view = _calendarController.view;
    return !_showList &&
        (view == CalendarView.day ||
            view == CalendarView.week ||
            view == CalendarView.workWeek);
  }

  Future<void> _loadVisitLinksPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showVisitLinks = prefs.getBool(_visitLinksPrefKey) ?? true;
    });
  }

  Future<void> _setShowVisitLinks(bool value) async {
    if (_showVisitLinks == value) return;
    setState(() => _showVisitLinks = value);
    if (!value) {
      _visitLinkHub.clear();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _visitLinkHub.bump();
      });
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_visitLinksPrefKey, value);
  }

  Widget _visitLinksToggle() {
    final on = _showVisitLinks;
    return Material(
      color: on ? const Color(0xFF008F3B) : const Color(0xFF9AA3B0),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          AppFeedback.pleasant();
          _setShowVisitLinks(!on);
        },
        child: const SizedBox(
          width: 34,
          height: 28,
          child: Icon(Icons.timeline, size: 18, color: Colors.white),
        ),
      ),
    );
  }

  List<TimeRegion> _nonWorkingRegions() {
    final today = DateTime.now();
    final stamp = Object.hash(
      _workStartMinutes,
      _workEndMinutes,
      SettingsService.readWorkDays(_scheduleConfig).join(','),
      SettingsService.readHolidayDates(_scheduleConfig).join(','),
      Object.hashAll(SettingsService.readVacationRanges(_scheduleConfig)),
      today.year,
      today.month,
      today.day,
    );
    if (stamp == _regionsStamp && _cachedRegions.isNotEmpty) {
      return _cachedRegions;
    }
    _regionsStamp = stamp;
    final startDay = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 60));
    final regions = <TimeRegion>[];

    for (var i = 0; i < 150; i++) {
      final day = startDay.add(Duration(days: i));
      final dayStart = DateTime(day.year, day.month, day.day);

      // Выходной, праздник или отпуск — гасим весь день, а не только часы.
      if (!SettingsService.isVisitDay(_scheduleConfig, dayStart)) {
        regions.add(
          TimeRegion(
            startTime: dayStart,
            endTime: dayStart.add(const Duration(days: 1)),
            color: _dayOffColor,
            enablePointerInteraction: true,
          ),
        );
        continue;
      }

      if (_workStartMinutes > 0) {
        regions.add(
          TimeRegion(
            startTime: dayStart,
            endTime: dayStart.add(Duration(minutes: _workStartMinutes)),
            color: _nonWorkingHourColor,
            enablePointerInteraction: true,
          ),
        );
      }

      if (_workEndMinutes < 24 * 60) {
        regions.add(
          TimeRegion(
            startTime: dayStart.add(Duration(minutes: _workEndMinutes)),
            endTime: dayStart.add(const Duration(days: 1)),
            color: _nonWorkingHourColor,
            enablePointerInteraction: true,
          ),
        );
      }
    }

    _cachedRegions = regions;
    return regions;
  }

  Color _appointmentColor(Job job, JobVisit visit) {
    final status = job.displayStatusForVisit(visit);
    if (JobStatuses.isCancelledStatus(status)) {
      return StatusService.colorOf(JobStatuses.cancelled);
    }
    if (status == JobStatuses.rescheduled) {
      return StatusService.colorOf(JobStatuses.rescheduled);
    }
    if (status == JobStatuses.waitingPart) {
      return StatusService.colorOf(JobStatuses.waitingPart);
    }
    if (JobStatuses.isCompletedStatus(status)) {
      return StatusService.colorOf(JobStatuses.completed);
    }
    return StatusService.colorOf(status);
  }

  bool _showJobOnCalendar(Job job) => !job.isDeleted;

  /// Пункт 1: перетаскивание прилипает к четверти часа — 7:00, 7:15, 7:30…
  /// Календарь отдаёт произвольную минуту, зависящую от пикселя, куда попал
  /// палец, поэтому округляем сами.
  static const int kDragSnapMinutes = 15;

  static DateTime _snapToQuarterHour(DateTime time) {
    final base = DateTime(time.year, time.month, time.day);
    final minutes = time.difference(base).inMinutes;
    final snapped = ((minutes / kDragSnapMinutes).round()) * kDragSnapMinutes;
    return base.add(Duration(minutes: snapped));
  }

  /// Пункт 19: «Готово» и «Отменено» двигать нельзя — работа уже закрыта.
  /// Заявки в работе тащить можно, но с подтверждением переноса.
  bool _visitDragLocked(Job? job, JobVisit? visit) {
    final status = (job?.status ?? '').trim();
    if (status.isNotEmpty) {
      return JobStatuses.isCompletedStatus(status) ||
          JobStatuses.isCancelledStatus(status);
    }
    return visit != null && (visit.isDone || visit.isCancelled);
  }

  void _warnDragLocked() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Закрытую заявку нельзя перенести'.tr),
        backgroundColor: Colors.orange.shade800,
      ),
    );
  }

  /// Отказ от переноса: Syncfusion уже сдвинул карточку внутри себя, поэтому
  /// перерисовываем список из снапшота, чтобы она вернулась на место.
  void _snapCardBack() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visitLinksEnabled) _visitLinkHub.bump();
    });
  }

  IconData get _viewChipIcon {
    switch (_currentViewMode) {
      case 'day':
        return Icons.view_day_outlined;
      case 'month':
        return Icons.calendar_month_outlined;
      case 'list':
        return Icons.view_agenda_outlined;
      case 'route':
        return Icons.route;
      default:
        return Icons.calendar_view_week;
    }
  }

  Widget _viewButton() {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _showViewPicker,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(_viewChipIcon, color: Colors.white, size: 26),
        ),
      ),
    );
  }

  String get _currentViewMode {
    if (_showList && _showRouteMap) return 'route';
    if (_showList) return 'list';
    final view = _calendarController.view ?? CalendarView.week;
    if (view == CalendarView.month) return 'month';
    if (view == CalendarView.day) return 'day';
    if (view == CalendarView.week) return 'week';
    return 'workWeek';
  }

  DateTime _todayDate() {
    final now = AppTimeService.wallClock(DateTime.now());
    return DateTime(now.year, now.month, now.day);
  }

  void _resetHourlyPager(DateTime focus) {
    _pageOriginDate = DateTime(focus.year, focus.month, focus.day);
    _currentPageIndex = _kBasePage;
    _savedVerticalOffset = null;
    if (_pageController.hasClients && _pageController.positions.length == 1) {
      _pageController.jumpToPage(_kBasePage);
    } else {
      _pagerGeneration++;
      _pageController.dispose();
      _pageController = PageController(initialPage: _kBasePage);
    }
  }

  List<DateTime> _visibleDatesForPage(int pageIndex, CalendarView view) {
    final delta = pageIndex - _kBasePage;
    if (view == CalendarView.day) {
      return [
        DateTime(
          _pageOriginDate.year,
          _pageOriginDate.month,
          _pageOriginDate.day + delta,
        ),
      ];
    }
    final ref = DateTime(
      _pageOriginDate.year,
      _pageOriginDate.month,
      _pageOriginDate.day + delta * 7,
    );
    final firstDay = view == CalendarView.workWeek ? 1 : _firstDayOfWeek;
    final start = calendarVisibleStart(
      displayDate: ref,
      view: view,
      firstDayOfWeek: firstDay,
    );
    final count = view == CalendarView.workWeek ? 5 : 7;
    return [
      for (var i = 0; i < count; i++)
        DateTime(start.year, start.month, start.day + i),
    ];
  }

  void _selectCalendarMode(String newValue) {
    var mode = newValue;
    _focusDate = _todayDate();
    if (mode == 'home') {
      mode = _defaultViewMode;
    }
    setState(() {
      if (mode == 'list' || mode == 'route') {
        _showList = true;
        _showRouteMap = mode == 'route';
        return;
      }
      _showList = false;
      _showRouteMap = false;
      _calendarController.displayDate = DateTime(
        _focusDate.year,
        _focusDate.month,
        _focusDate.day,
        2,
      );
      final view = mode == 'day'
          ? CalendarView.day
          : mode == 'week'
          ? CalendarView.week
          : mode == 'month'
          ? CalendarView.month
          : CalendarView.workWeek;
      _calendarController.view = view;
      _resetHourlyPager(_focusDate);
    });
    _publishHomeState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_showList &&
          _calendarController.view != CalendarView.month) {
        _scrollWorkHoursIntoView();
      }
    });
  }

  Future<void> _showViewPicker() async {
    final current = _currentViewMode;
    const options = <({String id, String label, IconData icon})>[
      (id: 'day', label: '1 день', icon: Icons.view_day_outlined),
      (id: 'workWeek', label: '5 дней', icon: Icons.view_week_outlined),
      (id: 'week', label: 'Неделя', icon: Icons.calendar_view_week),
      (id: 'month', label: 'Календарь', icon: Icons.calendar_month),
      (id: 'route', label: 'Маршрут', icon: Icons.route),
      (id: 'list', label: 'Список', icon: Icons.view_agenda_outlined),
    ];
    final selected = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Вид календаря'.tr,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.55,
                    children: [
                      for (final option in options)
                        Material(
                          color: current == option.id
                              ? AppColors.accent
                              : AppColors.cardMuted,
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => Navigator.pop(sheetContext, option.id),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    option.icon,
                                    size: 30,
                                    color: current == option.id
                                        ? Colors.black
                                        : AppColors.primaryOnCard,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    option.label.tr,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: current == option.id
                                          ? Colors.black
                                          : AppColors.ink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (selected != null && mounted) _selectCalendarMode(selected);
  }

  double get _fittedSlotHeight {
    final usable =
        (_calendarViewHeight -
                _calendarHeaderHeight -
                _calendarViewHeaderHeight)
            .clamp(240.0, 4000.0);
    const visibleHours = 16.5;
    return (usable / visibleHours).clamp(kMinCalendarHourHeight, 44.0);
  }

  void _scrollWorkHoursIntoView() {
    final base = _calendarController.displayDate ?? _focusDate;
    _calendarController.displayDate = DateTime(
      base.year,
      base.month,
      base.day,
      2,
    );
    _savedVerticalOffset = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingSettings) {
      return const AppLoading();
    }

    return Stack(
      children: [
        Column(
          children: [
            // --- ВЕРХНЯЯ ПАНЕЛЬ С ВЫБОРОМ ВИДА ---
            Container(
              height: 42,
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              color: AppColors.primary,
              child: Row(
                children: [
                  _viewButton(),
                  const Spacer(),
                  const CalendarTopIcons(color: Colors.white, iconSize: 24),
                ],
              ),
            ),

            // --- САМ КАЛЕНДАРЬ И ЕГО ДАННЫЕ ---
            Expanded(
              child: _showList
                  ? JobsScreen(
                      showRouteMap: _showRouteMap,
                      routeDate: _focusDate,
                      onRouteDateChanged: (value) =>
                          setState(() => _focusDate = value),
                      hideRouteDateBar: !_showRouteMap,
                      onFilterChanged: (_) {},
                      showStatusFilters: false,
                    )
                  : StreamBuilder<List<JobStatusDef>>(
                      stream: _statusesStream,
                      builder: (context, statusSnap) {
                        return StreamBuilder<QuerySnapshot>(
                          stream: _jobsSnap,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(child: Text('Ошибка загрузки'.tr));
                            }
                            if (!snapshot.hasData) {
                              return const AppLoading();
                            }

                            List<Appointment> appointments = [];
                            final activeAppointmentIds = <String>{};
                            // Настоящая длительность визита: календарю мы её
                            // не отдаём (там карточка — квадрат), а переносу
                            // и проверке пересечений она нужна.
                            final realMinutesById = <String, int>{};
                            final docsById = <String, QueryDocumentSnapshot>{};
                            for (final doc in snapshot.data!.docs) {
                              docsById[doc.id] = doc;
                              final data = doc.data() as Map<String, dynamic>;
                              Job job;
                              try {
                                job = Job.fromMap(data, doc.id);
                              } catch (_) {
                                continue;
                              }
                              if (!_showJobOnCalendar(job)) {
                                continue;
                              }
                              if (job.isUnscheduled) continue;
                              activeAppointmentIds.addAll(
                                job.activeVisits.map(
                                  (visit) =>
                                      JobVisit.appointmentId(doc.id, visit.id),
                                ),
                              );
                              for (final visit in job.coalescedVisits) {
                                final minutes =
                                    (visit.durationMinutes > 0
                                            ? visit.durationMinutes
                                            : _defaultDurationMinutes)
                                        .clamp(15, 8 * 60);
                                final appointmentId = JobVisit.appointmentId(
                                  doc.id,
                                  visit.id,
                                );
                                realMinutesById[appointmentId] = minutes;
                                final isDateOnly = !visit.hasTime;
                                final effectiveStart = isDateOnly
                                    ? DateTime(
                                        visit.startAt.year,
                                        visit.startAt.month,
                                        visit.startAt.day,
                                      )
                                    : visit.startAt;
                                appointments.add(
                                  Appointment(
                                    startTime: effectiveStart,
                                    endTime: effectiveStart.add(
                                      Duration(minutes: _cardMinutes(minutes)),
                                    ),
                                    isAllDay: isDateOnly,
                                    color: _appointmentColor(job, visit),
                                    id: appointmentId,
                                    notes: visit.note,
                                  ),
                                );
                              }
                            }
                            for (final event in _events) {
                              final eventAppointmentId =
                                  CalendarEvent.appointmentIdOf(event.id);
                              activeAppointmentIds.add(eventAppointmentId);
                              final eventMinutes = event.endAt
                                  .difference(event.startAt)
                                  .inMinutes
                                  .clamp(15, 8 * 60);
                              realMinutesById[eventAppointmentId] =
                                  eventMinutes;
                              appointments.add(
                                Appointment(
                                  startTime: event.startAt,
                                  endTime: event.startAt.add(
                                    Duration(
                                      minutes: _cardMinutes(eventMinutes),
                                    ),
                                  ),
                                  subject: '',
                                  color: event.priority.color,
                                  id: eventAppointmentId,
                                  notes: event.photoUrl,
                                ),
                              );
                            }

                            // Квадрат короткой заявки растёт вниз, в пустое
                            // время. Чтобы он не наехал на соседнюю карточку,
                            // держим под рукой ближайшее следующее начало дня.
                            final startsByDay = <DateTime, List<DateTime>>{};
                            for (final app in appointments) {
                              if (app.isAllDay) continue;
                              final start = app.startTime;
                              final day = DateTime(
                                start.year,
                                start.month,
                                start.day,
                              );
                              startsByDay
                                  .putIfAbsent(day, () => <DateTime>[])
                                  .add(start);
                            }
                            for (final starts in startsByDay.values) {
                              starts.sort();
                            }
                            double freeMinutesAfter(DateTime start) {
                              final day = DateTime(
                                start.year,
                                start.month,
                                start.day,
                              );
                              for (final other
                                  in startsByDay[day] ?? const <DateTime>[]) {
                                if (other.isAfter(start)) {
                                  return other
                                      .difference(start)
                                      .inMinutes
                                      .toDouble();
                                }
                              }
                              return day
                                  .add(const Duration(days: 1))
                                  .difference(start)
                                  .inMinutes
                                  .toDouble();
                            }

                            final currentView =
                                _calendarController.view ?? CalendarView.week;
                            final hourlyDates = _squareCardView
                                ? _visibleDatesForPage(
                                    _currentPageIndex,
                                    currentView,
                                  )
                                : const <DateTime>[];
                            final jobAppointments = [
                              for (final app in appointments)
                                if (!CalendarEvent.isAppointmentId(app.id)) app,
                            ];
                            final linkCatalog =
                                VisitLinkCatalog.fromAppointments(
                                  jobAppointments,
                                  visibleStart: hourlyDates.isNotEmpty
                                      ? hourlyDates.first
                                      : calendarVisibleStart(
                                          displayDate:
                                              _calendarController.displayDate,
                                          view: currentView,
                                          firstDayOfWeek: _firstDayOfWeek,
                                        ),
                                  visibleDays: hourlyDates.isNotEmpty
                                      ? hourlyDates.length
                                      : calendarVisibleDayCount(currentView),
                                );
                            _linkCatalog = linkCatalog;

                            // Плашка «N без даты визита» переехала в
                            // колокольчик: календарь показывает календарь.
                            return Column(
                              children: [
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      _calendarViewHeight =
                                          constraints.maxHeight;
                                      final slotHeight = _fittedSlotHeight;
                                      return RepaintBoundary(
                                        child:
                                            NotificationListener<
                                              ScrollNotification
                                            >(
                                              onNotification: (notification) {
                                                if (_visitLinksEnabled) {
                                                  _visitLinkHub.bump();
                                                }
                                                _nowLine.onScroll(notification);
                                                return false;
                                              },
                                              child: Stack(
                                                key: _visitLinkOverlayKey,
                                                clipBehavior: Clip.hardEdge,
                                                children: [
                                                  Positioned.fill(
                                                    child: _squareCardView
                                                        ? _buildHourlyCalendar(
                                                            view: currentView,
                                                            baseHourHeight:
                                                                slotHeight,
                                                            appointments:
                                                                appointments,
                                                            activeAppointmentIds:
                                                                activeAppointmentIds,
                                                            realMinutesById:
                                                                realMinutesById,
                                                            docsById: docsById,
                                                          )
                                                        : _buildMonthSfCalendar(
                                                            slotHeight:
                                                                slotHeight,
                                                            appointments:
                                                                appointments,
                                                            activeAppointmentIds:
                                                                activeAppointmentIds,
                                                            realMinutesById:
                                                                realMinutesById,
                                                            docsById: docsById,
                                                            freeMinutesAfter:
                                                                freeMinutesAfter,
                                                          ),
                                                  ),
                                                  if (_nowLineViewOk)
                                                    Positioned.fill(
                                                      child: NowTimeOverlay(
                                                        controller: _nowLine,
                                                        overlayKey:
                                                            _visitLinkOverlayKey,
                                                        slotHeight: slotHeight,
                                                      ),
                                                    ),
                                                  if (_visitLinksEnabled)
                                                    Positioned.fill(
                                                      child: IgnorePointer(
                                                        child: CustomPaint(
                                                          painter: VisitLinkPainter(
                                                            hub: _visitLinkHub,
                                                            overlayKey:
                                                                _visitLinkOverlayKey,
                                                            catalog:
                                                                linkCatalog,
                                                            timeRulerWidth:
                                                                _calendarController
                                                                        .view ==
                                                                    CalendarView
                                                                        .month
                                                                ? 0
                                                                : _timeRulerWidth,
                                                            cardRadius:
                                                                _calendarController
                                                                        .view ==
                                                                    CalendarView
                                                                        .month
                                                                ? 4
                                                                : 8,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  if (_visitLinksViewOk)
                                                    Positioned(
                                                      left: 8,
                                                      top:
                                                          _calendarHeaderHeight +
                                                          (_calendarViewHeaderHeight -
                                                                  28) /
                                                              2,
                                                      child:
                                                          _visitLinksToggle(),
                                                    ),
                                                ],
                                              ),
                                            ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHourlyCalendar({
    required CalendarView view,
    required double baseHourHeight,
    required List<Appointment> appointments,
    required Set<String> activeAppointmentIds,
    required Map<String, int> realMinutesById,
    required Map<String, QueryDocumentSnapshot> docsById,
  }) {
    final slotItems = <CalendarSlotItem>[
      for (final app in appointments)
        if (app.id != null && !app.isAllDay)
          CalendarSlotItem(id: app.id.toString(), startTime: app.startTime),
    ];
    final initialDates = _visibleDatesForPage(_currentPageIndex, view);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nowLine.visibleDates.value = initialDates;
      if (initialDates.isNotEmpty) {
        _linkCatalog?.updateVisibleRange(initialDates.first, initialDates.last);
      }
      if (_visitLinksEnabled) {
        _visitLinkHub.bump();
      }
    });

    return PageView.builder(
      key: ValueKey('hourly_pager_${view.name}_$_pagerGeneration'),
      controller: _pageController,
      onPageChanged: (pageIndex) {
        final visibleDates = _visibleDatesForPage(pageIndex, view);
        _currentPageIndex = pageIndex;
        if (visibleDates.isNotEmpty) {
          _focusDate = visibleDates.first;
          _calendarController.displayDate = DateTime(
            _focusDate.year,
            _focusDate.month,
            _focusDate.day,
            2,
          );
          _nowLine.visibleDates.value = visibleDates;
          _linkCatalog?.updateVisibleRange(
            visibleDates.first,
            visibleDates.last,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_visitLinksEnabled) {
            _visitLinkHub.bump();
          } else {
            _visitLinkHub.clear();
          }
          _nowLine.bump();
        });
      },
      itemBuilder: (context, pageIndex) {
        final visibleDates = _visibleDatesForPage(pageIndex, view);
        final cardSide = view == CalendarView.day
            ? kCalendarDayCardSide
            : kCalendarCardSide;
        final layout = CalendarHourLayout.compute(
          visibleDays: visibleDates,
          items: slotItems,
          baseHourHeight: baseHourHeight,
          cardSide: cardSide,
        );
        if (pageIndex == _currentPageIndex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && pageIndex == _currentPageIndex) {
              _nowLine.hourLayout = layout;
            }
          });
        }
        return _AdaptiveCalendarPage(
          key: ValueKey('hourly_page_${view.name}_$pageIndex'),
          visibleDates: visibleDates,
          today: _todayDate(),
          layout: layout,
          appointments: appointments,
          scheduleConfig: _scheduleConfig,
          workStartMinutes: _workStartMinutes,
          workEndMinutes: _workEndMinutes,
          initialScrollOffset: _savedVerticalOffset,
          onScrollOffsetChanged: (offset) {
            _savedVerticalOffset = offset;
          },
          onDayHeaderTap: view == CalendarView.day
              ? null
              : (date) {
                  AppFeedback.pleasant();
                  setState(() {
                    _focusDate = DateTime(date.year, date.month, date.day);
                    _calendarController.displayDate = DateTime(
                      _focusDate.year,
                      _focusDate.month,
                      _focusDate.day,
                      2,
                    );
                    _calendarController.view = CalendarView.day;
                    _resetHourlyPager(_focusDate);
                  });
                  _publishHomeState();
                },
          onEmptySlotLongPress: _onEmptySlot,
          isDragLocked: (app) => _isAppointmentDragLocked(app, docsById),
          onLockedDragAttempt: () {
            AppFeedback.haptic();
            _warnDragLocked();
          },
          cardBuilder: (app, size, {required bool forDragFeedback}) =>
              _buildAppointmentCard(
                app: app,
                slotSize: size,
                cardSize: size,
                docsById: docsById,
                registerLink: !forDragFeedback,
                handleGestures: false,
              ),
          onAppointmentDropped: (app, newTime, {required bool allDay}) =>
              _handleAppointmentDrop(
                appointment: app,
                dropped: newTime,
                droppedAllDay: allDay,
                appointments: appointments,
                activeAppointmentIds: activeAppointmentIds,
                realMinutesById: realMinutesById,
                docsById: docsById,
              ),
          onCardTap: (app) => _openAppointment(app, docsById),
        );
      },
    );
  }

  Widget _buildMonthSfCalendar({
    required double slotHeight,
    required List<Appointment> appointments,
    required Set<String> activeAppointmentIds,
    required Map<String, int> realMinutesById,
    required Map<String, QueryDocumentSnapshot> docsById,
    required double Function(DateTime) freeMinutesAfter,
  }) {
    _nowLine.hourLayout = null;
    return SfCalendar(
      controller: _calendarController,
      firstDayOfWeek: _firstDayOfWeek,
      backgroundColor: AppColors.card,
      headerHeight: _calendarHeaderHeight,
      viewHeaderHeight: _calendarViewHeaderHeight,
      specialRegions: _nonWorkingRegions(),
      timeRegionBuilder: (context, details) {
        return Container(
          width: details.bounds.width,
          height: details.bounds.height,
          color: _nonWorkingHourColor,
        );
      },
      dataSource: JobDataSource(appointments),
      onViewChanged: (details) {
        final visibleDates = details.visibleDates;
        _nowLine.visibleDates.value = List.of(visibleDates);
        if (visibleDates.isNotEmpty) {
          _linkCatalog?.updateVisibleRange(
            visibleDates.first,
            visibleDates.last,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _visitLinksEnabled) {
            _visitLinkHub.bump();
          } else if (mounted) {
            _visitLinkHub.clear();
          }
        });
      },
      allowDragAndDrop: true,
      dragAndDropSettings: const DragAndDropSettings(
        allowNavigation: true,
        allowScroll: true,
        showTimeIndicator: true,
      ),
      onDragStart: (AppointmentDragStartDetails details) {
        _lastDragSnap = null;
        AppFeedback.haptic();
      },
      onDragUpdate: (AppointmentDragUpdateDetails details) {
        final draggingTime = details.draggingTime;
        if (draggingTime == null) return;
        final snapped = _snapToQuarterHour(draggingTime);
        if (_lastDragSnap != null &&
            _lastDragSnap!.isAtSameMomentAs(snapped)) {
          return;
        }
        _lastDragSnap = snapped;
        AppFeedback.haptic();
      },
      onDragEnd: (AppointmentDragEndDetails details) async {
        final appointment = details.appointment;
        final dropped = details.droppingTime;
        if (appointment is! Appointment || dropped == null) return;
        await _handleAppointmentDrop(
          appointment: appointment,
          dropped: dropped,
          droppedAllDay: appointment.isAllDay,
          appointments: appointments,
          activeAppointmentIds: activeAppointmentIds,
          realMinutesById: realMinutesById,
          docsById: docsById,
        );
      },
      viewHeaderStyle: ViewHeaderStyle(
        dateTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 18,
          color: AppColors.ink,
        ),
        dayTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: AppColors.inkMuted,
        ),
      ),
      timeSlotViewSettings: TimeSlotViewSettings(
        startHour: 0,
        endHour: 24,
        timeInterval: const Duration(hours: 1),
        timeFormat: 'HH:mm',
        timeIntervalHeight: slotHeight,
        timeRulerSize: _timeRulerWidth,
        timeTextStyle: TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 12,
          color: AppColors.inkMuted,
        ),
      ),
      showCurrentTimeIndicator: false,
      monthViewSettings: const MonthViewSettings(
        showAgenda: false,
        appointmentDisplayMode: MonthAppointmentDisplayMode.appointment,
      ),
      onTap: (CalendarTapDetails details) {
        if (_calendarController.view == CalendarView.month &&
            details.targetElement == CalendarElement.calendarCell &&
            details.date != null) {
          setState(() {
            _focusDate = DateTime(
              details.date!.year,
              details.date!.month,
              details.date!.day,
            );
            _calendarController.displayDate = details.date;
            _calendarController.view = CalendarView.day;
            _resetHourlyPager(_focusDate);
          });
          _publishHomeState();
        }
      },
      onLongPress: (CalendarLongPressDetails details) {
        if (details.targetElement != CalendarElement.calendarCell ||
            details.date == null) {
          return;
        }
        if (details.appointments != null && details.appointments!.isNotEmpty) {
          return;
        }
        AppFeedback.haptic();
        _onEmptySlot(details.date!);
      },
      appointmentBuilder: (context, calendarAppointmentDetails) {
        final Appointment app =
            calendarAppointmentDetails.appointments.first;
        final bounds = calendarAppointmentDetails.bounds;
        final shape = calendarCardShape(
          slot: bounds.size,
          freeHeight:
              freeMinutesAfter(app.startTime) * slotHeight / 60,
          square: _squareCardView,
          cardSide: _currentCardSide,
          minHeight: 0,
        );
        return _buildAppointmentCard(
          app: app,
          slotSize: bounds.size,
          cardSize: shape.size,
          docsById: docsById,
          registerLink: true,
          handleGestures: true,
        );
      },
    );
  }

  bool _isAppointmentDragLocked(
    Appointment appointment,
    Map<String, QueryDocumentSnapshot> docsById,
  ) {
    if (CalendarEvent.isAppointmentId(appointment.id)) return false;
    final jobId = JobVisit.jobIdFromAppointment(appointment.id);
    final visitId = JobVisit.visitIdFromAppointment(appointment.id);
    final lockDoc = docsById[jobId];
    if (lockDoc == null) return false;
    Job? lockJob;
    try {
      lockJob = Job.fromMap(
        lockDoc.data() as Map<String, dynamic>,
        jobId,
      );
    } catch (_) {}
    final lockVisit = lockJob == null
        ? null
        : JobVisit.matchForAppointment(
            lockJob.coalescedVisits,
            visitId,
            appointment.startTime,
          );
    return _visitDragLocked(lockJob, lockVisit);
  }

  void _openAppointment(
    Appointment app,
    Map<String, QueryDocumentSnapshot> docsById,
  ) {
    AppFeedback.pleasant();
    if (CalendarEvent.isAppointmentId(app.id)) {
      final eventId = CalendarEvent.idFromAppointment(app.id);
      CalendarEvent? event;
      for (final item in _events) {
        if (item.id == eventId) {
          event = item;
          break;
        }
      }
      showCalendarEventSheet(context, event: event, startAt: app.startTime);
      return;
    }
    final jobId = JobVisit.jobIdFromAppointment(app.id);
    final originalJobDoc = docsById[jobId];
    if (originalJobDoc == null) return;
    final jobData = originalJobDoc.data() as Map<String, dynamic>;
    AppNav.openCard(
      context,
      key: AppNav.jobKey(jobId),
      builder: (context) => JobDetailsScreen(
        jobId: jobId,
        clientId: jobData['clientId'] ?? '',
        jobData: jobData,
      ),
    );
  }

  Future<void> _handleAppointmentDrop({
    required Appointment appointment,
    required DateTime dropped,
    bool droppedAllDay = false,
    required List<Appointment> appointments,
    required Set<String> activeAppointmentIds,
    required Map<String, int> realMinutesById,
    required Map<String, QueryDocumentSnapshot> docsById,
  }) async {
    final newTime = droppedAllDay
        ? DateTime(dropped.year, dropped.month, dropped.day)
        : _snapToQuarterHour(dropped);

    if (CalendarEvent.isAppointmentId(appointment.id)) {
      final eventId = CalendarEvent.idFromAppointment(appointment.id);
      CalendarEvent? event;
      for (final item in _events) {
        if (item.id == eventId) {
          event = item;
          break;
        }
      }
      if (event == null) return;
      try {
        await CalendarEventService.save(event.copyWith(startAt: newTime));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${'Не удалось сохранить'.tr}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final jobId = JobVisit.jobIdFromAppointment(appointment.id);
    final visitId = JobVisit.visitIdFromAppointment(appointment.id);

    if (_isAppointmentDragLocked(appointment, docsById)) {
      _warnDragLocked();
      return;
    }

    final duration = Duration(
      minutes:
          realMinutesById[appointment.id.toString()] ??
          appointment.endTime.difference(appointment.startTime).inMinutes,
    );
    if (!droppedAllDay) {
      final newEnd = newTime.add(duration);
      final overlaps = appointments.any((other) {
        if (other.isAllDay) return false;
        if (other.id.toString() == appointment.id.toString()) return false;
        if (!activeAppointmentIds.contains(other.id.toString())) {
          return false;
        }
        final otherEnd = other.startTime.add(
          Duration(
            minutes:
                realMinutesById[other.id.toString()] ??
                other.endTime.difference(other.startTime).inMinutes,
          ),
        );
        return newTime.isBefore(otherEnd) && newEnd.isAfter(other.startTime);
      });
      if (overlaps) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Это время пересекается с другой заявкой'.tr),
              backgroundColor: Colors.red,
            ),
          );
        }
        _snapCardBack();
        return;
      }
    }

    if (!mounted) return;
    final loc = AppLocale.instance.dateLocale;
    final oldDateLabel = DateFormat(
      'EEEE, d MMMM',
      loc,
    ).format(appointment.startTime);
    final oldLabel = appointment.isAllDay
        ? oldDateLabel
        : '$oldDateLabel · ${DateFormat('HH:mm').format(appointment.startTime)}';
    final newDateLabel = DateFormat('EEEE, d MMMM', loc).format(newTime);
    final newLabel = droppedAllDay
        ? newDateLabel
        : '$newDateLabel · ${DateFormat('HH:mm').format(newTime)}';
    final approved = await showConfirmCancelSheet(
      context,
      title: 'Перенести заявку?'.tr,
      message: '$oldLabel\n↓\n$newLabel',
      confirmLabel: 'Перенести'.tr,
    );
    if (!approved) {
      _snapCardBack();
      return;
    }

    final config = await SettingsService.loadConfig();
    final workStart = SettingsService.readWorkStartMinutes(config);
    final workEnd = SettingsService.readWorkEndMinutes(config);
    final durationMins = duration.inMinutes.clamp(15, 8 * 60);
    final newTimeInToronto = AppTimeService.bookingWallClock(newTime);
    final newMinutes = newTimeInToronto.hour * 60 + newTimeInToronto.minute;
    final isWorkDay = SettingsService.isVisitDay(config, newTime);
    final outOfWorkHours =
        !droppedAllDay &&
        (newMinutes < workStart || newMinutes + durationMins > workEnd);
    if (!isWorkDay || outOfWorkHours) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Это время за пределами рабочего расписания'.tr),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      _snapCardBack();
      return;
    }

    try {
      final jobDoc = docsById[jobId];
      if (jobDoc == null) return;
      final job = Job.fromMap(jobDoc.data() as Map<String, dynamic>, jobId);
      final visits = [...job.coalescedVisits];
      final minutes = duration.inMinutes.clamp(15, 8 * 60);
      final idx = visits.indexWhere((v) => v.id == visitId);
      final dayChanged = !JobVisit.isSameDay(appointment.startTime, newTime);
      if (idx >= 0) {
        visits[idx] = visits[idx].copyWith(
          startAt: newTime,
          durationMinutes: minutes,
          clearSms: dayChanged,
        );
      } else {
        visits.add(
          JobVisit(id: visitId, startAt: newTime, durationMinutes: minutes),
        );
      }
      await JobService.saveVisits(
        jobId,
        visits,
        defaultDuration: job.durationMinutes,
        markRescheduled: dayChanged && job.status != JobStatuses.waitingPart,
        markInstall: dayChanged && job.status == JobStatuses.waitingPart,
        currentStatus: job.status,
      );

      if (mounted) {
        final targetText = droppedAllDay
            ? DateFormat('d MMMM', AppLocale.instance.dateLocale).format(newTime)
            : DateFormat(
                'd MMMM, HH:mm',
                AppLocale.instance.dateLocale,
              ).format(newTime);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${'Заявка перенесена на'.tr} $targetText'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${'Не удалось перенести заявку'.tr}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildAppointmentCard({
    required Appointment app,
    required Size slotSize,
    required Size cardSize,
    required Map<String, QueryDocumentSnapshot> docsById,
    required bool registerLink,
    required bool handleGestures,
  }) {
    final shape = CalendarCardShape(
      slot: slotSize,
      width: cardSize.width,
      height: cardSize.height,
    );
    if (CalendarEvent.isAppointmentId(app.id)) {
      return _eventAppointmentCard(
        app,
        shape,
        handleGestures: handleGestures,
      );
    }

    final jobId = JobVisit.jobIdFromAppointment(app.id);
    final originalJobDoc = docsById[jobId];
    if (originalJobDoc == null) {
      return const SizedBox.shrink();
    }
    final jobData = originalJobDoc.data() as Map<String, dynamic>;
    final bool hasJobSite = jobData['hasJobSite'] == true;
    final String applianceType = jobData['applianceType'] ?? 'Техника'.tr;

    Job? parsedJob;
    try {
      parsedJob = Job.fromMap(jobData, jobId);
    } catch (_) {}
    final fallbackPhone =
        hasJobSite &&
            (jobData['jobSitePhone'] ?? '').toString().trim().isNotEmpty
        ? jobData['jobSitePhone'].toString().trim()
        : (jobData['clientPhone'] ?? '').toString().trim();
    final String clientName = parsedJob != null
        ? parsedJob.contactName
        : (fallbackPhone.isNotEmpty ? fallbackPhone : '');
    final type = (parsedJob?.applianceType.isNotEmpty == true)
        ? parsedJob!.applianceType
        : applianceType;
    final visitId = JobVisit.visitIdFromAppointment(app.id);
    JobVisit? visit;
    if (parsedJob != null) {
      visit = JobVisit.matchForAppointment(
        parsedJob.coalescedVisits,
        visitId,
        app.startTime,
      );
    }
    final displayStatus =
        parsedJob?.displayStatusForVisit(visit) ??
        (jobData['status'] ?? '').toString();
    final hatch = calendarHatchFor(status: displayStatus);
    final fiveDay = _calendarController.view == CalendarView.workWeek;
    final resultMark =
        hatch == CalendarHatchStyle.completed ||
            hatch == CalendarHatchStyle.cancelled
        ? hatch
        : null;
    final statusEmoji = resultMark == null
        ? calendarStatusEmoji(displayStatus)
        : null;
    final showName =
        !fiveDay && cardSize.width >= 56 && cardSize.height >= 26;
    final iconSize = showName
        ? (cardSize.height * 0.58).clamp(16.0, 28.0)
        : (cardSize.shortestSide * 0.62).clamp(11.0, 30.0);
    final statusIcon = CalendarStatusBadge(
      hatch: resultMark,
      emoji: statusEmoji,
      size: iconSize,
    );
    final radius = BorderRadius.circular(
      _calendarController.view == CalendarView.month ? 4 : 8,
    );
    final hasTime = !app.isAllDay && (visit?.hasTime ?? true);
    final timeStr = DateFormat('HH:mm').format(app.startTime);
    final cityStr = (parsedJob?.city ?? '').trim();
    final minimalSubtitle = [
      if (hasTime) timeStr,
      if (cityStr.isNotEmpty) cityStr,
      if (type.trim().isNotEmpty) trAny(type.trim()),
    ].join(' · ');

    Widget cardBody = HatchedCalendarCard(
      color: app.color,
      borderRadius: radius,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: showName ? 8 : 2),
        child: showName
            ? Row(
                children: [
                  statusIcon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                clientName.isEmpty
                                    ? 'Клиент'.tr
                                    : clientName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  height: 1.1,
                                  decoration:
                                      hatch == CalendarHatchStyle.cancelled
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                            if (jobData['clientIsRegular'] == true ||
                                ClientService.isRegularClient(
                                  clientId: (jobData['clientId'] ?? '')
                                      .toString(),
                                  phone: (jobData['clientPhone'] ?? '')
                                      .toString(),
                                ))
                              const RegularClientStar(
                                size: 13,
                                onDark: true,
                                padding: EdgeInsets.only(left: 3),
                              ),
                            CarePlanMark(
                              clientId: (jobData['clientId'] ?? '')
                                  .toString(),
                              phone: (jobData['clientPhone'] ?? '')
                                  .toString(),
                              planId: (jobData['carePlanId'] ?? '')
                                  .toString(),
                              size: 14,
                              onDark: true,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          minimalSubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w600,
                            fontSize: 11.5,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Center(child: statusIcon),
      ),
    );

    if (registerLink) {
      cardBody = VisitLinkReporter(
        hub: _visitLinkHub,
        appointmentId: app.id.toString(),
        jobId: jobId,
        startAt: app.startTime,
        color: app.color,
        enabled: _visitLinksEnabled,
        child: cardBody,
      );
    }

    final opacityChild = Opacity(
      opacity:
          resultMark == null && !JobStatuses.isClosed(parsedJob?.status ?? '')
          ? 1
          : kCalendarClosedOpacity,
      child: CalendarCardSlot(shape: shape, child: cardBody),
    );

    if (!handleGestures) {
      return opacityChild;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openAppointment(app, docsById),
      onLongPress: _visitDragLocked(parsedJob, visit)
          ? () {
              AppFeedback.haptic();
              _warnDragLocked();
            }
          : null,
      child: opacityChild,
    );
  }

  Future<void> _onEmptySlot(DateTime date) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Добавить в календарь'.tr,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryOnCard,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: Icon(
                    Icons.build_outlined,
                    color: AppColors.primaryOnCard,
                  ),
                  title: Text('Заявка'.tr),
                  onTap: () => Navigator.pop(sheetContext, 'job'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.event_note,
                    color: Color(0xFF5C6BC0),
                  ),
                  title: Text('Мероприятие'.tr),
                  subtitle: Text('Текст, время и фото'.tr),
                  onTap: () => Navigator.pop(sheetContext, 'event'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'job') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CreateJobScreen(preselectedDate: date),
        ),
      );
      return;
    }
    await showCalendarEventSheet(context, startAt: date);
  }

  Widget _eventAppointmentCard(
    Appointment app,
    CalendarCardShape shape, {
    bool handleGestures = true,
  }) {
    final eventId = CalendarEvent.idFromAppointment(app.id);
    CalendarEvent? event;
    for (final item in _events) {
      if (item.id == eventId) {
        event = item;
        break;
      }
    }
    final logoSize = (shape.size.shortestSide - 8).clamp(14.0, 56.0);
    final color = event?.priority.color ?? app.color;
    final slot = CalendarCardSlot(
      shape: shape,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(
            _calendarController.view == CalendarView.month ? 4 : 8,
          ),
        ),
        child: Center(
          child: Icon(Icons.flag, color: Colors.white, size: logoSize),
        ),
      ),
    );
    if (!handleGestures) {
      return slot;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        AppFeedback.pleasant();
        showCalendarEventSheet(context, event: event, startAt: app.startTime);
      },
      child: slot,
    );
  }
}

class _AdaptiveCalendarPage extends StatefulWidget {
  const _AdaptiveCalendarPage({
    super.key,
    required this.visibleDates,
    required this.today,
    required this.layout,
    required this.appointments,
    required this.scheduleConfig,
    required this.workStartMinutes,
    required this.workEndMinutes,
    required this.initialScrollOffset,
    required this.onScrollOffsetChanged,
    this.onDayHeaderTap,
    required this.onEmptySlotLongPress,
    required this.isDragLocked,
    required this.onLockedDragAttempt,
    required this.cardBuilder,
    required this.onAppointmentDropped,
    required this.onCardTap,
  });

  final List<DateTime> visibleDates;
  final DateTime today;
  final CalendarHourLayout layout;
  final List<Appointment> appointments;
  final Map<String, dynamic> scheduleConfig;
  final int workStartMinutes;
  final int workEndMinutes;
  final double? initialScrollOffset;
  final ValueChanged<double> onScrollOffsetChanged;
  final ValueChanged<DateTime>? onDayHeaderTap;
  final ValueChanged<DateTime> onEmptySlotLongPress;
  final bool Function(Appointment) isDragLocked;
  final VoidCallback onLockedDragAttempt;
  final Widget Function(Appointment, Size, {required bool forDragFeedback})
  cardBuilder;
  final Future<void> Function(Appointment, DateTime, {required bool allDay})
  onAppointmentDropped;
  final ValueChanged<Appointment> onCardTap;

  @override
  State<_AdaptiveCalendarPage> createState() => _AdaptiveCalendarPageState();
}

class _AdaptiveCalendarPageState extends State<_AdaptiveCalendarPage> {
  static const double _headerHeight = 24;
  static const double _viewHeaderHeight = 42;
  static const double _rulerWidth = 52;
  static Color get _nonWorkingHourColor => AppColors.nonWorkingHour;

  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _gridKey = GlobalKey();
  late final ScrollController _scrollController;

  Appointment? _draggingApp;
  DateTime? _draggingTime;
  bool _draggingAllDay = false;

  double get _defaultScrollOffset {
    final targetMinutes = (widget.workStartMinutes - 60)
        .clamp(0, 18 * 60)
        .toDouble();
    return widget.layout.yForMinutes(targetMinutes);
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset ?? _defaultScrollOffset,
    );
    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        widget.onScrollOffsetChanged(_scrollController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AdaptiveCalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialScrollOffset == null &&
        oldWidget.initialScrollOffset != null &&
        _scrollController.hasClients) {
      final target = _defaultScrollOffset.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime _snapQuarter(DateTime time) {
    final base = DateTime(time.year, time.month, time.day);
    final minutes = time.difference(base).inMinutes;
    final snapped = ((minutes / 15).round()) * 15;
    return base.add(Duration(minutes: snapped.clamp(0, 23 * 60 + 45)));
  }

  void _handleEmptyLongPress(LongPressStartDetails details, double dayWidth) {
    if (widget.visibleDates.isEmpty || dayWidth <= 0) return;
    final col = (details.localPosition.dx ~/ dayWidth).clamp(
      0,
      widget.visibleDates.length - 1,
    );
    final day = widget.visibleDates[col];
    final rawTime = widget.layout.timeForY(day, details.localPosition.dy);
    final slotTime = DateTime(
      day.year,
      day.month,
      day.day,
      rawTime.hour,
      (rawTime.minute ~/ 30) * 30,
    );
    AppFeedback.haptic();
    widget.onEmptySlotLongPress(slotTime);
  }

  void _updateDragFromGlobal(Offset globalPos, double dayWidth) {
    if (widget.visibleDates.isEmpty || dayWidth <= 0) return;

    final headerBox =
        _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (headerBox != null && headerBox.hasSize) {
      final headerLocal = headerBox.globalToLocal(globalPos);
      if (headerLocal.dy <= headerBox.size.height + 2) {
        final dxHeader = (headerLocal.dx - _rulerWidth).clamp(
          0.0,
          headerBox.size.width - _rulerWidth - 0.01,
        );
        final dayIdx = (dxHeader ~/ dayWidth).clamp(
          0,
          widget.visibleDates.length - 1,
        );
        final day = widget.visibleDates[dayIdx];
        final dayOnly = DateTime(day.year, day.month, day.day);
        if (!_draggingAllDay ||
            _draggingTime == null ||
            !_sameDay(_draggingTime!, dayOnly)) {
          setState(() {
            _draggingAllDay = true;
            _draggingTime = dayOnly;
          });
          AppFeedback.haptic();
        }
        return;
      }
    }

    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(globalPos);
    final dxInColumns = (local.dx - _rulerWidth).clamp(
      0.0,
      box.size.width - _rulerWidth - 0.01,
    );
    final dayIdx = (dxInColumns ~/ dayWidth).clamp(
      0,
      widget.visibleDates.length - 1,
    );
    final day = widget.visibleDates[dayIdx];
    final raw = widget.layout.timeForY(day, local.dy);
    var snapped = _snapQuarter(raw);
    if (snapped.hour == 0 && snapped.minute == 0) {
      snapped = DateTime(day.year, day.month, day.day, 0, 15);
    }
    if (_draggingAllDay ||
        _draggingTime == null ||
        !_draggingTime!.isAtSameMomentAs(snapped)) {
      setState(() {
        _draggingAllDay = false;
        _draggingTime = snapped;
      });
      AppFeedback.haptic();
    }

    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      final viewportY = local.dy - pos.pixels;
      if (viewportY < 32 && pos.pixels > 0) {
        _scrollController.jumpTo(
          (pos.pixels - 8).clamp(0.0, pos.maxScrollExtent),
        );
      } else if (viewportY > pos.viewportDimension - 32 &&
          pos.pixels < pos.maxScrollExtent) {
        _scrollController.jumpTo(
          (pos.pixels + 8).clamp(0.0, pos.maxScrollExtent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dates = widget.visibleDates;
    if (dates.isEmpty) return const SizedBox.shrink();
    final headerAnchor = dates[dates.length ~/ 2];
    final monthTitle = DateFormat(
      'MMMM yyyy',
      AppLocale.instance.dateLocale,
    ).format(headerAnchor);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final columnsWidth = (totalWidth - _rulerWidth).clamp(
          1.0,
          double.infinity,
        );
        final dayWidth = columnsWidth / dates.length;
        final cardSize = Size(widget.layout.cardSide, widget.layout.cardSide);

        final visibleAppointments = <Appointment>[
          for (final app in widget.appointments)
            if (app.id != null &&
                !app.isAllDay &&
                widget.layout.placements.containsKey(app.id.toString()))
              app,
        ];
        final allDayByDate = <List<Appointment>>[
          for (final date in dates)
            [
              for (final app in widget.appointments)
                if (app.isAllDay && _sameDay(app.startTime, date)) app,
            ],
        ];
        final showAllDayStrip =
            allDayByDate.any((list) => list.isNotEmpty) ||
            (_draggingApp != null && _draggingAllDay);

        return ColoredBox(
          color: AppColors.card,
          child: Column(
            children: [
              Container(
                height: _headerHeight,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                child: Text(
                  monthTitle,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
              ),
              Container(
                key: _headerKey,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  border: Border(
                    bottom: BorderSide(color: AppColors.border, width: 1),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: _viewHeaderHeight,
                      child: Row(
                        children: [
                          const SizedBox(width: _rulerWidth),
                          for (final date in dates)
                            Expanded(
                              child: _buildDayHeader(
                                date: date,
                                isToday: _sameDay(date, widget.today),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showAllDayStrip)
                      _buildAllDayStrip(
                        dates: dates,
                        allDayByDate: allDayByDate,
                        dayWidth: dayWidth,
                        cardSize: cardSize,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const ClampingScrollPhysics(),
                  child: SizedBox(
                    key: _gridKey,
                    width: totalWidth,
                    height: widget.layout.totalHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _AdaptiveGridPainter(
                              layout: widget.layout,
                              visibleDates: dates,
                              scheduleConfig: widget.scheduleConfig,
                              workStartMinutes: widget.workStartMinutes,
                              workEndMinutes: widget.workEndMinutes,
                              rulerWidth: _rulerWidth,
                              nonWorkingColor: _nonWorkingHourColor,
                            ),
                          ),
                        ),
                        Positioned(
                          left: _rulerWidth,
                          top: 0,
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onLongPressStart: (details) =>
                                _handleEmptyLongPress(details, dayWidth),
                          ),
                        ),
                        for (final app in visibleAppointments)
                          _buildPlacedAppointment(
                            app: app,
                            dates: dates,
                            dayWidth: dayWidth,
                            cardSize: cardSize,
                          ),
                        if (_draggingApp != null &&
                            _draggingTime != null &&
                            !_draggingAllDay)
                          ..._buildDragOverlay(
                            app: _draggingApp!,
                            draggingTime: _draggingTime!,
                            dates: dates,
                            dayWidth: dayWidth,
                            cardSize: cardSize,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDayHeader({required DateTime date, required bool isToday}) {
    final dayLabel = DateFormat(
      'E',
      AppLocale.instance.dateLocale,
    ).format(date).toUpperCase();
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          dayLabel,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 11.5,
            height: 1.0,
            color: isToday ? AppColors.primaryOnCard : AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 1),
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: isToday
              ? BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                )
              : null,
          child: Text(
            '${date.day}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              height: 1.0,
              color: isToday ? Colors.white : AppColors.ink,
            ),
          ),
        ),
      ],
    );
    if (widget.onDayHeaderTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onDayHeaderTap!(date),
      child: content,
    );
  }

  void _startCardDrag(
    Appointment app,
    Offset globalPos,
    double dayWidth,
  ) {
    if (widget.isDragLocked(app)) {
      widget.onLockedDragAttempt();
      return;
    }
    AppFeedback.haptic();
    setState(() {
      _draggingApp = app;
      _draggingAllDay = app.isAllDay;
      _draggingTime = app.isAllDay
          ? DateTime(
              app.startTime.year,
              app.startTime.month,
              app.startTime.day,
            )
          : _snapQuarter(app.startTime);
    });
    _updateDragFromGlobal(globalPos, dayWidth);
  }

  void _finishCardDrag() {
    final dragged = _draggingApp;
    final targetTime = _draggingTime;
    final targetAllDay = _draggingAllDay;
    setState(() {
      _draggingApp = null;
      _draggingTime = null;
      _draggingAllDay = false;
    });
    if (dragged == null || targetTime == null) return;
    final unchanged =
        dragged.isAllDay == targetAllDay &&
        (targetAllDay
            ? _sameDay(dragged.startTime, targetTime)
            : targetTime.isAtSameMomentAs(dragged.startTime));
    if (!unchanged) {
      widget.onAppointmentDropped(dragged, targetTime, allDay: targetAllDay);
    }
  }

  void _cancelCardDrag() {
    if (_draggingApp != null) {
      setState(() {
        _draggingApp = null;
        _draggingTime = null;
        _draggingAllDay = false;
      });
    }
  }

  Widget _buildAllDayStrip({
    required List<DateTime> dates,
    required List<List<Appointment>> allDayByDate,
    required double dayWidth,
    required Size cardSize,
  }) {
    final fullWidth = dates.length == 1 && dayWidth > cardSize.width + 8;
    final itemWidth = fullWidth
        ? dayWidth - 8
        : (dayWidth - 2 < cardSize.width
              ? (dayWidth - 2).clamp(16.0, cardSize.width)
              : cardSize.width);
    final itemSize = Size(itemWidth, cardSize.height);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: _rulerWidth),
          for (var i = 0; i < dates.length; i++)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var j = 0; j < allDayByDate[i].length; j++) ...[
                    if (j > 0) const SizedBox(height: 2),
                    _buildAllDayCard(
                      app: allDayByDate[i][j],
                      size: itemSize,
                      dayWidth: dayWidth,
                    ),
                  ],
                  if (_draggingApp != null &&
                      _draggingAllDay &&
                      _draggingTime != null &&
                      _sameDay(_draggingTime!, dates[i]) &&
                      !allDayByDate[i].any(
                        (a) => a.id.toString() == _draggingApp!.id.toString(),
                      )) ...[
                    if (allDayByDate[i].isNotEmpty) const SizedBox(height: 2),
                    SizedBox(
                      width: itemSize.width,
                      height: itemSize.height,
                      child: Opacity(
                        opacity: 0.75,
                        child: widget.cardBuilder(
                          _draggingApp!,
                          itemSize,
                          forDragFeedback: true,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAllDayCard({
    required Appointment app,
    required Size size,
    required double dayWidth,
  }) {
    final isBeingDragged =
        _draggingApp != null &&
        _draggingApp!.id.toString() == app.id.toString();
    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onCardTap(app),
        onLongPressStart: (details) =>
            _startCardDrag(app, details.globalPosition, dayWidth),
        onLongPressMoveUpdate: (details) {
          if (_draggingApp == null) return;
          _updateDragFromGlobal(details.globalPosition, dayWidth);
        },
        onLongPressEnd: (_) => _finishCardDrag(),
        onLongPressCancel: _cancelCardDrag,
        child: Opacity(
          opacity: isBeingDragged ? 0.35 : 1.0,
          child: widget.cardBuilder(app, size, forDragFeedback: false),
        ),
      ),
    );
  }

  Widget _buildPlacedAppointment({
    required Appointment app,
    required List<DateTime> dates,
    required double dayWidth,
    required Size cardSize,
  }) {
    final placement = widget.layout.placements[app.id.toString()];
    if (placement == null) return const SizedBox.shrink();
    final dayIndex = dates.indexWhere((d) => _sameDay(d, placement.day));
    if (dayIndex < 0) return const SizedBox.shrink();

    final fullWidth = dates.length == 1 && dayWidth > placement.size.width + 8;
    final rect = fullWidth
        ? Rect.fromLTWH(
            _rulerWidth + dayIndex * dayWidth + 4,
            placement.topInDay,
            dayWidth - 8,
            placement.size.height,
          )
        : placement.rectInColumn(
            _rulerWidth + dayIndex * dayWidth,
            dayWidth,
          );
    final isBeingDragged =
        _draggingApp != null &&
        _draggingApp!.id.toString() == app.id.toString();

    return Positioned.fromRect(
      rect: rect,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onCardTap(app),
        onLongPressStart: (details) =>
            _startCardDrag(app, details.globalPosition, dayWidth),
        onLongPressMoveUpdate: (details) {
          if (_draggingApp == null) return;
          _updateDragFromGlobal(details.globalPosition, dayWidth);
        },
        onLongPressEnd: (_) => _finishCardDrag(),
        onLongPressCancel: _cancelCardDrag,
        child: Opacity(
          opacity: isBeingDragged ? 0.35 : 1.0,
          child: widget.cardBuilder(
            app,
            rect.size,
            forDragFeedback: false,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDragOverlay({
    required Appointment app,
    required DateTime draggingTime,
    required List<DateTime> dates,
    required double dayWidth,
    required Size cardSize,
  }) {
    final dayIndex = dates.indexWhere((d) => _sameDay(d, draggingTime));
    if (dayIndex < 0) return const [];
    final y = widget.layout.yForTime(draggingTime);
    final fullWidth = dates.length == 1 && dayWidth > cardSize.width + 8;
    final side = fullWidth
        ? dayWidth - 8
        : (dayWidth < cardSize.width ? dayWidth : cardSize.width);
    final left = _rulerWidth + dayIndex * dayWidth + (dayWidth - side) / 2;
    final top = y.clamp(0.0, widget.layout.totalHeight - cardSize.height);
    final timeLabel = DateFormat('HH:mm').format(draggingTime);

    return [
      Positioned(
        left: 2,
        top: (y - 10).clamp(0.0, widget.layout.totalHeight - 20),
        width: _rulerWidth - 4,
        height: 20,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Center(
              child: Text(
                timeLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: left,
        top: top,
        width: side,
        height: cardSize.height,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: widget.cardBuilder(
              app,
              Size(side, cardSize.height),
              forDragFeedback: true,
            ),
          ),
        ),
      ),
    ];
  }
}

class _AdaptiveGridPainter extends CustomPainter {
  _AdaptiveGridPainter({
    required this.layout,
    required this.visibleDates,
    required this.scheduleConfig,
    required this.workStartMinutes,
    required this.workEndMinutes,
    required this.rulerWidth,
    required this.nonWorkingColor,
  });

  final CalendarHourLayout layout;
  final List<DateTime> visibleDates;
  final Map<String, dynamic> scheduleConfig;
  final int workStartMinutes;
  final int workEndMinutes;
  final double rulerWidth;
  final Color nonWorkingColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (visibleDates.isEmpty || size.width <= rulerWidth) return;
    final dayWidth = (size.width - rulerWidth) / visibleDates.length;
    final shadePaint = Paint()..color = nonWorkingColor;

    final workStartY = layout.yForMinutes(workStartMinutes.toDouble());
    final workEndY = layout.yForMinutes(workEndMinutes.toDouble());

    for (var i = 0; i < visibleDates.length; i++) {
      final day = visibleDates[i];
      final colLeft = rulerWidth + i * dayWidth;
      final isWorkDay = SettingsService.isVisitDay(scheduleConfig, day);
      if (!isWorkDay) {
        canvas.drawRect(
          Rect.fromLTWH(colLeft, 0, dayWidth, size.height),
          shadePaint,
        );
        continue;
      }
      if (workStartMinutes > 0 && workStartY > 0) {
        canvas.drawRect(
          Rect.fromLTWH(colLeft, 0, dayWidth, workStartY),
          shadePaint,
        );
      }
      if (workEndMinutes < 24 * 60 && workEndY < size.height) {
        canvas.drawRect(
          Rect.fromLTWH(colLeft, workEndY, dayWidth, size.height - workEndY),
          shadePaint,
        );
      }
    }

    final linePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;

    for (var i = 0; i <= visibleDates.length; i++) {
      final x = rulerWidth + i * dayWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }

    for (var h = 0; h <= 24; h++) {
      final y = layout.hourTop(h);
      canvas.drawLine(Offset(rulerWidth, y), Offset(size.width, y), linePaint);
    }

    final timeStyle = TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: 12,
      color: AppColors.inkMuted,
    );
    for (var h = 0; h < 24; h++) {
      final y = layout.hourTop(h);
      final label = '${h.toString().padLeft(2, '0')}:00';
      final tp = TextPainter(
        text: TextSpan(text: label, style: timeStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final textY = h == 0 ? 2.0 : y - tp.height / 2;
      tp.paint(canvas, Offset((rulerWidth - tp.width) / 2, textY));
    }
  }

  @override
  bool shouldRepaint(covariant _AdaptiveGridPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.nonWorkingColor != nonWorkingColor ||
        oldDelegate.workStartMinutes != workStartMinutes ||
        oldDelegate.workEndMinutes != workEndMinutes ||
        oldDelegate.scheduleConfig != scheduleConfig ||
        oldDelegate.visibleDates.length != visibleDates.length ||
        (visibleDates.isNotEmpty &&
            oldDelegate.visibleDates.first != visibleDates.first);
  }
}

class JobDataSource extends CalendarDataSource {
  JobDataSource(List<Appointment> source) {
    appointments = source;
  }
}
