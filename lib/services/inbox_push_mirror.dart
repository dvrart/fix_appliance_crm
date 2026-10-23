import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/job.dart';
import 'auth_service.dart';
import 'job_service.dart';
import 'local_notification_service.dart';
import 'network_status_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Новая карточка в колокольчике рисует шторку, пока приложение открыто.
/// Закрытое приложение будит FCM (системная шторка + нативный сервис).
/// Первый снимок потока только запоминает уже виденные id — иначе при
/// открытии снова сыпятся уведомления за полдня.
///
/// Он же убирает карточки обратно. Гасить их по месту — в переписке, в
/// списке звонков, в колокольчике — приходится в десятке мест, и каждое
/// новое легко забыть; к тому же прочитать письмо или открыть звонок
/// можно было и на другом устройстве. Поэтому последнее слово за сверкой
/// [sweep]: что висит в шторке, но ничему не соответствует — снимается.
class InboxPushMirror {
  static const _prefKey = 'inbox_push_shown_ids';

  /// Карточку снимаем не в тот же миг, как она «осиротела»: push почти
  /// всегда приходит раньше, чем Firestore присылает сам документ, и
  /// иначе свежее SMS гасило бы само себя.
  static const _sweepGrace = Duration(seconds: 8);
  static const _liveStreams = {
    'sms',
    'email',
    'sms_offers',
    'calls',
    'jobs',
  };

  static bool _started = false;
  static bool _ready = false;
  static final Set<String> _shown = {};
  static final Set<String> _primed = {};
  static final List<StreamSubscription<dynamic>> _subscriptions = [];
  static int _generation = 0;
  static Timer? _retry;

  /// Что действительно ждёт разбора: поток → теги его карточек.
  static final Map<String, Set<String>> _live = {};
  static final Map<String, DateTime> _staleSince = {};
  static Timer? _sweepTimer;

  static Future<void> start() async {
    if (_started || !AuthService.signedIn) return;
    _started = true;
    final generation = ++_generation;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_started || generation != _generation) return;
      _shown.addAll(prefs.getStringList(_prefKey) ?? const []);
      _ready = true;
      _subscriptions.addAll([
        SmsService.streamEmailOffers().listen(_onEmails, onError: _onError),
        SmsService.streamAll().listen(_onSms, onError: _onError),
        SmsService.streamSmsOffers().listen(_onSmsOffers, onError: _onError),
        TwilioService.getPendingReviewCalls().listen(
          (items) => _onCalls(items, 'calls_review'),
          onError: _onError,
        ),
        // Звонок считается новым, пока его не открыли, — независимо от
        // того, успел ли ИИ разобрать запись. По «готовым» карточку не
        // сверить: сразу после звонка её ещё нет в том потоке.
        TwilioService.streamNewIncomingCalls().listen(
          (items) => _setLive('calls', items.expand(_callTags)),
          onError: _onError,
        ),
        JobService.streamNeedsReview().listen(_onJobs, onError: _onError),
      ]);
    } catch (error) {
      _onError(error);
    }
  }

  static void stop() {
    _generation++;
    _started = false;
    _ready = false;
    _primed.clear();
    _retry?.cancel();
    _sweepTimer?.cancel();
    _live.clear();
    _staleSince.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  static void _onError(Object error) {
    debugPrint('InboxPushMirror: $error');
    stop();
    if (AuthService.signedIn) {
      _retry = Timer(const Duration(seconds: 15), () => unawaited(start()));
    }
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
    _setLive('email', items.expand(_messageTags));
    _emitNew(
      streamId: 'email',
      items: items,
      keyOf: (item) => 'email:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyEmail,
    );
  }

  static void _onSms(List<SmsMessage> items) {
    _setLive(
      'sms',
      items
          .where((item) => !item.isOutbound && !item.read && !item.isDeleted)
          .expand(_messageTags),
    );
    _emitNew(
      streamId: 'sms',
      items: items.where((item) {
        if (item.isOutbound || item.isEmail || item.read || item.isDeleted) {
          return false;
        }
        if (item.aiStatus == 'skipped_confirm' || item.aiStatus == 'processing') {
          return false;
        }
        return true;
      }),
      keyOf: (item) => 'sms:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifySms,
    );
  }

  static void _onSmsOffers(List<SmsMessage> items) {
    _setLive('sms_offers', items.expand(_messageTags));
    _emitNew(
      streamId: 'sms_offers',
      items: items,
      keyOf: (item) => 'sms:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifySmsOffer,
    );
  }

  static void _onCalls(List<CallRecord> items, String streamId) {
    _emitNew(
      streamId: streamId,
      items: items.where(
        (item) =>
            item.isIncoming &&
            !item.reviewed &&
            !item.isDeleted &&
            ![
              'ringing',
              'in-progress',
              'queued',
              'initiated',
            ].contains(item.status),
      ),
      keyOf: (item) => 'call:${item.id}',
      createdOf: (item) => item.startTime,
      notify: _notifyCall,
    );
  }

  static void _onJobs(List<Job> items) {
    final live = items.where((item) => !item.isDeleted && item.needsReview);
    _setLive('jobs', live.expand(_jobTags));
    _emitNew(
      streamId: 'jobs',
      items: live,
      keyOf: (item) => 'job:${item.id}',
      createdOf: (item) => item.createdAt,
      notify: _notifyJob,
    );
  }

  // ─── Сверка шторки с тем, что ещё не разобрано ──────────────────────────

  static void _setLive(String streamId, Iterable<String> tags) {
    _live[streamId] = {
      for (final tag in tags)
        if (tag.trim().isNotEmpty) tag.trim(),
    };
    _scheduleSweep(const Duration(seconds: 1));
  }

  static void _scheduleSweep(Duration delay) {
    if (!_started) return;
    _sweepTimer?.cancel();
    _sweepTimer = Timer(delay, () => unawaited(sweep()));
  }

  /// Снять из шторки карточки входящих, за которыми уже ничего не стоит:
  /// сообщение прочитано, звонок открыт, заявка разобрана или удалена.
  static Future<void> sweep() async {
    _sweepTimer?.cancel();
    if (!_started || !AuthService.signedIn) return;
    // Пока не слышали каждый поток, судить о «лишнем» не по чему.
    if (!_liveStreams.every(_live.containsKey)) return;
    // Без сети Firestore отстаёт от push: карточку о только что пришедшем
    // сообщении подкрепить нечем, а снимать её нельзя.
    if (NetworkStatusService.offline.value) {
      _staleSince.clear();
      return;
    }
    final want = <String>{for (final tags in _live.values) ...tags};
    final active = await LocalNotificationService.activeInboxTags();
    if (!_started) return;
    _staleSince.removeWhere(
      (tag, _) => want.contains(tag) || !active.contains(tag),
    );
    final now = DateTime.now();
    final drop = <String>{};
    for (final tag in active) {
      // Трогаем только карточки событий. Образец уведомления из настроек
      // и всё чужое на этих каналах должно спокойно висеть, пока его не
      // смахнут рукой.
      if (!tag.startsWith('crm_')) continue;
      if (want.contains(tag)) continue;
      final since = _staleSince[tag];
      if (since == null) {
        _staleSince[tag] = now;
      } else if (now.difference(since) >= _sweepGrace) {
        drop.add(tag);
      }
    }
    if (drop.isNotEmpty) {
      _staleSince.removeWhere((tag, _) => drop.contains(tag));
      await LocalNotificationService.cancelTags(drop);
    }
    if (_staleSince.isNotEmpty) _scheduleSweep(_sweepGrace);
  }

  static Iterable<String> _messageTags(SmsMessage message) {
    final type = message.isEmail ? 'email' : 'sms';
    final email = message.counterpartEmail;
    final phone = message.isOutbound ? message.to : message.from;
    return {
      if (email.isNotEmpty)
        NotificationService.shadeTag(
          type: 'email',
          from: email,
          messageId: message.id,
        ),
      if (phone.trim().isNotEmpty)
        NotificationService.shadeTag(
          type: type,
          from: phone,
          messageId: message.id,
        ),
      NotificationService.shadeTag(type: type, messageId: message.id),
    };
  }

  static Iterable<String> _callTags(CallRecord call) {
    final phone = call.isIncoming ? call.fromNumber : call.toNumber;
    final sid = call.callSid.isNotEmpty ? call.callSid : call.id;
    return {
      if (phone.trim().isNotEmpty)
        NotificationService.shadeTag(type: 'call', from: phone, callSid: sid),
      NotificationService.shadeTag(type: 'call', callSid: sid),
      NotificationService.shadeTag(type: 'call', callSid: call.id),
    };
  }

  static Iterable<String> _jobTags(Job job) {
    final from = job.intakeSource == 'email'
        ? job.sourceEmailFrom
        : job.clientPhone;
    final callId = (job.sourceCallId ?? '').trim();
    final emailId = (job.sourceEmailId ?? '').trim();
    return {
      if (from.trim().isNotEmpty)
        NotificationService.shadeTag(type: 'job', from: from, jobId: job.id),
      NotificationService.shadeTag(type: 'job', jobId: job.id),
      if (callId.isNotEmpty)
        NotificationService.shadeTag(type: 'call', callSid: callId),
      if (emailId.isNotEmpty)
        NotificationService.shadeTag(type: 'email', messageId: emailId),
    };
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

  static void _notifySmsOffer(SmsMessage message) {
    final extracted = message.extractedData;
    final appliance = extracted != null
        ? (extracted['appliance_type'] ?? '').toString().trim()
        : '';
    final body = [
      message.from,
      if (appliance.isNotEmpty) appliance,
      if (appliance.isEmpty)
        message.displayBody.trim().isNotEmpty
            ? message.displayBody.trim()
            : 'SMS о ремонте',
    ].where((s) => s.isNotEmpty).join(' · ');
    unawaited(
      NotificationService.showRemoteData({
        'type': 'sms',
        'source': 'sms',
        'from': message.from,
        'messageId': message.id,
        'title': 'SMS: ждёт заявку',
        'body': body,
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
        'source': source == 'email' || source == 'website' ? 'email' : source,
        'from': from,
        'jobId': job.id,
        'callSid': job.sourceCallId ?? '',
        'messageId': job.sourceEmailId ?? '',
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
