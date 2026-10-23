import 'package:fix_appliance_crm/services/service_guide_service.dart';
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
  });
}
