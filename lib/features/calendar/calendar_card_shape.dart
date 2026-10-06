import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Размер карточки визита внутри слота, который календарь отвёл заявке.
class CalendarCardShape {
  const CalendarCardShape({
    required this.slot,
    required this.width,
    required this.height,
  });

  /// Прямоугольник заявки от календаря: ширина колонки × длительность.
  final Size slot;

  final double width;
  final double height;

  Size get size => Size(width, height);

  /// Карточка выше слота и заходит вниз на свободное время.
  bool get overflows => height > slot.height + 0.5;
}

/// Час выглядел приплюснутой полоской, а два часа — красивым квадратом: высоту
/// карточке задавала длительность. FIX попросил (05.10.2026) квадрат при любой
/// длительности. В узких колонках (неделя, 5 дней) сторона квадрата — ширина
/// колонки: короткий визит дорастает вниз в свободное время, длинный остаётся
/// квадратом (занятое время на карточке не показано — FIX отказался от полосы
/// остатка). Наехать на соседнюю заявку квадрат не может: там сторона
/// ужимается до свободной высоты, поэтому плотный день не превращается в кашу.
/// В широких колонках (день) карточка остаётся полосой во всю ширину, но не
/// ниже [minHeight] — туда влезают имя и логотип.
CalendarCardShape calendarCardShape({
  required Size slot,
  required double freeHeight,
  required bool square,
  double minHeight = 0,
  double maxSide = 96,
}) {
  // Длинная заявка своё место занимает всегда, даже если следом впритык идёт
  // соседняя: ужимать можно только то, что мы дорисовали сверх длительности.
  final room = math.max(slot.height, freeHeight);
  if (square) {
    final side = math.max(0.0, math.min(math.min(slot.width, room), maxSide));
    return CalendarCardShape(slot: slot, width: side, height: side);
  }
  final height = math.min(math.max(slot.height, minHeight), room);
  return CalendarCardShape(
    slot: slot,
    width: slot.width,
    height: math.max(0.0, height),
  );
}

/// Кладёт карточку в слот календаря: квадрат по центру колонки, от времени
/// начала. Остаток занятого времени ничем не рисуется — полосу-шлейф FIX
/// отменил 05.10.2026.
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
        // Квадрат короткого визита выходит за слот вниз, в свободное время.
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
