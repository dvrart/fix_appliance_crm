import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/error_log_service.dart';
import '../../services/service_guide_service.dart';
import '../../shared/widgets/app_bar_save.dart';
import '../../shared/widgets/appliance_picture.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/dirty_leave_scope.dart';

class DiagnosticsScreen extends StatefulWidget {
  final String initialQuery;
  final String initialAppliance;
  final String initialBrand;
  final String initialKind;

  const DiagnosticsScreen({
    super.key,
    this.initialQuery = '',
    this.initialAppliance = 'all',
    this.initialBrand = 'all',
    this.initialKind = 'all',
  });

  /// Быстрое окно рекомендаций прямо из карточки заявки (по типу техники,
  /// бренду и описанию проблемы заказа).
  static Future<void> showForJob(
    BuildContext context, {
    required String applianceType,
    required String brand,
    String description = '',
    String initialKind = 'test_modes',
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return _JobDiagnosticsSheet(
          applianceType: applianceType,
          brand: brand,
          description: description,
          initialKind: initialKind,
        );
      },
    );
  }

  static String normalizeApplianceKey(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty || s == 'all' || s == 'все' || s == 'техника') return 'all';
    if (s.contains('мороз') && !s.contains('холод')) return 'freezer';
    if (s.contains('freezer') && !s.contains('fridge')) return 'freezer';
    if (s.contains('холод') || s.contains('fridge') || s.contains('refrig')) {
      return 'fridge';
    }
    if (s.contains('посуд') || s.contains('dish')) return 'dishwasher';
    if (s.contains('стир') || s.contains('wash')) return 'washer';
    if (s.contains('суш') || s.contains('dryer')) return 'dryer';
    if (s.contains('индук') || s.contains('вароч') || s.contains('cooktop')) {
      return 'cooktop';
    }
    if (s.contains('микроволн') || s.contains('свч') || s.contains('microwave')) {
      return 'microwave';
    }
    if (s.contains('плит') ||
        s.contains('духов') ||
        s.contains('range') ||
        s.contains('oven') ||
        s.contains('stove')) {
      return 'range';
    }
    for (final a in _DiagnosticsScreenState._appliances) {
      if (a.id == s) return a.id;
    }
    return 'all';
  }

  static String normalizeBrandKey(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty || s == 'all' || s == 'все') return 'all';
    if (s.contains('amana') || s.contains('kenmore')) return 'kenmore';
    if (s.contains('sub-zero') ||
        s.contains('subzero') ||
        s.contains('wolf') ||
        s.contains('miele')) {
      return 'miele';
    }
    if (s.contains('insignia') ||
        s.contains('midea') ||
        s.contains('hisense') ||
        s.contains('danby')) {
      return 'midea';
    }
    if (s.contains('fisher') || s.contains('paykel')) return 'fisher';
    if (s.contains('westinghouse')) return 'frigidaire';
    for (final b in _DiagnosticsScreenState._brands) {
      if (b.id != 'all' && s.contains(b.id)) return b.id;
    }
    return 'all';
  }

  static String normalizeKindKey(String raw) {
    final s = raw.trim().toLowerCase();
    if (s == 'error_codes' ||
        s == 'test_modes' ||
        s == 'field_guide' ||
        s == 'electrical') {
      return s;
    }
    if (s.contains('ошиб') || s.contains('error') || s.contains('code')) {
      return 'error_codes';
    }
    if (s.contains('тест') || s.contains('test')) return 'test_modes';
    if (s.contains('ом') || s.contains('ohm') || s.contains('electr')) {
      return 'electrical';
    }
    return 'all';
  }

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final TextEditingController _searchCtrl;
  late final Stream<List<Map<String, dynamic>>> _stream;
  late String _query;
  late String _selectedAppliance;
  late String _selectedBrand;
  late String _selectedKind;

  static const _kinds = <({
    String id,
    String ru,
    String en,
    IconData icon,
    Color color,
  })>[
    (
      id: 'all',
      ru: 'Все разделы',
      en: 'All sections',
      icon: Icons.apps,
      color: Color(0xFF1565C0),
    ),
    (
      id: 'error_codes',
      ru: 'Коды ошибок',
      en: 'Error codes',
      icon: Icons.error_outline,
      color: Color(0xFFD32F2F),
    ),
    (
      id: 'test_modes',
      ru: 'Тестовый режим',
      en: 'Test mode',
      icon: Icons.tune,
      color: Color(0xFF1976D2),
    ),
    (
      id: 'field_guide',
      ru: 'Диагностика',
      en: 'Diagnostics',
      icon: Icons.build_circle_outlined,
      color: Color(0xFFEF6C00),
    ),
    (
      id: 'electrical',
      ru: 'Омы и датчики',
      en: 'Ohms & specs',
      icon: Icons.electric_meter_outlined,
      color: Color(0xFF00897B),
    ),
  ];

  static const _appliances = <({String id, String ru, String en, String picType})>[
    (id: 'all', ru: 'Вся техника', en: 'All appliances', picType: 'other'),
    (id: 'fridge', ru: 'Холодильник', en: 'Fridge', picType: 'Холодильник'),
    (id: 'freezer', ru: 'Морозильник', en: 'Freezer', picType: 'Морозильник'),
    (id: 'washer', ru: 'Стиральная', en: 'Washer', picType: 'Стиральная машина'),
    (id: 'dryer', ru: 'Сушилка', en: 'Dryer', picType: 'Сушилка'),
    (id: 'dishwasher', ru: 'Посудомойка', en: 'Dishwasher', picType: 'Посудомойка'),
    (id: 'range', ru: 'Плита/Духовка', en: 'Range/Oven', picType: 'Плита/Духовка'),
    (id: 'cooktop', ru: 'Индукция/Панель', en: 'Cooktop', picType: 'Варочная панель'),
    (id: 'microwave', ru: 'Микроволновка', en: 'Microwave', picType: 'Микроволновка'),
    (id: 'other', ru: 'Прочее', en: 'Other', picType: 'Универсальное'),
  ];

  static const _brands = <({String id, String label})>[
    (id: 'all', label: 'Все бренды'),
    (id: 'samsung', label: 'Samsung'),
    (id: 'lg', label: 'LG'),
    (id: 'whirlpool', label: 'Whirlpool'),
    (id: 'maytag', label: 'Maytag'),
    (id: 'kitchenaid', label: 'KitchenAid'),
    (id: 'bosch', label: 'Bosch'),
    (id: 'ge', label: 'GE'),
    (id: 'frigidaire', label: 'Frigidaire'),
    (id: 'electrolux', label: 'Electrolux'),
    (id: 'kenmore', label: 'Kenmore / Amana'),
    (id: 'fisher', label: 'Fisher & Paykel'),
    (id: 'midea', label: 'Midea / Insignia'),
    (id: 'miele', label: 'Miele / Sub-Zero'),
    (id: 'panasonic', label: 'Panasonic'),
  ];

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Ошибка и диагностика');
    _query = widget.initialQuery.trim();
    _selectedAppliance =
        DiagnosticsScreen.normalizeApplianceKey(widget.initialAppliance);
    _selectedBrand = DiagnosticsScreen.normalizeBrandKey(widget.initialBrand);
    _selectedKind = DiagnosticsScreen.normalizeKindKey(widget.initialKind);
    _searchCtrl = TextEditingController(text: _query);
    _stream = ServiceGuideService.streamAll();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  static bool matchesFilter(
    Map<String, dynamic> rec, {
    required String kind,
    required String appliance,
    required String brand,
    required String query,
  }) {
    if (kind != 'all' && rec['kind'] != kind) {
      return false;
    }
    if (appliance != 'all') {
      final app = (rec['appliance'] ?? '').toString();
      if (app != appliance && app != 'all') {
        if (!(appliance == 'freezer' && app == 'fridge') &&
            !(appliance == 'range' && app == 'cooktop') &&
            !(appliance == 'cooktop' && app == 'range')) {
          return false;
        }
      }
    }
    if (brand != 'all') {
      final brandText =
          '${rec['brand'] ?? ''} ${rec['platform'] ?? ''} ${rec['topic'] ?? ''}'
              .toLowerCase();
      final isGeneral = brandText.contains('все бренды') ||
          brandText.contains('general') ||
          (rec['brand'] ?? '').toString().trim().isEmpty;
      final matchAliases = switch (brand) {
        'kenmore' => ['kenmore', 'amana', 'whirlpool'],
        'miele' => ['miele', 'sub-zero', 'subzero', 'wolf'],
        'midea' => ['midea', 'insignia', 'hisense', 'danby'],
        'fisher' => ['fisher', 'paykel', 'dishdrawer'],
        'bosch' => ['bosch', 'thermador', 'gaggenau'],
        'ge' => ['ge', 'profile', 'cafe'],
        _ => [brand],
      };
      final hasBrand = matchAliases.any((alias) => brandText.contains(alias));
      if (!hasBrand && !isGeneral) return false;
    }
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final hay = (rec['search'] ?? '').toString().toLowerCase();
      final compactHay = hay.replaceAll(RegExp(r'[\s\-]'), '');
      final compactQ = q.replaceAll(RegExp(r'[\s\-]'), '');
      if (compactHay.contains(compactQ) || hay.contains(q)) return true;
      final words = q
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.every((w) => hay.contains(w))) return true;
      return false;
    }
    return true;
  }

  bool _matchesRecord(Map<String, dynamic> rec) => matchesFilter(
        rec,
        kind: _selectedKind,
        appliance: _selectedAppliance,
        brand: _selectedBrand,
        query: _query,
      );

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _DiagnosticCardEditorPage(
          existing: existing,
          defaultAppliance:
              _selectedAppliance == 'all' ? 'fridge' : _selectedAppliance,
          defaultKind:
              _selectedKind == 'all' ? 'error_codes' : _selectedKind,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          context.tr('Ошибка и диагностика', 'Errors & diagnostics'),
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
        ),
        actions: [
          IconButton(
            tooltip: context.tr('Добавить карточку', 'Add card'),
            icon: const Icon(Icons.add_circle_outline, size: 26),
            onPressed: () => _openEditor(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTopFilters(context),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _stream,
              builder: (context, snapshot) {
                final allRecords = snapshot.data ?? const [];
                if (allRecords.isEmpty &&
                    snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  );
                }
                final filtered =
                    allRecords.where(_matchesRecord).toList();
                if (filtered.isEmpty) {
                  return _buildEmptyState(context);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 32),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final rec = filtered[index];
                    return _DiagnosticRecordCard(
                      key: ValueKey<String>(
                        '${rec['id']}_${_selectedKind}_${_selectedAppliance}_$_selectedBrand',
                      ),
                      record: rec,
                      initiallyExpanded: filtered.length <= 2 ||
                          (_query.trim().isNotEmpty && index == 0),
                      onEdit: () => _openEditor(rec),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopFilters(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: context.tr(
                  'Код ошибки (F21, 3E, E15, d80), бренд или симптом…',
                  'Error code (F21, 3E, E15, d80), brand, or symptom…',
                ),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.cardMuted,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Разделы: Все / Коды ошибок / Тестовый режим / Диагностика / Омы
          SizedBox(
            height: 40,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: _kinds.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = _kinds[index];
                final selected = _selectedKind == item.id;
                return ChoiceChip(
                  showCheckmark: false,
                  avatar: Icon(
                    item.icon,
                    size: 17,
                    color: selected ? Colors.white : item.color,
                  ),
                  label: Text(
                    context.tr(item.ru, item.en),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: selected ? Colors.white : AppColors.ink,
                    ),
                  ),
                  selected: selected,
                  selectedColor: item.color,
                  backgroundColor: AppColors.cardMuted,
                  side: BorderSide.none,
                  onSelected: (_) {
                    AppFeedback.pleasant();
                    setState(() => _selectedKind = item.id);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Виды бытовой техники
          SizedBox(
            height: 44,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: _appliances.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final app = _appliances[index];
                final selected = _selectedAppliance == app.id;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    AppFeedback.pleasant();
                    setState(() => _selectedAppliance = app.id);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primary
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? AppColors.accent
                            : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (app.id == 'all')
                          Icon(
                            Icons.kitchen,
                            size: 18,
                            color: selected
                                ? AppColors.accent
                                : AppColors.primary,
                          )
                        else
                          AppliancePicture(
                            type: app.picType,
                            size: 24,
                            onDark: selected,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          context.tr(app.ru, app.en),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: selected
                                ? Colors.white
                                : const Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Бренды
          SizedBox(
            height: 36,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              scrollDirection: Axis.horizontal,
              itemCount: _brands.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final b = _brands[index];
                final selected = _selectedBrand == b.id;
                return GestureDetector(
                  onTap: () {
                    AppFeedback.pleasant();
                    setState(() => _selectedBrand = b.id);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 4,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.accent
                          : const Color(0xFFEFF3F8),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      b.id == 'all'
                          ? context.tr('Все бренды', 'All brands')
                          : b.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: selected
                            ? const Color(0xFF1A1A1A)
                            : const Color(0xFF475569),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.manage_search_rounded,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              context.tr(
                'По этому фильтру карточек не найдено',
                'No diagnostic cards match this filter',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.inkMuted,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                _searchCtrl.clear();
                setState(() {
                  _query = '';
                  _selectedAppliance = 'all';
                  _selectedBrand = 'all';
                  _selectedKind = 'all';
                });
              },
              icon: const Icon(Icons.refresh),
              label: Text(context.tr('Сбросить фильтры', 'Reset filters')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Быстрое окно рекомендаций прямо в карточке заявки: сразу показывает
/// тестовый режим, коды ошибок и диагностику для техники и бренда заказа.
class _JobDiagnosticsSheet extends StatefulWidget {
  final String applianceType;
  final String brand;
  final String description;
  final String initialKind;

  const _JobDiagnosticsSheet({
    required this.applianceType,
    required this.brand,
    required this.description,
    required this.initialKind,
  });

  @override
  State<_JobDiagnosticsSheet> createState() => _JobDiagnosticsSheetState();
}

class _JobDiagnosticsSheetState extends State<_JobDiagnosticsSheet> {
  late final Stream<List<Map<String, dynamic>>> _stream;
  late String _kind;
  late String _applianceKey;
  late String _brandKey;

  @override
  void initState() {
    super.initState();
    _stream = ServiceGuideService.streamAll();
    _kind = DiagnosticsScreen.normalizeKindKey(widget.initialKind);
    if (_kind == 'all') _kind = 'test_modes';
    _applianceKey =
        DiagnosticsScreen.normalizeApplianceKey(widget.applianceType);
    _brandKey = DiagnosticsScreen.normalizeBrandKey(widget.brand);
  }

  List<Map<String, dynamic>> _pickRecommended(
    List<Map<String, dynamic>> allRecords,
  ) {
    // 1. Точное совпадение по разделу + технике + бренду
    var exact = allRecords
        .where(
          (r) => _DiagnosticsScreenState.matchesFilter(
            r,
            kind: _kind,
            appliance: _applianceKey,
            brand: _brandKey,
            query: '',
          ),
        )
        .toList();

    // Если выбраны «Коды ошибок», но по точному бренду есть и общая диагностика —
    // добавим её следом, чтобы мастер сразу видел и коды, и пошаговую проверку.
    if (_kind == 'error_codes') {
      final guides = allRecords.where(
        (r) => _DiagnosticsScreenState.matchesFilter(
          r,
          kind: 'field_guide',
          appliance: _applianceKey,
          brand: _brandKey,
          query: '',
        ),
      );
      for (final g in guides) {
        if (!exact.any((e) => e['id'] == g['id'])) {
          exact.add(g);
        }
      }
    }

    // Если бренд в заказе не указан или редкий — показываем все карточки для этой техники
    if (exact.isEmpty && _brandKey != 'all') {
      exact = allRecords
          .where(
            (r) => _DiagnosticsScreenState.matchesFilter(
              r,
              kind: _kind,
              appliance: _applianceKey,
              brand: 'all',
              query: '',
            ),
          )
          .toList();
    }

    // Если и тип техники не распознан — показываем все карточки выбранного раздела
    if (exact.isEmpty) {
      exact = allRecords
          .where((r) => _kind == 'all' || r['kind'] == _kind)
          .toList();
    }

    // Поднимаем наверх карточки, где бренд совпадает напрямую (а не «Все бренды»)
    if (_brandKey != 'all') {
      exact.sort((a, b) {
        final aBrand = (a['brand'] ?? '').toString().toLowerCase();
        final bBrand = (b['brand'] ?? '').toString().toLowerCase();
        final aDirect = aBrand.contains(_brandKey) ? 0 : 1;
        final bDirect = bBrand.contains(_brandKey) ? 0 : 1;
        if (aDirect != bDirect) return aDirect.compareTo(bDirect);
        return 0;
      });
    }

    return exact;
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    final applianceLabel = widget.applianceType.trim().isEmpty
        ? context.tr('Техника', 'Appliance')
        : trAny(widget.applianceType.trim());
    final brandLabel = widget.brand.trim();
    final subtitle = [
      applianceLabel,
      if (brandLabel.isNotEmpty) brandLabel,
    ].join(' · ');

    const tabs = <({
      String id,
      String ru,
      String en,
      IconData icon,
      Color color,
    })>[
      (
        id: 'test_modes',
        ru: 'Тестовый режим',
        en: 'Test mode',
        icon: Icons.tune,
        color: Color(0xFF1976D2),
      ),
      (
        id: 'error_codes',
        ru: 'Коды ошибок',
        en: 'Error codes',
        icon: Icons.error_outline,
        color: Color(0xFFD32F2F),
      ),
      (
        id: 'field_guide',
        ru: 'Диагностика',
        en: 'Diagnostics',
        icon: Icons.build_circle_outlined,
        color: Color(0xFFEF6C00),
      ),
      (
        id: 'electrical',
        ru: 'Омы и датчики',
        en: 'Ohms & specs',
        icon: Icons.electric_meter_outlined,
        color: Color(0xFF00897B),
      ),
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppliancePicture(
                        type: widget.applianceType,
                        size: 38,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr(
                                'Подсказка по заказу',
                                'Job diagnostic guide',
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.inkMuted,
                              ),
                            ),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: AppColors.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          final nav = Navigator.of(context);
                          nav.pop();
                          nav.push(
                            MaterialPageRoute<void>(
                              builder: (_) => DiagnosticsScreen(
                                initialAppliance: _applianceKey,
                                initialBrand: _brandKey,
                                initialKind: _kind,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.open_in_new, size: 17),
                        label: Text(context.tr('Вся база', 'Full guide')),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: tabs.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final t = tabs[index];
                        final selected = _kind == t.id;
                        return ChoiceChip(
                          showCheckmark: false,
                          avatar: Icon(
                            t.icon,
                            size: 16,
                            color: selected ? Colors.white : t.color,
                          ),
                          label: Text(
                            context.tr(t.ru, t.en),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: selected
                                  ? Colors.white
                                  : AppColors.ink,
                            ),
                          ),
                          selected: selected,
                          selectedColor: t.color,
                          backgroundColor: AppColors.cardMuted,
                          side: BorderSide.none,
                          onSelected: (_) {
                            AppFeedback.pleasant();
                            setState(() => _kind = t.id);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _stream,
                builder: (context, snapshot) {
                  final allRecords = snapshot.data ?? const [];
                  if (allRecords.isEmpty &&
                      snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                        ),
                      ),
                    );
                  }
                  final items = _pickRecommended(allRecords);
                  return ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final rec = items[index];
                      return _DiagnosticRecordCard(
                        key: ValueKey<String>(
                          'sheet_${rec['id']}_${_kind}_$index',
                        ),
                        record: rec,
                        initiallyExpanded: index == 0,
                        onEdit: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => _DiagnosticCardEditorPage(
                                existing: rec,
                                defaultAppliance: _applianceKey == 'all'
                                    ? 'fridge'
                                    : _applianceKey,
                                defaultKind: _kind,
                              ),
                            ),
                          );
                        },
                      );
                    },
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

/// Карточка справочника без `ExpansionTile`/`PageStorageKey` и без
/// `SelectableText`: не пишет `bool` в `PageStorage` (из-за чего
/// `ScrollPosition.restoreScrollOffset` падал с `bool is not a subtype of
/// double?`) и не создаёт внутренний `EditableText`.
class _DiagnosticRecordCard extends StatefulWidget {
  final Map<String, dynamic> record;
  final bool initiallyExpanded;
  final VoidCallback onEdit;

  const _DiagnosticRecordCard({
    super.key,
    required this.record,
    required this.initiallyExpanded,
    required this.onEdit,
  });

  @override
  State<_DiagnosticRecordCard> createState() => _DiagnosticRecordCardState();
}

class _DiagnosticRecordCardState extends State<_DiagnosticRecordCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant _DiagnosticRecordCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record['id'] != widget.record['id'] ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  static ({String labelRu, String labelEn, Color color, IconData icon})
      _kindMeta(String kind) {
    switch (kind) {
      case 'error_codes':
        return (
          labelRu: 'Коды ошибок',
          labelEn: 'Error codes',
          color: const Color(0xFFD32F2F),
          icon: Icons.error_outline,
        );
      case 'test_modes':
        return (
          labelRu: 'Тестовый режим',
          labelEn: 'Test mode',
          color: const Color(0xFF1976D2),
          icon: Icons.tune,
        );
      case 'electrical':
        return (
          labelRu: 'Омы и датчики',
          labelEn: 'Ohms & specs',
          color: const Color(0xFF00897B),
          icon: Icons.electric_meter_outlined,
        );
      default:
        return (
          labelRu: 'Диагностика',
          labelEn: 'Diagnostics',
          color: const Color(0xFFEF6C00),
          icon: Icons.build_circle_outlined,
        );
    }
  }

  static String _applianceTypeForPicture(String appliance, String category) {
    switch (appliance) {
      case 'fridge':
        return 'Холодильник';
      case 'freezer':
        return 'Морозильник';
      case 'washer':
        return 'Стиральная машина';
      case 'dryer':
        return 'Сушилка';
      case 'dishwasher':
        return 'Посудомойка';
      case 'range':
        return 'Плита/Духовка';
      case 'cooktop':
        return 'Варочная панель';
      case 'microwave':
        return 'Микроволновка';
      default:
        return category.isNotEmpty ? category : 'Универсальное';
    }
  }

  String _fullCopyText() {
    final record = widget.record;
    final buf = StringBuffer();
    final topic = (record['topic'] ?? '').toString().trim();
    final brand = (record['brand'] ?? '').toString().trim();
    final platform = (record['platform'] ?? '').toString().trim();
    final codes = (record['codes'] ?? '').toString().trim();
    final entry = (record['entry'] ?? '').toString().trim();
    final procedure = (record['procedure'] ?? '').toString().trim();
    final tests = (record['tests'] ?? '').toString().trim();
    final specs = (record['specs'] ?? '').toString().trim();
    final fix = (record['fix'] ?? '').toString().trim();
    final exit = (record['exit'] ?? '').toString().trim();
    final notes = (record['notes'] ?? '').toString().trim();

    buf.writeln(topic);
    if (brand.isNotEmpty) buf.writeln('Бренд: $brand');
    if (platform.isNotEmpty) buf.writeln('Модели: $platform');
    if (codes.isNotEmpty) buf.writeln('Коды: $codes');
    if (entry.isNotEmpty) buf.writeln('\n$entry');
    if (procedure.isNotEmpty) buf.writeln('\nПроверка / шаги:\n$procedure');
    if (tests.isNotEmpty) buf.writeln('\nТесты и замеры:\n$tests');
    if (specs.isNotEmpty) buf.writeln('\nНормы (Омы/Ток):\n$specs');
    if (fix.isNotEmpty) buf.writeln('\nРешение:\n$fix');
    if (exit.isNotEmpty) buf.writeln('\nВыход из теста: $exit');
    if (notes.isNotEmpty) buf.writeln('\nВажно:\n$notes');
    return buf.toString().trim();
  }

  void _toggleExpanded() {
    AppFeedback.pleasant();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final kind = (record['kind'] ?? 'field_guide').toString();
    final meta = _kindMeta(kind);
    final topic = (record['topic'] ?? '').toString();
    final brand = (record['brand'] ?? '').toString();
    final platform = (record['platform'] ?? '').toString();
    final category = (record['category'] ?? '').toString();
    final appliance = (record['appliance'] ?? '').toString();
    final codes = (record['codes'] ?? '').toString();
    final entry = (record['entry'] ?? '').toString();
    final procedure = (record['procedure'] ?? '').toString();
    final tests = (record['tests'] ?? '').toString();
    final specs = (record['specs'] ?? '').toString();
    final fix = (record['fix'] ?? '').toString();
    final exit = (record['exit'] ?? '').toString();
    final notes = (record['notes'] ?? '').toString();

    final entryTitle = switch (kind) {
      'test_modes' => context.tr(
          'Как войти в тестовый режим',
          'How to enter test mode',
        ),
      'error_codes' => context.tr(
          'Расшифровка кодов ошибок',
          'Error code meanings',
        ),
      'electrical' => context.tr(
          'Назначение и правило замера',
          'Overview & measurement rule',
        ),
      _ => context.tr('Причины неисправности', 'Root causes'),
    };

    return Material(
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: meta.color.withValues(alpha: _expanded ? 0.45 : 0.22),
          width: _expanded ? 1.5 : 1.1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppliancePicture(
                    type: _applianceTypeForPicture(appliance, category),
                    size: 46,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: meta.color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(meta.icon, size: 13, color: meta.color),
                                  const SizedBox(width: 4),
                                  Text(
                                    context.tr(meta.labelRu, meta.labelEn),
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w800,
                                      color: meta.color,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (brand.isNotEmpty)
                              Text(
                                brand,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.inkMuted,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          topic,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.ink,
                            height: 1.25,
                          ),
                        ),
                        if (platform.isNotEmpty && platform != brand) ...[
                          const SizedBox(height: 3),
                          Text(
                            platform,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                        if (codes.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.cardMuted,
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: AppColors.border),
                            ),
                            child: Text(
                              codes,
                              maxLines: _expanded ? 4 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 26,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 14),
                  if (entry.isNotEmpty)
                    _buildBlock(
                      context,
                      title: entryTitle,
                      body: entry,
                      bgColor: meta.color.withValues(alpha: 0.07),
                      borderColor: meta.color.withValues(alpha: 0.25),
                      titleColor: meta.color,
                      icon: meta.icon,
                    ),
                  if (procedure.isNotEmpty)
                    _buildBlock(
                      context,
                      title: kind == 'test_modes'
                          ? context.tr(
                              'Пошаговая работа в тесте',
                              'Test navigation steps',
                            )
                          : context.tr(
                              'Пошаговая диагностика',
                              'Step-by-step diagnostics',
                            ),
                      body: procedure,
                      bgColor: const Color(0xFFF8FAFC),
                      borderColor: const Color(0xFFE2E8F0),
                      titleColor: const Color(0xFF1E293B),
                      icon: Icons.format_list_numbered,
                    ),
                  if (tests.isNotEmpty)
                    _buildBlock(
                      context,
                      title: kind == 'test_modes'
                          ? context.tr('Список тестов по шагам', 'Test steps')
                          : context.tr(
                              'Замеры мультиметром (Омы / В / А)',
                              'Multimeter specs & checks',
                            ),
                      body: tests,
                      bgColor: const Color(0xFFF0FDF4),
                      borderColor: const Color(0xFFBBF7D0),
                      titleColor: const Color(0xFF166534),
                      icon: Icons.electric_meter_outlined,
                    ),
                  if (specs.isNotEmpty)
                    _buildBlock(
                      context,
                      title: context.tr(
                        'Нормы сопротивлений и питания',
                        'Resistance & power specs',
                      ),
                      body: specs,
                      bgColor: const Color(0xFFF0FDFA),
                      borderColor: const Color(0xFF99F6E4),
                      titleColor: const Color(0xFF0F766E),
                      icon: Icons.speed,
                    ),
                  if (fix.isNotEmpty)
                    _buildBlock(
                      context,
                      title: context.tr(
                        'Решение / Что менять',
                        'Fix / What to replace',
                      ),
                      body: fix,
                      bgColor: const Color(0xFFEFF6FF),
                      borderColor: const Color(0xFFBFDBFE),
                      titleColor: const Color(0xFF1D4ED8),
                      icon: Icons.handyman_outlined,
                    ),
                  if (exit.isNotEmpty)
                    _buildBlock(
                      context,
                      title: context.tr(
                        'Выход из тестового режима',
                        'How to exit test mode',
                      ),
                      body: exit,
                      bgColor: const Color(0xFFF8FAFC),
                      borderColor: const Color(0xFFE2E8F0),
                      titleColor: const Color(0xFF334155),
                      icon: Icons.exit_to_app,
                    ),
                  if (notes.isNotEmpty)
                    _buildBlock(
                      context,
                      title: context.tr(
                        'Важный нюанс мастера',
                        'Technician tip',
                      ),
                      body: notes,
                      bgColor: const Color(0xFFFFFBEB),
                      borderColor: const Color(0xFFFDE68A),
                      titleColor: const Color(0xFFB45309),
                      icon: Icons.lightbulb_outline,
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _fullCopyText()),
                          );
                          AppFeedback.pleasant();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text(context.tr('Скопировано', 'Copied')),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 17),
                        label: Text(context.tr('Скопировать', 'Copy')),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: widget.onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        label: Text(context.tr('Изменить', 'Edit')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBlock(
    BuildContext context, {
    required String title,
    required String body,
    required Color bgColor,
    required Color borderColor,
    required Color titleColor,
    required IconData icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () => AppFeedback.copy(context, '$title:\n$body'),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: titleColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: TextStyle(
                  fontSize: 13.8,
                  height: 1.38,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticCardEditorPage extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String defaultAppliance;
  final String defaultKind;

  const _DiagnosticCardEditorPage({
    this.existing,
    required this.defaultAppliance,
    required this.defaultKind,
  });

  @override
  State<_DiagnosticCardEditorPage> createState() =>
      _DiagnosticCardEditorPageState();
}

class _DiagnosticCardEditorPageState extends State<_DiagnosticCardEditorPage> {
  late String _kind;
  late String _appliance;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _platformCtrl;
  late final TextEditingController _codesCtrl;
  late final TextEditingController _topicCtrl;
  late final TextEditingController _entryCtrl;
  late final TextEditingController _procedureCtrl;
  late final TextEditingController _testsCtrl;
  late final TextEditingController _specsCtrl;
  late final TextEditingController _fixCtrl;
  late final TextEditingController _exitCtrl;
  late final TextEditingController _notesCtrl;

  late String _initialSignature;
  bool _saving = false;

  static const _applianceLabels = <String, String>{
    'fridge': 'Холодильники',
    'freezer': 'Морозильники',
    'washer': 'Стиральные машины',
    'dryer': 'Сушилки',
    'dishwasher': 'Посудомойки',
    'range': 'Плиты и духовки',
    'cooktop': 'Варочные панели и индукция',
    'microwave': 'Микроволновки',
    'other': 'Вытяжки, измельчители, винные шкафы',
    'all': 'Омы и датчики (Все)',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = (e?['kind'] as String?) ?? widget.defaultKind;
    _appliance = (e?['appliance'] as String?) ?? widget.defaultAppliance;
    if (!_applianceLabels.containsKey(_appliance)) {
      _appliance = 'fridge';
    }
    _brandCtrl = TextEditingController(text: (e?['brand'] ?? '').toString());
    _platformCtrl =
        TextEditingController(text: (e?['platform'] ?? '').toString());
    _codesCtrl = TextEditingController(text: (e?['codes'] ?? '').toString());
    _topicCtrl = TextEditingController(text: (e?['topic'] ?? '').toString());
    _entryCtrl = TextEditingController(text: (e?['entry'] ?? '').toString());
    _procedureCtrl =
        TextEditingController(text: (e?['procedure'] ?? '').toString());
    _testsCtrl = TextEditingController(text: (e?['tests'] ?? '').toString());
    _specsCtrl = TextEditingController(text: (e?['specs'] ?? '').toString());
    _fixCtrl = TextEditingController(text: (e?['fix'] ?? '').toString());
    _exitCtrl = TextEditingController(text: (e?['exit'] ?? '').toString());
    _notesCtrl = TextEditingController(text: (e?['notes'] ?? '').toString());
    _initialSignature = _signature();
    for (final c in _controllers) {
      c.addListener(_onChanged);
    }
  }

  List<TextEditingController> get _controllers => [
        _brandCtrl,
        _platformCtrl,
        _codesCtrl,
        _topicCtrl,
        _entryCtrl,
        _procedureCtrl,
        _testsCtrl,
        _specsCtrl,
        _fixCtrl,
        _exitCtrl,
        _notesCtrl,
      ];

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _signature() {
    return [
      _kind,
      _appliance,
      for (final c in _controllers) c.text.trim(),
    ].join('\u0001');
  }

  bool get _dirty => !_saving && _signature() != _initialSignature;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> _save() async {
    final topic = _topicCtrl.text.trim();
    if (topic.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Укажите заголовок карточки', 'Enter a card title'),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
    setState(() => _saving = true);
    try {
      await ServiceGuideService.saveRecord({
        if (widget.existing?['id'] != null) 'id': widget.existing!['id'],
        'kind': _kind,
        'appliance': _appliance,
        'category': _applianceLabels[_appliance] ?? 'Техника',
        'brand': _brandCtrl.text.trim(),
        'platform': _platformCtrl.text.trim(),
        'codes': _codesCtrl.text.trim(),
        'topic': topic,
        'entry': _entryCtrl.text.trim(),
        'procedure': _procedureCtrl.text.trim(),
        'tests': _testsCtrl.text.trim(),
        'specs': _specsCtrl.text.trim(),
        'fix': _fixCtrl.text.trim(),
        'exit': _exitCtrl.text.trim(),
        'notes': _notesCtrl.text.trim(),
      });
      if (!mounted) return true;
      _initialSignature = _signature();
      setState(() => _saving = false);
      AppCommands.reactHappy();
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

  Future<void> _delete() async {
    final id = (widget.existing?['id'] ?? '').toString();
    if (id.isEmpty) return;
    final ok = await showConfirmCancelSheet(
      context,
      title: context.tr('Удалить карточку?', 'Delete this card?'),
      message: _topicCtrl.text.trim(),
      confirmLabel: context.tr('Удалить', 'Delete'),
    );
    if (!ok || !mounted) return;
    await ServiceGuideService.deleteRecord(id);
    if (!mounted) return;
    AppCommands.reactAngry();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _save,
      child: Scaffold(
        backgroundColor: AppColors.surface,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          title: Text(
            isEdit
                ? context.tr('Редактировать карточку', 'Edit card')
                : context.tr('Новая карточка диагностики', 'New diagnostic card'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            if (isEdit)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: _delete,
              ),
            if (_dirty)
              AppBarSaveButton(
                dirty: _dirty,
                saving: _saving,
                onPressed: () async {
                  final nav = Navigator.of(context);
                  if (await _save() && mounted) {
                    nav.pop();
                  }
                },
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
          children: [
            _buildDropdownRow(
              label: context.tr('Раздел', 'Section'),
              value: _kind,
              items: {
                'error_codes': context.tr('Коды ошибок', 'Error codes'),
                'test_modes': context.tr('Тестовый режим', 'Test mode'),
                'field_guide': context.tr(
                  'Диагностика и ремонт',
                  'Diagnostics & repair',
                ),
                'electrical': context.tr('Омы и датчики', 'Ohms & specs'),
              },
              onChanged: (v) => setState(() => _kind = v),
            ),
            const SizedBox(height: 12),
            _buildDropdownRow(
              label: context.tr('Вид техники', 'Appliance'),
              value: _appliance,
              items: _applianceLabels,
              onChanged: (v) => setState(() => _appliance = v),
            ),
            const SizedBox(height: 12),
            _field(
              controller: _topicCtrl,
              label: context.tr('Заголовок карточки *', 'Card title *'),
              hint: 'Например: Коды ошибок стиралок Samsung / Вход в тест LG',
            ),
            const SizedBox(height: 12),
            _field(
              controller: _brandCtrl,
              label: context.tr('Бренд', 'Brand'),
              hint: 'Samsung, LG, Whirlpool, Bosch, GE, Frigidaire…',
            ),
            const SizedBox(height: 12),
            _field(
              controller: _platformCtrl,
              label: context.tr('Серия / Модели', 'Series / Platform'),
              hint: 'French Door, VMW Top-Load, Serie 500/800…',
            ),
            const SizedBox(height: 12),
            _field(
              controller: _codesCtrl,
              label: context.tr('Коды ошибок (через запятую)', 'Error codes'),
              hint: 'F21, 3E, LE, E15, E09, d80…',
            ),
            const SizedBox(height: 12),
            _field(
              controller: _entryCtrl,
              label: context.tr(
                'Вход в тестовый режим / Расшифровка кодов / Причина',
                'Test mode entry / Error codes / Root cause',
              ),
              maxLines: 5,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _procedureCtrl,
              label: context.tr(
                'Пошаговая диагностика / Шаги в тесте',
                'Step-by-step diagnostics / Procedure',
              ),
              maxLines: 5,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _testsCtrl,
              label: context.tr(
                'Замеры мультиметром (Омы / В / А) и номера тестов',
                'Multimeter checks & test numbers',
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _specsCtrl,
              label: context.tr(
                'Нормы сопротивления и тока',
                'Specs (Ohms / Amps)',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _fixCtrl,
              label: context.tr(
                'Решение / Что менять',
                'Fix / What to replace',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _exitCtrl,
              label: context.tr(
                'Выход из тестового режима',
                'How to exit test mode',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _notesCtrl,
              label: context.tr(
                'Важные нюансы мастера (лайфхак)',
                'Technician notes',
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownRow({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.inkMuted,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in items.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: value == entry.key,
                  onSelected: (_) => onChanged(entry.key),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: maxLines > 1,
        filled: true,
        fillColor: AppColors.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
