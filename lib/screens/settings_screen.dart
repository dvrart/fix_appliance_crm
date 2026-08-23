import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/haptics.dart';
import '../features/settings/pages/secretary_learn_page.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _useSignature = true;
  bool _applyHST = true;
  bool _darkTheme = false;
  bool _weekendInCalendar = false;
  bool _ai = true;
  bool _warehouse = true;
  bool _statistics = true;
  bool _reports = true;
  bool _expenses = true;
  bool _invoices = true;
  bool _trash = true;

  DocumentReference<Map<String, dynamic>> get _configRef =>
      FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('settings')
          .doc('config');

  @override
  void initState() {
    super.initState();
    _loadMenu();
  }

  Future<void> _loadMenu() async {
    final doc = await _configRef.get();
    final data = doc.data() ?? <String, dynamic>{};
    bool flag(String key) => data[key] is bool ? data[key] as bool : true;
    if (!mounted) return;
    setState(() {
      _ai = flag('menuShowAi');
      _warehouse = flag('menuShowWarehouse');
      _statistics = flag('menuShowStatistics');
      _reports = flag('menuShowReports');
      _expenses = flag('menuShowExpenses');
      _invoices = flag('menuShowInvoices') || flag('menuShowEstimates');
      _trash = flag('menuShowTrash');
    });
  }

  Future<void> _setFlag(String key, bool value) {
    return _configRef.set({key: value}, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Настройки системы',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        toolbarHeight: 48,
        elevation: 0,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'ФИНАНСЫ И ДОКУМЕНТЫ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Электронная подпись'),
            subtitle: const Text('Запрашивать подпись клиента в инвойсе'),
            value: _useSignature,
            onChanged: (val) {
              AppHaptics.button();
              setState(() => _useSignature = val);
            },
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Налог (HST 13%)'),
            subtitle: const Text('Автоматически считать налог в сметах'),
            value: _applyHST,
            onChanged: (val) {
              AppHaptics.button();
              setState(() => _applyHST = val);
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'МЕНЮ ПРИЛОЖЕНИЯ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Какие плитки показывать в боковом меню. Настройки всегда остаются.',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ),
          _menuSwitch('Ассистент', Icons.mic, Colors.deepPurple, _ai, (v) {
            setState(() => _ai = v);
            _setFlag('menuShowAi', v);
          }),
          _menuSwitch(
            'Склад',
            Icons.inventory_2_outlined,
            Colors.orange,
            _warehouse,
            (v) {
              setState(() => _warehouse = v);
              _setFlag('menuShowWarehouse', v);
            },
          ),
          _menuSwitch(
            'Статистика',
            Icons.query_stats,
            const Color(0xFF1565C0),
            _statistics,
            (v) {
              setState(() => _statistics = v);
              _setFlag('menuShowStatistics', v);
            },
          ),
          _menuSwitch('Отчеты', Icons.bar_chart, Colors.green, _reports, (v) {
            setState(() => _reports = v);
            _setFlag('menuShowReports', v);
          }),
          _menuSwitch(
            'Расходы',
            Icons.receipt_long_outlined,
            Colors.deepOrange,
            _expenses,
            (v) {
              setState(() => _expenses = v);
              _setFlag('menuShowExpenses', v);
            },
          ),
          _menuSwitch('Счета', Icons.receipt_long, Colors.teal, _invoices, (v) {
            setState(() => _invoices = v);
            _setFlag('menuShowInvoices', v);
            _setFlag('menuShowEstimates', v);
          }),
          _menuSwitch(
            'Корзина',
            Icons.delete_outline,
            const Color(0xFFE53935),
            _trash,
            (v) {
              setState(() => _trash = v);
              _setFlag('menuShowTrash', v);
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'СЕКРЕТАРЬ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over, color: Color(0xFF14557F)),
            title: const Text('Правила и обучение'),
            subtitle: const Text('Как секретарь отвечает на звонках'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              AppHaptics.button();
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SecretaryLearnPage()),
              );
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'ИНТЕРФЕЙС И КАЛЕНДАРЬ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Темная тема'),
            subtitle: const Text('Ночной режим (В разработке)'),
            value: _darkTheme,
            onChanged: (val) {
              AppHaptics.button();
              setState(() => _darkTheme = val);
            },
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Выходные в календаре'),
            subtitle: const Text('Показывать субботу и воскресенье'),
            value: _weekendInCalendar,
            onChanged: (val) {
              AppHaptics.button();
              setState(() => _weekendInCalendar = val);
              _setFlag('weekendInCalendar', val);
            },
          ),
        ],
      ),
    );
  }

  Widget _menuSwitch(
    String title,
    IconData icon,
    Color color,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      activeColor: const Color(0xFFFCC520),
      secondary: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(value ? 'Показано в меню' : 'Скрыто'),
      value: value,
      onChanged: (v) {
        AppHaptics.button();
        onChanged(v);
      },
    );
  }
}
