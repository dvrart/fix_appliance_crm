import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/app_commands.dart';
import '../core/api_keys.dart';
import '../core/sms_text.dart';
import '../models/client.dart';
import 'firestore_service.dart';
import 'notification_service.dart';

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

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
  /// Русский текст для мастера. Клиенту уходит [body] на английском.
  final String bodyRu;
  final DateTime? deletedAt;

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
    this.bodyRu = '',
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

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
      bodyRu: (map['bodyRu'] ?? '').toString(),
      deletedAt: map['deletedAt'] is Timestamp
          ? (map['deletedAt'] as Timestamp).toDate()
          : (map['deletedAt'] is DateTime
              ? map['deletedAt'] as DateTime
              : DateTime.tryParse((map['deletedAt'] ?? '').toString())),
    );
  }

  /// SMS всегда. Письма — только исходящие из CRM и ответы в этих цепочках.
  bool get visibleInCrm {
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

  /// Отправить SMS. Шапку ставит сервер из настроек «Шапка SMS».
  static Future<bool> sendSms({
    required String to,
    required String body,
    String? clientId,
    List<String> mediaUrls = const [],
    String? bodyRu,
    String? fallbackBody,
  }) async {
    try {
      final urls = mediaUrls.where((url) => url.startsWith('http')).toList();
      if (body.trim().isEmpty && urls.isEmpty) return false;
      final fallback = (fallbackBody ?? '').trim();
      final response = await http
          .post(
        Uri.parse('$kFirebaseFunctionsUrl/sendSms'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'to': toE164(to),
          'body': SmsText.formatSentences(body.trim()),
          'clientId': clientId,
          if (urls.isNotEmpty) 'mediaUrls': urls,
          if (bodyRu != null && bodyRu.trim().isNotEmpty) 'bodyRu': bodyRu.trim(),
          if (fallback.isNotEmpty) 'fallbackBody': SmsText.formatSentences(fallback),
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
        return true;
      }
      debugPrint('SmsService: ошибка отправки — ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
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

  static String toE164(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return phone;
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    if (phone.trim().startsWith('+')) return '+$digits';
    return '+$digits';
  }

  /// Стрим всех сообщений (для группировки в переписки).
  static Stream<List<SmsMessage>> streamAll() {
    return _ref.snapshots().map((snapshot) {
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
        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
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
      return filtered;
    });
  }

  static List<SmsConversation> buildConversations(
    List<SmsMessage> messages,
    List<Client> clients,
  ) {
    final byId = {for (final c in clients) c.id: c};
    final phoneToClient = <String, Client>{};
    final emailToClient = <String, Client>{};
    for (final c in clients) {
      final phone = normalizePhone(c.phone);
      if (phone.length >= 10) phoneToClient[phone] = c;
      final email = normalizeEmail(c.email ?? '');
      if (email.contains('@')) emailToClient[email] = c;
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
        batch.update(doc.reference, {'read': true});
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
