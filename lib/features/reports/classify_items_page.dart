import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';

/// Разбор старых счетов: где работа, а где запчасть.
///
/// До появления переключателя в счёте позиции метки не имели, и отчёт делил
/// их на глаз — по складу и себестоимости. «Control board for a washing
/// machine» за $300 уезжал в работу, и прибыль выглядела больше, чем была.
/// Здесь все такие позиции собраны в один список: подсказка проставлена по
/// названию, FIX правит только то, что подсказано неверно, и жмёт «Сохранить».
class ClassifyItemsPage extends StatefulWidget {
  const ClassifyItemsPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ClassifyItemsPage()),
    );
  }

  @override
  State<ClassifyItemsPage> createState() => _ClassifyItemsPageState();
}

/// Слова, по которым позицию видно без человека. Запчасть проверяем первой:
/// «control board replacement» — это всё-таки плата.
const _partWords = [
  'board', 'pump', 'valve', 'motor', 'belt', 'element', 'thermostat',
  'sensor', 'switch', 'hose', 'filter', 'gasket', 'bearing', 'seal',
  'compressor', 'heater', 'dispenser', 'latch', 'handle', 'drum', 'timer',
  'module', 'igniter', 'thermistor', 'capacitor', 'relay', 'damper', 'rack',
  'shelf', 'knob', 'coil', 'fan blade', 'door bin', 'inverter', 'pcb',
  'плат', 'насос', 'клапан', 'мотор', 'ремень', 'тэн', 'термостат', 'датчик',
  'шланг', 'фильтр', 'подшипник', 'сальник', 'помп', 'запчаст',
];

const _serviceWords = [
  'service call', 'diagnostic', 'labour', 'labor', 'repair', 'installation',
  'install', 'cleaning', 'trip charge', 'visit', 'warranty', 'estimate fee',
  'работ', 'диагност', 'ремонт', 'выезд', 'установк', 'чистк', 'услуг',
];

/// Подсказка по названию позиции. Это только предложение — решает человек.
bool guessIsPart(Map item) {
  final name = (item['name'] ?? '').toString().toLowerCase();
  for (final word in _partWords) {
    if (name.contains(word)) return true;
  }
  for (final word in _serviceWords) {
    if (name.contains(word)) return false;
  }
  return Job.isPartItem(item);
}

class _Row {
  final String jobId;
  final String clientName;
  final int docIndex;
  final String docNumber;
  final DateTime? date;
  final int itemIndex;
  final String name;
  final double qty;
  final double price;
  final bool fromWarehouse;
  bool isPart;
  final TextEditingController cost;

  _Row({
    required this.jobId,
    required this.clientName,
    required this.docIndex,
    required this.docNumber,
    required this.date,
    required this.itemIndex,
    required this.name,
    required this.qty,
    required this.price,
    required this.fromWarehouse,
    required this.isPart,
    required this.cost,
  });

  double get total => qty * price;
}

class _ClassifyItemsPageState extends State<ClassifyItemsPage> {
  bool _loading = true;
  bool _saving = false;
  String _error = '';
  List<Job> _jobs = const [];
  List<_Row> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.cost.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final jobs = await JobService.loadAllOnce();
      final rows = <_Row>[];
      for (final job in jobs) {
        if (job.isDeleted) continue;
        for (var d = 0; d < job.documents.length; d++) {
          final doc = job.documents[d];
          if (!Job.isInvoice(doc) || Job.isDocumentTrashed(doc)) continue;
          final items = doc['items'];
          if (items is! List) continue;
          for (var i = 0; i < items.length; i++) {
            final item = items[i];
            if (item is! Map) continue;
            if (Job.isItemClassified(item)) continue;
            rows.add(
              _Row(
                jobId: job.id,
                clientName: job.clientName,
                docIndex: d,
                docNumber: (doc['number'] ?? '').toString(),
                date: _docDate(doc),
                itemIndex: i,
                name: (item['name'] ?? 'Item').toString(),
                qty: _toDouble(item['qty'], fallback: 1),
                price: _toDouble(item['price']),
                fromWarehouse:
                    (item['warehouseItemId'] ?? '').toString().isNotEmpty,
                isPart: guessIsPart(item),
                cost: TextEditingController(
                  text: item['costPrice'] == null
                      ? ''
                      : _toDouble(item['costPrice']).toStringAsFixed(2),
                ),
              ),
            );
          }
        }
      }
      rows.sort((a, b) {
        final ad = a.date ?? DateTime(1970);
        final bd = b.date ?? DateTime(1970);
        return bd.compareTo(ad);
      });
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  static double _toDouble(dynamic value, {double fallback = 0}) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '.')) ?? fallback;
  }

  static DateTime? _docDate(Map doc) {
    final raw = doc['createdAt'] ?? doc['issuedAt'] ?? doc['date'];
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    try {
      final dynamic value = raw;
      final converted = value?.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {}
    return null;
  }

  Future<void> _save() async {
    if (_saving || _rows.isEmpty) return;
    setState(() => _saving = true);
    var saved = 0;
    var failed = 0;
    try {
      final byJob = <String, List<_Row>>{};
      for (final row in _rows) {
        byJob.putIfAbsent(row.jobId, () => []).add(row);
      }
      for (final entry in byJob.entries) {
        final job = _jobs.where((j) => j.id == entry.key).firstOrNull;
        if (job == null) continue;
        final documents = [
          for (final doc in job.documents) Map<String, dynamic>.from(doc),
        ];
        for (final row in entry.value) {
          if (row.docIndex >= documents.length) continue;
          final doc = documents[row.docIndex];
          final items = [
            for (final item in doc['items'] as List? ?? [])
              if (item is Map) Map<String, dynamic>.from(item) else item,
          ];
          if (row.itemIndex >= items.length) continue;
          final item = items[row.itemIndex];
          if (item is! Map<String, dynamic>) continue;
          item['type'] = row.isPart ? 'Part' : 'Service';
          final cost = double.tryParse(
            row.cost.text.trim().replaceAll(',', '.'),
          );
          if (row.isPart && cost != null) {
            item['costPrice'] = cost;
          } else if (!row.isPart) {
            item.remove('costPrice');
          }
          items[row.itemIndex] = item;
          doc['items'] = items;
          saved++;
        }
        try {
          await JobService.updateDocuments(job.id, documents);
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: failed > 0 ? Colors.orange.shade800 : null,
        content: Text(
          failed > 0
              ? context.tr(
                  'Часть заявок не сохранилась — проверьте связь и повторите',
                  'Some jobs did not save — check the connection and retry',
                )
              : '${context.tr('Размечено позиций', 'Lines classified')}: $saved',
        ),
      ),
    );
    if (failed == 0) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final parts = _rows.where((r) => r.isPart).length;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Text(
          context.tr('Разобрать позиции', 'Classify lines'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: _rows.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF14557F),
                      foregroundColor: Colors.white,
                    ),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(
                      '${context.tr('Сохранить', 'Save')} · ${_rows.length}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFCC520)),
            )
          : _error.isNotEmpty
              ? _message(
                  context.tr(
                    'Не удалось загрузить заявки. Проверьте связь.',
                    'Could not load jobs. Check the connection.',
                  ),
                  retry: true,
                )
              : _rows.isEmpty
                  ? _message(
                      context.tr(
                        'Все позиции уже размечены. Новые счета размечаются сразу при создании.',
                        'Every line is classified. New invoices are classified as you create them.',
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        _intro(parts),
                        const SizedBox(height: 12),
                        for (final row in _rows) _rowCard(row),
                      ],
                    ),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.checklist, size: 64, color: Colors.black26),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54, height: 1.4),
            ),
            if (retry) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _load,
                child: Text(context.tr('Ещё раз', 'Retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _intro(int parts) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF5FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBBD4E6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${context.tr('Позиций без метки', 'Unlabelled lines')}: ${_rows.length}',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF14557F),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr(
              'Это старые счета, выписанные до того, как в позицию добавили выбор «Работа / Запчасть». Подсказка уже проставлена по названию — поправьте, что не так, и нажмите «Сохранить».',
              'These invoices were issued before the Service / Part switch existed. A guess is filled in from the line name — fix what is wrong and tap Save.',
            ),
            style: const TextStyle(height: 1.35, color: Colors.black87),
          ),
          const SizedBox(height: 6),
          Text(
            '${context.tr('Сейчас помечено запчастями', 'Currently marked as parts')}: $parts',
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr(
              'Суммы счетов не меняются — метка нужна только отчётам.',
              'Invoice amounts do not change — the label is only for reports.',
            ),
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _rowCard(_Row row) {
    final date = row.date == null
        ? ''
        : DateFormat('d MMM yyyy', AppLocale.instance.dateLocale)
            .format(row.date!);
    final number = row.docNumber.isEmpty ? '' : '#${row.docNumber} · ';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '\$${row.total.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$number${row.clientName}${date.isEmpty ? '' : ' · $date'}',
            style: const TextStyle(
              fontSize: 12.5,
              color: Colors.black54,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(context.tr('Работа', 'Service')),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(context.tr('Запчасть', 'Part')),
                ),
              ],
              selected: {row.isPart},
              onSelectionChanged: (next) =>
                  setState(() => row.isPart = next.first),
            ),
          ),
          if (row.isPart) ...[
            const SizedBox(height: 8),
            TextField(
              controller: row.cost,
              enabled: !row.fromWarehouse,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                isDense: true,
                labelText: context.tr('Закупка', 'Cost'),
                prefixText: '\$ ',
                helperMaxLines: 2,
                helperText: row.fromWarehouse
                    ? context.tr('Со склада', 'From the warehouse')
                    : context.tr(
                        'Пусто — отчёт возьмёт 40% цены и пометит прикидкой',
                        'Empty — reports use 40% of price and flag it',
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
