import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/api_keys.dart';

/// Результат создания Stripe-инвойса, депозита или Checkout-ссылки.
class StripePaymentLink {
  final String url;
  final String rawUrl;
  final String kind;
  final double amount;
  final bool smsSent;
  final String? smsError;
  final String? invoiceId;
  final String? checkoutSessionId;

  StripePaymentLink({
    required this.url,
    this.rawUrl = '',
    required this.kind,
    required this.amount,
    this.smsSent = false,
    this.smsError,
    this.invoiceId,
    this.checkoutSessionId,
  });

  String get smsUrl {
    final raw = rawUrl.trim();
    if (raw.startsWith('http')) return raw;
    return url;
  }
}

/// Клиент Stripe через Firebase Functions: секреты остаются на сервере.
class StripeService {
  /// [kind]:
  /// - `invoice` — Stripe Invoice (hosted invoice URL, письмо если есть email)
  /// - `deposit` — Checkout на указанную сумму
  /// - `checkout` — Checkout на остаток по документу
  static Future<StripePaymentLink> createPayment({
    required String jobId,
    required int documentIndex,
    required String kind,
    double? amount,
    bool sendSms = true,
    bool sendEmail = true,
    double tip = 0,
    String? to,
  }) async {
    final response = await http.post(
      Uri.parse('$kFirebaseFunctionsUrl/createStripePayment'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'jobId': jobId,
        'documentIndex': documentIndex,
        'kind': kind,
        'amount': amount,
        'tip': tip,
        'sendSms': sendSms,
        'sendEmail': sendEmail,
        if (to != null && to.trim().isNotEmpty) 'to': to.trim(),
      }),
    );

    final body = response.body.isNotEmpty
        ? json.decode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode != 200 || body['success'] != true) {
      final message = (body['error'] ?? 'Stripe: ${response.statusCode}').toString();
      debugPrint('StripeService: $message');
      throw StripeServiceException(message);
    }

    return StripePaymentLink(
      url: body['url'] as String,
      rawUrl: (body['rawUrl'] ?? '').toString(),
      kind: (body['kind'] ?? kind).toString(),
      amount: (body['amount'] as num?)?.toDouble() ?? amount ?? 0,
      smsSent: body['smsSent'] == true,
      smsError: body['smsError']?.toString(),
      invoiceId: body['invoiceId']?.toString(),
      checkoutSessionId: body['checkoutSessionId']?.toString(),
    );
  }

  /// Connection token + Location для Stripe Terminal (Tap to Pay).
  static Future<StripeTerminalConnection> createConnectionToken() async {
    final body = await _postJson('/createTerminalConnectionToken', {});
    return StripeTerminalConnection(
      secret: body['secret'] as String,
      locationId: body['locationId'] as String,
      simulated: body['simulated'] == true,
    );
  }

  /// PaymentIntent для оплаты картой на месте (NFC / Tap to Pay).
  static Future<StripeTerminalPaymentIntent> createTerminalPaymentIntent({
    required String jobId,
    required int documentIndex,
    double? amount,
    double tip = 0,
  }) async {
    final body = await _postJson('/createTerminalPaymentIntent', {
      'jobId': jobId,
      'documentIndex': documentIndex,
      if (amount != null) 'amount': amount,
      if (tip > 0) 'tip': tip,
    });
    return StripeTerminalPaymentIntent(
      clientSecret: body['clientSecret'] as String,
      paymentIntentId: body['paymentIntentId'] as String,
      amount: (body['amount'] as num?)?.toDouble() ?? 0,
      due: (body['due'] as num?)?.toDouble() ?? (body['amount'] as num?)?.toDouble() ?? 0,
      simulated: body['simulated'] == true,
    );
  }

  /// Записать успешный Tap to Pay в заявку, не дожидаясь webhook.
  static Future<StripeTerminalComplete> completeTerminalPayment({
    required String paymentIntentId,
  }) async {
    final body = await _postJson('/completeTerminalPayment', {
      'paymentIntentId': paymentIntentId,
    });
    return StripeTerminalComplete(
      amount: (body['amount'] as num?)?.toDouble() ?? 0,
      paymentIntentId: (body['paymentIntentId'] ?? paymentIntentId).toString(),
    );
  }

  static Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await http.post(
      Uri.parse('$kFirebaseFunctionsUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );
    final body = response.body.isNotEmpty
        ? json.decode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};
    if (response.statusCode != 200 || body['success'] != true) {
      final message = (body['error'] ?? 'Stripe: ${response.statusCode}').toString();
      debugPrint('StripeService$path: $message');
      throw StripeServiceException(message);
    }
    return body;
  }

  static Future<StripeAccountBalance> fetchBalance() async {
    final body = await _postJson('/getStripeBalance', {});
    return StripeAccountBalance(
      available: (body['available'] as num?)?.toDouble() ?? 0,
      pending: (body['pending'] as num?)?.toDouble() ?? 0,
      currency: (body['currency'] ?? 'CAD').toString(),
      livemode: body['livemode'] == true,
    );
  }
}

class StripeAccountBalance {
  final double available;
  final double pending;
  final String currency;
  final bool livemode;

  StripeAccountBalance({
    required this.available,
    required this.pending,
    required this.currency,
    required this.livemode,
  });
}

class StripeTerminalConnection {
  final String secret;
  final String locationId;
  final bool simulated;

  StripeTerminalConnection({
    required this.secret,
    required this.locationId,
    required this.simulated,
  });
}

class StripeTerminalPaymentIntent {
  final String clientSecret;
  final String paymentIntentId;
  final double amount;
  final double due;
  final bool simulated;

  StripeTerminalPaymentIntent({
    required this.clientSecret,
    required this.paymentIntentId,
    required this.amount,
    required this.due,
    required this.simulated,
  });
}

class StripeTerminalComplete {
  final double amount;
  final String paymentIntentId;

  StripeTerminalComplete({
    required this.amount,
    required this.paymentIntentId,
  });
}

class StripeServiceException implements Exception {
  final String message;
  StripeServiceException(this.message);

  @override
  String toString() => message;
}
