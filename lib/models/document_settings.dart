import '../core/utils/formatters.dart';

/// Реквизиты компании и шаблоны Invoice / Estimate, которые уходят из приложения.
class DocumentSettings {
  final String companyName;
  final String companyPhone;
  final String companyEmail;
  final String companyAddress;
  final String hstNumber;
  final String invoiceSms;
  final String estimateSms;
  final String receiptSms;
  final String invoiceTerms;
  final String estimateTerms;
  final int estimateValidDays;
  final String logoUrl;
  final String smsHeader;
  final String paySms;
  final bool invoiceShowLogo;
  final bool invoiceShowQr;
  final bool invoiceShowPayments;
  final int invoiceAccent;
  final String documentPrefix;
  final int nextInvoiceNumber;
  final int nextEstimateNumber;

  const DocumentSettings({
    required this.companyName,
    required this.companyPhone,
    required this.companyEmail,
    required this.companyAddress,
    required this.hstNumber,
    required this.invoiceSms,
    required this.estimateSms,
    required this.receiptSms,
    required this.invoiceTerms,
    required this.estimateTerms,
    required this.estimateValidDays,
    this.logoUrl = '',
    this.smsHeader = kDefaultSmsHeader,
    this.paySms = kDefaultPaySms,
    this.invoiceShowLogo = true,
    this.invoiceShowQr = true,
    this.invoiceShowPayments = true,
    this.invoiceAccent = 0xFF14557F,
    this.documentPrefix = '',
    this.nextInvoiceNumber = 1,
    this.nextEstimateNumber = 1,
  });

  static const String kDefaultSmsHeader = 'fix-appliance.ca';
  static const String kDefaultPaySms =
      'Thank you for choosing {company}.\n\nPlease pay {amount} for your repair.\n\nOpen this page to pay:\n{url}';

  static String compactHeaderKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');
  }

  /// Название компании и «FIX ApplianceCA» не являются шапкой SMS.
  /// Строка с точкой (домен) — нормальная шапка, её не трогаем.
  static bool isBannedSmsHeader(String value, {String companyName = ''}) {
    final raw = value.trim();
    if (raw.isEmpty) return false;
    if (raw.contains('.')) return false;
    final compact = compactHeaderKey(raw);
    if (compact == 'fixapplianceca' || compact == 'fixappliance') return true;
    final company = companyName.trim();
    if (company.isNotEmpty &&
        !company.contains('.') &&
        compact == compactHeaderKey(company)) {
      return true;
    }
    return false;
  }

  static String sanitizeSmsHeader(String value, {String companyName = ''}) {
    final header = value.trim();
    if (header.isEmpty || isBannedSmsHeader(header, companyName: companyName)) {
      return '';
    }
    if (header.toLowerCase() == 'fixappliance.ca') return 'fix-appliance.ca';
    return header;
  }

  String get effectiveSmsHeader =>
      sanitizeSmsHeader(smsHeader, companyName: companyName);

  DocumentSettings copyWith({
    String? companyName,
    String? companyPhone,
    String? companyEmail,
    String? companyAddress,
    String? hstNumber,
    String? invoiceSms,
    String? estimateSms,
    String? receiptSms,
    String? invoiceTerms,
    String? estimateTerms,
    int? estimateValidDays,
    String? logoUrl,
    String? smsHeader,
    String? paySms,
    bool? invoiceShowLogo,
    bool? invoiceShowQr,
    bool? invoiceShowPayments,
    int? invoiceAccent,
    String? documentPrefix,
    int? nextInvoiceNumber,
    int? nextEstimateNumber,
  }) {
    return DocumentSettings(
      companyName: companyName ?? this.companyName,
      companyPhone: companyPhone ?? this.companyPhone,
      companyEmail: companyEmail ?? this.companyEmail,
      companyAddress: companyAddress ?? this.companyAddress,
      hstNumber: hstNumber ?? this.hstNumber,
      invoiceSms: invoiceSms ?? this.invoiceSms,
      estimateSms: estimateSms ?? this.estimateSms,
      receiptSms: receiptSms ?? this.receiptSms,
      invoiceTerms: invoiceTerms ?? this.invoiceTerms,
      estimateTerms: estimateTerms ?? this.estimateTerms,
      estimateValidDays: estimateValidDays ?? this.estimateValidDays,
      logoUrl: logoUrl ?? this.logoUrl,
      smsHeader: smsHeader ?? this.smsHeader,
      paySms: paySms ?? this.paySms,
      invoiceShowLogo: invoiceShowLogo ?? this.invoiceShowLogo,
      invoiceShowQr: invoiceShowQr ?? this.invoiceShowQr,
      invoiceShowPayments: invoiceShowPayments ?? this.invoiceShowPayments,
      invoiceAccent: invoiceAccent ?? this.invoiceAccent,
      documentPrefix: documentPrefix ?? this.documentPrefix,
      nextInvoiceNumber: nextInvoiceNumber ?? this.nextInvoiceNumber,
      nextEstimateNumber: nextEstimateNumber ?? this.nextEstimateNumber,
    );
  }

  /// Шапка, пустая строка, затем текст. Если шапка пустая — уходит только текст.
  String wrapOutgoingMessage(String body) {
    final text = _stripExistingHeader(body.trim());
    if (text.isEmpty) return '';
    final header = effectiveSmsHeader;
    if (header.isEmpty) return text;
    return '$header\n\n$text';
  }

  String _stripExistingHeader(String text) {
    if (text.isEmpty) return text;
    final lines = text.split(RegExp(r'\r?\n'));
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }
      final lower = line.toLowerCase();
      final isHeader = lower == effectiveSmsHeader.toLowerCase() ||
          lower == smsHeader.trim().toLowerCase() ||
          isBannedSmsHeader(line, companyName: companyName);
      if (!isHeader) break;
      i++;
    }
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    return lines.skip(i).join('\n').trim();
  }

  static const defaults = DocumentSettings(
    companyName: 'Fix Appliance',
    companyPhone: '',
    companyEmail: '',
    companyAddress: 'Waterford, Ontario',
    hstNumber: '',
    invoiceSms:
        'Hi {name}, your invoice {total} is ready. Amount due: {due}.\nDownload: {url}',
    estimateSms:
        'Hi {name}, here is your estimate {total}. Tap the link to confirm the repair:\n{url}',
    receiptSms:
        'Hi {name}, thank you for your payment of {total}. Download your paid invoice:\n{url}',
    invoiceTerms:
        'Payment is due upon completion of work. HST/GST is included when shown on this invoice.',
    estimateTerms:
        'This estimate is preliminary. The price may change after diagnosis.',
    estimateValidDays: 30,
    logoUrl: '',
    smsHeader: kDefaultSmsHeader,
    paySms: kDefaultPaySms,
    invoiceShowLogo: true,
    invoiceShowQr: true,
    invoiceShowPayments: true,
    invoiceAccent: 0xFF14557F,
    documentPrefix: '',
    nextInvoiceNumber: 1,
    nextEstimateNumber: 1,
  );

  factory DocumentSettings.fromMap(Map<String, dynamic>? data) {
    final map = data ?? const <String, dynamic>{};
    int validDays = defaults.estimateValidDays;
    final rawDays = map['estimateValidDays'];
    if (rawDays is int) validDays = rawDays;
    if (rawDays is num) validDays = rawDays.toInt();
    return DocumentSettings(
      companyName: (map['companyName'] ?? defaults.companyName).toString(),
      companyPhone: (map['companyPhone'] ?? defaults.companyPhone).toString(),
      companyEmail: (map['companyEmail'] ?? defaults.companyEmail).toString(),
      companyAddress: (map['companyAddress'] ?? defaults.companyAddress).toString(),
      hstNumber: (map['hstNumber'] ?? defaults.hstNumber).toString(),
      invoiceSms: (map['invoiceSms'] ?? defaults.invoiceSms).toString(),
      estimateSms: (map['estimateSms'] ?? defaults.estimateSms).toString(),
      receiptSms: (map['receiptSms'] ?? defaults.receiptSms).toString(),
      invoiceTerms: (map['invoiceTerms'] ?? defaults.invoiceTerms).toString(),
      estimateTerms: (map['estimateTerms'] ?? defaults.estimateTerms).toString(),
      estimateValidDays: validDays <= 0 ? defaults.estimateValidDays : validDays,
      logoUrl: (map['logoUrl'] ?? defaults.logoUrl).toString(),
      smsHeader: sanitizeSmsHeader(
        map['smsHeader'] == null ? kDefaultSmsHeader : map['smsHeader'].toString(),
        companyName: (map['companyName'] ?? defaults.companyName).toString(),
      ),
      paySms: (map['paySms'] ?? defaults.paySms).toString(),
      invoiceShowLogo: map['invoiceShowLogo'] != false,
      invoiceShowQr: map['invoiceShowQr'] != false,
      invoiceShowPayments: map['invoiceShowPayments'] != false,
      invoiceAccent: (map['invoiceAccent'] as num?)?.toInt() ?? defaults.invoiceAccent,
      documentPrefix: (map['documentPrefix'] ?? defaults.documentPrefix).toString(),
      nextInvoiceNumber: (map['nextInvoiceNumber'] as num?)?.toInt() ?? defaults.nextInvoiceNumber,
      nextEstimateNumber: (map['nextEstimateNumber'] as num?)?.toInt() ?? defaults.nextEstimateNumber,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'companyName': companyName,
      'companyPhone': companyPhone,
      'companyEmail': companyEmail,
      'companyAddress': companyAddress,
      'hstNumber': hstNumber,
      'invoiceSms': invoiceSms,
      'estimateSms': estimateSms,
      'receiptSms': receiptSms,
      'invoiceTerms': invoiceTerms,
      'estimateTerms': estimateTerms,
      'estimateValidDays': estimateValidDays,
      'logoUrl': logoUrl,
      'smsHeader': smsHeader,
      'paySms': paySms,
      'invoiceShowLogo': invoiceShowLogo,
      'invoiceShowQr': invoiceShowQr,
      'invoiceShowPayments': invoiceShowPayments,
      'invoiceAccent': invoiceAccent,
      'documentPrefix': documentPrefix,
      'nextInvoiceNumber': nextInvoiceNumber,
      'nextEstimateNumber': nextEstimateNumber,
    };
  }

  String templateFor(String kind) {
    switch (kind) {
      case 'estimate':
        return estimateSms;
      case 'receipt':
        return receiptSms;
      default:
        return invoiceSms;
    }
  }

  String termsFor(String kind) {
    return kind == 'estimate' ? estimateTerms : invoiceTerms;
  }

  String formattedNumber(int number) {
    final prefix = documentPrefix.trim();
    final digits = number.toString().padLeft(4, '0');
    return prefix.isEmpty ? digits : '$prefix$digits';
  }

  String titleFor(String kind) {
    switch (kind) {
      case 'estimate':
        return 'Estimate';
      case 'receipt':
        return 'Receipt';
      default:
        return 'Invoice';
    }
  }

  static String stripePaySms({
    required bool deposit,
    required String dollars,
    required String url,
    String company = 'FIX-Appliance CA',
    String template = kDefaultPaySms,
  }) {
    final amount = '\$$dollars';
    final kindLine = deposit
        ? 'Please pay a $amount deposit for your repair.'
        : 'Please pay $amount for your repair.';
    final rendered = template
        .replaceAll('{company}', company)
        .replaceAll('{amount}', amount)
        .replaceAll('{url}', url)
        .replaceAll('{name}', '')
        .trim();
    if (rendered.contains(url) && rendered.contains(amount)) return rendered;
    return 'Thank you for choosing $company.\n\n$kindLine\n\nOpen this page to pay:\n$url';
  }

  String renderSms({
    required String kind,
    required String clientName,
    required double total,
    required double due,
    required double paid,
    required List<dynamic> items,
    String url = '',
  }) {
    return applyPlaceholders(
      templateFor(kind),
      clientName: clientName,
      total: total,
      due: due,
      paid: paid,
      items: items,
      url: url,
    );
  }

  String applyPlaceholders(
    String template, {
    required String clientName,
    required double total,
    required double due,
    required double paid,
    required List<dynamic> items,
    String url = '',
  }) {
    return template
        .replaceAll('{name}', clientName)
        .replaceAll('{company}', companyName)
        .replaceAll('{phone}', companyPhone)
        .replaceAll('{email}', companyEmail)
        .replaceAll('{address}', companyAddress)
        .replaceAll('{hst}', hstNumber)
        .replaceAll('{total}', Formatters.formatCurrency(total))
        .replaceAll('{due}', Formatters.formatCurrency(due))
        .replaceAll('{paid}', Formatters.formatCurrency(paid))
        .replaceAll('{items}', formatItems(items))
        .replaceAll('{valid_days}', '$estimateValidDays')
        .replaceAll('{url}', url)
        .trim();
  }

  static String formatItems(List<dynamic> items) {
    if (items.isEmpty) return '';
    return items.map((item) {
      final map = item is Map ? Map<String, dynamic>.from(item) : <String, dynamic>{};
      final name = (map['name'] ?? 'Item').toString();
      final qty = (map['qty'] as num?)?.toDouble() ?? 1;
      final price = (map['price'] as num?)?.toDouble() ?? 0;
      final line = qty * price;
      if (qty == 1) {
        return '• $name ${Formatters.formatCurrency(line)}';
      }
      return '• $name × ${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1)} ${Formatters.formatCurrency(line)}';
    }).join('\n');
  }
}
