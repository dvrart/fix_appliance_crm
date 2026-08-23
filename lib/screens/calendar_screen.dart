// Файл: lib/screens/calendar_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import '../core/app_commands.dart';
import '../core/haptics.dart';
import '../shared/widgets/ai_head.dart';
import 'job_details_screen.dart';
import 'create_job_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final CalendarController _calendarController = CalendarController();

  int _firstDayOfWeek = 1; // 1 = Понедельник
  bool _isLoadingSettings = true;
  CalendarView _lastDropdownView = CalendarView.week;

  DateTime? _lastTapTime;
  DateTime? _lastTapDate;

  @override
  void initState() {
    super.initState();
    _calendarController.view = CalendarView.week;
    _loadCalendarSettings();
    AppCommands.calendarMode.addListener(_onCalendarCommand);
  }

  void _onCalendarCommand() {
    final mode = AppCommands.calendarMode.value;
    if (mode == null || !mounted) return;
    AppCommands.calendarMode.value = null;
    setState(() {
      _calendarController.view = mode == 'day'
          ? CalendarView.day
          : mode == 'workWeek'
              ? CalendarView.workWeek
              : CalendarView.week;
      _lastDropdownView = _calendarController.view ?? CalendarView.week;
    });
  }

  Future<void> _loadCalendarSettings() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('settings')
          .doc('config')
          .get();

      if (doc.exists && doc.data() != null) {
        setState(() {
          _firstDayOfWeek = doc.data()!['firstDayOfWeek'] ?? 1;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки настроек: $e');
    } finally {
      if (mounted) setState(() => _isLoadingSettings = false);
    }
  }

  Color _getStatusColor(String status) {
    if (status == 'Завершено') return Colors.green;
    if (status == 'В работе' || status == 'Ожидание запчасти')
      return Colors.red.shade400;
    if (status == 'В пути') return Colors.orange;
    return const Color(0xFF14557F);
  }

  // --- ФУНКЦИЯ ДЛЯ ВЫБОРА ИКОНКИ (ЛОГОТИПА) ТЕХНИКИ ---
  IconData _getApplianceIcon(String type) {
    final t = type.toLowerCase();
    if (t.contains('холод') ||
        t.contains('fridge') ||
        t.contains('refrigerator'))
      return Icons.kitchen;
    if (t.contains('стирал') || t.contains('wash'))
      return Icons.local_laundry_service;
    if (t.contains('суш') || t.contains('dryer')) return Icons.heat_pump;
    if (t.contains('посуд') || t.contains('dish')) return Icons.local_dining;
    if (t.contains('плит') ||
        t.contains('духов') ||
        t.contains('stove') ||
        t.contains('oven'))
      return Icons.microwave;
    if (t.contains('микроволн') || t.contains('microwave'))
      return Icons.microwave;
    return Icons.build; // Иконка по умолчанию, если техника неизвестна
  }

  @override
  void dispose() {
    AppCommands.calendarMode.removeListener(_onCalendarCommand);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingSettings) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFCC520)),
      );
    }

    final currentDropdownView = _calendarController.view == CalendarView.month
        ? _lastDropdownView
        : (_calendarController.view ?? CalendarView.week);

    return Column(
      children: [
        // --- ВЕРХНЯЯ ПАНЕЛЬ С ВЫБОРОМ ВИДА ---
        Container(
          height: 48,
          padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
          color: const Color(0xFF14557F),
          child: Row(
            children: [
              const AiHead(size: 30),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<CalendarView>(
                    value: currentDropdownView,
                    isDense: true,
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Color(0xFF14557F),
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF14557F),
                      fontSize: 14,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: CalendarView.day,
                        child: Text('1 День'),
                      ),
                      DropdownMenuItem(
                        value: CalendarView.workWeek,
                        child: Text('5 Дней'),
                      ),
                      DropdownMenuItem(
                        value: CalendarView.week,
                        child: Text('Неделя'),
                      ),
                    ],
                    onChanged: (CalendarView? newValue) {
                      AppHaptics.button();
                      if (newValue != null) {
                        setState(() {
                          _calendarController.view = newValue;
                          _lastDropdownView = newValue;
                        });
                      }
                    },
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor:
                      _calendarController.view == CalendarView.month
                      ? const Color(0xFFFCC520)
                      : Colors.transparent,
                  foregroundColor:
                      _calendarController.view == CalendarView.month
                      ? Colors.black
                      : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () {
                  AppHaptics.button();
                  setState(() {
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
                label: const Text(
                  'Месяц',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.grey),

        // --- САМ КАЛЕНДАРЬ И ЕГО ДАННЫЕ ---
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            // ВАЖНО: Мы исправили этот путь вчера, чтобы календарь видел все заявки
            stream: FirebaseFirestore.instance
                .collection('companies')
                .doc('fix_appliance_ca')
                .collection('jobs')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return const Center(child: Text('Ошибка загрузки'));
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                );
              }

              List<Appointment> appointments = [];
              for (var doc in snapshot.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                final scheduledAt = data['scheduledAt'] as Timestamp?;

                if (scheduledAt != null) {
                  final startTime = scheduledAt.toDate();
                  final status = data['status'] ?? 'Вызов';

                  appointments.add(
                    Appointment(
                      startTime: startTime,
                      endTime: startTime.add(const Duration(hours: 1)),
                      color: _getStatusColor(status),
                      id: doc
                          .id, // Передаем ID работы, чтобы потом достать из нее всю инфу
                    ),
                  );
                }
              }

              return SfCalendar(
                controller: _calendarController,
                firstDayOfWeek: _firstDayOfWeek,
                dataSource: JobDataSource(appointments),
                timeSlotViewSettings: const TimeSlotViewSettings(
                  startHour: 8,
                  endHour: 20,
                  timeFormat: 'HH:mm',
                  timeIntervalHeight: 90,
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

                  // 2. Открытие готовой заявки
                  if (details.targetElement == CalendarElement.appointment &&
                      details.appointments != null) {
                    final Appointment app = details.appointments!.first;
                    final originalJobDoc = snapshot.data!.docs.firstWhere(
                      (doc) => doc.id == app.id,
                    );
                    final jobData =
                        originalJobDoc.data() as Map<String, dynamic>;

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => JobDetailsScreen(
                          jobId: app.id.toString(),
                          clientId: jobData['clientId'] ?? '',
                          jobData: jobData,
                        ),
                      ),
                    );
                    return;
                  }

                  // 3. Создание новой заявки (Двойной клик)
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

                  // Вытягиваем ВСЕ данные о работе по ее ID
                  final originalJobDoc = snapshot.data!.docs.firstWhere(
                    (doc) => doc.id == app.id,
                  );
                  final jobData = originalJobDoc.data() as Map<String, dynamic>;

                  // 1. Определяем адрес и пытаемся достать оттуда город
                  final bool hasJobSite = jobData['hasJobSite'] == true;
                  final String rawAddress = hasJobSite
                      ? (jobData['jobSiteAddress'] ?? '')
                      : (jobData['clientAddress'] ?? '');

                  String city = rawAddress;
                  final addressParts = rawAddress.split(',');
                  if (addressParts.length >= 2) {
                    city = addressParts[1]
                        .trim(); // Обычно город идет после первой запятой
                  }
                  if (city.isEmpty) city = 'Город не указан';

                  // 2. Вытягиваем технику и статус
                  final String applianceType =
                      jobData['applianceType'] ?? 'Техника';
                  final String status = jobData['status'] ?? 'Вызов';

                  // Если включен вид "Месяц" (места в ячейке очень мало)
                  if (_calendarController.view == CalendarView.month) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: app.color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _getApplianceIcon(applianceType),
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(
                              city,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // Если включен вид "День" или "Неделя" (места много, рисуем по ТЗ)
                  return Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: app.color,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // ГОРОД (СВЕРХУ)
                        Text(
                          city,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),

                        // ЛОГОТИП ТЕХНИКИ (ПО ЦЕНТРУ)
                        Expanded(
                          child: Center(
                            child: Icon(
                              _getApplianceIcon(applianceType),
                              color: Colors.white.withOpacity(0.95),
                              size: 28, // Крупная иконка
                            ),
                          ),
                        ),

                        // СТАТУС (СНИЗУ)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            status,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
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
