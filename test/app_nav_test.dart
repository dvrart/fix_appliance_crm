import 'package:fix_appliance_crm/shared/app_nav.dart';
import 'package:fix_appliance_crm/shared/unsaved_navigation_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late GlobalKey<NavigatorState> nav;

  Future<void> boot(WidgetTester tester) async {
    nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [AppNavObserver()],
        home: const Text('home'),
      ),
    );
  }

  // Открытие не ждём: как и у `Navigator.push`, его future завершается
  // только при закрытии карточки.
  Future<void> openJob(WidgetTester tester, String id) async {
    AppNav.openCard<void>(
      nav.currentContext!,
      key: AppNav.jobKey(id),
      builder: (_) => Text('job $id'),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openChat(WidgetTester tester, String phone) async {
    AppNav.openCard<void>(
      nav.currentContext!,
      key: AppNav.chatKey(phone: phone),
      builder: (_) => Text('chat $phone'),
    );
    await tester.pumpAndSettle();
  }

  int depth() => AppNav.pagesOf(nav.currentState!).length;

  Future<bool> stay() async => true;

  testWidgets('та же заявка не кладётся второй копией — возврат к открытой', (
    tester,
  ) async {
    await boot(tester);
    await openJob(tester, 'a');
    await openChat(tester, '+1 416 555 0100');
    await openJob(tester, 'a');

    expect(find.text('job a'), findsOneWidget);
    expect(find.text('chat +1 416 555 0100'), findsNothing);
    // Главная + заявка: переписка снята, копии заявки нет.
    expect(depth(), 2);
  });

  testWidgets('переписка узнаётся по номеру в любом написании', (tester) async {
    await boot(tester);
    await openChat(tester, '+14165550100');
    await openJob(tester, 'a');
    await openChat(tester, '(416) 555-0100');

    expect(find.text('chat +14165550100'), findsOneWidget);
    expect(depth(), 2);
  });

  testWidgets('глубже лимита стек не растёт — старая карточка уходит', (
    tester,
  ) async {
    await boot(tester);
    for (var i = 0; i <= AppNav.maxCards; i++) {
      await openJob(tester, 'job$i');
    }

    expect(depth(), AppNav.maxCards + 1);
    expect(find.text('job job0'), findsNothing);
  });

  testWidgets('несохранённые правки лимит не выбрасывает', (tester) async {
    UnsavedNavigationGate.push(stay, unsaved: () => true);
    addTearDown(() => UnsavedNavigationGate.pop(stay));
    await boot(tester);
    for (var i = 0; i <= AppNav.maxCards; i++) {
      await openJob(tester, 'job$i');
    }

    expect(depth(), AppNav.maxCards + 2);
  });

  testWidgets('выход на главную снимает промежуточные экраны без анимации', (
    tester,
  ) async {
    await boot(tester);
    await openJob(tester, 'a');
    await openChat(tester, '+14165550100');
    await openJob(tester, 'b');

    AppNav.collapse(nav.currentState!);
    // Ни одного кадра анимации: между главной и верхним экраном пусто.
    expect(depth(), 2);

    await AppNav.popToRoot(nav.currentState!);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(nav.currentState!.canPop(), isFalse);
  });

  testWidgets('покинутая вкладка возвращается на корень', (tester) async {
    await boot(tester);
    await openJob(tester, 'a');
    await openJob(tester, 'b');

    AppNav.resetToRoot(nav.currentState!);
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(depth(), 1);
  });

  testWidgets('вкладку с несохранёнными правками не сбрасываем', (
    tester,
  ) async {
    UnsavedNavigationGate.push(stay, unsaved: () => true);
    addTearDown(() => UnsavedNavigationGate.pop(stay));
    await boot(tester);
    await openJob(tester, 'a');

    AppNav.resetToRoot(nav.currentState!);
    await tester.pumpAndSettle();

    expect(find.text('job a'), findsOneWidget);
  });
}
