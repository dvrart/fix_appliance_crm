import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fix_appliance_crm/core/theme.dart';
import 'package:fix_appliance_crm/shared/widgets/linked_text.dart';

void main() {
  group('parseTextLinks', () {
    test('находит ссылку, почту и телефон', () {
      final links = parseTextLinks(
        'Пишите на fix@example.com, сайт www.fixappliance.ca, '
        'телефон (416) 555-1234.',
      );
      expect(links.map((l) => l.kind).toList(), [
        TextLinkKind.email,
        TextLinkKind.url,
        TextLinkKind.phone,
      ]);
      expect(links[0].text, 'fix@example.com');
      expect(links[1].text, 'www.fixappliance.ca');
      expect(links[2].text, '(416) 555-1234');
    });

    test('точка в конце предложения в ссылку не входит', () {
      final links = parseTextLinks('Счёт тут https://pay.example.com/x1.');
      expect(links.single.text, 'https://pay.example.com/x1');
    });

    test('дата и время за телефон не считаются', () {
      expect(parseTextLinks('Визит 2026-09-20 14:00, цена 1 250.50'), isEmpty);
    });

    test('номер в международном виде', () {
      final links = parseTextLinks('звоните +14165551234 в любое время');
      expect(links.single.kind, TextLinkKind.phone);
      expect(links.single.text, '+14165551234');
    });
  });

  testWidgets('нажатие на ссылку открывает меню, текст выделяемый',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LinkedText('Счёт тут https://pay.example.com/x1 — оплатите'),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.tapOnText(
      find.textRange.ofSubstring('https://pay.example.com/x1'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Открыть ссылку'), findsOneWidget);
    expect(find.text('Скопировать'), findsOneWidget);
  });

  testWidgets('выделение текста красное', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: LinkedText('Приеду завтра к двум')),
      ),
    );
    final text = tester.widget<RichText>(find.byType(RichText).first);
    expect(text.selectionColor, const Color(0x66E53935));
  });

  testWidgets('во время выделения сообщений ссылки не мешают',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LinkedText(
            'Счёт тут https://pay.example.com/x1',
            interactive: false,
          ),
        ),
      ),
    );
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('долгое нажатие экрана выигрывает у выделения текста',
      (tester) async {
    var longPresses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickLongPress(
            onLongPress: () => longPresses++,
            child: const LinkedText('Приеду завтра к двум'),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(LinkedText));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
  });

  testWidgets('внутри чужой области выделения своей не заводит',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: LinkedText('Приеду завтра к двум'),
          ),
        ),
      ),
    );
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
