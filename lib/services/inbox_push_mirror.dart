import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/job.dart';
import 'job_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Новая карточка в колокольчике сразу рисует шторку — и когда приложение
/// уже открыто, и когда его только что открыли после звонка / письма.
class InboxPushMirror {
  static const _prefKey = 'inbox_push_shown_ids';
  static bool _started = false;
  static bool _ready = false;
  static final Set<String> _shown = {};

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    _shown.addAll(prefs.getStringList(_prefKey) ?? const []);
    _ready = true;
    SmsService.streamEmailOffers().listen(_onEmails);
    SmsService.streamAll().listen(_onSms);
    TwilioService.getPendingReviewCalls()
        .listen((items) => _onCalls(items));
    TwilioService.getAiProcessingCalls()
        .listen((items) => _onCalls(items));
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
      items: items,
      keyOf: (item) => 'email:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyEmail,
    );
  }

  static void _onSms(List<SmsMessage> items) {
    _emitNew(
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

  static void _onCalls(List<CallRecord> items) {
    _emitNew(
      items: items.where((item) => !item.reviewed && !item.isDeleted),
      keyOf: (item) => 'call:${item.id}',
      createdOf: (item) => item.startTime,
      notify: _notifyCall,
    );
  }

  static void _onJobs(List<Job> items) {
    _emitNew(
      items: items.where((item) => !item.isDeleted && item.needsReview),
      keyOf: (item) => 'job:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyJob,
    );
  }

  static void _emitNew<T>({
    required Iterable<T> items,
    required String Function(T item) keyOf,
    required DateTime? Function(T item) createdOf,
    required void Function(T item) notify,
  }) {
    if (!_ready) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 6));
    for (final item in items) {
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
      }),
    );
  }
}
