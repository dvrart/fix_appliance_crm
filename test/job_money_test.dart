import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/job_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Деньги: сумма счёта, HST, оплаты, метка оплаты.
///
/// До этого тестами были закрыты звук, звонки и SMS, а расчёт счёта — нет,
/// хотя ошибка здесь стоит денег и уезжает клиенту в PDF. Здесь закреплено
/// поведение, на которое опираются карточка заявки, список и отчёты.
void main() {
  Map<String, dynamic> invoice({
    List<Map<String, dynamic>> items = const [],
    double taxRate = 0.13,
    List<Map<String, dynamic>> payments = const [],
    String type = 'Invoice',
    Map<String, dynamic>? stripe,
    String? deletedAt,
    String? status,
  }) {
    return {
      'type': type,
      'items': items,
      'taxRate': taxRate,
      'payments': payments,
      if (stripe != null) 'stripe': stripe,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (status != null) 'status': status,
    };
  }

  group('сумма счёта', () {
    test('складывает количество на цену', () {
      final doc = invoice(
        items: [
          {'name': 'Вызов', 'qty': 1, 'price': 99.0},
          {'name': 'Ремень', 'qty': 2, 'price': 45.50},
        ],
      );

      expect(Job.documentSubtotal(doc), closeTo(190.0, 0.001));
    });

    test('количество не указано — считаем одну штуку', () {
      final doc = invoice(
        items: [
          {'name': 'Вызов', 'price': 99.0},
        ],
      );
      expect(Job.documentSubtotal(doc), closeTo(99.0, 0.001));
    });

    test('числа строками тоже считаются', () {
      final doc = invoice(
        items: [
          {'qty': '2', 'price': '45.50'},
        ],
      );
      expect(Job.documentSubtotal(doc), closeTo(91.0, 0.001));
    });

    test('мусор в позициях не ломает счёт', () {
      expect(Job.documentSubtotal(invoice(items: const [])), 0);
      expect(Job.documentSubtotal({'items': 'не список'}), 0);
      expect(
        Job.documentSubtotal({
          'items': [
            'мусор',
            42,
            {'qty': 1, 'price': 10.0},
          ],
        }),
        closeTo(10.0, 0.001),
      );
    });

    test('HST 13% и итог', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 200.0},
        ],
      );

      expect(Job.documentTax(doc), closeTo(26.0, 0.001));
      expect(Job.documentTotal(doc), closeTo(226.0, 0.001));
    });

    test('без налога итог равен сумме позиций', () {
      final doc = invoice(
        taxRate: 0,
        items: [
          {'qty': 1, 'price': 200.0},
        ],
      );
      expect(Job.documentTax(doc), 0);
      expect(Job.documentTotal(doc), closeTo(200.0, 0.001));
    });
  });

  group('оплаты', () {
    test('складывает все платежи', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        payments: [
          {'amount': 50.0, 'method': 'Cash'},
          {'amount': 63.0, 'method': 'e-Transfer'},
        ],
      );
      expect(Job.documentPaid(doc), closeTo(113.0, 0.001));
    });

    test('оплата через Stripe без списка платежей закрывает счёт', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        stripe: {'status': 'paid'},
      );
      expect(Job.documentPaid(doc), closeTo(113.0, 0.001));
      expect(Job.documentPayMark(doc), 'paid');
    });
  });

  group('метка оплаты в списке', () {
    Map<String, dynamic> withPaid(double amount) => invoice(
      items: [
        {'qty': 1, 'price': 100.0},
      ],
      payments: [
        {'amount': amount, 'method': 'Cash'},
      ],
    );

    test('полностью оплачен', () {
      expect(Job.documentPayMark(withPaid(113.0)), 'paid');
    });

    test('частично — депозит', () {
      expect(Job.documentPayMark(withPaid(50.0)), 'deposit');
    });

    test('ничего не платили', () {
      expect(Job.documentPayMark(invoice(items: [
        {'qty': 1, 'price': 100.0},
      ])), 'unpaid');
    });

    test('копеечный недобор всё равно считается оплатой', () {
      // 113 - 112.995 = 0.005, меньше допуска: иначе счёт вечно висел бы
      // недоплаченным из-за округления центов.
      expect(Job.documentPayMark(withPaid(112.995)), 'paid');
    });

    test('недобор в цент оплатой не считается', () {
      expect(Job.documentPayMark(withPaid(112.98)), 'deposit');
    });

    test('возврат помечается возвратом, а не депозитом', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        payments: [
          {'amount': 113.0, 'method': 'Cash'},
          {'amount': -113.0, 'method': 'Refund'},
        ],
      );
      expect(Job.documentPayMark(doc), 'refunded');
    });

    test('смета метки оплаты не получает', () {
      expect(Job.documentPayMark(invoice(type: 'Estimate')), '');
    });

    test('удалённый счёт метки не получает', () {
      expect(
        Job.documentPayMark(
          invoice(
            items: [
              {'qty': 1, 'price': 100.0},
            ],
            deletedAt: '2026-09-21T10:00:00.000Z',
          ),
        ),
        '',
      );
    });

    test('отменённый счёт не считается счётом', () {
      expect(Job.isInvoice(invoice(status: 'cancelled')), isFalse);
      expect(Job.isInvoice(invoice(status: 'отменён')), isFalse);
      expect(Job.isInvoice(invoice()), isTrue);
    });
  });

  group('чем платили: депозит и остаток', () {
    test('первый платёж — депозит, закрывающий — остаток', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        payments: [
          {'amount': 50.0, 'method': 'Cash', 'date': '2026-09-01T10:00:00Z'},
          {
            'amount': 63.0,
            'method': 'e-Transfer',
            'date': '2026-09-02T10:00:00Z',
          },
        ],
      );

      final methods = Job.documentPayMethods(doc);
      expect(methods.deposit, 'Cash');
      expect(methods.balance, 'e-Transfer');
    });

    test('одна полная оплата — только остаток', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        payments: [
          {'amount': 113.0, 'method': 'Cash', 'date': '2026-09-01T10:00:00Z'},
        ],
      );

      final methods = Job.documentPayMethods(doc);
      expect(methods.deposit, '');
      expect(methods.balance, 'Cash');
    });

    test('чаевые не попадают ни в депозит, ни в остаток', () {
      final doc = invoice(
        items: [
          {'qty': 1, 'price': 100.0},
        ],
        payments: [
          {'amount': 113.0, 'method': 'Cash', 'date': '2026-09-01T10:00:00Z'},
          {'amount': 20.0, 'method': 'Tip', 'date': '2026-09-01T10:01:00Z'},
        ],
      );

      final methods = Job.documentPayMethods(doc);
      expect(methods.balance, 'Cash');
      expect(methods.deposit, isNot(contains('Tip')));
      expect(methods.balance, isNot(contains('Tip')));
    });

    test('названия способов приводятся к короткому виду', () {
      expect(Job.paymentMethodLabel('наличные'), 'Cash');
      expect(Job.paymentMethodLabel('Interac'), 'e-Transfer');
      expect(Job.paymentMethodLabel('Stripe (card present)'), 'Stripe (card)');
      expect(Job.paymentMethodLabel('Stripe (deposit)'), 'Stripe');
    });
  });

  group('итоги по заявке', () {
    Job jobWith(List<Map<String, dynamic>> documents) {
      return Job.fromMap({
        'clientName': 'Amelia',
        'documents': documents,
        'createdAt': '2026-09-01T10:00:00.000Z',
      }, 'job1');
    }

    test('смета в выручку не попадает', () {
      final job = jobWith([
        invoice(
          items: [
            {'qty': 1, 'price': 100.0},
          ],
        ),
        invoice(
          type: 'Estimate',
          items: [
            {'qty': 1, 'price': 900.0},
          ],
        ),
      ]);

      expect(job.invoicedTotal, closeTo(113.0, 0.001));
    });

    test('два счёта складываются, оплаты тоже', () {
      final job = jobWith([
        invoice(
          items: [
            {'qty': 1, 'price': 100.0},
          ],
          payments: [
            {'amount': 113.0, 'method': 'Cash'},
          ],
        ),
        invoice(
          items: [
            {'qty': 1, 'price': 200.0},
          ],
          payments: [
            {'amount': 100.0, 'method': 'Cash'},
          ],
        ),
      ]);

      expect(job.invoicedTotal, closeTo(339.0, 0.001));
      expect(job.paidTotal, closeTo(213.0, 0.001));
    });
  });

  group('статус оплаты заявки', () {
    test('без счетов — none', () {
      expect(JobService.paymentStatusOf(const []), 'none');
      expect(
        JobService.paymentStatusOf([invoice(type: 'Estimate')]),
        'none',
      );
    });

    test('оплачен полностью', () {
      expect(
        JobService.paymentStatusOf([
          invoice(
            items: [
              {'qty': 1, 'price': 100.0},
            ],
            payments: [
              {'amount': 113.0, 'method': 'Cash'},
            ],
          ),
        ]),
        'paid',
      );
    });

    test('оплачен частично', () {
      expect(
        JobService.paymentStatusOf([
          invoice(
            items: [
              {'qty': 1, 'price': 100.0},
            ],
            payments: [
              {'amount': 50.0, 'method': 'Cash'},
            ],
          ),
        ]),
        'partial',
      );
    });

    test('не оплачен', () {
      expect(
        JobService.paymentStatusOf([
          invoice(
            items: [
              {'qty': 1, 'price': 100.0},
            ],
          ),
        ]),
        'unpaid',
      );
    });

    test('удалённый счёт в статус не входит', () {
      expect(
        JobService.paymentStatusOf([
          invoice(
            items: [
              {'qty': 1, 'price': 100.0},
            ],
            deletedAt: '2026-09-21T10:00:00.000Z',
          ),
        ]),
        'none',
      );
    });
  });
}
