import 'package:flutter/material.dart';
import '../screens/settings_screen.dart'; // Подключаем экран настроек
import '../screens/warehouse_screen.dart'; // Подключаем экран склада


class CustomDrawer extends StatelessWidget {
  const CustomDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          // --- ШАПКА МЕНЮ ---
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF14557F)),
            currentAccountPicture: const CircleAvatar(
              backgroundColor: Color(0xFFFCC520),
              child: Icon(Icons.build, size: 40, color: Colors.black),
            ),
            accountName: const Text(
              'FIX-Appliance CRM',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            accountEmail: const Text('info@fix-appliance.ca'),
          ),

          // --- ОСНОВНОЙ СПИСОК ---
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // 1. Склад запчастей
                ListTile(
                  leading: const Icon(
                    Icons.warehouse,
                    color: Color(0xFF14557F),
                  ),
                  title: const Text(
                    'Склад запчастей',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            WarehouseScreen(), // <-- Убрали const здесь
                      ),
                    );
                  },
                ),
                const Divider(),

                // 2. Документы
                ExpansionTile(
                  leading: const Icon(Icons.folder, color: Colors.grey),
                  title: const Text('Документы'),
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 54),
                      leading: const Icon(Icons.receipt_long, size: 20),
                      title: const Text('Инвойсы'),
                      onTap: () {},
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 54),
                      leading: const Icon(Icons.bar_chart, size: 20),
                      title: const Text('Отчеты'),
                      onTap: () {},
                    ),
                  ],
                ),

                // 3. ГЛАВНАЯ ПАПКА НАСТРОЕК
                ExpansionTile(
                  leading: const Icon(Icons.settings, color: Colors.grey),
                  title: const Text('Настройки'),
                  initiallyExpanded: true,
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 54),
                      leading: const Icon(Icons.person_outline, size: 20),
                      title: const Text('Настройки аккаунта'),
                      onTap: () {},
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 54),
                      leading: const Icon(Icons.display_settings, size: 20),
                      title: const Text('Настройки системы'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                SettingsScreen(), // <-- И убрали const здесь
                          ),
                        );
                      },
                    ),

                    // ПАПКА "СВЯЗЬ" ВНУТРИ НАСТРОЕК
                    ExpansionTile(
                      tilePadding: const EdgeInsets.only(left: 54, right: 16),
                      leading: const Icon(
                        Icons.contact_phone_outlined,
                        size: 20,
                      ),
                      title: const Text('Связь'),
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 72),
                          leading: const Icon(Icons.sms_outlined, size: 18),
                          title: const Text('Сообщения (СМС)'),
                          onTap: () {},
                        ),
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 72),
                          leading: const Icon(
                            Icons.text_snippet_outlined,
                            size: 18,
                          ),
                          title: const Text('Настройка шаблонов'),
                          onTap: () {},
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // --- ВЕРСИЯ ПРИЛОЖЕНИЯ ---
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('v1.0.0 (Beta)', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}
