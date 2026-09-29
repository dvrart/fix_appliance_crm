import 'package:fix_appliance_crm/core/constants.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> invoice({
  double price = 300,
  List<Map<String, dynamic>> payments = const [],
  Map<String, dynamic>? stripe,
  String type = 'Invoice',
}) {
  return {
    'type': type,
    'items': [
      {'name': 'Repair', 'qty': 1, 'price': price},
    ],
    'payments': payments,
    if (stripe != null) 'stripe': stripe,
  };
}

void main() {
  group('Job.documentDepositTaken', () {
    test('частичная оплата наличными — это депозит', () {
      expect(
        Job.documentDepositTaken(
          invoice(payments: [
            {'amount': 100.0, 'method': 'Cash'},
          ]),
        ),
        isTrue,
      );
    });

    test('полная оплата депозитом не считается', () {
      expect(
        Job.documentDepositTaken(
          invoice(payments: [
            {'amount': 300.0, 'method': 'Cash'},
          ]),
        ),
        isFalse,
      );
    });

    test('выставленная ссылка Stripe без денег — не депозит', () {
      expect(
        Job.documentDepositTaken(
          invoice(stripe: {'mode': 'deposit', 'status': 'open'}),
        ),
        isFalse,
      );
    });

    test('частичный возврат по оплаченному счёту — не депозит', () {
      expect(
        Job.documentDepositTaken(
          invoice(payments: [
            {'amount': 300.0, 'method': 'Stripe'},
            {'amount': -200.0, 'method': 'Stripe (refund)'},
          ], stripe: {'status': 'partially_refunded'}),
        ),
        isFalse,
      );
    });

    test('смета депозитом не становится', () {
      expect(
        Job.documentDepositTaken(
          invoice(type: 'Estimate', payments: [
            {'amount': 100.0, 'method': 'Cash'},
          ]),
        ),
        isFalse,
      );
    });
  });

  group('JobStatuses.shouldMarkDeposit', () {
    test('обычная заявка получает «Депозит»', () {
      expect(JobStatuses.shouldMarkDeposit(JobStatuses.call), isTrue);
      expect(JobStatuses.shouldMarkDeposit(JobStatuses.rescheduled), isTrue);
    });

    test('«Ожидание запчасти» не трогаем — заявка остаётся в фургоне', () {
      expect(JobStatuses.shouldMarkDeposit(JobStatuses.waitingPart), isFalse);
    });

    test('закрытые заявки не поднимаем', () {
      for (final status in ['Завершено', 'Готово', 'Отменено', 'Canceled']) {
        expect(JobStatuses.shouldMarkDeposit(status), isFalse, reason: status);
      }
    });

    test('повторно статус не пишем', () {
      for (final status in ['Депозит', 'депозит', 'Взят депозит', 'Deposit']) {
        expect(JobStatuses.shouldMarkDeposit(status), isFalse, reason: status);
      }
    });
  });

  group('«Депозит» и автоперенос', () {
    test('новый визит не перетирает депозит статусом «Перенос»', () {
      expect(JobStatuses.canMarkRescheduled(JobStatuses.deposit), isFalse);
      expect(
        JobStatuses.shouldWriteRescheduled(JobStatuses.deposit, mark: true),
        isFalse,
      );
    });

    test('обычный статус переносится как раньше', () {
      expect(
        JobStatuses.shouldWriteRescheduled(JobStatuses.call, mark: true),
        isTrue,
      );
    });
  });
}
