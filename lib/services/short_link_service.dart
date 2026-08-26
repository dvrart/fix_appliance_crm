import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';

class ShortLink {
  final String url;
  final String code;
  final String carrierUrl;

  const ShortLink({
    required this.url,
    required this.code,
    this.carrierUrl = '',
  });

  String get smsCarrier {
    if (carrierUrl.startsWith('http')) return carrierUrl;
    final c = code.trim();
    if (c.isEmpty) return '';
    return '$kFirebaseFunctionsUrl/p/${Uri.encodeComponent(c)}';
  }
}

/// Short https links that redirect to Stripe checkout or a PDF in Storage.
class ShortLinkService {
  static Future<ShortLink> ensure({
    required String targetUrl,
    String? code,
    String type = '',
    String jobId = '',
  }) async {
    final original = targetUrl.trim();
    if (original.isEmpty) {
      return ShortLink(url: original, code: code ?? '');
    }
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/shortenLink'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'url': original,
              if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
              if (type.isNotEmpty) 'type': type,
              if (jobId.isNotEmpty) 'jobId': jobId,
            }),
          )
          .timeout(const Duration(seconds: 15));
      final body = response.body.isNotEmpty
          ? json.decode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final shortUrl = (body['shortUrl'] ?? '').toString().trim();
      final nextCode = (body['code'] ?? code ?? '').toString().trim();
      if (response.statusCode == 200 &&
          body['success'] == true &&
          shortUrl.isNotEmpty) {
        return ShortLink(
          url: shortUrl,
          code: nextCode,
          carrierUrl: (body['carrierUrl'] ?? '').toString().trim().isNotEmpty
              ? (body['carrierUrl'] ?? '').toString().trim()
              : (nextCode.isEmpty
                  ? ''
                  : '$kFirebaseFunctionsUrl/p/${Uri.encodeComponent(nextCode)}'),
        );
      }
      debugPrint('ShortLinkService: ${body['error'] ?? response.statusCode}');
    } catch (error) {
      debugPrint('ShortLinkService: $error');
    }
    return ShortLink(url: original, code: code ?? '');
  }
}
