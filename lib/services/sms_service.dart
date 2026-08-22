import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/api_keys.dart';
import '../core/sms_text.dart';
import '../models/client.dart';
import 'firestore_service.dart';
import 'notification_service.dart';

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
  /// Русский текст для мастера. Клиенту уходит [body] на английском.
  final String bodyRu;

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
    this.bodyRu = '',
  });

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

  factory SmsMessage.fromMap(Map<String, dynamic> map, String docId) {
    final from = (map['from'] ?? '').toString();
    final to = (map['to'] ?? '').toString();
    final fromEmail = (map['fromEmail'] ?? '').toString();
    final toEmail = (map['toEmail'] ?? '').toString();
    final looksEmail = from.contains('@') || to.contains('@') || fromEmail.contains('@') || toEmail.contains('@');
    return SmsMessage(
      id: docId,
      sid: map['sid'] ?? '',
      from: from,
      to: to,
      body: map['body'] ?? '',
      direction: map['direction'] ?? 'outbound',
      status: map['status'] ?? 'sent',
      clientId: map['clientId'],
      createdAt: map['createdAt'] != null ? (map['createdAt'] as Timestamp).toDate() : null,
      read: map['read'] == true,
      mediaUrls: map['mediaUrls'] != null
          ? List<String>.from(map['mediaUrls'])
          : const [],
      aiStatus: map['aiStatus'] ?? 'none',
      extractedData: map['extractedData'] != null
          ? Map<String, dynamic>.from(map['extractedData'])
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
      bodyRu: (map['bodyRu'] ?? '').toString(),
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

  SmsConversation({
    required this.phoneNumber,
    this.email,
    required this.clientId,
    required this.lastMessage,
    required this.unreadCount,
    this.hasSms = true,
    this.hasEmail = false,
  });
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
    return _ref.where('emailOfferPending', isEqualTo: true).snapshots().map((snapshot) {
      final items = snapshot.docs
          .map(
            (doc) => SmsMessage.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .where((message) => message.jobId == null || message.jobId!.isEmpty)
          .toList();
      items.sort(
        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return items;
    });
  }

  static Future<void> dismissEmailOffer(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _ref.doc(id).set(
      {
        'emailOfferPending': false,
        'emailOfferDismissed': true,
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
  }) async {
    try {
      final urls = mediaUrls.where((url) => url.startsWith('http')).toList();
      if (body.trim().isEmpty && urls.isEmpty) return false;
      final response = await http.post(
        Uri.parse('$kFirebaseFunctionsUrl/sendSms'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'to': toE164(to),
          'body': SmsText.formatSentences(body.trim()),
          'clientId': clientId,
          if (urls.isNotEmpty) 'mediaUrls': urls,
          if (bodyRu != null && bodyRu.trim().isNotEmpty) 'bodyRu': bodyRu.trim(),
        }),
      );
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
    return _ref.orderBy('createdAt', descending: true).limit(1200).snapshots().map(
          (snapshot) => snapshot.docs
              .map((doc) => SmsMessage.fromMap(doc.data() as Map<String, dynamic>, doc.id))
              .where((message) => message.visibleInCrm)
              .toList(),
        );
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
  }) {
    final normalized = normalizePhone(phoneNumber);
    final extra = {
      for (final phone in extraPhones)
        if (normalizePhone(phone).length >= 10) normalizePhone(phone),
    };
    final emailKey = normalizeEmail(email ?? '');
    return streamAll().map((messages) {
      final filtered = messages.where((m) {
        if (emailsOnly != m.isEmail) return false;
        final jobKey = (jobId ?? '').trim();
        if (jobKey.isNotEmpty && (m.jobId ?? '').toString() == jobKey) {
          return true;
        }
        if (clientId != null && clientId.isNotEmpty && m.clientId == clientId) {
          return true;
        }
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
        }
        if (emailsOnly && emailKey.contains('@')) {
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
        continue;
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
        clientId: meta.clientId,
        lastMessage: last,
        unreadCount: msgs.where((m) => !m.isOutbound && !m.read).length,
        hasSms: msgs.any((m) => !m.isEmail),
        hasEmail: msgs.any((m) => m.isEmail),
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
