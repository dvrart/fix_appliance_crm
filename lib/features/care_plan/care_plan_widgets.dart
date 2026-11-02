import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_locale.dart';
import '../../models/care_plan.dart';
import '../../services/care_plan_service.dart';

/// Цвета и подписи Care Plan — одни на все экраны.
class CarePlanStyle {
  static const Color color = Color(0xFF2E7D32);
  static const Color onDark = Color(0xFF69F0AE);
  static const IconData icon = Icons.verified_user;

  static String statusLabel(String status) {
    switch (status) {
      case CarePlan.active:
        return 'Активен'.tr;
      case CarePlan.pastDue:
        return 'Платёж не прошёл'.tr;
      case CarePlan.paused:
        return 'Пауза'.tr;
      case CarePlan.cancelled:
        return 'Отменён'.tr;
      default:
        return 'Ждёт оплаты'.tr;
    }
  }

  static Color statusColor(String status) {
    switch (status) {
      case CarePlan.active:
        return color;
      case CarePlan.pastDue:
        return const Color(0xFFD32F2F);
      case CarePlan.paused:
        return const Color(0xFF757575);
      case CarePlan.cancelled:
        return const Color(0xFF9E9E9E);
      default:
        return const Color(0xFFEF6C00);
    }
  }

  static String kindLabel(String kind) => kind == CarePlan.kindMaintenance
      ? 'Плановое ТО'.tr
      : 'Ремонт по плану'.tr;

  static String attentionLabel(CarePlan plan, CarePlanAttention reason) {
    final due = DateFormat('dd.MM.yyyy').format(plan.maintenanceDue);
    switch (reason) {
      case CarePlanAttention.paymentFailed:
        return 'Ежемесячный платёж не прошёл'.tr;
      case CarePlanAttention.maintenanceOverdue:
        return '${'Пора ТО — срок'.tr} $due';
      case CarePlanAttention.maintenanceSoon:
        final days = plan.daysToMaintenance(DateTime.now());
        return '${'ТО через'.tr} $days ${'дн.'.tr} · $due';
      case CarePlanAttention.awaitingPayment:
        return 'Договор подписан, подписка не оплачена'.tr;
      case CarePlanAttention.none:
        return '';
    }
  }

  static IconData attentionIcon(CarePlanAttention reason) {
    switch (reason) {
      case CarePlanAttention.paymentFailed:
        return Icons.credit_card_off;
      case CarePlanAttention.awaitingPayment:
        return Icons.payments_outlined;
      default:
        return Icons.build_circle_outlined;
    }
  }

  /// Льготы плана одной строкой — для баннера заявки и экрана звонка.
  /// 100% на работу — ремонт бесплатный, клиент платит только за запчасти.
  static String benefitsLine(CarePlan plan) {
    final percent = plan.discountPercent.round();
    final repair = percent >= 100
        ? 'Ремонт бесплатно'.tr
        : '−$percent% ${'на ремонт'.tr}';
    return '${'Диагностика бесплатно'.tr} · $repair · ${'приоритет'.tr}';
  }
}

/// Маленький щит рядом с именем в списках (как звёздочка постоянного
/// клиента). Ничего не рисует, если клиент не на плане.
class CarePlanMark extends StatelessWidget {
  final String? clientId;
  final String? phone;
  final double size;
  final bool onDark;

  const CarePlanMark({
    super.key,
    this.clientId,
    this.phone,
    this.size = 17,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final plan = CarePlanService.memberPlanFor(
          clientId: clientId,
          phone: phone,
        );
        if (plan == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Tooltip(
            message: 'Care Plan — гарантийный клиент'.tr,
            child: Icon(
              CarePlanStyle.icon,
              size: size,
              color: onDark ? CarePlanStyle.onDark : CarePlanStyle.color,
            ),
          ),
        );
      },
    );
  }
}

/// Крупная плашка на экране входящего звонка: мастер видит, что звонит
/// клиент на Care Plan, ещё до ответа.
class CarePlanCallBadge extends StatelessWidget {
  final String phone;
  final bool compact;

  const CarePlanCallBadge({super.key, required this.phone, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final plan = CarePlanService.memberPlanFor(phone: phone);
        if (plan == null) return const SizedBox.shrink();
        final now = DateTime.now();
        final warning = plan.status == CarePlan.pastDue
            ? 'платёж не прошёл'.tr
            : plan.inWaiting(now)
            ? '${'ожидание до'.tr} ${DateFormat('dd.MM').format(plan.waitingUntil)}'
            : '';
        return Container(
          margin: EdgeInsets.only(top: compact ? 6 : 12),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 4 : 7,
          ),
          decoration: BoxDecoration(
            color: CarePlanStyle.onDark.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: CarePlanStyle.onDark, width: 1.4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CarePlanStyle.icon,
                color: CarePlanStyle.onDark,
                size: compact ? 16 : 20,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  [
                    'CARE PLAN · ${'гарантийный вызов'.tr}',
                    if (warning.isNotEmpty) warning,
                  ].join(' · '),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 12 : 14,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Пилюля статуса плана.
class CarePlanStatusChip extends StatelessWidget {
  final String status;

  const CarePlanStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = CarePlanStyle.statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        CarePlanStyle.statusLabel(status),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
