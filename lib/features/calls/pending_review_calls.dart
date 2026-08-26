import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../services/ai_service.dart';
import '../../services/job_service.dart';
import '../../services/twilio_service.dart';
import '../ai/job_preview_screen.dart';
import '../ai/post_call_screen.dart';
import '../jobs/job_details/job_details_screen.dart';
import 'call_review_page.dart';

/// Звонок секретаря, который мастер ещё не проверил.
class PendingReviewCallCard extends StatelessWidget {
  final CallRecord call;
  final VoidCallback? onChanged;

  const PendingReviewCallCard({
    super.key,
    required this.call,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    call.isIncoming ? Icons.phone_callback : Icons.phone_forwarded,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        call.isIncoming ? call.fromNumber : call.toNumber,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        call.startTime != null
                            ? Formatters.formatDateTime(call.startTime)
                            : '',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Новое'.tr,
                    style: TextStyle(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            if (call.transcription != null && call.transcription!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  call.transcription!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => CallReviewPage.open(
                  context,
                  callId: call.id,
                  call: call,
                ),
                icon: const Icon(Icons.headphones, size: 18),
                label: Text('Запись, текст и ошибка'.tr),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await TwilioService.markReviewed(call.id);
                      onChanged?.call();
                    },
                    icon: const Icon(Icons.skip_next),
                    label: Text('Пропустить'.tr),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.grey),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => reviewCall(context, call, onChanged: onChanged),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      call.createdJobId != null && call.createdJobId!.isNotEmpty
                          ? 'Открыть заявку'.tr
                          : 'Создать заявку'.tr,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> reviewCall(
  BuildContext context,
  CallRecord call, {
  VoidCallback? onChanged,
}) async {
  if (call.createdJobId != null && call.createdJobId!.isNotEmpty) {
    final job = await JobService.getById(call.createdJobId!);
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
      final latest = await JobService.getById(job.id);
      if (latest != null && !latest.needsReview) {
        await TwilioService.markReviewed(call.id);
        onChanged?.call();
      }
      return;
    }
  }

  ExtractedJobData extractedData;
  if (call.extractedData != null && call.extractedData!.isNotEmpty) {
    extractedData = ExtractedJobData.fromJson(call.extractedData!);
  } else if (call.transcription != null && call.transcription!.isNotEmpty) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('ИИ анализирует разговор...'.tr),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      extractedData = await AiService.extractJobData(call.transcription!);
    } catch (error) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${'Ошибка ИИ'.tr}: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  } else {
    if (!context.mounted) return;
    final dictated = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(builder: (_) => const PostCallScreen()),
    );
    if (dictated == true) {
      await TwilioService.markReviewed(call.id);
      onChanged?.call();
    }
    return;
  }

  if (!context.mounted) return;
  final result = await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      builder: (_) => JobPreviewScreen(
        extractedData: extractedData,
        originalText: call.transcription ?? '',
        fallbackPhone: call.isIncoming ? call.fromNumber : call.toNumber,
      ),
    ),
  );

  if (result == true) {
    await TwilioService.markReviewed(call.id);
    onChanged?.call();
  }
}
