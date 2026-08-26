import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/settings_service.dart';
import 'pages/about_settings_page.dart';
import 'pages/appearance_settings_page.dart';
import 'pages/ai_secretary_settings_page.dart';
import 'pages/assistant_settings_page.dart';
import 'pages/calendar_settings_page.dart';
import 'pages/catalog_settings_page.dart';
import 'pages/communication_settings_page.dart';
import 'pages/company_settings_page.dart';
import 'pages/finance_settings_page.dart';
import 'pages/import_export_settings_page.dart';
import 'pages/menu_settings_page.dart';
import 'pages/payments_settings_page.dart';
import 'pages/service_area_settings_page.dart';
import 'widgets/company_logo.dart';
import 'widgets/settings_ui.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(
          context.tr('Настройки', 'Settings'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder(
        stream: SettingsService.watchDocumentSettings(),
        builder: (context, docsSnap) {
          final docs = docsSnap.data;
          final name = docs?.companyName ?? 'Fix Appliance';
          final address = docs?.companyAddress ?? '';

          return StreamBuilder<Map<String, dynamic>>(
            stream: SettingsService.watchConfig(),
            builder: (context, configSnap) {
              final config = configSnap.data ?? <String, dynamic>{};
              final workStart = SettingsService.readWorkStartMinutes(config);
              final workEnd = SettingsService.readWorkEndMinutes(config);
              final areaLabel = SettingsService.describeServiceArea(config);
              final polygon = config['servicePolygon'];
              final hasPolygon = polygon is List && polygon.length >= 3;
              final area = areaLabel.isNotEmpty
                  ? areaLabel
                  : hasPolygon
                      ? context.tr(
                          'Район отмечен на карте',
                          'Area marked on the map',
                        )
                      : context.tr(
                          'Не отмечена на карте',
                          'Not marked on the map',
                        );
              final assistantOn = SettingsService.readAssistantEnabled(config);
              final secretaryOn = SettingsService.readAiAnswerEnabled(config);
              final secretaryTimeout =
                  SettingsService.readAiAnswerTimeoutSeconds(config);

              return ListenableBuilder(
                listenable: AppLocale.instance,
                builder: (context, _) {
                  return ListView(
                    padding: const EdgeInsets.only(top: 12, bottom: 32),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Material(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () =>
                                _open(context, const CompanySettingsPage()),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  CompanyLogo(url: docs?.logoUrl, size: 52),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          address.isEmpty
                                              ? context.tr(
                                                  'Реквизиты компании'.tr,
                                                  'Company details',
                                                )
                                              : address,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: Colors.white70,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      SettingsTileSection(
                        title: context.tr('Аккаунт', 'Account'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Компания', 'Company'),
                            icon: Icons.business,
                            color: AppColors.primary,
                            onTap: () =>
                                _open(context, const CompanySettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Календарь', 'Calendar'),
                            subtitle: SettingsService.workHoursLabel(
                              workStart,
                              workEnd,
                            ),
                            icon: Icons.calendar_month,
                            color: Colors.teal,
                            onTap: () =>
                                _open(context, const CalendarSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Зона', 'Area'),
                            subtitle: area,
                            icon: Icons.map_outlined,
                            color: Colors.orange,
                            onTap: () => _open(
                              context,
                              const ServiceAreaSettingsPage(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Каталог', 'Catalog'),
                            icon: Icons.kitchen,
                            color: Colors.deepOrange,
                            onTap: () =>
                                _open(context, const CatalogSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Связь', 'Communication'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Связь', 'Calls'),
                            subtitle: context.tr('Twilio, SMS', 'Twilio, SMS'),
                            icon: Icons.forum_outlined,
                            color: Colors.indigo,
                            onTap: () => _open(
                              context,
                              const CommunicationSettingsPage(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Ассистент', 'Assistant'),
                            subtitle: assistantOn
                                ? context.tr('Вкл', 'On')
                                : context.tr('Выкл', 'Off'),
                            icon: Icons.record_voice_over,
                            color: Colors.deepPurple,
                            active: assistantOn,
                            onTap: () => _open(
                              context,
                              const AssistantSettingsPage(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Секретарь', 'Secretary'),
                            subtitle: secretaryOn
                                ? (secretaryTimeout <= 0
                                    ? context.tr('Сразу', 'Immediately')
                                    : '${secretaryTimeout}s')
                                : context.tr('Выкл', 'Off'),
                            icon: Icons.support_agent,
                            color: Colors.indigo,
                            active: secretaryOn,
                            onTap: () => _open(
                              context,
                              const AiSecretarySettingsPage(),
                            ),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Финансы', 'Finance'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Документы', 'Documents'),
                            subtitle: 'HST / GST',
                            icon: Icons.receipt_long,
                            color: Colors.green,
                            onTap: () =>
                                _open(context, const FinanceSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Платежи', 'Payments'),
                            subtitle: 'Stripe',
                            icon: Icons.contactless,
                            color: const Color(0xFF635BFF),
                            onTap: () =>
                                _open(context, const PaymentsSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Импорт', 'Import'),
                            subtitle: 'CSV',
                            icon: Icons.import_export,
                            color: Colors.blueGrey,
                            onTap: () => _open(
                              context,
                              const ImportExportSettingsPage(),
                            ),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Приложение', 'App'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Язык', 'Language'),
                            subtitle: AppLocale.instance.isEn
                                ? 'EN → RU'
                                : 'RU → EN',
                            icon: Icons.translate,
                            color: Colors.teal,
                            onTap: () => AppLocale.instance.toggle(),
                          ),
                          SettingsHubTile(
                            title: context.tr('Экран', 'Display'),
                            icon: Icons.format_size,
                            color: Colors.orange,
                            onTap: () => _open(
                              context,
                              const AppearanceSettingsPage(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Меню', 'Menu'),
                            icon: Icons.grid_view,
                            color: Colors.blueGrey,
                            onTap: () =>
                                _open(context, const MenuSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('О приложении', 'About'),
                            subtitle: '1.0.0',
                            icon: Icons.info_outline,
                            color: Colors.grey,
                            onTap: () =>
                                _open(context, const AboutSettingsPage()),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
