import 'package:flutter_test/flutter_test.dart';

import 'package:fix_appliance_crm/services/notification_service.dart';

/// Карточка в шторке гаснет только тем же ключом, которым её нарисовали.
/// Ключ собирают два разных места — показ (`tagFor`) и снятие
/// (`inboxTagsFor`), — и пока они расходились, письмо с длинного адреса
/// висело в уведомлениях даже после прочтения: показывали хеш, а гасили
/// обрезанную строку.
void main() {
  void expectDismissed(
    Map<String, String> push,
    Map<String, dynamic> seen, {
    String? reason,
  }) {
    expect(
      NotificationService.inboxTagsFor(seen),
      contains(NotificationService.tagFor(push)),
      reason: reason,
    );
  }

  group('просмотренное уходит из шторки', () {
    test('SMS: номер в уведомлении и в переписке записан по-разному', () {
      expectDismissed(
        {'type': 'sms', 'peer': '+14165550199', 'messageId': 'm1'},
        {'type': 'sms', 'from': '(416) 555-0199'},
      );
    });

    test('звонок: карточку рисовали по номеру звонящего', () {
      expectDismissed(
        {'type': 'call', 'peer': '+14165550199', 'callSid': 'CA1'},
        {
          'type': 'call',
          'callId': 'CA1',
          'callSid': 'CA1',
          'from': '+1 416 555 0199',
        },
      );
    });

    test('звонок без номера — по id звонка', () {
      expectDismissed(
        {'type': 'call', 'callSid': 'CA0000000000000000000000000000001'},
        {'type': 'call', 'callSid': 'CA0000000000000000000000000000001'},
      );
    });

    test('заявка из колокольчика — по её id', () {
      expectDismissed(
        {'type': 'job', 'jobId': 'J1'},
        {'type': 'job', 'jobId': 'J1', 'from': ''},
      );
    });

    test('письмо с длинного адреса — тег хешируется одинаково', () {
      const address =
          'very.long.service.address.for.the.shop@someverylongdomainname.example.com';
      final tag = NotificationService.tagFor({'type': 'email', 'peer': address});
      expect(tag.length, lessThanOrEqualTo(50));
      expectDismissed(
        {'type': 'email', 'peer': address},
        {'type': 'email', 'from': address},
        reason: 'длинный адрес и показывают, и гасят по одному хешу',
      );
    });

    test('письмо: адрес в уведомлении с заглавными буквами', () {
      expectDismissed(
        {'type': 'email', 'peer': 'Client@Example.com'},
        {'type': 'email', 'from': 'client@example.com'},
      );
    });

    test('заявка с телефона гасит и карточку звонка, и свою', () {
      final tags = NotificationService.inboxTagsFor({
        'type': 'job',
        'jobId': 'J2',
        'from': '+14165550199',
        'callSid': 'CA2',
      });
      expect(
        tags,
        containsAll([
          NotificationService.tagFor({'type': 'call', 'peer': '+14165550199'}),
          NotificationService.tagFor({'type': 'call', 'callSid': 'CA2'}),
          NotificationService.tagFor({'type': 'job', 'jobId': 'J2'}),
        ]),
      );
    });

    test('чужая карточка не гаснет заодно', () {
      final tags = NotificationService.inboxTagsFor({
        'type': 'sms',
        'from': '+14165550199',
      });
      expect(
        tags,
        isNot(contains(NotificationService.tagFor({
          'type': 'sms',
          'peer': '+14165550100',
        }))),
      );
    });
  });
}
