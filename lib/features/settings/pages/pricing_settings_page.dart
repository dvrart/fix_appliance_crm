import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';

/// Прайс лежит в `settings/config`, потому что его читает и телефонный секретарь.
class PricingSettingsPage extends StatefulWidget {
  const PricingSettingsPage({super.key});

  @override
  State<PricingSettingsPage> createState() => _PricingSettingsPageState();
}

class _PricingSettingsPageState extends State<PricingSettingsPage> {
  final _serviceCall = TextEditingController();
  final _hourly = TextEditingController();
  final _minimum = TextEditingController();
  final _markup = TextEditingController();

  bool _loading = true;
  bool _dirty = false;
  String _defaultTax = SettingsService.taxHst;
  String _savedTax = SettingsService.taxHst;

  @override
  void initState() {
    super.initState();
    for (final controller in [_serviceCall, _hourly, _minimum, _markup]) {
      controller.addListener(_markDirty);
    }
    _load();
  }

  @override
  void dispose() {
    for (final controller in [_serviceCall, _hourly, _minimum, _markup]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  static String _numberText(double value) {
    if (value <= 0) return '';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }

  static double _parse(TextEditingController controller) {
    final raw = controller.text.replaceAll(',', '.').replaceAll('\$', '').trim();
    return double.tryParse(raw) ?? 0;
  }

  Future<void> _load() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    setState(() {
      _serviceCall.text = _numberText(
        SettingsService.readServiceCallFee(config),
      );
      _hourly.text = _numberText(SettingsService.readHourlyRate(config));
      _minimum.text = _numberText(SettingsService.readMinimumCharge(config));
      _markup.text = _numberText(
        SettingsService.readPartsMarkupPercent(config),
      );
      _defaultTax = SettingsService.readDefaultTax(config);
      _savedTax = _defaultTax;
      _loading = false;
      _dirty = false;
    });
  }

  Future<bool> _save() async {
    await SettingsService.savePricing(
      serviceCallFee: _parse(_serviceCall),
      hourlyRate: _parse(_hourly),
      minimumCharge: _parse(_minimum),
      partsMarkupPercent: _parse(_markup),
    );
    if (_defaultTax != _savedTax) {
      await SettingsService.setDefaultTax(_defaultTax);
      _savedTax = _defaultTax;
    }
    if (!mounted) return true;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            'Прайс сохранён. Секретарь называет эти цены.',
            'Prices saved. The phone secretary quotes them.',
          ),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    return true;
  }

  String _taxLabel(String tax) {
    switch (tax) {
      case SettingsService.taxGst:
        return context.tr('GST 5%', 'GST 5%');
      case SettingsService.taxNone:
        return context.tr('Без налога (0%)', 'No tax (0%)');
      default:
        return context.tr('HST 13%', 'HST 13%');
    }
  }

  Future<void> _pickDefaultTax() async {
    final next = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                context.tr('Налог по умолчанию', 'Default tax'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                context.tr(
                  'В каждом счёте налог всё равно можно сменить',
                  'You can still change tax on each invoice',
                ),
              ),
            ),
            for (final tax in const [
              SettingsService.taxHst,
              SettingsService.taxGst,
              SettingsService.taxNone,
            ])
              ListTile(
                title: Text(_taxLabel(tax)),
                trailing: tax == _defaultTax
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, tax),
              ),
          ],
        ),
      ),
    );
    if (next == null || !mounted) return;
    setState(() {
      _defaultTax = next;
      _dirty = _dirty || next != _savedTax;
    });
  }

  Widget _moneyField({
    required TextEditingController controller,
    required String title,
    required String hint,
    required IconData icon,
    required Color color,
    String prefix = '\$',
    String? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    hint,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      prefixText: suffix == null ? prefix : null,
                      suffixText: suffix,
                      hintText: '0',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Прайс', 'Prices'),
      dirty: _dirty,
      onSave: _save,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    context.tr(
                      'Эти цены называет телефонный секретарь и подставляет счёт.',
                      'The phone secretary quotes these and invoices use them.',
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                      height: 1.3,
                    ),
                  ),
                ),
                _moneyField(
                  controller: _serviceCall,
                  title: context.tr('Вызов', 'Service call'),
                  hint: context.tr(
                    'Диагностика. Не берём, если клиент согласился на ремонт',
                    'Diagnostic fee, waived when the repair is approved',
                  ),
                  icon: Icons.directions_car,
                  color: Colors.orange,
                ),
                _moneyField(
                  controller: _hourly,
                  title: context.tr('Ставка за час', 'Hourly rate'),
                  hint: context.tr(
                    'Работа мастера. 0 — не показывать',
                    'Labour per hour. 0 — hide it',
                  ),
                  icon: Icons.schedule,
                  color: Colors.indigo,
                ),
                _moneyField(
                  controller: _minimum,
                  title: context.tr('Минимальный чек', 'Minimum charge'),
                  hint: context.tr(
                    'Меньше этой суммы счёт не выставляем. 0 — нет минимума',
                    'Never invoice below this. 0 — no minimum',
                  ),
                  icon: Icons.price_check,
                  color: Colors.green,
                ),
                _moneyField(
                  controller: _markup,
                  title: context.tr('Наценка на запчасти', 'Parts markup'),
                  hint: context.tr(
                    'Прибавляется к закупочной цене со склада',
                    'Added on top of the warehouse cost price',
                  ),
                  icon: Icons.trending_up,
                  color: Colors.deepPurple,
                  suffix: '%',
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('Налог по умолчанию', 'Default tax'),
                      subtitle: _taxLabel(_defaultTax),
                      icon: Icons.receipt_long,
                      iconColor: Colors.teal,
                      showDivider: false,
                      onTap: _pickDefaultTax,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
