import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/care_plan.dart';
import '../../../services/care_plan_service.dart';
import '../../../shared/app_nav.dart';
import '../../care_plan/care_plan_widgets.dart';
import '../../clients/client_details_screen.dart';
import '../widgets/settings_ui.dart';

/// Настройки → Care Plan: условия подписки для новых договоров и список всех
/// клиентов на плане. Условия старых договоров не меняются — они записаны в
/// самом плане на день подписания.
class CarePlanSettingsPage extends StatefulWidget {
  const CarePlanSettingsPage({super.key});

  @override
  State<CarePlanSettingsPage> createState() => _CarePlanSettingsPageState();
}

class _CarePlanSettingsPageState extends State<CarePlanSettingsPage> {
  final _price = TextEditingController();
  final _discount = TextEditingController();
  final _minTerm = TextEditingController();
  final _waiting = TextEditingController();
  final _coolingOff = TextEditingController();
  final _interval = TextEditingController();
  final _first = TextEditingController();
  final _remind = TextEditingController();
  final _baseUrl = TextEditingController();
  CarePlanTerms _saved = const CarePlanTerms();
  bool _loading = true;

  List<TextEditingController> get _all => [
    _price,
    _discount,
    _minTerm,
    _waiting,
    _coolingOff,
    _interval,
    _first,
    _remind,
    _baseUrl,
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_changed);
    }
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  void _fill(CarePlanTerms t) {
    _price.text = _num(t.monthlyPrice);
    _discount.text = _num(t.discountPercent);
    _minTerm.text = '${t.minTermMonths}';
    _waiting.text = '${t.waitingDays}';
    _coolingOff.text = '${t.coolingOffDays}';
    _interval.text = '${t.maintenanceMonths}';
    _first.text = '${t.firstMaintenanceDays}';
    _remind.text = '${t.remindDays}';
    _baseUrl.text = t.passportBaseUrl;
  }

  Future<void> _load() async {
    final terms = await CarePlanService.loadTerms();
    if (!mounted) return;
    _fill(terms);
    setState(() {
      _saved = terms;
      _loading = false;
    });
  }

  CarePlanTerms get _current => CarePlanTerms.fromConfig({
    'carePlanPrice': _price.text.replaceAll(',', '.'),
    'carePlanDiscountPercent': _discount.text.replaceAll(',', '.'),
    'carePlanMinTermMonths': _minTerm.text,
    'carePlanWaitingDays': _waiting.text,
    'carePlanCoolingOffDays': _coolingOff.text,
    'carePlanMaintenanceMonths': _interval.text,
    'carePlanFirstMaintenanceDays': _first.text,
    'carePlanRemindDays': _remind.text,
    'passportBaseUrl': _baseUrl.text,
  });

  bool get _dirty {
    if (_loading) return false;
    final a = _current.toConfig();
    final b = _saved.toConfig();
    for (final key in a.keys) {
      if ('${a[key]}' != '${b[key]}') return true;
    }
    return false;
  }

  Future<bool> _save() async {
    final next = _current;
    await CarePlanService.saveTerms(next);
    if (!mounted) return true;
    _fill(next);
    setState(() => _saved = next);
    return true;
  }

  void _openClient(CarePlan plan) {
    unawaited(
      AppNav.openCard(
        context,
        key: AppNav.clientKey(plan.clientId),
        builder: (_) => ClientDetailsScreen(
          clientId: plan.clientId,
          clientData: {'fullName': plan.clientName},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Care Plan',
      dirty: _dirty,
      onSave: _save,
      onDiscard: () => _fill(_saved),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Text(
                  'Подписка на гарантийное обслуживание. Условия ниже — для новых договоров; уже подписанные планы живут по своим.'
                      .tr,
                  style: TextStyle(color: AppColors.inkMuted, height: 1.35),
                ),
                const SizedBox(height: 14),
                _row(_price, 'Цена в месяц, \$ (без HST)'.tr, Icons.payments_outlined),
                _row(_discount, 'Скидка на работу, % (100 — ремонт бесплатно)'.tr, Icons.percent),
                _row(_minTerm, 'Минимальный срок, мес.'.tr, Icons.event_repeat),
                _row(_coolingOff, 'Отказ без причины, дней (Онтарио — 10)'.tr, Icons.undo),
                _row(_waiting, 'Ожидание льгот после подписания, дней'.tr, Icons.hourglass_bottom),
                _row(_first, 'Первое ТО через, дней'.tr, Icons.build_circle_outlined),
                _row(_interval, 'ТО раз в, мес.'.tr, Icons.autorenew),
                _row(_remind, 'Напомнить о ТО за, дней'.tr, Icons.notifications_active_outlined),
                _row(_baseUrl, 'Адрес страницы паспорта'.tr, Icons.link, number: false),
                Text(
                  'Адрес печатается в QR на наклейках — после первой печати его лучше не менять.'.tr,
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                ),
                const SizedBox(height: 22),
                _registry(),
              ],
            ),
    );
  }

  Widget _row(
    TextEditingController c,
    String label,
    IconData icon, {
    bool number = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.url,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _registry() {
    return ValueListenableBuilder<int>(
      valueListenable: CarePlanService.revision,
      builder: (context, _, _) {
        final plans = [...CarePlanService.plans]
          ..sort((a, b) {
            final byStatus = CarePlan.statuses
                .indexOf(a.status)
                .compareTo(CarePlan.statuses.indexOf(b.status));
            if (byStatus != 0) return byStatus;
            return a.clientName.toLowerCase().compareTo(b.clientName.toLowerCase());
          });
        final members = plans.where((p) => p.isMember).length;
        final terms = CarePlanService.terms;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${'Клиенты на плане'.tr}: $members'
              '${members > 0 ? ' · ${'≈'} \$${(members * terms.monthlyPrice).toStringAsFixed(0)}/${'мес'.tr}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            if (plans.isEmpty)
              Text(
                'Пока ни одного. План оформляется в карточке клиента.'.tr,
                style: TextStyle(color: AppColors.inkMuted),
              ),
            for (final plan in plans)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  leading: Icon(
                    CarePlanStyle.icon,
                    color: CarePlanStyle.statusColor(plan.status),
                  ),
                  title: Text(
                    plan.clientName.isEmpty ? 'Клиент'.tr : plan.clientName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    [
                      if (plan.contractNumber.isNotEmpty) '№${plan.contractNumber}',
                      DateFormat('dd.MM.yyyy').format(plan.signedAt),
                      '${'ТО'.tr} ${DateFormat('dd.MM.yyyy').format(plan.maintenanceDue)}',
                    ].join(' · '),
                  ),
                  trailing: CarePlanStatusChip(status: plan.status),
                  onTap: () => _openClient(plan),
                ),
              ),
          ],
        );
      },
    );
  }
}
