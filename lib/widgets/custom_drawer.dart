import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/haptics.dart';
import '../screens/reports_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/warehouse_screen.dart';

class CustomDrawer extends StatelessWidget {
  const CustomDrawer({super.key});

  DocumentReference<Map<String, dynamic>> get _configRef =>
      FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('settings')
          .doc('config');

  bool _flag(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is bool) return value;
    return true;
  }

  void _open(BuildContext context, Widget page) {
    AppHaptics.button();
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _configRef.snapshots(),
        builder: (context, snapshot) {
          final config = snapshot.data?.data() ?? <String, dynamic>{};
          return Column(
            children: [
              const UserAccountsDrawerHeader(
                decoration: BoxDecoration(color: Color(0xFF14557F)),
                currentAccountPicture: CircleAvatar(
                  backgroundColor: Color(0xFFFCC520),
                  child: Icon(Icons.build, size: 40, color: Colors.black),
                ),
                accountName: Text(
                  'FIX-Appliance CRM',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                accountEmail: Text('info@fix-appliance.ca'),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (_flag(config, 'menuShowWarehouse'))
                      ListTile(
                        leading: const Icon(
                          Icons.inventory_2_outlined,
                          color: Colors.orange,
                        ),
                        title: const Text(
                          'Склад',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () => _open(context, const WarehouseScreen()),
                      ),
                    if (_flag(config, 'menuShowStatistics'))
                      ListTile(
                        leading: const Icon(
                          Icons.query_stats,
                          color: Color(0xFF1565C0),
                        ),
                        title: const Text(
                          'Статистика',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () => _open(context, const ReportsScreen()),
                      ),
                    if (_flag(config, 'menuShowReports'))
                      ListTile(
                        leading: const Icon(Icons.bar_chart, color: Colors.green),
                        title: const Text(
                          'Отчеты',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () => _open(context, const ReportsScreen()),
                      ),
                    if (_flag(config, 'menuShowExpenses'))
                      ListTile(
                        leading: const Icon(
                          Icons.receipt_long_outlined,
                          color: Colors.deepOrange,
                        ),
                        title: const Text(
                          'Расходы',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () => _open(context, const ReportsScreen()),
                      ),
                    if (_flag(config, 'menuShowInvoices') ||
                        _flag(config, 'menuShowEstimates'))
                      ListTile(
                        leading: const Icon(Icons.receipt_long, color: Colors.teal),
                        title: const Text(
                          'Счета',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () => _open(context, const ReportsScreen()),
                      ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text(
                        'Настройки',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onTap: () => _open(context, const SettingsScreen()),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'v1.0.0 (Beta)',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
