import 'package:fix_appliance_crm/core/utils/app_date_picker.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
    await initializeDateFormatting('en');
  });

  Future<List<DateTime>> pump(
    WidgetTester tester, {
    required DateTime value,
    DateTime? rangeStart,
  }) async {
    final changes = <DateTime>[];
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AppDateTimePanel(
              value: value,
              firstDate: DateTime(2026, 9, 1),
              lastDate: DateTime(2026, 12, 31),
              onChanged: changes.add,
              rangeStart: rangeStart,
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('нажатие на число меняет день и сохраняет время', (tester) async {
    final changes = await pump(tester, value: DateTime(2026, 9, 30, 14, 30));
    // Первое совпадение — число в календаре, второе — час на барабане.
    await tester.tap(find.text('15').first);
    expect(changes, [DateTime(2026, 9, 15, 14, 30)]);
  });

  testWidgets('стрелка листает месяц, за границей — не листает', (
    tester,
  ) async {
    final changes = await pump(tester, value: DateTime(2026, 9, 30, 9, 0));
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pump();
    await tester.tap(find.text('3').first);
    expect(changes.single, DateTime(2026, 10, 3, 9, 0));

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    // Сентябрь — первый разрешённый месяц, дальше назад не уходим.
    await tester.tap(find.text('1').first);
    expect(changes.last, DateTime(2026, 9, 1, 9, 0));
  });

  testWidgets('барабаны часов и минут не крутятся по кругу (00–23 и 00–59)', (
    tester,
  ) async {
    await pump(tester, value: DateTime(2026, 9, 30, 0, 0));
    final pickers = tester
        .widgetList<CupertinoPicker>(find.byType(CupertinoPicker))
        .toList();
    expect(pickers.length, 2);
    for (final picker in pickers) {
      expect(picker.childDelegate, isA<ListWheelChildListDelegate>());
      final delegate = picker.childDelegate as ListWheelChildListDelegate;
      expect(delegate.children.isNotEmpty, isTrue);
    }
    final hourDelegate =
        pickers[0].childDelegate as ListWheelChildListDelegate;
    final minuteDelegate =
        pickers[1].childDelegate as ListWheelChildListDelegate;
    expect(hourDelegate.children.length, 24);
    expect(minuteDelegate.children.length, 60);
  });

  testWidgets('optionalTime позволяет выбрать только дату без времени', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    DateTime? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showAppDateTimeSheet(
                  context: context,
                  initial: DateTime(2026, 11, 10, 14, 30),
                  firstDate: DateTime(2026, 1, 1),
                  lastDate: DateTime(2027, 12, 31),
                  optionalTime: true,
                  initialWithTime: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AppTimeWheel), findsOneWidget);

    await tester.tap(find.text('Только дата'));
    await tester.pumpAndSettle();
    expect(find.byType(AppTimeWheel), findsNothing);

    await tester.tap(find.byType(AppSheetConfirmButton));
    await tester.pumpAndSettle();
    expect(result, DateTime(2026, 11, 10));
  });

  test('Job.isPromisedOverdue учитывает дату без времени и дату со временем', () {
    final now = DateTime(2026, 11, 7, 15, 0);
    expect(Job.isPromisedOverdue(null, now), isFalse);
    // Только дата (00:00): сегодня ещё не просрочено, вчера — просрочено.
    expect(Job.isPromisedOverdue(DateTime(2026, 11, 7), now), isFalse);
    expect(Job.isPromisedOverdue(DateTime(2026, 11, 6), now), isTrue);
    // С временем сегодня: 14:00 уже просрочено в 15:00, а 16:00 — ещё нет.
    expect(Job.isPromisedOverdue(DateTime(2026, 11, 7, 14, 0), now), isTrue);
    expect(Job.isPromisedOverdue(DateTime(2026, 11, 7, 16, 0), now), isFalse);
  });
}
