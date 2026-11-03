import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/app_commands.dart';
import '../features/calls/call_review_page.dart';
import '../features/clients/client_details_screen.dart';
import '../features/jobs/email_offer_page.dart';
import '../features/jobs/job_details/job_details_screen.dart';
import '../features/messages/conversation_screen.dart';
import '../models/client.dart';
import '../shared/app_nav.dart';
import 'app_lock_service.dart';
import 'auth_service.dart';
import 'client_service.dart';
import 'job_reminder_service.dart';
import 'job_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Куда ведёт уведомление.
enum NotificationTargetKind {
  /// Открывать нечего: хватает того, что приложение вышло на экран.
  none,

  /// Вкладка нижнего меню (утренний и вечерний список заявок).
  tab,

  /// Разбор конкретного звонка.
  call,

  /// Письмо о ремонте с кнопками «завести заявку / не надо».
  emailOffer,

  /// Переписка с собеседником; [NotificationTarget.messageId] — то
  /// сообщение, о котором было уведомление.
  conversation,

  /// Карточка заявки.
  job,

  /// Карточка клиента.
  client,
}

/// Разбор payload уведомления, вынесенный из [NotificationRouter.open].
///
/// Отдельно — чтобы «куда ведёт эта карточка» проверялось тестом, без
/// навигатора и Firestore: раньше уведомление о SMS, к которому сервер
/// успел привязать заявку, открывало карточку заявки, и прочитать само
/// сообщение было негде.
class NotificationTarget {
  final NotificationTargetKind kind;
  final String callId;
  final String jobId;
  final String clientId;

  /// Телефон или адрес собеседника.
  final String peer;
  final String messageId;
  final bool emailChannel;
  final bool websiteInbox;
  final int tab;

  const NotificationTarget(
    this.kind, {
    this.callId = '',
    this.jobId = '',
    this.clientId = '',
    this.peer = '',
    this.messageId = '',
    this.emailChannel = false,
    this.websiteInbox = false,
    this.tab = 0,
  });
}

/// Тап по push или локальному уведомлению открывает того клиента / ту заявку,
/// о которых написано в уведомлении — не «следующего» в календаре.
class NotificationRouter {
  static String? _lastKey;
  static DateTime? _lastAt;
  static Map<String, dynamic>? _pending;
  static Timer? _readyRetry;
  static bool _watchingAccess = false;

  static bool get _canOpen =>
      AuthService.signedIn &&
      !AppLockService.locked.value &&
      rootNavigatorKey.currentState?.mounted == true;

  static void _waitForAccess(Map<String, dynamic> data) {
    _pending = Map.of(data);
    if (!_watchingAccess) {
      _watchingAccess = true;
      AuthService.user.addListener(_flushPending);
      AppLockService.locked.addListener(_flushPending);
    }
    _readyRetry?.cancel();
    if (AuthService.signedIn && !AppLockService.locked.value) {
      _readyRetry = Timer(const Duration(milliseconds: 200), _flushPending);
    }
  }

  static void _flushPending() {
    final data = _pending;
    if (data == null) return;
    if (!_canOpen) {
      _waitForAccess(data);
      return;
    }
    _pending = null;
    _readyRetry?.cancel();
    unawaited(open(data));
  }

  static Future<void> handlePayload(String? raw) async {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return;
    try {
      final decoded = json.decode(text);
      if (decoded is Map) {
        await open(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
  }

  static String _at(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = (data[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  /// Куда ведёт карточка уведомления.
  ///
  /// Порядок важен и проверяется тестами: звонок всегда открывает разбор
  /// того самого звонка, SMS и письмо — ту самую переписку, и ни то, ни
  /// другое не перехватывает карточка заявки, даже когда сервер успел
  /// привязать заявку к сообщению и прислал `jobId`.
  static NotificationTarget targetFor(Map<String, dynamic> data) {
    const none = NotificationTarget(NotificationTargetKind.none);
    if (data.isEmpty) return none;
    final type = (data['type'] ?? '').toString().trim();
    final jobId = _at(data, ['jobId', 'job_id']);
    final clientId = _at(data, ['clientId', 'client_id']);
    final peer = _at(data, ['peer', 'from', 'to']);
    final messageId = _at(data, ['messageId', 'message_id']);
    final callId = _at(data, ['callSid', 'callId', 'call_id']);

    if (type == 'active_call' ||
        type == 'leave_status' ||
        type == 'on_the_way') {
      return none;
    }
    if (type == 'morning' || type == 'evening') {
      return const NotificationTarget(NotificationTargetKind.tab);
    }

    // Звонок открывает запись и расшифровку этого звонка. Если id в
    // уведомлении нет, [open] доищет его по номеру.
    if (type == 'call' ||
        ((type == 'secretary_lesson' || type == 'secretary_learn') &&
            callId.isNotEmpty)) {
      return NotificationTarget(
        NotificationTargetKind.call,
        callId: callId,
        peer: peer,
      );
    }

    if (type == 'email_offer' && messageId.isNotEmpty) {
      return NotificationTarget(
        NotificationTargetKind.emailOffer,
        messageId: messageId,
      );
    }

    // Сообщение ведёт в переписку, а не в заявку: по уведомлению о письме
    // или SMS мастер идёт читать текст. Решение «Отправить / Не
    // отправлять» (`outbox`) тоже принимается кнопками под текстом.
    final isEmail = type == 'email' || type == 'email_offer';
    if (type == 'sms' || type == 'outbox' || isEmail) {
      return _conversation(
        peer: peer,
        clientId: clientId,
        messageId: messageId,
        emailChannel: isEmail || (type != 'outbox' && peer.contains('@')),
      );
    }

    // Care Plan (пора ТО, платёж не прошёл) — в карточку клиента, где план,
    // оплата и паспорта техники.
    if (type == 'care_plan' && (clientId.isNotEmpty || peer.isNotEmpty)) {
      return NotificationTarget(
        NotificationTargetKind.client,
        clientId: clientId,
        peer: peer,
      );
    }

    if (jobId.isNotEmpty) {
      return NotificationTarget(
        NotificationTargetKind.job,
        jobId: jobId,
        peer: peer,
        clientId: clientId,
        messageId: messageId,
      );
    }

    if (peer.contains('@')) {
      return _conversation(
        peer: peer,
        clientId: clientId,
        messageId: messageId,
        emailChannel: true,
      );
    }

    if (peer.isEmpty) return none;
    if (type == 'client' || type.isEmpty) {
      return NotificationTarget(
        NotificationTargetKind.client,
        peer: peer,
        clientId: clientId,
        messageId: messageId,
      );
    }
    return _conversation(
      peer: peer,
      clientId: clientId,
      messageId: messageId,
      emailChannel: false,
    );
  }

  static NotificationTarget _conversation({
    required String peer,
    required String clientId,
    required String messageId,
    required bool emailChannel,
  }) {
    if (emailChannel && SmsMessage.looksLikeWebsiteForm(fromEmail: peer)) {
      return NotificationTarget(
        NotificationTargetKind.conversation,
        websiteInbox: true,
        emailChannel: true,
        messageId: messageId,
      );
    }
    return NotificationTarget(
      NotificationTargetKind.conversation,
      peer: peer,
      clientId: clientId,
      messageId: messageId,
      emailChannel: emailChannel,
    );
  }

  static Future<void> open(Map<String, dynamic> data) async {
    if (data.isEmpty) return;
    if (!_canOpen) {
      _waitForAccess(data);
      return;
    }
    final key = [
      (data['type'] ?? '').toString(),
      _at(data, ['jobId', 'job_id']),
      _at(data, ['clientId', 'client_id']),
      _at(data, ['peer', 'from', 'to']),
      _at(data, ['messageId', 'message_id']),
      _at(data, ['callSid', 'callId', 'call_id']),
    ].join('|');
    final now = DateTime.now();
    if (_lastKey == key &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastKey = key;
    _lastAt = now;

    unawaited(NotificationService.dismissInbox(data));
    if ((data['type'] ?? '').toString().trim() == 'job_reminder') {
      final remindJobId = _at(data, ['jobId', 'job_id']);
      if (remindJobId.isNotEmpty) {
        unawaited(JobReminderService.markOpened(remindJobId));
      }
    }

    final target = targetFor(data);
    if (target.kind == NotificationTargetKind.none) return;

    final nav = await _navigator();
    if (nav == null) return;

    switch (target.kind) {
      case NotificationTargetKind.none:
        return;

      case NotificationTargetKind.tab:
        AppCommands.openTab(target.tab);
        return;

      case NotificationTargetKind.call:
        // В уведомлении приходят и SID Twilio, и id документа — обычно это
        // одно и то же, но у дочернего звонка SID свой, и по нему разбор
        // открылся бы пустым.
        var callId = await TwilioService.firstExistingCallId([
          target.callId,
          (data['callId'] ?? '').toString(),
          (data['call_id'] ?? '').toString(),
        ]);
        if (callId.isEmpty) {
          callId = await TwilioService.latestInboxCallId(from: target.peer);
        }
        if (callId.isEmpty || !nav.mounted) return;
        await CallReviewPage.open(nav.context, callId: callId);
        return;

      case NotificationTargetKind.emailOffer:
        if (!nav.mounted) return;
        await EmailOfferPage.open(nav.context, messageId: target.messageId);
        return;

      case NotificationTargetKind.conversation:
        await _openConversation(nav, target);
        return;

      case NotificationTargetKind.job:
        final job = await JobService.getById(target.jobId);
        if (job != null) {
          if (!nav.mounted) return;
          await AppNav.openCard(
            nav.context,
            key: AppNav.jobKey(job.id),
            builder: (_) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          );
          return;
        }
        // Заявку удалили — показываем хотя бы того, от кого она пришла.
        if (target.peer.isEmpty) return;
        await _openConversation(
          nav,
          _conversation(
            peer: target.peer,
            clientId: target.clientId,
            messageId: target.messageId,
            emailChannel: target.peer.contains('@'),
          ),
        );
        return;

      case NotificationTargetKind.client:
        final client = await _clientFor(
          from: target.peer,
          clientId: target.clientId,
        );
        if (!nav.mounted) return;
        if (client == null) {
          await _openConversation(nav, target);
          return;
        }
        await AppNav.openCard(
          nav.context,
          key: AppNav.clientKey(client.id),
          builder: (_) => ClientDetailsScreen(
            clientId: client.id,
            clientData: client.toMap(),
          ),
        );
        return;
    }
  }

  static Future<void> _openConversation(
    NavigatorState nav,
    NotificationTarget target,
  ) async {
    if (target.websiteInbox) {
      if (!nav.mounted) return;
      await ConversationScreen.open(
        nav.context,
        contactName: kWebsiteInboxTitle,
        websiteInbox: true,
        initialChannel: ConversationChannel.email,
        highlightMessageId: target.messageId,
      );
      return;
    }
    final isEmail = target.peer.contains('@');
    final client = await _clientFor(
      from: target.peer,
      email: isEmail ? target.peer : '',
      clientId: target.clientId,
    );
    if (!nav.mounted) return;
    await ConversationScreen.open(
      nav.context,
      phoneNumber: isEmail ? (client?.phone ?? '') : target.peer,
      email: isEmail ? target.peer : client?.email,
      contactName: client?.fullName,
      clientId: client?.id ?? target.clientId,
      initialChannel: target.emailChannel
          ? ConversationChannel.email
          : ConversationChannel.sms,
      highlightMessageId: target.messageId,
    );
  }

  static Future<Client?> _clientFor({
    String from = '',
    String email = '',
    String clientId = '',
  }) async {
    if (clientId.isNotEmpty) {
      final byId = await ClientService.getById(clientId);
      if (byId != null) return byId;
    }
    final phone = SmsService.normalizePhone(from);
    if (phone.length >= 7) {
      final byPhone = await ClientService.findByPhone(from);
      if (byPhone != null) return byPhone;
    }
    final wantEmail = email.trim().toLowerCase();
    if (!wantEmail.contains('@')) return null;
    final clients = await ClientService.streamAll().first;
    for (final client in clients) {
      if ((client.email ?? '').trim().toLowerCase() == wantEmail) return client;
    }
    return null;
  }

  static Future<NavigatorState?> _navigator() async {
    for (var i = 0; i < 40; i++) {
      final nav = AppNav.activeTabNavigator ?? rootNavigatorKey.currentState;
      if (nav != null && nav.mounted) return nav;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return AppNav.activeTabNavigator ?? rootNavigatorKey.currentState;
  }
}
