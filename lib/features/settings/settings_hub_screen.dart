import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/settings_service.dart';
import 'pages/about_settings_page.dart';
import 'pages/appearance_settings_page.dart';
import 'pages/ai_secretary_settings_page.dart';
import 'pages/app_lock_settings_page.dart';
import 'pages/assistant_settings_page.dart';
import 'pages/backup_settings_page.dart';
import 'pages/calendar_settings_page.dart';
import 'pages/catalog_settings_page.dart';
import 'pages/communication_settings_page.dart';
import 'pages/company_settings_page.dart';
import 'pages/document_settings_page.dart';
import 'pages/import_export_settings_page.dart';
import 'pages/error_log_page.dart';
import 'pages/menu_settings_page.dart';
import 'pages/message_templates_page.dart';
import 'pages/payments_settings_page.dart';
import 'pages/pricing_settings_page.dart';
import 'pages/service_area_settings_page.dart';
import 'pages/work_days_settings_page.dart';
import 'widgets/company_logo.dart';
import 'widgets/settings_ui.dart';

/// Настройки сгруппированы по вопросу «про что это», а не по технологии:
/// Компания · Расписание · Клиенту · Подключения · Приложение · Данные.
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
        automaticallyImplyLeading: false,
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
              final workDays = SettingsService.readWorkDays(config);
              final serviceCall = SettingsService.readServiceCallFee(config);
              final areaLabel = SettingsService.describeServiceArea(config);
              final polygon = config['servicePolygon'];
              final hasPolygon = polygon is List && polygon.length >= 3;
              final area = areaLabel.isNotEmpty
                  ? areaLabel
                  : hasPolygon
                      ? context.tr('Отмечена', 'Marked')
                      : context.tr('Не отмечена', 'Not marked');
              final assistantOn = SettingsService.readAssistantEnabled(config);
              final secretaryOn = SettingsService.readAiAnswerEnabled(config);
              final secretaryTimeout =
                  SettingsService.readAiAnswerTimeoutSeconds(config);
              final defaultView = SettingsService.readDefaultCalendarView(
                config,
              );

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
                                                  'Реквизиты компании',
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
                        title: context.tr('Компания', 'Company'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Реквизиты', 'Details'),
                            subtitle: name,
                            icon: Icons.business,
                            color: AppColors.primary,
                            onTap: () =>
                                _open(context, const CompanySettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Прайс', 'Prices'),
                            subtitle: serviceCall > 0
                                ? SettingsService.formatMoney(serviceCall)
                                : context.tr('Задать', 'Set'),
                            icon: Icons.payments_outlined,
                            color: Colors.green,
                            onTap: () =>
                                _open(context, const PricingSettingsPage()),
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
                            subtitle: context.tr('Техника, статусы', 'Types, statuses'),
                            icon: Icons.kitchen,
                            color: Colors.deepOrange,
                            onTap: () =>
                                _open(context, const CatalogSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Расписание', 'Schedule'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Рабочие дни', 'Working days'),
                            subtitle:
                                '${SettingsService.workDaysLabel(workDays)} · '
                                '${SettingsService.workHoursLabel(workStart, workEnd)}',
                            icon: Icons.event_available,
                            color: Colors.teal,
                            onTap: () =>
                                _open(context, const WorkDaysSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Календарь', 'Calendar'),
                            subtitle: SettingsService.calendarViewLabel(
                              defaultView,
                            ).tr,
                            icon: Icons.calendar_month,
                            color: Colors.blue,
                            onTap: () =>
                                _open(context, const CalendarSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Клиенту', 'To the client'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Шаблоны', 'Templates'),
                            subtitle: context.tr('Тексты SMS', 'SMS text'),
                            icon: Icons.article_outlined,
                            color: Colors.blueGrey,
                            onTap: () =>
                                _open(context, const MessageTemplatesPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Когда слать', 'When to send'),
                            subtitle: context.tr(
                              'Запись, напоминание',
                              'Booking, reminder',
                            ),
                            icon: Icons.schedule_send,
                            color: Colors.indigo,
                            onTap: () => _open(
                              context,
                              const CommunicationSettingsPage.sms(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Счета', 'Invoices'),
                            subtitle: context.tr('PDF и сметы', 'PDF and estimates'),
                            icon: Icons.receipt_long,
                            color: Colors.green,
                            onTap: () =>
                                _open(context, const DocumentSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Подключения', 'Connections'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Телефон', 'Phone'),
                            subtitle: 'Twilio',
                            icon: Icons.phone_in_talk,
                            color: Colors.green,
                            onTap: () => _open(
                              context,
                              const CommunicationSettingsPage.calls(),
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
                          SettingsHubTile(
                            title: context.tr('Почта', 'Email'),
                            subtitle: 'Gmail',
                            icon: Icons.mail_outline,
                            color: const Color(0xFFEA4335),
                            onTap: () => _open(
                              context,
                              const CommunicationSettingsPage.gmail(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Платежи', 'Payments'),
                            subtitle: 'Stripe',
                            icon: Icons.contactless,
                            color: const Color(0xFF635BFF),
                            onTap: () =>
                                _open(context, const PaymentsSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Приложение', 'App'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Уведомления', 'Alerts'),
                            subtitle: context.tr('Шторка, брифинг', 'Tray, briefing'),
                            icon: Icons.notifications_outlined,
                            color: Colors.orange,
                            onTap: () => _open(
                              context,
                              const CommunicationSettingsPage.alerts(),
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
                            title: context.tr('Вид', 'Display'),
                            subtitle: AppLocale.instance.isEn
                                ? 'English'
                                : 'Русский',
                            icon: Icons.format_size,
                            color: Colors.teal,
                            onTap: () => _open(
                              context,
                              const AppearanceSettingsPage(),
                            ),
                          ),
                          SettingsHubTile(
                            title: context.tr('Меню', 'Menu'),
                            subtitle: context.tr('Что видно слева', 'Left drawer'),
                            icon: Icons.grid_view,
                            color: Colors.blueGrey,
                            onTap: () =>
                                _open(context, const MenuSettingsPage()),
                          ),
                        ],
                      ),
                      SettingsTileSection(
                        title: context.tr('Данные', 'Data'),
                        tiles: [
                          SettingsHubTile(
                            title: context.tr('Копия', 'Backup'),
                            subtitle: context.tr('Автосохранение', 'Automatic'),
                            icon: Icons.backup_outlined,
                            color: Colors.blue,
                            onTap: () =>
                                _open(context, const BackupSettingsPage()),
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
                          SettingsHubTile(
                            title: context.tr('Замок', 'Lock'),
                            subtitle: context.tr('PIN, отпечаток', 'PIN, finger'),
                            icon: Icons.lock_outline,
                            color: Colors.brown,
                            onTap: () =>
                                _open(context, const AppLockSettingsPage()),
                          ),
                          SettingsHubTile(
                            title: context.tr('Ошибки', 'Errors'),
                            subtitle: context.tr('Что ломалось', 'What broke'),
                            icon: Icons.bug_report_outlined,
                            color: Colors.deepOrange,
                            onTap: () => _open(context, const ErrorLogPage()),
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
