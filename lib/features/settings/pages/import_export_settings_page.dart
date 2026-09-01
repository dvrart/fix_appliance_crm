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

  Future<void> _importKnown(String source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await ImportExportService.importFromFile(
        sourceLabel: source,
      );
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
          SettingsTileSection(
            title: context.tr('Экспорт', 'Export'),
            tiles: [
              SettingsHubTile(
                title: context.tr('Клиенты', 'Clients'),
                subtitle: 'CSV',
                icon: Icons.people_outline,
                color: AppColors.primary,
                onTap: () => _run(
                  ImportExportService.exportClientsCsv,
                  ok: context.tr('Файл клиентов готов', 'Clients file is ready'),
                ),
              ),
              SettingsHubTile(
                title: context.tr('Заявки', 'Jobs'),
                subtitle: 'CSV',
                icon: Icons.assignment_outlined,
                color: Colors.teal,
                onTap: () => _run(
                  ImportExportService.exportJobsCsv,
                  ok: context.tr('Файл заявок готов', 'Jobs file is ready'),
                ),
              ),
              SettingsHubTile(
                title: context.tr('Бэкап', 'Backup'),
                subtitle: 'JSON',
                icon: Icons.archive_outlined,
                color: Colors.indigo,
                onTap: () => _run(
                  ImportExportService.exportBackupJson,
                  ok: context.tr('Бэкап готов', 'Backup is ready'),
                ),
              ),
              SettingsHubTile(
                title: context.tr('Шаблон', 'Template'),
                subtitle: 'CSV',
                icon: Icons.table_view_outlined,
                color: Colors.brown,
                onTap: () => _run(
                  ImportExportService.exportImportTemplate,
                  ok: context.tr('Шаблон готов', 'Template is ready'),
                ),
              ),
            ],
          ),
          SettingsTileSection(
            title: context.tr('Импорт CRM', 'CRM import'),
            tiles: [
              SettingsHubTile(
                title: 'Jobber',
                subtitle: 'CSV',
                icon: Icons.handshake_outlined,
                color: const Color(0xFF00A86B),
                onTap: () => _importKnown('Jobber'),
              ),
              SettingsHubTile(
                title: 'Workiz',
                subtitle: 'CSV',
                icon: Icons.handyman_outlined,
                color: const Color(0xFF2563EB),
                onTap: () => _importKnown('Workiz'),
              ),
              SettingsHubTile(
                title: 'Housecall',
                subtitle: 'Pro',
                icon: Icons.home_repair_service_outlined,
                color: const Color(0xFF7C3AED),
                onTap: () => _importKnown('Housecall Pro'),
              ),
              SettingsHubTile(
                title: 'ServiceTitan',
                subtitle: 'CSV',
                icon: Icons.apartment_outlined,
                color: const Color(0xFF0F766E),
                onTap: () => _importKnown('ServiceTitan'),
              ),
              SettingsHubTile(
                title: 'FieldEdge',
                subtitle: 'CSV',
                icon: Icons.map_outlined,
                color: const Color(0xFFEA580C),
                onTap: () => _importKnown('FieldEdge'),
              ),
              SettingsHubTile(
                title: 'Fusion',
                subtitle: 'Service',
                icon: Icons.hub_outlined,
                color: const Color(0xFFDB2777),
                onTap: () => _importKnown('Service Fusion'),
              ),
              SettingsHubTile(
                title: context.tr('Файл', 'File'),
                subtitle: 'CSV / JSON',
                icon: Icons.file_upload_outlined,
                color: Colors.deepOrange,
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
