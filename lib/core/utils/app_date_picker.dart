import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../shared/widgets/app_bar_save.dart';
import '../constants.dart';
import '../l10n/app_locale.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Месяц и сразу под ним барабан времени — без второго окна.
/// Нижняя часть экрана, чтобы всё доставалось большим пальцем.
class AppDateTimePanel extends StatefulWidget {
  final DateTime value;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool showTime;
  final ValueChanged<DateTime> onChanged;
  final ValueChanged<DateTime>? onDayTap;

  /// Подсветка периода (отпуск): от [rangeStart] до [rangeEnd] включительно.
  final DateTime? rangeStart;
  final DateTime? rangeEnd;

  const AppDateTimePanel({
    super.key,
    required this.value,
    required this.firstDate,
    required this.lastDate,
    required this.onChanged,
    this.showTime = true,
    this.onDayTap,
    this.rangeStart,
    this.rangeEnd,
  });

  @override
  State<AppDateTimePanel> createState() => _AppDateTimePanelState();
}

/// Барабан часов и минут (24 ч) без круговой прокрутки: 00–23 и 00–59.
/// Меняет только время у [value], дата остаётся.
class AppTimeWheel extends StatefulWidget {
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final double height;

  const AppTimeWheel({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = 132,
  });

  @override
  State<AppTimeWheel> createState() => _AppTimeWheelState();
}

class _AppTimeWheelState extends State<AppTimeWheel> {
  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _hour = widget.value.hour.clamp(0, 23);
    _minute = widget.value.minute.clamp(0, 59);
    _hourController = FixedExtentScrollController(initialItem: _hour);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void didUpdateWidget(covariant AppTimeWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextHour = widget.value.hour.clamp(0, 23);
    final nextMinute = widget.value.minute.clamp(0, 59);
    if (nextHour != _hour) {
      _hour = nextHour;
      if (_hourController.hasClients) {
        _hourController.jumpToItem(_hour);
      }
    }
    if (nextMinute != _minute) {
      _minute = nextMinute;
      if (_minuteController.hasClients) {
        _minuteController.jumpToItem(_minute);
      }
    }
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  void _emit(int hour, int minute) {
    if (hour == _hour && minute == _minute) return;
    _hour = hour;
    _minute = minute;
    HapticFeedback.selectionClick();
    widget.onChanged(
      DateTime(
        widget.value.year,
        widget.value.month,
        widget.value.day,
        _hour,
        _minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: AppColors.ink,
    );
    return SizedBox(
      height: widget.height,
      child: CupertinoTheme(
        data: CupertinoThemeData(
          brightness: AppColors.isDark ? Brightness.dark : Brightness.light,
          textTheme: CupertinoTextThemeData(
            dateTimePickerTextStyle: textStyle,
            pickerTextStyle: textStyle,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 96,
              child: CupertinoPicker(
                scrollController: _hourController,
                itemExtent: 36,
                looping: false,
                selectionOverlay:
                    const CupertinoPickerDefaultSelectionOverlay(
                      capEndEdge: false,
                    ),
                onSelectedItemChanged: (h) => _emit(h.clamp(0, 23), _minute),
                children: [
                  for (var h = 0; h < 24; h++)
                    Center(
                      child: Text(
                        h.toString().padLeft(2, '0'),
                        style: textStyle,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(':', style: textStyle),
            ),
            SizedBox(
              width: 96,
              child: CupertinoPicker(
                scrollController: _minuteController,
                itemExtent: 36,
                looping: false,
                selectionOverlay:
                    const CupertinoPickerDefaultSelectionOverlay(
                      capStartEdge: false,
                    ),
                onSelectedItemChanged: (m) => _emit(_hour, m.clamp(0, 59)),
                children: [
                  for (var m = 0; m < 60; m++)
                    Center(
                      child: Text(
                        m.toString().padLeft(2, '0'),
                        style: textStyle,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppDateTimePanelState extends State<AppDateTimePanel> {
  late DateTime _month = DateTime(widget.value.year, widget.value.month);

  @override
  void didUpdateWidget(covariant AppDateTimePanel old) {
    super.didUpdateWidget(old);
    if (old.value.year != widget.value.year ||
        old.value.month != widget.value.month) {
      _month = DateTime(widget.value.year, widget.value.month);
    }
  }

  bool get _canPrev => _month.isAfter(
    DateTime(widget.firstDate.year, widget.firstDate.month),
  );

  bool get _canNext => _month.isBefore(
    DateTime(widget.lastDate.year, widget.lastDate.month),
  );

  void _shiftMonth(int delta) {
    HapticFeedback.selectionClick();
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  void _pickDay(DateTime day) {
    HapticFeedback.selectionClick();
    final v = widget.value;
    final next = DateTime(day.year, day.month, day.day, v.hour, v.minute);
    widget.onChanged(next);
    widget.onDayTap?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        _weekdays(),
        _grid(),
        if (widget.showTime) ...[
          const SizedBox(height: 4),
          AppTimeWheel(value: widget.value, onChanged: widget.onChanged),
        ],
      ],
    );
  }

  Widget _header() {
    final title = DateFormat(
      'LLLL yyyy',
      AppLocale.instance.dateLocale,
    ).format(_month);
    return Row(
      children: [
        IconButton(
          onPressed: _canPrev ? () => _shiftMonth(-1) : null,
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
        ),
        Expanded(
          child: Text(
            title[0].toUpperCase() + title.substring(1),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.primaryOnCard,
            ),
          ),
        ),
        IconButton(
          onPressed: _canNext ? () => _shiftMonth(1) : null,
          icon: const Icon(Icons.chevron_right_rounded, size: 30),
        ),
      ],
    );
  }

  Widget _weekdays() {
    final fmt = DateFormat.E(AppLocale.instance.dateLocale);
    // 2024-01-01 — понедельник.
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Text(
              fmt.format(DateTime(2024, 1, 1 + i)),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: i >= 5 ? Colors.red.shade400 : AppColors.inkMuted,
              ),
            ),
          ),
      ],
    );
  }

  Widget _grid() {
    final first = DateTime(_month.year, _month.month);
    final lead = first.weekday - 1;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final rows = ((lead + daysInMonth) / 7).ceil();
    final today = _day(DateTime.now());
    final ranged = widget.rangeStart != null;
    final selected = _day(widget.rangeStart ?? widget.value);
    final rangeEnd = widget.rangeEnd == null ? null : _day(widget.rangeEnd!);
    final min = _day(widget.firstDate);
    final max = _day(widget.lastDate);
    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final n = r * 7 + c - lead + 1;
                      if (n < 1 || n > daysInMonth) {
                        return const SizedBox(height: 40);
                      }
                      final day = DateTime(_month.year, _month.month, n);
                      final enabled = !day.isBefore(min) && !day.isAfter(max);
                      final isSel = day == selected || day == rangeEnd;
                      final isToday = day == today;
                      final inRange =
                          ranged &&
                          rangeEnd != null &&
                          day.isAfter(selected) &&
                          day.isBefore(rangeEnd);
                      return Container(
                        height: 40,
                        color: inRange
                            ? AppColors.primary.withValues(alpha: 0.12)
                            : null,
                        child: Center(
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: enabled ? () => _pickDay(day) : null,
                            child: Container(
                              width: 38,
                              height: 38,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSel ? AppColors.primary : null,
                                border: isToday && !isSel
                                    ? Border.all(
                                        color: AppColors.primary,
                                        width: 1.6,
                                      )
                                    : null,
                              ),
                              child: Text(
                                '$n',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: isSel || isToday
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: !enabled
                                      ? AppColors.inkMuted.withValues(alpha: 0.4)
                                      : isSel
                                      ? Colors.white
                                      : AppColors.ink,
                                ),
                              ),
                            ),
                          ),
                        ),
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

/// Крупная зелёная галочка внизу окна выбора.
class AppSheetConfirmButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String? label;

  const AppSheetConfirmButton({super.key, this.onPressed, this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: ElevatedButton.icon(
        onPressed: onPressed == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onPressed!();
              },
        icon: const Icon(Icons.check_rounded, size: 28),
        label: Text(
          label ?? 'Готово'.tr,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: kConfirmGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

Widget _sheetTitle(String title, String? subtitle) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Column(
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.ink,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle,
              style: TextStyle(fontSize: 14, color: AppColors.inkMuted),
            ),
          ),
      ],
    ),
  );
}

String appDateTimeLabel(DateTime value, {bool withTime = true}) {
  final date = DateFormat(
    'EEE, d MMM',
    AppLocale.instance.dateLocale,
  ).format(value);
  return withTime ? '$date · ${DateFormat('HH:mm').format(value)}' : date;
}

/// Дата и время в одном окне снизу. Возвращает null при отмене.
Future<DateTime?> showAppDateTimeSheet({
  required BuildContext context,
  required DateTime initial,
  DateTime? firstDate,
  DateTime? lastDate,
  String? title,
}) {
  final now = DateTime.now();
  final first = firstDate ?? DateTime(now.year - 1);
  final last = lastDate ?? DateTime(now.year + 3);
  var value = initial.isBefore(first)
      ? first
      : initial.isAfter(last)
      ? last
      : initial;
  return showModalBottomSheet<DateTime>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(title ?? 'Дата и время'.tr, appDateTimeLabel(value)),
              AppDateTimePanel(
                value: value,
                firstDate: first,
                lastDate: last,
                onChanged: (v) => setSheet(() => value = v),
              ),
              const SizedBox(height: 8),
              AppSheetConfirmButton(
                onPressed: () => Navigator.pop(sheetContext, value),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Период (с — по), окно снизу: первое нажатие — начало, второе — конец.
Future<DateTimeRange?> showAppDateRangeSheet({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  String? title,
}) {
  DateTime? start;
  DateTime? end;
  final fmt = DateFormat('d MMM', AppLocale.instance.dateLocale);
  return showModalBottomSheet<DateTimeRange>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheet) {
        final hint = start == null
            ? 'Нажмите первый день'.tr
            : end == null
            ? '${fmt.format(start!)} — ${'нажмите последний день'.tr}'
            : '${fmt.format(start!)} — ${fmt.format(end!)}';
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sheetTitle(title ?? 'Период'.tr, hint),
                AppDateTimePanel(
                  value: start ?? DateTime.now(),
                  rangeStart: start ?? DateTime(1900),
                  rangeEnd: end,
                  firstDate: firstDate,
                  lastDate: lastDate,
                  showTime: false,
                  onChanged: (_) {},
                  onDayTap: (v) => setSheet(() {
                    final d = _day(v);
                    if (start == null || end != null || d.isBefore(start!)) {
                      start = d;
                      end = null;
                    } else {
                      end = d;
                    }
                  }),
                ),
                const SizedBox(height: 8),
                AppSheetConfirmButton(
                  onPressed: start == null
                      ? null
                      : () => Navigator.pop(
                          sheetContext,
                          DateTimeRange(start: start!, end: end ?? start!),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Только дата, окно снизу. Нажатие на число сразу закрывает окно.
Future<DateTime?> showAppDateSheet({
  required BuildContext context,
  required DateTime initial,
  required DateTime firstDate,
  required DateTime lastDate,
  String? title,
}) {
  final init = initial.isBefore(firstDate)
      ? firstDate
      : initial.isAfter(lastDate)
      ? lastDate
      : initial;
  final value = _day(init);
  return showModalBottomSheet<DateTime>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(title ?? 'Выберите дату'.tr, null),
            AppDateTimePanel(
              value: value,
              firstDate: firstDate,
              lastDate: lastDate,
              showTime: false,
              onChanged: (_) {},
              onDayTap: (v) => Navigator.pop(sheetContext, _day(v)),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: TextButton(
                      onPressed: () =>
                          Navigator.pop(sheetContext, _day(DateTime.now())),
                      child: Text(
                        'Сегодня'.tr,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(
                        'Отмена'.tr,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.inkMuted,
                        ),
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
}
