import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';
import '../../../core/l10n/app_locale.dart';

class MenuSettingsPage extends StatefulWidget {
  const MenuSettingsPage({super.key});

  @override
  State<MenuSettingsPage> createState() => _MenuSettingsPageState();
}

class _MenuSettingsPageState extends State<MenuSettingsPage> {
  bool _loading = true;
  bool _ai = true;
  bool _warehouse = true;
  bool _reports = true;
  bool _invoices = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SettingsService.loadConfig();
    if (!mounted) return;
    setState(() {
      _ai = SettingsService.menuFlag(data, 'menuShowAi');
      _warehouse = SettingsService.menuFlag(data, 'menuShowWarehouse');
      _reports = SettingsService.menuFlag(data, 'menuShowReports');
      _invoices = SettingsService.menuFlag(data, 'menuShowInvoices') ||
          SettingsService.menuFlag(data, 'menuShowEstimates');
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Меню приложения'.tr,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Какие плитки показывать в боковом меню. Звонки и переписка — в нижней вкладке «Связь». Настройки всегда остаются.'.tr,
                    style: TextStyle(color: Colors.black54),
                  ),
                ),
                SettingsGroup(
                  children: [
                    _flag('Ассистент'.tr, Icons.mic, Colors.deepPurple, _ai, (v) {
                      setState(() => _ai = v);
                      SettingsService.updateConfig('menuShowAi', v);
                    }),
                    _flag('Склад'.tr, Icons.inventory_2_outlined, Colors.orange, _warehouse, (v) {
                      setState(() => _warehouse = v);
                      SettingsService.updateConfig('menuShowWarehouse', v);
                    }),
                    _flag(
                      'Отчеты'.tr,
                      Icons.bar_chart,
                      Colors.green,
                      _reports,
                      (v) {
                        setState(() => _reports = v);
                        SettingsService.updateConfig('menuShowReports', v);
                      },
                    ),
                    _flag(
                      'Счета'.tr,
                      Icons.receipt_long,
                      Colors.teal,
                      _invoices,
                      (v) {
                        setState(() => _invoices = v);
                        SettingsService.updateConfig('menuShowInvoices', v);
                        SettingsService.updateConfig('menuShowEstimates', v);
                      },
                      showDivider: false,
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _flag(
    String title,
    IconData icon,
    Color color,
    bool value,
    ValueChanged<bool> onChanged, {
    bool showDivider = true,
  }) {
    return SettingsRow(
      title: title,
      subtitle: value ? 'Показано в меню'.tr : 'Скрыто'.tr,
      icon: icon,
      iconColor: color,
      showDivider: showDivider,
      trailing: Switch(
        activeThumbColor: AppColors.accent,
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
