import 'dart:typed_data';

import 'package:fix_appliance_crm/features/care_plan/sticker_renderer.dart';
import 'package:fix_appliance_crm/models/care_plan.dart';
import 'package:fix_appliance_crm/models/home_appliance.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/care_plan_service.dart';
import 'package:fix_appliance_crm/services/notification_router.dart';
import 'package:fix_appliance_crm/services/sticker_printer_service.dart';
import 'package:flutter_test/flutter_test.dart';

int _bits(int byte) {
  var n = 0;
  for (var b = byte; b != 0; b >>= 1) {
    n += b & 1;
  }
  return n;
}

CarePlan _plan({
  String id = 'p1',
  String clientId = 'c1',
  String status = CarePlan.active,
  DateTime? signedAt,
  DateTime? last,
  DateTime? next,
  List<String> phones = const ['4165550101'],
}) => CarePlan(
  id: id,
  clientId: clientId,
  clientName: 'Amelia',
  phones: phones,
  status: status,
  signedAt: signedAt ?? DateTime(2026, 9, 1),
  lastMaintenanceAt: last,
  nextMaintenanceDue: next,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Care Plan dates', () {
    test('months are added with the day pinned to the end of a short month', () {
      expect(CarePlan.addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(CarePlan.addMonths(DateTime(2027, 11, 15), 3), DateTime(2028, 2, 15));
      expect(CarePlan.addMonths(DateTime(2026, 10, 25), 12), DateTime(2027, 10, 25));
    });

    test('first maintenance comes after the first-maintenance days, then every interval', () {
      final plan = _plan(signedAt: DateTime(2026, 10, 25, 15));
      expect(plan.maintenanceDue, DateTime(2026, 11, 24));
      final serviced = _plan(signedAt: DateTime(2026, 10, 25), last: DateTime(2026, 11, 20));
      expect(serviced.maintenanceDue, DateTime(2027, 11, 20));
      expect(_plan(next: DateTime(2026, 12, 1)).maintenanceDue, DateTime(2026, 12, 1));
    });

    test('contract windows: 10-day cancellation, 30-day waiting, 12-month minimum', () {
      final plan = _plan(signedAt: DateTime(2026, 10, 25, 18));
      expect(plan.coolingOffUntil, DateTime(2026, 11, 4));
      expect(plan.inCoolingOff(DateTime(2026, 11, 3, 23)), isTrue);
      expect(plan.inCoolingOff(DateTime(2026, 11, 4, 8)), isFalse);
      expect(plan.waitingUntil, DateTime(2026, 11, 24));
      expect(plan.repairBenefitsActive(DateTime(2026, 11, 10)), isFalse);
      expect(plan.repairBenefitsActive(DateTime(2026, 11, 24)), isTrue);
      expect(plan.minTermUntil, DateTime(2027, 10, 25));
      expect(plan.monthlyTotal(0.13), 11.3);
    });

    test('attention: failed payment first, then overdue and soon maintenance, then unpaid contracts', () {
      final now = DateTime(2026, 10, 25, 9);
      expect(
        _plan(status: CarePlan.pastDue, next: DateTime(2026, 10, 1)).attention(now),
        CarePlanAttention.paymentFailed,
      );
      expect(_plan(next: DateTime(2026, 10, 25)).attention(now), CarePlanAttention.maintenanceOverdue);
      expect(_plan(next: DateTime(2026, 11, 8)).attention(now), CarePlanAttention.maintenanceSoon);
      expect(_plan(next: DateTime(2026, 11, 9)).attention(now), CarePlanAttention.none);
      expect(
        _plan(status: CarePlan.pending, signedAt: DateTime(2026, 10, 23)).attention(now),
        CarePlanAttention.awaitingPayment,
      );
      expect(
        _plan(status: CarePlan.pending, signedAt: DateTime(2026, 10, 24)).attention(now),
        CarePlanAttention.none,
      );
      expect(
        _plan(status: CarePlan.cancelled, next: DateTime(2026, 10, 1)).attention(now),
        CarePlanAttention.none,
      );
    });

    test('terms from settings are clamped and keep a valid passport address', () {
      final terms = CarePlanTerms.fromConfig({
        'carePlanPrice': '12.5',
        'carePlanDiscountPercent': 150,
        'carePlanRemindDays': 0,
        'passportBaseUrl': 'not a url',
      });
      expect(terms.monthlyPrice, 12.5);
      expect(terms.discountPercent, 100);
      expect(terms.remindDays, 1);
      expect(terms.passportBaseUrl, CarePlanTerms.defaultPassportBaseUrl);
      expect(const CarePlanTerms().monthlyPrice, 10);
      expect(const CarePlanTerms().discountPercent, 100);
    });

    test('the app never writes the server-owned Stripe fields', () {
      final plan = CarePlan.fromMap({
        'clientId': 'c1',
        'status': 'active',
        'signedAt': '2026-10-25T12:00:00.000',
        'stripe': {'subscriptionId': 'sub_1', 'lastPaymentAmount': 11.3},
        'phones': ['4165550101'],
      }, 'p1');
      expect(plan.stripeSubscriptionId, 'sub_1');
      expect(plan.lastPaymentAmount, 11.3);
      expect(plan.toMap().containsKey('stripe'), isFalse);
      expect(plan.toMap()['phones'], ['4165550101']);
      expect(CarePlan.fromMap({'status': 'weird'}, 'x').status, CarePlan.pending);
    });
  });

  group('appliance passport', () {
    test('English names for the sticker and the public page', () {
      expect(ApplianceEnglish.of('Стиральная машина'), 'Washer');
      expect(ApplianceEnglish.of('Сушилка'), 'Dryer');
      expect(ApplianceEnglish.of('Посудомойка'), 'Dishwasher');
      expect(ApplianceEnglish.of('Холодильник'), 'Refrigerator');
      expect(ApplianceEnglish.of('Морозильник'), 'Freezer');
      expect(ApplianceEnglish.of('Плита/Духовка'), 'Range');
      expect(ApplianceEnglish.of('Микроволновка'), 'Microwave');
      expect(ApplianceEnglish.of('Кофемашина'), 'Appliance');
      expect(ApplianceEnglish.of('Wine cooler'), 'Wine cooler');
      expect(
        const HomeAppliance(id: 'x', clientId: 'c', type: 'Сушилка', brand: 'LG').englishTitle,
        'LG Dryer',
      );
    });

    test('passport codes are long, unambiguous and make a clean URL', () {
      final code = PassportCode.generate();
      expect(code.length, PassportCode.length);
      expect(PassportCode.isValid(code), isTrue);
      expect(RegExp('[01ilo]').hasMatch(code), isFalse);
      expect(PassportCode.isValid('../etc'), isFalse);
      expect(
        PassportCode.url('https://doc.fix-appliance.ca/a/', 'k7m2x9qa3f'),
        'https://doc.fix-appliance.ca/a/k7m2x9qa3f',
      );
    });

    test('maintenance checklist matches the appliance type', () {
      expect(MaintenanceChecklist.forType('Сушилка'), contains('Exhaust vent duct cleaned'));
      expect(MaintenanceChecklist.forType('Холодильник'), contains('Condenser coils cleaned'));
      expect(MaintenanceChecklist.forType('Что-то'), ['General inspection', 'Test run']);
    });
  });

  group('plan calls and jobs', () {
    setUp(() {
      CarePlanService.debugSetData(
        plans: [
          _plan(),
          _plan(id: 'p2', clientId: 'c2', status: CarePlan.pending, phones: ['4165550102']),
        ],
        appliances: const [
          HomeAppliance(id: 'washer2abc', clientId: 'c1', planId: 'p1', type: 'Стиральная машина'),
          HomeAppliance(id: 'fridge2abc', clientId: 'c1', planId: 'p1', type: 'Холодильник'),
          HomeAppliance(id: 'fridge3abc', clientId: 'c1', type: 'Холодильник'),
          HomeAppliance(id: 'dryer22abc', clientId: 'c1', type: 'Сушилка', status: HomeAppliance.statusRetired),
        ],
      );
    });

    test('a member is found by card or by any phone format; pending plans are not members', () {
      expect(CarePlanService.memberPlanFor(clientId: 'c1')?.id, 'p1');
      expect(CarePlanService.memberPlanFor(phone: '+1 (416) 555-0101')?.id, 'p1');
      expect(CarePlanService.memberPlanFor(phone: '4165550102'), isNull);
      expect(CarePlanService.memberPlanFor(phone: ''), isNull);
      expect(CarePlanService.appliancesForClient('c1').length, 3, reason: 'retired dryer hidden');
    });

    test('a new job of a member is tagged «repair by plan» and linked to an unambiguous passport', () {
      final job = Job(
        id: '',
        clientId: '',
        clientName: 'Amelia',
        clientPhone: '+14165550101',
        clientAddress: '',
        createdAt: DateTime(2026, 10, 25),
        appliances: [
          JobAppliance(type: 'Стиральная машина'),
          JobAppliance(type: 'Холодильник'),
        ],
      );
      final fields = CarePlanService.autoTagFields(job);
      expect(fields['carePlanId'], 'p1');
      expect(fields['carePlanKind'], CarePlan.kindRepair);
      expect(fields['applianceIds'], ['washer2abc'], reason: 'two fridges — FIX picks one himself');

      expect(CarePlanService.autoTagFields(job.copyWith(carePlanId: 'p1')), isEmpty);
      expect(CarePlanService.autoTagFields(job.copyWith(clientPhone: '+14165550102')), isEmpty);
    });

    test('the native incoming-call label lists only member phones', () {
      expect(CarePlanService.callerLabels(CarePlanService.plans), {
        '4165550101': CarePlanService.callerLabel,
      });
    });

    test('jobs keep passport links and plan kind through the model', () {
      final job = Job.fromMap({
        'clientId': 'c1',
        'applianceIds': ['washer2abc', ''],
        'carePlanId': 'p1',
        'carePlanKind': 'maintenance',
      }, 'j1');
      expect(job.applianceIds, ['washer2abc']);
      expect(job.carePlanKind, CarePlan.kindMaintenance);
      final map = job.toMap();
      expect(map['applianceIds'], ['washer2abc']);
      expect(map['carePlanId'], 'p1');
      final plain = Job.fromMap({'clientId': 'c1'}, 'j2').toMap();
      expect(plain.containsKey('applianceIds'), isFalse);
      expect(plain.containsKey('carePlanKind'), isFalse);
    });

    test('a Care Plan push opens the client card', () {
      final target = NotificationRouter.targetFor({'type': 'care_plan', 'clientId': 'c1'});
      expect(target.kind, NotificationTargetKind.client);
      expect(target.clientId, 'c1');
    });
  });

  group('Phomemo M250 sticker', () {
    test('command sequence: init, heat, density, raster header, raster, feed — with the pauses', () {
      final steps = PhomemoCommands.build(
        raster: Uint8List(72 * 300),
        widthBytes: 72,
        heightLines: 300,
        density: 6,
        feedDots: 32,
      );
      expect(steps[0].bytes, [0x1b, 0x40]);
      expect(steps[1].bytes, [0x1b, 0x37, 0x07, 140, 0x02]);
      expect(steps[2].bytes, [0x1d, 0x7c, 6]);
      expect(steps[3].bytes, [0x1d, 0x76, 0x30, 0x00, 72, 0, 44, 1]);
      expect(steps[4].bytes.length, 72 * 300);
      expect(steps[5].bytes, [0x1b, 0x4a, 32]);
      expect([for (final s in steps) s.delayMs], [100, 30, 50, 0, 300, 800]);
      expect(
        PhomemoCommands.build(raster: Uint8List(0), widthBytes: 72, heightLines: 0, density: 99)[2].bytes,
        [0x1d, 0x7c, 8],
      );
    });

    test('raster: left pixel in the high bit, black is 1, the label is centred in the head', () {
      final rgba = Uint8List(10 * 2 * 4)..fillRange(0, 80, 255);
      void black(int x, int y) {
        final i = (y * 10 + x) * 4;
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
      }

      black(0, 0);
      black(9, 0);
      final out = StickerRaster.fromRgba(rgba, 10, 2, widthBytes: 4);
      expect(out.length, 8);
      expect(out.sublist(0, 4), [0, 0x80, 0x40, 0]);
      expect(out.sublist(4), [0, 0, 0, 0]);
    });

    test('a 50×30 sticker becomes a 72-byte raster with ink only inside the label', () async {
      const settings = StickerPrinterSettings(labelWidthMm: 50, labelHeightMm: 30);
      final content = StickerContent.forAppliance(
        const HomeAppliance(
          id: 'k7m2x9qa3f',
          clientId: 'c1',
          type: 'Стиральная машина',
          brand: 'LG',
          serialNumber: '905KWAB12345',
        ),
        company: 'FIX Appliance',
        phone: '(519) 555-0100',
        url: 'https://doc.fix-appliance.ca/a/k7m2x9qa3f',
      );
      expect(content.title, 'Washer');
      final (raster, height) = await StickerRenderer.renderRaster(content, settings);
      expect(height, 240);
      expect(raster.length, 72 * 240);
      expect(raster.fold<int>(0, (n, b) => n + _bits(b)), greaterThan(2000));
      for (var y = 0; y < height; y++) {
        expect(raster[y * 72], 0);
        expect(raster[y * 72 + 71], 0);
      }
    });
  });
}
