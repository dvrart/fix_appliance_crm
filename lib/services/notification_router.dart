import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_commands.dart';
import '../features/clients/client_details_screen.dart';
import '../features/jobs/email_offer_page.dart';
import '../features/jobs/job_details/job_details_screen.dart';
import '../features/messages/conversation_screen.dart';
import '../features/settings/pages/secretary_learn_page.dart';
import '../models/client.dart';
import 'client_service.dart';
import 'job_service.dart';
import 'sms_service.dart';

/// Тап по push или локальному уведомлению открывает того клиента / ту заявку,
/// о которых написано в уведомлении — не «следующего» в календаре.
class NotificationRouter {
  static String? _lastKey;
  static DateTime? _lastAt;

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

  static Future<void> open(Map<String, dynamic> data) async {
    if (data.isEmpty) return;
    final type = (data['type'] ?? '').toString();
    final jobId = (data['jobId'] ?? data['job_id'] ?? '').toString().trim();
    final from = (data['from'] ?? data['to'] ?? '').toString().trim();
    final messageId =
        (data['messageId'] ?? data['message_id'] ?? '').toString().trim();
    final key = '$type|$jobId|$from|$messageId';
    final now = DateTime.now();
    if (_lastKey == key &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastKey = key;
    _lastAt = now;

    final nav = await _navigator();
    if (nav == null) return;

    if (type == 'morning' || type == 'evening') {
      AppCommands.openTab(0);
      return;
    }

    if (type == 'secretary_lesson' || type == 'secretary_learn') {
      await nav.push(
        MaterialPageRoute(builder: (_) => const SecretaryLearnPage()),
      );
      return;
    }

    if (type == 'email_offer' && messageId.isNotEmpty) {
      await EmailOfferPage.open(nav.context, messageId: messageId);
      return;
    }

    if (jobId.isNotEmpty) {
      final job = await JobService.getById(jobId);
      if (job != null) {
        await nav.push(
          MaterialPageRoute(
            builder: (_) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          ),
        );
        return;
      }
    }

    if (type == 'email' || from.contains('@')) {
      final client = await _clientFor(from: from, email: from);
      await nav.push(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            phoneNumber: client?.phone ?? '',
            email: from.contains('@') ? from : client?.email,
            contactName: client?.fullName,
            clientId: client?.id,
            initialChannel: ConversationChannel.email,
          ),
        ),
      );
      return;
    }

    if (from.isNotEmpty) {
      final client = await _clientFor(from: from);
      if (client != null && (type == 'client' || type.isEmpty && jobId.isEmpty)) {
        await nav.push(
          MaterialPageRoute(
            builder: (_) => ClientDetailsScreen(
              clientId: client.id,
              clientData: client.toMap(),
            ),
          ),
        );
        return;
      }
      await nav.push(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            phoneNumber: from,
            email: client?.email,
            contactName: client?.fullName,
            clientId: client?.id,
            initialChannel: ConversationChannel.sms,
          ),
        ),
      );
    }
  }

  static Future<Client?> _clientFor({String from = '', String email = ''}) async {
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
      final nav = rootNavigatorKey.currentState;
      if (nav != null && nav.mounted) return nav;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return rootNavigatorKey.currentState;
  }
}
