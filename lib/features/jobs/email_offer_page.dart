import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../services/ai_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../ai/job_preview_screen.dart';
import 'job_details/job_details_screen.dart';

/// Offer from a repair email: create a client card and a visit.
class EmailOfferPage {
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
        SnackBar(content: Text(context.tr('Письмо не найдено', 'Email not found'))),
      );
      return;
    }
    final jobId = (loaded.jobId ?? '').trim();
    if (jobId.isNotEmpty && !loaded.emailOfferPending) {
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
            clientEmail: loaded.isWebsiteFormMail
                ? (loaded.replyToEmail.contains('@') ? loaded.replyToEmail : null)
                : loaded.counterpartEmail,
            problemDescription: loaded.body,
          );
    final website = loaded.isWebsiteFormMail;
    final from = website
        ? (loaded.replyToEmail.contains('@')
            ? loaded.replyToEmail
            : (extracted.clientEmail ?? ''))
        : (loaded.counterpartEmail.isNotEmpty
            ? loaded.counterpartEmail
            : loaded.from);
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => JobPreviewScreen(
          extractedData: extracted,
          originalText: [
            if (loaded.subject.trim().isNotEmpty) loaded.subject.trim(),
            loaded.body.trim(),
          ].where((line) => line.isNotEmpty).join('\n\n'),
          fallbackEmail: from.contains('@') ? from : extracted.clientEmail,
          existingClientId: website ? null : loaded.clientId,
          sourceMessageId: loaded.id,
          sourceEmailFrom: from,
          sourceEmailSubject: loaded.subject,
        ),
      ),
    );
  }
}
