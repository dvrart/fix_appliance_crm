import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../services/services.dart';
import '../../shared/widgets/confirm_action_sheet.dart';

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
    final who = name.trim().isEmpty ? 'there' : name.trim();
    final template =
        templates['job_done'] ?? SettingsService.defaultJobDoneSms;
    var body = template
        .replaceAll('{name}', who)
        .replaceAll('{date}', '')
        .replaceAll('{time}', '')
        .replaceAll('{address}', address.trim())
        .replaceAll('{review}', reviewUrl)
        .replaceAll('{appliance}', '')
        .trim();
    if (reviewUrl.isNotEmpty && !body.contains(reviewUrl)) {
      body = '$body $reviewUrl'.trim();
    }

    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: clientId,
    );
    if (!context.mounted) return ok;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'SMS с просьбой об отзыве отправлено'.tr
              : 'Не удалось отправить SMS'.tr,
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
    return ok;
  }
}
