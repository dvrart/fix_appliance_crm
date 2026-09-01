import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../shared/widgets/job_agenda_card.dart';
import 'job_details/job_details_screen.dart';

/// All jobs that are not done or cancelled — no split by day.
/// `ActiveJobsScreen.today()` показывает только визиты на сегодня.
class ActiveJobsScreen extends StatelessWidget {
  final DateTime? day;

  const ActiveJobsScreen({super.key}) : day = null;

  ActiveJobsScreen.today({super.key}) : day = DateTime.now();

  static int _compare(Job a, Job b) {
    final aAt = a.scheduledAt;
    final bAt = b.scheduledAt;
    if (aAt == null && bAt == null) return b.createdAt.compareTo(a.createdAt);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    return aAt.compareTo(bAt);
  }

  @override
  Widget build(BuildContext context) {
    final target = day;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Text(target == null ? 'Активные'.tr : 'Сегодня'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: StreamBuilder<List<Job>>(
        stream: JobService.streamAll(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          final jobs =
              snapshot.data!
                  .where(
                    (job) => target == null
                        ? !JobStatuses.isClosed(job.status)
                        : job.hasVisitOn(target),
                  )
                  .toList()
                ..sort(_compare);

          if (jobs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  target == null
                      ? 'Нет активных заявок'.tr
                      : 'На сегодня визитов нет'.tr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            itemCount: jobs.length,
            itemBuilder: (context, index) {
              final job = jobs[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: JobAgendaCard(
                  job: job,
                  visit: target == null
                      ? job.latestVisit
                      : (job.visitOn(target) ?? job.latestVisit),
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}
