import 'package:fix_appliance_crm/features/calendar/calendar_card_shape.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Карточка визита квадратная при любой длительности (просьба FIX, 05.10.2026).
/// Час раньше рисовался полоской 44×25 — отсюда «сплюснутость».
void main() {
  group('calendarCardShape — узкая колонка (неделя, 5 дней)', () {
    test('час в свободном дне дорастает до квадрата', () {
      final shape = calendarCardShape(
        slot: const Size(44, 25),
        freeHeight: 50, // до следующей заявки два часа
        square: true,
      );
      expect(shape.width, 44);
      expect(shape.height, 44);
      expect(shape.overflows, isTrue);
    });

    test('полчаса тоже квадрат, а не тонкая полоска', () {
      final shape = calendarCardShape(
        slot: const Size(44, 12.5),
        freeHeight: 25,
        square: true,
      );
      expect(shape.width, 25);
      expect(shape.height, 25);
    });

    test('заявка впритык к соседней — квадрат ужимается, а не плющится', () {
      final shape = calendarCardShape(
        slot: const Size(44, 25),
        freeHeight: 25, // следующая заявка через час
        square: true,
      );
      expect(shape.width, 25);
      expect(shape.height, 25);
      expect(shape.overflows, isFalse);
    });

    test('две заявки в одно время не схлопывают карточку в ноль', () {
      final shape = calendarCardShape(
        slot: const Size(22, 25),
        freeHeight: 0,
        square: true,
      );
      expect(shape.width, 22);
      expect(shape.height, 22);
    });

    test('четыре часа — тот же квадрат, без шлейфа под ним', () {
      final shape = calendarCardShape(
        slot: const Size(44, 100),
        freeHeight: 240,
        square: true,
      );
      expect(shape.width, 44);
      expect(shape.height, 44);
      expect(shape.overflows, isFalse);
    });

    test('длинная заявка не ужимается соседней, стоящей вплотную', () {
      final shape = calendarCardShape(
        slot: const Size(44, 100),
        freeHeight: 12,
        square: true,
      );
      expect(shape.height, 44);
    });

    test('на планшете квадрат не разрастается больше maxSide', () {
      final shape = calendarCardShape(
        slot: const Size(140, 60),
        freeHeight: 300,
        square: true,
        maxSide: 96,
      );
      expect(shape.width, 96);
      expect(shape.height, 96);
    });
  });

  group('calendarCardShape — широкая колонка (день, месяц)', () {
    test('день: карточка во всю ширину, но не ниже минимума', () {
      final shape = calendarCardShape(
        slot: const Size(300, 25),
        freeHeight: 120,
        square: false,
        minHeight: 40,
      );
      expect(shape.width, 300);
      expect(shape.height, 40);
    });

    test('день: соседняя заявка впритык — растём только до неё', () {
      final shape = calendarCardShape(
        slot: const Size(300, 25),
        freeHeight: 25,
        square: false,
        minHeight: 40,
      );
      expect(shape.height, 25);
    });

    test('месяц: карточку не трогаем', () {
      final shape = calendarCardShape(
        slot: const Size(48, 18),
        freeHeight: 600,
        square: false,
      );
      expect(shape.width, 48);
      expect(shape.height, 18);
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

    testWidgets('квадрат короткой заявки выходит за слот и не обрезается', (
      tester,
    ) async {
      await pumpSlot(
        tester,
        calendarCardShape(
          slot: const Size(44, 25),
          freeHeight: 50,
          square: true,
        ),
      );
      expect(tester.takeException(), isNull);
      // Место в сетке занято по длительности, а нарисованная карточка — квадрат.
      expect(tester.getSize(find.byType(CalendarCardSlot)), const Size(44, 25));
      expect(tester.getSize(find.byKey(const Key('card'))), const Size(44, 44));
    });

    testWidgets('под длинной заявкой ничего не дорисовывается', (tester) async {
      await pumpSlot(
        tester,
        calendarCardShape(
          slot: const Size(44, 100),
          freeHeight: 240,
          square: true,
        ),
      );
      final card = tester.getRect(find.byKey(const Key('card')));
      expect(card.size, const Size(44, 44));
      // Шлейф убран: внутри слота только сама карточка.
      expect(find.byType(DecoratedBox), findsNothing);
    });
  });
}
