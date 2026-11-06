import 'package:fix_appliance_crm/features/reports/odsp_report.dart';
import 'package:fix_appliance_crm/features/reports/report_metrics.dart';
import 'package:fix_appliance_crm/models/expense.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разложение цифр CRM по строкам месячной формы ODSP 3083E.
/// Ошибка здесь уезжает прямо в отчёт для соцработника.
///
/// Правило FIX (05.11.2026): доход — только безнал (карта/Stripe и e-Transfer,
/// наличные не считаются) и только работа/чаевые (заработок на запчастях не
/// плюсуется, sale of goods = 0); расходы — все, включая любую закупку запчастей.
void main() {
  final start = DateTime(2026, 10, 1);
  final endExclusive = DateTime(2026, 11, 1);
  final endInclusive = DateTime(2026, 10, 31);

  Expense receipt({
    required String category,
    required double amount,
    bool capital = false,
  }) {
    final info = ExpenseCategories.byId(category);
    return Expense(
      id: 'e-$category-$amount-$capital',
      vendor: 'Test',
      date: DateTime(2026, 10, 10),
      amountExHst: amount,
      hst: 0,
      total: amount,
      category: info.id,
      gifi: info.gifi,
      capitalAsset: capital,
      createdAt: DateTime(2026, 10, 11),
    );
  }

  OdspReportFigures build({
    ReportMetrics metrics = const ReportMetrics(),
    ReportMetrics? cardMetrics,
    ReportMetrics? etransferMetrics,
    List<Expense> expenses = const [],
    String hstNumber = '',
    String companyName = 'FIX-APPLIANCE.CA',
  }) {
    return OdspReportFigures.build(
      companyName: companyName,
      hstNumber: hstNumber,
      periodStart: start,
      periodEndInclusive: endInclusive,
      metrics: metrics,
      cardMetrics: cardMetrics,
      etransferMetrics: etransferMetrics,
      expenses: expenses,
    );
  }

  group('доход — только карта и e-Transfer, без наличных и без запчастей', () {
    test('в доход идут работа и чаевые по карте и e-Transfer, запчасти не плюсуются', () {
      final f = build(
        cardMetrics: const ReportMetrics(
          partsSales: 300,
          labourSales: 350,
          tips: 15,
          hstCollectible: 84.5,
        ),
        etransferMetrics: const ReportMetrics(
          partsSales: 250,
          labourSales: 100,
          tips: 5,
          hstCollectible: 45.5,
        ),
      );

      expect(f.saleOfGoods, 0);
      expect(f.serviceIncome, closeTo(450, 0.001));
      expect(f.otherIncome, closeTo(20, 0.001));
      expect(f.totalIncome, closeTo(470, 0.001));
    });

    test('пустой месяц — нулевой доход', () {
      final f = build();
      expect(f.totalIncome, 0);
      expect(f.netBusinessIncome, 0);
    });

    test('карта и e-Transfer считаются (только работа), наличные — нет', () {
      Map<String, dynamic> invoice({
        required List<Map<String, dynamic>> items,
        required List<Map<String, dynamic>> payments,
      }) {
        return {
          'type': 'Invoice',
          'number': '1001',
          'createdAt': DateTime(2026, 10, 7).toIso8601String(),
          'items': items,
          'taxRate': 0.13,
          'payments': payments,
        };
      }

      Job job(String id, List<Map<String, dynamic>> documents) {
        return Job.fromMap({
          'clientId': 'c1',
          'clientName': 'Клиент',
          'status': 'Завершено',
          'createdAt': DateTime(2026, 10, 5).toIso8601String(),
          'documents': documents,
        }, id);
      }

      // Наличными: работа 1000 + запчасть 550 (закупка 466,44), HST 13%.
      // Наличная оплата в доход НЕ идёт, но закупка её запчасти — расход.
      final cashJob = job('cash-job', [
        invoice(
          items: [
            {'name': 'Repair', 'qty': 1, 'price': 1000.0},
            {
              'name': 'Pump',
              'qty': 1,
              'price': 550.0,
              'type': 'Part',
              'costPrice': 466.44,
            },
          ],
          payments: [
            {
              'amount': 1751.50,
              'method': 'Cash',
              'date': DateTime(2026, 10, 8).toIso8601String(),
            },
            {
              'amount': 50.0,
              'method': 'Cash Tip',
              'date': DateTime(2026, 10, 8).toIso8601String(),
            },
          ],
        ),
      ]);
      // Переводом: работа 500 + запчасть 100 (закупка 70), HST 13%.
      // В доход идёт только работа 500 (запчасть 100 не плюсуется).
      final transferJob = job('transfer-job', [
        invoice(
          items: [
            {'name': 'Repair', 'qty': 1, 'price': 500.0},
            {
              'name': 'Valve',
              'qty': 1,
              'price': 100.0,
              'type': 'Part',
              'costPrice': 70.0,
            },
          ],
          payments: [
            {
              'amount': 678.0,
              'method': 'e-Transfer',
              'date': DateTime(2026, 10, 9).toIso8601String(),
            },
          ],
        ),
      ]);
      // Картой (Stripe): работа 300 + чаевые 25.
      final cardJob = job('card-job', [
        invoice(
          items: [
            {'name': 'Repair', 'qty': 1, 'price': 300.0},
          ],
          payments: [
            {
              'amount': 339.0,
              'method': 'Stripe',
              'date': DateTime(2026, 10, 10).toIso8601String(),
            },
            {
              'amount': 25.0,
              'method': 'Stripe Tip',
              'date': DateTime(2026, 10, 10).toIso8601String(),
            },
          ],
        ),
      ]);

      // Оплата по ссылке и дебетовой картой, даже если в том же счёте был
      // наличный аванс: работа 200 + запчасть 100 (закупка 60, наценка 40),
      // HST 13% -> всего 339. Наличными заплатили треть (113), остальное
      // (226 = две трети) — по ссылке и дебетовой картой. В доход пойдёт
      // только 2/3 от работы (200 * 2/3 = 133.333...), без наличной трети и
      // без запчасти / её наценки.
      final mixedLinkDebitJob = job('mixed-link-debit-job', [
        invoice(
          items: [
            {'name': 'Repair', 'qty': 1, 'price': 200.0},
            {
              'name': 'Sensor',
              'qty': 1,
              'price': 100.0,
              'type': 'Part',
              'costPrice': 60.0,
            },
          ],
          payments: [
            {
              'amount': 113.0,
              'method': 'Cash',
              'date': DateTime(2026, 10, 11).toIso8601String(),
            },
            {
              'amount': 113.0,
              'method': 'Payment link',
              'date': DateTime(2026, 10, 11).toIso8601String(),
            },
            {
              'amount': 113.0,
              'method': 'Debit',
              'date': DateTime(2026, 10, 11).toIso8601String(),
            },
          ],
        ),
      ]);

      final full = ReportMetrics.build(
        jobs: [cashJob, transferJob, cardJob, mixedLinkDebitJob],
        start: start,
        endExclusive: endExclusive,
      );
      final f = build(metrics: full);

      expect(f.saleOfGoods, 0);
      expect(f.serviceIncome, closeTo(800 + 200 * 2 / 3, 0.001));
      expect(f.otherIncome, closeTo(25, 0.001));
      expect(f.totalIncome, closeTo(825 + 200 * 2 / 3, 0.001));
      expect(f.hstCollected, closeTo(117 + 39 * 2 / 3, 0.001));
      // Расход — весь: закупка всех запчастей, независимо от способа оплаты.
      expect(f.costOfGoodsPurchased, closeTo(596.44, 0.001));
    });
  });

  group('вопрос про GST/HST', () {
    test('HST-номер указан — ответ Yes и сумма налога месяца', () {
      final f = build(
        hstNumber: '12345 6789 RT0001',
        cardMetrics: const ReportMetrics(hstCollectible: 130),
      );
      expect(f.collectsHst, isTrue);
      expect(f.hstCollected, closeTo(130, 0.001));
    });

    test('без HST-номера — ответ No', () {
      final f = build(cardMetrics: const ReportMetrics(hstCollectible: 130));
      expect(f.collectsHst, isFalse);
    });
  });

  group('расходы', () {
    test('категории чеков попадают в свои строки формы', () {
      final f = build(
        metrics: const ReportMetrics(partsCost: 466.44),
        expenses: [
          receipt(category: 'phone', amount: 85),
          receipt(category: 'insurance', amount: 45),
          receipt(category: 'vehicle', amount: 300),
          receipt(category: 'fees', amount: 12.5),
          receipt(category: 'accounting', amount: 100),
          receipt(category: 'advertising', amount: 40),
          receipt(category: 'rent', amount: 200),
          receipt(category: 'supplies', amount: 30),
          receipt(category: 'tools', amount: 70),
        ],
      );

      expect(f.costOfGoodsPurchased, closeTo(466.44, 0.001));
      expect(f.telephone, closeTo(85, 0.001));
      expect(f.businessInsurance, closeTo(45, 0.001));
      expect(f.vehicleExpense, closeTo(300, 0.001));
      expect(f.bankCharges, closeTo(12.5, 0.001));
      expect(f.accountingFees, closeTo(100, 0.001));
      expect(f.advertising, closeTo(40, 0.001));
      expect(f.rent, closeTo(200, 0.001));
      expect(f.suppliesAndEquipment, closeTo(100, 0.001));
      expect(f.totalExpenses, closeTo(1348.94, 0.001));
    });

    test('чеки запчастей складываются с закупкой из счетов, разбивка видна', () {
      final f = build(
        metrics: const ReportMetrics(partsCost: 400),
        expenses: [receipt(category: 'parts', amount: 66.44)],
      );

      expect(f.costFromInvoices, closeTo(400, 0.001));
      expect(f.costFromReceipts, closeTo(66.44, 0.001));
      expect(f.costOfGoodsPurchased, closeTo(466.44, 0.001));
    });

    test('прочее, еда и зарплата идут в other expenses с расшифровкой', () {
      final f = build(
        expenses: [
          receipt(category: 'other', amount: 15),
          receipt(category: 'meals', amount: 20),
          receipt(category: 'wages', amount: 500),
        ],
      );

      expect(f.otherExpenses, closeTo(535, 0.001));
      expect(f.otherSpec.length, 3);
    });

    test('капитальный инструмент (CCA) в расходы месяца не входит', () {
      final f = build(
        expenses: [
          receipt(category: 'tools', amount: 900, capital: true),
          receipt(category: 'tools', amount: 50),
        ],
      );

      expect(f.suppliesAndEquipment, closeTo(50, 0.001));
      expect(f.capitalTotal, closeTo(900, 0.001));
    });

    test('чистый доход = доход минус расходы, как на бумажной форме', () {
      final f = build(
        metrics: const ReportMetrics(partsCost: 766.44),
        cardMetrics: const ReportMetrics(labourSales: 1000),
        expenses: [
          receipt(category: 'phone', amount: 85),
          receipt(category: 'insurance', amount: 45),
        ],
      );

      expect(f.totalIncome, closeTo(1000, 0.001));
      expect(f.totalExpenses, closeTo(896.44, 0.001));
      expect(f.netBusinessIncome, closeTo(103.56, 0.001));
    });
  });

  group('текст для буфера', () {
    test('строки идут в порядке формы и с итогами', () {
      final f = build(
        hstNumber: '12345 6789 RT0001',
        metrics: const ReportMetrics(partsCost: 466.44),
        cardMetrics: const ReportMetrics(
          partsSales: 550,
          labourSales: 1000,
          hstCollectible: 113,
        ),
        expenses: [receipt(category: 'phone', amount: 85)],
      );
      final text = f.clipboardText();

      expect(text, contains('Report for Period: October 2026 (Month)'));
      expect(text, contains('Sale of goods: \$0.00'));
      expect(text, contains('Service income: \$1000.00'));
      expect(text, contains('Total Income: \$1000.00'));
      expect(text, contains('Are you collecting GST/HST? Yes'));
      expect(text, contains('Telephone: \$85.00'));
      expect(text, contains('Total Expenses: \$551.44'));
      expect(text, contains('Net Business Income'));
      expect(text, contains('business kilometres: fill in by hand'));
      expect(text, contains('only cashless payments'));
    });

    test('без HST-номера в тексте ответ No', () {
      final f = build();
      expect(f.clipboardText(), contains('Are you collecting GST/HST? No'));
    });
  });
}
