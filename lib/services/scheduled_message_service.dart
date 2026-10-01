import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_service.dart';
import 'network_status_service.dart';
import 'sms_service.dart' show SmsService;

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Одно отложенное сообщение (SMS или email), ожидающее отправки.
class ScheduledMessage {
  final String id;

  /// 'sms' или 'email'
  final String channel;

  /// Номер телефона получателя (для SMS)
  final String to;

  /// Email получателя (для email)
  final String toEmail;

  final String body;
  final String bodyRu;
  final String? clientId;
  final String subject;
  final List<String> mediaUrls;
  final DateTime sendAt;

  /// pending → sending → sent / failed / cancelled
  final String status;
  final DateTime? createdAt;
  final DateTime? sentAt;
  final String? errorMsg;

  const ScheduledMessage({
    required this.id,
    required this.channel,
    required this.to,
    required this.toEmail,
    required this.body,
    required this.bodyRu,
    this.clientId,
    required this.subject,
    required this.mediaUrls,
    required this.sendAt,
    required this.status,
    this.createdAt,
    this.sentAt,
    this.errorMsg,
  });

  bool get isPending => status == 'pending' || status == 'sending';

  factory ScheduledMessage.fromMap(Map<String, dynamic> map, String id) {
    final sendAt = _asDate(map['sendAt']) ?? DateTime.now();
    return ScheduledMessage(
      id: id,
      channel: (map['channel'] ?? 'sms').toString(),
      to: (map['to'] ?? '').toString(),
      toEmail: (map['toEmail'] ?? '').toString(),
      body: (map['body'] ?? '').toString(),
      bodyRu: (map['bodyRu'] ?? '').toString(),
      clientId: map['clientId']?.toString(),
      subject: (map['subject'] ?? '').toString(),
      mediaUrls: map['mediaUrls'] is List
          ? [for (final u in map['mediaUrls'] as List) u.toString()]
          : const [],
      sendAt: sendAt,
      status: (map['status'] ?? 'pending').toString(),
      createdAt: _asDate(map['createdAt']),
      sentAt: _asDate(map['sentAt']),
      errorMsg: map['errorMsg']?.toString(),
    );
  }
}

/// Сервис отложенной отправки SMS и email.
///
/// Данные хранятся в Firestore `scheduled_messages`.
/// Cloud Function `processScheduledMessages` проверяет коллекцию раз в минуту
/// и отправляет все сообщения с `sendAt <= now` и `status == 'pending'`.
class ScheduledMessageService {
  static CollectionReference get _ref => FirestoreService.scheduledMessagesRef;

  /// Создать отложенное сообщение.
  static Future<String> schedule({
    required String channel,
    required String to,
    String toEmail = '',
    required String body,
    String bodyRu = '',
    String? clientId,
    String subject = '',
    List<String> mediaUrls = const [],
    required DateTime sendAt,
  }) async {
    final doc = _ref.doc();
    await settleWrite(doc.set({
      'channel': channel,
      'to': to,
      'toEmail': toEmail,
      'body': body,
      'bodyRu': bodyRu,
      'clientId': clientId,
      'subject': subject,
      'mediaUrls': mediaUrls,
      'sendAt': Timestamp.fromDate(sendAt.toUtc()),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    }));
    return doc.id;
  }

  /// Отменить отложенное сообщение (status → cancelled).
  static Future<void> cancel(String id) async {
    if (id.trim().isEmpty) return;
    await _ref.doc(id).set({'status': 'cancelled'}, SetOptions(merge: true));
  }

  /// Поток pending-сообщений для данной переписки.
  /// Подходит для SMS-нити (по phone) и email-нити (по email).
  static Stream<List<ScheduledMessage>> streamPendingForConversation(
    String phone, {
    String? email,
    String? clientId,
  }) {
    final normalized = SmsService.normalizePhone(phone);
    final emailKey = (email ?? '').trim().toLowerCase();
    return _ref
        .where('status', whereIn: ['pending', 'sending', 'failed'])
        .snapshots()
        .map((snap) {
          final out = <ScheduledMessage>[];
          for (final doc in snap.docs) {
            try {
              final msg = ScheduledMessage.fromMap(
                doc.data() as Map<String, dynamic>,
                doc.id,
              );
              // Совпадение по клиенту
              if (clientId != null &&
                  clientId.isNotEmpty &&
                  msg.clientId == clientId) {
                out.add(msg);
                continue;
              }
              // Совпадение по телефону
              if (normalized.length >= 10 &&
                  SmsService.normalizePhone(msg.to) == normalized) {
                out.add(msg);
                continue;
              }
              // Совпадение по email
              if (emailKey.contains('@') &&
                  msg.toEmail.trim().toLowerCase() == emailKey) {
                out.add(msg);
                continue;
              }
            } catch (_) {}
          }
          out.sort((a, b) => a.sendAt.compareTo(b.sendAt));
          return out;
        });
  }
}
