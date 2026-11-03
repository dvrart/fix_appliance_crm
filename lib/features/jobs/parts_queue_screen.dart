import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../models/job.dart';
import '../../services/services.dart';
import '../jobs/job_details/editors/job_tile_editors.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../../shared/app_nav.dart';
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
        automaticallyImplyLeading: false,
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
          final today = DateTime.now();
          final startOfToday = DateTime(today.year, today.month, today.day);
          // 0 — срок прошёл, 1 — срок ещё впереди, 2 — день не обещан.
          int rank(Job job) {
            final promised = job.promisedPartAt;
            if (promised == null) return 2;
            return promised.isBefore(startOfToday) ? 0 : 1;
          }

          jobs.sort((a, b) {
            final byRank = rank(a).compareTo(rank(b));
            if (byRank != 0) return byRank;
            return (a.promisedPartAt ?? a.createdAt)
                .compareTo(b.promisedPartAt ?? b.createdAt);
          });
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
              final promised = job.promisedPartAt;
              final overdue =
                  promised != null && promised.isBefore(startOfToday);
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    AppNav.openCard(
                      context,
                      key: AppNav.jobKey(job.id),
                      builder: (_) => JobDetailsScreen(
                        jobId: job.id,
                        clientId: job.clientId,
                        jobData: job.toMap(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: overdue
                              ? const Color(0xFFD32F2F).withValues(alpha: 0.15)
                              : AppColors.accent.withValues(alpha: 0.25),
                          child: Icon(
                            Icons.local_shipping,
                            color: overdue
                                ? const Color(0xFFD32F2F)
                                : AppColors.primary,
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
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      job.contactName.isEmpty
                                          ? job.contactPhone
                                          : job.contactName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (job.clientIsRegular ||
                                      ClientService.isRegularClient(
                                        clientId: job.clientId,
                                        phone: job.clientPhone,
                                      ))
                                    const RegularClientStar(size: 16),
                                ],
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
                              if (promised != null)
                                Builder(
                                  builder: (context) {
                                    final datePart = DateFormat(
                                      'd MMM',
                                      AppLocale.instance.dateLocale,
                                    ).format(promised);
                                    final hasTime =
                                        promised.hour != 0 ||
                                        promised.minute != 0;
                                    final whenLabel = hasTime
                                        ? '$datePart · ${DateFormat('HH:mm').format(promised)}'
                                        : datePart;
                                    return Text(
                                      overdue
                                          ? '${'Обещал к'.tr} $whenLabel — ${'срок прошёл'.tr}'
                                          : '${'Обещал к'.tr} $whenLabel',
                                      style: TextStyle(
                                        color: overdue
                                            ? const Color(0xFFC62828)
                                            : AppColors.primary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    );
                                  },
                                ),
                              if (job.scheduledAt != null)
                                Text(
                                  '${'След. визит'.tr}: ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(job.scheduledAt!)}',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                  ),
                                ),
                              for (final order in job.trackingOrders)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    [
                                      if (order.effectiveCarrier.isNotEmpty)
                                        trackingPartsFromLabel(
                                          order.effectiveCarrier,
                                        ),
                                      if (order.part.isNotEmpty) order.part,
                                      if (order.trackingNumber.isNotEmpty)
                                        order.trackingNumber
                                      else if (order.orderId.isNotEmpty)
                                        order.orderId,
                                      if (order.status == 'delivered')
                                        'Доставлено'.tr
                                      else if (order.status ==
                                          'out_for_delivery')
                                        'Курьер сегодня'.tr
                                      else if (order.status == 'shipped')
                                        'Отправлено'.tr,
                                    ].join(' · '),
                                    style: TextStyle(
                                      color: order.status == 'delivered'
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
