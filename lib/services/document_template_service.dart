import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/l10n/app_locale.dart';
import '../core/utils/formatters.dart';
import '../models/document_settings.dart';
import '../shared/widgets/keyboard_safe.dart';
import 'job_service.dart';
import 'outbound_media_service.dart';
import 'settings_service.dart';
import 'sms_service.dart';

class DocumentSendData {
  final String kind;
  final String jobId;
  final String clientId;
  final String clientName;
  final String clientPhone;
  final String clientAddress;
  final int documentNumber;
  final List<dynamic> items;
  final double subtotal;
  final double tax;
  final double taxRate;
  final double total;
  final double paid;
  final double due;
  final List<Map<String, dynamic>> payments;
  final String subject;
  final DateTime? serviceDate;
  final String clientEmail;
  final String clientCompany;
  final Future<void> Function(String url)? persistPdfUrl;

  const DocumentSendData({
    required this.kind,
    required this.jobId,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    required this.clientAddress,
    required this.documentNumber,
    required this.items,
    required this.subtotal,
    required this.tax,
    required this.taxRate,
    required this.total,
    required this.paid,
    required this.due,
    this.payments = const [],
    this.subject = '',
    this.serviceDate,
    this.clientEmail = '',
    this.clientCompany = '',
    this.persistPdfUrl,
  });
}

/// Счёт и смета из приложения: SMS по шаблону из настроек + PDF.
class DocumentTemplateService {
  static Future<void> showSendSheet({
    required BuildContext context,
    required DocumentSendData data,
  }) async {
    final settings = await SettingsService.loadDocumentSettings();
    if (!context.mounted) return;

    final preview = TextEditingController(
      text: settings.wrapOutgoingMessage(
        settings.renderSms(
          kind: data.kind,
          clientName: data.clientName,
          total: data.total,
          due: data.due,
          paid: data.paid,
          items: data.items,
          url: '{url}',
        ),
      ),
    );

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) {
          return KeyboardAvoidingSheet(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _sheetTitle(data.kind),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF14557F),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Клиенту уйдёт SMS на английском: ссылка на PDF или сам файл.'.tr,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: preview,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: 'Текст SMS'.tr,
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await _sendDocumentSms(
                              context: context,
                              settings: settings,
                              data: data,
                              body: preview.text.trim(),
                              asFile: false,
                            );
                          },
                          icon: const Icon(Icons.link),
                          label: Text('Отправить ссылку'.tr),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF14557F),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        await _sendDocumentSms(
                          context: context,
                          settings: settings,
                          data: data,
                          body: preview.text.trim(),
                          asFile: true,
                        );
                      },
                      icon: const Icon(Icons.picture_as_pdf),
                      label: Text('Отправить PDF'.tr),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF14557F),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      preview.dispose();
    }
  }

  static Future<String> _ensurePdfUrl({
    required DocumentSettings settings,
    required DocumentSendData data,
  }) async {
    final bytes = await buildPdf(settings: settings, data: data);
    final url = await OutboundMediaService.upload(
      OutboundAttachment(
        name: _fileName(data),
        mime: 'application/pdf',
        bytes: bytes,
      ),
    );
    await data.persistPdfUrl?.call(url);
    return url;
  }

  static String _bodyWithUrl(String body, String url) {
    var text = body.trim();
    if (text.contains('{url}')) {
      text = text.replaceAll('{url}', url);
    } else if (url.isNotEmpty && !text.contains(url)) {
      text = '$text\n\nDownload:\n$url';
    }
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static String _bodyWithoutUrl(String body) {
    return body
        .replaceAll('{url}', '')
        .replaceAll(RegExp(r'\n*Download:\s*', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static Future<void> _sendDocumentSms({
    required BuildContext context,
    required DocumentSettings settings,
    required DocumentSendData data,
    required String body,
    required bool asFile,
  }) async {
    if (data.clientPhone.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('У клиента нет телефона'.tr)),
        );
      }
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    var ok = false;
    try {
      final pdfUrl = await _ensurePdfUrl(settings: settings, data: data);
      final text = asFile ? _bodyWithoutUrl(body) : _bodyWithUrl(body, pdfUrl);
      if (text.isEmpty && !asFile) {
        throw 'Текст SMS пустой'.tr;
      }
      ok = await SmsService.sendSms(
        to: data.clientPhone,
        body: text.isEmpty && asFile
            ? 'Hi ${data.clientName}, your invoice is attached.'
            : text,
        clientId: data.clientId,
        mediaUrls: asFile ? [pdfUrl] : const [],
      );
      if (!ok && asFile) {
        ok = await SmsService.sendSms(
          to: data.clientPhone,
          body: _bodyWithUrl(body, pdfUrl),
          clientId: data.clientId,
        );
      }
      await JobService.sendMessage(
        jobId: data.jobId,
        text: asFile
            ? (text.isEmpty ? 'Invoice PDF attached.' : text)
            : text,
        targetRole: 'Владелец'.tr,
        sender: 'company',
      );
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'SMS отправлено клиенту'.tr : 'Не удалось отправить SMS'.tr),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  /// After a payment: SMS the client a download link, no UI sheet.
  static Future<bool> sendPdfLinkQuietly({
    required DocumentSendData data,
  }) async {
    if (data.clientPhone.trim().isEmpty) return false;
    final settings = await SettingsService.loadDocumentSettings();
    try {
      final pdfUrl = await _ensurePdfUrl(settings: settings, data: data);
      final body = settings.wrapOutgoingMessage(
        settings.renderSms(
          kind: data.kind,
          clientName: data.clientName,
          total: data.total,
          due: data.due,
          paid: data.paid,
          items: data.items,
          url: pdfUrl,
        ),
      );
      final text = _bodyWithUrl(body, pdfUrl);
      if (text.isEmpty) return false;
      final ok = await SmsService.sendSms(
        to: data.clientPhone,
        body: text,
        clientId: data.clientId,
      );
      await JobService.sendMessage(
        jobId: data.jobId,
        text: text,
        targetRole: 'Владелец'.tr,
        sender: 'company',
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  static Future<void> sharePdf({
    required DocumentSettings settings,
    required DocumentSendData data,
  }) async {
    final bytes = await buildPdf(settings: settings, data: data);
    await Printing.sharePdf(
      bytes: bytes,
      filename: _fileName(data),
    );
  }

  static Future<void> printPdf({
    required DocumentSettings settings,
    required DocumentSendData data,
  }) async {
    final bytes = await buildPdf(settings: settings, data: data);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  static Future<Uint8List> buildPdf({
    required DocumentSettings settings,
    required DocumentSendData data,
  }) async {
    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final italic = await PdfGoogleFonts.notoSansItalic();
    final pdf = pw.Document();
    final primary = PdfColor.fromInt(settings.invoiceAccent);
    final issued = DateTime.now();
    final service = data.serviceDate ?? issued;
    pw.ImageProvider? logo;
    if (settings.invoiceShowLogo && settings.logoUrl.startsWith('http')) {
      try {
        final response = await http.get(Uri.parse(settings.logoUrl));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          logo = pw.MemoryImage(response.bodyBytes);
        }
      } catch (_) {}
    }
    final qrData = settings.effectiveSmsHeader.contains('.')
        ? (settings.effectiveSmsHeader.startsWith('http')
            ? settings.effectiveSmsHeader
            : 'https://${settings.effectiveSmsHeader}')
        : 'https://fixappliance.ca';
    final paidLabel = data.kind == 'estimate'
        ? 'Total'
        : (data.due <= 0 && data.paid > 0 ? 'Total Paid' : 'Amount Due');
    final paidValue = data.kind == 'estimate'
        ? data.total
        : (data.due <= 0 && data.paid > 0 ? data.paid : data.due);

    pw.Widget infoCol(String title, List<String> lines) {
      return pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title.toUpperCase(),
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 4),
            for (final line in lines.where((line) => line.trim().isNotEmpty))
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 1),
                child: pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
              ),
          ],
        ),
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.fromLTRB(36, 28, 36, 28),
          theme: pw.ThemeData.withFont(
            base: regular,
            bold: bold,
            italic: italic,
          ),
        ),
        footer: (context) {
          return pw.Column(
            children: [
              pw.SizedBox(height: 8),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  if (settings.invoiceShowQr)
                    pw.BarcodeWidget(
                      barcode: pw.Barcode.qrCode(),
                      data: qrData,
                      width: 52,
                      height: 52,
                    ),
                  if (settings.invoiceShowQr) pw.SizedBox(width: 12),
                  pw.Expanded(
                    child: pw.Text(
                      qrData.replaceFirst(RegExp(r'^https://'), ''),
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ),
                  pw.Text(
                    'Page ${context.pageNumber} of ${context.pagesCount}',
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: PdfColors.grey600,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
        build: (context) {
          return [
            pw.Container(height: 4, color: primary),
            pw.SizedBox(height: 16),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (logo != null) ...[
                  pw.Container(
                    width: 56,
                    height: 56,
                    child: pw.Image(logo, fit: pw.BoxFit.contain),
                  ),
                  pw.SizedBox(width: 12),
                ],
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        settings.companyName,
                        style: pw.TextStyle(
                          fontSize: 14,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      if (settings.companyEmail.isNotEmpty)
                        pw.Text(settings.companyEmail,
                            style: const pw.TextStyle(fontSize: 9)),
                      if (settings.companyPhone.isNotEmpty)
                        pw.Text(settings.companyPhone,
                            style: const pw.TextStyle(fontSize: 9)),
                      if (settings.hstNumber.isNotEmpty)
                        pw.Text(
                          '${data.taxRate == 0.05 ? 'GST' : 'HST'} ${settings.hstNumber}',
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                    ],
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      '#${data.documentNumber.toString().padLeft(6, '0')}',
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      Formatters.formatDateEn(issued),
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Text(
              data.subject.trim().isEmpty
                  ? '${settings.titleFor(data.kind)} for ${data.clientName}'
                  : data.subject.trim(),
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 14),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                infoCol('Customer', [
                  data.clientName,
                  data.clientCompany,
                  data.clientEmail,
                  data.clientPhone,
                  data.clientAddress,
                ]),
                pw.SizedBox(width: 12),
                infoCol('Invoice details', [
                  'PDF created ${Formatters.formatDateEn(issued)}',
                  'Amount  ${Formatters.formatCurrency(data.total)}',
                  'Service date  ${Formatters.formatDateEn(service)}',
                ]),
                pw.SizedBox(width: 12),
                infoCol('Payment', [
                  data.due <= 0 && data.paid > 0
                      ? 'Paid ${Formatters.formatDateEn(issued)}'
                      : 'Due ${Formatters.formatDateEn(issued)}',
                  Formatters.formatCurrency(paidValue),
                ]),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 10,
              ),
              headerDecoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey400),
                ),
              ),
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.center,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
              headers: const ['Items', 'Quantity', 'Price', 'Amount'],
              data: [
                for (final item in data.items)
                  [
                    (item is Map ? (item['name'] ?? 'Item') : 'Item').toString(),
                    _qty(item).toStringAsFixed(_qty(item) % 1 == 0 ? 0 : 1),
                    Formatters.formatCurrency(_price(item)),
                    Formatters.formatCurrency(_qty(item) * _price(item)),
                  ],
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.SizedBox(
                width: 240,
                child: pw.Column(
                  children: [
                    _pdfTotalRow('Subtotal', Formatters.formatCurrency(data.subtotal)),
                    _pdfTotalRow(
                      _pdfTaxLabel(data.taxRate),
                      Formatters.formatCurrency(data.tax),
                    ),
                    pw.Divider(),
                    _pdfTotalRow(
                      paidLabel,
                      Formatters.formatCurrency(paidValue),
                      bold: true,
                    ),
                  ],
                ),
              ),
            ),
            if (settings.invoiceShowPayments && data.payments.isNotEmpty) ...[
              pw.SizedBox(height: 18),
              pw.Text(
                'Payments',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12),
              ),
              pw.SizedBox(height: 6),
              for (final payment in data.payments)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        [
                          (payment['date'] ?? '').toString().split('T').first,
                          (payment['method'] ?? 'Payment').toString(),
                        ].where((part) => part.trim().isNotEmpty).join('  ·  '),
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                      pw.Text(
                        Formatters.formatCurrency(
                          (payment['amount'] as num?)?.toDouble() ?? 0,
                        ),
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
            ],
            pw.SizedBox(height: 20),
            pw.Text(
              settings.termsFor(data.kind),
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            if (data.kind == 'estimate')
              pw.Text(
                'Valid for ${settings.estimateValidDays} days.',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
              ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static String _sheetTitle(String kind) {
    switch (kind) {
      case 'estimate':
        return 'Отправить смету'.tr;
      case 'receipt':
        return 'Отправить чек'.tr;
      default:
        return 'Отправить счёт'.tr;
    }
  }

  static String _fileName(DocumentSendData data) {
    final type = data.kind == 'estimate'
        ? 'Estimate'
        : (data.kind == 'receipt' ? 'Receipt' : 'Invoice');
    return 'FixAppliance-$type-${data.documentNumber}.pdf';
  }

  static double _qty(dynamic item) {
    if (item is Map) return (item['qty'] as num?)?.toDouble() ?? 1;
    return 1;
  }

  static double _price(dynamic item) {
    if (item is Map) return (item['price'] as num?)?.toDouble() ?? 0;
    return 0;
  }

  static String _pdfTaxLabel(double rate) {
    if ((rate - 0.13).abs() < 0.0001) return 'HST (13%)';
    if ((rate - 0.05).abs() < 0.0001) return 'GST (5%)';
    if (rate <= 0) return 'Tax (0%)';
    return 'Tax (${(rate * 100).round()}%)';
  }

  static pw.Widget _pdfTotalRow(String label, String value, {bool bold = false}) {
    final style = pw.TextStyle(
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontSize: bold ? 12 : 10,
    );
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: style),
          pw.Text(value, style: style),
        ],
      ),
    );
  }
}
