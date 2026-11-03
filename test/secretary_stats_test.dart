import 'package:fix_appliance_crm/features/reports/secretary_stats.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Статистика секретаря: оценка расходов и что дали её звонки.
void main() {
  CallRecord call(
    String id, {
    int seconds = 0,
    String by = 'ai',
    String direction = 'inbound',
    String? engine,
    String? recordingUrl,
    String? jobId,
  }) {
    return CallRecord.fromMap({
      'durationSeconds': seconds,
      'answeredBy': by,
      'direction': direction,
      'status': 'completed',
      if (engine != null) 'aiReception': {'engine': engine},
      if (recordingUrl != null) 'recordingUrl': recordingUrl,
      if (jobId != null) 'createdJobId': jobId,
    }, id);
  }

  Job job(String id, {double paid = 0, String? sourceCallId}) {
    return Job.fromMap({
      'clientName': 'Will',
      'createdAt': '2026-10-01T10:00:00.000Z',
      if (sourceCallId != null) 'sourceCallId': sourceCallId,
      'documents': [
        {
          'type': 'Invoice',
          'items': [
            {'qty': 1, 'price': 200.0},
          ],
          'taxRate': 0.13,
          'payments': [
            if (paid > 0) {'amount': paid},
          ],
        },
      ],
    }, id);
  }

  group('оценка расходов', () {
    test('Twilio округляет звонок вверх до минуты', () {
      final cost = SecretaryCost.of([call('c1', seconds: 61, by: 'master')]);

      expect(cost.phone, closeTo(2 * SecretaryCost.twilioInboundPerMin, 1e-9));
      expect(cost.ai, 0);
    });

    test('звонок секретаря: медиапоток, голосовая модель и фоновая аналитика', () {
      final cost = SecretaryCost.of([call('c1', seconds: 120, engine: 'gemini-live')]);

      expect(
        cost.phone,
        closeTo(2 * (SecretaryCost.twilioInboundPerMin + SecretaryCost.mediaStreamPerMin), 1e-9),
      );
      expect(
        cost.ai,
        closeTo(2 * (SecretaryCost.geminiLivePerMin + SecretaryCost.analyticsPerMin), 1e-9),
      );
    });

    test('OpenAI дороже Gemini', () {
      final gemini = SecretaryCost.of([call('c1', seconds: 60, engine: 'gemini-live')]);
      final openAi = SecretaryCost.of([call('c2', seconds: 60, engine: 'openai-realtime')]);

      expect(openAi.ai, greaterThan(gemini.ai));
    });

    test('запись и расшифровка по двум дорожкам считаются отдельно, SMS тоже', () {
      final cost = SecretaryCost.of(
        [call('c1', seconds: 60, by: 'master', recordingUrl: 'https://api.twilio.com/r.mp3')],
        smsCount: 3,
      );

      expect(
        cost.recording,
        closeTo(SecretaryCost.recordingPerMin + SecretaryCost.transcriptionPerMin, 1e-9),
      );
      expect(cost.sms, closeTo(3 * SecretaryCost.smsEach, 1e-9));
      expect(cost.total, closeTo(cost.phone + cost.recording + cost.sms, 1e-9));
    });

    test('сорвавшийся звонок без минут ничего не стоит', () {
      expect(SecretaryCost.of([call('c1')]).total, 0);
    });
  });

  group('что дали звонки секретаря', () {
    test('заявка по ссылке со звонка и по звонку в заявке, оплата — только оплаченные', () {
      final funnel = SecretaryFunnel.of(
        [
          call('c1', jobId: 'j1'),
          call('c2'),
          call('c3'),
        ],
        [
          job('j1', paid: 226),
          job('j2', sourceCallId: 'c2'),
          job('j3'),
        ],
      );

      expect(funnel.calls, 3);
      expect(funnel.jobs, 2);
      expect(funnel.paidJobs, 1);
      expect(funnel.revenue, closeTo(226, 1e-9));
    });

    test('два звонка по одной заявке — одна заявка', () {
      final funnel = SecretaryFunnel.of(
        [call('c1', jobId: 'j1'), call('c2', jobId: 'j1')],
        [job('j1')],
      );

      expect(funnel.calls, 2);
      expect(funnel.jobs, 1);
    });
  });
}
