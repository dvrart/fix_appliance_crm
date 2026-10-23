import 'package:flutter/material.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/ui_scale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../services/client_service.dart';
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

  /// false — время уже показано рядом (шкала времени в списке дня).
  final bool showTime;

  /// Всегда рисовать компактную полоску вместо высокой карточки.
  final bool forceCompact;

  /// Спокойная строка «Все визиты»: время, имя и статус, без заливки в цвет
  /// статуса и без кнопок звонка и чата — всё это внутри карточки заявки.
  final bool showWorkState;

  /// Количество непрочитанных входящих сообщений по этой заявке / клиенту.
  final int unreadSmsCount;

  /// Количество исходящих черновиков SMS, ждущих одобрения мастера.
  final int pendingSmsCount;

  const JobAgendaCard({
    super.key,
    required this.job,
    this.visit,
    this.onTap,
    this.routeIndex,
    this.footer,
    this.routeIndexColor,
    this.showTime = true,
    this.forceCompact = false,
    this.showWorkState = false,
    this.unreadSmsCount = 0,
    this.pendingSmsCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppUiSettings.instance,
        ClientService.regularRevision,
      ]),
      builder: (ctx, _) {
        final ui = AppUiSettings.instance;
        final displayStatus = job.displayStatusForVisit(visit);
        final statusColor = StatusService.colorOf(displayStatus);
        final statusLabel = SettingsService.listFilterLabel(displayStatus).tr;
        final name = job.contactName.trim().isEmpty
            ? '—'
            : job.contactName.trim();
        final isRegular =
            job.clientIsRegular ||
            ClientService.isRegularClient(
              clientId: job.clientId,
              phone: job.clientPhone,
            );
        final compact =
            forceCompact || JobStatuses.isCompactAgendaStatus(displayStatus);

        if (showWorkState) {
          return _visitRowCard(
            context: ctx,
            ui: ui,
            displayStatus: displayStatus,
            statusColor: statusColor,
            statusLabel: statusLabel,
            name: name,
            isRegular: isRegular,
          );
        }

        return compact
            ? _compactCard(
                context: ctx,
                ui: ui,
                displayStatus: displayStatus,
                statusColor: statusColor,
                statusLabel: statusLabel,
                name: name,
                isRegular: isRegular,
              )
            : _fullCard(
                context: ctx,
                ui: ui,
                displayStatus: displayStatus,
                statusColor: statusColor,
                statusLabel: statusLabel,
                name: name,
                isRegular: isRegular,
              );
      },
    );
  }

  Widget _fullCard({
    required BuildContext context,
    required AppUiSettings ui,
    required String displayStatus,
    required Color statusColor,
    required String statusLabel,
    required String name,
    required bool isRegular,
  }) {
    final address = job.workAddress.trim();
    final nameSize = 15.5 * ui.cardNameScale;
    final when = visit?.startAt ?? job.scheduledAt;
    final timeLabel = showTime ? Formatters.formatTime(when) : '';

    return Material(
      color: ui.paperColor,
      elevation: 1,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        onLongPress: address.isNotEmpty
            ? () => AppFeedback.copy(context, address)
            : (name != '—' ? () => AppFeedback.copy(context, name) : null),
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
                                  color: AppColors.primaryOnCard,
                                  fontWeight: FontWeight.w900,
                                  fontSize:
                                      18 * ui.cardNameScale.clamp(0.9, 1.2),
                                  height: 1,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
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
                                          JobStatuses.isCancelledStatus(
                                            displayStatus,
                                          )
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                ),
                                if (isRegular)
                                  const RegularClientStar(size: 17),
                              ],
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
                                  color: AppColors.primaryOnCard,
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
                      child: Stack(
                        children: [
                          AppliancePicture(
                            type: job.applianceType,
                            fillSlot: true,
                          ),
                          if (job.appliances.length > 1)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: _applianceCountBadge(
                                job.appliances.length,
                              ),
                            ),
                        ],
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

  Widget _applianceCountBadge(int count) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _compactCard({
    required BuildContext context,
    required AppUiSettings ui,
    required String displayStatus,
    required Color statusColor,
    required String statusLabel,
    required String name,
    required bool isRegular,
  }) {
    final nameSize = 14.5 * ui.cardNameScale;
    final when = visit?.startAt ?? job.scheduledAt;
    final timeLabel = showTime ? Formatters.formatTime(when) : '';
    final fill = Color.alphaBlend(
      statusColor.withValues(alpha: 0.22),
      ui.paperColor,
    );
    final address = job.workAddress.trim();
    final trailingText = (footer != null && footer!.trim().isNotEmpty)
        ? footer!.trim()
        : address;

    return Material(
      color: fill,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: address.isNotEmpty
            ? () => AppFeedback.copy(context, address)
            : (name != '—' ? () => AppFeedback.copy(context, name) : null),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
              VisitConfirmBadge.mark(visit, size: 17),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
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
                                        JobStatuses.isCancelledStatus(
                                          displayStatus,
                                        )
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                              if (isRegular) const RegularClientStar(size: 16),
                            ],
                          ),
                        ),
                        if (timeLabel.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            timeLabel,
                            style: TextStyle(
                              color: AppColors.primaryOnCard,
                              fontWeight: FontWeight.w900,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: statusLabel,
                                  style: TextStyle(
                                    color: statusColor,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11.5,
                                  ),
                                ),
                                if (job.isRepeatCall ||
                                    job.status == JobStatuses.repeat)
                                  TextSpan(
                                    text: ' · ',
                                    style: TextStyle(
                                      color: ui.addressColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                if (job.isRepeatCall ||
                                    job.status == JobStatuses.repeat)
                                  TextSpan(
                                    text:
                                        StatusService.labelOf(
                                          JobStatuses.repeat,
                                        ).tr,
                                    style: TextStyle(
                                      color: StatusService.colorOf(
                                        JobStatuses.repeat,
                                      ),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                    ),
                                  ),
                                if (trailingText.isNotEmpty)
                                  TextSpan(
                                    text: ' · ',
                                    style: TextStyle(
                                      color: ui.addressColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                if (trailingText.isNotEmpty)
                                  TextSpan(
                                    text: trailingText,
                                    style: TextStyle(
                                      color:
                                          footer != null &&
                                              footer!.trim().isNotEmpty
                                          ? statusColor
                                          : ui.addressColor,
                                      fontSize: 11,
                                      fontWeight:
                                          footer != null &&
                                              footer!.trim().isNotEmpty
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AppliancePicture(type: job.applianceType, size: 34),
            ],
          ),
        ),
      ),
    );
  }

  /// Строка списка «Все визиты»: слева значок техники, затем время, имя
  /// и в правом углу статус на белом фоне. Выделены только время и статус —
  /// каждый в своём бледном чипе; кнопок действий нет, звонок и переписка
  /// живут внутри карточки заявки.
  Widget _visitRowCard({
    required BuildContext context,
    required AppUiSettings ui,
    required String displayStatus,
    required Color statusColor,
    required String statusLabel,
    required String name,
    required bool isRegular,
  }) {
    final nameSize = 14.5 * ui.cardNameScale;
    final when = visit?.startAt ?? job.scheduledAt;
    final timeLabel = showTime ? Formatters.formatTime(when) : '';
    final address = job.workAddress.trim();
    final isJobCancelled = JobStatuses.isCancelledStatus(job.status);
    final mutedStatus = Color.alphaBlend(
      statusColor.withValues(alpha: 0.88),
      ui.darkNow ? Colors.white : Colors.black,
    );

    return Material(
      color: ui.paperColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: address.isNotEmpty
            ? () => AppFeedback.copy(context, address)
            : (name != '—' ? () => AppFeedback.copy(context, name) : null),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            children: [
              AppliancePicture(type: job.applianceType, size: 34),
              const SizedBox(width: 8),
              if (timeLabel.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    timeLabel,
                    style: TextStyle(
                      color: AppColors.primaryOnCard,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: nameSize,
                              height: 1.1,
                              color: ui.nameColor,
                              decoration:
                                  isJobCancelled ||
                                      JobStatuses.isCancelledStatus(
                                        displayStatus,
                                      )
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (isRegular) const RegularClientStar(size: 16),
                        if (job.isUnconfirmedAuto) ...[
                          const SizedBox(width: 4),
                          _unverifiedAutoBadge(context),
                        ],
                      ],
                    ),
                    if (unreadSmsCount > 0 || pendingSmsCount > 0) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (unreadSmsCount > 0) ...[
                            _smsCountBadge(
                              count: unreadSmsCount,
                              color: const Color(0xFF0277BD),
                              icon: Icons.mark_chat_unread_rounded,
                              tooltip: context.tr(
                                'Непрочитанное сообщение',
                                'Unread message',
                              ),
                              onTap: onTap,
                            ),
                            const SizedBox(width: 4),
                          ],
                          if (pendingSmsCount > 0)
                            _smsCountBadge(
                              count: pendingSmsCount,
                              color: const Color(0xFFE65100),
                              icon: Icons.schedule_send_rounded,
                              tooltip: context.tr(
                                'SMS ждёт подтверждения отправки',
                                'SMS awaiting approval',
                              ),
                              onTap: onTap,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 135),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: mutedStatus,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unverifiedAutoBadge(BuildContext context) {
    final icon = Job.intakeSourceIcon(job.intakeSource);
    return Tooltip(
      message: context.tr('Не проверено', 'Unverified'),
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          color: const Color(0xFF6A1B9A).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Icon(icon, size: 11, color: const Color(0xFF6A1B9A)),
      ),
    );
  }

  Widget _smsCountBadge({
    required int count,
    required Color color,
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final badge = Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: Colors.white),
            const SizedBox(width: 2.5),
            Text(
              '$count',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 10,
                height: 1.05,
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return badge;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: badge,
    );
  }

}
