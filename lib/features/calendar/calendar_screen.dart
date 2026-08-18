import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import '../../core/constants.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';
import '../../services/app_time_service.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/create_job_screen.dart';
import '../jobs/jobs_screen.dart';
import '../jobs/route_map_view.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../../shared/widgets/appliance_logo.dart';
import '../../shared/widgets/job_status_filter_bar.dart';
import '../../shared/widgets/calendar_hatch.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final CalendarController _calendarController = CalendarController();
  StreamSubscription? _configSub;

  int _firstDayOfWeek = 1; // 1 = Понедельник
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  int _travelBufferMinutes = SettingsService.defaultTravelBufferMinutes;
  int _defaultDurationMinutes = SettingsService.defaultJobDurationMinutes;
  bool _weekendInCalendar = false;
  bool _isLoadingSettings = true;
  CalendarView _lastDropdownView = CalendarView.week;
  bool _showList = true;

  DateTime? _lastTapTime;
  DateTime? _lastTapDate;
  bool _showRouteMap = false;
  DateTime _routeDate = DateTime.now();
  String _jobFilter = JobStatuses.call;
  final ValueNotifier<RouteMapChrome?> _routeChrome = ValueNotifier(null);
  double _timeIntervalHeight = -1;
  int? _pinchId1;
  int? _pinchId2;
  Offset? _pinchP1;
  Offset? _pinchP2;
  double? _pinchStartDistance;
  double? _pinchStartHeight;
  double _calendarViewHeight = 600;

  static const Color _nonWorkingHourColor = Color(0xFFF3F4F6);

  @override
  void initState() {
    super.initState();
    _calendarController.view = CalendarView.week;
    _listenCalendarSettings();
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
      setState(() {
        _firstDayOfWeek = (data['firstDayOfWeek'] as num?)?.toInt() ?? 1;
        _workStartMinutes = SettingsService.readWorkStartMinutes(data);
        _workEndMinutes = SettingsService.readWorkEndMinutes(data);
        _travelBufferMinutes = SettingsService.readTravelBufferMinutes(data);
        _defaultDurationMinutes = SettingsService.readJobDurationMinutes(data);
        _weekendInCalendar = data['weekendInCalendar'] ?? false;
        if (!_weekendInCalendar &&
            _calendarController.view == CalendarView.week) {
          _calendarController.view = CalendarView.workWeek;
          _lastDropdownView = CalendarView.workWeek;
        }
        _isLoadingSettings = false;
      });
    }, onError: (e) {
      debugPrint('Ошибка загрузки настроек: $e');
      if (mounted) setState(() => _isLoadingSettings = false);
    });
  }

  @override
  void dispose() {
    _configSub?.cancel();
    _routeChrome.dispose();
    super.dispose();
  }

  List<TimeRegion> _nonWorkingRegions() {
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

    return regions;
  }

  Color _appointmentColor(Job job, JobVisit visit) {
    if (job.status == JobStatuses.cancelled) {
      return StatusService.colorOf(JobStatuses.cancelled);
    }
    if (visit.isDone || job.status == JobStatuses.completed) {
      return StatusService.colorOf(JobStatuses.completed);
    }
    return StatusService.colorOf(job.status);
  }

  bool _showJobOnCalendar(Job job) {
    if (job.status == JobStatuses.completed ||
        job.status == JobStatuses.cancelled ||
        job.status == JobStatuses.rescheduled) {
      return true;
    }
    return SettingsService.jobMatchesListFilter(job, _jobFilter);
  }

  String _formatRouteDate(DateTime date) {
    return DateFormat('d MMM', AppLocale.instance.dateLocale)
        .format(date)
        .replaceAll('.', '');
  }

  String get _currentViewMode {
    if (_showList) return 'list';
    final view = _calendarController.view == CalendarView.month
        ? _lastDropdownView
        : (_calendarController.view ??
            (_weekendInCalendar ? CalendarView.week : CalendarView.workWeek));
    if (view == CalendarView.week && !_weekendInCalendar) return 'workWeek';
    if (view == CalendarView.day) return 'day';
    if (view == CalendarView.week) return 'week';
    return 'workWeek';
  }

  void _selectCalendarMode(String newValue) {
    setState(() {
      if (newValue == 'list') {
        _showList = true;
        return;
      }
      _showList = false;
      _showRouteMap = false;
      _routeChrome.value = null;
      final view = newValue == 'day'
          ? CalendarView.day
          : newValue == 'week'
              ? CalendarView.week
              : CalendarView.workWeek;
      _calendarController.view = view;
      _lastDropdownView = view;
      _timeIntervalHeight = -1;
    });
  }

  Future<void> _pickRouteDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _routeDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _routeDate = picked);
  }

  Widget _compactRouteDate() {
    return ValueListenableBuilder<RouteMapChrome?>(
      valueListenable: _routeChrome,
      builder: (context, chrome, _) {
        return Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.chevron_left, color: Color(0xFF14557F)),
              onPressed: () {
                setState(() => _routeDate = _routeDate.subtract(const Duration(days: 1)));
              },
            ),
            Flexible(
              child: GestureDetector(
                onTap: _pickRouteDate,
                child: Text(
                  _formatRouteDate(_routeDate),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.chevron_right, color: Color(0xFF14557F)),
              onPressed: () {
                setState(() => _routeDate = _routeDate.add(const Duration(days: 1)));
              },
            ),
            if (chrome != null) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Расставить время по маршруту'.tr,
                icon: const Icon(Icons.schedule, color: Color(0xFF14557F)),
                onPressed: chrome.applyTimes,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Открыть в Google Maps'.tr,
                icon: const Icon(Icons.map_outlined, color: Color(0xFF14557F)),
                onPressed: chrome.openMaps,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Оптимизировать заново'.tr,
                icon: const Icon(Icons.refresh, color: Color(0xFF14557F)),
                onPressed: chrome.refresh,
              ),
              Flexible(
                child: Text(
                  chrome.distanceText,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  double get _fittedSlotHeight {
    final hours = 24.0;
    final usable = (_calendarViewHeight - 72).clamp(240.0, 4000.0);
    return (usable / hours).clamp(16.0, 80.0);
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
        _pinchStartHeight =
            _timeIntervalHeight < 0 ? _fittedSlotHeight : _timeIntervalHeight;
      }
    }
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
    if ((next - (_timeIntervalHeight < 0 ? _fittedSlotHeight : _timeIntervalHeight)).abs() < 0.5) {
      return;
    }
    setState(() => _timeIntervalHeight = next);
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
  }

  // --- ВСПЛЫВАЮЩЕЕ ОКНО ПРИ ОДИНАРНОМ КЛИКЕ ---
  void _showQuickInfoDialog(String clientName, String description) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          clientName,
          style: const TextStyle(
            color: Color(0xFF14557F),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          description.isNotEmpty ? description : 'Нет описания поломки'.tr,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ЗАКРЫТЬ'.tr, style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
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
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          color: Colors.white,
          child: Row(
            children: [
              PopupMenuButton<String>(
                tooltip: 'Вид'.tr,
                icon: const Icon(Icons.more_vert, color: Color(0xFF14557F)),
                padding: EdgeInsets.zero,
                onSelected: _selectCalendarMode,
                itemBuilder: (context) {
                  final current = _currentViewMode;
                  Widget item(String value, String label) {
                    return Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: current == value
                              ? const Icon(
                                  Icons.check,
                                  size: 18,
                                  color: Color(0xFF14557F),
                                )
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Text(label),
                      ],
                    );
                  }

                  return [
                    PopupMenuItem(
                      value: 'day',
                      child: item('day', '1 день'.tr),
                    ),
                    PopupMenuItem(
                      value: 'workWeek',
                      child: item('workWeek', '5 дней'.tr),
                    ),
                    PopupMenuItem(
                      value: 'week',
                      child: item('week', 'неделя'.tr),
                    ),
                    PopupMenuItem(
                      value: 'list',
                      child: item('list', 'список'.tr),
                    ),
                  ];
                },
              ),
              if (_showList && _showRouteMap)
                Expanded(child: _compactRouteDate())
              else
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor:
                        !_showList && _calendarController.view == CalendarView.month
                            ? const Color(0xFFFCC520)
                            : Colors.transparent,
                    foregroundColor:
                        !_showList && _calendarController.view == CalendarView.month
                            ? Colors.black
                            : const Color(0xFF14557F),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _showList = false;
                      if (_calendarController.view == CalendarView.month) {
                        _calendarController.view = _lastDropdownView;
                      } else {
                        _lastDropdownView =
                            _calendarController.view ?? CalendarView.week;
                        _calendarController.view = CalendarView.month;
                      }
                    });
                  },
                  icon: const Icon(Icons.calendar_month),
                  label: Text(
                    'Месяц'.tr,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.grey),
        if (!(_showList && _showRouteMap))
          JobStatusFilterBar(
            selectedId: _jobFilter,
            onSelected: (id) => setState(() => _jobFilter = id),
          ),

        // --- САМ КАЛЕНДАРЬ И ЕГО ДАННЫЕ ---
        Expanded(
          child: _showList
              ? JobsScreen(
                  showRouteMap: _showRouteMap,
                  onShowRouteMapChanged: (value) {
                    setState(() => _showRouteMap = value);
                    if (!value) _routeChrome.value = null;
                  },
                  routeDate: _routeDate,
                  onRouteDateChanged: (value) => setState(() => _routeDate = value),
                  hideRouteDateBar: true,
                  selectedFilter: _jobFilter,
                  onFilterChanged: (id) => setState(() => _jobFilter = id),
                  showStatusFilters: false,
                  onRouteChromeChanged: (chrome) {
                    if (!mounted) return;
                    _routeChrome.value = chrome;
                  },
                )
              : StreamBuilder<List<JobStatusDef>>(
            stream: StatusService.streamDefs(),
            builder: (context, statusSnap) {
              return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('companies')
                .doc(kCompanyId)
                .collection('jobs')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Ошибка загрузки'.tr));
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
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
                  final slotHeight = _timeIntervalHeight < 0
                      ? _fittedSlotHeight
                      : _timeIntervalHeight;
                  return Listener(
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerUp,
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
                allowDragAndDrop: _pinchId2 == null,
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
                      _lastDropdownView = CalendarView.day;
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
                  final String description = jobData['description'] ?? '';
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
                  final hatch = calendarHatchFor(
                    status: parsedJob?.status ??
                        (jobData['status'] ?? '').toString(),
                    visitDone: visit?.isDone == true,
                  );
                  final hatchIcon = calendarHatchIcon(hatch);
                  final bounds = calendarAppointmentDetails.bounds;
                  final logoSize = (bounds.height - 10).clamp(16.0, 34.0);
                  final showName = bounds.width >= 72 && bounds.height >= 28;
                  final radius = BorderRadius.circular(
                    _calendarController.view == CalendarView.month ? 4 : 8,
                  );

                  // Обертка для обработки двойных и одинарных кликов
                  return SizedBox(
                    width: bounds.width,
                    height: bounds.height,
                    child: GestureDetector(
                    onTap: () {
                      // Одинарный клик -> Показываем Инфо
                      _showQuickInfoDialog(clientName, description);
                    },
                    onDoubleTap: () {
                      // Двойной клик -> Проваливаемся в заявку
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
                                  if (hatchIcon != null) ...[
                                    Icon(hatchIcon, color: Colors.white, size: 14),
                                    const SizedBox(width: 3),
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
                                ],
                              )
                            : Center(
                                child: hatchIcon != null
                                    ? Icon(hatchIcon, color: Colors.white, size: 16)
                                    : ApplianceLogo(
                                        type: type,
                                        size: logoSize.clamp(14, 22),
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
          );
            },
          ),
        ),
      ],
        ),
        if (!_showList)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'calendar_add_fab',
              backgroundColor: AppColors.accent,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateJobScreen()),
                );
              },
              child: const Icon(Icons.add, color: Colors.black),
            ),
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
