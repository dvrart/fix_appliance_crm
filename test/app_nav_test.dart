import 'package:fix_appliance_crm/core/app_commands.dart';
import 'package:fix_appliance_crm/features/calls/call_screen.dart';
import 'package:fix_appliance_crm/features/jobs/active_jobs_screen.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/sms_service.dart';
import 'package:fix_appliance_crm/services/status_service.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:fix_appliance_crm/shared/app_nav.dart';
import 'package:fix_appliance_crm/shared/unsaved_navigation_gate.dart';
import 'package:fix_appliance_crm/shared/widgets/appliance_picture.dart';
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

  // Панели (левое меню, шторка «Все визиты», колокольчик, поиск) в стеке
  // маршрутов не лежат: вернуть их может только `PanelReturn`.
  Future<void> openFromPanel(
    WidgetTester tester,
    VoidCallback back, {
    String title = 'screen',
  }) async {
    PanelReturn.open<void>(
      nav.currentState!,
      push: () => nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => Text(title)),
      ),
      back: back,
    );
    await tester.pumpAndSettle();
  }

  // Возврат отложен на 140 мс после закрытия экрана.
  Future<void> settleReturn(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('«Назад» с открытого экрана возвращает панель', (tester) async {
    await boot(tester);
    var returned = 0;
    await openFromPanel(tester, () => returned++);
    expect(find.text('screen'), findsOneWidget);

    nav.currentState!.pop();
    await settleReturn(tester);

    expect(returned, 1);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('отменённый возврат панель не открывает', (tester) async {
    await boot(tester);
    var returned = 0;
    await openFromPanel(tester, () => returned++);

    // Смена вкладки или выход на главную: пользователь уже не там, откуда
    // открывал панель.
    PanelReturn.cancel();
    nav.currentState!.pop();
    await settleReturn(tester);

    expect(returned, 0);
  });

  testWidgets('экран, снятый из середины стека, панель не возвращает', (
    tester,
  ) async {
    await boot(tester);
    var returned = 0;
    await openFromPanel(tester, () => returned++);
    await openJob(tester, 'a');

    // Так карточку снимает лимит стека: её future завершается, но вернулись
    // не на страницу под панелью, а в чужой экран.
    nav.currentState!.removeRoute(AppNav.pagesOf(nav.currentState!)[1]);
    await settleReturn(tester);

    expect(returned, 0);
    expect(find.text('job a'), findsOneWidget);
  });

  testWidgets(
    'список всех визитов показывает новые сверху, а старые — при прокрутке вниз',
    (tester) async {
      final referenceNow = DateTime(2026, 10, 19, 9, 0);
      final jobs = <Job>[
        for (var i = 1; i <= 8; i++)
          Job(
            id: 'past-job-$i',
            clientId: 'cp-$i',
            clientName: 'Past Client $i',
            clientPhone: '+1416555010$i',
            clientAddress: '$i King St',
            status: i.isEven ? 'Завершено' : 'Вызов',
            createdAt: DateTime(2026, 10, 1),
            visits: [
              JobVisit(
                id: 'v-past-$i',
                startAt: DateTime(2026, 10, 19 - i, 11, 0),
                durationMinutes: 120,
              ),
            ],
          ),
        Job(
          id: 'today-job',
          clientId: 'c2',
          clientName: 'Today Client',
          clientPhone: '+14165550102',
          clientAddress: '20 Queen St',
          createdAt: DateTime(2026, 10, 18),
          visits: [
            JobVisit(
              id: 'v-today',
              startAt: DateTime(2026, 10, 19, 14, 0),
              durationMinutes: 120,
            ),
          ],
        ),
        Job(
          id: 'future-job',
          clientId: 'c3',
          clientName: 'Future Client',
          clientPhone: '+14165550103',
          clientAddress: '30 Bay St',
          createdAt: DateTime(2026, 10, 19),
          visits: [
            JobVisit(
              id: 'v-future',
              startAt: DateTime(2026, 10, 21, 10, 0),
              durationMinutes: 120,
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: AllVisitsScreen(
            jobsStream: Stream<List<Job>>.value(jobs),
            statusesStream: const Stream<List<JobStatusDef>>.empty(),
            referenceNow: referenceNow,
            showStatusFilters: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Все визиты'), findsOneWidget);
      expect(find.text('Future Client'), findsOneWidget);
      expect(find.text('Today Client'), findsOneWidget);
      expect(find.text('Вызов'), findsWidgets);
      expect(find.text('Готово'), findsWidgets);
      expect(
        tester.getTopLeft(find.text('Future Client')).dy,
        lessThan(tester.getTopLeft(find.text('Today Client')).dy),
      );

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();

      expect(find.text('Past Client 8'), findsOneWidget);
    },
  );

  testWidgets(
    '«Все визиты» показывает значки новых SMS и «Не проверено», но без подтверждения визита и кнопок звонка и чата',
    (tester) async {
      final referenceNow = DateTime(2026, 10, 19, 9, 0);
      final jobs = <Job>[
        Job(
          id: 'ai-job',
          clientId: 'c-ai',
          clientName: 'John Smith',
          clientPhone: '+14165550199',
          clientAddress: '100 Yonge St',
          createdAt: DateTime(2026, 10, 19),
          needsReview: true,
          createdByAi: true,
          source: 'phone',
          visits: [
            JobVisit(
              id: 'v-ai',
              startAt: DateTime(2026, 10, 19, 14, 0),
              durationMinutes: 120,
              smsConfirmStatus: JobVisit.confirmConfirmed,
            ),
          ],
        ),
      ];
      final unread = <SmsMessage>[
        SmsMessage(
          id: 'm1',
          sid: 's1',
          from: '+14165550199',
          to: '+16470000000',
          body: 'See you at 2pm!',
          direction: 'inbound',
          read: false,
          jobId: 'ai-job',
        ),
      ];
      final awaiting = <SmsMessage>[
        SmsMessage(
          id: 'm2',
          sid: 's2',
          from: '+16470000000',
          to: '+14165550199',
          body: 'Confirming your visit',
          direction: 'outbound',
          approval: 'pending',
          jobId: 'ai-job',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: AllVisitsScreen(
            jobsStream: Stream<List<Job>>.value(jobs),
            statusesStream: const Stream<List<JobStatusDef>>.empty(),
            unreadMessagesStream: Stream<List<SmsMessage>>.value(unread),
            awaitingApprovalStream: Stream<List<SmsMessage>>.value(awaiting),
            referenceNow: referenceNow,
            showStatusFilters: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Не проверено'), findsOneWidget);
      expect(find.byIcon(Icons.mark_chat_unread_rounded), findsOneWidget);
      // Подтверждение визита по SMS с карточки убрано.
      expect(find.text('SMS'), findsNothing);
      expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget);
      // Звонок и переписка — только из карточки заявки.
      expect(find.byIcon(Icons.phone_in_talk_rounded), findsNothing);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);

      // Порядок слева направо: иконка техники → время → имя → статус.
      final iconX = tester.getTopLeft(find.byType(AppliancePicture)).dx;
      final timeX = tester.getTopLeft(find.text('14:00')).dx;
      final nameX = tester.getTopLeft(find.text('John Smith')).dx;
      final statusX = tester.getTopLeft(find.text('Вызов')).dx;
      expect(iconX, lessThan(timeX));
      expect(timeX, lessThan(nameX));
      expect(nameX, lessThan(statusX));
    },
  );

  testWidgets(
    'экраны из корневого контекста открываются во вкладке, оставляя нижнее меню видимым',
    (tester) async {
      final tabNav = GlobalKey<NavigatorState>();
      AppNav.bindTabNavigator(() => tabNav.currentState);
      addTearDown(() => AppNav.bindTabNavigator(null));

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [AppNav.rootObserver],
          home: Column(
            children: [
              Expanded(
                child: Navigator(
                  key: tabNav,
                  observers: [AppNavObserver()],
                  onGenerateRoute: (_) =>
                      MaterialPageRoute(builder: (_) => const Text('tab-root')),
                ),
              ),
              const Text('bottom-dock'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      AppNav.navigatorOf(rootNavigatorKey.currentContext!).push(
        MaterialPageRoute<void>(builder: (_) => const Text('inner-screen')),
      );
      await tester.pumpAndSettle();

      expect(find.text('inner-screen'), findsOneWidget);
      expect(find.text('bottom-dock'), findsOneWidget);
    },
  );

  testWidgets(
    'экран входящего звонка открывается на весь экран поверх нижней панели',
    (tester) async {
      final tabNav = GlobalKey<NavigatorState>();
      AppNav.bindTabNavigator(() => tabNav.currentState);
      final prevStatus = TwilioService.callStatus;
      TwilioService.callStatus = 'ringing';
      addTearDown(() {
        AppNav.bindTabNavigator(null);
        TwilioService.callStatus = prevStatus;
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [AppNav.rootObserver],
          home: Column(
            children: [
              Expanded(
                child: Navigator(
                  key: tabNav,
                  observers: [AppNavObserver()],
                  onGenerateRoute: (_) =>
                      MaterialPageRoute(builder: (_) => const Text('tab-root')),
                ),
              ),
              const Text('bottom-dock'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      CallScreen.open<void>(
        rootNavigatorKey.currentContext!,
        phoneNumber: '+1 (416) 555-0199',
        contactName: 'Amelia',
        isIncoming: true,
        resumeExisting: true,
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallScreen), findsOneWidget);
      expect(find.text('Amelia'), findsOneWidget);
      expect(find.text('bottom-dock'), findsNothing);
    },
  );
}
