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
  String _defaultTax = SettingsService.taxHst;
  String _hstNumber = '';

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
      _defaultTax = SettingsService.readDefaultTax(data);
      _hstNumber = docs.hstNumber;
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
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                SettingsTileSection(
                  title: context.tr('Документы', 'Documents'),
                  tiles: [
                    SettingsHubTile(
                      title: context.tr('Счета', 'Invoices'),
                      subtitle: context.tr('PDF / сметы', 'PDF / estimates'),
                      icon: Icons.description,
                      color: AppColors.primary,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DocumentSettingsPage(),
                          ),
                        );
                      },
                    ),
                    SettingsHubTile(
                      title: context.tr('Налог', 'Tax'),
                      subtitle: _taxLabel(_defaultTax),
                      icon: Icons.receipt_long,
                      color: Colors.green,
                      onTap: _pickDefaultTax,
                    ),
                    SettingsHubTile(
                      title: 'HST / GST',
                      subtitle: _hstNumber.isEmpty
                          ? context.tr('Номер', 'Number')
                          : _hstNumber,
                      icon: Icons.numbers,
                      color: Colors.blueGrey,
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
