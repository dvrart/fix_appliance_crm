import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/care_plan.dart';
import '../../models/home_appliance.dart';
import '../../services/care_plan_service.dart';
import '../../services/job_service.dart';
import '../jobs/job_details/editors/warranty_report_sheet.dart';
import '../../shared/widgets/appliance_picture.dart';
import '../../services/firestore_service.dart';
import 'care_plan_section.dart';
import 'care_plan_widgets.dart';

/// Поля заявки, которые касаются Care Plan.
class _JobPlanFields {
  final String carePlanId;
  final String carePlanKind;
  final List<String> applianceIds;

  const _JobPlanFields({
    this.carePlanId = '',
    this.carePlanKind = '',
    this.applianceIds = const [],
  });

  factory _JobPlanFields.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const _JobPlanFields();
    return _JobPlanFields(
      carePlanId: (map['carePlanId'] ?? '').toString().trim(),
      carePlanKind: (map['carePlanKind'] ?? '').toString().trim(),
      applianceIds: map['applianceIds'] is List
          ? [
              for (final id in map['applianceIds'] as List)
                if (id.toString().trim().isNotEmpty) id.toString().trim(),
            ]
          : const [],
    );
  }
}

/// Плашка над вкладками заявки: клиент на Care Plan — это гарантийный
/// вызов. Видна только у членов плана (или если заявка уже помечена планом).
/// Тап — выбрать «плановое ТО» или «ремонт по плану», привязать паспорта
/// техники, отметить ТО выполненным.
class CarePlanJobBanner extends StatefulWidget {
  final String jobId;
  final String clientId;
  final String phone;

  const CarePlanJobBanner({
    super.key,
    required this.jobId,
    required this.clientId,
    required this.phone,
  });

  @override
  State<CarePlanJobBanner> createState() => _CarePlanJobBannerState();
}

class _CarePlanJobBannerState extends State<CarePlanJobBanner> {
  late final Stream<DocumentSnapshot> _job = FirestoreService.jobsRef
      .doc(widget.jobId)
      .snapshots();

  CarePlan? _planFor(_JobPlanFields fields) {
    if (fields.carePlanId.isNotEmpty) {
      final byId = CarePlanService.planById(fields.carePlanId);
      if (byId != null) return byId;
    }
    return CarePlanService.memberPlanFor(
      clientId: widget.clientId,
      phone: widget.phone,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.jobId.trim().isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        // Пока планов нет вообще, не подписываемся на заявку зря.
        if (CarePlanService.plans.isEmpty) return const SizedBox.shrink();
        return StreamBuilder<DocumentSnapshot>(
          stream: _job,
          builder: (context, snapshot) {
            final fields = _JobPlanFields.fromMap(
              snapshot.data?.data() as Map<String, dynamic>?,
            );
            final plan = _planFor(fields);
            if (plan == null) return const SizedBox.shrink();
            return _banner(context, plan, fields);
          },
        );
      },
    );
  }

  /// Ремонт бесплатный только у техники со стикером. Без наклейки — обычная
  /// строка льгот, чтобы не обещать то, чего счёт не сделает.
  String _repairLine(CarePlan plan, _JobPlanFields fields) {
    final covered = fields.applianceIds.any((id) {
      final appliance = CarePlanService.applianceById(id);
      return appliance != null &&
          appliance.planId.isNotEmpty &&
          appliance.stickerPrintedAt != null;
    });
    if (!covered) return CarePlanStyle.benefitsLine(plan);
    return '${'Ремонт бесплатно'.tr} · ${'Оплата только за запчасти'.tr}';
  }

  Widget _banner(BuildContext context, CarePlan plan, _JobPlanFields fields) {
    final now = DateTime.now();
    final kind = fields.carePlanKind;
    final warning = plan.status == CarePlan.pastDue
        ? 'Платёж по подписке не прошёл'.tr
        : !plan.isMember
        ? '${'План'.tr}: ${CarePlanStyle.statusLabel(plan.status).toLowerCase()}'
        : plan.inWaiting(now)
        ? '${'Льготы на ремонт — с'.tr} ${DateFormat('dd.MM.yyyy').format(plan.waitingUntil)}'
        : '';
    final title = [
      'CARE PLAN',
      kind.isEmpty ? 'гарантийный клиент'.tr : CarePlanStyle.kindLabel(kind),
    ].join(' · ');
    return Material(
      color: CarePlanStyle.color.withValues(alpha: 0.12),
      child: InkWell(
        onTap: () => _JobPlanSheet.show(
          context,
          jobId: widget.jobId,
          plan: plan,
          fields: fields,
        ),
        child: Container(
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: CarePlanStyle.color, width: 1.2),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              const Icon(CarePlanStyle.icon, color: CarePlanStyle.color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: CarePlanStyle.color,
                        fontSize: 13.5,
                      ),
                    ),
                    Text(
                      kind == CarePlan.kindMaintenance
                          ? '${'Входит в подписку — счёт не нужен'.tr} · ${fields.applianceIds.length} ${'паспортов'.tr}'
                          : _repairLine(plan, fields),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppColors.ink),
                    ),
                    if (warning.isNotEmpty)
                      Text(
                        warning,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFD32F2F),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: CarePlanStyle.color),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobPlanSheet extends StatefulWidget {
  final String jobId;
  final CarePlan plan;
  final _JobPlanFields fields;

  const _JobPlanSheet({
    required this.jobId,
    required this.plan,
    required this.fields,
  });

  static Future<void> show(
    BuildContext context, {
    required String jobId,
    required CarePlan plan,
    required _JobPlanFields fields,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _JobPlanSheet(jobId: jobId, plan: plan, fields: fields),
    );
  }

  @override
  State<_JobPlanSheet> createState() => _JobPlanSheetState();
}

class _JobPlanSheetState extends State<_JobPlanSheet> {
  late String _kind = widget.fields.carePlanKind;
  late final Set<String> _linked = {...widget.fields.applianceIds};

  List<HomeAppliance> get _owned =>
      CarePlanService.appliancesForClient(widget.plan.clientId);

  Future<void> _setKind(String kind) async {
    setState(() => _kind = kind);
    await CarePlanService.setJobPlan(
      widget.jobId,
      planId: widget.plan.id,
      kind: kind,
    );
  }

  Future<String> _currentReport() async {
    try {
      final snap = await FirestoreService.jobsRef.doc(widget.jobId).get();
      return ((snap.data() as Map?)?['solution'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _toggle(String id, bool on) async {
    setState(() => on ? _linked.add(id) : _linked.remove(id));
    await CarePlanService.setJobAppliances(widget.jobId, _linked.toList());
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final owned = _owned;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          children: [
            Row(
              children: [
                const Icon(CarePlanStyle.icon, color: CarePlanStyle.color),
                const SizedBox(width: 8),
                Text(
                  'Гарантийный вызов'.tr,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                CarePlanStatusChip(status: plan.status),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              CarePlanStyle.benefitsLine(plan),
              style: TextStyle(color: AppColors.inkMuted),
            ),
            if (plan.inWaiting(DateTime.now()))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${'Период ожидания: бесплатные диагностика и ремонт — с'.tr} '
                  '${DateFormat('dd.MM.yyyy').format(plan.waitingUntil)}',
                  style: const TextStyle(color: Color(0xFFEF6C00), fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 14),
            Text('Что это за вызов'.tr, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text('Ремонт по плану'.tr),
                  selected: _kind == CarePlan.kindRepair,
                  onSelected: (_) => _setKind(CarePlan.kindRepair),
                ),
                ChoiceChip(
                  label: Text('Плановое ТО'.tr),
                  selected: _kind == CarePlan.kindMaintenance,
                  onSelected: (_) => _setKind(CarePlan.kindMaintenance),
                ),
                ChoiceChip(
                  label: Text('Обычный вызов'.tr),
                  selected: _kind.isEmpty,
                  onSelected: (_) => _setKind(''),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Техника из паспортов'.tr,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            if (owned.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'У клиента нет паспортов техники — добавьте их в карточке клиента.'.tr,
                  style: TextStyle(color: AppColors.inkMuted),
                ),
              ),
            for (final a in owned)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _linked.contains(a.id),
                activeColor: CarePlanStyle.color,
                onChanged: (on) => _toggle(a.id, on == true),
                title: Text(a.displayName.isEmpty ? 'Техника'.tr : trAny(a.displayName)),
                subtitle: Text(
                  [
                    if (a.model.isNotEmpty) a.model,
                    if (a.serialNumber.isNotEmpty) 'S/N ${a.serialNumber}',
                  ].join(' · '),
                ),
                secondary: AppliancePicture(type: a.type, size: 36),
              ),
            const SizedBox(height: 10),
            SizedBox(
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  final host = navigator.context;
                  final current = await _currentReport();
                  navigator.pop();
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                  if (!host.mounted) return;
                  final text = await WarrantyReportSheet.ask(host, existing: current);
                  if (text == null || text.trim().isEmpty) return;
                  await JobService.update(widget.jobId, {'solution': text.trim()});
                },
                icon: const Icon(Icons.edit_note),
                label: Text('Изменить отчет'.tr),
              ),
            ),
            if (_kind == CarePlan.kindMaintenance && plan.isMember) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: CarePlanStyle.color),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    final host = navigator.context;
                    navigator.pop();
                    await Future<void>.delayed(const Duration(milliseconds: 250));
                    if (!host.mounted) return;
                    unawaited(
                      MaintenanceDoneSheet.show(host, plan: plan, jobId: widget.jobId),
                    );
                  },
                  icon: const Icon(Icons.task_alt),
                  label: Text('ТО выполнено'.tr),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
