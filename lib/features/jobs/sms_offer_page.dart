import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../services/ai_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../ai/job_preview_screen.dart';
import 'job_details/job_details_screen.dart';

/// SMS-заявка на ремонт: показать текст и предложить создать карточку клиента.
class SmsOfferPage {
  static Future<void> open(
    BuildContext context, {
    required String messageId,
    SmsMessage? message,
  }) async {
    final id = messageId.trim().isNotEmpty ? messageId.trim() : (message?.id ?? '');
    if (id.isEmpty) return;
    final loaded = message ?? await SmsService.getById(id);
    if (!context.mounted) return;
    if (loaded == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('SMS не найдено', 'SMS not found'))),
      );
      return;
    }

    // Если заявка уже создана — открываем её
    final jobId = (loaded.jobId ?? '').trim();
    if (jobId.isNotEmpty && !loaded.smsOfferPending) {
      final job = await JobService.getById(jobId);
      if (!context.mounted) return;
      if (job != null) {
        await Navigator.of(context, rootNavigator: true).push(
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

    final extracted = loaded.extractedData != null && loaded.extractedData!.isNotEmpty
        ? ExtractedJobData.fromJson(loaded.extractedData!)
        : ExtractedJobData(
            clientPhone: loaded.from.contains('+') ? loaded.from : null,
            problemDescription: loaded.displayBody,
          );

    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => JobPreviewScreen(
          extractedData: extracted,
          originalText: loaded.displayBody,
          fallbackPhone: loaded.from.isNotEmpty ? loaded.from : null,
          existingClientId: loaded.clientId,
          sourceSmsId: loaded.id,
        ),
      ),
    );
  }
}
