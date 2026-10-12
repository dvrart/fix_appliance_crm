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
import '../../../../shared/widgets/catalog_picker.dart';
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

const _kTrackingSuppliers = <String, String>{
  'amazon': 'Amazon',
  'reliable_parts': 'Reliable Parts',
  'partselect': 'PartSelect',
  'encompass': 'Encompass / RepairClinic',
  'marcone': 'Marcone',
  'ebay': 'eBay',
  'carrier': 'UPS / FedEx / Purolator / Canada Post',
  'other': 'Другой',
};

String visitDurationLabel(int minutes) {
  switch (minutes) {
    case 30:
      return '30 мин'.tr;
    case 45:
      return '45 мин'.tr;
    case 60:
      return '1 час'.tr;
    case 90:
      return '1.5 часа'.tr;
    case 120:
      return '2 часа'.tr;
    case 180:
      return '3 часа'.tr;
    default:
      return '$minutes ${'мин'.tr}';
  }
}

String trackingStatusLabel(String status) {
  switch (status) {
    case 'delivered':
      return 'Доставлено'.tr;
    case 'out_for_delivery':
      return 'Курьер сегодня'.tr;
    case 'shipped':
      return 'Отправлено'.tr;
    default:
      return status;
  }
}

String _cleanJobText(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text == 'Нет описания') return '';
  return text;
}

class _JobInfo {
  final String problem;
  final String solution;
  final String packing;
  final String trackingNumber;
  final String amazonOrderId;
  final String carrier;
  final int durationMinutes;

  const _JobInfo({
    required this.problem,
    required this.solution,
    required this.packing,
    required this.trackingNumber,
    required this.amazonOrderId,
    required this.carrier,
    required this.durationMinutes,
  });

  bool sameTracking(_JobInfo other) =>
      trackingNumber == other.trackingNumber &&
      amazonOrderId == other.amazonOrderId &&
      carrier == other.carrier;

  @override
  bool operator ==(Object other) =>
      other is _JobInfo &&
      problem == other.problem &&
      solution == other.solution &&
      packing == other.packing &&
      sameTracking(other) &&
      durationMinutes == other.durationMinutes;

  @override
  int get hashCode => Object.hash(
    problem,
    solution,
    packing,
    trackingNumber,
    amazonOrderId,
    carrier,
    durationMinutes,
  );
}

Future<void> openJobInfoEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final carrier = (ctrl.jobData['trackingCarrier'] ?? '').toString().trim();
  final amazonId = ctrl.amazonOrderId.trim();
  final before = _JobInfo(
    problem: _cleanJobText(ctrl.currentDescription),
    solution: _cleanJobText(ctrl.currentSolution),
    packing: packingItemsFromNotes(ctrl.packingNotes).join('\n'),
    trackingNumber: ctrl.trackingNumber.trim(),
    amazonOrderId: amazonId,
    carrier: _kTrackingSuppliers.containsKey(carrier)
        ? carrier
        : (carrier.isEmpty && amazonId.isNotEmpty ? 'amazon' : 'other'),
    durationMinutes: ctrl.durationMinutes,
  );
  final after = await _openEditor<_JobInfo>(
    context,
    _JobInfoEditorPage(initial: before, trackingStatus: ctrl.trackingStatus),
  );
  if (after == null) return;
  if (after.problem != before.problem || after.solution != before.solution) {
    await ctrl.updateProblemAndSolution(
      problem: after.problem,
      solution: after.solution,
    );
  }
  if (after.packing != before.packing) {
    await ctrl.updatePackingNotes(after.packing);
  }
  if (!after.sameTracking(before)) {
    await ctrl.updateTracking(
      number: after.trackingNumber,
      amazonId: after.amazonOrderId,
      carrier: after.carrier,
    );
  }
  if (after.durationMinutes != before.durationMinutes) {
    await ctrl.updateDurationMinutes(after.durationMinutes);
  }
}

Future<void> openApplianceEditor(
  BuildContext context,
  JobDetailsController ctrl,
) async {
  final raw = ctrl.jobData['appliances'];
  final initial = <Map<String, String>>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      initial.add({
        'type': (item['type'] ?? '').toString(),
        'brand': (item['brand'] ?? '').toString(),
        'model': (item['model'] ?? '').toString(),
        'serialNumber': (item['serialNumber'] ?? '').toString(),
        'issue': (item['issue'] ?? '').toString(),
      });
    }
  }
  if (initial.isEmpty) {
    initial.add({
      'type': (ctrl.jobData['applianceType'] ?? '').toString(),
      'brand': (ctrl.jobData['brand'] ?? '').toString(),
      'model': (ctrl.jobData['model'] ?? '').toString(),
      'serialNumber': (ctrl.jobData['serialNumber'] ?? '').toString(),
      'issue': ctrl.currentDescription,
    });
  }
  final saved = await _openEditor<List<Map<String, String>>>(
    context,
    _ApplianceEditorPage(initial: initial),
  );
  if (saved != null) {
    await ctrl.updateAppliances(saved);
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

class _JobInfoEditorPage extends StatefulWidget {
  final _JobInfo initial;
  final String trackingStatus;
  const _JobInfoEditorPage({
    required this.initial,
    required this.trackingStatus,
  });

  @override
  State<_JobInfoEditorPage> createState() => _JobInfoEditorPageState();
}

class _JobInfoEditorPageState extends State<_JobInfoEditorPage>
    with SingleTickerProviderStateMixin {
  static const _problemTint = Color(0xFFFFF1F0);
  static const _problemAccent = Color(0xFFB71C1C);
  static const _solutionTint = Color(0xFFEFF8F1);
  static const _solutionAccent = Color(0xFF1B5E20);
  static const _durationOptions = [30, 45, 60, 90, 120, 180];

  late final TabController _tabs;
  late final TextEditingController _problem;
  late final TextEditingController _solution;
  late final TextEditingController _packingInput;
  late final TextEditingController _trackingNumber;
  late final TextEditingController _amazonOrder;
  late final List<String> _packing;
  late String _carrier;
  late int _duration;
  Animation<double>? _tabAnimation;
  int _hapticTab = 0;
  bool _translating = false;
  bool _swapLock = false;
  String _problemOther = '';

  Color get _plainTint =>
      Color.alphaBlend(AppColors.primary.withValues(alpha: 0.05), Colors.white);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _tabs = TabController(length: 2, vsync: this);
    _tabAnimation = _tabs.animation;
    _tabAnimation?.addListener(_onTabAnimation);
    _tabs.addListener(_onTabs);
    _problem = TextEditingController(text: initial.problem);
    _solution = TextEditingController(text: initial.solution);
    _packingInput = TextEditingController();
    _trackingNumber = TextEditingController(text: initial.trackingNumber);
    _amazonOrder = TextEditingController(text: initial.amazonOrderId);
    _packing = packingItemsFromNotes(initial.packing);
    _carrier = initial.carrier;
    _duration = initial.durationMinutes;
  }

  @override
  void dispose() {
    _tabAnimation?.removeListener(_onTabAnimation);
    _tabs.removeListener(_onTabs);
    _tabs.dispose();
    _problem.dispose();
    _solution.dispose();
    _packingInput.dispose();
    _trackingNumber.dispose();
    _amazonOrder.dispose();
    super.dispose();
  }

  void _buzzTab(int index) {
    final next = index.clamp(0, _tabs.length - 1);
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

  _JobInfo get _current {
    final typed = _packingInput.text.trim();
    return _JobInfo(
      problem: _cleanJobText(_problem.text),
      solution: _cleanJobText(_solution.text),
      packing: [..._packing, if (typed.isNotEmpty) typed].join('\n'),
      trackingNumber: _trackingNumber.text.trim(),
      amazonOrderId: _amazonOrder.text.trim(),
      carrier: _carrier,
      durationMinutes: _duration,
    );
  }

  bool get _dirty => _current != widget.initial;

  void _save() {
    FocusScope.of(context).unfocus();
    Navigator.pop(context, _current);
  }

  void _addPacking() {
    final value = _packingInput.text.trim();
    if (value.isEmpty) return;
    _packing.add(value);
    _packingInput.clear();
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

  InputDecoration _field({String? label, String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  TextStyle get _sectionStyle => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w800,
    color: Colors.grey.shade700,
  );

  Widget _textPane({
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
                decoration: _field(hint: hint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSheet(
    String title,
    Widget Function(BuildContext sheetContext, VoidCallback refresh) body,
  ) async {
    FocusScope.of(context).unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            void refresh() {
              setSheet(() {});
              if (mounted) setState(() {});
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.75,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 30,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(child: body(sheetContext, refresh)),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  void _openPackingSheet() {
    _openSheet('Что взять с собой'.tr, (sheetContext, refresh) {
      void add() {
        _addPacking();
        refresh();
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _packing.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Список пуст — добавьте позицию'.tr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    itemCount: _packing.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return Material(
                        color: _plainTint,
                        borderRadius: BorderRadius.circular(12),
                        child: ListTile(
                          title: Text(_packing[index]),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, color: Colors.grey),
                            onPressed: () {
                              _packing.removeAt(index);
                              refresh();
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _packingInput,
                    autofocus: _packing.isEmpty,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => refresh(),
                    onSubmitted: (_) => add(),
                    decoration: _field(hint: 'Фильтр, плата, ключи…'.tr),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: add,
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
        ],
      );
    });
  }

  void _openTrackingSheet() {
    final status = widget.trackingStatus.trim();
    _openSheet('Доставка'.tr, (sheetContext, refresh) {
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          if (status.isNotEmpty) ...[
            Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  size: 20,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${'Статус'.tr}: ${trackingStatusLabel(status)}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Text('Поставщик'.tr, style: _sectionStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in _kTrackingSuppliers.entries)
                ChoiceChip(
                  label: Text(entry.value.tr),
                  selected: _carrier == entry.key,
                  onSelected: (_) {
                    _carrier = entry.key;
                    refresh();
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _trackingNumber,
            textInputAction: TextInputAction.next,
            onChanged: (_) => refresh(),
            decoration: _field(label: 'Трек-номер'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amazonOrder,
            textInputAction: TextInputAction.done,
            onChanged: (_) => refresh(),
            decoration: _field(
              label: 'Номер заказа'.tr,
              hint: '123-1234567-1234567',
            ),
          ),
        ],
      );
    });
  }

  void _openDurationSheet() {
    final options = {
      ..._durationOptions,
      widget.initial.durationMinutes,
    }.toList()..sort();
    _openSheet('Длительность нового визита'.tr, (sheetContext, refresh) {
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final minutes in options)
            ListTile(
              leading: Icon(
                _duration == minutes
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: AppColors.primary,
              ),
              title: Text(
                visitDurationLabel(minutes),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              selected: _duration == minutes,
              onTap: () {
                _duration = minutes;
                refresh();
                Navigator.pop(sheetContext);
              },
            ),
        ],
      );
    });
  }

  Widget _visitTile({
    required IconData icon,
    required String caption,
    required String value,
    required VoidCallback onTap,
  }) {
    final empty = value.isEmpty;
    return Material(
      color: _plainTint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 19, color: AppColors.primary),
              ),
              const SizedBox(height: 6),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                empty ? '—' : value,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: empty ? Colors.grey : const Color(0xFF1A1A1A),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _visitPanel() {
    final typed = _packingInput.text.trim();
    final packing = [..._packing, if (typed.isNotEmpty) typed];
    final number = _trackingNumber.text.trim();
    final order = _amazonOrder.text.trim();
    final status = widget.trackingStatus.trim();
    final tracking = number.isEmpty && order.isEmpty
        ? ''
        : (status.isNotEmpty && _current.sameTracking(widget.initial)
              ? trackingStatusLabel(status)
              : (number.isNotEmpty ? number : order));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text('К визиту'.tr, style: _sectionStyle),
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _visitTile(
                    icon: Icons.inventory_2_outlined,
                    caption: 'С собой'.tr,
                    value: packing.isEmpty
                        ? ''
                        : (packing.length == 1
                              ? packing.first
                              : '${packing.length}'),
                    onTap: _openPackingSheet,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _visitTile(
                    icon: Icons.local_shipping_outlined,
                    caption: 'Доставка'.tr,
                    value: tracking,
                    onTap: _openTrackingSheet,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _visitTile(
                    icon: Icons.timer_outlined,
                    caption: 'Длительность'.tr,
                    value: visitDurationLabel(_duration),
                    onTap: _openDurationSheet,
                  ),
                ),
              ],
            ),
          ),
        ],
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
              title: Text('Информация'.tr),
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
                      _textPane(
                        tint: _problemTint,
                        controller: _problem,
                        hint: 'Нажмите, чтобы добавить описание...'.tr,
                        translate: true,
                      ),
                      _textPane(
                        tint: _solutionTint,
                        controller: _solution,
                        hint: 'Что сделали, какая деталь, результат...'.tr,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: Material(
              color: Colors.white,
              elevation: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _visitPanel(),
                  BottomConfirmButton(dirty: _dirty, onPressed: _save),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ApplianceEditItem {
  final TextEditingController type;
  final TextEditingController brand;
  final TextEditingController model;
  final TextEditingController serial;
  final TextEditingController issue;

  _ApplianceEditItem(Map<String, String> initial)
    : type = TextEditingController(text: initial['type'] ?? ''),
      brand = TextEditingController(text: initial['brand'] ?? ''),
      model = TextEditingController(text: initial['model'] ?? ''),
      serial = TextEditingController(text: initial['serialNumber'] ?? ''),
      issue = TextEditingController(text: initial['issue'] ?? '');

  _ApplianceEditItem.empty()
    : type = TextEditingController(),
      brand = TextEditingController(),
      model = TextEditingController(),
      serial = TextEditingController(),
      issue = TextEditingController();

  void dispose() {
    type.dispose();
    brand.dispose();
    model.dispose();
    serial.dispose();
    issue.dispose();
  }
}

class _ApplianceEditorPage extends StatefulWidget {
  final List<Map<String, String>> initial;
  const _ApplianceEditorPage({required this.initial});

  @override
  State<_ApplianceEditorPage> createState() => _ApplianceEditorPageState();
}

class _ApplianceEditorPageState extends State<_ApplianceEditorPage> {
  late List<_ApplianceEditItem> _items;

  @override
  void initState() {
    super.initState();
    _items = [for (final item in widget.initial) _ApplianceEditItem(item)];
    if (_items.isEmpty) _items.add(_ApplianceEditItem.empty());
    for (final item in _items) {
      _attach(item);
    }
  }

  void _attach(_ApplianceEditItem item) {
    for (final controller in [
      item.type,
      item.brand,
      item.model,
      item.serial,
      item.issue,
    ]) {
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  bool get _dirty {
    if (_items.length != widget.initial.length) return true;
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final original = widget.initial[i];
      if (item.type.text != (original['type'] ?? '') ||
          item.brand.text != (original['brand'] ?? '') ||
          item.model.text != (original['model'] ?? '') ||
          item.serial.text != (original['serialNumber'] ?? '') ||
          item.issue.text != (original['issue'] ?? '')) {
        return true;
      }
    }
    return false;
  }

  void _add() {
    final item = _ApplianceEditItem.empty();
    _attach(item);
    setState(() => _items.add(item));
  }

  void _remove(int index) {
    final item = _items[index];
    setState(() => _items.removeAt(index));
    item.dispose();
  }

  Future<void> _pickType(_ApplianceEditItem item) async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Тип техники'.tr,
      itemsStream: CatalogService.streamApplianceTypes(),
      onAdd: CatalogService.addApplianceType,
    );
    if (result != null) {
      setState(() => item.type.text = result);
    }
  }

  Future<void> _pickBrand(_ApplianceEditItem item) async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Бренд'.tr,
      itemsStream: CatalogService.streamBrands(),
      onAdd: CatalogService.addBrand,
    );
    if (result != null) {
      setState(() => item.brand.text = result);
    }
  }

  void _save() {
    for (final item in _items) {
      if (item.type.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Укажите тип техники'.tr)),
        );
        return;
      }
    }
    Navigator.pop(context, [
      for (final item in _items)
        {
          'type': item.type.text,
          'brand': item.brand.text,
          'model': item.model.text,
          'serialNumber': item.serial.text,
          'issue': item.issue.text,
        },
    ]);
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    IconData? icon,
    String? hint,
    int maxLines = 1,
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        readOnly: readOnly,
        onTap: onTap,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon == null
              ? null
              : Icon(icon, color: Colors.grey, size: 20),
          suffixIcon: readOnly
              ? const Icon(Icons.arrow_drop_down, color: Colors.grey)
              : null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFFCC520), width: 2),
          ),
          filled: true,
          fillColor: Colors.grey.shade50,
        ),
      ),
    );
  }

  Widget _applianceCard(int index) {
    final item = _items[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${'Аппарат'.tr} ${index + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
                if (_items.length > 1)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _remove(index),
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppliancePicture(type: item.type.text, size: 48),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field(
                    controller: item.type,
                    label: 'Тип техники'.tr,
                    readOnly: true,
                    onTap: () => _pickType(item),
                  ),
                ),
              ],
            ),
            _field(
              controller: item.brand,
              label: 'Бренд'.tr,
              hint: 'Без бренда'.tr,
              icon: Icons.branding_watermark,
              readOnly: true,
              onTap: () => _pickBrand(item),
            ),
            _field(
              controller: item.model,
              label: 'Модель'.tr,
              icon: Icons.qr_code,
            ),
            _field(
              controller: item.serial,
              label: 'Серийный номер'.tr,
              icon: Icons.pin,
            ),
            _field(
              controller: item.issue,
              label: 'Описание'.tr,
              icon: Icons.build,
              maxLines: 2,
            ),
          ],
        ),
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
          for (var index = 0; index < _items.length; index++)
            _applianceCard(index),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text('Добавить еще технику'.tr),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF14557F),
                side: const BorderSide(color: Color(0xFF14557F)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
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
