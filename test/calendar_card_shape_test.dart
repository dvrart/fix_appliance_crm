import 'package:fix_appliance_crm/features/calendar/calendar_card_shape.dart';
import 'package:fix_appliance_crm/features/calendar/calendar_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CalendarScreen type is available', () {
    expect(const CalendarScreen(), isA<Widget>());
  });

  group('calendarCardShape — часовые виды (37×37 и 50×50)', () {
    test('в 5-дневном / недельном виде карточка всегда 37×37 при любом свободном времени', () {
      final freeDay = calendarCardShape(
        slot: const Size(48, 39),
        freeHeight: 160,
        square: true,
      );
      final backToBack = calendarCardShape(
        slot: const Size(48, 25),
        freeHeight: 25,
        square: true,
      );
      final wideDay = calendarCardShape(
        slot: const Size(320, 39),
        freeHeight: 240,
        square: true,
      );

      expect(freeDay.size, const Size(37, 37));
      expect(backToBack.size, const Size(37, 37));
      expect(wideDay.size, const Size(37, 37));
    });

    test('в виде на 1 день карточка размером 50×50', () {
      final oneDay = calendarCardShape(
        slot: const Size(320, 52),
        freeHeight: 200,
        square: true,
        cardSide: kCalendarDayCardSide,
      );
      expect(oneDay.size, const Size(50, 50));
    });

    test('месяц: карточку не превращаем в квадрат 37×37', () {
      final shape = calendarCardShape(
        slot: const Size(48, 18),
        freeHeight: 600,
        square: false,
      );
      expect(shape.width, 48);
      expect(shape.height, 18);
    });
  });

  group('CalendarHourLayout — адаптивная шкала времени', () {
    final mon = DateTime(2026, 10, 19);
    final tue = DateTime(2026, 10, 20);

    test('заявки в соседние часы (10:00 и 11:00) стоят по 37×37 без раздвижения', () {
      final layout = CalendarHourLayout.compute(
        visibleDays: [mon, tue],
        baseHourHeight: 39,
        items: [
          CalendarSlotItem(id: 'a', startTime: DateTime(2026, 10, 19, 10, 0)),
          CalendarSlotItem(id: 'b', startTime: DateTime(2026, 10, 19, 11, 0)),
        ],
      );

      final a = layout.placements['a']!;
      final b = layout.placements['b']!;
      expect(a.size, const Size(37, 37));
      expect(b.size, const Size(37, 37));
      expect(layout.hourHeight(10), 39);
      expect(layout.hourHeight(11), 39);
      expect(a.topInDay + a.size.height, lessThan(b.topInDay));
    });

    test('вид на 1 день: карточки 50×50 и высота часа не меньше 52', () {
      final layout = CalendarHourLayout.compute(
        visibleDays: [mon],
        baseHourHeight: 39,
        items: [
          CalendarSlotItem(id: 'd1', startTime: DateTime(2026, 10, 19, 10, 0)),
          CalendarSlotItem(id: 'd2', startTime: DateTime(2026, 10, 19, 11, 0)),
        ],
      );

      final d1 = layout.placements['d1']!;
      final d2 = layout.placements['d2']!;
      expect(layout.cardSide, 50);
      expect(d1.size, const Size(50, 50));
      expect(d2.size, const Size(50, 50));
      expect(layout.hourHeight(10), 52);
      expect(d1.topInDay + d1.size.height, lessThan(d2.topInDay));
    });

    test('два визита в один час раздвигают этот час и встают друг под другом', () {
      final layout = CalendarHourLayout.compute(
        visibleDays: [mon, tue],
        baseHourHeight: 39,
        items: [
          CalendarSlotItem(id: 'v1', startTime: DateTime(2026, 10, 20, 12, 0)),
          CalendarSlotItem(id: 'v2', startTime: DateTime(2026, 10, 20, 12, 30)),
        ],
      );

      final v1 = layout.placements['v1']!;
      final v2 = layout.placements['v2']!;
      expect(v1.size, const Size(37, 37));
      expect(v2.size, const Size(37, 37));
      expect(v2.topInDay, greaterThanOrEqualTo(v1.topInDay + 37 + kCalendarCardGap));
      expect(layout.hourHeight(12), greaterThanOrEqualTo(78));
      expect(layout.hourTop(13), layout.hourTop(12) + layout.hourHeight(12));
    });

    test('визит в 12:30 перед 13:00 сдвинут по минуте и раздвигает час 12:00', () {
      final layout = CalendarHourLayout.compute(
        visibleDays: [mon, tue],
        baseHourHeight: 39,
        items: [
          CalendarSlotItem(
            id: 'tue_1230',
            startTime: DateTime(2026, 10, 20, 12, 30),
          ),
          CalendarSlotItem(
            id: 'tue_1300',
            startTime: DateTime(2026, 10, 20, 13, 0),
          ),
        ],
      );

      final first = layout.placements['tue_1230']!;
      final second = layout.placements['tue_1300']!;
      expect(first.size, const Size(37, 37));
      expect(second.size, const Size(37, 37));
      expect(first.topInHour, greaterThan(15));
      expect(layout.hourHeight(12), greaterThan(39));
      expect(first.topInDay + first.size.height, lessThan(second.topInDay));

      final rect1 = first.rectInColumn(100, 48);
      final rect2 = second.rectInColumn(100, 48);
      expect(rect1.left, rect2.left);
      expect(rect1.width, 37);
      expect(rect2.width, 37);
    });
  });

  group('CalendarCardSlot', () {
    Future<void> pumpSlot(WidgetTester tester, CalendarCardShape shape) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CalendarCardSlot(
              shape: shape,
              child: const ColoredBox(color: Colors.green, key: Key('card')),
            ),
          ),
        ),
      );
    }

    testWidgets('карточка 37×37 центрируется внутри слота колонки', (
      tester,
    ) async {
      await pumpSlot(
        tester,
        calendarCardShape(
          slot: const Size(48, 39),
          freeHeight: 39,
          square: true,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CalendarCardSlot)), const Size(48, 39));
      expect(tester.getSize(find.byKey(const Key('card'))), const Size(37, 37));
    });
  });
}
