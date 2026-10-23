import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Фиксированный размер карточки визита в многодневном календаре (5 дней / неделя): 37×37.
const double kCalendarCardSide = 37.0;

/// Фиксированный размер карточки визита в виде на 1 день: 50×50.
const double kCalendarDayCardSide = 50.0;

/// Размер стороны карточки для количества видимых дней в часовой сетке.
double calendarCardSideForDays(int visibleDayCount) {
  return visibleDayCount == 1 ? kCalendarDayCardSide : kCalendarCardSide;
}

/// Зазор между карточками, когда в одном часе несколько визитов.
const double kCalendarCardGap = 2.0;

/// Отступ карточки от верхней и нижней границ часа.
const double kCalendarHourInset = 1.0;

/// Минимальная высота одного часа, чтобы карточка 37×37 всегда помещалась целиком.
const double kMinCalendarHourHeight =
    kCalendarCardSide + kCalendarHourInset * 2;

/// Размер карточки визита внутри слота календаря.
class CalendarCardShape {
  const CalendarCardShape({
    required this.slot,
    required this.width,
    required this.height,
  });

  /// Прямоугольник слота.
  final Size slot;

  final double width;
  final double height;

  Size get size => Size(width, height);

  /// Карточка выше слота.
  bool get overflows => height > slot.height + 0.5;
}

/// В часовых видах карточка фиксированного квадратного размера
/// (`37×37` в 5 днях / неделе и `50×50` в 1 дне).
/// В месяце (`square: false`) размер остаётся по слоту ячейки.
CalendarCardShape calendarCardShape({
  required Size slot,
  required double freeHeight,
  required bool square,
  double minHeight = 0,
  double cardSide = kCalendarCardSide,
  double? maxSide,
}) {
  if (square) {
    final target = maxSide != null ? math.min(cardSide, maxSide) : cardSide;
    final side = slot.width > 0 ? math.min(slot.width, target) : target;
    return CalendarCardShape(slot: slot, width: side, height: side);
  }
  final room = math.max(slot.height, freeHeight);
  final height = math.min(math.max(slot.height, minHeight), room);
  return CalendarCardShape(
    slot: slot,
    width: slot.width,
    height: math.max(0.0, height),
  );
}

/// Кладёт карточку в слот календаря по центру колонки.
class CalendarCardSlot extends StatelessWidget {
  const CalendarCardSlot({super.key, required this.shape, required this.child});

  final CalendarCardShape shape;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: shape.slot.width,
      height: shape.slot.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: (shape.slot.width - shape.width) / 2,
            width: shape.width,
            height: shape.height,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Элемент расписания для расчёта адаптивной шкалы времени.
class CalendarSlotItem {
  const CalendarSlotItem({required this.id, required this.startTime});

  final String id;
  final DateTime startTime;
}

/// Координаты конкретной карточки 30×30 внутри колонки дня.
class CalendarCardPlacement {
  const CalendarCardPlacement({
    required this.id,
    required this.day,
    required this.hour,
    required this.topInHour,
    required this.topInDay,
    required this.size,
  });

  final String id;
  final DateTime day;
  final int hour;
  final double topInHour;
  final double topInDay;
  final Size size;

  Rect rectInColumn(double columnLeft, double columnWidth) {
    final side = columnWidth > 0
        ? math.min(columnWidth, size.width)
        : size.width;
    final left = columnLeft + (columnWidth - side) / 2;
    return Rect.fromLTWH(left, topInDay, side, size.height);
  }
}

/// Адаптивная сетка 24 часов: каждый час по умолчанию равен [baseHourHeight],
/// но автоматически раздвигается по высоте, если внутри часа несколько визитов
/// или визит назначен со сдвигом по минутам (например, на 12:30 перед 13:00).
class CalendarHourLayout {
  CalendarHourLayout._({
    required this.baseHourHeight,
    required this.cardSide,
    required this.hourHeights,
    required this.hourTops,
    required this.placements,
  });

  factory CalendarHourLayout.compute({
    required Iterable<DateTime> visibleDays,
    required Iterable<CalendarSlotItem> items,
    double baseHourHeight = kMinCalendarHourHeight,
    double? cardSide,
    double cardGap = kCalendarCardGap,
    double hourInset = kCalendarHourInset,
  }) {
    final days = <DateTime>[
      for (final d in visibleDays) DateTime(d.year, d.month, d.day),
    ];
    final resolvedCardSide =
        cardSide ?? calendarCardSideForDays(days.length);
    final minHourHeight = math.max(
      baseHourHeight,
      resolvedCardSide + hourInset * 2,
    );
    final daySet = days.toSet();

    final byDayHour = <(DateTime, int), List<CalendarSlotItem>>{};
    for (final item in items) {
      final day = DateTime(
        item.startTime.year,
        item.startTime.month,
        item.startTime.day,
      );
      if (daySet.isNotEmpty && !daySet.contains(day)) continue;
      final hour = item.startTime.hour.clamp(0, 23);
      byDayHour.putIfAbsent((day, hour), () => <CalendarSlotItem>[]).add(item);
    }

    for (final list in byDayHour.values) {
      list.sort((a, b) {
        final cmp = a.startTime.compareTo(b.startTime);
        if (cmp != 0) return cmp;
        return a.id.compareTo(b.id);
      });
    }

    final hourHeights = List<double>.filled(24, minHourHeight);
    final topInHourById = <String, (DateTime, int, double)>{};

    for (var hour = 0; hour < 24; hour++) {
      var requiredHeight = minHourHeight;
      for (final day in (days.isNotEmpty ? days : _extractDays(byDayHour))) {
        final bucket = byDayHour[(day, hour)];
        if (bucket == null || bucket.isEmpty) continue;
        var prevBottom = -cardGap;
        for (final item in bucket) {
          final minute = item.startTime.minute.clamp(0, 59);
          final minuteOffset = hourInset + (minute / 60.0) * minHourHeight;
          final topInHour = math.max(minuteOffset, prevBottom + cardGap);
          final bottomInHour = topInHour + resolvedCardSide;
          prevBottom = bottomInHour;
          topInHourById[item.id] = (day, hour, topInHour);
        }
        final needed = prevBottom + hourInset;
        if (needed > requiredHeight) {
          requiredHeight = needed;
        }
      }
      hourHeights[hour] = requiredHeight;
    }

    final hourTops = List<double>.filled(25, 0.0);
    for (var hour = 0; hour < 24; hour++) {
      hourTops[hour + 1] = hourTops[hour] + hourHeights[hour];
    }

    final placements = <String, CalendarCardPlacement>{};
    topInHourById.forEach((id, entry) {
      final (day, hour, topInHour) = entry;
      placements[id] = CalendarCardPlacement(
        id: id,
        day: day,
        hour: hour,
        topInHour: topInHour,
        topInDay: hourTops[hour] + topInHour,
        size: Size(resolvedCardSide, resolvedCardSide),
      );
    });

    return CalendarHourLayout._(
      baseHourHeight: minHourHeight,
      cardSide: resolvedCardSide,
      hourHeights: hourHeights,
      hourTops: hourTops,
      placements: placements,
    );
  }

  static Iterable<DateTime> _extractDays(
    Map<(DateTime, int), List<CalendarSlotItem>> byDayHour,
  ) {
    return {for (final key in byDayHour.keys) key.$1};
  }

  final double baseHourHeight;
  final double cardSide;
  final List<double> hourHeights;
  final List<double> hourTops;
  final Map<String, CalendarCardPlacement> placements;

  double get totalHeight => hourTops[24];

  double hourTop(int hour) => hourTops[hour.clamp(0, 24)];

  double hourHeight(int hour) => hourHeights[hour.clamp(0, 23)];

  /// Вертикальная координата для количества минут от начала суток (0..1440).
  double yForMinutes(double totalMinutes) {
    final clamped = totalMinutes.clamp(0.0, 24.0 * 60.0);
    if (clamped >= 24.0 * 60.0) return totalHeight;
    final hour = (clamped ~/ 60).clamp(0, 23);
    final rem = (clamped - hour * 60) / 60.0;
    return hourTops[hour] + rem * hourHeights[hour];
  }

  /// Вертикальная координата для конкретного момента времени.
  double yForTime(DateTime time) {
    final minutes = time.hour * 60.0 + time.minute + time.second / 60.0;
    return yForMinutes(minutes);
  }

  /// Обратное преобразование координаты Y внутри сетки в дату/время выбранного дня.
  DateTime timeForY(DateTime day, double y) {
    final clampedY = y.clamp(0.0, totalHeight);
    var hour = 23;
    for (var h = 0; h < 24; h++) {
      if (clampedY < hourTops[h + 1] || h == 23) {
        hour = h;
        break;
      }
    }
    final hTop = hourTops[hour];
    final hHeight = math.max(1.0, hourHeights[hour]);
    final localY = (clampedY - hTop).clamp(0.0, hHeight);
    final minute = ((localY / hHeight) * 60.0).round().clamp(0, 59);
    return DateTime(day.year, day.month, day.day, hour, minute);
  }
}
