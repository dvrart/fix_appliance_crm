import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/thumb_image.dart';
import '../../../../services/catalog_service.dart';
import '../../../../services/message_translate_service.dart';
import '../../../../shared/widgets/appliance_picture.dart';
import '../../../../shared/widgets/app_bar_save.dart';
import '../../../../shared/widgets/dirty_leave_scope.dart';
import '../widgets/full_screen_gallery.dart';
import '../job_details_controller.dart';

List<String> packingItemsFromNotes(String notes) {
  final trimmed = notes.trim();
  if (trimmed.isEmpty) return [];
  if (trimmed.contains('\n')) {
    return trimmed
        .split('\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return trimmed
      .split(RegExp(r'[,;]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

Future<T?> _openEditor<T>(BuildContext context, Widget page) {
  return Navigator.push<T>(context, MaterialPageRoute(builder: (_) => page));
}

Future<void> openPackingEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final saved = await _openEditor<String>(
    context,
    _PackingEditorPage(initial: ctrl.packingNotes),
  );
  if (saved != null) await ctrl.updatePackingNotes(saved);
}

Future<void> openDescriptionEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final saved = await _openEditor<Map<String, String>>(
    context,
    _DescriptionEditorPage(
      initialProblem: ctrl.currentDescription,
      initialSolution: ctrl.currentSolution,
    ),
  );
  if (saved != null) {
    await ctrl.updateProblemAndSolution(
      problem: saved['problem'] ?? '',
      solution: saved['solution'] ?? '',
    );
  }
}

Future<void> openApplianceEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final appliances = ctrl.jobData['appliances'];
  Map<String, dynamic>? primary;
  if (appliances is List && appliances.isNotEmpty && appliances.first is Map) {
    primary = Map<String, dynamic>.from(appliances.first as Map);
  }
  final currentType = (ctrl.jobData['applianceType'] ?? primary?['type'] ?? '')
      .toString();
  final currentBrand = (ctrl.jobData['brand'] ?? primary?['brand'] ?? '')
      .toString();
  final saved = await _openEditor<Map<String, String>>(
    context,
    _ApplianceEditorPage(initialType: currentType, initialBrand: currentBrand),
  );
  if (saved != null) {
    await ctrl.updateAppliance(
      type: saved['type'] ?? currentType,
      brand: saved['brand'] ?? '',
    );
  }
}

Future<void> openPhotosEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final kept = [
    for (final item in ctrl.attachments)
      if (_keepWithPhotos(item)) Map<String, dynamic>.from(item),
  ];
  final photos = [
    for (final item in ctrl.attachments)
      if (!_keepWithPhotos(item)) Map<String, dynamic>.from(item),
  ];
  final original = [
    for (final item in ctrl.attachments) Map<String, dynamic>.from(item),
  ];
  var applied = false;
  void apply(List<Map<String, dynamic>> next) {
    applied = true;
    ctrl.replaceAttachments([...next, ...kept]);
  }

  final saved = await _openEditor<List<Map<String, dynamic>>>(
    context,
    _PhotosEditorPage(initial: photos, onChanged: apply),
  );
  if (saved != null) {
    ctrl.replaceAttachments([...saved, ...kept]);
  } else if (applied) {
    ctrl.replaceAttachments(original);
  }
}

bool _keepWithPhotos(Map<String, dynamic> item) {
  final kind = (item['kind'] ?? '').toString();
  return kind == 'call' || kind == 'signature';
}

class _EditorScaffold extends StatelessWidget {
  final String title;
  final bool dirty;
  final VoidCallback onSave;
  final Widget body;
  final Widget? bottom;

  const _EditorScaffold({
    required this.title,
    required this.dirty,
    required this.onSave,
    required this.body,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: dirty,
      onSave: () async {
        onSave();
        return true;
      },
      child: Builder(
        builder: (context) {
          return Scaffold(
            backgroundColor: AppColors.surface,
            appBar: AppBar(
              title: Text(title),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              automaticallyImplyLeading: false,
            ),
            body: body,
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (bottom != null) bottom!,
                BottomConfirmButton(dirty: dirty, onPressed: onSave),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PackingEditorPage extends StatefulWidget {
  final String initial;
  const _PackingEditorPage({required this.initial});

  @override
  State<_PackingEditorPage> createState() => _PackingEditorPageState();
}

class _PackingEditorPageState extends State<_PackingEditorPage> {
  late List<String> _items;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _items = packingItemsFromNotes(widget.initial);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _dirty {
    final original = packingItemsFromNotes(widget.initial);
    if (original.length != _items.length) return true;
    for (var i = 0; i < _items.length; i++) {
      if (original[i] != _items[i]) return true;
    }
    return false;
  }

  void _add() {
    final value = _input.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _items.add(value);
      _input.clear();
    });
  }

  void _save() {
    Navigator.pop(context, _items.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    return _EditorScaffold(
      title: 'Что взять с собой'.tr,
      dirty: _dirty,
      onSave: _save,
      body: Column(
        children: [
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text(
                      'Список пуст — добавьте позицию'.tr,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: _items.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        child: ListTile(
                          title: Text(_items[index]),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, color: Colors.grey),
                            onPressed: () =>
                                setState(() => _items.removeAt(index)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(
                        hintText: 'Фильтр, плата, ключи…'.tr,
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _add,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DescriptionEditorPage extends StatefulWidget {
  final String initialProblem;
  final String initialSolution;
  const _DescriptionEditorPage({
    required this.initialProblem,
    required this.initialSolution,
  });

  @override
  State<_DescriptionEditorPage> createState() => _DescriptionEditorPageState();
}

class _DescriptionEditorPageState extends State<_DescriptionEditorPage>
    with SingleTickerProviderStateMixin {
  static const _problemTint = Color(0xFFFFF1F0);
  static const _problemAccent = Color(0xFFB71C1C);
  static const _solutionTint = Color(0xFFEFF8F1);
  static const _solutionAccent = Color(0xFF1B5E20);

  late final TabController _tabs;
  late final TextEditingController _problem;
  late final TextEditingController _solution;
  Animation<double>? _tabAnimation;
  int _hapticTab = 0;
  bool _translating = false;
  bool _swapLock = false;
  String _problemOther = '';

  static String _clean(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text == 'Нет описания') return '';
    return text;
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabAnimation = _tabs.animation;
    _tabAnimation?.addListener(_onTabAnimation);
    _tabs.addListener(_onTabs);
    _problem = TextEditingController(text: _clean(widget.initialProblem));
    _solution = TextEditingController(text: _clean(widget.initialSolution));
  }

  @override
  void dispose() {
    _tabAnimation?.removeListener(_onTabAnimation);
    _tabs.removeListener(_onTabs);
    _tabs.dispose();
    _problem.dispose();
    _solution.dispose();
    super.dispose();
  }

  void _buzzTab(int index) {
    final next = index.clamp(0, 1);
    if (next == _hapticTab) return;
    _hapticTab = next;
    AppFeedback.pleasant();
  }

  void _onTabAnimation() {
    final value = _tabAnimation?.value;
    if (value == null) return;
    _buzzTab(value.round());
  }

  void _onTabs() {
    if (!mounted) return;
    _buzzTab(_tabs.index);
    if (!_tabs.indexIsChanging) setState(() {});
  }

  bool get _dirty =>
      _clean(_problem.text) != _clean(widget.initialProblem) ||
      _clean(_solution.text) != _clean(widget.initialSolution);

  void _save() {
    Navigator.pop(context, {
      'problem': _clean(_problem.text),
      'solution': _clean(_solution.text),
    });
  }

  Future<void> _translateProblem() async {
    final text = _problem.text.trim();
    if (text.isEmpty || _translating) return;
    if (_problemOther.trim().isNotEmpty) {
      final current = _problem.text;
      _swapLock = true;
      setState(() {
        _problem.text = _problemOther;
        _problemOther = current;
      });
      _swapLock = false;
      return;
    }
    setState(() => _translating = true);
    try {
      final translated = MessageTranslateService.looksRussian(text)
          ? await MessageTranslateService.toEnglish(text)
          : await MessageTranslateService.toRussian(text);
      if (!mounted) return;
      if (translated.trim().isEmpty || translated.trim() == text) return;
      setState(() {
        _problemOther = text;
        _problem.text = translated;
      });
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  Widget _pane({
    required Color tint,
    required TextEditingController controller,
    required String hint,
    bool translate = false,
  }) {
    return ColoredBox(
      color: tint,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          children: [
            if (translate)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _translating ? null : _translateProblem,
                  icon: _translating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.translate, size: 20),
                  label: Text('Перевести'.tr),
                ),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: (_) {
                  if (translate && !_swapLock) _problemOther = '';
                  setState(() {});
                },
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: hint,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: () async {
        _save();
        return true;
      },
      child: Builder(
        builder: (context) {
          return Scaffold(
            backgroundColor: AppColors.surface,
            appBar: AppBar(
              title: Text('Описание'.tr),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              automaticallyImplyLeading: false,
            ),
            body: Column(
              children: [
                AnimatedBuilder(
                  animation: _tabs.animation!,
                  builder: (context, _) {
                    final t = _tabs.animation!.value.clamp(0.0, 1.0);
                    final tint = Color.lerp(_problemTint, _solutionTint, t)!;
                    final accent = Color.lerp(
                      _problemAccent,
                      _solutionAccent,
                      t,
                    )!;
                    return Material(
                      color: tint,
                      child: TabBar(
                        controller: _tabs,
                        labelColor: accent,
                        unselectedLabelColor: const Color(0xFF5A5A5A),
                        indicatorColor: accent,
                        indicatorWeight: 3,
                        labelStyle: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                        tabs: [
                          Tab(text: 'Описание проблемы'.tr),
                          Tab(text: 'Решение проблемы'.tr),
                        ],
                      ),
                    );
                  },
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _pane(
                        tint: _problemTint,
                        controller: _problem,
                        hint: 'Нажмите, чтобы добавить описание...'.tr,
                        translate: true,
                      ),
                      _pane(
                        tint: _solutionTint,
                        controller: _solution,
                        hint: 'Что сделали, какая деталь, результат...'.tr,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: BottomConfirmButton(
              dirty: _dirty,
              onPressed: _save,
            ),
          );
        },
      ),
    );
  }
}

class _ApplianceEditorPage extends StatefulWidget {
  final String initialType;
  final String initialBrand;
  const _ApplianceEditorPage({
    required this.initialType,
    required this.initialBrand,
  });

  @override
  State<_ApplianceEditorPage> createState() => _ApplianceEditorPageState();
}

class _ApplianceEditorPageState extends State<_ApplianceEditorPage> {
  late String _type;
  late String _brand;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType.trim();
    _brand = widget.initialBrand.trim();
  }

  bool get _dirty =>
      _type != widget.initialType.trim() ||
      _brand != widget.initialBrand.trim();

  void _save() {
    if (_type.isEmpty) return;
    Navigator.pop(context, {'type': _type, 'brand': _brand});
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: Color(0xFF14557F),
        ),
      ),
    );
  }

  Widget _choiceTile({
    required String label,
    required bool selected,
    Widget? leading,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? AppColors.accent.withValues(alpha: 0.28) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: leading,
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: selected
            ? const Icon(Icons.check_circle, color: Color(0xFF14557F))
            : null,
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _EditorScaffold(
      title: 'Техника'.tr,
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _sectionTitle('Тип техники'.tr),
          StreamBuilder<List<String>>(
            stream: CatalogService.streamApplianceTypes(),
            builder: (context, snapshot) {
              final items = [
                ...(snapshot.data ?? CatalogService.defaultApplianceTypes),
              ];
              if (_type.isNotEmpty && !items.contains(_type)) {
                items.insert(0, _type);
              }
              return Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    if (index > 0) const SizedBox(height: 8),
                    _choiceTile(
                      label: trAny(items[index]),
                      selected: items[index] == _type,
                      leading: AppliancePicture(type: items[index], size: 48),
                      onTap: () => setState(() => _type = items[index]),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          _sectionTitle('Бренд'.tr),
          StreamBuilder<List<String>>(
            stream: CatalogService.streamBrands(),
            builder: (context, snapshot) {
              final items = [...(snapshot.data ?? const <String>[])];
              if (_brand.isNotEmpty && !items.contains(_brand)) {
                items.insert(0, _brand);
              }
              if (items.isEmpty) {
                return Text(
                  'Добавьте бренды в настройках каталога'.tr,
                  style: const TextStyle(color: Colors.grey),
                );
              }
              return Column(
                children: [
                  _choiceTile(
                    label: 'Без бренда'.tr,
                    selected: _brand.isEmpty,
                    onTap: () => setState(() => _brand = ''),
                  ),
                  for (final brand in items) ...[
                    const SizedBox(height: 8),
                    _choiceTile(
                      label: brand,
                      selected: brand == _brand,
                      onTap: () => setState(() => _brand = brand),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PhotosEditorPage extends StatefulWidget {
  final List<Map<String, dynamic>> initial;
  final ValueChanged<List<Map<String, dynamic>>>? onChanged;
  const _PhotosEditorPage({required this.initial, this.onChanged});

  @override
  State<_PhotosEditorPage> createState() => _PhotosEditorPageState();
}

class _PhotosEditorPageState extends State<_PhotosEditorPage> {
  late List<Map<String, dynamic>> _items;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _items = [
      for (final item in widget.initial) Map<String, dynamic>.from(item),
    ];
  }

  bool get _dirty {
    if (_items.length != widget.initial.length) return true;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i]['url'] != widget.initial[i]['url'] ||
          _items[i]['localPath'] != widget.initial[i]['localPath']) {
        return true;
      }
    }
    return false;
  }

  ImageProvider _imageOf(Map<String, dynamic> item) {
    final local = (item['localPath'] ?? '').toString();
    final url = (item['url'] ?? '').toString();
    if (local.isNotEmpty && url.isEmpty) {
      return ResizeImage(
        FileImage(File(local)),
        width: 480,
        policy: ResizeImagePolicy.fit,
      );
    }
    return thumbImage(url, width: 480);
  }

  Future<void> _add({required bool camera}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picker = ImagePicker();
      if (camera) {
        final file = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1200,
          imageQuality: 85,
        );
        if (file == null) return;
        _append(file.path);
      } else {
        final files = await picker.pickMultiImage(
          maxWidth: 1200,
          imageQuality: 85,
        );
        for (final file in files) {
          _append(file.path);
        }
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _notify() {
    widget.onChanged?.call([
      for (final item in _items) Map<String, dynamic>.from(item),
    ]);
  }

  void _append(String localPath) {
    setState(() {
      _items.add({
        'url': '',
        'localPath': localPath,
        'name': '${DateTime.now().millisecondsSinceEpoch}.jpg',
        'pendingUpload': true,
        'uploadedAt': DateTime.now().toIso8601String(),
      });
    });
    _notify();
  }

  void _open(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenGallery(images: _items, initialIndex: index),
      ),
    );
  }

  void _save() {
    Navigator.pop(context, _items);
  }

  Future<void> _pickAndAdd() async {
    if (_picking) return;
    final camera = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: Text('Сделать фото'.tr),
                onTap: () => Navigator.pop(context, true),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: Text('Выбрать из галереи'.tr),
                onTap: () => Navigator.pop(context, false),
              ),
            ],
          ),
        );
      },
    );
    if (camera == null) return;
    await _add(camera: camera);
  }

  Widget _addPhotoPlus({double size = 88}) {
    return Material(
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _picking ? null : _pickAndAdd,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: _picking
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.black,
                    ),
                  )
                : const Icon(Icons.add, color: Colors.black, size: 44),
          ),
        ),
      ),
    );
  }

  Widget _photoCell(int index) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Material(
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(index),
            child: Image(
              image: _imageOf(_items[index]),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return const ColoredBox(
                  color: Color(0xFFE0E0E0),
                  child: Icon(Icons.broken_image_outlined),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                setState(() => _items.removeAt(index));
                _notify();
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, color: Colors.white, size: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _EditorScaffold(
      title: 'Фото'.tr,
      dirty: _dirty,
      onSave: _save,
      body: _items.isEmpty
          ? Center(child: _addPhotoPlus(size: 96))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _items.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Center(child: _addPhotoPlus(size: 72));
                }
                return _photoCell(index - 1);
              },
            ),
    );
  }
}
