import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
import '../../../services/account_service.dart';
import '../widgets/settings_ui.dart';

class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('О приложении', 'About'),
      body: ListView(
        padding: const EdgeInsets.only(top: 20, bottom: 40),
        children: [
          SettingsGroup(
            children: [
              SettingsRow(
                title: 'Fix Cloud',
                subtitle: context.tr(
                  'Учёт заявок, звонков и счетов',
                  'Jobs, calls, and invoices',
                ),
                icon: Icons.build_circle_outlined,
                iconColor: Colors.blueGrey,
                trailing: const SizedBox.shrink(),
              ),
              SettingsRow(
                title: context.tr('Язык', 'Language'),
                subtitle: AppLocale.instance.isEn ? 'English' : 'Русский'.tr,
                icon: Icons.translate,
                iconColor: Colors.teal,
                onTap: () => AppLocale.instance.toggle(),
              ),
              SettingsRow(
                title: context.tr('Версия', 'Version'),
                subtitle: '1.0.0',
                icon: Icons.info_outline,
                iconColor: Colors.grey,
                trailing: Text(
                  context.tr('Актуальная', 'Current'),
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                showDivider: false,
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: context.tr('Выйти из аккаунта', 'Sign out'),
                subtitle: context.tr(
                  'На этом телефоне откроется вход',
                  'Returns to the sign-in screen',
                ),
                icon: Icons.logout,
                iconColor: Colors.redAccent,
                onTap: () => AccountService.instance.signOut(),
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
