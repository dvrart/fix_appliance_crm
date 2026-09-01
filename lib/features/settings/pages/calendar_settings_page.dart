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
  int _firstDayOfWeek = 1;
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _workEndMinutes = SettingsService.defaultWorkEndMinutes;
  int _jobDurationMinutes = SettingsService.defaultJobDurationMinutes;
  String _defaultCalendarView = SettingsService.defaultCalendarView;
  String _timeSource = SettingsService.timeSourceManual;
  String? _timeZoneName;
  String? _timeZoneId;
  int? _timeOffsetSeconds;

  int _savedFirstDayOfWeek = 1;
  int _savedWorkStart = SettingsService.defaultWorkStartMinutes;
  int _savedWorkEnd = SettingsService.defaultWorkEndMinutes;
  int _savedDuration = SettingsService.defaultJobDurationMinutes;
  String _savedView = SettingsService.defaultCalendarView;
  String _savedTimeSource = SettingsService.timeSourceManual;
  String? _savedZoneName;
  String? _savedZoneId;
  int? _savedOffset;

  bool get _dirty =>
      !_loading &&
      (_firstDayOfWeek != _savedFirstDayOfWeek ||
          _workStartMinutes != _savedWorkStart ||
          _workEndMinutes != _savedWorkEnd ||
          _jobDurationMinutes != _savedDuration ||
          _defaultCalendarView != _savedView ||
          _timeSource != _savedTimeSource ||
          _timeZoneName != _savedZoneName ||
          _timeZoneId != _savedZoneId ||
          _timeOffsetSeconds != _savedOffset);

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
      _firstDayOfWeek = (data['firstDayOfWeek'] as num?)?.toInt() ?? 1;
      _workStartMinutes = SettingsService.readWorkStartMinutes(data);
      _workEndMinutes = SettingsService.readWorkEndMinutes(data);
      _jobDurationMinutes = SettingsService.readJobDurationMinutes(data);
      _defaultCalendarView = SettingsService.readDefaultCalendarView(data);
      _timeSource = SettingsService.readTimeSource(data);
      _timeZoneName = data['timeZoneName'] as String?;
      _timeZoneId = data['timeZoneId'] as String?;
      _timeOffsetSeconds = (data['timeOffsetSeconds'] as num?)?.toInt();
      _savedFirstDayOfWeek = _firstDayOfWeek;
      _savedWorkStart = _workStartMinutes;
      _savedWorkEnd = _workEndMinutes;
      _savedDuration = _jobDurationMinutes;
      _savedView = _defaultCalendarView;
      _savedTimeSource = _timeSource;
      _savedZoneName = _timeZoneName;
      _savedZoneId = _timeZoneId;
      _savedOffset = _timeOffsetSeconds;
      _loading = false;
    });
  }

  Future<bool> _save() async {
    await SettingsService.updateConfigMap({
      'firstDayOfWeek': _firstDayOfWeek,
      'workStartMinutes': _workStartMinutes,
      'workEndMinutes': _workEndMinutes,
      'defaultJobDurationMinutes': _jobDurationMinutes,
      'defaultCalendarView': _defaultCalendarView,
      'timeSource': _timeSource,
      'timeZoneId': _timeZoneId,
      'timeZoneName': _timeZoneName,
      'timeOffsetSeconds': _timeOffsetSeconds,
    });
    AppTimeService.timeSource = _timeSource;
    AppTimeService.timeZoneId = _timeZoneId;
    AppTimeService.timeZoneName = _timeZoneName;
    AppTimeService.offsetSeconds = _timeOffsetSeconds;
    if (!mounted) return true;
    setState(() {
      _savedFirstDayOfWeek = _firstDayOfWeek;
      _savedWorkStart = _workStartMinutes;
      _savedWorkEnd = _workEndMinutes;
      _savedDuration = _jobDurationMinutes;
      _savedView = _defaultCalendarView;
      _savedTimeSource = _timeSource;
      _savedZoneName = _timeZoneName;
      _savedZoneId = _timeZoneId;
      _savedOffset = _timeOffsetSeconds;
    });
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
      _timeZoneId = result.zoneId;
      _timeOffsetSeconds = result.offsetSeconds;
    });
  }

  Future<T?> _pickSheet<T>({
    required String title,
    required List<({T value, String label})> options,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final opt in options)
              ListTile(
                title: Text(opt.label),
                trailing: opt.value == current
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, opt.value),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDefaultView() async {
    final next = await _pickSheet<String>(
      title: 'Вид по умолчанию'.tr,
      current: _defaultCalendarView,
      options: [
        for (final id in SettingsService.calendarViewIds)
          (value: id, label: SettingsService.calendarViewLabel(id).tr),
      ],
    );
    if (next == null || !mounted) return;
    setState(() => _defaultCalendarView = next);
  }

  Future<void> _pickWeekStart() async {
    final next = await _pickSheet<int>(
      title: 'Начало недели'.tr,
      current: _firstDayOfWeek,
      options: [
        (value: 1, label: 'Понедельник'.tr),
        (value: 7, label: 'Воскресенье'.tr),
      ],
    );
    if (next == null || !mounted) return;
    setState(() => _firstDayOfWeek = next);
  }

  Future<void> _pickDuration() async {
    final next = await _pickSheet<int>(
      title: 'Длительность визита'.tr,
      current: _jobDurationMinutes,
      options: [
        (value: 30, label: '30 мин'.tr),
        (value: 45, label: '45 мин'.tr),
        (value: 60, label: '1 час'.tr),
        (value: 90, label: '1.5 ч'.tr),
        (value: 120, label: '2 часа'.tr),
        (value: 180, label: '3 часа'.tr),
      ],
    );
    if (next == null || !mounted) return;
    setState(() => _jobDurationMinutes = next);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Календарь и время'.tr,
      dirty: _dirty,
      onSave: _save,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                SettingsTileSection(
                  title: 'Календарь'.tr,
                  tiles: [
                    SettingsHubTile(
                      title: 'Вид'.tr,
                      subtitle: SettingsService.calendarViewLabel(
                        _defaultCalendarView,
                      ).tr,
                      icon: Icons.calendar_view_week,
                      color: Colors.blue,
                      onTap: _pickDefaultView,
                    ),
                    SettingsHubTile(
                      title: 'Неделя'.tr,
                      subtitle: _firstDayOfWeek == 1 ? 'Пн'.tr : 'Вс'.tr,
                      icon: Icons.calendar_today,
                      color: Colors.teal,
                      onTap: _pickWeekStart,
                    ),
                    SettingsHubTile(
                      title: 'Время'.tr,
                      subtitle: SettingsService.timeSourceLabel(
                        _timeSource,
                        zoneName: _timeZoneName,
                      ),
                      icon: Icons.public,
                      color: Colors.blueGrey,
                      onTap: _editTimeSource,
                    ),
                    SettingsHubTile(
                      title: 'Часы'.tr,
                      subtitle: SettingsService.workHoursLabel(
                        _workStartMinutes,
                        _workEndMinutes,
                      ),
                      icon: Icons.access_time,
                      color: Colors.indigo,
                      onTap: _editWorkHours,
                    ),
                    SettingsHubTile(
                      title: 'Визит'.tr,
                      subtitle: '$_jobDurationMinutes ${'мин'.tr}',
                      icon: Icons.timer_outlined,
                      color: Colors.teal,
                      onTap: _pickDuration,
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
