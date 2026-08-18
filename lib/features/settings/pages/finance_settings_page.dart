import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';
import 'document_settings_page.dart';

class FinanceSettingsPage extends StatefulWidget {
  const FinanceSettingsPage({super.key});

  @override
  State<FinanceSettingsPage> createState() => _FinanceSettingsPageState();
}

class _FinanceSettingsPageState extends State<FinanceSettingsPage> {
  bool _loading = true;
  bool _useSignature = true;
  String _defaultTax = SettingsService.taxHst;
  String _hstNumber = '';
  double _markup = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SettingsService.loadConfig();
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() {
      _useSignature = data['useSignature'] ?? true;
      _defaultTax = SettingsService.readDefaultTax(data);
      _hstNumber = docs.hstNumber;
      _markup = SettingsService.readPartsMarkupPercent(data);
      _loading = false;
    });
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
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(context.tr('Налог по умолчанию', 'Default tax')),
                subtitle: Text(
                  context.tr(
                    'В каждом счёте налог всё равно можно сменить',
                    'You can still change tax on each invoice',
                  ),
                ),
              ),
              RadioListTile<String>(
                title: Text(context.tr('HST 13%', 'HST 13%')),
                value: SettingsService.taxHst,
                groupValue: _defaultTax,
                onChanged: (value) => Navigator.pop(context, value),
              ),
              RadioListTile<String>(
                title: Text(context.tr('GST 5%', 'GST 5%')),
                subtitle: Text(
                  context.tr(
                    'Например, для First Nations',
                    'For example, First Nations',
                  ),
                ),
                value: SettingsService.taxGst,
                groupValue: _defaultTax,
                onChanged: (value) => Navigator.pop(context, value),
              ),
              RadioListTile<String>(
                title: Text(context.tr('Без налога (0%)', 'No tax (0%)')),
                value: SettingsService.taxNone,
                groupValue: _defaultTax,
                onChanged: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
        );
      },
    );
    if (next == null || !mounted) return;
    setState(() => _defaultTax = next);
    await SettingsService.setDefaultTax(next);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Финансы', 'Finance'),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('Счета и сметы', 'Invoices & estimates'),
                      subtitle: context.tr(
                        'Шаблоны SMS. PDF всегда на английском',
                        'SMS templates. PDFs are always in English',
                      ),
                      icon: Icons.description,
                      iconColor: AppColors.primary,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DocumentSettingsPage(),
                          ),
                        );
                      },
                    ),
                    SettingsRow(
                      title: context.tr('Электронная подпись', 'E-signature'),
                      subtitle: context.tr(
                        'Спрашивать подпись в конце работы',
                        'Ask for a signature at the end of the job',
                      ),
                      icon: Icons.draw,
                      iconColor: Colors.orange,
                      trailing: Switch(
                        activeThumbColor: AppColors.accent,
                        value: _useSignature,
                        onChanged: (val) {
                          setState(() => _useSignature = val);
                          SettingsService.updateConfig('useSignature', val);
                        },
                      ),
                    ),
                    SettingsRow(
                      title: context.tr('Налог по умолчанию', 'Default tax'),
                      subtitle: context.tr(
                        '${_taxLabel(_defaultTax)} — в счёте можно выбрать другой',
                        '${_taxLabel(_defaultTax)} — change it on each invoice',
                      ),
                      icon: Icons.receipt_long,
                      iconColor: Colors.green,
                      onTap: _pickDefaultTax,
                    ),
                    SettingsRow(
                      title: context.tr('Наценка на запчасти', 'Parts markup'),
                      subtitle: context.tr(
                        _markup <= 0
                            ? 'Берётся цена со склада'
                            : '${_markup.toStringAsFixed(0)}% к закупочной',
                        _markup <= 0
                            ? 'Uses the warehouse sell price'
                            : '${_markup.toStringAsFixed(0)}% on cost',
                      ),
                      icon: Icons.percent,
                      iconColor: Colors.teal,
                      onTap: () async {
                        final ctrl = TextEditingController(
                          text: _markup <= 0 ? '' : _markup.toStringAsFixed(0),
                        );
                        final saved = await showDialog<double>(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              title: Text(
                                context.tr('Наценка на запчасти', 'Parts markup'),
                              ),
                              content: TextField(
                                controller: ctrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  suffixText: '%',
                                  hintText: '0',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text('Отмена'.tr),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(
                                    context,
                                    double.tryParse(ctrl.text.trim()) ?? 0,
                                  ),
                                  child: Text('Сохранить'.tr),
                                ),
                              ],
                            );
                          },
                        );
                        if (saved == null || !mounted) return;
                        final next = saved.clamp(0, 300).toDouble();
                        setState(() => _markup = next);
                        await SettingsService.updateConfig(
                          'partsMarkupPercent',
                          next,
                        );
                      },
                    ),
                    SettingsRow(
                      title: context.tr('HST / GST номер', 'HST / GST number'),
                      subtitle: _hstNumber.isEmpty
                          ? context.tr(
                              'Не указан — для счетов и PDF',
                              'Not set — used on invoices and PDFs',
                            )
                          : _hstNumber,
                      icon: Icons.numbers,
                      iconColor: Colors.blueGrey,
                      showDivider: false,
                      onTap: () async {
                        final saved = await showHstNumberDialog(
                          context: context,
                          initialValue: _hstNumber,
                        );
                        if (saved == null || !mounted) return;
                        await SettingsService.updateHstNumber(saved);
                        if (!mounted) return;
                        setState(() => _hstNumber = saved);
                      },
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
