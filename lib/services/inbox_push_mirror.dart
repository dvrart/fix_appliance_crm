import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/job.dart';
import 'job_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Новая карточка в колокольчике рисует шторку, пока приложение открыто.
/// Закрытое приложение будит FCM (системная шторка + нативный сервис).
/// Первый снимок потока только запоминает уже виденные id — иначе при
/// открытии снова сыпятся уведомления за полдня.
class InboxPushMirror {
  static const _prefKey = 'inbox_push_shown_ids';
  static bool _started = false;
  static bool _ready = false;
  static final Set<String> _shown = {};
  static final Set<String> _primed = {};

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    _shown.addAll(prefs.getStringList(_prefKey) ?? const []);
    _ready = true;
    SmsService.streamEmailOffers().listen((items) => _onEmails(items));
    SmsService.streamAll().listen((items) => _onSms(items));
    TwilioService.getPendingReviewCalls()
        .listen((items) => _onCalls(items, 'calls_review'));
    TwilioService.getAiProcessingCalls()
        .listen((items) => _onCalls(items, 'calls_ai'));
    JobService.streamNeedsReview().listen(_onJobs);
  }

  static Future<void> markShown(String key) async {
    if (key.trim().isEmpty || !_shown.add(key)) return;
    if (_shown.length > 400) {
      final keep = _shown.toList().sublist(_shown.length - 300);
      _shown
        ..clear()
        ..addAll(keep);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, _shown.toList());
  }

  static bool alreadyShown(String key) => _shown.contains(key);

  static void _onEmails(List<SmsMessage> items) {
    _emitNew(
      streamId: 'email',
      items: items,
      keyOf: (item) => 'email:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyEmail,
    );
  }

  static void _onSms(List<SmsMessage> items) {
    _emitNew(
      streamId: 'sms',
      items: items.where((item) {
        if (item.isOutbound || item.isEmail) return false;
        if (item.aiStatus == 'skipped_confirm') return false;
        return true;
      }),
      keyOf: (item) => 'sms:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifySms,
    );
  }

  static void _onCalls(List<CallRecord> items, String streamId) {
    _emitNew(
      streamId: streamId,
      items: items.where((item) => !item.reviewed && !item.isDeleted),
      keyOf: (item) => 'call:${item.id}',
      createdOf: (item) => item.startTime,
      notify: _notifyCall,
    );
  }

  static void _onJobs(List<Job> items) {
    _emitNew(
      streamId: 'jobs',
      items: items.where((item) => !item.isDeleted && item.needsReview),
      keyOf: (item) => 'job:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyJob,
    );
  }

  static void _emitNew<T>({
    required String streamId,
    required Iterable<T> items,
    required String Function(T item) keyOf,
    required DateTime? Function(T item) createdOf,
    required void Function(T item) notify,
  }) {
    if (!_ready) return;
    final list = items.toList();
    // Первый снимок — только запомнить уже существующие карточки. Иначе
    // при каждом открытии приложения сыпятся шторки за последние 6 часов,
    // хотя push уже должен был прийти в фоне.
    if (!_primed.contains(streamId)) {
      if (list.isEmpty) return;
      _primed.add(streamId);
      for (final item in list) {
        unawaited(markShown(keyOf(item)));
      }
      return;
    }
    final cutoff = DateTime.now().subtract(const Duration(hours: 6));
    for (final item in list) {
      final key = keyOf(item);
      if (alreadyShown(key)) continue;
      final created = createdOf(item);
      if (created != null && created.isBefore(cutoff)) {
        unawaited(markShown(key));
        continue;
      }
      unawaited(markShown(key));
      notify(item);
    }
  }

  static void _notifyEmail(SmsMessage message) {
    final from = message.counterpartEmail.isNotEmpty
        ? message.counterpartEmail
        : message.from;
    final who = message.isWebsiteFormMail
        ? kWebsiteInboxTitle
        : (from.isEmpty ? 'клиент' : from);
    unawaited(
      NotificationService.showRemoteData({
        'type': message.emailOfferPending || message.emailIntake
            ? 'email_offer'
            : 'email',
        'source': 'email',
        'from': from,
        'messageId': message.id,
        'title': message.emailOfferPending || message.applianceRepair
            ? 'Письмо о ремонте'
            : 'Письмо от $who',
        'body': message.subject.trim().isNotEmpty
            ? message.subject
            : message.displayBody,
      }),
    );
  }

  static void _notifySms(SmsMessage message) {
    unawaited(
      NotificationService.showRemoteData({
        'type': 'sms',
        'from': message.from,
        'messageId': message.id,
        'title': 'SMS от ${message.from}',
        'body': message.displayBody.trim().isEmpty
            ? 'Фото или вложение'
            : message.displayBody,
      }),
    );
  }

  static void _notifyCall(CallRecord call) {
    if ((call.createdJobId ?? '').trim().isNotEmpty) return;
    final phone = call.isIncoming ? call.fromNumber : call.toNumber;
    final title = call.serviceDeclined
        ? 'Звонок: заявку не создаём'
        : (call.answeredByAi ? 'ИИ взял звонок' : 'Входящий звонок');
    unawaited(
      NotificationService.showRemoteData({
        'type': 'call',
        'from': phone,
        'callSid': call.callSid.isNotEmpty ? call.callSid : call.id,
        'callId': call.id,
        'title': title,
        'body': phone,
      }),
    );
  }

  static void _notifyJob(Job job) {
    final source = job.intakeSource;
    final from = source == 'email'
        ? job.sourceEmailFrom
        : (job.clientPhone.trim().isNotEmpty
            ? job.clientPhone
            : job.contactName);
    unawaited(
      NotificationService.showRemoteData({
        'type': 'job',
        'source': source == 'email' || source == 'website' ? 'email' : 'phone',
        'from': from,
        'jobId': job.id,
        'title': source == 'email' || source == 'website'
            ? 'Заявка с почты'
            : (source == 'sms' ? 'Заявка из SMS' : 'Заявка с телефона'),
        'body': [
          job.contactName,
          job.applianceType,
        ].where((part) => part.trim().isNotEmpty).join(' · '),
        'applianceType': job.applianceType,
        'clientName': job.contactName,
        'city': job.displayCity,
      }),
    );
  }
}
