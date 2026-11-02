import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qr/qr.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/app_date_picker.dart';
import '../../models/care_plan.dart';
import '../../models/home_appliance.dart';
import '../../services/ai_service.dart';
import '../../services/care_plan_service.dart';
import '../../services/catalog_service.dart';
import '../../services/settings_service.dart';
import '../../services/sticker_printer_service.dart';
import '../../services/stripe_service.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/appliance_picture.dart';
import '../../shared/widgets/catalog_picker.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../settings/pages/sticker_printer_settings_page.dart';
import 'care_plan_widgets.dart';
import 'sticker_renderer.dart';

final _date = DateFormat('dd.MM.yyyy');

String _money(double value) => '\$${value.toStringAsFixed(2)}';

void _snack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: error ? Colors.red : CarePlanStyle.color,
    ),
  );
}

/// Блок «Care Plan и техника» в карточке клиента: договор подписки, оплата,
/// ТО и цифровые паспорта техники с наклейками.
class CarePlanSection extends StatefulWidget {
  final String clientId;
  final Map<String, dynamic> clientData;

  const CarePlanSection({
    super.key,
    required this.clientId,
    required this.clientData,
  });

  @override
  State<CarePlanSection> createState() => _CarePlanSectionState();
}

class _CarePlanSectionState extends State<CarePlanSection> {
  String _syncedFor = '';

  String get _name =>
      (widget.clientData['fullName'] ?? widget.clientData['name'] ?? '')
          .toString()
          .trim();
  String get _phone => (widget.clientData['phone'] ?? '').toString().trim();
  String get _address => (widget.clientData['address'] ?? '').toString().trim();
  String? get _email {
    final value = (widget.clientData['email'] ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }

  /// Номера клиента поменялись в карточке — план узнаёт звонящего по новым.
  void _syncPhones(CarePlan plan) {
    final phones = CarePlanService.phonesOfClient(widget.clientData);
    final key = '${plan.id}|${phones.join(',')}';
    if (_syncedFor == key || phones.isEmpty) return;
    _syncedFor = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(CarePlanService.syncPhones(plan, phones));
    });
  }

  Future<void> _editPlan([CarePlan? plan]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CarePlanEditPage(
          clientId: widget.clientId,
          clientName: _name,
          address: _address,
          phones: CarePlanService.phonesOfClient(widget.clientData),
          plan: plan,
        ),
      ),
    );
  }

  Future<void> _editAppliance({HomeAppliance? appliance, String planId = ''}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AppliancePassportPage(
          clientId: widget.clientId,
          appliance: appliance,
          defaultPlanId: planId,
          clientPhone: _phone,
          clientAddress: _address,
          clientEmail: _email,
        ),
      ),
    );
  }

  Future<void> _payment(CarePlan plan) =>
      CarePlanPaymentSheet.show(context, plan: plan, phone: _phone);

  Future<void> _scheduleMaintenance(CarePlan plan) async {
    final items = CarePlanService.appliancesForPlan(plan.id);
    try {
      final (jobId, job) = await CarePlanService.createMaintenanceJob(
        plan: plan,
        appliances: items,
        clientPhone: _phone,
        clientAddress: plan.address.isNotEmpty ? plan.address : _address,
        clientEmail: _email,
      );
      if (!mounted) return;
      _snack(context, 'Заявка на ТО создана — поставьте дату визита'.tr);
      await AppNav.openCard(
        context,
        key: AppNav.jobKey(jobId),
        builder: (_) => JobDetailsScreen(
          jobId: jobId,
          clientId: plan.clientId,
          jobData: job.toMap(),
        ),
      );
    } catch (e) {
      if (mounted) _snack(context, '${'Не удалось создать заявку'.tr}: $e', error: true);
    }
  }

  Future<void> _maintenanceDone(CarePlan plan) =>
      MaintenanceDoneSheet.show(context, plan: plan);

  Future<void> _menu(CarePlan plan, String action) async {
    switch (action) {
      case 'edit':
        await _editPlan(plan);
      case 'activate':
        await CarePlanService.setStatus(plan.id, CarePlan.active);
      case 'pause':
        await CarePlanService.setStatus(plan.id, CarePlan.paused);
      case 'sync':
        try {
          final status = await StripeService.syncCarePlan(plan.id);
          if (mounted) {
            _snack(
              context,
              '${'Статус оплаты'.tr}: ${CarePlanStyle.statusLabel(status)}',
            );
          }
        } catch (e) {
          if (mounted) _snack(context, '$e', error: true);
        }
      case 'cancel':
        final ok = await showConfirmCancelSheet(
          context,
          title: 'Отменить Care Plan?'.tr,
          message:
              'Подписку в Stripe отмените в кабинете Stripe — здесь план только помечается отменённым. Паспорта техники останутся.'
                  .tr,
          confirmLabel: 'Отменить план'.tr,
        );
        if (ok) await CarePlanService.setStatus(plan.id, CarePlan.cancelled);
      case 'delete':
        final ok = await showConfirmCancelSheet(
          context,
          title: 'Удалить план?'.tr,
          message: 'Только если план заведён по ошибке. Паспорта техники останутся у клиента.'.tr,
          confirmLabel: 'Удалить'.tr,
        );
        if (ok) await CarePlanService.deletePlan(plan.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final plans = CarePlanService.plansForClient(widget.clientId);
        final current = plans.where((p) => !p.isCancelled).firstOrNull;
        final appliances = CarePlanService.appliancesForClient(widget.clientId);
        if (current != null) _syncPhones(current);
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: current?.isMember == true
                  ? CarePlanStyle.color.withValues(alpha: 0.6)
                  : AppColors.border,
              width: current?.isMember == true ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (current == null)
                _noPlan(plans)
              else
                _planCard(current),
              Divider(height: 1, color: AppColors.border),
              _appliances(appliances, current),
            ],
          ),
        );
      },
    );
  }

  Widget _noPlan(List<CarePlan> plans) {
    final terms = CarePlanService.terms;
    final cancelled = plans.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Row(
        children: [
          Icon(CarePlanStyle.icon, color: AppColors.inkMuted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cancelled ? 'Care Plan отменён'.tr : 'Care Plan не оформлен'.tr,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_money(terms.monthlyPrice)}/${'мес'.tr} · '
                  '${'диагностика бесплатно'.tr} · '
                  '${terms.discountPercent >= 100 ? 'ремонт бесплатно'.tr : '−${terms.discountPercent.round()}%'} · '
                  '${'ТО раз в год'.tr}',
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CarePlanStyle.color),
            onPressed: () => _editPlan(),
            child: Text('Оформить'.tr),
          ),
        ],
      ),
    );
  }

  Widget _planCard(CarePlan plan) {
    final now = DateTime.now();
    final terms = CarePlanService.terms;
    final taxRate = plan.monthlyPrice > 0 ? _taxRate : 0.0;
    final days = plan.daysToMaintenance(now);
    final dueText = days < 0
        ? '${'просрочено на'.tr} ${-days} ${'дн.'.tr}'
        : days == 0
        ? 'сегодня'.tr
        : '${'через'.tr} $days ${'дн.'.tr}';
    final lastPay = plan.lastPaymentAt;
    final lines = <(IconData, String, Color?)>[
      (
        Icons.description_outlined,
        [
          if (plan.contractNumber.isNotEmpty) '${'Договор'.tr} №${plan.contractNumber}',
          '${'подписан'.tr} ${_date.format(plan.signedAt)}',
        ].join(' · '),
        null,
      ),
      (
        Icons.payments_outlined,
        '${_money(plan.monthlyPrice)}/${'мес'.tr}'
            '${taxRate > 0 ? ' + HST = ${_money(plan.monthlyTotal(taxRate))}' : ''}'
            ' · ${'минимум до'.tr} ${_date.format(plan.minTermUntil)}',
        null,
      ),
      if (plan.isMember || plan.status == CarePlan.pending)
        (
          Icons.build_circle_outlined,
          '${'ТО'.tr}: ${_date.format(plan.maintenanceDue)} · $dueText',
          days <= 0
              ? Colors.red
              : days <= terms.remindDays
              ? const Color(0xFFEF6C00)
              : null,
        ),
      if (plan.inCoolingOff(now))
        (
          Icons.undo,
          '${'Клиент может отказаться без причины до'.tr} ${_date.format(plan.coolingOffUntil)}',
          const Color(0xFFEF6C00),
        ),
      if (plan.inWaiting(now))
        (
          Icons.hourglass_bottom,
          '${'Бесплатные диагностика и ремонт — с'.tr} ${_date.format(plan.waitingUntil)}',
          null,
        ),
      if (lastPay != null)
        (
          Icons.check_circle_outline,
          '${'Последний платёж'.tr} ${_date.format(lastPay)}'
              '${plan.lastPaymentAmount > 0 ? ' · ${_money(plan.lastPaymentAmount)}' : ''}',
          null,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(CarePlanStyle.icon, color: CarePlanStyle.color),
              const SizedBox(width: 10),
              const Text(
                'Care Plan',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
              const SizedBox(width: 8),
              CarePlanStatusChip(status: plan.status),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'Действия'.tr,
                onSelected: (value) => _menu(plan, value),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text('Изменить договор'.tr)),
                  if (plan.status != CarePlan.active)
                    PopupMenuItem(value: 'activate', child: Text('Отметить активным'.tr)),
                  if (plan.status == CarePlan.active)
                    PopupMenuItem(value: 'pause', child: Text('Поставить на паузу'.tr)),
                  PopupMenuItem(value: 'sync', child: Text('Сверить оплату со Stripe'.tr)),
                  PopupMenuItem(value: 'cancel', child: Text('Отменить план'.tr)),
                  if (plan.status == CarePlan.pending)
                    PopupMenuItem(value: 'delete', child: Text('Удалить (ошибка)'.tr)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final (icon, text, color) in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 16, color: color ?? AppColors.inkMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: 13,
                        color: color ?? AppColors.ink,
                        fontWeight: color != null ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (plan.status != CarePlan.active || plan.stripeSubscriptionId.isEmpty)
                  _action(
                    Icons.credit_card,
                    plan.status == CarePlan.pastDue
                        ? 'Новая карта'.tr
                        : 'Оплата подписки'.tr,
                    () => _payment(plan),
                    filled: true,
                  ),
                if (plan.isMember) ...[
                  _action(Icons.event_available, 'Записать на ТО'.tr, () => _scheduleMaintenance(plan)),
                  _action(Icons.task_alt, 'ТО выполнено'.tr, () => _maintenanceDone(plan)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  double get _taxRate => _cachedTaxRate;
  static double _cachedTaxRate = 0.13;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final config = await SettingsService.loadConfig();
      final rate = SettingsService.readDefaultTaxRate(config);
      if (rate != _cachedTaxRate && mounted) setState(() => _cachedTaxRate = rate);
    }());
  }

  Widget _action(IconData icon, String label, VoidCallback onTap, {bool filled = false}) {
    final style = filled
        ? FilledButton.styleFrom(
            backgroundColor: CarePlanStyle.color,
            visualDensity: VisualDensity.compact,
          )
        : null;
    return filled
        ? FilledButton.icon(
            style: style,
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
          )
        : OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: CarePlanStyle.color,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
  }

  /// Срок ТО прямо на единице техники. Далеко — обычным цветом, скоро —
  /// жёлтым, просрочено или сегодня — красным. Без плана ничего не рисует.
  Widget _dueLine(CarePlan plan) {
    final days = plan.daysToMaintenance(DateTime.now());
    final color = days <= 0
        ? Colors.red
        : days <= CarePlanService.terms.remindDays
        ? const Color(0xFFEF6C00)
        : AppColors.inkMuted;
    return Text(
      plan.maintenanceDueLine(
        DateTime.now(),
        remindDays: CarePlanService.terms.remindDays,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: days <= CarePlanService.terms.remindDays
            ? FontWeight.w700
            : FontWeight.w500,
      ),
    );
  }

  Widget _appliances(List<HomeAppliance> items, CarePlan? plan) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.qr_code_2, size: 20, color: AppColors.primaryOnCard),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${'Техника · паспорта'.tr}${items.isEmpty ? '' : ' (${items.length})'}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: () => _editAppliance(planId: plan?.id ?? ''),
                icon: const Icon(Icons.add, size: 18),
                label: Text('Добавить'.tr),
              ),
            ],
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 8),
              child: Text(
                'Сфотографируйте шильдик — паспорт заполнится сам, потом печатайте наклейку.'.tr,
                style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
              ),
            ),
          for (final a in items)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _editAppliance(appliance: a),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    AppliancePicture(type: a.type, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  a.displayName.isEmpty ? 'Техника'.tr : trAny(a.displayName),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (a.planId.isNotEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(CarePlanStyle.icon, size: 14, color: CarePlanStyle.color),
                                ),
                            ],
                          ),
                          Text(
                            [
                              if (a.model.isNotEmpty) a.model,
                              if (a.serialNumber.isNotEmpty) 'S/N ${a.serialNumber}',
                              if (a.stickerPrintedAt == null) 'наклейки нет'.tr,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                          ),
                          if (plan != null && a.planId == plan.id)
                            _dueLine(plan),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Печать наклейки'.tr,
                      onPressed: () => StickerPrintSheet.show(context, a),
                      icon: Icon(Icons.print_outlined, color: AppColors.primaryOnCard),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Оформление и правка договора Care Plan (бумажный бланк, заполненный у
/// клиента). Цена и сроки берутся из Настройки → Care Plan и фиксируются в
/// плане на день подписания.
class CarePlanEditPage extends StatefulWidget {
  final String clientId;
  final String clientName;
  final String address;
  final List<String> phones;
  final CarePlan? plan;

  const CarePlanEditPage({
    super.key,
    required this.clientId,
    required this.clientName,
    required this.address,
    required this.phones,
    this.plan,
  });

  @override
  State<CarePlanEditPage> createState() => _CarePlanEditPageState();
}

class _CarePlanEditPageState extends State<CarePlanEditPage> {
  late final _contract = TextEditingController(text: widget.plan?.contractNumber ?? '');
  late final _address = TextEditingController(text: widget.plan?.address ?? widget.address);
  late final _notes = TextEditingController(text: widget.plan?.notes ?? '');
  late DateTime _signedAt = widget.plan?.signedAt ?? DateTime.now();
  DateTime? _nextDue;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nextDue = widget.plan?.nextMaintenanceDue;
    unawaited(CarePlanService.loadTerms().then((_) {
      if (mounted) setState(() {});
    }));
  }

  @override
  void dispose() {
    _contract.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  CarePlanTerms get _terms => CarePlanService.terms;

  DateTime get _computedDue => CarePlan.computeNextMaintenanceDue(
    signedAt: _signedAt,
    lastMaintenanceAt: widget.plan?.lastMaintenanceAt,
    maintenanceMonths: widget.plan?.maintenanceMonths ?? _terms.maintenanceMonths,
    firstMaintenanceDays:
        widget.plan?.firstMaintenanceDays ?? _terms.firstMaintenanceDays,
  );

  Future<void> _pickSigned() async {
    final picked = await showAppDateSheet(
      context: context,
      initial: _signedAt,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      title: 'Дата подписания'.tr,
    );
    if (picked != null && mounted) setState(() => _signedAt = picked);
  }

  Future<void> _pickDue() async {
    final picked = await showAppDateSheet(
      context: context,
      initial: _nextDue ?? _computedDue,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 800)),
      title: 'Следующее ТО'.tr,
    );
    if (picked != null && mounted) setState(() => _nextDue = picked);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final existing = widget.plan;
      if (existing == null) {
        await CarePlanService.createPlan(
          clientId: widget.clientId,
          clientName: widget.clientName,
          phones: widget.phones,
          address: _address.text.trim(),
          contractNumber: _contract.text.trim(),
          signedAt: _signedAt,
          nextMaintenanceDue: _nextDue,
          notes: _notes.text.trim(),
        );
      } else {
        await CarePlanService.updatePlan(
          CarePlan(
            id: existing.id,
            clientId: existing.clientId,
            clientName: widget.clientName.isEmpty ? existing.clientName : widget.clientName,
            phones: widget.phones.isEmpty ? existing.phones : widget.phones,
            address: _address.text.trim(),
            status: existing.status,
            contractNumber: _contract.text.trim(),
            signedAt: _signedAt,
            monthlyPrice: existing.monthlyPrice,
            discountPercent: existing.discountPercent,
            minTermMonths: existing.minTermMonths,
            waitingDays: existing.waitingDays,
            coolingOffDays: existing.coolingOffDays,
            maintenanceMonths: existing.maintenanceMonths,
            firstMaintenanceDays: existing.firstMaintenanceDays,
            lastMaintenanceAt: existing.lastMaintenanceAt,
            nextMaintenanceDue: _nextDue,
            notes: _notes.text.trim(),
            stripe: existing.stripe,
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack(context, '$e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _terms;
    final plan = widget.plan;
    final price = plan?.monthlyPrice ?? t.monthlyPrice;
    final discount = plan?.discountPercent ?? t.discountPercent;
    final minTerm = plan?.minTermMonths ?? t.minTermMonths;
    final waiting = plan?.waitingDays ?? t.waitingDays;
    final coolingOff = plan?.coolingOffDays ?? t.coolingOffDays;
    return Scaffold(
      appBar: AppBar(
        title: Text(plan == null ? 'Новый Care Plan'.tr : 'Договор Care Plan'.tr),
        backgroundColor: CarePlanStyle.color,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: CarePlanStyle.color),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check),
            label: Text('Сохранить'.tr, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(
            widget.clientName.isEmpty ? 'Клиент'.tr : widget.clientName,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contract,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Номер бланка договора'.tr,
              hintText: '0001',
              prefixIcon: const Icon(Icons.numbers),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _dateTile(Icons.draw_outlined, 'Дата подписания'.tr, _signedAt, _pickSigned),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            decoration: InputDecoration(
              labelText: 'Адрес дома по договору'.tr,
              prefixIcon: const Icon(Icons.home_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _dateTile(
            Icons.build_circle_outlined,
            'Следующее ТО'.tr,
            _nextDue ?? _computedDue,
            _pickDue,
            hint: _nextDue == null ? 'посчитано по условиям'.tr : null,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Заметки'.tr,
              prefixIcon: const Icon(Icons.notes),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: CarePlanStyle.color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan == null
                      ? 'Условия (из Настройки → Care Plan)'.tr
                      : 'Условия на день подписания'.tr,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_money(price)}/${'мес'.tr} + HST · '
                  '${discount >= 100 ? 'ремонт бесплатно'.tr : '−${discount.round()}% ${'на ремонт'.tr}'} · '
                  '${'диагностика бесплатно'.tr} · ${'ТО раз в год'.tr}\n'
                  '${'Минимальный срок'.tr}: $minTerm ${'мес.'.tr} · '
                  '${'отказ без причины'.tr}: $coolingOff ${'дн.'.tr} · '
                  '${'ожидание льгот'.tr}: $waiting ${'дн.'.tr}',
                  style: TextStyle(color: AppColors.inkMuted, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateTile(
    IconData icon,
    String label,
    DateTime value,
    VoidCallback onTap, {
    String? hint,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: hint,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
        ),
        child: Text(_date.format(value), style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

/// Паспорт одной единицы техники: фото шильдика → ИИ заполняет поля,
/// сохранить → напечатать наклейку с QR.
class AppliancePassportPage extends StatefulWidget {
  final String clientId;
  final HomeAppliance? appliance;
  final String defaultPlanId;
  final String clientPhone;
  final String clientAddress;
  final String? clientEmail;

  const AppliancePassportPage({
    super.key,
    required this.clientId,
    this.appliance,
    this.defaultPlanId = '',
    this.clientPhone = '',
    this.clientAddress = '',
    this.clientEmail,
  });

  @override
  State<AppliancePassportPage> createState() => _AppliancePassportPageState();
}

class _AppliancePassportPageState extends State<AppliancePassportPage> {
  late final HomeAppliance? _a = widget.appliance;
  late final _type = TextEditingController(text: _a?.type ?? '');
  late final _brand = TextEditingController(text: _a?.brand ?? '');
  late final _model = TextEditingController(text: _a?.model ?? '');
  late final _serial = TextEditingController(text: _a?.serialNumber ?? '');
  late final _made = TextEditingController(text: _a?.manufactureDate ?? '');
  late final _placement = TextEditingController(text: _a?.placement ?? '');
  late final _notes = TextEditingController(text: _a?.notes ?? '');
  late String _planId = _a?.planId ?? widget.defaultPlanId;
  Uint8List? _photo;
  bool _reading = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_type, _brand, _model, _serial, _made, _placement, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  CarePlan? get _plan {
    for (final p in CarePlanService.plansForClient(widget.clientId)) {
      if (!p.isCancelled) return p;
    }
    return null;
  }

  Future<void> _scan(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _photo = bytes;
      _reading = true;
    });
    try {
      final types = await CatalogService.loadList('applianceTypes');
      final scan = await AiService.readNameplate(imageBytes: bytes, types: types);
      if (!mounted) return;
      if (scan == null) {
        _snack(context, 'ИИ не разобрал шильдик — заполните поля вручную'.tr, error: true);
        return;
      }
      setState(() {
        if ((scan.type ?? '').isNotEmpty) _type.text = scan.type!;
        if ((scan.brand ?? '').isNotEmpty) _brand.text = scan.brand!;
        if ((scan.model ?? '').isNotEmpty) _model.text = scan.model!;
        if ((scan.serialNumber ?? '').isNotEmpty) _serial.text = scan.serialNumber!;
        if ((scan.manufactureDate ?? '').isNotEmpty) _made.text = scan.manufactureDate!;
      });
      _snack(context, 'Шильдик прочитан — проверьте поля'.tr);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _pickType() async {
    final value = await showCatalogPicker(
      context: context,
      title: 'Тип техники'.tr,
      itemsStream: CatalogService.streamApplianceTypes(),
      onAdd: CatalogService.addApplianceType,
    );
    if (value != null && mounted) setState(() => _type.text = value);
  }

  Future<void> _pickBrand() async {
    final value = await showCatalogPicker(
      context: context,
      title: 'Бренд'.tr,
      itemsStream: CatalogService.streamBrands(),
      onAdd: CatalogService.addBrand,
    );
    if (value != null && mounted) setState(() => _brand.text = value);
  }

  Future<HomeAppliance?> _save({bool close = true}) async {
    if (_saving) return null;
    if (_type.text.trim().isEmpty) {
      _snack(context, 'Выберите тип техники'.tr, error: true);
      return null;
    }
    setState(() => _saving = true);
    try {
      final isNew = _a == null;
      final code = _a?.id ?? await CarePlanService.newPassportCode();
      var photoUrl = _a?.nameplatePhotoUrl ?? '';
      final photo = _photo;
      if (photo != null) {
        photoUrl = await CarePlanService.uploadNameplate(code, photo) ?? photoUrl;
      }
      final appliance = HomeAppliance(
        id: code,
        clientId: widget.clientId,
        planId: _planId,
        type: _type.text.trim(),
        brand: _brand.text.trim(),
        model: _model.text.trim().toUpperCase(),
        serialNumber: _serial.text.trim().toUpperCase(),
        manufactureDate: _made.text.trim(),
        placement: _placement.text.trim(),
        notes: _notes.text.trim(),
        nameplatePhotoUrl: photoUrl,
        status: _a?.status ?? HomeAppliance.statusActive,
        createdAt: _a?.createdAt,
        stickerPrintedAt: _a?.stickerPrintedAt,
        serviceLog: _a?.serviceLog ?? const [],
      );
      await CarePlanService.saveAppliance(appliance, isNew: isNew);
      if (!mounted) return appliance;
      if (close) {
        Navigator.of(context).pop();
      } else {
        setState(() => _saving = false);
      }
      return appliance;
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack(context, '$e', error: true);
      }
      return null;
    }
  }

  Future<void> _saveAndPrint() async {
    final saved = await _save(close: false);
    if (saved == null || !mounted) return;
    await StickerPrintSheet.show(context, saved);
    if (mounted) Navigator.of(context).pop();
  }

  /// Заявка прямо с этого паспорта: ремонт или запись на ТО. Открывается
  /// карточка заявки, техника и план уже привязаны.
  Future<void> _job(bool maintenance) async {
    final a = _a;
    final plan = _plan;
    if (a == null || plan == null) return;
    try {
      final (jobId, job) = maintenance
          ? await CarePlanService.createMaintenanceJob(
              plan: plan,
              appliances: [a],
              clientPhone: widget.clientPhone,
              clientAddress:
                  plan.address.isNotEmpty ? plan.address : widget.clientAddress,
              clientEmail: widget.clientEmail,
            )
          : await CarePlanService.createRepairJob(
              plan: plan,
              appliance: a,
              clientPhone: widget.clientPhone,
              clientAddress:
                  plan.address.isNotEmpty ? plan.address : widget.clientAddress,
              clientEmail: widget.clientEmail,
            );
      if (!mounted) return;
      _snack(
        context,
        maintenance
            ? 'Заявка на ТО создана — поставьте дату визита'.tr
            : 'Заявка на ремонт создана'.tr,
      );
      await AppNav.openCard(
        context,
        key: AppNav.jobKey(jobId),
        builder: (_) => JobDetailsScreen(
          jobId: jobId,
          clientId: plan.clientId,
          jobData: job.toMap(),
        ),
      );
    } catch (e) {
      if (mounted) {
        _snack(context, '${'Не удалось создать заявку'.tr}: $e', error: true);
      }
    }
  }

  Future<void> _retire(bool retired) async {
    final a = _a;
    if (a == null) return;
    await CarePlanService.setApplianceRetired(a.id, retired);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final a = _a;
    final url = a == null ? '' : CarePlanService.passportUrl(a.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(a == null ? 'Новый паспорт техники'.tr : 'Паспорт техники'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          if (a != null)
            PopupMenuButton<String>(
              onSelected: (value) => _retire(value == 'retire'),
              itemBuilder: (_) => [
                if (a.isActive)
                  PopupMenuItem(value: 'retire', child: Text('Техника заменена — в архив'.tr))
                else
                  PopupMenuItem(value: 'restore', child: Text('Вернуть из архива'.tr)),
              ],
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _saveAndPrint,
                  icon: const Icon(Icons.print_outlined),
                  label: Text('Сохранить и печать'.tr),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _saving ? null : () => _save(),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check),
                  label: Text('Сохранить'.tr),
                ),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _reading ? null : () => _scan(ImageSource.camera),
                  icon: _reading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_camera_outlined),
                  label: Text(_reading ? 'ИИ читает шильдик…'.tr : 'Фото шильдика'.tr),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Из галереи'.tr,
                onPressed: _reading ? null : () => _scan(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
              ),
            ],
          ),
          if (_photo != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(_photo!, height: 140, fit: BoxFit.cover, cacheWidth: 600),
            ),
          ],
          const SizedBox(height: 14),
          _pickerField(_type, 'Тип техники'.tr, Icons.kitchen, _pickType),
          const SizedBox(height: 12),
          _pickerField(_brand, 'Бренд'.tr, Icons.sell_outlined, _pickBrand, editable: true),
          const SizedBox(height: 12),
          _field(_model, 'Модель'.tr, Icons.tag, caps: true),
          const SizedBox(height: 12),
          _field(_serial, 'Серийный номер'.tr, Icons.qr_code, caps: true),
          const SizedBox(height: 12),
          _monthField(),
          const SizedBox(height: 12),
          _field(_placement, 'Где стоит (кухня, подвал…)'.tr, Icons.place_outlined),
          const SizedBox(height: 12),
          _field(_notes, 'Заметки для себя'.tr, Icons.notes, lines: 2),
          if (plan != null && a != null && a.planId == plan.id && plan.isMember) ...[
            const SizedBox(height: 8),
            _dueBanner(plan),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: CarePlanStyle.color,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _job(true),
                    icon: const Icon(Icons.event_available, size: 18),
                    label: Text('Записать на ТО'.tr),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: CarePlanStyle.color,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _job(false),
                    icon: const Icon(Icons.build_outlined, size: 18),
                    label: Text('Заявка на ремонт'.tr),
                  ),
                ),
              ],
            ),
          ],
          if (plan != null) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _planId == plan.id,
              activeThumbColor: CarePlanStyle.color,
              onChanged: (on) => setState(() => _planId = on ? plan.id : ''),
              title: Text('Входит в Care Plan'.tr),
              subtitle: Text(
                '${'Договор'.tr} ${plan.contractNumber.isEmpty ? '' : '№${plan.contractNumber} '}· ${CarePlanStyle.statusLabel(plan.status)}',
              ),
              secondary: const Icon(CarePlanStyle.icon, color: CarePlanStyle.color),
            ),
          ],
          if (a != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cardMuted,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Страница паспорта (QR на наклейке)'.tr,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  SelectableText(url, style: TextStyle(color: AppColors.primaryOnCard)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => AppFeedback.copy(context, url),
                        icon: const Icon(Icons.copy, size: 18),
                        label: Text('Копировать'.tr),
                      ),
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text('Открыть'.tr),
                      ),
                    ],
                  ),
                  if (a.serviceLog.isNotEmpty) ...[
                    const Divider(),
                    Text('История ТО'.tr, style: const TextStyle(fontWeight: FontWeight.w800)),
                    for (final entry in a.serviceLog.reversed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_date.format(entry.date)} — ${entry.items.join(', ')}',
                          style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Та же строка срока ТО, что в списке техники клиента, только крупнее.
  Widget _dueBanner(CarePlan plan) {
    final days = plan.daysToMaintenance(DateTime.now());
    final color = days <= 0
        ? Colors.red
        : days <= CarePlanService.terms.remindDays
        ? const Color(0xFFEF6C00)
        : CarePlanStyle.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.build_circle_outlined, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              plan.maintenanceDueLine(
                DateTime.now(),
                remindDays: CarePlanService.terms.remindDays,
              ),
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  DateTime? _madeMonth() {
    final text = _made.text.trim();
    final match = RegExp(r'^(\d{4})(?:-(\d{1,2}))?').firstMatch(text);
    if (match == null) return null;
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2) ?? '') ?? 1;
    if (year == null || month < 1 || month > 12) return null;
    return DateTime(year, month);
  }

  String _madeLabel() {
    final month = _madeMonth();
    if (month == null) return 'Не указана'.tr;
    final title = DateFormat('LLLL yyyy', AppLocale.instance.dateLocale).format(month);
    return title[0].toUpperCase() + title.substring(1);
  }

  Future<void> _pickMade() async {
    final now = DateTime.now();
    final initial = _madeMonth() ?? DateTime(now.year, now.month);
    var picked = initial;
    final saved = await showModalBottomSheet<DateTime>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: 280,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      const SizedBox(width: 48),
                      Expanded(
                        child: Text(
                          'Дата выпуска'.tr,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext, picked),
                        icon: const Icon(Icons.check),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CupertinoTheme(
                    data: CupertinoThemeData(
                      brightness: AppColors.isDark ? Brightness.dark : Brightness.light,
                    ),
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.monthYear,
                      initialDateTime: initial,
                      minimumDate: DateTime(1980),
                      maximumDate: DateTime(now.year + 1, 12),
                      onDateTimeChanged: (value) => picked = value,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (saved == null || !mounted) return;
    setState(() {
      _made.text =
          '${saved.year}-${saved.month.toString().padLeft(2, '0')}';
    });
  }

  Widget _monthField() {
    return InkWell(
      onTap: _pickMade,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Дата выпуска'.tr,
          prefixIcon: const Icon(Icons.calendar_month_outlined),
          suffixIcon: const Icon(Icons.arrow_drop_down),
          border: const OutlineInputBorder(),
        ),
        child: Text(_madeLabel(), style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon, {bool caps = false, int lines = 1}) {
    return TextField(
      controller: c,
      minLines: lines,
      maxLines: lines,
      textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _pickerField(
    TextEditingController c,
    String label,
    IconData icon,
    VoidCallback onPick, {
    bool editable = false,
  }) {
    return TextField(
      controller: c,
      readOnly: !editable,
      onTap: editable ? null : onPick,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: IconButton(icon: const Icon(Icons.list), onPressed: onPick),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// Превью наклейки и печать на Phomemo M250.
class StickerPrintSheet extends StatefulWidget {
  final HomeAppliance appliance;

  const StickerPrintSheet({super.key, required this.appliance});

  static Future<void> show(BuildContext context, HomeAppliance appliance) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StickerPrintSheet(appliance: appliance),
    );
  }

  @override
  State<StickerPrintSheet> createState() => _StickerPrintSheetState();
}

class _StickerPrintSheetState extends State<StickerPrintSheet> {
  StickerPrinterSettings? _settings;
  StickerContent? _content;
  bool _printing = false;
  String _status = '';
  int _copies = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = await StickerPrinterService.loadSettings();
    final docs = await SettingsService.loadDocumentSettings();
    await CarePlanService.loadTerms();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _content = StickerContent.forAppliance(
        widget.appliance,
        company: StickerContent.shopName,
        phone: docs.companyPhone,
        url: CarePlanService.passportUrl(widget.appliance.id),
      );
    });
  }

  Future<void> _openPrinter() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const StickerPrinterSettingsPage()),
    );
    await _load();
  }

  Future<void> _print() async {
    final settings = _settings;
    final content = _content;
    if (settings == null || content == null || _printing) return;
    if (!settings.hasPrinter) {
      await _openPrinter();
      return;
    }
    setState(() {
      _printing = true;
      _status = 'Печатаю…'.tr;
    });
    try {
      final (raster, height) = await StickerRenderer.renderRaster(content, settings);
      for (var i = 0; i < _copies; i++) {
        await StickerPrinterService.printRaster(
          raster: raster,
          heightLines: height,
          settings: settings,
        );
      }
      await CarePlanService.markStickerPrinted(widget.appliance.id);
      if (!mounted) return;
      AppFeedback.pleasant();
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final content = _content;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Наклейка паспорта'.tr,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            if (settings == null || content == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else ...[
              StickerPreview(content: content, settings: settings),
              const SizedBox(height: 10),
              Text(
                [
                  settings.hasPrinter
                      ? settings.printerName
                      : 'Принтер не выбран'.tr,
                  '${settings.labelWidthMm.round()}×${settings.labelHeightMm.round()} мм',
                ].join(' · '),
                style: TextStyle(color: AppColors.inkMuted),
              ),
              TextButton.icon(
                onPressed: _openPrinter,
                icon: const Icon(Icons.settings_bluetooth, size: 18),
                label: Text('Принтер и размер наклейки'.tr),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Копий'.tr),
                  IconButton(
                    onPressed: _copies > 1 ? () => setState(() => _copies--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$_copies', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  IconButton(
                    onPressed: _copies < 5 ? () => setState(() => _copies++) : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _printing ? AppColors.primaryOnCard : Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _printing ? null : _print,
                  icon: const Icon(Icons.print),
                  label: Text(
                    settings.hasPrinter ? 'Печатать'.tr : 'Выбрать принтер'.tr,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// «ТО выполнено»: какие паспорта обслужены. В историю каждого ложится
/// стандартный список работ по типу техники (его видит клиент по QR).
class MaintenanceDoneSheet extends StatefulWidget {
  final CarePlan plan;
  final String jobId;

  const MaintenanceDoneSheet({super.key, required this.plan, this.jobId = ''});

  static Future<void> show(BuildContext context, {required CarePlan plan, String jobId = ''}) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => MaintenanceDoneSheet(plan: plan, jobId: jobId),
    );
  }

  @override
  State<MaintenanceDoneSheet> createState() => _MaintenanceDoneSheetState();
}

class _MaintenanceDoneSheetState extends State<MaintenanceDoneSheet> {
  late final List<HomeAppliance> _items = CarePlanService.appliancesForPlan(widget.plan.id);
  late final Set<String> _picked = {for (final a in _items) a.id};
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await CarePlanService.markMaintenanceDone(
        plan: widget.plan,
        serviced: [for (final a in _items) if (_picked.contains(a.id)) a],
        jobId: widget.jobId,
      );
      if (!mounted) return;
      AppFeedback.pleasant();
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack(context, '$e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = CarePlan.addMonths(DateTime.now(), widget.plan.maintenanceMonths);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ТО выполнено'.tr,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                '${'Следующее ТО'.tr}: ${_date.format(next)}',
                style: TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'К плану не привязано ни одного паспорта — отметится только дата ТО.'.tr,
                          style: TextStyle(color: AppColors.inkMuted),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final a in _items)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _picked.contains(a.id),
                              activeColor: CarePlanStyle.color,
                              onChanged: (on) => setState(() {
                                if (on == true) {
                                  _picked.add(a.id);
                                } else {
                                  _picked.remove(a.id);
                                }
                              }),
                              title: Text(trAny(a.displayName)),
                              subtitle: Text(
                                MaintenanceChecklist.forType(a.type).join(' · '),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: CarePlanStyle.color),
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.task_alt),
                  label: Text('Сохранить в паспорта'.tr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Оплата подписки прямо у клиента: QR со ссылкой Stripe на экране (клиент
/// сканирует своим телефоном) или та же ссылка в SMS по нажатию мастера.
class CarePlanPaymentSheet extends StatefulWidget {
  final CarePlan plan;
  final String phone;

  const CarePlanPaymentSheet({super.key, required this.plan, required this.phone});

  static Future<void> show(BuildContext context, {required CarePlan plan, required String phone}) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => CarePlanPaymentSheet(plan: plan, phone: phone),
    );
  }

  @override
  State<CarePlanPaymentSheet> createState() => _CarePlanPaymentSheetState();
}

class _CarePlanPaymentSheetState extends State<CarePlanPaymentSheet> {
  CarePlanCheckout? _checkout;
  String _error = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  Future<void> _create() async {
    try {
      final checkout = await StripeService.createCarePlanCheckout(planId: widget.plan.id);
      if (mounted) setState(() => _checkout = checkout);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _sms() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final result = await StripeService.createCarePlanCheckout(
        planId: widget.plan.id,
        sendSms: true,
        to: widget.phone,
      );
      if (!mounted) return;
      _snack(
        context,
        result.smsSent
            ? 'Ссылка на оплату отправлена в SMS'.tr
            : '${'SMS не ушло'.tr}: ${result.smsError ?? ''}',
        error: !result.smsSent,
      );
      if (result.smsSent) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _snack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkout = _checkout;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Оплата Care Plan'.tr,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Клиент сканирует QR своим телефоном и вводит карту — дальше Stripe списывает сам каждый месяц.'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 14),
            if (_error.isNotEmpty)
              Text(_error, style: const TextStyle(color: Colors.red))
            else if (checkout == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else ...[
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: CustomPaint(painter: _QrPainter(checkout.url)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_money(checkout.monthlyTotal)} / ${'мес'.tr}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => AppFeedback.copy(context, checkout.url),
                      icon: const Icon(Icons.copy, size: 18),
                      label: Text('Копировать'.tr),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.phone.isEmpty || _sending ? null : _sms,
                      icon: const Icon(Icons.sms_outlined, size: 18),
                      label: Text('Отправить SMS'.tr),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final String data;

  _QrPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final QrImage image;
    try {
      image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    } catch (_) {
      return;
    }
    final n = image.moduleCount;
    final module = size.shortestSide / n;
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          canvas.drawRect(Rect.fromLTWH(c * module, r * module, module + 0.5, module + 0.5), ink);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.data != data;
}
