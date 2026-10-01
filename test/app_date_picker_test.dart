import 'package:fix_appliance_crm/core/utils/app_date_picker.dart';
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
}
