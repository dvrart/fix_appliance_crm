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
      createdAt: DateTime(2026, 10, 11, 9),
    );
  }

  SmsMessage email({
    required String id,
    bool offerPending = false,
    bool bellPending = false,
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
  }) {
    return Job.fromMap({
      'clientName': 'Amelia',
      'applianceType': 'Washer',
      'status': status,
      'needsReview': needsReview,
      'intakeSource': 'phone',
      'createdAt': DateTime(2026, 10, 11, 7),
      if (deletedAt != null) 'deletedAt': deletedAt,
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
        jobs: [job(id: 'job-1')],
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

    test('просто непрочитанное письмо — это переписка, а не решение', () {
      final selection = InboxSelection.of(
        emailOffers: [
          email(id: 'M1', bellPending: true),
          email(id: 'M2', offerPending: true),
        ],
      );
      expect(selection.emailOffers.map((m) => m.id), ['M2']);
      expect(selection.decideCount, 1);
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
        awaitingSms: [
          sms(id: 'S1', direction: 'outbound', approval: 'pending'),
          sms(
            id: 'S2',
            direction: 'outbound',
            approval: 'pending',
            deletedAt: DateTime(2026, 10, 10),
          ),
        ],
        smsOffers: [sms(id: 'S3', smsOfferPending: true)],
        failedSms: [sms(id: 'S4', direction: 'outbound')],
      );
      expect(selection.awaiting.map((m) => m.id), ['S1']);
      expect(selection.decideCount, 2);
      expect(selection.attentionCount, 1);
    });

    test('группы складываются в общую цифру колокольчика', () {
      final selection = InboxSelection.of(
        awaitingSms: [
          sms(id: 'S1', direction: 'outbound', approval: 'pending'),
        ],
        smsOffers: [sms(id: 'S2', smsOfferPending: true)],
        emailOffers: [email(id: 'M1', offerPending: true)],
        failedSms: [sms(id: 'S3', direction: 'outbound')],
        calls: [call(id: 'CA1')],
        jobs: [job(id: 'job-1')],
      );
      expect(selection.decideCount, 3);
      expect(selection.attentionCount, 2);
      expect(selection.confirmCount, 1);
      expect(selection.total, 6);
      expect(selection.isEmpty, isFalse);
    });
  });
}
