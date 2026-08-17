import 'package:flutter/material.dart';

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
            onChanged: (val) => setState(() => _useSignature = val),
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Налог (HST 13%)'),
            subtitle: const Text('Автоматически считать налог в сметах'),
            value: _applyHST,
            onChanged: (val) => setState(() => _applyHST = val),
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
            onChanged: (val) => setState(() => _darkTheme = val),
          ),
          SwitchListTile(
            activeColor: const Color(0xFFFCC520),
            title: const Text('Выходные в календаре'),
            subtitle: const Text('Показывать субботу и воскресенье'),
            value: _weekendInCalendar,
            onChanged: (val) => setState(() => _weekendInCalendar = val),
          ),
        ],
      ),
    );
  }
}
