import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/thumb_image.dart';
import '../../../../models/job.dart';
import '../../../../services/catalog_service.dart';
import '../../../../services/message_translate_service.dart';
import '../../../../shared/widgets/appliance_picture.dart';
import '../../../../shared/widgets/catalog_picker.dart';
import '../../../../shared/widgets/app_bar_save.dart';
import '../../../../shared/widgets/dirty_leave_scope.dart';
import '../../../diagnostics/diagnostics_screen.dart';
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
  'parts_of_canada': 'partsofcanada.com',
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

String trackingPartsFromLabel(String carrier) {
  switch (carrier.trim()) {
    case 'amazon':
      return 'Запчасти с Amazon'.tr;
    case 'reliable_parts':
      return 'Запчасти с Reliable Parts'.tr;
    case 'partselect':
      return 'Запчасти с PartSelect'.tr;
    case 'parts_of_canada':
    case 'partsofcanada':
    case 'partsofcanada.com':
      return 'Запчасти с partsofcanada.com'.tr;
    case 'encompass':
      return 'Запчасти с Encompass'.tr;
    case 'marcone':
      return 'Запчасти с Marcone'.tr;
    case 'ebay':
      return 'Запчасти с eBay'.tr;
    case 'carrier':
      return 'Запчасти (курьер)'.tr;
    default:
      return 'Заказаны запчасти'.tr;
  }
}

String _cleanJobText(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text == 'Нет описания') return '';
  return text;
}

class _TrackingOrderDraft {
  final TextEditingController part;
  final TextEditingController trackingNumber;
  final TextEditingController orderId;
  String carrier;
  String status;
  String id;

  _TrackingOrderDraft({
    String part = '',
    String trackingNumber = '',
    String orderId = '',
    this.carrier = '',
    this.status = '',
    this.id = '',
  }) : part = TextEditingController(text: part),
       trackingNumber = TextEditingController(text: trackingNumber),
       orderId = TextEditingController(text: orderId);

  factory _TrackingOrderDraft.fromOrder(JobTrackingOrder order) {
    final rawCarrier = order.carrier.trim();
    final resolvedCarrier = order.isEmpty
        ? ''
        : (_kTrackingSuppliers.containsKey(rawCarrier)
              ? rawCarrier
              : order.effectiveCarrier);
    return _TrackingOrderDraft(
      id: order.id,
      part: order.part,
      trackingNumber: order.trackingNumber,
      orderId: order.orderId,
      carrier: resolvedCarrier,
      status: order.status,
    );
  }

  JobTrackingOrder toOrder() {
    final p = part.text.trim();
    final t = trackingNumber.text.trim();
    final o = orderId.text.trim();
    final c = carrier.trim();
    final hasAny = p.isNotEmpty || t.isNotEmpty || o.isNotEmpty || c.isNotEmpty;
    if (!hasAny) return const JobTrackingOrder();
    final resolvedCarrier = c.isNotEmpty
        ? c
        : ((o.isNotEmpty || t.toUpperCase().startsWith('TBA'))
              ? 'amazon'
              : 'other');
    return JobTrackingOrder(
      id: id,
      part: p,
      carrier: resolvedCarrier,
      trackingNumber: t,
      orderId: o,
      status: status,
    );
  }

  void dispose() {
    part.dispose();
    trackingNumber.dispose();
    orderId.dispose();
  }
}

class _JobInfo {
  final String problem;
  final String solution;
  final List<JobRecall> recalls;
  final String packing;
  final List<JobTrackingOrder> trackingOrders;
  final int durationMinutes;

  const _JobInfo({
    required this.problem,
    required this.solution,
    this.recalls = const [],
    required this.packing,
    required this.trackingOrders,
    required this.durationMinutes,
  });

  bool sameTracking(_JobInfo other) {
    if (trackingOrders.length != other.trackingOrders.length) return false;
    for (var i = 0; i < trackingOrders.length; i++) {
      if (trackingOrders[i] != other.trackingOrders[i]) return false;
    }
    return true;
  }

  bool sameRecalls(_JobInfo other) {
    if (recalls.length != other.recalls.length) return false;
    for (var i = 0; i < recalls.length; i++) {
      if (recalls[i] != other.recalls[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is _JobInfo &&
      problem == other.problem &&
      solution == other.solution &&
      sameRecalls(other) &&
      packing == other.packing &&
      sameTracking(other) &&
      durationMinutes == other.durationMinutes;

  @override
  int get hashCode => Object.hash(
    problem,
    solution,
    Object.hashAll(recalls),
    packing,
    Object.hashAll(trackingOrders),
    durationMinutes,
  );
}

class _RecallDraft {
  final String id;
  DateTime date;
  final String initialReport;
  final String initialReportEn;
  final TextEditingController description;
  final TextEditingController report;

  _RecallDraft({
    required this.id,
    required this.date,
    required String initialDescription,
    required this.initialReport,
    required this.initialReportEn,
  }) : description = TextEditingController(text: initialDescription),
       report = TextEditingController(text: initialReport);

  factory _RecallDraft.fromRecall(JobRecall r) => _RecallDraft(
    id: r.id,
    date: r.date,
    initialDescription: _cleanJobText(r.description),
    initialReport: _cleanJobText(r.report),
    initialReportEn: r.reportEn,
  );

  JobRecall toRecall() {
    final cleanDesc = _cleanJobText(description.text);
    final cleanRep = _cleanJobText(report.text);
    return JobRecall(
      id: id,
      date: date,
      description: cleanDesc,
      report: cleanRep,
      reportEn: cleanRep == initialReport ? initialReportEn : '',
    );
  }

  void dispose() {
    description.dispose();
    report.dispose();
  }
}

Future<void> openJobInfoEditor(
  BuildContext context,
  JobDetailsController ctrl, {
  int? initialRecallIndex,
}) async {
  final initialOrders = ctrl.trackingOrders.isNotEmpty
      ? List<JobTrackingOrder>.from(ctrl.trackingOrders)
      : JobTrackingOrder.parseList(ctrl.jobData);
  final initialRecalls = List<JobRecall>.from(ctrl.recalls);
  final firstVisitAt = ctrl.visits.isNotEmpty
      ? ctrl.visits.first.startAt
      : null;
  final defaultRecallIndex = initialRecallIndex ??
      ((ctrl.currentStatus == JobStatuses.repeatVisit &&
              initialRecalls.isNotEmpty)
          ? initialRecalls.length - 1
          : -1);
  final before = _JobInfo(
    problem: _cleanJobText(ctrl.currentDescription),
    solution: _cleanJobText(ctrl.currentSolution),
    recalls: initialRecalls,
    packing: packingItemsFromNotes(ctrl.packingNotes).join('\n'),
    trackingOrders: initialOrders,
    durationMinutes: ctrl.durationMinutes,
  );
  final after = await _openEditor<_JobInfo>(
    context,
    _JobInfoEditorPage(
      initial: before,
      firstVisitDate: firstVisitAt,
      initialRecallIndex: defaultRecallIndex,
      trackingStatus: ctrl.trackingStatus,
      applianceType: _primaryApplianceField(ctrl, 'type', 'applianceType'),
      applianceBrand: _primaryApplianceField(ctrl, 'brand', 'brand'),
      onAutoTranslatedProblem: (translated) {
        unawaited(
          ctrl.updateProblemAndSolution(
            problem: translated,
            solution: ctrl.currentSolution,
          ),
        );
      },
    ),
  );
  if (after == null) return;
  if (after.problem != before.problem || after.solution != before.solution) {
    await ctrl.updateProblemAndSolution(
      problem: after.problem,
      solution: after.solution,
    );
  }
  if (!after.sameRecalls(before)) {
    await ctrl.updateRecalls(after.recalls);
  }
  if (after.packing != before.packing) {
    await ctrl.updatePackingNotes(after.packing);
  }
  if (!after.sameTracking(before)) {
    await ctrl.updateTrackingOrders(after.trackingOrders);
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
                ?bottom,
                BottomConfirmButton(dirty: dirty, onPressed: onSave),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _primaryApplianceField(
  JobDetailsController ctrl,
  String itemKey,
  String rootKey,
) {
  final raw = ctrl.jobData['appliances'];
  if (raw is List && raw.isNotEmpty && raw.first is Map) {
    final first = raw.first as Map;
    final val = (first[itemKey] ?? '').toString().trim();
    if (val.isNotEmpty) return val;
  }
  return (ctrl.jobData[rootKey] ?? '').toString().trim();
}

class _JobInfoEditorPage extends StatefulWidget {
  final _JobInfo initial;
  final DateTime? firstVisitDate;
  final int initialRecallIndex;
  final String trackingStatus;
  final String applianceType;
  final String applianceBrand;
  final ValueChanged<String>? onAutoTranslatedProblem;
  const _JobInfoEditorPage({
    required this.initial,
    this.firstVisitDate,
    this.initialRecallIndex = -1,
    required this.trackingStatus,
    this.applianceType = '',
    this.applianceBrand = '',
    this.onAutoTranslatedProblem,
  });

  @override
  State<_JobInfoEditorPage> createState() => _JobInfoEditorPageState();
}

class _JobInfoEditorPageState extends State<_JobInfoEditorPage>
    with SingleTickerProviderStateMixin {
  static Color get _problemTint =>
      AppColors.isDark ? const Color(0xFF3E191E) : const Color(0xFFFFCDD2);
  static Color get _problemFieldFill =>
      AppColors.isDark ? const Color(0xFF2B1216) : const Color(0xFFFFEBEE);
  static Color get _problemAccent =>
      AppColors.isDark ? const Color(0xFFFF8A80) : const Color(0xFFC62828);
  static Color get _solutionTint =>
      AppColors.isDark ? const Color(0xFF163822) : const Color(0xFFC8E6C9);
  static Color get _solutionFieldFill =>
      AppColors.isDark ? const Color(0xFF102819) : const Color(0xFFE8F5E9);
  static Color get _solutionAccent =>
      AppColors.isDark ? const Color(0xFF69F0AE) : const Color(0xFF1B5E20);

  late final TabController _tabs;
  late final TextEditingController _problem;
  late final TextEditingController _solution;
  late final List<_RecallDraft> _recallDrafts;
  int _selectedRecallIndex = -1;
  late final TextEditingController _packingInput;
  late final List<_TrackingOrderDraft> _trackingDrafts;
  late final List<String> _packing;
  late int _duration;
  late String _baselineProblem;
  Animation<double>? _tabAnimation;
  int _hapticTab = 0;
  bool _translating = false;
  bool _swapLock = false;

  TextEditingController get _activeProblemController =>
      (_selectedRecallIndex >= 0 &&
              _selectedRecallIndex < _recallDrafts.length)
          ? _recallDrafts[_selectedRecallIndex].description
          : _problem;

  TextEditingController get _activeSolutionController =>
      (_selectedRecallIndex >= 0 &&
              _selectedRecallIndex < _recallDrafts.length)
          ? _recallDrafts[_selectedRecallIndex].report
          : _solution;

  Color get _plainTint =>
      Color.alphaBlend(AppColors.primary.withValues(alpha: 0.08), AppColors.card);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _tabs = TabController(length: 2, vsync: this);
    _tabAnimation = _tabs.animation;
    _tabAnimation?.addListener(_onTabAnimation);
    _tabs.addListener(_onTabs);
    _baselineProblem = initial.problem;
    _problem = TextEditingController(text: initial.problem);
    _solution = TextEditingController(text: initial.solution);
    _recallDrafts = [
      for (final r in initial.recalls) _RecallDraft.fromRecall(r),
    ];
    if (widget.initialRecallIndex >= 0 &&
        widget.initialRecallIndex < _recallDrafts.length) {
      _selectedRecallIndex = widget.initialRecallIndex;
    }
    _packingInput = TextEditingController();
    _trackingDrafts = initial.trackingOrders.isNotEmpty
        ? [
            for (final order in initial.trackingOrders)
              _TrackingOrderDraft.fromOrder(order),
          ]
        : [_TrackingOrderDraft()];
    _packing = packingItemsFromNotes(initial.packing);
    _duration = initial.durationMinutes;
    unawaited(_autoTranslateProblemIfNeeded());
  }

  @override
  void dispose() {
    _tabAnimation?.removeListener(_onTabAnimation);
    _tabs.removeListener(_onTabs);
    _tabs.dispose();
    _problem.dispose();
    _solution.dispose();
    for (final r in _recallDrafts) {
      r.dispose();
    }
    _packingInput.dispose();
    for (final draft in _trackingDrafts) {
      draft.dispose();
    }
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

  List<JobTrackingOrder> get _currentTrackingOrders => [
    for (final draft in _trackingDrafts)
      if (draft.toOrder().isNotEmpty) draft.toOrder(),
  ];

  _JobInfo get _current {
    final typed = _packingInput.text.trim();
    return _JobInfo(
      problem: _cleanJobText(_problem.text),
      solution: _cleanJobText(_solution.text),
      recalls: [for (final r in _recallDrafts) r.toRecall()],
      packing: [..._packing, if (typed.isNotEmpty) typed].join('\n'),
      trackingOrders: _currentTrackingOrders,
      durationMinutes: _duration,
    );
  }

  _JobInfo get _baseline => _JobInfo(
    problem: _cleanJobText(_baselineProblem),
    solution: widget.initial.solution,
    recalls: widget.initial.recalls,
    packing: widget.initial.packing,
    trackingOrders: widget.initial.trackingOrders,
    durationMinutes: widget.initial.durationMinutes,
  );

  void _addNewRecall() {
    AppFeedback.pleasant();
    final created = JobRecall.create(date: DateTime.now());
    setState(() {
      _recallDrafts.add(_RecallDraft.fromRecall(created));
      _selectedRecallIndex = _recallDrafts.length - 1;
      _tabs.animateTo(0);
    });
  }

  Future<void> _pickRecallDate(int index) async {
    if (index < 0 || index >= _recallDrafts.length) return;
    final current = _recallDrafts[index].date;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2022),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _recallDrafts[index].date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        current.hour,
        current.minute,
      );
    });
  }

  void _removeRecall(int index) {
    if (index < 0 || index >= _recallDrafts.length) return;
    AppFeedback.selection();
    setState(() {
      final removed = _recallDrafts.removeAt(index);
      removed.dispose();
      if (_selectedRecallIndex >= _recallDrafts.length) {
        _selectedRecallIndex = _recallDrafts.length - 1;
      }
    });
  }

  String _shortDay(DateTime d) =>
      DateFormat('d MMM', AppLocale.instance.dateLocale).format(d);

  Widget _buildRecallSelectorBar() {
    if (_recallDrafts.isEmpty) return const SizedBox.shrink();
    final firstLabel = widget.firstVisitDate != null
        ? '${context.tr('1-й ремонт', '1st repair')} (${_shortDay(widget.firstVisitDate!)})'
        : context.tr('1-й ремонт', '1st repair');
    return Container(
      width: double.infinity,
      color: AppColors.card,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              label: Text(firstLabel),
              selected: _selectedRecallIndex == -1,
              onSelected: (_) {
                FocusScope.of(context).unfocus();
                setState(() => _selectedRecallIndex = -1);
              },
              selectedColor: AppColors.primary.withValues(alpha: 0.2),
              labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: _selectedRecallIndex == -1
                    ? FontWeight.w800
                    : FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            for (var i = 0; i < _recallDrafts.length; i++) ...[
              const SizedBox(width: 6),
              InputChip(
                avatar: const Icon(
                  Icons.replay_circle_filled_rounded,
                  size: 17,
                  color: Color(0xFFD97706),
                ),
                label: GestureDetector(
                  onLongPress: () => _pickRecallDate(i),
                  child: Text(
                    _recallDrafts.length == 1
                        ? '${context.tr('Повторный выезд', 'Recall')} (${_shortDay(_recallDrafts[i].date)})'
                        : '${context.tr('Повтор', 'Recall')} #${i + 1} (${_shortDay(_recallDrafts[i].date)})',
                  ),
                ),
                selected: _selectedRecallIndex == i,
                onSelected: (_) {
                  FocusScope.of(context).unfocus();
                  setState(() => _selectedRecallIndex = i);
                },
                onDeleted: _selectedRecallIndex == i
                    ? () => _removeRecall(i)
                    : null,
                deleteIconColor: Colors.red.shade600,
                selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: _selectedRecallIndex == i
                      ? FontWeight.w800
                      : FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ],
            const SizedBox(width: 6),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: Text(context.tr('Ещё повтор', 'Add recall')),
              onPressed: _addNewRecall,
            ),
          ],
        ),
      ),
    );
  }

  bool get _dirty => _current != _baseline;

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

  void _applyProblemText(String next) {
    _swapLock = true;
    setState(() {
      _problem.text = next;
    });
    _swapLock = false;
  }

  Future<void> _autoTranslateProblemIfNeeded() async {
    final text = _problem.text.trim();
    if (text.isEmpty || _translating) return;
    if (!MessageTranslateService.prefersRussian(text)) return;
    setState(() => _translating = true);
    try {
      final appliance = [
        widget.applianceType.trim(),
        widget.applianceBrand.trim(),
      ].where((s) => s.isNotEmpty).join(' ');
      final translated = await MessageTranslateService.toRussianJob(
        text,
        appliance: appliance,
      );
      if (!mounted) return;
      final out = translated.trim();
      if (out.isEmpty || out == text) return;
      // Применяем автоперевод, если пользователь ещё не менял текст вручную.
      if (_problem.text.trim() == text) {
        _baselineProblem = out;
        _applyProblemText(out);
        widget.onAutoTranslatedProblem?.call(out);
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  InputDecoration _field({
    String? label,
    String? hint,
    Color? fillColor,
    Color? borderColor,
  }) {
    final sideColor = borderColor ?? AppColors.border;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: fillColor ?? AppColors.card,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sideColor, width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sideColor.withValues(alpha: 0.65), width: 1.4),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sideColor, width: 2.0),
      ),
    );
  }

  TextStyle get _sectionStyle => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w800,
    color: AppColors.inkMuted,
  );

  Widget _textPane({
    required Color tint,
    required Color fieldFill,
    required Color accent,
    required TextEditingController controller,
    required String hint,
  }) {
    return ColoredBox(
      color: tint,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          children: [
            if (_translating && identical(controller, _problem))
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Expanded(
              child: TextField(
                key: ValueKey(
                  'pane_${_selectedRecallIndex}_${identical(controller, _activeProblemController) ? 'p' : 's'}',
                ),
                controller: controller,
                onChanged: (_) {
                  if (!_swapLock) {
                    setState(() {});
                  }
                },
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: _field(
                  hint: hint,
                  fillColor: fieldFill,
                  borderColor: accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSheet(
    String title,
    Widget Function(BuildContext sheetContext, VoidCallback refresh) body, {
    String Function()? titleBuilder,
  }) async {
    FocusScope.of(context).unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
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

            final currentTitle = titleBuilder != null ? titleBuilder() : title;
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
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
                                currentTitle,
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
    if (_trackingDrafts.isEmpty) {
      _trackingDrafts.add(_TrackingOrderDraft());
    }
    _openSheet(
      'Доставка'.tr,
      titleBuilder: () {
        final orders = _currentTrackingOrders;
        if (orders.isEmpty) return 'Доставка'.tr;
        if (orders.length == 1) {
          return trackingPartsFromLabel(orders.first.effectiveCarrier);
        }
        return '${'Заказаны запчасти'.tr} (${orders.length})';
      },
      (sheetContext, refresh) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            for (var i = 0; i < _trackingDrafts.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              _buildTrackingOrderCard(
                index: i,
                draft: _trackingDrafts[i],
                canRemove: _trackingDrafts.length > 1 ||
                    _trackingDrafts[i].toOrder().isNotEmpty,
                onRemove: () {
                  if (_trackingDrafts.length <= 1) {
                    _trackingDrafts[i].part.clear();
                    _trackingDrafts[i].trackingNumber.clear();
                    _trackingDrafts[i].orderId.clear();
                    _trackingDrafts[i].carrier = '';
                    _trackingDrafts[i].status = '';
                  } else {
                    final removed = _trackingDrafts.removeAt(i);
                    removed.dispose();
                  }
                  refresh();
                },
                refresh: refresh,
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: () {
                  _trackingDrafts.add(_TrackingOrderDraft());
                  refresh();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primaryOnCard,
                  side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: Text(
                  context.tr('+ Добавить ещё запчасть', '+ Add another part'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(sheetContext),
                style: FilledButton.styleFrom(
                  backgroundColor: kConfirmGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                icon: const Icon(Icons.check_rounded, size: 22),
                label: Text('Сохранить'.tr),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTrackingOrderCard({
    required int index,
    required _TrackingOrderDraft draft,
    required bool canRemove,
    required VoidCallback onRemove,
    required VoidCallback refresh,
  }) {
    final status = draft.status.trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.local_shipping_outlined,
                size: 18,
                color: AppColors.primaryOnCard,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _trackingDrafts.length > 1
                      ? '${context.tr('Запчасть', 'Part')} #${index + 1}'
                      : 'Поставщик'.tr,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryOnCard,
                  ),
                ),
              ),
              if (status.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: status == 'delivered'
                        ? Colors.green.withValues(alpha: 0.15)
                        : AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    trackingStatusLabel(status),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: status == 'delivered'
                          ? Colors.green.shade800
                          : AppColors.primaryOnCard,
                    ),
                  ),
                ),
              if (canRemove)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Удалить'.tr,
                  onPressed: onRemove,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in _kTrackingSuppliers.entries)
                ChoiceChip(
                  label: Text(entry.value.tr),
                  selected: draft.carrier == entry.key,
                  onSelected: (_) {
                    draft.carrier = draft.carrier == entry.key ? '' : entry.key;
                    refresh();
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: draft.part,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.next,
            onChanged: (_) => refresh(),
            decoration: _field(
              label: 'Какая запчасть'.tr,
              hint: 'Помпа, ТЭН, плата…'.tr,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: draft.trackingNumber,
            textInputAction: TextInputAction.next,
            onChanged: (_) => refresh(),
            decoration: _field(label: 'Трек-номер'.tr),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: draft.orderId,
            textInputAction: TextInputAction.done,
            onChanged: (_) => refresh(),
            decoration: _field(
              label: 'Номер заказа'.tr,
              hint: '123-1234567-1234567',
            ),
          ),
        ],
      ),
    );
  }

  void _openDiagnostics() {
    DiagnosticsScreen.showForJob(
      context,
      applianceType: widget.applianceType,
      brand: widget.applianceBrand,
      description: _problem.text,
      initialKind: 'test_modes',
    );
  }

  Widget _visitTile({
    required IconData icon,
    required String caption,
    required String value,
    required VoidCallback onTap,
    bool highlightCaption = false,
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 26, color: AppColors.primary),
              ),
              const SizedBox(height: 8),
              Text(
                caption,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.15,
                  fontWeight: FontWeight.bold,
                  color: highlightCaption
                      ? AppColors.primaryOnCard
                      : AppColors.inkMuted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                empty ? '—' : value,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: empty ? Colors.grey : AppColors.ink,
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
    final orders = _currentTrackingOrders;
    final hasTracking = orders.isNotEmpty;
    String tracking = '';
    String trackingCaption = 'Доставка'.tr;
    if (orders.length == 1) {
      final first = orders.first;
      final status = first.status.trim().isNotEmpty
          ? first.status.trim()
          : widget.trackingStatus.trim();
      final code = status.isNotEmpty
          ? trackingStatusLabel(status)
          : (first.trackingNumber.isNotEmpty
                ? first.trackingNumber
                : first.orderId);
      tracking = [
        if (first.part.isNotEmpty) first.part,
        if (code.isNotEmpty) code,
      ].join('\n');
      trackingCaption = trackingPartsFromLabel(first.effectiveCarrier);
    } else if (orders.length > 1) {
      trackingCaption = '${'Доставка'.tr} (${orders.length})';
      tracking = [
        for (final o in orders)
          o.part.isNotEmpty
              ? o.part
              : (_kTrackingSuppliers[o.effectiveCarrier] ??
                    (o.trackingNumber.isNotEmpty
                        ? o.trackingNumber
                        : o.orderId)),
      ].where((s) => s.trim().isNotEmpty).join(', ');
    }
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
                    caption: trackingCaption,
                    value: tracking,
                    highlightCaption: hasTracking,
                    onTap: _openTrackingSheet,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _visitTile(
                    icon: Icons.help_outline_rounded,
                    caption: context.tr('Подсказка', 'Diagnostics'),
                    value: widget.applianceBrand.trim().isNotEmpty
                        ? widget.applianceBrand.trim()
                        : trAny(widget.applianceType.trim()),
                    highlightCaption: true,
                    onTap: _openDiagnostics,
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
              actions: [
                TextButton.icon(
                  onPressed: _addNewRecall,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: const Icon(Icons.replay_rounded, size: 19),
                  label: Text(
                    context.tr('+ Повтор', '+ Recall'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.tr('Ошибка и диагностика', 'Diagnostics'),
                  onPressed: _openDiagnostics,
                  icon: const Icon(Icons.help_outline_rounded, size: 26),
                ),
              ],
            ),
            body: Column(
              children: [
                _buildRecallSelectorBar(),
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
                        unselectedLabelColor: AppColors.inkMuted,
                        indicatorColor: accent,
                        indicatorWeight: 3,
                        labelStyle: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                        tabs: [
                          Tab(
                            text: _selectedRecallIndex < 0
                                ? context.tr('Описание', 'Description')
                                : context.tr(
                                    'Описание (повтор)',
                                    'Recall issue',
                                  ),
                          ),
                          Tab(
                            text: _selectedRecallIndex < 0
                                ? 'Отчет'.tr
                                : context.tr('Отчет (повтор)', 'Recall report'),
                          ),
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
                        fieldFill: _problemFieldFill,
                        accent: _problemAccent,
                        controller: _activeProblemController,
                        hint: _selectedRecallIndex < 0
                            ? 'Нажмите, чтобы добавить описание...'.tr
                            : context.tr(
                                'С чем клиент обратился повторно...',
                                'What happened on the recall...',
                              ),
                      ),
                      _textPane(
                        tint: _solutionTint,
                        fieldFill: _solutionFieldFill,
                        accent: _solutionAccent,
                        controller: _activeSolutionController,
                        hint: _selectedRecallIndex < 0
                            ? 'Что сделали, какая деталь, результат...'.tr
                            : context.tr(
                                'Что сделали на повторном выезде...',
                                'What was done on the recall...',
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: Material(
              color: AppColors.card,
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
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFFCC520), width: 2),
          ),
          filled: true,
          fillColor: AppColors.cardMuted,
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
        side: BorderSide(color: AppColors.border),
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
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryOnCard,
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
  int _nameSeq = 0;

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
    final now = DateTime.now();
    _nameSeq += 1;
    setState(() {
      _items.add({
        'url': '',
        'localPath': localPath,
        'name': '${now.microsecondsSinceEpoch}_$_nameSeq.jpg',
        'pendingUpload': true,
        'uploadedAt': now.toIso8601String(),
      });
    });
    _notify();
  }

  void _open(int index) {
    final newestFirst = _items.reversed.toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenGallery(
          images: newestFirst,
          initialIndex: _items.length - 1 - index,
        ),
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
                return _photoCell(_items.length - index);
              },
            ),
    );
  }
}
