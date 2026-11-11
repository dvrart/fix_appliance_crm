import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../core/sms_text.dart';
import '../../services/services.dart';
import '../../shared/widgets/confirm_action_sheet.dart';

final _linkRe = RegExp(r'https?://', caseSensitive: false);

bool _hasLink(String text) => _linkRe.hasMatch(text);

class JobReviewOffer {
  static Future<void> askAndSend(
    BuildContext context, {
    required String phone,
    required String name,
    required String address,
    required String clientId,
    String jobId = '',
  }) async {
    if (!context.mounted) return;
    final action = await showConfirmActionSheet(
      context,
      title: 'Попросить отзыв?'.tr,
      message:
          'Клиент оплатил счёт. Отправить SMS со ссылкой на Google-отзыв?'.tr,
      saveLabel: 'Отправить'.tr,
      stayLabel: 'Позже'.tr,
    );
    if (action == UnsavedChangesAction.save && context.mounted) {
      await send(
        context,
        phone: phone,
        name: name,
        address: address,
        clientId: clientId,
        jobId: jobId,
      );
    }
    if (jobId.isEmpty) return;
    try {
      await JobService.update(jobId, {
        'reviewSmsSentAt': FieldValue.serverTimestamp(),
        'requestReviewSms': FieldValue.delete(),
        'reviewSmsDueAt': FieldValue.delete(),
      });
    } catch (_) {}
  }

  static Future<bool> send(
    BuildContext context, {
    required String phone,
    required String name,
    required String address,
    required String clientId,
    String jobId = '',
  }) async {
    if (phone.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Нет телефона для SMS'.tr),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return false;
    }

    final config = await SettingsService.loadConfig();
    final templates = await SettingsService.loadSmsTemplates();
    final reviewUrl = SettingsService.readGoogleReviewUrl(config);
    final template =
        templates['job_done'] ?? SettingsService.defaultJobDoneSms;
    var body = SmsText.fillName(template, name);
    body = SmsText.replacePlaceholder(body, 'date', '');
    body = SmsText.replacePlaceholder(body, 'time', '');
    body = SmsText.replacePlaceholder(body, 'address', address.trim());
    body = SmsText.replacePlaceholder(body, 'review', reviewUrl);
    body = SmsText.replacePlaceholder(body, 'url', reviewUrl);
    body = SmsText.replacePlaceholder(body, 'appliance', '');
    body = body.trim();
    // Дописываем ссылку, только если в тексте её вообще нет. Раньше сравнивали
    // с адресом из настроек, и шаблон с вписанной руками ссылкой получал вторую.
    if (reviewUrl.isNotEmpty && !_hasLink(body)) {
      body = '$body $reviewUrl'.trim();
    }

    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: clientId,
      jobId: jobId.trim().isEmpty ? null : jobId.trim(),
    );
    if (!context.mounted) return ok;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'SMS с просьбой об отзыве отправлено'.tr
              : SmsService.failureText(),
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
    return ok;
  }
}
