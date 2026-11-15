import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/tester_build.dart';
import '../../../services/auth_service.dart';
import '../../../shared/widgets/app_onboarding_guide.dart';
import '../widgets/settings_ui.dart';

class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService.user.value;
    final email = (user?.email ?? '').trim();
    return SettingsPageScaffold(
      title: context.tr('О приложении', 'About'),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('О приложении', 'About'),
            tiles: [
              SettingsHubTile(
                title: kTesterAppBuild ? 'FIX CRM TEST' : 'FIX CRM',
                subtitle: kTesterAppBuild && email.isNotEmpty
                    ? email
                    : context.tr('Заявки', 'Jobs'),
                icon: Icons.build_circle_outlined,
                color: Colors.blueGrey,
                onTap: () {},
              ),
              if (kTesterAppBuild) ...[
                SettingsHubTile(
                  title: context.tr('База данных', 'Database'),
                  subtitle: kCompanyId,
                  icon: Icons.storage_outlined,
                  color: Colors.teal,
                  active: true,
                  onTap: () {},
                ),
                SettingsHubTile(
                  title: context.tr('Гайд по приложению', 'App Guide'),
                  subtitle: context.tr(
                    'Обзор кнопок, заявок, счетов и настроек',
                    'Tour of buttons, jobs, invoices & settings',
                  ),
                  icon: Icons.menu_book_rounded,
                  color: Colors.indigo,
                  onTap: () => AppOnboardingGuide.open(context),
                ),
                SettingsHubTile(
                  title: context.tr('Выйти', 'Sign out'),
                  subtitle: context.tr('Сменить аккаунт', 'Switch account'),
                  icon: Icons.logout,
                  color: Colors.redAccent,
                  onTap: () async {
                    await AuthService.signOut();
                    if (context.mounted) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                ),
              ] else
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
