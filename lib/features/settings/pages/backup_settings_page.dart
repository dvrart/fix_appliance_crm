import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/backup_service.dart';
import '../widgets/settings_ui.dart';

class BackupSettingsPage extends StatefulWidget {
  const BackupSettingsPage({super.key});

  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  bool _loading = true;
  bool _working = false;
  bool _cloudWorking = false;
  int _intervalDays = 7;
  String _folder = '';
  List<BackupFile> _files = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final days = await BackupService.intervalDays();
    final files = await BackupService.list();
    final folder = await BackupService.folderPath();
    if (!mounted) return;
    setState(() {
      _intervalDays = days;
      _files = files;
      _folder = folder;
      _loading = false;
    });
  }

  String _intervalLabel(int days) {
    switch (days) {
      case 0:
        return context.tr('Не делать', 'Never');
      case 1:
        return context.tr('Каждый день', 'Every day');
      case 7:
        return context.tr('Раз в неделю', 'Once a week');
      default:
        return context.tr('Раз в месяц', 'Once a month');
    }
  }

  Future<void> _pickInterval() async {
    final next = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                context.tr('Как часто', 'How often'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final days in BackupService.intervalOptions)
              ListTile(
                title: Text(_intervalLabel(days)),
                trailing: days == _intervalDays
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, days),
              ),
          ],
        ),
      ),
    );
    if (next == null || !mounted) return;
    await BackupService.setIntervalDays(next);
    if (!mounted) return;
    setState(() => _intervalDays = next);
  }

  Future<void> _createNow() async {
    setState(() => _working = true);
    final created = await BackupService.createNow();
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created == null
              ? context.tr('Не получилось сделать копию', 'Backup failed')
              : context.tr('Копия готова', 'Backup saved'),
        ),
      ),
    );
    await _load();
  }

  Future<void> _createCloudNow() async {
    setState(() => _cloudWorking = true);
    final created = await BackupService.createCloudNow();
    if (!mounted) return;
    setState(() => _cloudWorking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created == null
              ? context.tr(
                  'Облако не ответило. Проверьте интернет.',
                  'The cloud did not answer. Check the connection.',
                )
              : context.tr('Копия уехала в облако', 'Copy is in the cloud'),
        ),
      ),
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _when(DateTime date) {
    final locale = AppLocale.instance.isEn ? 'en' : 'ru';
    return DateFormat('d MMMM, HH:mm', locale).format(date);
  }

  @override
  Widget build(BuildContext context) {
    final last = _files.isEmpty ? null : _files.first.createdAt;
    return SettingsPageScaffold(
      title: context.tr('Копия', 'Backup'),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: [
                _sectionTitle(
                  context.tr('В облаке', 'In the cloud'),
                  context.tr(
                    'Сервер сам делает копию каждое воскресенье ночью. Телефон при '
                    'этом может быть выключен. Хранятся последние 12 недель.',
                    'The server makes a copy every Sunday night on its own. Your '
                    'phone can be off. The last 12 weeks are kept.',
                  ),
                ),
                _cloudSection(),
                _sectionTitle(
                  context.tr('На телефоне', 'On this phone'),
                  context.tr(
                    'Быстрая копия во внутренней папке приложения. Её не видно в '
                    'проводнике и она стирается вместе с приложением.',
                    'A quick copy in the app private folder. A file manager will '
                    'not show it and it goes away with the app.',
                  ),
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('Автокопия', 'Automatic backup'),
                      subtitle: _intervalLabel(_intervalDays),
                      icon: Icons.backup_outlined,
                      iconColor: _intervalDays == 0
                          ? Colors.grey
                          : AppColors.primary,
                      onTap: _pickInterval,
                    ),
                    SettingsRow(
                      title: context.tr('Сделать сейчас', 'Back up now'),
                      subtitle: last == null
                          ? context.tr('Копий пока нет', 'No copies yet')
                          : '${context.tr('Последняя', 'Last')}: ${_when(last)}',
                      icon: Icons.save_alt,
                      iconColor: Colors.green,
                      showDivider: false,
                      trailing: _working
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : const Icon(Icons.chevron_right, color: Colors.grey),
                      onTap: _working ? null : _createNow,
                    ),
                  ],
                ),
                if (_files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      context.tr(
                        'Храним последние ${BackupService.keepCount}',
                        'We keep the last ${BackupService.keepCount}',
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                if (_files.isNotEmpty)
                  SettingsGroup(
                    children: [
                      for (var i = 0; i < _files.length; i++)
                        SettingsRow(
                          title: _when(_files[i].createdAt),
                          subtitle: _size(_files[i].bytes),
                          icon: Icons.insert_drive_file_outlined,
                          iconColor: Colors.blueGrey,
                          showDivider: i < _files.length - 1,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.ios_share,
                                  color: Colors.blueGrey,
                                ),
                                onPressed: () =>
                                    BackupService.share(_files[i]),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () async {
                                  await BackupService.delete(_files[i]);
                                  await _load();
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (_folder.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: SelectableText(
                      _folder,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black38,
                        height: 1.25,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.black54,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cloudSection() {
    return StreamBuilder<List<CloudBackup>>(
      stream: BackupService.watchCloud(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <CloudBackup>[];
        final last = items.isEmpty ? null : items.first;
        return SettingsGroup(
          children: [
            SettingsRow(
              title: context.tr('Последняя копия', 'Latest copy'),
              subtitle: last == null
                  ? context.tr(
                      'Ещё не делалась — нажмите ниже',
                      'Not made yet — tap below',
                    )
                  : '${_when(last.createdAt)} · ${_size(last.bytes)} · '
                      '${last.totalDocs} ${context.tr('записей', 'records')}',
              icon: Icons.cloud_done_outlined,
              iconColor: last == null ? Colors.grey : Colors.green,
              trailing: last == null
                  ? const SizedBox.shrink()
                  : const Icon(Icons.download, color: Colors.blueGrey),
              onTap: last == null ? null : () => BackupService.openCloud(last),
            ),
            SettingsRow(
              title: context.tr('В облако сейчас', 'To the cloud now'),
              subtitle: items.length <= 1
                  ? context.tr('Не дожидаясь воскресенья', 'Without waiting for Sunday')
                  : '${context.tr('Всего копий', 'Copies stored')}: ${items.length}',
              icon: Icons.cloud_upload_outlined,
              iconColor: AppColors.primary,
              showDivider: false,
              trailing: _cloudWorking
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: _cloudWorking ? null : _createCloudNow,
            ),
          ],
        );
      },
    );
  }
}
