import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../services/catalog_service.dart';
import '../../../services/status_service.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';
import '../../../core/l10n/app_locale.dart';

class CatalogSettingsPage extends StatelessWidget {
  const CatalogSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Каталог'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 20, bottom: 40),
        children: [
          SettingsGroup(
            children: [
              SettingsRow(
                title: 'Типы техники'.tr,
                subtitle: 'Список для создания заявки'.tr,
                icon: Icons.kitchen,
                iconColor: Colors.deepOrange,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Типы техники'.tr,
                      hint: 'Эти значения предлагаются в поле «Тип»'.tr,
                      stream: CatalogService.streamApplianceTypes,
                      onAdd: CatalogService.addApplianceType,
                      onRemove: CatalogService.removeApplianceType,
                    ),
                  ),
                ),
              ),
              SettingsRow(
                title: 'Бренды'.tr,
                subtitle: 'Список для создания заявки'.tr,
                icon: Icons.branding_watermark,
                iconColor: Colors.indigo,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Бренды'.tr,
                      hint: 'Эти значения предлагаются в поле «Бренд»'.tr,
                      stream: CatalogService.streamBrands,
                      onAdd: CatalogService.addBrand,
                      onRemove: CatalogService.removeBrand,
                    ),
                  ),
                ),
              ),
              SettingsRow(
                title: 'Статусы заявок'.tr,
                subtitle: 'Название, цвет, свои статусы'.tr,
                icon: Icons.flag_outlined,
                iconColor: Colors.teal,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _StatusListPage()),
                ),
              ),
              SettingsRow(
                title: 'Откуда узнали'.tr,
                subtitle: 'Источники для карточки клиента'.tr,
                icon: Icons.campaign_outlined,
                iconColor: Colors.deepPurple,
                showDivider: false,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Откуда узнали'.tr,
                      hint: 'Эти значения предлагаются в карточке клиента'.tr,
                      stream: CatalogService.streamLeadSources,
                      onAdd: CatalogService.addLeadSource,
                      onRemove: CatalogService.removeLeadSource,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CatalogListPage extends StatefulWidget {
  final String title;
  final String hint;
  final Stream<List<String>> Function() stream;
  final Future<void> Function(String value) onAdd;
  final Future<void> Function(String value) onRemove;

  const _CatalogListPage({
    required this.title,
    required this.hint,
    required this.stream,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<_CatalogListPage> createState() => _CatalogListPageState();
}

class _CatalogListPageState extends State<_CatalogListPage> {
  final _addCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _add([String? raw]) async {
    FocusManager.instance.primaryFocus?.unfocus();
    var value = (raw ?? _addCtrl.text).trim();
    if (value.isEmpty) {
      value = (await showSettingsTextDialog(
            context: context,
            title: 'Новое значение'.tr,
            label: widget.title,
            initialValue: '',
            capitalization: TextCapitalization.sentences,
          ))
              ?.trim() ??
          '';
    }
    if (value.isEmpty || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.onAdd(value);
      _addCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${'Добавлено'.tr}: $value'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _plusButton() {
    return SizedBox(
      width: 56,
      height: 56,
      child: IconButton.filled(
        style: IconButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
          disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: _saving ? null : () => _add(),
        icon: _saving
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
              )
            : const Icon(Icons.add, size: 28),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: widget.title,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(widget.hint, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Новое значение'.tr,
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    onSubmitted: (v) => _add(v),
                  ),
                ),
                const SizedBox(width: 8),
                _plusButton(),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<List<String>>(
                stream: widget.stream(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text('${snapshot.error}'));
                  }
                  if (!snapshot.hasData) {
                    return Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    );
                  }
                  final items = snapshot.data!;
                  if (items.isEmpty) {
                    return Center(child: Text('Список пуст'.tr));
                  }
                  return ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      SettingsGroup(
                        children: [
                          for (var i = 0; i < items.length; i++)
                            SettingsRow(
                              title: items[i],
                              subtitle: '',
                              icon: Icons.label_outline,
                              iconColor: AppColors.primary,
                              showDivider: i < items.length - 1,
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () => widget.onRemove(items[i]),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusListPage extends StatefulWidget {
  const _StatusListPage();

  @override
  State<_StatusListPage> createState() => _StatusListPageState();
}

class _StatusListPageState extends State<_StatusListPage> {
  bool _saving = false;

  static const _palette = [
    0xFF1E88E5,
    0xFFFCC520,
    0xFFFB8C00,
    0xFF43A047,
    0xFFE53935,
    ...StatusService.extraPalette,
  ];

  Future<void> _edit(JobStatusDef status) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final saved = await showDialog<(String, int)>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _StatusEditorDialog(status: status, palette: _palette),
    );
    if (saved == null) return;
    await StatusService.update(
      id: status.id,
      label: saved.$1,
      colorValue: saved.$2,
    );
  }

  Future<void> _add() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final created = await showDialog<(String, int)>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _StatusEditorDialog(palette: _palette),
    );
    if (created == null || created.$1.isEmpty || !mounted) return;
    setState(() => _saving = true);
    try {
      await StatusService.add(created.$1, colorValue: created.$2);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Статусы заявок'.tr,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Нажмите статус, чтобы сменить название и цвет. Плюс в списке добавляет новый.'.tr,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 56,
                height: 56,
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _saving ? null : _add,
                  icon: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Icon(Icons.add, size: 28),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<List<JobStatusDef>>(
                stream: StatusService.streamDefs(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text('${snapshot.error}'));
                  }
                  if (!snapshot.hasData) {
                    return Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    );
                  }
                  final items = snapshot.data!;
                  return ListView(
                    children: [
                      SettingsGroup(
                        children: [
                          for (var i = 0; i < items.length; i++)
                            SettingsRow(
                              title: trAny(items[i].label),
                              subtitle: items[i].id == JobStatuses.rescheduled
                                  ? 'Сам, после нового визита'.tr
                                  : items[i].id == JobStatuses.inProgress
                                      ? 'Больше не используется'.tr
                                      : items[i].builtin
                                          ? 'Базовый'.tr
                                          : 'Свой'.tr,
                              icon: Icons.circle,
                              iconColor: items[i].color,
                              showDivider: i < items.length - 1,
                              onTap: () => _edit(items[i]),
                              trailing: items[i].builtin
                                  ? const Icon(Icons.edit_outlined, color: Colors.grey)
                                  : IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                                      onPressed: () => StatusService.remove(items[i].id),
                                    ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusEditorDialog extends StatefulWidget {
  final JobStatusDef? status;
  final List<int> palette;

  const _StatusEditorDialog({
    this.status,
    required this.palette,
  });

  @override
  State<_StatusEditorDialog> createState() => _StatusEditorDialogState();
}

class _StatusEditorDialogState extends State<_StatusEditorDialog> {
  late final TextEditingController _nameCtrl;
  late int _color;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.status?.label ?? '');
    _color = widget.status?.colorValue ?? widget.palette.first;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _nameCtrl.text.trim();
    if (label.isEmpty) return;
    Navigator.pop(context, (label, _color));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.status != null;
    return AlertDialog(
      title: Text(
        isEdit
            ? (widget.status!.builtin ? 'Изменить статус'.tr : 'Статус'.tr)
            : 'Новый статус'.tr,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'Название'.tr),
            ),
            const SizedBox(height: 16),
            Text('Цвет'.tr, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final value in widget.palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = value),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Color(value),
                      child: _color == value
                          ? const Icon(Icons.check, color: Colors.white, size: 18)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Отмена'.tr),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(isEdit ? 'Сохранить'.tr : 'Добавить'.tr),
        ),
      ],
    );
  }
}
