import 'package:flutter_test/flutter_test.dart';

import 'package:fix_appliance_crm/services/notification_router.dart';

/// Куда ведёт карточка уведомления.
///
/// Проверка нужна потому, что путь выбирался по длинной цепочке `if`, и
/// порядок в ней решал больше, чем тип уведомления: SMS, к которому сервер
/// успел привязать заявку, открывало карточку заявки — прочитать само
/// сообщение было негде. Payload'ы ниже — настоящие, из `functions`
/// (`notifyMaster`) и из `InboxPushMirror`.
void main() {
  NotificationTarget target(Map<String, dynamic> data) =>
      NotificationRouter.targetFor(data);

  group('звонок ведёт на разбор этого звонка', () {
    test('секретарь взял трубку: push с callSid', () {
      final result = target({
        'type': 'call',
        'kind': 'call_offer',
        'source': 'phone',
        'callSid': 'CA1',
        'peer': '+14165550199',
        'title': 'Входящий звонок',
      });
      expect(result.kind, NotificationTargetKind.call);
      expect(result.callId, 'CA1');
    });

    test('заявка с телефона всё равно открывает звонок, а не карточку', () {
      final result = target({
        'type': 'call',
        'kind': 'job',
        'callSid': 'CA2',
        'jobId': 'J1',
        'peer': '+14165550199',
      });
      expect(result.kind, NotificationTargetKind.call);
      expect(result.callId, 'CA2');
    });

    test('локальная карточка: id документа и SID лежат в разных ключах', () {
      final result = target({
        'type': 'call',
        'callSid': 'CA3',
        'callId': 'CA3',
        'from': '+14165550199',
      });
      expect(result.kind, NotificationTargetKind.call);
      expect(result.callId, 'CA3');
    });

    test('пропущенный без id звонка — ищем по номеру в open()', () {
      final result = target({'type': 'call', 'peer': '+14165550199'});
      expect(result.kind, NotificationTargetKind.call);
      expect(result.callId, isEmpty);
      expect(result.peer, '+14165550199');
    });

    test('разбор ошибки секретаря ведёт на тот же звонок', () {
      final result = target({'type': 'secretary_lesson', 'callSid': 'CA4'});
      expect(result.kind, NotificationTargetKind.call);
      expect(result.callId, 'CA4');
    });
  });

  group('сообщение ведёт в переписку, а не в заявку', () {
    test('SMS: открываем то сообщение, которое пришло', () {
      final result = target({
        'type': 'sms',
        'peer': '+14165550199',
        'messageId': 'SM1',
        'clientId': 'C1',
      });
      expect(result.kind, NotificationTargetKind.conversation);
      expect(result.messageId, 'SM1');
      expect(result.peer, '+14165550199');
      expect(result.emailChannel, isFalse);
    });

    test('«SMS не доставлено» приходит с jobId и всё равно ведёт в чат', () {
      final result = target({
        'type': 'sms',
        'peer': '+14165550199',
        'to': '+14165550199',
        'messageId': 'SM2',
        'jobId': 'J2',
        'smsFailed': '1',
      });
      expect(result.kind, NotificationTargetKind.conversation);
      expect(result.messageId, 'SM2');
    });

    test('письмо открывает почтовую ленту', () {
      final result = target({
        'type': 'email',
        'source': 'email',
        'peer': 'client@example.com',
        'messageId': 'EM1',
      });
      expect(result.kind, NotificationTargetKind.conversation);
      expect(result.emailChannel, isTrue);
      expect(result.messageId, 'EM1');
      expect(result.peer, 'client@example.com');
    });

    test('письмо о ремонте открывает само письмо с кнопками', () {
      final result = target({
        'type': 'email_offer',
        'peer': 'client@example.com',
        'messageId': 'EM2',
      });
      expect(result.kind, NotificationTargetKind.emailOffer);
      expect(result.messageId, 'EM2');
    });

    test('«Отправить / Не отправлять» — в переписку, не в заявку', () {
      final result = target({
        'type': 'outbox',
        'peer': '+14165550199',
        'jobId': 'J3',
        'messageId': 'SM3',
      });
      expect(result.kind, NotificationTargetKind.conversation);
      expect(result.emailChannel, isFalse);
      expect(result.messageId, 'SM3');
    });

    test('ответ на подтверждение визита без заявки — в переписку', () {
      final result = target({
        'type': 'visit_confirm',
        'peer': '+14165550199',
        'unmatched': '1',
      });
      expect(result.kind, NotificationTargetKind.conversation);
    });
  });

  group('заявка ведёт в карточку заявки', () {
    test('заявка с почты: адрес отправителя не уводит в переписку', () {
      final result = target({
        'type': 'job',
        'source': 'email',
        'jobId': 'J4',
        'messageId': 'EM3',
        'peer': 'client@example.com',
      });
      expect(result.kind, NotificationTargetKind.job);
      expect(result.jobId, 'J4');
    });

    test('заявка из SMS', () {
      final result = target({
        'type': 'job',
        'source': 'sms',
        'jobId': 'J5',
        'peer': '+14165550199',
      });
      expect(result.kind, NotificationTargetKind.job);
      expect(result.jobId, 'J5');
    });

    test('клиент подтвердил визит', () {
      final result = target({
        'type': 'visit_confirm',
        'jobId': 'J6',
        'peer': '+14165550199',
      });
      expect(result.kind, NotificationTargetKind.job);
    });

    test('посылка от поставщика', () {
      final result = target({
        'type': 'shipment',
        'jobId': 'J7',
        'trackingStatus': 'delivered',
      });
      expect(result.kind, NotificationTargetKind.job);
    });

    test('скоро визит', () {
      final result = target({
        'type': 'visit_soon',
        'jobId': 'J8',
        'visitId': 'V1',
      });
      expect(result.kind, NotificationTargetKind.job);
    });
  });

  group('остальное', () {
    test('утренний и вечерний список открывают календарь', () {
      expect(target({'type': 'morning'}).kind, NotificationTargetKind.tab);
      expect(target({'type': 'evening'}).kind, NotificationTargetKind.tab);
    });

    test('подсказки во время разговора ничего не открывают', () {
      for (final type in const ['active_call', 'on_the_way', 'leave_status']) {
        expect(
          target({'type': type, 'jobId': 'J9'}).kind,
          NotificationTargetKind.none,
          reason: type,
        );
      }
    });

    test('пустой payload', () {
      expect(target(const {}).kind, NotificationTargetKind.none);
    });

    test('карточка клиента — только когда тип не назван', () {
      expect(
        target({'peer': '+14165550199'}).kind,
        NotificationTargetKind.client,
      );
      expect(
        target({'type': 'client', 'peer': '+14165550199'}).kind,
        NotificationTargetKind.client,
      );
    });
  });
}
