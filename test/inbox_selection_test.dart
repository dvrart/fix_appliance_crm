import 'package:fix_appliance_crm/core/constants.dart';
import 'package:fix_appliance_crm/features/ai/assistant/review_bell_button.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/sms_service.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Колокольчик считает решения, а не события. Эти проверки держат
/// цифру честной: пока в неё складывали всё подряд, она не доходила до
/// нуля и на неё перестали смотреть.
void main() {
  SmsMessage sms({
    required String id,
    String direction = 'inbound',
    String body = 'Текст',
    bool smsOfferPending = false,
    String approval = '',
    DateTime? deletedAt,
    bool read = true,
  }) {
    return SmsMessage(
      id: id,
      sid: id,
      from: '+14165550101',
      to: '+16471234567',
      body: body,
      direction: direction,
      smsOfferPending: smsOfferPending,
      approval: approval,
      deletedAt: deletedAt,
      read: read,
      createdAt: DateTime(2026, 10, 11, 9),
    );
  }

  SmsMessage email({
    required String id,
    bool offerPending = false,
    bool bellPending = false,
    bool read = true,
  }) {
    return SmsMessage(
      id: id,
      sid: id,
      from: 'client@example.com',
      to: 'shop@example.com',
      body: 'My washer leaks',
      direction: 'inbound',
      channel: 'email',
      fromEmail: 'client@example.com',
      crmThread: true,
      emailOfferPending: offerPending,
      emailBellPending: bellPending,
      read: read,
      createdAt: DateTime(2026, 10, 11, 10),
    );
  }

  CallRecord call({
    required String id,
    String? createdJobId,
    bool reviewed = false,
    DateTime? deletedAt,
    String status = 'completed',
  }) {
    return CallRecord(
      id: id,
      callSid: id,
      fromNumber: '+14165550101',
      toNumber: '+16471234567',
      direction: 'inbound',
      status: status,
      startTime: DateTime(2026, 10, 11, 8),
      createdJobId: createdJobId,
      reviewed: reviewed,
      deletedAt: deletedAt,
      answeredBy: 'ai',
    );
  }

  Job job({
    required String id,
    bool needsReview = true,
    String status = JobStatuses.call,
    DateTime? deletedAt,
    DateTime? visitAt,
  }) {
    return Job.fromMap({
      'clientName': 'Amelia',
      'applianceType': 'Washer',
      'status': status,
      'needsReview': needsReview,
      'intakeSource': 'phone',
      'createdAt': DateTime(2026, 10, 11, 7),
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (visitAt != null)
        'visits': [
          {
            'id': 'v-$id',
            'startAt': visitAt,
            'durationMinutes': 60,
            'outcome': JobVisit.scheduled,
          },
        ],
    }, id);
  }

  group('что попадает в колокольчик', () {
    test('пустой отбор даёт ноль — до него теперь можно дойти', () {
      const empty = InboxSelection();
      expect(empty.total, 0);
      expect(empty.isEmpty, isTrue);
    });

    test('звонок с заявкой не дублируется: решение принимают по заявке', () {
      final selection = InboxSelection.of(
        calls: [
          call(id: 'CA1'),
          call(id: 'CA2', createdJobId: 'job-1'),
        ],
        jobs: [job(id: 'job-1', visitAt: DateTime(2026, 10, 15, 10))],
        now: DateTime(2026, 10, 11, 12),
      );
      expect(selection.calls.map((c) => c.id), ['CA1']);
      expect(selection.jobs.map((j) => j.id), ['job-1']);
      expect(selection.total, 2);
    });

    test('разобранный и удалённый звонки не считаются', () {
      final selection = InboxSelection.of(
        calls: [
          call(id: 'CA1', reviewed: true),
          call(id: 'CA2', deletedAt: DateTime(2026, 10, 10)),
          call(id: 'CA3'),
          call(id: 'CA3'),
        ],
      );
      expect(selection.calls.map((c) => c.id), ['CA3']);
      expect(selection.attentionCount, 1);
    });

    // Колокольчик больше не предлагает завести заявку: письмо и SMS,
    // похожие на вызов мастера, идут обычной строкой «пришло письмо».
    // Заявку мастер создаёт сам — из звонка или руками.
    test('письмо-заявка стоит в переписке, а не в отдельном предложении', () {
      final selection = InboxSelection.of(
        unreadMessages: [
          email(id: 'M1', bellPending: true, read: false),
          email(id: 'M2', offerPending: true, read: false),
        ],
      );
      expect(selection.messages.map((m) => m.id), ['M1', 'M2']);
      expect(selection.attentionCount, 2);
    });

    test('заявка ждёт подтверждения, пока она живая и не закрыта', () {
      final selection = InboxSelection.of(
        jobs: [
          job(id: 'job-1'),
          job(id: 'job-2', needsReview: false),
          job(id: 'job-3', status: JobStatuses.completed),
          job(id: 'job-4', status: JobStatuses.cancelled),
          job(id: 'job-5', deletedAt: DateTime(2026, 10, 10)),
          job(id: 'job-1'),
        ],
      );
      expect(selection.jobs.map((j) => j.id), ['job-1']);
      expect(selection.confirmCount, 1);
    });

    test('удалённые сообщения не держат счётчик', () {
      final selection = InboxSelection.of(
        unreadMessages: [
          sms(id: 'S1', read: false),
          sms(id: 'S2', read: false, deletedAt: DateTime(2026, 10, 10)),
        ],
        failedSms: [
          sms(id: 'S3', direction: 'outbound'),
          sms(
            id: 'S4',
            direction: 'outbound',
            deletedAt: DateTime(2026, 10, 10),
          ),
        ],
      );
      expect(selection.messages.map((m) => m.id), ['S1']);
      expect(selection.failedSms.map((m) => m.id), ['S3']);
      expect(selection.attentionCount, 2);
    });

    test('группы складываются в общую цифру колокольчика', () {
      final selection = InboxSelection.of(
        unreadMessages: [
          sms(id: 'S1', read: false),
          email(id: 'M1', offerPending: true, read: false),
        ],
        failedSms: [sms(id: 'S3', direction: 'outbound')],
        calls: [call(id: 'CA1')],
        jobs: [job(id: 'job-1', visitAt: DateTime(2026, 10, 15, 10))],
        now: DateTime(2026, 10, 11, 12),
      );
      expect(selection.attentionCount, 4);
      expect(selection.confirmCount, 1);
      expect(selection.total, 5);
      expect(selection.isEmpty, isFalse);
    });

    test('непрочитанные входящие сообщения попадают в список уведомлений', () {
      final unreadSms = SmsMessage(
        id: 'U1',
        sid: 'U1',
        from: '+14165550101',
        to: '+16471234567',
        body: 'I am home now',
        direction: 'inbound',
        read: false,
        createdAt: DateTime(2026, 10, 11, 11),
      );
      final selection = InboxSelection.of(
        unreadMessages: [unreadSms],
      );
      expect(selection.messages.map((m) => m.id), ['U1']);
      expect(selection.attentionCount, 1);
      expect(selection.total, 1);
    });

    test('сообщение и звонок находят привязанную рабочую карточку', () {
      final activeJob = Job.fromMap({
        'clientId': 'client-1',
        'clientName': 'Amelia',
        'clientPhone': '+1 (416) 555-0101',
        'applianceType': 'Washer',
        'status': JobStatuses.call,
        'needsReview': false,
        'createdAt': DateTime(2026, 10, 10, 12),
      }, 'job-active');
      final closedJob = Job.fromMap({
        'clientId': 'client-1',
        'clientName': 'Amelia',
        'clientPhone': '+1 (416) 555-0101',
        'applianceType': 'Dryer',
        'status': JobStatuses.completed,
        'needsReview': false,
        'createdAt': DateTime(2026, 10, 11, 12),
      }, 'job-closed');

      final unreadSms = SmsMessage(
        id: 'U1',
        sid: 'U1',
        from: '4165550101',
        to: '+16471234567',
        body: 'Did the part arrive?',
        direction: 'inbound',
        read: false,
        createdAt: DateTime(2026, 10, 11, 14),
      );
      final incomingCall = call(id: 'CA-active');

      final selection = InboxSelection.of(
        jobs: [closedJob, activeJob],
        unreadMessages: [unreadSms],
        calls: [incomingCall],
      );

      expect(selection.jobForMessage(unreadSms)?.id, 'job-active');
      expect(selection.jobForCall(incomingCall)?.id, 'job-active');
    });
  });

  /// Машинка доставки и плашка «N без даты визита» уехали из шапки
  /// календаря в колокольчик, а рядом с ними встало напоминание о скором
  /// визите. Эти проверки держат отбор: цифра на колокольчике теперь
  /// отвечает и за них.
  group('визиты и доставка', () {
    final now = DateTime(2026, 10, 11, 12);

    test('заявка без даты визита попадает в колокольчик один раз', () {
      final selection = InboxSelection.of(
        jobs: [
          job(id: 'job-1', needsReview: false),
          job(id: 'job-2', needsReview: false, visitAt: DateTime(2026, 10, 20)),
        ],
        now: now,
      );
      expect(selection.unscheduled.map((j) => j.id), ['job-1']);
      expect(selection.visitsCount, 1);
      expect(selection.total, 1);
    });

    test('закрытая и удалённая заявки без даты не считаются', () {
      final selection = InboxSelection.of(
        jobs: [
          job(id: 'job-1', needsReview: false, status: JobStatuses.completed),
          job(id: 'job-2', needsReview: false, status: JobStatuses.cancelled),
          job(
            id: 'job-3',
            needsReview: false,
            deletedAt: DateTime(2026, 10, 10),
          ),
        ],
        now: now,
      );
      expect(selection.unscheduled, isEmpty);
      expect(selection.total, 0);
    });

    test('ожидание запчасти — это строка доставки', () {
      final selection = InboxSelection.of(
        jobs: [
          job(
            id: 'job-1',
            needsReview: false,
            status: JobStatuses.waitingPart,
            visitAt: DateTime(2026, 10, 20),
          ),
        ],
        now: now,
      );
      expect(selection.delivery.map((j) => j.id), ['job-1']);
      expect(selection.unscheduled, isEmpty);
      expect(selection.visitsCount, 1);
    });

    test('напоминают только о ближайших двух часах и только вперёд', () {
      final selection = InboxSelection.of(
        jobs: [
          job(id: 'soon', needsReview: false, visitAt: DateTime(2026, 10, 11, 13)),
          job(id: 'later', needsReview: false, visitAt: DateTime(2026, 10, 11, 17)),
          job(id: 'past', needsReview: false, visitAt: DateTime(2026, 10, 11, 9)),
        ],
        now: now,
      );
      expect(selection.soonVisits.map((s) => s.job.id), ['soon']);
      expect(selection.visitsCount, 1);
    });

    test('отменённый визит не напоминает о себе', () {
      final cancelled = Job.fromMap({
        'clientName': 'Amelia',
        'status': JobStatuses.call,
        'needsReview': false,
        'createdAt': DateTime(2026, 10, 11, 7),
        'visits': [
          {
            'id': 'v1',
            'startAt': DateTime(2026, 10, 11, 13),
            'durationMinutes': 60,
            'outcome': JobVisit.cancelled,
          },
        ],
      }, 'job-1');
      final selection = InboxSelection.of(jobs: [cancelled], now: now);
      expect(selection.soonVisits, isEmpty);
    });
  });
}
