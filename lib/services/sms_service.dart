import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/app_commands.dart';
import '../core/api_keys.dart';
import '../core/l10n/app_locale.dart';
import '../core/sms_text.dart';
import '../models/client.dart';
import 'error_log_service.dart';
import 'firestore_service.dart';
import 'notification_service.dart';
import 'auth_service.dart';
import 'network_status_service.dart';
import 'technician_service.dart';

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Путь исходящего сообщения до клиента: очередь → отправлено → доставлено.
enum SmsDelivery { none, queued, sent, delivered, read, failed }

/// Одно SMS-сообщение (входящее или исходящее).
class SmsMessage {
  final String id;
  final String sid;
  final String from;
  final String to;
  final String body;
  final String direction; // 'inbound' | 'outbound'
  final String status;
  final String? clientId;
  final DateTime? createdAt;
  final bool read;
  final List<String> mediaUrls;
  final String aiStatus;
  final Map<String, dynamic>? extractedData;
  final String? jobId;
  final bool hasPendingMedia;
  final String channel; // 'sms' | 'email'
  final String fromEmail;
  final String toEmail;
  final String subject;
  final String? emailMessageId;
  final bool crmThread;
  final bool emailOfferPending;
  final bool emailBellPending;
  final bool emailOfferDismissed;
  final bool watchedSender;
  final bool websiteForm;
  final String fromName;
  final String replyToEmail;
  final bool emailIntake;
  final bool applianceRepair;
  /// Входящее SMS, которое ИИ определил как заявку на ремонт — ждёт ручного создания.
  final bool smsOfferPending;
  /// Код ошибки Twilio, если оператор не доставил SMS (30007 — спам-фильтр).
  final String errorCode;
  /// Мастер убрал карточку «не доставлено» с колокольчика.
  final bool failureDismissed;
  /// Русский текст для мастера. Клиенту уходит [body] на английском.
  final String bodyRu;
  final DateTime? deletedAt;

  /// Судьба исходящего, которое придумал сервер: `pending` — ждёт решения
  /// мастера и клиенту ещё не ушло, `approved` — отправлено по кнопке,
  /// `rejected` — мастер отказался. Пусто у всего, что мастер отправил сам.
  final String approval;
  final String reaction;
  final bool isReactionEcho;

  SmsMessage({
    required this.id,
    required this.sid,
    required this.from,
    required this.to,
    required this.body,
    required this.direction,
    this.status = 'sent',
    this.clientId,
    this.createdAt,
    this.read = true,
    this.mediaUrls = const [],
    this.aiStatus = 'none',
    this.extractedData,
    this.jobId,
    this.hasPendingMedia = false,
    this.channel = 'sms',
    this.fromEmail = '',
    this.toEmail = '',
    this.subject = '',
    this.emailMessageId,
    this.crmThread = false,
    this.emailOfferPending = false,
    this.emailBellPending = false,
    this.emailOfferDismissed = false,
    this.watchedSender = false,
    this.websiteForm = false,
    this.fromName = '',
    this.replyToEmail = '',
    this.emailIntake = false,
    this.applianceRepair = false,
    this.smsOfferPending = false,
    this.errorCode = '',
    this.failureDismissed = false,
    this.bodyRu = '',
    this.deletedAt,
    this.approval = '',
    this.reaction = '',
    this.isReactionEcho = false,
  });

  bool get isDeleted => deletedAt != null;

  /// Сообщение лежит в очереди и клиенту не ушло: нужно «Отправить» мастера.
  bool get awaitingApproval => approval == 'pending' && !isDeleted;

  /// Мастер нажал «Не отправлять» — текст остаётся в переписке как след.
  bool get sendingRejected => approval == 'rejected';

  /// Оператор не доставил сообщение. Twilio присылает это статус-колбэком
  /// уже после отправки, поэтому в чате такое SMS выглядело «отправлено».
  bool get deliveryFailed =>
      isOutbound &&
      !awaitingApproval &&
      !sendingRejected &&
      (status == 'undelivered' || status == 'failed');

  /// Докуда дошло исходящее сообщение.
  ///
  /// Статусы приносит Twilio колбэком `smsStatusCallback`. «Прочитано»
  /// обычные SMS не отдают вообще — такой статус бывает только у RCS и
  /// WhatsApp, поэтому у нас потолок почти всегда «Доставлено». Это не
  /// ошибка и не недоделка: у оператора просто нет такой квитанции.
  SmsDelivery get delivery {
    if (!isOutbound || awaitingApproval || sendingRejected) {
      return SmsDelivery.none;
    }
    switch (status.trim().toLowerCase()) {
      case 'read':
        return SmsDelivery.read;
      case 'delivered':
        return SmsDelivery.delivered;
      case 'sent':
        return SmsDelivery.sent;
      case 'accepted':
      case 'queued':
      case 'scheduled':
      case 'sending':
        return SmsDelivery.queued;
      case 'undelivered':
      case 'failed':
      case 'canceled':
        return SmsDelivery.failed;
      default:
        return SmsDelivery.none;
    }
  }

  /// Почему не дошло — человеческим языком, как в шторке.
  String get failureReason => failureReasonFor(errorCode);

  static String failureReasonFor(String code) {
    switch (code.trim()) {
      case '30003':
        return 'телефон выключен или вне сети'.tr;
      case '30004':
        return 'номер заблокировал приём SMS'.tr;
      case '30005':
        return 'номер не существует'.tr;
      case '30006':
        return 'стационарный номер, SMS не принимает'.tr;
      case '30007':
        return 'оператор заблокировал (спам-фильтр)'.tr;
      case '21610':
        return 'клиент отписался (STOP)'.tr;
      case '21211':
      case '21614':
        return 'неверный номер'.tr;
      default:
        return 'оператор не доставил'.tr;
    }
  }

  static const trashKeepDays = 30;

  int get trashDaysLeft {
    final deleted = deletedAt;
    if (deleted == null) return 0;
    final days =
        deleted.add(const Duration(days: trashKeepDays)).difference(DateTime.now()).inDays;
    return days < 0 ? 0 : days;
  }

  bool get isOutbound => direction == 'outbound';

  String get displayBody {
    final ru = bodyRu.trim();
    if (ru.isEmpty) return body;
    if (ru == body.trim()) return body;
    return ru;
  }

  bool get isEmail =>
      channel == 'email' || fromEmail.contains('@') || toEmail.contains('@');

  String get counterpartEmail {
    final raw = isOutbound
        ? (toEmail.isNotEmpty ? toEmail : to)
        : (fromEmail.isNotEmpty ? fromEmail : from);
    final email = raw.trim().toLowerCase();
    return email.contains('@') ? email : '';
  }

  bool get isWebsiteFormMail {
    if (!isEmail || isOutbound) return false;
    if (websiteForm) return true;
    return looksLikeWebsiteForm(
      fromEmail: counterpartEmail,
      fromName: fromName,
      subject: subject,
      body: body,
    );
  }

  static bool looksLikeWebsiteForm({
    required String fromEmail,
    String fromName = '',
    String subject = '',
    String body = '',
  }) {
    final from = fromEmail.trim().toLowerCase();
    final name = fromName.trim().toLowerCase();
    final subj = subject.toLowerCase();
    final text = body.toLowerCase();
    if (RegExp(r'^(wordpress|wpadmin|wpforms|wp|webmaster)@').hasMatch(from)) {
      return true;
    }
    if (from.contains('wordpress')) return true;
    if (RegExp(r'\bwordpress\b|\bwpforms\b|\bwpcf7\b').hasMatch(name)) {
      return true;
    }
    if (RegExp(
      r'this e-?mail was sent from (a )?contact form|sent from (your )?(contact form on|wordpress)|powered by (wpforms|contact form 7|elementor)',
    ).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'contact form on .{2,160} \(https?:\/\/').hasMatch(text)) {
      return true;
    }
    if (RegExp(
      r'\[wordpress\]|new (contact )?form (entry|submission)|website (inquiry|request|form)|форма с сайта|заявка с сайта',
    ).hasMatch(subj)) {
      return true;
    }
    if (text.contains('fix-appliance.ca') &&
        RegExp(r'\*name\b|\byour name\b|\bfull name\b').hasMatch(text) &&
        RegExp(r'\*email\b|\be-?mail address\b').hasMatch(text)) {
      return true;
    }
    return false;
  }

  factory SmsMessage.fromMap(Map<String, dynamic> map, String docId) {
    final from = (map['from'] ?? '').toString();
    final to = (map['to'] ?? '').toString();
    final fromEmail = (map['fromEmail'] ?? '').toString();
    final toEmail = (map['toEmail'] ?? '').toString();
    final looksEmail = from.contains('@') || to.contains('@') || fromEmail.contains('@') || toEmail.contains('@');
    return SmsMessage(
      id: docId,
      sid: (map['sid'] ?? '').toString(),
      from: from,
      to: to,
      body: (map['body'] ?? '').toString(),
      direction: (map['direction'] ?? 'outbound').toString(),
      status: (map['status'] ?? 'sent').toString(),
      clientId: map['clientId']?.toString(),
      createdAt: _asDate(map['createdAt']),
      read: map['read'] == true,
      mediaUrls: map['mediaUrls'] is List
          ? [for (final item in map['mediaUrls'] as List) item.toString()]
          : const [],
      aiStatus: (map['aiStatus'] ?? 'none').toString(),
      extractedData: map['extractedData'] is Map
          ? Map<String, dynamic>.from(map['extractedData'] as Map)
          : null,
      jobId: map['jobId']?.toString(),
      hasPendingMedia: map['twilioMedia'] is List && (map['twilioMedia'] as List).isNotEmpty,
      channel: (map['channel'] ?? (looksEmail ? 'email' : 'sms')).toString(),
      fromEmail: fromEmail,
      toEmail: toEmail,
      subject: (map['subject'] ?? '').toString(),
      emailMessageId: map['emailMessageId']?.toString(),
      crmThread: map['crmThread'] == true,
      emailOfferPending: map['emailOfferPending'] == true,
      emailBellPending: map['emailBellPending'] == true,
      emailOfferDismissed: map['emailOfferDismissed'] == true,
      watchedSender: map['watchedSender'] == true,
      websiteForm: map['websiteForm'] == true,
      fromName: (map['fromName'] ?? '').toString(),
      replyToEmail: (map['replyToEmail'] ?? '').toString(),
      emailIntake: map['emailIntake'] == true,
      applianceRepair: map['applianceRepair'] == true,
      smsOfferPending: map['smsOfferPending'] == true,
      errorCode: (map['errorCode'] ?? '').toString(),
      failureDismissed: map['failureDismissed'] == true,
      bodyRu: (map['bodyRu'] ?? '').toString(),
      approval: (map['approval'] ?? '').toString(),
      reaction: (map['reaction'] ?? '').toString(),
      isReactionEcho: map['isReactionEcho'] == true,
      deletedAt: map['deletedAt'] is Timestamp
          ? (map['deletedAt'] as Timestamp).toDate()
          : (map['deletedAt'] is DateTime
              ? map['deletedAt'] as DateTime
              : DateTime.tryParse((map['deletedAt'] ?? '').toString())),
    );
  }

  SmsMessage copyWith({String? reaction}) {
    return SmsMessage(
      id: id,
      sid: sid,
      from: from,
      to: to,
      body: body,
      direction: direction,
      status: status,
      clientId: clientId,
      createdAt: createdAt,
      read: read,
      mediaUrls: mediaUrls,
      aiStatus: aiStatus,
      extractedData: extractedData,
      jobId: jobId,
      hasPendingMedia: hasPendingMedia,
      channel: channel,
      fromEmail: fromEmail,
      toEmail: toEmail,
      subject: subject,
      emailMessageId: emailMessageId,
      crmThread: crmThread,
      emailOfferPending: emailOfferPending,
      emailBellPending: emailBellPending,
      emailOfferDismissed: emailOfferDismissed,
      watchedSender: watchedSender,
      websiteForm: websiteForm,
      fromName: fromName,
      replyToEmail: replyToEmail,
      emailIntake: emailIntake,
      applianceRepair: applianceRepair,
      smsOfferPending: smsOfferPending,
      errorCode: errorCode,
      failureDismissed: failureDismissed,
      bodyRu: bodyRu,
      deletedAt: deletedAt,
      approval: approval,
      reaction: reaction ?? this.reaction,
      isReactionEcho: isReactionEcho,
    );
  }

  /// SMS всегда. Письма — только исходящие из CRM и ответы в этих цепочках.
  bool get visibleInCrm {
    if (isReactionEcho) return false;
    if (!isEmail) return true;
    if (isOutbound) return true;
    return crmThread;
  }
}

/// Одна переписка, сгруппированная по номеру телефона собеседника —
/// для списка на экране "Сообщения".
class SmsConversation {
  final String phoneNumber;
  final String? email;
  final String? clientId;
  final SmsMessage lastMessage;
  final int unreadCount;
  final bool hasSms;
  final bool hasEmail;
  final bool isWebsite;
  final List<String> messageIds;

  SmsConversation({
    required this.phoneNumber,
    this.email,
    required this.clientId,
    required this.lastMessage,
    required this.unreadCount,
    this.hasSms = true,
    this.hasEmail = false,
    this.isWebsite = false,
    this.messageIds = const [],
  });

  String get selectKey {
    if (isWebsite) return 'website';
    final client = (clientId ?? '').trim();
    if (client.isNotEmpty) return 'c:$client';
    final phone = SmsService.normalizePhone(phoneNumber);
    if (phone.length >= 10) return 'p:$phone';
    return 'e:${SmsService.normalizeEmail(email ?? '')}';
  }
}

/// Сервис двусторонней SMS-переписки через Twilio.
class SmsService {
  static CollectionReference get _ref => FirestoreService.messagesRef;

  static String normalizePhone(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  static Future<SmsMessage?> getById(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    final doc = await _ref.doc(trimmed).get();
    if (!doc.exists) return null;
    return SmsMessage.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  static Stream<List<SmsMessage>> streamEmailOffers() {
    return _ref.where('channel', isEqualTo: 'email').snapshots().map((snapshot) {
      final now = DateTime.now();
      final items = snapshot.docs
          .map(
            (doc) => SmsMessage.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .where((message) {
            if (message.direction != 'inbound') return false;
            if (message.emailOfferDismissed) return false;
            final jobId = (message.jobId ?? '').trim();
            if (jobId.isNotEmpty && !message.emailOfferPending) return false;
            if (message.emailOfferPending || message.emailBellPending) {
              return true;
            }
            if (message.read) return false;
            final when = message.createdAt;
            if (when != null && now.difference(when).inDays > 21) return false;
            return message.crmThread ||
                message.watchedSender ||
                message.emailIntake ||
                message.applianceRepair;
          })
          .toList();
      items.sort(
        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return _collapseDuplicateEmailOffers(items);
    });
  }

  static String _emailOfferDedupeKey(SmsMessage message) {
    final from = message.counterpartEmail;
    final subject =
        message.subject.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final when = message.createdAt?.toUtc();
    final minute = when == null
        ? ''
        : '${when.year.toString().padLeft(4, '0')}'
            '${when.month.toString().padLeft(2, '0')}'
            '${when.day.toString().padLeft(2, '0')}'
            '${when.hour.toString().padLeft(2, '0')}'
            '${when.minute.toString().padLeft(2, '0')}';
    return '$from|$subject|$minute';
  }

  static List<SmsMessage> _collapseDuplicateEmailOffers(List<SmsMessage> items) {
    if (items.length < 2) return items;
    final seen = <String>{};
    final out = <SmsMessage>[];
    for (final message in items) {
      final key = _emailOfferDedupeKey(message);
      if (key == '||') {
        out.add(message);
        continue;
      }
      if (!seen.add(key)) continue;
      out.add(message);
    }
    return out;
  }

  static Future<void> markEmailSeen(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'emailBellPending': false,
        'read': true,
      },
      SetOptions(merge: true),
    );
  }

  static Future<void> dismissEmailOffer(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'emailOfferPending': false,
        'emailBellPending': false,
        'emailOfferDismissed': true,
        'read': true,
        'aiStatus': 'dismissed',
      },
      SetOptions(merge: true),
    );
  }

  static Future<void> acceptEmailOffer(
    String messageId, {
    required String jobId,
    required String clientId,
  }) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'emailOfferPending': false,
        'emailBellPending': false,
        'jobId': jobId,
        'clientId': clientId,
        'aiStatus': 'done',
        'read': true,
      },
      SetOptions(merge: true),
    );
  }

  /// Входящие SMS, которые ИИ пометил как заявку на ремонт.
  /// Мастер сам решает, создавать ли заявку.
  static Stream<List<SmsMessage>> streamSmsOffers() {
    return _ref
        .where('channel', isEqualTo: 'sms')
        .where('smsOfferPending', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(days: 7));
      final items = snapshot.docs
          .map(
            (doc) => SmsMessage.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .where((message) {
            if (message.direction != 'inbound') return false;
            if (message.isDeleted) return false;
            final when = message.createdAt;
            if (when != null && when.isBefore(cutoff)) return false;
            return true;
          })
          .toList();
      items.sort(
        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return items;
    });
  }

  /// Исходящие, которые оператор не доставил. Бейдж «Связи» считает их,
  /// пока мастер не откроет сам диалог: раньше провал был виден только в
  /// логах Twilio.
  static Stream<List<SmsMessage>> streamFailedOutbound() {
    return _ref
        .where('deliveryFailed', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      final items = snapshot.docs
          .map(
            (doc) => SmsMessage.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .where((message) {
            if (message.failureDismissed || message.isDeleted) return false;
            if (!message.deliveryFailed) return false;
            final when = message.createdAt;
            return when == null || when.isAfter(cutoff);
          })
          .toList();
      items.sort(
        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return items;
    });
  }

  static Future<void> dismissFailure(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {'failureDismissed': true},
      SetOptions(merge: true),
    );
  }

  static Future<void> dismissSmsOffer(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'smsOfferPending': false,
        'read': true,
        'aiStatus': 'dismissed',
      },
      SetOptions(merge: true),
    );
  }

  static Future<void> acceptSmsOffer(
    String messageId, {
    required String jobId,
    required String clientId,
  }) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'smsOfferPending': false,
        'jobId': jobId,
        'clientId': clientId,
        'aiStatus': 'done',
        'read': true,
      },
      SetOptions(merge: true),
    );
  }

  /// Исходящие, которые придумал сервер и которые клиенту ещё не ушли.
  /// Решение FIX, 05.10.2026: ни одно такое сообщение не уходит само —
  /// мастер видит текст и жмёт «Отправить» или «Не отправлять».
  static Stream<List<SmsMessage>> streamAwaitingApproval() {
    return _ref
        .where('approval', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) {
      final items = snapshot.docs
          .map(
            (doc) => SmsMessage.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .where((message) => message.awaitingApproval)
          .toList();
      items.sort(
        (a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );
      return items;
    });
  }

  /// Отправить ([send] = true) или отклонить сообщение из очереди.
  /// Twilio дёргает сервер: решение возвращается уже после попытки отправки,
  /// поэтому ошибку видно сразу, а сообщение остаётся в очереди.
  static Future<bool> decideOutbox(String messageId, {required bool send}) async {
    final id = messageId.trim();
    if (id.isEmpty) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/approveOutbox'),
            headers: await AuthService.headers(),
            body: json.encode({'id': id, 'action': send ? 'send' : 'reject'}),
          )
          .timeout(const Duration(seconds: 40));
      if (response.statusCode == 200) {
        lastError = '';
        return true;
      }
      lastError = _describeSendError(response.statusCode, response.body);
      ErrorLogService.record(
        'Решение по сообщению не прошло (${response.statusCode}): ${response.body.trim()}',
        null,
        kind: 'sms',
      );
      return false;
    } catch (e, s) {
      lastError = e is TimeoutException ? 'сервер не ответил вовремя' : 'нет связи';
      ErrorLogService.record(e, s, kind: 'sms');
      return false;
    }
  }

  /// Почему не ушло последнее SMS. Раньше причина уходила в debugPrint,
  /// которого в релизе не видно, и владелец получал бесполезное
  /// «Не удалось отправить SMS» без единой подсказки.
  static String lastError = '';

  /// Текст для подсказки на экране — с причиной, если она известна.
  static String failureText() {
    final base = 'Не удалось отправить SMS'.tr;
    return lastError.isEmpty ? base : '$base: $lastError';
  }

  static String _describeSendError(int status, String body) {
    if (status == 401) {
      return 'нужно войти в приложение заново';
    }
    if (status == 0) return 'нет связи с сервером';
    String detail = '';
    try {
      final decoded = json.decode(body);
      if (decoded is Map && decoded['error'] != null) {
        detail = decoded['error'].toString();
      }
    } catch (_) {
      detail = body.trim();
    }
    detail = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (detail.length > 120) detail = '${detail.substring(0, 120)}…';
    return detail.isEmpty ? 'сервер ответил $status' : detail;
  }

  /// Отправить SMS. Шапку ставит сервер из настроек «Шапка SMS».
  static Future<bool> sendSms({
    required String to,
    required String body,
    String? clientId,
    String? jobId,
    List<String> mediaUrls = const [],
    String? bodyRu,
    String? fallbackBody,
    Map<String, String>? visitBooking,
  }) async {
    try {
      final urls = mediaUrls.where((url) => url.startsWith('http')).toList();
      if (body.trim().isEmpty && urls.isEmpty) return false;
      // Кириллицу здесь не трогаем: русский текст на сервере ещё переводят на
      // английский, и только то, что перевод не осилил, он транслитерирует.
      final fallback = (fallbackBody ?? '').trim();
      if (visitBooking != null && !await waitForWriteAcknowledgement(
        FirebaseFirestore.instance.waitForPendingWrites(),
      )) {
        lastError = 'Изменения визита ещё не синхронизированы. SMS не отправлено — повторите после восстановления связи';
        return false;
      }
      final response = await http
          .post(
        Uri.parse('$kFirebaseFunctionsUrl/sendSms'),
        headers: await AuthService.headers(),
        body: json.encode({
          'to': toE164(to),
          'body': SmsText.formatSentences(body.trim()),
          'clientId': clientId,
          if (jobId != null && jobId.trim().isNotEmpty) 'jobId': jobId.trim(),
          if (urls.isNotEmpty) 'mediaUrls': urls,
          if (bodyRu != null && bodyRu.trim().isNotEmpty) 'bodyRu': bodyRu.trim(),
          if (fallback.isNotEmpty) 'fallbackBody': SmsText.formatSentences(fallback),
          'visitBooking': ?visitBooking,
        }),
      )
          .timeout(const Duration(seconds: 40));
      if (response.statusCode == 200) {
        if (bodyRu != null && bodyRu.trim().isNotEmpty) {
          try {
            final payload = json.decode(response.body);
            final id = payload['id']?.toString();
            if (id != null && id.isNotEmpty) {
              await _ref.doc(id).set(
                {'bodyRu': bodyRu.trim()},
                SetOptions(merge: true),
              );
            }
          } catch (_) {}
        }
        lastError = '';
        return true;
      }
      lastError = _describeSendError(response.statusCode, response.body);
      if (response.statusCode == 202 && visitBooking != null) return false;
      // В журнал ошибок, иначе причину видно только в отладочной сборке.
      ErrorLogService.record(
        'SMS не ушло (${response.statusCode}): ${response.body.trim()}',
        null,
        kind: 'sms',
      );
      debugPrint('SmsService: ошибка отправки — ${response.statusCode}: ${response.body}');
      return false;
    } catch (e, s) {
      lastError = e is TimeoutException ? 'сервер не ответил вовремя' : 'нет связи';
      ErrorLogService.record(e, s, kind: 'sms');
      debugPrint('SmsService: ошибка отправки: $e');
      return false;
    }
  }

  static Future<void> saveBodyRu(String messageId, String bodyRu) async {
    if (messageId.isEmpty || bodyRu.trim().isEmpty) return;
    try {
      await _ref.doc(messageId).set(
        {'bodyRu': bodyRu.trim()},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  /// Стандартная строка Tapback для iOS и Google Messages (Android):
  /// без шапки компании и с точной цитатой сообщения в кавычках “...”,
  /// чтобы телефон собеседника прикрепил реакцию к пузырю сообщения, а не
  /// показал отдельную SMS.
  static String buildTapbackBody(String emoji, String originalBody) {
    final quote = originalBody;
    switch (emoji) {
      case '👍':
        return 'Liked “$quote”';
      case '❤️':
        return 'Loved “$quote”';
      case '😂':
        return 'Laughed at “$quote”';
      case '❗':
        return 'Emphasized “$quote”';
      case '❓':
        return 'Questioned “$quote”';
      default:
        return '\u200a$emoji\u200ato “$quote”';
    }
  }

  /// Распознать входящий Tapback от клиента (например `Liked “...”` или
  /// `Loved “...”`), чтобы повесить значок на сообщение в CRM, а не
  /// показывать отдельным пузырём.
  static ({String emoji, String quoted})? parseTapback(String rawBody) {
    final text = rawBody.trim();
    if (text.isEmpty) return null;
    final apple = RegExp(
      r'^(Liked|Loved|Laughed at|Emphasized|Questioned|Disliked)\s+[“"]([\s\S]+)[”"]$',
    ).firstMatch(text);
    if (apple != null) {
      final verb = apple.group(1)!;
      final quoted = apple.group(2)!;
      final emoji = switch (verb) {
        'Liked' => '👍',
        'Loved' => '❤️',
        'Laughed at' => '😂',
        'Emphasized' => '❗',
        'Questioned' => '❓',
        'Disliked' => '👎',
        _ => '👍',
      };
      return (emoji: emoji, quoted: quoted);
    }
    final google = RegExp(
      r'^\u200a?(\S+)\u200a?\s*to\s+[“"]([\s\S]+)[”"]$',
    ).firstMatch(text);
    if (google != null) {
      return (emoji: google.group(1)!, quoted: google.group(2)!);
    }
    final reacted = RegExp(
      r'^Reacted\s+(\S+)\s+to\s+[“"]([\s\S]+)[”"]$',
    ).firstMatch(text);
    if (reacted != null) {
      return (emoji: reacted.group(1)!, quoted: reacted.group(2)!);
    }
    return null;
  }

  /// Поставить (или снять) реакцию на SMS и отправить Tapback клиенту,
  /// чтобы реакция прикрепилась к сообщению.
  static Future<bool> reactToMessage({
    required SmsMessage message,
    required String emoji,
    required String toPhone,
    String? clientId,
  }) async {
    final trimmed = emoji.trim();
    try {
      await _ref.doc(message.id).set(
        {'reaction': trimmed},
        SetOptions(merge: true),
      );
    } catch (_) {
      return false;
    }
    if (trimmed.isEmpty) return true;
    final phone = toPhone.trim();
    if (phone.isEmpty || message.isEmail) return true;
    final original = message.body;
    if (original.trim().isEmpty) return true;
    final tapback = buildTapbackBody(trimmed, original);
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/sendSms'),
            headers: await AuthService.headers(),
            body: json.encode({
              'to': toE164(phone),
              'body': tapback,
              'clientId': clientId,
              'isReactionEcho': true,
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (response.statusCode == 200) {
        try {
          final payload = json.decode(response.body);
          final id = payload['id']?.toString() ?? '';
          if (id.isNotEmpty) {
            await _ref.doc(id).delete();
          }
        } catch (_) {}
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String toE164(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return phone;
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    if (phone.trim().startsWith('+')) return '+$digits';
    return '+$digits';
  }

  static StreamSubscription<QuerySnapshot>? _allSub;
  static List<SmsMessage>? _allLatest;
  static final Set<MultiStreamController<List<SmsMessage>>> _allListeners = {};

  /// Стрим всех сообщений (для группировки в переписки).
  static Stream<List<SmsMessage>> streamAll() {
    return Stream<List<SmsMessage>>.multi((controller) {
      final cached = _allLatest;
      if (cached != null) {
        controller.add(cached);
      }
      _allListeners.add(controller);
      _allSub ??= _ref.snapshots().listen(
        (snapshot) {
          final messages = <SmsMessage>[];
          for (final doc in snapshot.docs) {
            try {
              final data = doc.data();
              if (data is! Map) continue;
              final message = SmsMessage.fromMap(
                Map<String, dynamic>.from(data),
                doc.id,
              );
              if (message.visibleInCrm && !message.isDeleted) {
                messages.add(message);
              }
            } catch (error) {
              debugPrint('SMS ${doc.id}: $error');
            }
          }
          messages.sort(
            (a, b) => (b.createdAt ?? DateTime(0)).compareTo(
              a.createdAt ?? DateTime(0),
            ),
          );
          _allLatest = messages;
          for (final listener in _allListeners.toList()) {
            listener.add(messages);
          }
        },
        onError: (Object error, StackTrace stack) {
          for (final listener in _allListeners.toList()) {
            listener.addError(error, stack);
          }
        },
      );
      controller.onCancel = () async {
        _allListeners.remove(controller);
        if (_allListeners.isEmpty) {
          final sub = _allSub;
          _allSub = null;
          _allLatest = null;
          await sub?.cancel();
        }
      };
    });
  }

  /// Непрочитанные входящие — только они, без всей переписки: по этому
  /// потоку живут счётчики на вкладке «Связь», и он должен быть дешёвым.
  /// Фильтр «видно ли это в CRM» остаётся в памяти: письмо не из нашей
  /// цепочки лежит в коллекции, но в списке переписок его нет, и считать
  /// его нельзя.
  static Stream<List<SmsMessage>> streamUnreadInbound() {
    return _ref
        .where('direction', isEqualTo: 'inbound')
        .where('read', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
      final messages = <SmsMessage>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data();
          if (data is! Map) continue;
          final message = SmsMessage.fromMap(
            Map<String, dynamic>.from(data),
            doc.id,
          );
          if (!message.isDeleted &&
              (message.visibleInCrm ||
                  (message.emailOfferPending && !message.emailOfferDismissed))) {
            messages.add(message);
          }
        } catch (error) {
          debugPrint('SMS ${doc.id}: $error');
        }
      }
      messages.sort(
        (a, b) =>
            (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return messages;
    });
  }

  static Stream<List<SmsMessage>> streamTrashed() {
    return _ref.orderBy('createdAt', descending: true).limit(1200).snapshots().map(
          (snapshot) => snapshot.docs
              .map((doc) => SmsMessage.fromMap(doc.data() as Map<String, dynamic>, doc.id))
              .where((message) => message.isDeleted)
              .toList(),
        );
  }

  static Future<void> delete(String id) async {
    if (id.trim().isEmpty) return;
    AppCommands.reactAngry();
    await _ref.doc(id).set(
      {
        'deletedAt': FieldValue.serverTimestamp(),
        'aiSkip': true,
        'aiStatus': 'skipped',
      },
      SetOptions(merge: true),
    );
  }

  static Future<void> deleteMany(Iterable<String> ids) async {
    for (final id in ids) {
      await delete(id);
    }
  }

  static Future<void> restore(String id) async {
    if (id.trim().isEmpty) return;
    await _ref.doc(id).set(
      {'deletedAt': FieldValue.delete()},
      SetOptions(merge: true),
    );
  }

  static Future<void> deleteForever(String id) async {
    if (id.trim().isEmpty) return;
    await _ref.doc(id).delete();
  }

  static Future<void> purgeExpiredTrash() async {
    final cutoff = DateTime.now().subtract(const Duration(days: SmsMessage.trashKeepDays));
    final snapshot = await _ref.limit(1200).get();
    for (final doc in snapshot.docs) {
      try {
        final message = SmsMessage.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (message.deletedAt != null && message.deletedAt!.isBefore(cutoff)) {
          await deleteForever(message.id);
        }
      } catch (_) {}
    }
  }

  static String normalizeEmail(String value) => value.trim().toLowerCase();

  /// Переписка с клиентом. [emailsOnly] — только письма, иначе только SMS.
  static Stream<List<SmsMessage>> streamConversation(
    String phoneNumber, {
    String? email,
    String? clientId,
    String? jobId,
    List<String> extraPhones = const [],
    bool emailsOnly = false,
    bool websiteInbox = false,
  }) {
    if (TechnicianService.isTechnician) {
      final targetJobId = (jobId ?? '').trim();
      if (targetJobId.isEmpty) return Stream.value(const []);
      return _ref.where('jobId', isEqualTo: targetJobId).snapshots().map((
        snapshot,
      ) {
        final items = <SmsMessage>[];
        for (final doc in snapshot.docs) {
          try {
            final data = doc.data();
            if (data is! Map) continue;
            final m = SmsMessage.fromMap(
              Map<String, dynamic>.from(data),
              doc.id,
            );
            if (!m.isDeleted && m.visibleInCrm && emailsOnly == m.isEmail) {
              items.add(m);
            }
          } catch (_) {}
        }
        items.sort(
          (a, b) =>
              (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
        );
        return _foldTapbacks(items);
      });
    }
    final normalized = normalizePhone(phoneNumber);
    final extra = {
      for (final phone in extraPhones)
        if (normalizePhone(phone).length >= 10) normalizePhone(phone),
    };
    final emailKey = normalizeEmail(email ?? '');
    return streamAll().map((messages) {
      final filtered = messages.where((m) {
        if (websiteInbox) {
          return m.isEmail && m.isWebsiteFormMail;
        }
        if (m.isWebsiteFormMail) return false;
        if (emailsOnly != m.isEmail) return false;
        if (!emailsOnly) {
          final from = normalizePhone(m.from);
          final to = normalizePhone(m.to);
          if (normalized.length >= 10 &&
              (from == normalized || to == normalized)) {
            return true;
          }
          if (extra.contains(from) || extra.contains(to)) {
            return true;
          }
          return false;
        }
        if (emailKey.contains('@')) {
          final fromE = normalizeEmail(m.fromEmail.isNotEmpty ? m.fromEmail : m.from);
          final toE = normalizeEmail(m.toEmail.isNotEmpty ? m.toEmail : m.to);
          if (fromE == emailKey || toE == emailKey) return true;
        }
        return false;
      }).toList();
      filtered.sort((a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)));
      return _foldTapbacks(filtered);
    });
  }

  static String _normTapbackText(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Сворачивает SMS-реакции (`Liked “...”`, `Loved “...”` и т.п.) в поле
  /// `reaction` того сообщения, к которому они относятся, чтобы лайк стоял
  /// на самом сообщении, а не висел отдельным пузырём.
  static List<SmsMessage> _foldTapbacks(List<SmsMessage> sorted) {
    if (sorted.length < 2) return sorted;
    final out = <SmsMessage>[];
    for (final msg in sorted) {
      final parsed = parseTapback(msg.body);
      if (parsed != null) {
        final targetNorm = _normTapbackText(parsed.quoted);
        var matchedIndex = -1;
        for (var i = out.length - 1; i >= 0; i--) {
          final candidateNorm = _normTapbackText(out[i].body);
          if (candidateNorm.isNotEmpty &&
              (candidateNorm == targetNorm ||
                  candidateNorm.endsWith(targetNorm) ||
                  targetNorm.endsWith(candidateNorm))) {
            matchedIndex = i;
            break;
          }
        }
        if (matchedIndex >= 0) {
          if (out[matchedIndex].reaction.trim().isEmpty) {
            out[matchedIndex] = out[matchedIndex].copyWith(
              reaction: parsed.emoji,
            );
          }
          continue;
        }
      }
      out.add(msg);
    }
    return out;
  }

  static List<SmsConversation> buildConversations(
    List<SmsMessage> messages,
    List<Client> clients,
  ) {
    final byId = {for (final c in clients) c.id: c};
    final phoneToClient = <String, Client>{};
    final emailToClient = <String, Client>{};
    for (final c in clients) {
      final hasRealName =
          c.fullName.isNotEmpty && !Client.isPlaceholderName(c.fullName);
      final phone = normalizePhone(c.phone);
      if (phone.length >= 10) {
        final prev = phoneToClient[phone];
        if (prev == null ||
            (hasRealName && Client.isPlaceholderName(prev.fullName))) {
          phoneToClient[phone] = c;
        }
      }
      final email = normalizeEmail(c.email ?? '');
      if (email.contains('@')) {
        final prev = emailToClient[email];
        if (prev == null ||
            (hasRealName && Client.isPlaceholderName(prev.fullName))) {
          emailToClient[email] = c;
        }
      }
      for (final location in c.locations) {
        for (final contact in location.contacts) {
          final cp = normalizePhone(contact.phone);
          if (cp.length >= 10) phoneToClient.putIfAbsent(cp, () => c);
        }
      }
    }

    final grouped = <String, List<SmsMessage>>{};
    final keys = <String, ({String phone, String email, String? clientId})>{};

    for (final m in messages) {
      if (m.isWebsiteFormMail) {
        grouped.putIfAbsent('website', () => []).add(m);
        keys['website'] = (
          phone: '',
          email: '',
          clientId: null,
        );
        continue;
      }
      Client? client = m.clientId != null ? byId[m.clientId] : null;
      final counterpart = m.isOutbound ? m.to : m.from;
      final phone = normalizePhone(counterpart);
      if (client == null && phone.length >= 10) client = phoneToClient[phone];
      final email = m.counterpartEmail;
      if (client == null && email.contains('@')) client = emailToClient[email];

      late final String key;
      if (client != null) {
        key = 'c:${client.id}';
      } else if (phone.length >= 10) {
        key = 'p:$phone';
      } else if (email.contains('@')) {
        key = 'e:$email';
      } else {
        key = 'm:${m.id}';
      }

      grouped.putIfAbsent(key, () => []).add(m);
      final prev = keys[key];
      keys[key] = (
        phone: client?.phone ??
            (phone.length >= 10 ? counterpart : (prev?.phone ?? '')),
        email: (client?.email != null && client!.email!.contains('@'))
            ? client.email!.trim()
            : (email.contains('@') ? email : (prev?.email ?? '')),
        clientId: client?.id ?? prev?.clientId ?? m.clientId,
      );
    }

    final conversations = grouped.entries.map((entry) {
      final msgs = entry.value
        ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
      final last = msgs.first;
      final meta = keys[entry.key]!;
      return SmsConversation(
        phoneNumber: meta.phone,
        email: meta.email.contains('@') ? meta.email : null,
        clientId: entry.key == 'website' ? null : meta.clientId,
        lastMessage: last,
        unreadCount: msgs.where((m) => !m.isOutbound && !m.read).length,
        hasSms: msgs.any((m) => !m.isEmail),
        hasEmail: msgs.any((m) => m.isEmail),
        isWebsite: entry.key == 'website',
        messageIds: [for (final message in msgs) message.id],
      );
    }).toList();

    conversations.sort((a, b) =>
        (b.lastMessage.createdAt ?? DateTime(0)).compareTo(a.lastMessage.createdAt ?? DateTime(0)));
    return conversations;
  }

  /// Список переписок, сгруппированных по клиенту / номеру / почте.
  static Stream<List<SmsConversation>> streamConversations() {
    return streamAll().map((messages) => buildConversations(messages, const <Client>[]));
  }

  /// Отметить входящие этой переписки как прочитанные (SMS и письма).
  static Future<void> markConversationRead(
    String phoneNumber, {
    String? email,
    String? clientId,
    bool websiteInbox = false,
  }) async {
    final normalized = normalizePhone(phoneNumber);
    final emailKey = normalizeEmail(email ?? '');
    final snapshot = await _ref
        .where('direction', isEqualTo: 'inbound')
        .where('read', isEqualTo: false)
        .get();

    final batch = FirebaseFirestore.instance.batch();
    var hasUpdates = false;
    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (websiteInbox) {
        if (SmsMessage.fromMap(data, doc.id).isWebsiteFormMail) {
          batch.update(doc.reference, {'read': true});
          hasUpdates = true;
        }
        continue;
      }
      final from = (data['from'] ?? '').toString();
      final to = (data['to'] ?? '').toString();
      final fromEmail = (data['fromEmail'] ?? from).toString();
      final toEmail = (data['toEmail'] ?? '').toString();
      final docClientId = (data['clientId'] ?? '').toString();
      final clientMatch =
          clientId != null && clientId.isNotEmpty && docClientId == clientId;
      final phoneMatch = normalized.length >= 10 &&
          (normalizePhone(from) == normalized || normalizePhone(to) == normalized);
      final emailMatch = emailKey.contains('@') &&
          (normalizeEmail(fromEmail) == emailKey ||
              normalizeEmail(toEmail) == emailKey ||
              normalizeEmail(from) == emailKey ||
              normalizeEmail(to) == emailKey);
      if (clientMatch || phoneMatch || emailMatch) {
        // `emailBellPending` гасится здесь же: иначе прочитанное письмо
        // уходило из переписки, но продолжало висеть в уведомлениях и
        // держать счётчик — два независимых «прочитано» на один факт.
        batch.update(doc.reference, {'read': true, 'emailBellPending': false});
        hasUpdates = true;
      }
    }
    // Недоставленные исходящие гасятся вместе с открытием диалога: мастер
    // видит «Не доставлено» в самой переписке, отдельного уведомления
    // про провал (бейдж «Связи») после этого уже не стоит.
    final failedSnapshot = await _ref
        .where('deliveryFailed', isEqualTo: true)
        .get();
    for (final doc in failedSnapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['failureDismissed'] == true) continue;
      final to = (data['to'] ?? '').toString();
      final toEmail = (data['toEmail'] ?? '').toString();
      final docClientId = (data['clientId'] ?? '').toString();
      final clientMatch =
          clientId != null && clientId.isNotEmpty && docClientId == clientId;
      final phoneMatch =
          normalized.length >= 10 && normalizePhone(to) == normalized;
      final emailMatch = emailKey.contains('@') &&
          (normalizeEmail(toEmail) == emailKey ||
              normalizeEmail(to) == emailKey);
      if (clientMatch || phoneMatch || emailMatch) {
        batch.update(doc.reference, {'failureDismissed': true});
        hasUpdates = true;
      }
    }
    if (hasUpdates) await batch.commit();
    await NotificationService.dismissConversation(
      phone: phoneNumber,
      email: email,
    );
  }
}
