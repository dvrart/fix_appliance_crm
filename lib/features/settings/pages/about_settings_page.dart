import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
import '../widgets/settings_ui.dart';

class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('О приложении', 'About'),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('О приложении', 'About'),
            tiles: [
              SettingsHubTile(
                title: 'FIX CRM',
                subtitle: context.tr('Заявки', 'Jobs'),
                icon: Icons.build_circle_outlined,
                color: Colors.blueGrey,
                onTap: () {},
              ),
              SettingsHubTile(
                title: context.tr('Язык', 'Language'),
                subtitle: AppLocale.instance.isEn ? 'EN' : 'RU',
                icon: Icons.translate,
                color: Colors.teal,
                onTap: () => AppLocale.instance.toggle(),
              ),
              SettingsHubTile(
                title: context.tr('Версия', 'Version'),
                subtitle: '1.0.0',
                icon: Icons.info_outline,
                color: Colors.grey,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }
}
