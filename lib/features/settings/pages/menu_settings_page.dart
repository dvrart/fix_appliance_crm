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
  bool _statistics = true;
  bool _reports = true;
  bool _expenses = true;
  bool _invoices = true;
  bool _trash = true;
  bool _savedAi = true;
  bool _savedWarehouse = true;
  bool _savedStatistics = true;
  bool _savedReports = true;
  bool _savedExpenses = true;
  bool _savedInvoices = true;
  bool _savedTrash = true;

  bool get _dirty =>
      !_loading &&
      (_ai != _savedAi ||
          _warehouse != _savedWarehouse ||
          _statistics != _savedStatistics ||
          _reports != _savedReports ||
          _expenses != _savedExpenses ||
          _invoices != _savedInvoices ||
          _trash != _savedTrash);

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
      _statistics = SettingsService.menuFlag(data, 'menuShowStatistics');
      _reports = SettingsService.menuFlag(data, 'menuShowReports');
      _expenses = SettingsService.menuFlag(data, 'menuShowExpenses');
      _invoices = SettingsService.menuFlag(data, 'menuShowInvoices') ||
          SettingsService.menuFlag(data, 'menuShowEstimates');
      _trash = SettingsService.menuFlag(data, 'menuShowTrash');
      _savedAi = _ai;
      _savedWarehouse = _warehouse;
      _savedStatistics = _statistics;
      _savedReports = _reports;
      _savedExpenses = _expenses;
      _savedInvoices = _invoices;
      _savedTrash = _trash;
      _loading = false;
    });
  }

  Future<bool> _save() async {
    await SettingsService.updateConfigMap({
      'menuShowAi': _ai,
      'menuShowWarehouse': _warehouse,
      'menuShowStatistics': _statistics,
      'menuShowReports': _reports,
      'menuShowExpenses': _expenses,
      'menuShowInvoices': _invoices,
      'menuShowEstimates': _invoices,
      'menuShowTrash': _trash,
    });
    if (!mounted) return true;
    setState(() {
      _savedAi = _ai;
      _savedWarehouse = _warehouse;
      _savedStatistics = _statistics;
      _savedReports = _reports;
      _savedExpenses = _expenses;
      _savedInvoices = _invoices;
      _savedTrash = _trash;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Меню приложения'.tr,
      dirty: _dirty,
      onSave: _loading ? null : _save,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Какие плитки показывать в боковом меню. Звонки и переписка — в нижней вкладке «Связь». Настройки всегда остаются.'.tr,
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
                SettingsTileSection(
                  title: 'Меню'.tr,
                  tiles: [
                    _tile('Ассистент'.tr, Icons.mic, Colors.deepPurple, _ai, (v) {
                      setState(() => _ai = v);
                    }),
                    _tile(
                      'Склад'.tr,
                      Icons.inventory_2_outlined,
                      Colors.orange,
                      _warehouse,
                      (v) => setState(() => _warehouse = v),
                    ),
                    _tile(
                      'Статистика'.tr,
                      Icons.query_stats,
                      const Color(0xFF1565C0),
                      _statistics,
                      (v) => setState(() => _statistics = v),
                    ),
                    _tile('Отчеты'.tr, Icons.bar_chart, Colors.green, _reports,
                        (v) => setState(() => _reports = v)),
                    _tile(
                      'Расходы'.tr,
                      Icons.receipt_long_outlined,
                      Colors.deepOrange,
                      _expenses,
                      (v) => setState(() => _expenses = v),
                    ),
                    _tile('Счета'.tr, Icons.receipt_long, Colors.teal, _invoices,
                        (v) => setState(() => _invoices = v)),
                    _tile(
                      'Корзина'.tr,
                      Icons.delete_outline,
                      const Color(0xFFE53935),
                      _trash,
                      (v) => setState(() => _trash = v),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _tile(
    String title,
    IconData icon,
    Color color,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SettingsHubTile(
      title: title,
      subtitle: value ? 'Вкл'.tr : 'Скрыто'.tr,
      icon: icon,
      color: color,
      active: value,
      onTap: () => onChanged(!value),
    );
  }
}
