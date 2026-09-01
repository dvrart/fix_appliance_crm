import 'package:flutter/material.dart';

import '../../../core/app_commands.dart';
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
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'Каталог'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Типы'.tr,
                subtitle: 'Техника'.tr,
                icon: Icons.kitchen,
                color: Colors.deepOrange,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Типы техники'.tr,
                      hint: 'Эти значения предлагаются в поле «Тип»'.tr,
                      field: 'applianceTypes',
                    ),
                  ),
                ),
              ),
              SettingsHubTile(
                title: 'Бренды'.tr,
                subtitle: 'Марки'.tr,
                icon: Icons.branding_watermark,
                color: Colors.indigo,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Бренды'.tr,
                      hint: 'Эти значения предлагаются в поле «Бренд»'.tr,
                      field: 'brands',
                    ),
                  ),
                ),
              ),
              SettingsHubTile(
                title: 'Статусы'.tr,
                subtitle: 'Заявки'.tr,
                icon: Icons.flag_outlined,
                color: Colors.teal,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _StatusListPage()),
                ),
              ),
              SettingsHubTile(
                title: 'Источники'.tr,
                subtitle: 'Откуда'.tr,
                icon: Icons.campaign_outlined,
                color: Colors.deepPurple,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _CatalogListPage(
                      title: 'Откуда узнали'.tr,
                      hint: 'Эти значения предлагаются в карточке клиента'.tr,
                      field: 'leadSources',
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
  final String field;

  const _CatalogListPage({
    required this.title,
    required this.hint,
    required this.field,
  });

  @override
  State<_CatalogListPage> createState() => _CatalogListPageState();
}

class _CatalogListPageState extends State<_CatalogListPage> {
  final _addCtrl = TextEditingController();
  final ValueNotifier<Set<String>> _selected = ValueNotifier({});
  late final bool Function() _dismissSelection;
  bool _loading = true;
  bool _saving = false;
  List<String> _items = [];
  List<String> _savedItems = [];

  bool get _dirty =>
      !_loading && _items.join('\u0001') != _savedItems.join('\u0001');

  bool get _selecting => _selected.value.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _dismissSelection = () {
      if (_selected.value.isEmpty) return false;
      _selected.value = {};
      return true;
    };
    AppCommands.addSelectionGuard(_dismissSelection);
    _selected.addListener(_onSelectionChanged);
    _load();
  }

  Future<void> _load() async {
    final items = await CatalogService.loadList(widget.field);
    if (!mounted) return;
    setState(() {
      _items = List<String>.from(items);
      _savedItems = List<String>.from(items);
      _loading = false;
    });
  }

  void _sortItems() {
    if (widget.field == 'applianceTypes' || widget.field == 'brands') {
      _items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      await CatalogService.replaceList(widget.field, _items);
      if (!mounted) return true;
      setState(() {
        _savedItems = List<String>.from(_items);
        _saving = false;
      });
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selected.removeListener(_onSelectionChanged);
    AppCommands.removeSelectionGuard(_dismissSelection);
    _selected.dispose();
    _addCtrl.dispose();
    super.dispose();
  }

  void _clearSelection() => _selected.value = {};

  void _toggleSelected(String item) {
    final next = Set<String>.from(_selected.value);
    if (!next.add(item)) next.remove(item);
    _selected.value = next;
  }

  Future<void> _deleteSelected() async {
    final items = _selected.value.toList();
    if (items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить'.tr),
        content: Text(
          '${'Удалить'.tr} ${items.length}?\n\n${items.take(5).join(', ')}'
          '${items.length > 5 ? '…' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Удалить'.tr),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final remove = items.toSet();
    setState(() {
      _items = [
        for (final item in _items)
          if (!remove.contains(item)) item,
      ];
    });
    _clearSelection();
  }

  void _onItemTap(String item) {
    if (_selecting) {
      _toggleSelected(item);
    } else {
      _toggleSelected(item);
    }
  }

  void _onItemLongPress(String item) => _toggleSelected(item);

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
    if (_items.any((item) => item.toLowerCase() == value.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Уже в списке'.tr)),
      );
      return;
    }
    setState(() {
      _items = [..._items, value];
      _sortItems();
    });
    _addCtrl.clear();
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
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.add, size: 28),
      ),
    );
  }

  Widget _deleteBar(int count) {
    return Material(
      color: AppColors.primary,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: _clearSelection,
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Отмена'.tr,
              ),
              Expanded(
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _deleteSelected,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  'Удалить'.tr,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: widget.title,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    return SettingsPageScaffold(
      title: widget.title,
      dirty: _dirty,
      onSave: _save,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              _selecting
                  ? 'Нажмите «Удалить» внизу или отмените выбор.'.tr
                  : widget.hint,
              style: const TextStyle(color: Colors.black54),
            ),
            if (!_selecting) ...[
              const SizedBox(height: 4),
              Text(
                'Зажмите или нажмите плитку, чтобы выделить.'.tr,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            if (!_selecting)
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
            if (!_selecting) const SizedBox(height: 12),
            Expanded(
              child: _items.isEmpty
                  ? Center(child: Text('Список пуст'.tr))
                  : ValueListenableBuilder<Set<String>>(
                      valueListenable: _selected,
                      builder: (context, selected, _) {
                        return GridView.builder(
                          padding: const EdgeInsets.only(bottom: 16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.05,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            return SettingsHubTile(
                              title: item,
                              subtitle: '',
                              icon: Icons.label_outline,
                              color: AppColors.primary,
                              selected: selected.contains(item),
                              onTap: () => _onItemTap(item),
                              onLongPress: () => _onItemLongPress(item),
                            );
                          },
                        );
                      },
                    ),
            ),
            if (_selecting) _deleteBar(_selected.value.length),
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
  final ValueNotifier<Set<String>> _selected = ValueNotifier({});
  late final bool Function() _dismissSelection;
  bool _loading = true;
  bool _saving = false;
  List<JobStatusDef> _items = [];
  String _savedFp = '';

  String _fp(List<JobStatusDef> items) =>
      items.map((s) => '${s.id}\u0001${s.label}\u0001${s.colorValue}').join('\n');

  bool get _dirty => !_loading && _fp(_items) != _savedFp;

  bool get _selecting => _selected.value.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _dismissSelection = () {
      if (_selected.value.isEmpty) return false;
      _selected.value = {};
      return true;
    };
    AppCommands.addSelectionGuard(_dismissSelection);
    _selected.addListener(_onSelectionChanged);
    _load();
  }

  Future<void> _load() async {
    final items = await StatusService.loadDefsOnce();
    if (!mounted) return;
    setState(() {
      _items = List<JobStatusDef>.from(items);
      _savedFp = _fp(_items);
      _loading = false;
    });
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      await StatusService.replaceAll(_items);
      if (!mounted) return true;
      setState(() {
        _savedFp = _fp(_items);
        _saving = false;
      });
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selected.removeListener(_onSelectionChanged);
    AppCommands.removeSelectionGuard(_dismissSelection);
    _selected.dispose();
    super.dispose();
  }

  void _clearSelection() => _selected.value = {};

  void _toggleSelected(String id) {
    final next = Set<String>.from(_selected.value);
    if (!next.add(id)) next.remove(id);
    _selected.value = next;
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.value.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить'.tr),
        content: Text('${'Удалить'.tr} ${ids.length}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Удалить'.tr),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final remove = ids.toSet();
    setState(() {
      _items = [
        for (final item in _items)
          if (!remove.contains(item.id) || item.builtin) item,
      ];
    });
    _clearSelection();
  }

  void _onStatusTap(JobStatusDef status) {
    if (_selecting) {
      if (!status.builtin) _toggleSelected(status.id);
      return;
    }
    _edit(status);
  }

  void _onStatusLongPress(JobStatusDef status) {
    if (status.builtin) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Базовый статус удалить нельзя'.tr),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    _toggleSelected(status.id);
  }

  Widget _deleteBar(int count) {
    return Material(
      color: AppColors.primary,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: _clearSelection,
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Отмена'.tr,
              ),
              Expanded(
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _deleteSelected,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  'Удалить'.tr,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(JobStatusDef status) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final saved = await showDialog<(String, int)>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _StatusEditorDialog(status: status),
    );
    if (saved == null || !mounted) return;
    setState(() {
      _items = [
        for (final item in _items)
          if (item.id == status.id)
            item.copyWith(label: saved.$1, colorValue: saved.$2)
          else
            item,
      ];
    });
  }

  Future<void> _add() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final created = await showDialog<(String, int)>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _StatusEditorDialog(),
    );
    if (created == null || created.$1.isEmpty || !mounted) return;
    final trimmed = created.$1.trim();
    if (_items.any((item) => item.id == trimmed || item.label == trimmed)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Уже в списке'.tr)),
      );
      return;
    }
    setState(() {
      _items = [
        ..._items,
        JobStatusDef(
          id: trimmed,
          label: trimmed,
          colorValue: created.$2,
          builtin: false,
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: 'Статусы заявок'.tr,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    return SettingsPageScaffold(
      title: 'Статусы заявок'.tr,
      dirty: _dirty,
      onSave: _save,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              _selecting
                  ? 'Нажмите «Удалить» внизу или отмените выбор.'.tr
                  : 'Нажмите статус, чтобы сменить название и цвет. Плюс в списке добавляет новый.'.tr,
              style: const TextStyle(color: Colors.black54),
            ),
            if (!_selecting) ...[
              const SizedBox(height: 4),
              Text(
                'Зажмите свой статус, чтобы выделить и удалить.'.tr,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            if (!_selecting)
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor:
                          AppColors.accent.withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _saving ? null : _add,
                    icon: _saving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.add, size: 28),
                  ),
                ),
              ),
            if (!_selecting) const SizedBox(height: 12),
            Expanded(
              child: ValueListenableBuilder<Set<String>>(
                valueListenable: _selected,
                builder: (context, selected, _) {
                  return GridView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.05,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final status = _items[i];
                          final subtitle = status.id == JobStatuses.rescheduled
                              ? 'Сам'.tr
                              : status.id == JobStatuses.inProgress
                                  ? '—'.tr
                                  : status.builtin
                                      ? 'Базовый'.tr
                                      : 'Свой'.tr;
                          return SettingsHubTile(
                            title: trAny(status.label),
                            subtitle: subtitle,
                            icon: Icons.circle,
                            color: status.color,
                            active: !status.builtin,
                            selected: selected.contains(status.id),
                            onTap: () => _onStatusTap(status),
                            onLongPress: () => _onStatusLongPress(status),
                          );
                        },
                      );
                    },
                  ),
            ),
            if (_selecting) _deleteBar(_selected.value.length),
          ],
        ),
      ),
    );
  }
}

class _StatusEditorDialog extends StatefulWidget {
  final JobStatusDef? status;

  const _StatusEditorDialog({this.status});

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
    _color = widget.status?.colorValue ?? StatusService.statusColorPalette.first;
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

  Color _contrastIconColor(int argb) {
    final c = Color(argb);
    return c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
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
            const SizedBox(height: 4),
            Text(
              'Выберите оттенок'.tr,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            for (final group in StatusService.statusColorGroups) ...[
              Text(
                group.labelKey.tr,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in group.colors)
                    GestureDetector(
                      onTap: () => setState(() => _color = value),
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: Color(value),
                        child: _color == value
                            ? Icon(
                                Icons.check,
                                color: _contrastIconColor(value),
                                size: 17,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
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
