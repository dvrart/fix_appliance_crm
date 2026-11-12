import 'package:fix_appliance_crm/features/reports/odsp_report.dart';
import 'package:fix_appliance_crm/features/reports/report_metrics.dart';
import 'package:fix_appliance_crm/models/document_settings.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/models/technician.dart';
import 'package:fix_appliance_crm/models/technician_payout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tech = TechnicianProfile(
    uid: 'tech-ivan-1',
    name: 'Ivan Petrov',
    email: 'ivan@example.test',
    profitSharePercent: 50,
    businessName: 'Ivan Appliance Services',
    collectsHst: true,
    hstNumber: '999888777 RT0001',
    etransferEmail: 'pay@ivanrepair.ca',
  );

  Job buildJob({
    required String id,
    String? assignedTo,
    double taxRate = 0.0,
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> payments,
  }) {
    return Job(
      id: id,
      clientId: 'client-1',
      clientName: 'Sarah Connor',
      clientPhone: '+14165550199',
      clientAddress: '100 King St, Toronto',
      assignedTo: assignedTo,
      createdAt: DateTime(2026, 10, 15, 12),
      documents: [
        {
          'type': 'Invoice',
          'number': '101',
          'createdAt': '2026-10-15T14:00:00',
          'taxRate': taxRate,
          'items': items,
          'payments': payments,
        },
      ],
    );
  }

  test('запчасть купил мастер с фото чека: 350 - 100 = 250 чистыми, по 125 каждому, в офис 125', () {
    final job = buildJob(
      id: 'job-tech-part',
      assignedTo: tech.uid,
      items: [
        {'name': 'Labour', 'type': 'Service', 'qty': 1, 'price': 200.0},
        {
          'name': 'Drain pump',
          'type': 'Part',
          'qty': 1,
          'price': 150.0,
          'costPrice': 100.0,
          'partSource': PartSource.tech,
          'receiptUrl': 'https://storage.test/receipt1.jpg',
        },
      ],
      payments: [
        {'amount': 350.0, 'method': 'e-Transfer', 'date': '2026-10-15T15:00:00'},
      ],
    );

    final payout = TechnicianPayoutCalculator.forJob(
      job,
      profitSharePercent: 50,
    );
    expect(payout.revenueExTax, closeTo(350.0, 0.001));
    expect(payout.techVerifiedPartsCost, closeTo(100.0, 0.001));
    expect(payout.ownerPartsCost, closeTo(0.0, 0.001));
    expect(payout.netProfit, closeTo(250.0, 0.001));
    expect(payout.techProfit, closeTo(125.0, 0.001));
    expect(payout.ownerProfit, closeTo(125.0, 0.001));
    expect(payout.dueToOwner, closeTo(125.0, 0.001));
  });

  test('запчасть выдал владелец: 350 - 100 = 250 чистыми, мастеру 125, в офис 225 (100 деталь + 125 доля)', () {
    final job = buildJob(
      id: 'job-owner-part',
      assignedTo: tech.uid,
      items: [
        {'name': 'Labour', 'type': 'Service', 'qty': 1, 'price': 200.0},
        {
          'name': 'Control board',
          'type': 'Part',
          'qty': 1,
          'price': 150.0,
          'costPrice': 100.0,
          'partSource': PartSource.owner,
        },
      ],
      payments: [
        {'amount': 350.0, 'method': 'Cash', 'date': '2026-10-15T15:00:00'},
      ],
    );

    final payout = TechnicianPayoutCalculator.forJob(
      job,
      profitSharePercent: 50,
    );
    expect(payout.netProfit, closeTo(250.0, 0.001));
    expect(payout.techProfit, closeTo(125.0, 0.001));
    expect(payout.ownerProfit, closeTo(125.0, 0.001));
    expect(payout.dueToOwner, closeTo(225.0, 0.001));
  });

  test('запчасть «купил мастер» без фото чека не вычитается из чистой прибыли, а свой HST мастера не делится', () {
    // Подытог 350 + 13% HST мастера (45.50) = 395.50 оплачено клиентом.
    final job = buildJob(
      id: 'job-no-receipt',
      assignedTo: tech.uid,
      taxRate: 0.13,
      items: [
        {'name': 'Labour', 'type': 'Service', 'qty': 1, 'price': 200.0},
        {
          'name': 'Heater',
          'type': 'Part',
          'qty': 1,
          'price': 150.0,
          'costPrice': 100.0,
          'partSource': PartSource.tech,
          // receiptUrl отсутствует!
        },
      ],
      payments: [
        {'amount': 395.50, 'method': 'e-Transfer', 'date': '2026-10-15T15:00:00'},
      ],
    );

    final payout = TechnicianPayoutCalculator.forJob(
      job,
      profitSharePercent: 50,
    );
    expect(payout.revenueExTax, closeTo(350.0, 0.01));
    expect(payout.techUnverifiedPartsCost, closeTo(100.0, 0.01));
    expect(payout.recognizedPartsCost, closeTo(0.0, 0.01));
    expect(payout.netProfit, closeTo(350.0, 0.01));
    expect(payout.dueToOwner, closeTo(175.0, 0.01));
  });

  test('принятые расчёты уменьшают остаток мастера к передаче в офис', () {
    final job = buildJob(
      id: 'job-1',
      assignedTo: tech.uid,
      items: [
        {'name': 'Service', 'type': 'Service', 'qty': 1, 'price': 200.0},
      ],
      payments: [
        {'amount': 200.0, 'method': 'Cash', 'date': '2026-10-15T15:00:00'},
      ],
    );
    final summary = TechnicianPayoutCalculator.forTechnician(
      technician: tech,
      jobs: [job],
      settlements: [
        TechnicianSettlement(
          id: 's-1',
          technicianId: tech.uid,
          technicianName: tech.name,
          amount: 60.0,
          createdAt: DateTime(2026, 10, 16),
        ),
      ],
    );
    expect(summary.totalGrossDueToOwner, closeTo(100.0, 0.001));
    expect(summary.totalSettled, closeTo(60.0, 0.001));
    expect(summary.balanceDueToOwner, closeTo(40.0, 0.001));
  });

  test('реквизиты частного мастера подменяют HST и почту владельца на счетах', () {
    final shop = DocumentSettings.defaults.copyWith(
      companyName: 'Fix Appliance',
      companyEmail: 'office@fix-appliance.ca',
      companyAddress: 'Waterford, ON',
      hstNumber: '111222333 RT0001',
    );
    final applied = tech.applyToDocumentSettings(shop);
    expect(applied.companyName, 'Ivan Appliance Services');
    expect(applied.hstNumber, '999888777 RT0001');
    expect(applied.companyEmail, 'pay@ivanrepair.ca');
    expect(applied.companyAddress, isEmpty);

    final noTaxTech = tech.copyWith(collectsHst: false);
    expect(noTaxTech.applyToDocumentSettings(shop).hstNumber, isEmpty);
  });

  test('заказы частных мастеров не попадают в отчёт ODSP владельца', () {
    final ownerJob = buildJob(
      id: 'owner-job',
      assignedTo: null,
      items: [
        {'name': 'Repair', 'type': 'Service', 'qty': 1, 'price': 180.0},
      ],
      payments: [
        {'amount': 180.0, 'method': 'e-Transfer', 'date': '2026-10-15T15:00:00'},
      ],
    );
    final techJob = buildJob(
      id: 'tech-job',
      assignedTo: tech.uid,
      items: [
        {'name': 'Repair', 'type': 'Service', 'qty': 1, 'price': 500.0},
      ],
      payments: [
        {'amount': 500.0, 'method': 'e-Transfer', 'date': '2026-10-15T16:00:00'},
      ],
    );
    final metrics = ReportMetrics.build(
      jobs: [ownerJob, techJob],
      start: DateTime(2026, 10, 1),
      endExclusive: DateTime(2026, 11, 1),
    );
    final figures = OdspReportFigures.build(
      companyName: 'Fix Appliance',
      hstNumber: '',
      periodStart: DateTime(2026, 10, 1),
      periodEndInclusive: DateTime(2026, 10, 31),
      metrics: metrics,
      expenses: const [],
    );
    expect(figures.serviceIncome, closeTo(180.0, 0.001));
  });

  test('повторные выезды (recalls) хранят свои описания и отчёты отдельно от первого ремонта', () {
    final r1 = JobRecall(
      id: 'rec_1',
      date: DateTime(2026, 11, 10, 14),
      description: 'Снова течёт снизу',
      report: 'Подтянул хомут патрубка помпы',
      reportEn: 'Tightened the drain pump hose clamp.',
    );
    // При правке только описания перевод отчёта сохраняется:
    final sameReport = r1.copyWith(description: 'Капает при отжиме');
    expect(sameReport.reportEn, 'Tightened the drain pump hose clamp.');

    // При изменении самого отчёта старый перевод сбрасывается для нового автоперевода:
    final changedReport = r1.copyWith(report: 'Заменил патрубок целиком');
    expect(changedReport.reportEn, isEmpty);

    final job = Job(
      id: 'j-recall',
      clientId: 'c-1',
      clientName: 'John',
      clientPhone: '4165550100',
      clientAddress: '1 Main St',
      description: 'Не сливает воду',
      solution: 'Заменил сливную помпу',
      recalls: [r1],
      createdAt: DateTime(2026, 11, 1),
    );
    final roundTrip = Job.fromMap(job.toMap(), job.id);
    expect(roundTrip.description, 'Не сливает воду');
    expect(roundTrip.solution, 'Заменил сливную помпу');
    expect(roundTrip.recalls, hasLength(1));
    expect(roundTrip.recalls.single.description, 'Снова течёт снизу');
    expect(roundTrip.recalls.single.report, 'Подтянул хомут патрубка помпы');
  });
}
