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
                title: 'Прайсбук'.tr,
                subtitle: 'Good / Better / Best для смет'.tr,
                icon: Icons.sell_outlined,
                iconColor: Colors.green,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _PricebookPage()),
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
      actions: [
        IconButton(
          tooltip: 'Добавить'.tr,
          onPressed: _saving ? null : () => _add(),
          icon: const Icon(Icons.add_circle, color: Color(0xFFFCC520), size: 32),
        ),
      ],
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
                    return const Center(
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
      actions: [
        IconButton(
          tooltip: 'Добавить'.tr,
          onPressed: _saving ? null : _add,
          icon: const Icon(Icons.add_circle, color: Color(0xFFFCC520), size: 32),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Нажмите статус, чтобы сменить название и цвет. Жёлтый плюс добавляет новый.'.tr,
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
                    return const Center(
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
                              subtitle: items[i].builtin ? 'Базовый'.tr : 'Свой'.tr,
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

class _PricebookPage extends StatelessWidget {
  const _PricebookPage();

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Прайсбук'.tr,
      body: StreamBuilder<List<PricebookItem>>(
        stream: CatalogService.streamPricebook(),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <PricebookItem>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
            children: [
              Text(
                'Три цены на типовую работу. В смете мастер выбирает Good / Better / Best.'.tr,
                style: const TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              for (final item in items)
                Card(
                  child: ListTile(
                    title: Text(item.name),
                    subtitle: Text(
                      [
                        if (item.applianceType.isNotEmpty) trAny(item.applianceType),
                        'G \$${item.good.toStringAsFixed(0)}',
                        'B \$${item.better.toStringAsFixed(0)}',
                        'B \$${item.best.toStringAsFixed(0)}',
                      ].join(' · '),
                    ),
                    onTap: () => _editPricebookItem(context, item),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => CatalogService.removePricebookItem(item.id),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => _editPricebookItem(context, null),
                icon: const Icon(Icons.add),
                label: Text('Добавить работу'.tr),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<void> _editPricebookItem(BuildContext context, PricebookItem? existing) async {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final typeCtrl = TextEditingController(text: existing?.applianceType ?? '');
  final goodCtrl = TextEditingController(
    text: existing == null ? '' : existing.good.toStringAsFixed(0),
  );
  final betterCtrl = TextEditingController(
    text: existing == null ? '' : existing.better.toStringAsFixed(0),
  );
  final bestCtrl = TextEditingController(
    text: existing == null ? '' : existing.best.toStringAsFixed(0),
  );
  final notesCtrl = TextEditingController(text: existing?.notes ?? '');
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(existing == null ? 'Новая работа'.tr : 'Прайсбук'.tr),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(labelText: 'Название'.tr),
              ),
              TextField(
                controller: typeCtrl,
                decoration: InputDecoration(labelText: 'Тип техники'.tr),
              ),
              TextField(
                controller: goodCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Good \$'),
              ),
              TextField(
                controller: betterCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Better \$'),
              ),
              TextField(
                controller: bestCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Best \$'),
              ),
              TextField(
                controller: notesCtrl,
                decoration: InputDecoration(labelText: 'Заметка'.tr),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Сохранить'.tr),
          ),
        ],
      );
    },
  );
  if (saved != true) return;
  final name = nameCtrl.text.trim();
  if (name.isEmpty) return;
  final item = PricebookItem(
    id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: name,
    applianceType: typeCtrl.text.trim(),
    good: double.tryParse(goodCtrl.text) ?? 0,
    better: double.tryParse(betterCtrl.text) ?? 0,
    best: double.tryParse(bestCtrl.text) ?? 0,
    notes: notesCtrl.text.trim(),
  );
  await CatalogService.upsertPricebookItem(item);
}
