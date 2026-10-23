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

  group('детализация: заявка, инвойс, деталь', () {
    test('расклад по каждой детали, каждому инвойсу и каждой заявке сходится', () {
      final j1 = job(
        id: 'job_a',
        client: 'Алексей',
        documents: [
          invoice(
            number: '101',
            date: DateTime(2026, 10, 5),
            items: [
              {'name': 'Diagnostic & Labour', 'qty': 1, 'price': 150.0, 'type': 'Service'},
              {
                'name': 'Drain pump',
                'qty': 1,
                'price': 140.0,
                'type': 'Part',
                'costPrice': 45.0,
              },
              {
                'name': 'Clamp',
                'qty': 2,
                'price': 15.0,
                'type': 'Part',
                'costPrice': 4.0,
              },
            ],
            payments: [
              {
                'amount': 361.60,
                'method': 'Stripe',
                'date': DateTime(2026, 10, 5).toIso8601String(),
              },
            ],
          ),
          invoice(
            number: '102',
            date: DateTime(2026, 10, 12),
            items: [
              {'name': 'Follow-up install', 'qty': 1, 'price': 80.0, 'type': 'Service'},
              {
                'name': 'Control board',
                'qty': 1,
                'price': 260.0,
                'type': 'Part',
                'costPrice': 110.0,
              },
            ],
          ),
        ],
      );

      final m = build([j1]);

      // Итоги периода:
      // Запчасти для меня: 45 + (2 * 4) + 110 = 163
      // Запчасти для клиента: 140 + 30 + 260 = 430
      // Наценка на запчастях: 430 - 163 = 267
      // Работа: 150 + 80 = 230
      // Грязными без HST: 430 + 230 = 660
      // Чистыми (после запчастей): 660 - 163 = 497
      expect(m.partsCost, closeTo(163, 0.001));
      expect(m.partsSales, closeTo(430, 0.001));
      expect(m.partsMargin, closeTo(267, 0.001));
      expect(m.labourSales, closeTo(230, 0.001));
      expect(m.salesExHst, closeTo(660, 0.001));
      expect(m.grossProfit, closeTo(497, 0.001));

      // Проверка уровня заявки (invoiceJobs):
      expect(m.invoiceJobs.length, 1);
      final rJob = m.invoiceJobs.single;
      expect(rJob.salesExHst, closeTo(660, 0.001));
      expect(rJob.partsCost, closeTo(163, 0.001));
      expect(rJob.partsSales, closeTo(430, 0.001));
      expect(rJob.partsMargin, closeTo(267, 0.001));
      expect(rJob.labourSales, closeTo(230, 0.001));
      expect(rJob.netProfit, closeTo(497, 0.001));
      expect(rJob.invoices.length, 2);
      expect(rJob.parts.length, 3);

      // Проверка уровня инвойса #101:
      final inv101 = m.invoices.firstWhere((i) => i.number == '101');
      expect(inv101.docIndex, 0);
      expect(inv101.grossExHst, closeTo(320, 0.001));
      expect(inv101.partsCost, closeTo(53, 0.001));
      expect(inv101.partsSales, closeTo(170, 0.001));
      expect(inv101.partsMargin, closeTo(117, 0.001));
      expect(inv101.labourSales, closeTo(150, 0.001));
      expect(inv101.netProfit, closeTo(267, 0.001));
      expect(inv101.paidExHst, closeTo(320, 0.001));
      expect(inv101.paidNetProfit, closeTo(267, 0.001));

      // Проверка уровня отдельной детали (Clamp, 2 шт.):
      final clamp = inv101.parts.firstWhere((p) => p.name == 'Clamp');
      expect(clamp.docIndex, 0);
      expect(clamp.itemIndex, 2);
      expect(clamp.cost, closeTo(8, 0.001));
      expect(clamp.sold, closeTo(30, 0.001));
      expect(clamp.margin, closeTo(22, 0.001));
    });
  });

  group('разбивка и фильтр по способу оплаты', () {
    test('делит заработок на наличные, кредитку и электронный перевод', () {
      final m = build([
        job(
          id: 'j_cash',
          client: 'Олег',
          documents: [
            invoice(
              number: '201',
              date: DateTime(2026, 10, 4),
              items: [
                {'name': 'Labour', 'qty': 1, 'price': 100.0, 'type': 'Service'},
                {
                  'name': 'Belt',
                  'qty': 1,
                  'price': 50.0,
                  'type': 'Part',
                  'costPrice': 20.0,
                },
              ],
              payments: [
                {
                  'amount': 169.50,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 4).toIso8601String(),
                },
                {
                  'amount': 10.0,
                  'method': 'Tip',
                  'date': DateTime(2026, 10, 4).toIso8601String(),
                },
              ],
            ),
          ],
        ),
        job(
          id: 'j_card',
          client: 'Мария',
          documents: [
            invoice(
              number: '202',
              date: DateTime(2026, 10, 6),
              items: [
                {'name': 'Labour', 'qty': 1, 'price': 120.0, 'type': 'Service'},
                {
                  'name': 'Pump',
                  'qty': 1,
                  'price': 80.0,
                  'type': 'Part',
                  'costPrice': 30.0,
                },
              ],
              payments: [
                {
                  'amount': 226.0,
                  'method': 'Stripe (card present)',
                  'date': DateTime(2026, 10, 6).toIso8601String(),
                },
                {
                  'amount': 15.0,
                  'method': 'Чаевые',
                  'date': DateTime(2026, 10, 6).toIso8601String(),
                },
              ],
            ),
          ],
        ),
        job(
          id: 'j_et',
          client: 'Денис',
          documents: [
            invoice(
              number: '203',
              date: DateTime(2026, 10, 8),
              items: [
                {
                  'name': 'Diagnostic',
                  'qty': 1,
                  'price': 100.0,
                  'type': 'Service',
                },
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'e-Transfer',
                  'date': DateTime(2026, 10, 8).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      final cash = m.forMethod(ReportPayMethod.cash);
      final card = m.forMethod(ReportPayMethod.card);
      final etransfer = m.forMethod(ReportPayMethod.etransfer);

      // Наличные: выручка 150, себестоимость 20, чистыми 130, с HST 169.50, чаевые 10
      expect(cash.salesExHst, closeTo(150, 0.001));
      expect(cash.invoiced, closeTo(169.50, 0.001));
      expect(cash.paid, closeTo(169.50, 0.001));
      expect(cash.partsCost, closeTo(20, 0.001));
      expect(cash.partsSales, closeTo(50, 0.001));
      expect(cash.grossProfit, closeTo(130, 0.001));
      expect(cash.tips, closeTo(10, 0.001));
      expect(cash.invoiceCount, 1);

      // Кредитка (Stripe): выручка 200, себестоимость 30, чистыми 170, с HST 226, чаевые 15
      expect(card.salesExHst, closeTo(200, 0.001));
      expect(card.invoiced, closeTo(226.0, 0.001));
      expect(card.paid, closeTo(226.0, 0.001));
      expect(card.partsCost, closeTo(30, 0.001));
      expect(card.partsSales, closeTo(80, 0.001));
      expect(card.grossProfit, closeTo(170, 0.001));
      expect(card.tips, closeTo(15, 0.001));
      expect(card.invoiceCount, 1);

      // Электронный перевод: выручка 100, себестоимость 0, чистыми 100, с HST 113
      expect(etransfer.salesExHst, closeTo(100, 0.001));
      expect(etransfer.invoiced, closeTo(113.0, 0.001));
      expect(etransfer.paid, closeTo(113.0, 0.001));
      expect(etransfer.partsCost, closeTo(0, 0.001));
      expect(etransfer.grossProfit, closeTo(100, 0.001));
      expect(etransfer.tips, closeTo(0, 0.001));
      expect(etransfer.invoiceCount, 1);

      // Сумма всех трёх способов сходится с общим итогом периода:
      expect(
        cash.grossProfit + card.grossProfit + etransfer.grossProfit,
        closeTo(m.grossProfit, 0.001),
      );
      expect(
        cash.paid + card.paid + etransfer.paid,
        closeTo(m.paid, 0.001),
      );
    });

    test('счёт, оплаченный пополам двумя способами, делится пропорционально', () {
      final m = build([
        job(
          id: 'j_split',
          client: 'Анна',
          documents: [
            invoice(
              number: '301',
              date: DateTime(2026, 10, 10),
              items: [
                {'name': 'Labour', 'qty': 1, 'price': 100.0, 'type': 'Service'},
                {
                  'name': 'Heater',
                  'qty': 1,
                  'price': 100.0,
                  'type': 'Part',
                  'costPrice': 40.0,
                },
              ],
              payments: [
                {
                  'amount': 113.0,
                  'method': 'e-Transfer',
                  'date': DateTime(2026, 10, 10).toIso8601String(),
                },
                {
                  'amount': 113.0,
                  'method': 'Cash',
                  'date': DateTime(2026, 10, 11).toIso8601String(),
                },
              ],
            ),
          ],
        ),
      ]);

      final cash = m.forMethod(ReportPayMethod.cash);
      final etransfer = m.forMethod(ReportPayMethod.etransfer);
      final card = m.forMethod(ReportPayMethod.card);

      expect(card.paid, 0);
      expect(card.invoiceCount, 0);

      // Половина счёта — наличными, половина — переводом:
      expect(cash.paid, closeTo(113, 0.001));
      expect(cash.salesExHst, closeTo(100, 0.001));
      expect(cash.partsCost, closeTo(20, 0.001));
      expect(cash.partsSales, closeTo(50, 0.001));
      expect(cash.grossProfit, closeTo(80, 0.001));

      expect(etransfer.paid, closeTo(113, 0.001));
      expect(etransfer.salesExHst, closeTo(100, 0.001));
      expect(etransfer.partsCost, closeTo(20, 0.001));
      expect(etransfer.partsSales, closeTo(50, 0.001));
      expect(etransfer.grossProfit, closeTo(80, 0.001));
    });

    test(
      'счёт с депозитом в один день и доплатой в другой день входит в оба дня по своей доле, и «Все» равно сумме способов оплаты',
      () {
        final jobs = [
          job(
            id: 'j_split_days',
            client: '000369940 Ontario Inc',
            documents: [
              invoice(
                number: '0086',
                date: DateTime(2026, 10, 16, 12, 13),
                taxRate: 0,
                items: [
                  {
                    'name': 'oven repair',
                    'qty': 1,
                    'price': 200.0,
                    'type': 'Service',
                  },
                  {
                    'name': 'GE Range Igniter Glowbar',
                    'qty': 1,
                    'price': 118.0,
                    'costPrice': 30.0,
                    'type': 'Part',
                  },
                ],
                payments: [
                  {
                    'amount': 159.0,
                    'method': 'Stripe (deposit)',
                    'date': DateTime(2026, 10, 16, 16, 15).toIso8601String(),
                  },
                  {
                    'amount': 159.0,
                    'method': 'Stripe',
                    'date': DateTime(2026, 10, 19, 21, 54).toIso8601String(),
                  },
                ],
              ),
            ],
          ),
          job(
            id: 'j_cash_1',
            client: 'Kate Broussard',
            documents: [
              invoice(
                number: '0087',
                date: DateTime(2026, 10, 19, 14, 59),
                taxRate: 0,
                items: [
                  {
                    'name': 'Service call',
                    'qty': 1,
                    'price': 99.0,
                    'type': 'Service',
                  },
                ],
                payments: [
                  {
                    'amount': 99.0,
                    'method': 'Cash',
                    'date': DateTime(2026, 10, 19, 14, 59).toIso8601String(),
                  },
                ],
              ),
            ],
          ),
          job(
            id: 'j_cash_2',
            client: 'Mike Feetham',
            documents: [
              invoice(
                number: '0088',
                date: DateTime(2026, 10, 19, 17, 25),
                taxRate: 0,
                items: [
                  {
                    'name': 'inverter control board GE',
                    'qty': 1,
                    'price': 300.0,
                    'costPrice': 250.0,
                    'type': 'Part',
                  },
                  {
                    'name': 'washing machine repair',
                    'qty': 1,
                    'price': 150.0,
                    'type': 'Service',
                  },
                ],
                payments: [
                  {
                    'amount': 450.0,
                    'method': 'Cash',
                    'date': DateTime(2026, 10, 19, 17, 26).toIso8601String(),
                  },
                ],
              ),
            ],
          ),
          job(
            id: 'j_cash_3',
            client: 'Rodolfo Benavides',
            documents: [
              invoice(
                number: '0089',
                date: DateTime(2026, 10, 19, 18, 42),
                taxRate: 0,
                items: [
                  {
                    'name': 'Service call',
                    'qty': 1,
                    'price': 99.0,
                    'type': 'Service',
                  },
                ],
                payments: [
                  {
                    'amount': 99.0,
                    'method': 'Cash',
                    'date': DateTime(2026, 10, 19, 18, 42).toIso8601String(),
                  },
                ],
              ),
            ],
          ),
        ];

        // День 19 октября 2026:
        final day19 = ReportMetrics.build(
          jobs: jobs,
          start: DateTime(2026, 10, 19),
          endExclusive: DateTime(2026, 10, 20),
        );
        final cash19 = day19.forMethod(ReportPayMethod.cash);
        final card19 = day19.forMethod(ReportPayMethod.card);

        // Наличные за 19 окт: грязными 648, запчасти 250, чистыми 398
        expect(cash19.salesExHst, closeTo(648, 0.001));
        expect(cash19.partsCost, closeTo(250, 0.001));
        expect(cash19.grossProfit, closeTo(398, 0.001));

        // Кредитка за 19 окт (вторая половина счёта #0086):
        // грязными 159, доля детали 15 (половина от 30), чистыми 144
        expect(card19.salesExHst, closeTo(159, 0.001));
        expect(card19.invoiced, closeTo(159, 0.001));
        expect(card19.paid, closeTo(159, 0.001));
        expect(card19.partsCost, closeTo(15, 0.001));
        expect(card19.partsSales, closeTo(59, 0.001));
        expect(card19.grossProfit, closeTo(144, 0.001));
        expect(card19.invoiceCount, 1);
        expect(card19.invoiceJobs.length, 1);

        // Всего за 19 окт = Наличные (398) + Кредитка (144) = 542 чистыми (807 грязными)
        expect(day19.salesExHst, closeTo(807, 0.001));
        expect(day19.invoiced, closeTo(807, 0.001));
        expect(day19.paid, closeTo(807, 0.001));
        expect(day19.partsCost, closeTo(265, 0.001));
        expect(day19.grossProfit, closeTo(542, 0.001));
        expect(
          cash19.grossProfit + card19.grossProfit,
          closeTo(day19.grossProfit, 0.001),
        );

        // День 16 октября 2026 (первая половина счёта #0086):
        final day16 = ReportMetrics.build(
          jobs: jobs,
          start: DateTime(2026, 10, 16),
          endExclusive: DateTime(2026, 10, 17),
        );
        expect(day16.salesExHst, closeTo(159, 0.001));
        expect(day16.partsCost, closeTo(15, 0.001));
        expect(day16.grossProfit, closeTo(144, 0.001));

        // За весь октябрь оба дня складываются ровно в 100% без задвоения:
        final month = build(jobs);
        expect(
          day16.grossProfit + day19.grossProfit,
          closeTo(month.grossProfit, 0.001),
        );
      },
    );
  });
}
