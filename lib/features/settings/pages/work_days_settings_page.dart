import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/utils/app_time_picker.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';

/// Когда мастер выезжает: дни недели, часы, праздники и отпуск.
/// Всё живёт в `settings/config`, потому что календарь и секретарь читают
/// одни и те же поля.
class WorkDaysSettingsPage extends StatefulWidget {
  const WorkDaysSettingsPage({super.key});

  @override
  State<WorkDaysSettingsPage> createState() => _WorkDaysSettingsPageState();
}

class _WorkDaysSettingsPageState extends State<WorkDaysSettingsPage> {
  bool _loading = true;
  bool _dirty = false;
  Set<int> _days = {...SettingsService.defaultWorkDays};
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  List<String> _holidays = [];
  List<({String from, String to})> _vacations = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    setState(() {
      _days = {...SettingsService.readWorkDays(config)};
      _workStartMinutes = SettingsService.readWorkStartMinutes(config);
      _workEndMinutes = SettingsService.readWorkEndMinutes(config);
      _holidays = [...SettingsService.readHolidayDates(config)];
      _vacations = [...SettingsService.readVacationRanges(config)];
      _loading = false;
      _dirty = false;
    });
  }

  Future<bool> _save() async {
    final days = _days.toList()..sort();
    await SettingsService.updateConfigMap({
      'workDays': days,
      'workStartMinutes': _workStartMinutes,
      'workEndMinutes': _workEndMinutes,
      'holidayDates': _holidays,
      'vacationRanges': SettingsService.serializeVacationRanges(_vacations),
    });
    if (!mounted) return true;
    setState(() => _dirty = false);
    return true;
  }

  TimeOfDay _timeFromMinutes(int minutes) {
    if (minutes >= 24 * 60) return const TimeOfDay(hour: 0, minute: 0);
    return TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  }

  Future<void> _editWorkHours() async {
    final start = await showAppTimePicker(
      context: context,
      initialTime: _timeFromMinutes(_workStartMinutes),
      helpText: context.tr('Начало рабочего дня', 'Day starts'),
    );
    if (start == null || !mounted) return;
    final end = await showAppTimePicker(
      context: context,
      initialTime: _timeFromMinutes(_workEndMinutes),
      helpText: context.tr('Конец рабочего дня', 'Day ends'),
    );
    if (end == null || !mounted) return;

    final startMinutes = start.hour * 60 + start.minute;
    var endMinutes = end.hour * 60 + end.minute;
    if (endMinutes == 0) endMinutes = 24 * 60;
    if (endMinutes <= startMinutes) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Конец рабочего дня должен быть позже начала',
              'The end of the day must be after the start',
            ),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() {
      _workStartMinutes = startMinutes;
      _workEndMinutes = endMinutes;
      _dirty = true;
    });
  }

  String _pretty(String key) {
    final date = DateTime.tryParse(key);
    if (date == null) return key;
    final locale = AppLocale.instance.isEn ? 'en' : 'ru';
    return DateFormat('d MMMM yyyy, EEE', locale).format(date);
  }

  Future<void> _addHoliday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: context.tr('Выходной день', 'Day off'),
    );
    if (picked == null || !mounted) return;
    final key = SettingsService.ymd(picked);
    if (_holidays.contains(key)) return;
    setState(() {
      _holidays = [..._holidays, key]..sort();
      _dirty = true;
    });
  }

  Future<void> _addVacation() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: context.tr('Отпуск', 'Vacation'),
      saveText: context.tr('Готово', 'Done'),
    );
    if (range == null || !mounted) return;
    setState(() {
      _vacations = [
        ..._vacations,
        (from: SettingsService.ymd(range.start), to: SettingsService.ymd(range.end)),
      ]..sort((a, b) => a.from.compareTo(b.from));
      _dirty = true;
    });
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _emptyHint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: Colors.black45),
      ),
    );
  }

  Widget _addButton(String label, VoidCallback onTap) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add_circle_outline),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Рабочие дни', 'Working days'),
      dirty: _dirty,
      onSave: _save,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    context.tr(
                      'В нерабочий день секретарь всё равно примет заявку, но визит предложит на другой день.',
                      'On a day off the secretary still takes the order and offers another day for the visit.',
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                      height: 1.3,
                    ),
                  ),
                ),
                _card(
                  title: context.tr('Выезжаю', 'I visit on'),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var day = 1; day <= 7; day++)
                          FilterChip(
                            label: Text(SettingsService.weekdayShort(day)),
                            selected: _days.contains(day),
                            selectedColor: AppColors.accent,
                            checkmarkColor: Colors.black,
                            labelStyle: TextStyle(
                              fontWeight: _days.contains(day)
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: Colors.black87,
                            ),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _days.add(day);
                                } else {
                                  _days.remove(day);
                                }
                                _dirty = true;
                              });
                            },
                          ),
                      ],
                    ),
                    if (_days.isEmpty)
                      _emptyHint(
                        context.tr(
                          'Ни одного дня — визиты не назначаются вообще.',
                          'No day selected — no visits can be booked at all.',
                        ),
                      ),
                  ],
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('Часы', 'Hours'),
                      subtitle: SettingsService.workHoursLabel(
                        _workStartMinutes,
                        _workEndMinutes,
                      ),
                      icon: Icons.access_time,
                      iconColor: Colors.indigo,
                      showDivider: false,
                      onTap: _editWorkHours,
                    ),
                  ],
                ),
                _card(
                  title: context.tr('Праздники', 'Holidays'),
                  children: [
                    if (_holidays.isEmpty)
                      _emptyHint(
                        context.tr('Пока пусто', 'Nothing yet'),
                      ),
                    for (final key in _holidays)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.event_busy,
                          color: Colors.redAccent,
                        ),
                        title: Text(_pretty(key)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () {
                            setState(() {
                              _holidays = [..._holidays]..remove(key);
                              _dirty = true;
                            });
                          },
                        ),
                      ),
                    _addButton(
                      context.tr('Добавить день', 'Add a day'),
                      _addHoliday,
                    ),
                  ],
                ),
                _card(
                  title: context.tr('Отпуск', 'Vacation'),
                  children: [
                    if (_vacations.isEmpty)
                      _emptyHint(
                        context.tr('Пока пусто', 'Nothing yet'),
                      ),
                    for (final range in _vacations)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.beach_access,
                          color: Colors.teal,
                        ),
                        title: Text(_pretty(range.from)),
                        subtitle: range.to == range.from
                            ? null
                            : Text(
                                '${context.tr('по', 'through')} ${_pretty(range.to)}',
                              ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () {
                            setState(() {
                              _vacations = [..._vacations]..remove(range);
                              _dirty = true;
                            });
                          },
                        ),
                      ),
                    _addButton(
                      context.tr('Добавить отпуск', 'Add vacation'),
                      _addVacation,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
