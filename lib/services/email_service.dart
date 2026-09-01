import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';

/// Исходящая почта через Cloud Function (Gmail SMTP).
class EmailService {
  static Future<bool> sendEmail({
    required String to,
    required String body,
    String? subject,
    String? clientId,
    String? phone,
    List<String> mediaUrls = const [],
    String? bodyRu,
  }) async {
    final email = to.trim();
    final urls = mediaUrls.where((url) => url.startsWith('http')).toList();
    if (!email.contains('@') || (body.trim().isEmpty && urls.isEmpty)) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/sendEmail'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'to': email,
              'body': body.trim(),
              if (subject != null && subject.trim().isNotEmpty) 'subject': subject.trim(),
              if (clientId != null) 'clientId': clientId,
              if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
              if (urls.isNotEmpty) 'mediaUrls': urls,
              if (bodyRu != null && bodyRu.trim().isNotEmpty) 'bodyRu': bodyRu.trim(),
            }),
          )
          .timeout(const Duration(seconds: 90));
      if (response.statusCode == 200) return true;
      debugPrint('EmailService: ${response.statusCode} ${response.body}');
      return false;
    } catch (e) {
      debugPrint('EmailService: $e');
      return false;
    }
  }
}
