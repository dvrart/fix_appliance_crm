import 'package:fix_appliance_crm/features/ai/assistant/assistant_tools.dart';
import 'package:fix_appliance_crm/services/service_guide_service.dart';
import 'package:fix_appliance_crm/shared/app_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServiceGuideService.lookup', () {
    test('находит коды ошибок по разным брендам и видам техники', () async {
      final boschE15 = await ServiceGuideService.lookup(
        query: 'ошибка E15 посудомойка Bosch',
        brand: 'Bosch',
        appliance: 'dishwasher',
        code: 'E15',
      );
      expect(boschE15['found'], isTrue);
      final hits1 = boschE15['hits'] as List;
      expect(hits1.first['topic'].toString().toLowerCase(), contains('bosch'));

      final whirlpoolVmW = await ServiceGuideService.lookup(
        query: 'код ошибки F7E1 стиральная машина Whirlpool',
        brand: 'Whirlpool',
        appliance: 'washer',
        code: 'F7E1',
      );
      expect(whirlpoolVmW['found'], isTrue);

      final lgFridge = await ServiceGuideService.lookup(
        query: 'холодильник LG ошибка Er IF',
        brand: 'LG',
        appliance: 'fridge',
        code: 'Er IF',
      );
      expect(lgFridge['found'], isTrue);

      final microwave = await ServiceGuideService.lookup(
        query: 'микроволновка Panasonic ошибка H97 не греет',
        brand: 'Panasonic',
        appliance: 'microwave',
        code: 'H97',
      );
      expect(microwave['found'], isTrue);
    });

    test('находит вход в тестовый режим и нормы сопротивлений в Омах', () async {
      final testMode = await ServiceGuideService.lookup(
        query: 'как войти в тестовый режим и сделать калибровку Whirlpool VMW',
        brand: 'Whirlpool',
        appliance: 'washer',
        kind: 'test_modes',
      );
      expect(testMode['found'], isTrue);
      final hits = testMode['hits'] as List;
      expect(hits.first['kind'], 'test_modes');
      expect(hits.first['entry'].toString(), contains('3'));

      final ohms = await ServiceGuideService.lookup(
        query: 'сопротивление датчика духовки RTD в омах',
        appliance: 'range',
        kind: 'electrical',
      );
      expect(ohms['found'], isTrue);
    });

    test('находит мануал W11448643 и тестовые режимы всех основных стиральных машин', () async {
      final techSheet = await ServiceGuideService.lookup(
        query: 'W11448643 тестовый режим',
        appliance: 'washer',
      );
      expect(techSheet['found'], isTrue);
      final sheetHits = techSheet['hits'] as List;
      expect(
        sheetHits.first['codes'].toString().toUpperCase(),
        contains('W11448643'),
      );

      final newAcu = await ServiceGuideService.lookup(
        query: 'MVW6230HW F7EA тестовый режим 1-2-3',
        brand: 'Maytag',
        appliance: 'washer',
      );
      expect(newAcu['found'], isTrue);

      final speedQueen = await ServiceGuideService.lookup(
        query: 'Speed Queen TR7 FF7 вход в тестовый режим Er dL',
        brand: 'Speed Queen',
        appliance: 'washer',
      );
      expect(speedQueen['found'], isTrue);

      final blomberg = await ServiceGuideService.lookup(
        query: 'Blomberg WM72200W тестовый режим H5',
        brand: 'Blomberg',
        appliance: 'washer',
      );
      expect(blomberg['found'], isTrue);

      // Встроенный ИИ может вызвать lookup_service_guide без поля query, только по brand+appliance+kind:
      final viaAssistant = await AssistantTools.handle('lookup_service_guide', {
        'brand': 'Whirlpool',
        'appliance': 'washer',
        'kind': 'test_modes',
      });
      expect(viaAssistant['found'], isTrue);

      final washTower = await ServiceGuideService.lookup(
        query: 'LG WashTower WKEX200 тестовый режим',
        brand: 'LG',
        appliance: 'washer',
      );
      expect(washTower['found'], isTrue);

      final asko = await ServiceGuideService.lookup(
        query: 'Asko W2084 E0 сервисное меню',
        brand: 'Asko',
        appliance: 'washer',
      );
      expect(asko['found'], isTrue);

      final heatPumpDryer = await ServiceGuideService.lookup(
        query: 'сушилка с тепловым насосом Heat Pump Miele T1 F66',
        brand: 'Miele',
        appliance: 'dryer',
      );
      expect(heatPumpDryer['found'], isTrue);

      final geDishwasherCsm = await ServiceGuideService.lookup(
        query: 'посудомойка GE мёртвая панель CSM 7 вспышек',
        brand: 'GE',
        appliance: 'dishwasher',
      );
      expect(geDishwasherCsm['found'], isTrue);

      final liebherr = await ServiceGuideService.lookup(
        query: 'холодильник Liebherr ошибка F2 датчик испарителя',
        brand: 'Liebherr',
        appliance: 'fridge',
      );
      expect(liebherr['found'], isTrue);

      final bertazzoni = await ServiceGuideService.lookup(
        query: 'газовая духовка Bertazzoni тухнет термопара',
        brand: 'Bertazzoni',
        appliance: 'range',
      );
      expect(bertazzoni['found'], isTrue);
    });

    testWidgets('ключевое слово «открытая» не цепляет случайные карточки и видит открытый чат', (tester) async {
      // Регрессия: слово «открытая» раньше совпадало по 2-буквенному префиксу «от»
      // с чужой заявкой «Посудомоечная Машина Париж».
      expect(
        AssistantTools.matchScoreForTest(
          'Посудомоечная Машина Париж от клиента 9058075214',
          'открытая',
        ),
        0,
      );

      final navKey = GlobalKey<NavigatorState>();
      AppNav.bindTabNavigator(() => navKey.currentState);
      addTearDown(() => AppNav.bindTabNavigator(null));

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [AppNav.rootObserver],
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => AppNav.openCard<void>(
                ctx,
                key: AppNav.chatKey(phone: '+12269186432'),
                builder: (_) => const Scaffold(body: Text('chat')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(AppNav.topCardKey, 'card:chat:2269186432');
    });
  });
}
