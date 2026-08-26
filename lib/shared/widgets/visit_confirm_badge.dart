import 'package:flutter/material.dart';

import '../../models/job.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/constants.dart';

/// Значок SMS-подтверждения визита: ? не подтверждено, ✓ да, ✕ отмена, перенос.
class VisitConfirmBadge extends StatelessWidget {
  final String status;
  final bool compact;
  final bool iconOnly;
  final bool stacked;
  final bool expand;

  const VisitConfirmBadge({
    super.key,
    required this.status,
    this.compact = false,
    this.iconOnly = false,
    this.stacked = false,
    this.expand = false,
  });

  static VisitConfirmBadge? maybe(String status, {bool compact = false}) {
    if (status.isEmpty) return null;
    return VisitConfirmBadge(status: status, compact: compact);
  }

  static String visualOf(JobVisit? visit, {String jobStatus = ''}) {
    if (jobStatus.isNotEmpty && JobStatuses.isCancelledStatus(jobStatus)) {
      return JobVisit.confirmCancelled;
    }
    if (jobStatus == JobStatuses.rescheduled) {
      return JobVisit.confirmReschedule;
    }
    if (visit == null) return JobVisit.confirmPending;
    final status = visit.effectiveConfirmStatus;
    if (status.isEmpty) return JobVisit.confirmPending;
    return status;
  }

  static Widget stamp(JobVisit? visit, {String jobStatus = '', bool expand = false}) {
    final status = visualOf(visit, jobStatus: jobStatus);
    return VisitConfirmBadge(status: status, stacked: true, expand: expand);
  }

  static Widget mark(JobVisit? visit, {double size = 22}) {
    final status = visualOf(visit);
    final badge = VisitConfirmBadge(status: status, iconOnly: true, compact: true);
    return IconTheme(
      data: IconThemeData(size: size),
      child: badge,
    );
  }

  _ConfirmLook get _look {
    switch (status) {
      case JobVisit.confirmConfirmed:
        return const _ConfirmLook(
          icon: Icons.check_circle,
          color: Color(0xFF2E7D32),
          bg: Color(0xFFE8F5E9),
          label: 'Заказ принят',
        );
      case JobVisit.confirmCancelled:
        return const _ConfirmLook(
          icon: Icons.cancel,
          color: Color(0xFFC62828),
          bg: Color(0xFFFFEBEE),
          label: 'Отменён',
        );
      case JobVisit.confirmReschedule:
        return const _ConfirmLook(
          icon: Icons.update,
          color: Color(0xFF6A1B9A),
          bg: Color(0xFFF3E5F5),
          label: 'Перенос',
        );
      default:
        return const _ConfirmLook(
          icon: Icons.hourglass_top,
          color: Color(0xFFEF6C00),
          bg: Color(0xFFFFF3E0),
          label: 'Заказ не принят',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = _look;
    if (iconOnly) {
      return Tooltip(
        message: look.label.tr,
        child: Icon(look.icon, size: compact ? 22 : 26, color: look.color),
      );
    }
    if (stacked) {
      return Container(
        width: expand ? double.infinity : 72,
        height: expand ? double.infinity : null,
        alignment: Alignment.center,
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        decoration: BoxDecoration(
          color: look.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: look.color.withValues(alpha: 0.35)),
        ),
        child: FittedBox(
          fit: BoxFit.contain,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                look.label.tr,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: look.color,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: look.color,
                  shape: BoxShape.circle,
                ),
                child: Icon(look.icon, size: 22, color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: look.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: look.color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(look.icon, size: compact ? 14 : 16, color: look.color),
          const SizedBox(width: 4),
          Text(
            look.label.tr,
            style: TextStyle(
              color: look.color,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmLook {
  final IconData icon;
  final Color color;
  final Color bg;
  final String label;

  const _ConfirmLook({
    required this.icon,
    required this.color,
    required this.bg,
    required this.label,
  });
}
