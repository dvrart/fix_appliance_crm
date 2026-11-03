import '../../models/job.dart';
import '../../services/twilio_service.dart';

/// Грубая оценка расходов на звонки и SMS, в долларах США.
///
/// Тарифы — прайсы Twilio, Google и OpenAI на ноябрь 2026. Twilio округляет
/// каждый звонок вверх до минуты, поэтому минуты считаются по звонку.
class SecretaryCost {
  static const twilioInboundPerMin = 0.0085;
  static const twilioOutboundPerMin = 0.014;
  static const mediaStreamPerMin = 0.0044;
  static const geminiLivePerMin = 0.02;
  static const openAiRealtimePerMin = 0.06;
  static const analyticsPerMin = 0.002;
  static const recordingPerMin = 0.0025;

  /// Whisper разбирает запись по двум дорожкам — минута звонка стоит дважды.
  static const transcriptionPerMin = 2 * 0.006;
  static const smsEach = 0.0079;

  final double phone;
  final double ai;
  final double recording;
  final double sms;

  const SecretaryCost({
    this.phone = 0,
    this.ai = 0,
    this.recording = 0,
    this.sms = 0,
  });

  double get total => phone + ai + recording + sms;

  static bool answeredByAi(CallRecord call) {
    final by = call.answeredBy.toLowerCase();
    return by == 'ai' || by == 'secretary';
  }

  static SecretaryCost of(Iterable<CallRecord> calls, {int smsCount = 0}) {
    var phone = 0.0;
    var ai = 0.0;
    var recording = 0.0;
    for (final call in calls) {
      final secs = call.durationSeconds ?? 0;
      if (secs <= 0) continue;
      final minutes = (secs / 60).ceil();
      phone += minutes *
          (call.isIncoming ? twilioInboundPerMin : twilioOutboundPerMin);
      if (answeredByAi(call)) {
        final openAi = call.aiReception?['engine'] == 'openai-realtime';
        phone += minutes * mediaStreamPerMin;
        ai += minutes *
            ((openAi ? openAiRealtimePerMin : geminiLivePerMin) +
                analyticsPerMin);
      }
      if (call.hasRecording) {
        recording += minutes * (recordingPerMin + transcriptionPerMin);
      }
    }
    return SecretaryCost(
      phone: phone,
      ai: ai,
      recording: recording,
      sms: smsCount * smsEach,
    );
  }
}

/// Что дали звонки, которые приняла секретарь: заявки и оплаты по ним.
class SecretaryFunnel {
  final int calls;
  final int jobs;
  final int paidJobs;
  final double revenue;

  const SecretaryFunnel({
    this.calls = 0,
    this.jobs = 0,
    this.paidJobs = 0,
    this.revenue = 0,
  });

  /// Звонок связан с заявкой, если на звонке записана заявка или в заявке —
  /// звонок, из которого её завели.
  static SecretaryFunnel of(Iterable<CallRecord> aiCalls, Iterable<Job> jobs) {
    final byId = {for (final job in jobs) job.id: job};
    final bySourceCall = {
      for (final job in jobs)
        if ((job.sourceCallId ?? '').trim().isNotEmpty)
          job.sourceCallId!.trim(): job,
    };
    final linked = <String, Job>{};
    var calls = 0;
    for (final call in aiCalls) {
      calls++;
      final job = byId[(call.createdJobId ?? '').trim()] ??
          bySourceCall[call.id] ??
          bySourceCall[call.callSid];
      if (job != null) linked[job.id] = job;
    }
    final paid = linked.values.where((job) => job.paidTotal > 0.009).toList();
    return SecretaryFunnel(
      calls: calls,
      jobs: linked.length,
      paidJobs: paid.length,
      revenue: paid.fold(0.0, (sum, job) => sum + job.paidTotal),
    );
  }
}
