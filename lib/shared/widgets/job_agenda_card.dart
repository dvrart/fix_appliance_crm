import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/ui_scale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';
import 'appliance_picture.dart';
import 'visit_confirm_badge.dart';

/// Карточка заявки: полная для вызова, полоска после смены статуса.
class JobAgendaCard extends StatelessWidget {
  final Job job;
  final JobVisit? visit;
  final VoidCallback? onTap;
  final int? routeIndex;
  final String? footer;
  final Color? routeIndexColor;

  const JobAgendaCard({
    super.key,
    required this.job,
    this.visit,
    this.onTap,
    this.routeIndex,
    this.footer,
    this.routeIndexColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        final ui = AppUiSettings.instance;
        final displayStatus = job.displayStatusForVisit(visit);
        final statusColor = StatusService.colorOf(displayStatus);
        final statusLabel = SettingsService.listFilterLabel(displayStatus).tr;
        final name = job.contactName.trim().isEmpty
            ? '—'
            : job.contactName.trim();
        final compact = JobStatuses.isCompactAgendaStatus(displayStatus);

        return compact
            ? _compactCard(
                ui: ui,
                displayStatus: displayStatus,
                statusColor: statusColor,
                statusLabel: statusLabel,
                name: name,
              )
            : _fullCard(
                ui: ui,
                displayStatus: displayStatus,
                statusColor: statusColor,
                statusLabel: statusLabel,
                name: name,
              );
      },
    );
  }

  Widget _fullCard({
    required AppUiSettings ui,
    required String displayStatus,
    required Color statusColor,
    required String statusLabel,
    required String name,
  }) {
    final address = job.workAddress.trim();
    final nameSize = 15.5 * ui.cardNameScale;
    final when = visit?.startAt ?? job.scheduledAt;
    final timeLabel = Formatters.formatTime(when);

    return Material(
      color: ui.paperColor,
      elevation: 1,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: IntrinsicHeight(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: VisitConfirmBadge.stamp(
                                visit,
                                jobStatus: displayStatus,
                                expand: true,
                              ),
                            ),
                          ),
                          if (routeIndex != null)
                            Positioned(
                              top: 3,
                              left: 3,
                              child: Container(
                                width: 18,
                                height: 18,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: routeIndexColor ?? AppColors.primary,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '$routeIndex',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 2, 0, 20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (timeLabel.isNotEmpty) ...[
                              Text(
                                timeLabel,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w900,
                                  fontSize:
                                      18 * ui.cardNameScale.clamp(0.9, 1.2),
                                  height: 1,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Text(
                              name,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: nameSize,
                                height: 1.1,
                                color: ui.nameColor,
                                decoration:
                                    JobStatuses.isCancelledStatus(displayStatus)
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            if (job.isRepeatCall ||
                                job.status == JobStatuses.repeat) ...[
                              const SizedBox(height: 2),
                              Text(
                                StatusService.labelOf(JobStatuses.repeat).tr,
                                style: TextStyle(
                                  color: StatusService.colorOf(
                                    JobStatuses.repeat,
                                  ),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                            if (address.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                address,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: ui.addressColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  height: 1.15,
                                ),
                              ),
                            ],
                            if (footer != null &&
                                footer!.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                footer!.trim(),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 96,
                      child: AppliancePicture(
                        type: job.applianceType,
                        fillSlot: true,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 80,
                right: 104,
                bottom: 0,
                child: Center(child: _statusTab(statusColor, statusLabel)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusTab(Color color, String label) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _compactCard({
    required AppUiSettings ui,
    required String displayStatus,
    required Color statusColor,
    required String statusLabel,
    required String name,
  }) {
    final nameSize = 14.5 * ui.cardNameScale;
    final when = visit?.startAt ?? job.scheduledAt;
    final timeLabel = Formatters.formatTime(when);
    final fill = Color.alphaBlend(
      statusColor.withValues(alpha: 0.22),
      ui.paperColor,
    );

    return Material(
      color: fill,
      elevation: 1,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (routeIndex != null) ...[
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: routeIndexColor ?? AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$routeIndex',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              VisitConfirmBadge.mark(visit, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: nameSize,
                              height: 1.1,
                              color: ui.nameColor,
                              decoration:
                                  JobStatuses.isCancelledStatus(displayStatus)
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (timeLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            timeLabel,
                            style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (job.isRepeatCall ||
                            job.status == JobStatuses.repeat) ...[
                          const SizedBox(width: 6),
                          Text(
                            StatusService.labelOf(JobStatuses.repeat).tr,
                            style: TextStyle(
                              color: StatusService.colorOf(JobStatuses.repeat),
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        if (footer != null && footer!.trim().isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              footer!.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppliancePicture(type: job.applianceType, size: 44),
            ],
          ),
        ),
      ),
    );
  }
}
