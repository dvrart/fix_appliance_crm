import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';
import '../../shared/widgets/job_agenda_card.dart';
import 'job_details/job_details_screen.dart';

/// Выбор фильтра и список заявок без разбивки по дням.
class JobFilterGroupsScreen extends StatefulWidget {
  final String selectedId;
  final ValueChanged<String> onSelected;

  const JobFilterGroupsScreen({
    super.key,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  State<JobFilterGroupsScreen> createState() => _JobFilterGroupsScreenState();
}

class _JobFilterGroupsScreenState extends State<JobFilterGroupsScreen> {
  late String _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedId;
  }

  void _select(String id) {
    if (_selectedId == id) return;
    setState(() => _selectedId = id);
    widget.onSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text('Фильтр'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: SettingsService.watchConfig(),
        builder: (context, configSnap) {
          final quick = SettingsService.readListQuickFilters(
            configSnap.data ?? const <String, dynamic>{},
          );
          return StreamBuilder<List<JobStatusDef>>(
            stream: StatusService.streamDefs(),
            builder: (context, statusSnap) {
              final filters = SettingsService.buildJobListFilters(
                statusSnap.data ?? const [],
                quick,
              );
              return StreamBuilder<List<Job>>(
                stream: JobService.streamAll(),
                builder: (context, jobsSnap) {
                  if (!jobsSnap.hasData) {
                    return Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    );
                  }
                  final jobs = jobsSnap.data ?? [];
                  final matched = jobs
                      .where(
                        (job) => SettingsService.jobMatchesListFilter(
                          job,
                          _selectedId,
                        ),
                      )
                      .toList()
                    ..sort(_compareJobs);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Material(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final filter in filters)
                                FilterChip(
                                  label: Text(trAny(filter.label)),
                                  selected: _selectedId == filter.id,
                                  selectedColor: AppColors.accent,
                                  checkmarkColor: Colors.black,
                                  labelStyle: TextStyle(
                                    color: _selectedId == filter.id
                                        ? Colors.black
                                        : Colors.black87,
                                    fontWeight: _selectedId == filter.id
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  onSelected: (_) => _select(filter.id),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: jobs.isEmpty
                            ? Center(
                                child: Text(
                                  'Нет заявок'.tr,
                                  style: TextStyle(color: Colors.grey.shade600),
                                ),
                              )
                            : matched.isEmpty
                                ? Center(
                                    child: Text(
                                      'Нет работ с таким статусом'.tr,
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      10,
                                      12,
                                      24,
                                    ),
                                    itemCount: matched.length,
                                    itemBuilder: (context, index) {
                                      final job = matched[index];
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        child: JobAgendaCard(
                                          job: job,
                                          visit: job.latestVisit,
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    JobDetailsScreen(
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
                                  ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  static int _compareJobs(Job a, Job b) {
    final aAt = a.scheduledAt ?? a.createdAt;
    final bAt = b.scheduledAt ?? b.createdAt;
    return bAt.compareTo(aAt);
  }
}
