import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/utils/app_time_picker.dart';
import '../../../services/app_time_service.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';
import '../../../core/l10n/app_locale.dart';

class CalendarSettingsPage extends StatefulWidget {
  const CalendarSettingsPage({super.key});

  @override
  State<CalendarSettingsPage> createState() => _CalendarSettingsPageState();
}

class _CalendarSettingsPageState extends State<CalendarSettingsPage> {
  bool _loading = true;
  bool _weekendInCalendar = false;
  int _firstDayOfWeek = 1;
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  int _jobDurationMinutes = SettingsService.defaultJobDurationMinutes;
  int _travelBufferMinutes = SettingsService.defaultTravelBufferMinutes;
  String _defaultCalendarView = SettingsService.defaultCalendarView;
  String _timeSource = SettingsService.timeSourceManual;
  String? _timeZoneName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SettingsService.loadConfig();
    AppTimeService.applyConfig(data);
    if (!mounted) return;
    setState(() {
      _weekendInCalendar = data['weekendInCalendar'] ?? false;
      _firstDayOfWeek = (data['firstDayOfWeek'] as num?)?.toInt() ?? 1;
      _workStartMinutes = SettingsService.readWorkStartMinutes(data);
      _workEndMinutes = SettingsService.readWorkEndMinutes(data);
      _jobDurationMinutes = SettingsService.readJobDurationMinutes(data);
      _travelBufferMinutes = SettingsService.readTravelBufferMinutes(data);
      _defaultCalendarView = SettingsService.readDefaultCalendarView(data);
      _timeSource = SettingsService.readTimeSource(data);
      _timeZoneName = data['timeZoneName'] as String?;
      _loading = false;
    });
  }

  TimeOfDay _timeFromMinutes(int minutes) {
    if (minutes >= 24 * 60) return const TimeOfDay(hour: 0, minute: 0);
    return TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  }

  Future<void> _editWorkHours() async {
    final start = await showAppTimePicker(
      context: context,
      initialTime: _timeFromMinutes(_workStartMinutes),
      helpText: 'Начало рабочего дня'.tr,
    );
    if (start == null || !mounted) return;
    final end = await showAppTimePicker(
      context: context,
      initialTime: _timeFromMinutes(_workEndMinutes),
      helpText: 'Конец рабочего дня'.tr,
    );
    if (end == null || !mounted) return;

    final startMinutes = start.hour * 60 + start.minute;
    var endMinutes = end.hour * 60 + end.minute;
    if (endMinutes == 0) endMinutes = 24 * 60;
    if (endMinutes <= startMinutes) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Конец рабочего дня должен быть позже начала'.tr),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() {
      _workStartMinutes = startMinutes;
      _workEndMinutes = endMinutes;
    });
    await SettingsService.updateConfig('workStartMinutes', startMinutes);
    await SettingsService.updateConfig('workEndMinutes', endMinutes);
  }

  Future<void> _editTimeSource() async {
    final result = await showDialog<TimeSourceResult>(
      context: context,
      builder: (context) => TimeSourceDialog(
        source: _timeSource,
        zoneName: _timeZoneName,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _timeSource = result.source;
      _timeZoneName = result.zoneName;
    });
    AppTimeService.timeSource = result.source;
    AppTimeService.timeZoneId = result.zoneId;
    AppTimeService.timeZoneName = result.zoneName;
    AppTimeService.offsetSeconds = result.offsetSeconds;
    await SettingsService.updateConfig('timeSource', result.source);
    await SettingsService.updateConfig('timeZoneId', result.zoneId);
    await SettingsService.updateConfig('timeZoneName', result.zoneName);
    await SettingsService.updateConfig('timeOffsetSeconds', result.offsetSeconds);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Календарь и время'.tr,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: 'Вид по умолчанию'.tr,
                      subtitle: SettingsService.calendarViewLabel(
                        _defaultCalendarView,
                      ).tr,
                      icon: Icons.calendar_view_week,
                      iconColor: Colors.blue,
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _defaultCalendarView,
                          items: [
                            for (final id in SettingsService.calendarViewIds)
                              DropdownMenuItem(
                                value: id,
                                child: Text(
                                  SettingsService.calendarViewLabel(id).tr,
                                ),
                              ),
                          ],
                          onChanged: (val) {
                            if (val == null) return;
                            setState(() => _defaultCalendarView = val);
                            SettingsService.updateConfig(
                              'defaultCalendarView',
                              val,
                            );
                          },
                        ),
                      ),
                    ),
                    SettingsRow(
                      title: 'Выходные дни'.tr,
                      subtitle: 'Показывать субботу и воскресенье'.tr,
                      icon: Icons.weekend,
                      iconColor: Colors.purple,
                      trailing: Switch(
                        activeThumbColor: AppColors.accent,
                        value: _weekendInCalendar,
                        onChanged: (val) {
                          setState(() => _weekendInCalendar = val);
                          SettingsService.updateConfig('weekendInCalendar', val);
                        },
                      ),
                    ),
                    SettingsRow(
                      title: 'Начало недели'.tr,
                      subtitle: _firstDayOfWeek == 1 ? 'Понедельник'.tr : 'Воскресенье'.tr,
                      icon: Icons.calendar_today,
                      iconColor: Colors.teal,
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _firstDayOfWeek,
                          items: [
                            DropdownMenuItem(value: 1, child: Text('Понедельник'.tr)),
                            DropdownMenuItem(value: 7, child: Text('Воскресенье'.tr)),
                          ],
                          onChanged: (val) {
                            if (val == null) return;
                            setState(() => _firstDayOfWeek = val);
                            SettingsService.updateConfig('firstDayOfWeek', val);
                          },
                        ),
                      ),
                    ),
                    SettingsRow(
                      title: 'Источник времени'.tr,
                      subtitle: SettingsService.timeSourceLabel(
                        _timeSource,
                        zoneName: _timeZoneName,
                      ),
                      icon: Icons.public,
                      iconColor: Colors.blueGrey,
                      onTap: _editTimeSource,
                    ),
                    SettingsRow(
                      title: 'Рабочее время'.tr,
                      subtitle: SettingsService.workHoursLabel(
                        _workStartMinutes,
                        _workEndMinutes,
                      ),
                      icon: Icons.access_time,
                      iconColor: Colors.indigo,
                      onTap: _editWorkHours,
                    ),
                    SettingsRow(
                      title: 'Длительность визита'.tr,
                      subtitle: '$_jobDurationMinutes ${'мин по умолчанию'.tr}',
                      icon: Icons.timer_outlined,
                      iconColor: Colors.teal,
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _jobDurationMinutes,
                          items: [
                            DropdownMenuItem(value: 30, child: Text('30 мин'.tr)),
                            DropdownMenuItem(value: 45, child: Text('45 мин'.tr)),
                            DropdownMenuItem(value: 60, child: Text('1 час'.tr)),
                            DropdownMenuItem(value: 90, child: Text('1.5 ч'.tr)),
                            DropdownMenuItem(value: 120, child: Text('2 часа'.tr)),
                          ],
                          onChanged: (val) {
                            if (val == null) return;
                            setState(() => _jobDurationMinutes = val);
                            SettingsService.updateConfig(
                              'defaultJobDurationMinutes',
                              val,
                            );
                          },
                        ),
                      ),
                    ),
                    SettingsRow(
                      title: 'Дорога между заявками'.tr,
                      subtitle: '$_travelBufferMinutes ${'мин буфер в календаре'.tr}',
                      icon: Icons.directions_car,
                      iconColor: Colors.orange,
                      showDivider: false,
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _travelBufferMinutes,
                          items: [
                            DropdownMenuItem(value: 0, child: Text('нет'.tr)),
                            DropdownMenuItem(value: 15, child: Text('15 мин'.tr)),
                            DropdownMenuItem(value: 20, child: Text('20 мин'.tr)),
                            DropdownMenuItem(value: 30, child: Text('30 мин'.tr)),
                            DropdownMenuItem(value: 45, child: Text('45 мин'.tr)),
                            DropdownMenuItem(value: 60, child: Text('1 час'.tr)),
                          ],
                          onChanged: (val) {
                            if (val == null) return;
                            setState(() => _travelBufferMinutes = val);
                            SettingsService.updateConfig(
                              'travelBufferMinutes',
                              val,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class TimeSourceResult {
  final String source;
  final String? zoneId;
  final String? zoneName;
  final int? offsetSeconds;

  const TimeSourceResult({
    required this.source,
    this.zoneId,
    this.zoneName,
    this.offsetSeconds,
  });
}

class TimeSourceDialog extends StatefulWidget {
  final String source;
  final String? zoneName;

  const TimeSourceDialog({required this.source, this.zoneName});

  @override
  State<TimeSourceDialog> createState() => _TimeSourceDialogState();
}

class _TimeSourceDialogState extends State<TimeSourceDialog> {
  late String _source;
  String? _zoneName;
  String? _zoneId;
  int? _offsetSeconds;
  bool _loadingGeo = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _zoneName = widget.zoneName;
    _zoneId = AppTimeService.timeZoneId;
    _offsetSeconds = AppTimeService.offsetSeconds;
  }

  Future<void> _selectGeolocation() async {
    setState(() {
      _source = SettingsService.timeSourceGeolocation;
      _loadingGeo = true;
      _error = null;
    });
    final result = await AppTimeService.detectFromLocation();
    if (!mounted) return;
    setState(() {
      _loadingGeo = false;
      if (result.info == null) {
        _error = result.error ??
            'Не удалось определить время по GPS. Проверьте геолокацию.'.tr;
        return;
      }
      _zoneId = result.info!.timeZoneId;
      _zoneName = result.info!.timeZoneName;
      _offsetSeconds = result.info!.offsetSeconds;
    });
  }

  void _save() {
    if (_source == SettingsService.timeSourceGeolocation &&
        (_offsetSeconds == null || _loadingGeo)) {
      setState(() {
        _error = _loadingGeo
            ? 'Подождите, определяется пояс по GPS'.tr
            : 'Сначала определите время по геолокации'.tr;
      });
      return;
    }
    Navigator.pop(
      context,
      TimeSourceResult(
        source: _source,
        zoneId: _source == SettingsService.timeSourceGeolocation ? _zoneId : null,
        zoneName:
            _source == SettingsService.timeSourceGeolocation ? _zoneName : null,
        offsetSeconds: _source == SettingsService.timeSourceGeolocation
            ? _offsetSeconds
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Источник времени'.tr),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<String>(
            contentPadding: EdgeInsets.zero,
            title: Text('Вручную'.tr),
            subtitle: Text('Время телефона'.tr),
            value: SettingsService.timeSourceManual,
            groupValue: _source,
            onChanged: _loadingGeo
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _source = value;
                      _error = null;
                    });
                  },
          ),
          RadioListTile<String>(
            contentPadding: EdgeInsets.zero,
            title: Text('По геолокации'.tr),
            subtitle: Text(
              _zoneName != null &&
                      _source == SettingsService.timeSourceGeolocation
                  ? _zoneName!
                  : 'Часовой пояс по GPS'.tr,
            ),
            value: SettingsService.timeSourceGeolocation,
            groupValue: _source,
            onChanged: _loadingGeo ? null : (_) => _selectGeolocation(),
          ),
          if (_loadingGeo)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(color: AppColors.primary),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _loadingGeo ? null : _selectGeolocation,
                child: Text('Повторить'.tr),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Отмена'.tr),
        ),
        ElevatedButton(
          onPressed: _loadingGeo ? null : _save,
          child: Text('Сохранить'.tr),
        ),
      ],
    );
  }
}
