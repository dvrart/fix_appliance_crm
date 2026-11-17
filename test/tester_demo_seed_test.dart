import 'package:fix_appliance_crm/core/constants.dart';
import 'package:fix_appliance_crm/models/care_plan.dart';
import 'package:fix_appliance_crm/models/client.dart';
import 'package:fix_appliance_crm/models/expense.dart';
import 'package:fix_appliance_crm/models/home_appliance.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/models/warehouse_item.dart';
import 'package:fix_appliance_crm/services/sms_service.dart';
import 'package:fix_appliance_crm/services/tester_demo_seed_service.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('набор демо-данных тестировщика содержит 10 клиентов, 15 выездов на неделю и склад', () {
    final anchor = DateTime(2026, 11, 18, 11, 30);
    final bundle = TesterDemoSeedService.buildSeedBundle(now: anchor);

    // 1. Ровно 10 клиентов
    expect(bundle.clients.length, 10);
    final clients = [
      for (final raw in bundle.clients)
        Client.fromMap(raw, raw['id'] as String),
    ];
    for (final client in clients) {
      expect(client.fullName, isNotEmpty);
      expect(client.phone, isNotEmpty);
      expect(client.locations, isNotEmpty);
      expect(client.primaryLocation!.hasCoords, isTrue);
    }

    // 2. Распределение заявок по клиентам: у одного 3, у другого 2, у 8 остальных по 1
    final jobs = [
      for (final raw in bundle.jobs) Job.fromMap(raw, raw['id'] as String),
    ];
    expect(jobs.length, 13);

    final byClient = <String, List<Job>>{};
    for (final job in jobs) {
      byClient.putIfAbsent(job.clientId, () => []).add(job);
    }
    expect(byClient.length, 10);

    final counts = byClient.values.map((list) => list.length).toList()..sort();
    expect(counts, [1, 1, 1, 1, 1, 1, 1, 1, 2, 3]);

    // 3. У всех клиентов с 1 заявкой заявки уже выполнены и оплачены,
    //    а у остальных — в разных активных статусах
    final multiClientStatuses = <String>{};
    for (final entry in byClient.entries) {
      final clientJobs = entry.value;
      if (clientJobs.length == 1) {
        final job = clientJobs.single;
        expect(job.status, JobStatuses.completed);
        expect(job.completedAt, isNotNull);
        expect(job.solution, isNotEmpty);
        expect(job.paymentLabel, 'Оплачено');
        expect(job.coalescedVisits.every((v) => v.isDone), isTrue);
      } else {
        for (final job in clientJobs) {
          expect(JobStatuses.isCompletedStatus(job.status), isFalse);
          multiClientStatuses.add(job.status);
        }
      }
    }
    expect(multiClientStatuses.length, 5);
    expect(
      multiClientStatuses,
      containsAll(<String>[
        JobStatuses.call,
        JobStatuses.waitingPart,
        JobStatuses.install,
        JobStatuses.deposit,
        JobStatuses.waitingPayment,
      ]),
    );

    // 4. Все 15 выездов лежат внутри текущей недели (понедельник — воскресенье)
    final monday = DateTime(2026, 11, 16);
    final nextMonday = monday.add(const Duration(days: 7));
    final allVisits = [for (final job in jobs) ...job.coalescedVisits];
    expect(allVisits.length, 15);
    for (final visit in allVisits) {
      expect(
        !visit.startAt.isBefore(monday) && visit.startAt.isBefore(nextMonday),
        isTrue,
      );
    }

    // 5. Склад наполнен запчастями всех основных категорий
    expect(bundle.warehouseItems.length, 12);
    final parts = [
      for (final raw in bundle.warehouseItems)
        WarehouseItem.fromMap(raw, raw['id'] as String),
    ];
    final categories = {for (final p in parts) p.category};
    expect(
      categories,
      containsAll(<String>[
        'Холодильник',
        'Стиральная машина',
        'Сушилка',
        'Плита/Духовка',
        'Посудомойка',
        'Универсальное',
      ]),
    );

    // 6. Расходы, звонки, SMS, Care Plan и паспорта читаются моделями без ошибок
    final expenses = [
      for (final raw in bundle.expenses)
        Expense.fromMap(raw, raw['id'] as String),
    ];
    expect(expenses.length, 5);

    final calls = [
      for (final raw in bundle.calls)
        CallRecord.fromMap(raw, raw['id'] as String),
    ];
    expect(calls.length, 4);

    final messages = [
      for (final raw in bundle.messages)
        SmsMessage.fromMap(raw, raw['id'] as String),
    ];
    expect(messages.length, 6);

    final plans = [
      for (final raw in bundle.carePlans)
        CarePlan.fromMap(raw, raw['id'] as String),
    ];
    expect(plans.length, 1);

    final appliances = [
      for (final raw in bundle.appliances)
        HomeAppliance.fromMap(raw, raw['id'] as String),
    ];
    expect(appliances.length, 1);
  });
}
