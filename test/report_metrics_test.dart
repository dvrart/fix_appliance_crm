import 'package:fix_appliance_crm/features/reports/report_metrics.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Отчёт за период: что считается продажей, что деньгами, куда идут
/// чаевые и возвраты и во сколько обошлись запчасти.
///
/// Раньше этот расчёт жил внутри экрана и проверить его было нечем, а
/// ошибка здесь уезжает прямо в пакет для T2.
void main() {
  final start = DateTime(2026, 10, 1);
  final end = DateTime(2026, 11, 1);

  Map<String, dynamic> invoice({
    String number = '1001',
    required DateTime date,
    List<Map<String, dynamic>> items = const [],
    double taxRate = 0.13,
    List<Map<String, dynamic>> payments = const [],
    String type = 'Invoice',
    Map<String, dynamic>? stripe,
  }) {
    return {
      'type': type,
      'number': number,
      'createdAt': date.toIso8601String(),
      'items': items,
      'taxRate': taxRate,
      'payments': payments,
      if (stripe != null) 'stripe': stripe,
    };
  }

  Job job({
    String id = 'job1',
    String client = 'Иван',
    DateTime? createdAt,
    DateTime? completedAt,
    String status = 'Завершено',
    List<Map<String, dynamic>> documents = const [],
  }) {
    return Job.fromMap({
      'clientId': 'c1',
      'clientName': client,
      'status': status,
      'createdAt': (createdAt ?? DateTime(2026, 10, 5)).toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt.toIso8601String(),
      'documents': documents,
    }, id);
  }

  ReportMetrics build(List<Job> jobs, {Map<String, double> costs = const {}}) {
    return ReportMetrics.build(
      jobs: jobs,
      start: start,
      endExclusive: end,
      warehouseCosts: costs,
    );
  }

  group('продажи и HST', () {
    test('счёт периода попадает в продажи по дате счёта', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'name': 'Diagnostic', 'qty': 1, 'price': 100.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.invoiceCount, 1);
      expect(m.salesExHst, closeTo(100, 0.001));
      expect(m.hstCollectible, closeTo(13, 0.001));
      expect(m.invoiced, closeTo(113, 0.001));
      expect(m.invoices.single.number, '1001');
    });

    test('счёт соседнего месяца в продажи не идёт', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 9, 29),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.invoiceCount, 0);
      expect(m.salesExHst, 0);
    });

    test('смета не счёт', () {
      final m = build([
        job(
          documents: [
            invoice(
              type: 'Estimate',
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 500.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.invoiceCount, 0);
      expect(m.invoiced, 0);
    });
  });

  group('деньги', () {
    test('оплата признаётся по дате платежа и делится на часть без HST и HST', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 9).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.paid, closeTo(113, 0.001));
      expect(m.cashExHst, closeTo(100, 0.001));
      expect(m.hstReceived, closeTo(13, 0.001));
      expect(m.cashReceivedExHst, closeTo(100, 0.001));
      expect(m.due, closeTo(0, 0.001));
    });

    test('оплата пришла в следующем месяце — в этом её нет, но долг виден', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 20),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 11, 3).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.paid, 0);
      // Долг — состояние на сегодня: деньги уже пришли, пусть и позже.
      expect(m.due, closeTo(0, 0.001));
    });

    test('оплата Stripe без строки платежа всё равно считается один раз', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              stripe: {'status': 'paid'},
            ),
          ],
        ),
      ]);

      expect(m.paid, closeTo(113, 0.001));
      expect(m.payments.length, 1);
      expect(m.due, closeTo(0, 0.001));
    });

    test('депозит — часть денег, остальное в долг', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 200.0},
              ],
              payments: [
                {
                  'amount': 100.0,
                  'method': 'Stripe',
                  'date': DateTime(2026, 10, 8).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.paid, closeTo(100, 0.001));
      expect(m.due, closeTo(126, 0.001));
      expect(m.unpaidInvoices.single.due, closeTo(126, 0.001));
    });
  });

  group('чаевые', () {
    test('чаевые не продажа, не HST и не «Получено»', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 7).toIso8601String(),
                },
                {
                  'amount': 20.0,
                  'method': 'Tip',
                  'date': DateTime(2026, 10, 7).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.tips, closeTo(20, 0.001));
      expect(m.paid, closeTo(113, 0.001));
      expect(m.hstReceived, closeTo(13, 0.001));
      expect(m.salesExHst, closeTo(100, 0.001));
      expect(m.tipPayments.single.hst, closeTo(0, 0.001));
    });

    test('чаевые не закрывают долг по счёту', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 50.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 7).toIso8601String(),
                },
                {
                  'amount': 80.0,
                  'method': 'Tip',
                  'date': DateTime(2026, 10, 7).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.due, closeTo(63, 0.001));
    });
  });

  group('возвраты', () {
    test('возврат уменьшает полученное и виден отдельной строкой', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'Stripe',
                  'date': DateTime(2026, 10, 7).toIso8601String(),
                },
                {
                  'amount': -113.0,
                  'method': 'Stripe (refund)',
                  'date': DateTime(2026, 10, 10).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.paid, closeTo(0, 0.001));
      expect(m.refunds, closeTo(113, 0.001));
      expect(m.refundPayments.length, 1);
      expect(m.hstReceived, closeTo(0, 0.001));
    });
  });

  group('запчасти и работа', () {
    test('себестоимость из позиции счёта, наценка и работа отдельно', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'name': 'Labour', 'qty': 1, 'price': 120.0},
                {
                  'name': 'Pump',
                  'qty': 2,
                  'price': 50.0,
                  'type': 'Part',
                  'costPrice': 20.0,
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.partsCost, closeTo(40, 0.001));
      expect(m.partsSales, closeTo(100, 0.001));
      expect(m.labourSales, closeTo(120, 0.001));
      expect(m.salesExHst, closeTo(220, 0.001));
      expect(m.grossProfit, closeTo(180, 0.001));
      expect(m.parts.single.margin, closeTo(60, 0.001));
      expect(m.labourItems.single.name, 'Labour');
    });

    test('себестоимость берётся со склада, если в счёте её нет', () {
      final m = build(
        [
          job(
            documents: [
              invoice(
                date: DateTime(2026, 10, 7),
                items: [
                  {
                    'name': 'Belt',
                    'qty': 1,
                    'price': 60.0,
                    'type': 'Part',
                    'warehouseItemId': 'w1',
                  },
                ],
              ),
            ],
          ),
        ],
        costs: {'w1': 18.0},
      );

      expect(m.partsCost, closeTo(18, 0.001));
      expect(m.hasGuessedCost, isFalse);
    });

    test('без себестоимости запчасть считается как 40% цены и помечается', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'name': 'Valve', 'qty': 1, 'price': 100.0, 'type': 'Part'},
              ],
            ),
          ],
        ),
      ]);

      expect(m.partsCost, closeTo(40, 0.001));
      expect(m.hasGuessedCost, isTrue);
    });

    test('метка «Service» сильнее себестоимости в позиции', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {
                  'name': 'Washing machine repair',
                  'qty': 1,
                  'price': 300.0,
                  'type': 'Service',
                  'costPrice': 90.0,
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.partsCost, 0);
      expect(m.partsSales, 0);
      expect(m.labourSales, closeTo(300, 0.001));
      expect(m.unclassifiedItems, isEmpty);
    });

    test('метка «Part» без себестоимости — запчасть с прикидкой', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {
                  'name': 'control board for a washing machine',
                  'qty': 1,
                  'price': 300.0,
                  'type': 'Part',
                },
              ],
            ),
          ],
        ),
      ]);

      expect(m.partsSales, closeTo(300, 0.001));
      expect(m.partsCost, closeTo(120, 0.001));
      expect(m.labourSales, 0);
      expect(m.hasGuessedCost, isTrue);
      expect(m.unclassifiedItems, isEmpty);
    });

    test('позиция без метки попадает в список «разобрать»', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {
                  'name': 'control board for a washing machine',
                  'qty': 1,
                  'price': 300.0,
                },
                {'name': 'washing machine repair', 'qty': 1, 'price': 300.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.unclassifiedItems.length, 2);
      // Без метки обе уходят в работу — это и есть та ошибка, из-за которой
      // появился экран «Разобрать позиции».
      expect(m.labourSales, closeTo(600, 0.001));
    });

    test('обычная позиция без типа — это работа, а не запчасть', () {
      final m = build([
        job(
          documents: [
            invoice(
              date: DateTime(2026, 10, 7),
              items: [
                {'name': 'Service call', 'qty': 1, 'price': 99.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.partsCost, 0);
      expect(m.labourSales, closeTo(99, 0.001));
    });
  });

  group('заявки', () {
    test('созданные и завершённые считаются по своим датам', () {
      final m = build([
        job(
          id: 'a',
          createdAt: DateTime(2026, 10, 2),
          completedAt: DateTime(2026, 10, 3),
        ),
        job(
          id: 'b',
          createdAt: DateTime(2026, 9, 20),
          completedAt: DateTime(2026, 10, 4),
        ),
        job(
          id: 'c',
          createdAt: DateTime(2026, 10, 30),
          status: 'В работе',
        ),
      ]);

      expect(m.createdCount, 2);
      expect(m.completedCount, 2);
      expect(m.createdJobs.map((e) => e.job.id), containsAll(['a', 'c']));
    });

    test('удалённая заявка в отчёт не идёт', () {
      final deleted = Job.fromMap({
        'clientName': 'Иван',
        'status': 'Завершено',
        'createdAt': DateTime(2026, 10, 2).toIso8601String(),
        'deletedAt': DateTime(2026, 10, 3).toIso8601String(),
      }, 'x');

      expect(build([deleted]).createdCount, 0);
    });
  });

  group('итоговые показатели', () {
    test('средний чек и собрано', () {
      final m = build([
        job(
          documents: [
            invoice(
              number: '1',
              date: DateTime(2026, 10, 2),
              items: [
                {'qty': 1, 'price': 100.0},
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 2).toIso8601String(),
                },
              ],
            ),
            invoice(
              number: '2',
              date: DateTime(2026, 10, 3),
              items: [
                {'qty': 1, 'price': 300.0},
              ],
            ),
          ],
        ),
      ]);

      expect(m.invoiced, closeTo(452, 0.001));
      expect(m.avgTicket, closeTo(226, 0.001));
      expect(m.collectionRate, closeTo(25, 0.01));
    });

    test('пустой период не делит на ноль', () {
      final m = build([]);
      expect(m.avgTicket, 0);
      expect(m.collectionRate, 0);
      expect(m.grossProfit, 0);
    });
  });
}
