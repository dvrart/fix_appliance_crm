import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/care_plan.dart';
import '../../services/care_plan_service.dart';
import '../../shared/app_nav.dart';
import '../clients/client_details_screen.dart';
import 'care_plan_widgets.dart';

/// Значок в шапке календаря (рядом с «Ждём запчасть»): клиенты на Care Plan,
/// которых пора записать на ТО, у кого не прошёл платёж или кто подписал
/// договор, но не оплатил. Виден только пока такие есть.
class CarePlanAttentionButton extends StatelessWidget {
  final Color color;
  final double iconSize;

  const CarePlanAttentionButton({
    super.key,
    required this.color,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final count = CarePlanService.attentionPlans().length;
        if (count == 0) return const SizedBox.shrink();
        return IconButton(
          tooltip: context.tr('Care Plan: пора ТО / оплата', 'Care Plan: due'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          onPressed: () {
            HapticFeedback.selectionClick();
            unawaited(CarePlanAttentionSheet.show(context));
          },
          icon: Badge(
            backgroundColor: AppColors.accent,
            textColor: Colors.black,
            label: Text('$count'),
            child: Icon(CarePlanStyle.icon, color: color, size: iconSize),
          ),
        );
      },
    );
  }
}

class CarePlanAttentionSheet extends StatelessWidget {
  final BuildContext hostContext;
  final BuildContext sheetContext;

  const CarePlanAttentionSheet({
    super.key,
    required this.hostContext,
    required this.sheetContext,
  });

  static Future<void> show(BuildContext hostContext) {
    return showModalBottomSheet<void>(
      context: hostContext,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => CarePlanAttentionSheet(
        hostContext: hostContext,
        sheetContext: sheetContext,
      ),
    );
  }

  void _open(CarePlan plan) {
    final host = hostContext;
    unawaited(() async {
      if (Navigator.of(sheetContext).canPop()) Navigator.pop(sheetContext);
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!host.mounted) return;
      await PanelReturn.open(
        AppNav.navigatorOf(host),
        push: () => AppNav.openCard(
          host,
          key: AppNav.clientKey(plan.clientId),
          builder: (_) => ClientDetailsScreen(
            clientId: plan.clientId,
            clientData: {'fullName': plan.clientName},
          ),
        ),
        back: () {
          if (host.mounted) unawaited(show(host));
        },
      );
    }());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final items = CarePlanService.attentionPlans();
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      const Icon(CarePlanStyle.icon, color: CarePlanStyle.color),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Care Plan',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 22,
                          ),
                        ),
                      ),
                      Text(
                        '${items.length}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 12),
                Flexible(
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            context.tr('Всё в порядке', 'All good'),
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final (plan, reason) = items[index];
                            final urgent = reason == CarePlanAttention.paymentFailed ||
                                reason == CarePlanAttention.maintenanceOverdue;
                            final color = urgent
                                ? const Color(0xFFD32F2F)
                                : const Color(0xFFEF6C00);
                            final count =
                                CarePlanService.appliancesForPlan(plan.id).length;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Material(
                                color: AppColors.card,
                                borderRadius: BorderRadius.circular(10),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: BorderSide(color: color.withValues(alpha: 0.4)),
                                  ),
                                  leading: Icon(
                                    CarePlanStyle.attentionIcon(reason),
                                    color: color,
                                  ),
                                  title: Text(
                                    plan.clientName.isEmpty
                                        ? 'Клиент'.tr
                                        : plan.clientName,
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  subtitle: Text(
                                    [
                                      CarePlanStyle.attentionLabel(plan, reason),
                                      if (count > 0) '$count ${'ед. техники'.tr}',
                                    ].join(' · '),
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _open(plan),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
