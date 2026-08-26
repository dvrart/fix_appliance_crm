import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/import_export_service.dart';
import '../widgets/settings_ui.dart';

class ImportExportSettingsPage extends StatefulWidget {
  const ImportExportSettingsPage({super.key});

  @override
  State<ImportExportSettingsPage> createState() =>
      _ImportExportSettingsPageState();
}

class _ImportExportSettingsPageState extends State<ImportExportSettingsPage> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted || ok == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await ImportExportService.importFromFile();
      if (!mounted) return;
      if (result.error != null && result.error!.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.summary),
          backgroundColor: result.error == null ? Colors.green : Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(context.tr('Импорт и экспорт', 'Import & export')),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          if (_busy)
            LinearProgressIndicator(
              color: AppColors.accent,
              minHeight: 3,
            ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: context.tr('Экспорт клиентов', 'Export clients'),
                subtitle: context.tr('CSV для Excel', 'CSV for Excel'),
                icon: Icons.people_outline,
                iconColor: AppColors.primary,
                onTap: () => _run(
                  ImportExportService.exportClientsCsv,
                  ok: context.tr('Файл клиентов готов', 'Clients file is ready'),
                ),
              ),
              SettingsRow(
                title: context.tr('Экспорт заявок', 'Export jobs'),
                subtitle: context.tr('CSV для Excel', 'CSV for Excel'),
                icon: Icons.assignment_outlined,
                iconColor: Colors.teal,
                onTap: () => _run(
                  ImportExportService.exportJobsCsv,
                  ok: context.tr('Файл заявок готов', 'Jobs file is ready'),
                ),
              ),
              SettingsRow(
                title: context.tr('Полный бэкап', 'Full backup'),
                subtitle: context.tr(
                  'JSON клиентов и заявок',
                  'JSON of clients and jobs',
                ),
                icon: Icons.archive_outlined,
                iconColor: Colors.indigo,
                showDivider: false,
                onTap: () => _run(
                  ImportExportService.exportBackupJson,
                  ok: context.tr('Бэкап готов', 'Backup is ready'),
                ),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: context.tr('CSV-шаблон для импорта', 'CSV import template'),
                subtitle: context.tr(
                  'Полный шаблон. Подходит для Square: First Name, Last Name, Email Address, Phone Number, Appointment Date.',
                  'Full template. Also accepts Square columns: First Name, Last Name, Email Address, Phone Number, Appointment Date.',
                ),
                icon: Icons.table_view_outlined,
                iconColor: Colors.brown,
                onTap: () => _run(
                  ImportExportService.exportImportTemplate,
                  ok: context.tr('Шаблон готов', 'Template is ready'),
                ),
              ),
              SettingsRow(
                title: context.tr('Импорт из файла', 'Import from file'),
                subtitle: context.tr(
                  'CSV или JSON. Клиенты с тем же телефоном обновляются. Строка с техникой или датой создаёт заявку.',
                  'CSV or JSON. Clients with the same phone are updated. A row with an appliance or date also creates a job.',
                ),
                icon: Icons.file_upload_outlined,
                iconColor: Colors.deepOrange,
                showDivider: false,
                onTap: _import,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              context.tr(
                'Amazon, Reliable Parts, PartSelect, Encompass, Marcone и почтовые службы не пускают приложение в личный кабинет. Добавьте трек или номер заказа в заявку. Когда на Gmail придёт письмо «отправлено / курьер / доставлено», в приложение сразу придёт уведомление.',
                'Amazon, Reliable Parts, PartSelect, Encompass, Marcone and the carriers do not let apps into a shopping account. Add a tracking or order number on the job. When Gmail gets a shipped / out for delivery / delivered email, the app notifies you right away.',
              ),
              style: const TextStyle(color: Colors.black54, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
