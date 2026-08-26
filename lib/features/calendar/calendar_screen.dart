import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';
import '../../services/app_time_service.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/create_job_screen.dart';
import '../jobs/jobs_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../../shared/widgets/appliance_logo.dart';
import '../../shared/widgets/calendar_hatch.dart';
import '../../shared/widgets/visit_confirm_badge.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> with UiSettingsAware {
  final CalendarController _calendarController = CalendarController();
  StreamSubscription? _configSub;

  int _firstDayOfWeek = 1; // 1 = Понедельник
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  int _travelBufferMinutes = SettingsService.defaultTravelBufferMinutes;
  int _defaultDurationMinutes = SettingsService.defaultJobDurationMinutes;
  bool _weekendInCalendar = false;
  bool _isLoadingSettings = true;
  bool _showList = true;
  bool _showRouteMap = false;
  bool _appliedDefaultView = false;
  String _defaultViewMode = SettingsService.defaultCalendarView;

  DateTime? _lastTapTime;
  DateTime? _lastTapDate;
  DateTime _focusDate = DateTime.now();
  final ValueNotifier<double> _slotHeight = ValueNotifier<double>(-1);
  final ValueNotifier<bool> _pinching = ValueNotifier<bool>(false);
  late final Stream<QuerySnapshot> _jobsSnap;
  int? _pinchId1;
  int? _pinchId2;
  Offset? _pinchP1;
  Offset? _pinchP2;
  double? _pinchStartDistance;
  double? _pinchStartHeight;
  double _calendarViewHeight = 600;
  List<TimeRegion> _cachedRegions = const [];
  int _regionsStamp = 0;

  static const Color _nonWorkingHourColor = Color(0xFFF3F4F6);

  @override
  void initState() {
    super.initState();
    _calendarController.view = CalendarView.week;
    _jobsSnap = FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('jobs')
        .snapshots();
    _listenCalendarSettings();
    AppCommands.calendarMode.addListener(_onCalendarCommand);
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

  void _listenCalendarSettings() {
    _configSub = FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('settings')
        .doc('config')
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      final data = doc.data() ?? <String, dynamic>{};
      AppTimeService.applyConfig(data);
      final defaultView = SettingsService.readDefaultCalendarView(data);
      setState(() {
        _firstDayOfWeek = (data['firstDayOfWeek'] as num?)?.toInt() ?? 1;
        _workStartMinutes = SettingsService.readWorkStartMinutes(data);
        _workEndMinutes = SettingsService.readWorkEndMinutes(data);
        _travelBufferMinutes = SettingsService.readTravelBufferMinutes(data);
        _defaultDurationMinutes = SettingsService.readJobDurationMinutes(data);
        _weekendInCalendar = data['weekendInCalendar'] ?? false;
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
    }, onError: (e) {
      debugPrint('Ошибка загрузки настроек: $e');
      if (mounted) setState(() => _isLoadingSettings = false);
    });
  }

  @override
  void dispose() {
    AppCommands.calendarMode.removeListener(_onCalendarCommand);
    _configSub?.cancel();
    _slotHeight.dispose();
    _pinching.dispose();
    super.dispose();
  }

  List<TimeRegion> _nonWorkingRegions() {
    final stamp = Object.hash(_workStartMinutes, _workEndMinutes);
    if (stamp == _regionsStamp && _cachedRegions.isNotEmpty) {
      return _cachedRegions;
    }
    _regionsStamp = stamp;
    final today = DateTime.now();
    final startDay = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 60));
    final regions = <TimeRegion>[];

    for (var i = 0; i < 150; i++) {
      final day = startDay.add(Duration(days: i));
      final dayStart = DateTime(day.year, day.month, day.day);

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
    if (visit.isDone || JobStatuses.isCompletedStatus(status)) {
      return StatusService.colorOf(JobStatuses.completed);
    }
    return StatusService.colorOf(status);
  }

  bool _showJobOnCalendar(Job job) => !job.isDeleted;

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
      color: Colors.white.withValues(alpha: 0.16),
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
    final view = _calendarController.view ??
        (_weekendInCalendar ? CalendarView.week : CalendarView.workWeek);
    if (view == CalendarView.month) return 'month';
    if (view == CalendarView.day) return 'day';
    if (view == CalendarView.week) return 'week';
    return 'workWeek';
  }

  DateTime _todayDate() {
    final now = AppTimeService.wallClock(DateTime.now());
    return DateTime(now.year, now.month, now.day);
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
        _workStartMinutes ~/ 60,
        _workStartMinutes % 60,
      );
      final view = mode == 'day'
          ? CalendarView.day
          : mode == 'week'
              ? CalendarView.week
              : mode == 'month'
                  ? CalendarView.month
                  : CalendarView.workWeek;
      _calendarController.view = view;
      _slotHeight.value = -1;
    });
    _publishHomeState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_showList && _calendarController.view != CalendarView.month) {
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Вид календаря'.tr,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF14557F),
                  ),
                ),
                const SizedBox(height: 16),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.35,
                  children: [
                    for (final option in options)
                      Material(
                        color: current == option.id
                            ? AppColors.accent
                            : const Color(0xFFF3F6F9),
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => Navigator.pop(sheetContext, option.id),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  option.icon,
                                  size: 32,
                                  color: current == option.id
                                      ? Colors.black
                                      : AppColors.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  option.label.tr,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: current == option.id
                                        ? Colors.black
                                        : const Color(0xFF1B2A3A),
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
        );
      },
    );
    if (selected != null && mounted) _selectCalendarMode(selected);
  }

  double get _fittedSlotHeight {
    final hours =
        ((_workEndMinutes - _workStartMinutes) / 60).clamp(8.0, 12.0);
    final usable = (_calendarViewHeight - 72).clamp(240.0, 4000.0);
    return (usable / hours).clamp(16.0, 120.0);
  }

  void _scrollWorkHoursIntoView() {
    final base = _calendarController.displayDate ?? _focusDate;
    _calendarController.displayDate = DateTime(
      base.year,
      base.month,
      base.day,
      _workStartMinutes ~/ 60,
      _workStartMinutes % 60,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pinchId1 == null) {
      _pinchId1 = event.pointer;
      _pinchP1 = event.position;
    } else if (_pinchId2 == null) {
      _pinchId2 = event.pointer;
      _pinchP2 = event.position;
      if (_pinchP1 != null && _pinchP2 != null) {
        _pinchStartDistance = (_pinchP1! - _pinchP2!).distance;
        _pinchStartHeight = _currentSlotHeight;
        _pinching.value = true;
      }
    }
  }

  double get _currentSlotHeight {
    final value = _slotHeight.value;
    return value < 0 ? _fittedSlotHeight : value;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _pinchId1) _pinchP1 = event.position;
    if (event.pointer == _pinchId2) _pinchP2 = event.position;
    if (_pinchId1 == null ||
        _pinchId2 == null ||
        _pinchP1 == null ||
        _pinchP2 == null ||
        _pinchStartDistance == null ||
        _pinchStartDistance! < 8 ||
        _pinchStartHeight == null) {
      return;
    }
    final scale = (_pinchP1! - _pinchP2!).distance / _pinchStartDistance!;
    final next = (_pinchStartHeight! * scale).clamp(16.0, 160.0);
    if ((next - _currentSlotHeight).abs() < 2.4) return;
    _slotHeight.value = next;
  }

  void _onPointerUp(PointerEvent event) {
    if (event.pointer == _pinchId1) {
      _pinchId1 = _pinchId2;
      _pinchP1 = _pinchP2;
      _pinchId2 = null;
      _pinchP2 = null;
    } else if (event.pointer == _pinchId2) {
      _pinchId2 = null;
      _pinchP2 = null;
    }
    _pinchStartDistance = null;
    _pinchStartHeight = null;
    if (_pinchId2 == null) _pinching.value = false;
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
          height: 56,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          color: AppColors.primary,
          alignment: Alignment.centerLeft,
          child: _viewButton(),
        ),

        // --- САМ КАЛЕНДАРЬ И ЕГО ДАННЫЕ ---
        Expanded(
          child: _showList
              ? JobsScreen(
                  showRouteMap: _showRouteMap,
                  routeDate: _focusDate,
                  onRouteDateChanged: (value) => setState(() => _focusDate = value),
                  hideRouteDateBar: !_showRouteMap,
                  onFilterChanged: (_) {},
                  showStatusFilters: false,
                )
              : StreamBuilder<List<JobStatusDef>>(
            stream: StatusService.streamDefs(),
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
                for (final visit in job.coalescedVisits) {
                  final minutes = visit.durationMinutes > 0
                      ? visit.durationMinutes
                      : _defaultDurationMinutes;
                  appointments.add(
                    Appointment(
                      startTime: visit.startAt,
                      endTime: visit.startAt.add(
                        Duration(minutes: minutes.clamp(15, 8 * 60)),
                      ),
                      color: _appointmentColor(job, visit),
                      id: JobVisit.appointmentId(doc.id, visit.id),
                      notes: visit.note,
                    ),
                  );
                }
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  _calendarViewHeight = constraints.maxHeight;
                  return Listener(
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerUp,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _slotHeight,
                      builder: (context, height, _) {
                        final slotHeight =
                            height < 0 ? _fittedSlotHeight : height;
                        return ValueListenableBuilder<bool>(
                          valueListenable: _pinching,
                          builder: (context, pinching, _) {
                            return RepaintBoundary(
                              child: SfCalendar(
                controller: _calendarController,
                firstDayOfWeek: _firstDayOfWeek,
                backgroundColor: Colors.white,
                specialRegions: _nonWorkingRegions(),
                timeRegionBuilder: (context, details) {
                  return Container(
                    width: details.bounds.width,
                    height: details.bounds.height,
                    color: _nonWorkingHourColor,
                  );
                },
                dataSource: JobDataSource(appointments),

                // --- ПЕРЕТАСКИВАНИЕ ЗАЯВОК ДЛЯ ПЕРЕНОСА ДАТЫ/ВРЕМЕНИ ---
                allowDragAndDrop: !pinching,
                dragAndDropSettings: const DragAndDropSettings(
                  allowNavigation: true,
                  allowScroll: true,
                  showTimeIndicator: true,
                ),
                onDragEnd: (AppointmentDragEndDetails details) async {
                  final appointment = details.appointment;
                  final newTime = details.droppingTime;
                  if (appointment is! Appointment || newTime == null) return;

                  final jobId = JobVisit.jobIdFromAppointment(appointment.id);
                  final visitId = JobVisit.visitIdFromAppointment(appointment.id);
                  final duration = appointment.endTime.difference(appointment.startTime);
                  final newEnd = newTime.add(duration);
                  final buffer = Duration(minutes: _travelBufferMinutes);
                  final overlaps = appointments.any((other) {
                    if (other.id.toString() == appointment.id.toString()) return false;
                    final otherStart = other.startTime.subtract(buffer);
                    final otherEnd = other.endTime.add(buffer);
                    return newTime.isBefore(otherEnd) && newEnd.isAfter(otherStart);
                  });
                  if (overlaps) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Это время пересекается с другой заявкой (с учётом дороги)'.tr,
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                    return;
                  }

                  try {
                    final jobDoc = docsById[jobId];
                    if (jobDoc == null) return;
                    final job = Job.fromMap(
                      jobDoc.data() as Map<String, dynamic>,
                      jobId,
                    );
                    final visits = [...job.coalescedVisits];
                    final minutes = duration.inMinutes.clamp(15, 8 * 60);
                    final idx = visits.indexWhere((v) => v.id == visitId);
                    final dayChanged =
                        !JobVisit.isSameDay(appointment.startTime, newTime);
                    if (idx >= 0) {
                      visits[idx] = visits[idx].copyWith(
                        startAt: newTime,
                        durationMinutes: minutes,
                        clearSms: dayChanged,
                      );
                    } else {
                      visits.add(
                        JobVisit(
                          id: visitId,
                          startAt: newTime,
                          durationMinutes: minutes,
                        ),
                      );
                    }
                    await JobService.saveVisits(
                      jobId,
                      visits,
                      defaultDuration: job.durationMinutes,
                      markRescheduled: dayChanged,
                      currentStatus: job.status,
                    );

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${'Заявка перенесена на'.tr} ${DateFormat('d MMMM, HH:mm', AppLocale.instance.dateLocale).format(newTime)}',
                          ),
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
                },

                // --- СТИЛИЗАЦИЯ ШАПКИ (ЖИРНЫЕ ДАТЫ И ДНИ) ---
                viewHeaderStyle: const ViewHeaderStyle(
                  dateTextStyle: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.black87,
                  ),
                  dayTextStyle: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.black54,
                  ),
                ),

                // --- СТИЛИЗАЦИЯ ВРЕМЕНИ И МАСШТАБА ---
                timeSlotViewSettings: TimeSlotViewSettings(
                  startHour: 0,
                  endHour: 24,
                  timeInterval: const Duration(hours: 1),
                  timeFormat: 'HH:mm',
                  timeIntervalHeight: slotHeight,
                  timeRulerSize: 52,
                  timeTextStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Colors.black87,
                  ),
                ),
                monthViewSettings: const MonthViewSettings(
                  showAgenda: false,
                  appointmentDisplayMode:
                      MonthAppointmentDisplayMode.appointment,
                ),
                onTap: (CalendarTapDetails details) {
                  // 1. Месяц -> День (Один клик)
                  if (_calendarController.view == CalendarView.month &&
                      details.targetElement == CalendarElement.calendarCell) {
                    setState(() {
                      _calendarController.displayDate = details.date;
                      _calendarController.view = CalendarView.day;
                    });
                    return;
                  }

                  // ИГНОРИРУЕМ ТАПЫ ПО ЗАЯВКАМ ТУТ (обрабатываются в appointmentBuilder)
                  if (details.targetElement == CalendarElement.appointment) {
                    return;
                  }

                  // 2. Создание новой заявки по пустому месту (Двойной клик)
                  if (details.targetElement == CalendarElement.calendarCell &&
                      details.date != null) {
                    final now = DateTime.now();
                    if (_lastTapTime != null &&
                        now.difference(_lastTapTime!).inMilliseconds < 500 &&
                        _lastTapDate == details.date) {
                      _lastTapTime = null;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CreateJobScreen(),
                        ),
                      );
                    } else {
                      _lastTapTime = now;
                      _lastTapDate = details.date;
                    }
                  }
                },

                // --- ЗДЕСЬ МЫ РИСУЕМ НАШИ НОВЫЕ КРАСИВЫЕ КАРТОЧКИ ---
                appointmentBuilder: (context, calendarAppointmentDetails) {
                  final Appointment app =
                      calendarAppointmentDetails.appointments.first;

                  final jobId = JobVisit.jobIdFromAppointment(app.id);
                  final originalJobDoc = docsById[jobId];
                  if (originalJobDoc == null) {
                    return const SizedBox.shrink();
                  }
                  final jobData = originalJobDoc.data() as Map<String, dynamic>;

                  // Определяем адрес для логики имени
                  final bool hasJobSite = jobData['hasJobSite'] == true;

                  final String applianceType =
                      jobData['applianceType'] ?? 'Техника'.tr;

                  // Определяем Имя и Описание для одинарного клика
                  final String clientName =
                      hasJobSite &&
                          jobData['jobSiteName'] != null &&
                          jobData['jobSiteName'].toString().isNotEmpty
                      ? jobData['jobSiteName']
                      : (jobData['clientName'] ?? 'Клиент'.tr);
                  Job? parsedJob;
                  try {
                    parsedJob = Job.fromMap(jobData, jobId);
                  } catch (_) {}
                  final type = (parsedJob?.applianceType.isNotEmpty == true)
                      ? parsedJob!.applianceType
                      : applianceType;
                  final visitId = JobVisit.visitIdFromAppointment(app.id);
                  JobVisit? visit;
                  if (parsedJob != null) {
                    for (final item in parsedJob.coalescedVisits) {
                      if (item.id == visitId) {
                        visit = item;
                        break;
                      }
                    }
                  }
                  final displayStatus = parsedJob?.displayStatusForVisit(visit) ??
                      (jobData['status'] ?? '').toString();
                  final hatch = calendarHatchFor(
                    status: displayStatus,
                    visitDone: visit?.isDone == true &&
                        displayStatus != JobStatuses.rescheduled,
                  );
                  final hatchIcon = calendarHatchIcon(hatch);
                  final bounds = calendarAppointmentDetails.bounds;
                  final fiveDay =
                      _calendarController.view == CalendarView.workWeek;
                  final logoSize = bounds.width < 56
                      ? (bounds.shortestSide - 6).clamp(28.0, 72.0)
                      : (bounds.height - 6).clamp(32.0, 64.0);
                  final showName =
                      !fiveDay && bounds.width >= 56 && bounds.height >= 26;
                  final radius = BorderRadius.circular(
                    _calendarController.view == CalendarView.month ? 4 : 8,
                  );

                  // Обертка: один тап открывает заявку
                  return SizedBox(
                    width: bounds.width,
                    height: bounds.height,
                    child: GestureDetector(
                    onTap: () {
                      AppFeedback.pleasant();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => JobDetailsScreen(
                            jobId: jobId,
                            clientId: jobData['clientId'] ?? '',
                            jobData: jobData,
                          ),
                        ),
                      );
                    },
                    child: HatchedCalendarCard(
                      color: app.color,
                      borderRadius: radius,
                      hatch: hatch,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: showName
                            ? Row(
                                children: [
                                  if (!fiveDay) ...[
                                    VisitConfirmBadge.mark(visit, size: 16),
                                    const SizedBox(width: 3),
                                    if (hatchIcon != null) ...[
                                      Icon(hatchIcon, color: Colors.white, size: 14),
                                      const SizedBox(width: 3),
                                    ],
                                  ],
                                  Expanded(
                                    child: Text(
                                      clientName,
                                      maxLines: bounds.height >= 48 ? 2 : 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                        height: 1.15,
                                        decoration: hatch ==
                                                CalendarHatchStyle.cancelled
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  ApplianceLogo(
                                    type: type,
                                    size: logoSize,
                                    onDark: true,
                                  ),
                                  if (!fiveDay &&
                                      visit != null &&
                                      visit.effectiveConfirmStatus ==
                                          JobVisit.confirmConfirmed) ...[
                                    const SizedBox(width: 3),
                                    const Icon(
                                      Icons.check_circle,
                                      color: Colors.white,
                                      size: 14,
                                    ),
                                  ] else if (!fiveDay &&
                                      visit != null &&
                                      visit.effectiveConfirmStatus.isNotEmpty) ...[
                                    const SizedBox(width: 3),
                                    const Icon(
                                      Icons.sms_failed,
                                      color: Colors.white,
                                      size: 14,
                                    ),
                                  ],
                                ],
                              )
                            : Center(
                                child: ApplianceLogo(
                                  type: type,
                                  size: logoSize,
                                  onDark: true,
                                ),
                              ),
                      ),
                    ),
                    ),
                  );
                },
                              ),
                            );
                          },
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
      ],
    );
  }
}

class JobDataSource extends CalendarDataSource {
  JobDataSource(List<Appointment> source) {
    appointments = source;
  }
}
