import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../models/job.dart';
import '../../services/services.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../../core/l10n/app_locale.dart';

class PartsQueueScreen extends StatelessWidget {
  const PartsQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Ожидаемые запчасти'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<Job>>(
        stream: JobService.streamByStatus(JobStatuses.waitingPart),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          final jobs = snapshot.data!;
          if (jobs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Нет заявок в ожидании запчасти'.tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            );
          }
          jobs.sort(
            (a, b) => (a.scheduledAt ?? a.createdAt)
                .compareTo(b.scheduledAt ?? b.createdAt),
          );
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: jobs.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final job = jobs[index];
              final parts = job.expectedParts;
              final partLabel = parts.isEmpty
                  ? 'Запчасть не указана'.tr
                  : parts.join(', ');
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => JobDetailsScreen(
                          jobId: job.id,
                          clientId: job.clientId,
                          jobData: job.toMap(),
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: AppColors.accent.withValues(alpha: 0.25),
                          child: Icon(
                            Icons.local_shipping,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                partLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                job.clientName.isEmpty
                                    ? 'Клиент'.tr
                                    : job.clientName,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                trAny(job.applianceType),
                                style: TextStyle(color: Colors.grey.shade700),
                              ),
                              if (job.workAddress.trim().isNotEmpty)
                                Text(
                                  job.workAddress,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                  ),
                                ),
                              if (job.scheduledAt != null)
                                Text(
                                  '${'След. визит'.tr}: ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(job.scheduledAt!)}',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                  ),
                                ),
                              if (job.trackingNumber.isNotEmpty ||
                                  job.trackingStatus.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    [
                                      if (job.trackingNumber.isNotEmpty)
                                        job.trackingNumber,
                                      if (job.trackingStatus == 'delivered')
                                        'Доставлено'.tr
                                      else if (job.trackingStatus ==
                                          'out_for_delivery')
                                        'Курьер сегодня'.tr
                                      else if (job.trackingStatus == 'shipped')
                                        'Отправлено'.tr,
                                    ].join(' · '),
                                    style: TextStyle(
                                      color: job.trackingStatus == 'delivered'
                                          ? Colors.green.shade700
                                          : AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
