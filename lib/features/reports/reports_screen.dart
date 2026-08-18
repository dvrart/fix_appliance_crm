import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import '../../models/job.dart';
import '../../services/firestore_service.dart';
import '../../services/warehouse_service.dart';
import '../../core/l10n/app_locale.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _selectedFilter = 'День';
  final List<String> _filters = ['День', 'Неделя', 'Месяц', 'Год'];
  DateTime _selectedDate = DateTime.now();
  Map<String, double> _warehouseCosts = const {};

  @override
  void initState() {
    super.initState();
    _loadWarehouseCosts();
  }

  Future<void> _loadWarehouseCosts() async {
    final items = await WarehouseService.streamAll().first;
    if (!mounted) return;
    setState(() {
      _warehouseCosts = {
        for (final item in items)
          if (item.costPrice != null) item.id: item.costPrice!,
      };
    });
  }

  DateTime get _periodStart {
    final date = _selectedDate;
    switch (_selectedFilter) {
      case 'Неделя':
        final monday = DateTime(date.year, date.month, date.day)
            .subtract(Duration(days: date.weekday - 1));
        return monday;
      case 'Месяц':
        return DateTime(date.year, date.month, 1);
      case 'Год':
        return DateTime(date.year, 1, 1);
      default:
        return DateTime(date.year, date.month, date.day);
    }
  }

  DateTime get _periodEndExclusive {
    switch (_selectedFilter) {
      case 'Неделя':
        return _periodStart.add(const Duration(days: 7));
      case 'Месяц':
        return DateTime(_selectedDate.year, _selectedDate.month + 1, 1);
      case 'Год':
        return DateTime(_selectedDate.year + 1, 1, 1);
      default:
        return _periodStart.add(const Duration(days: 1));
    }
  }

  String get _periodLabel {
    switch (_selectedFilter) {
      case 'Неделя':
        final end = _periodEndExclusive.subtract(const Duration(days: 1));
        return '${DateFormat('d MMM', AppLocale.instance.dateLocale).format(_periodStart)} – ${DateFormat('d MMM yyyy', AppLocale.instance.dateLocale).format(end)}';
      case 'Месяц':
        return DateFormat('LLLL yyyy', AppLocale.instance.dateLocale).format(_selectedDate);
      case 'Год':
        return '${_selectedDate.year}';
      default:
        return DateFormat('d MMMM yyyy', AppLocale.instance.dateLocale).format(_selectedDate);
    }
  }

  void _shiftPeriod(int direction) {
    setState(() {
      switch (_selectedFilter) {
        case 'Неделя':
          _selectedDate = _selectedDate.add(Duration(days: 7 * direction));
          break;
        case 'Месяц':
          _selectedDate = DateTime(
            _selectedDate.year,
            _selectedDate.month + direction,
            1,
          );
          break;
        case 'Год':
          _selectedDate = DateTime(_selectedDate.year + direction, 1, 1);
          break;
        default:
          _selectedDate = _selectedDate.add(Duration(days: direction));
      }
    });
  }

  Future<void> _pickPeriodDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF14557F)),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Финансовый отчет'.tr,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _filters.map((filter) {
                  final isSelected = _selectedFilter == filter;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        trAny(filter),
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: const Color(0xFF14557F),
                      backgroundColor: Colors.grey.shade200,
                      onSelected: (selected) {
                        if (!selected) return;
                        setState(() => _selectedFilter = filter);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.chevron_left,
                    size: 30,
                    color: Color(0xFF14557F),
                  ),
                  onPressed: () => _shiftPeriod(-1),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(
                      Icons.calendar_month,
                      color: Color(0xFF14557F),
                    ),
                    label: Text(
                      _periodLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF14557F),
                      ),
                    ),
                    onPressed: _pickPeriodDate,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.chevron_right,
                    size: 30,
                    color: Color(0xFF14557F),
                  ),
                  onPressed: () => _shiftPeriod(1),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirestoreService.jobsRef.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _buildEmptyState();
                }

                final metrics = _calculateMetrics(snapshot.data!.docs);
                if (metrics.jobCount == 0 &&
                    metrics.invoiced == 0 &&
                    metrics.paid == 0) {
                  return _buildEmptyState();
                }

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              'Выставлено'.tr,
                              metrics.invoiced,
                              Colors.blue,
                              Icons.receipt_long,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Оплачено'.tr,
                              metrics.paid,
                              Colors.green,
                              Icons.payments,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              'Долг'.tr,
                              metrics.due,
                              Colors.red,
                              Icons.warning_amber,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Запчасти (себест.)'.tr,
                              metrics.expenses,
                              Colors.orange,
                              Icons.inventory_2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14557F),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'ЧИСТАЯ ПРИБЫЛЬ'.tr,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '\$${(metrics.paid - metrics.expenses).toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Color(0xFFFCC520),
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${'Завершено работ'.tr}: ${metrics.completedCount}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      Text(
                        'График выручки'.tr,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF14557F),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        height: 250,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.shade200,
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            maxY: metrics.barMax == 0
                                ? 100.0
                                : metrics.barMax * 1.2,
                            barTouchData: BarTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget:
                                      (double value, TitleMeta meta) {
                                    const style = TextStyle(
                                      color: Colors.grey,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    );
                                    final index = value.toInt();
                                    final text = index >= 0 &&
                                            index < metrics.barLabels.length
                                        ? metrics.barLabels[index]
                                        : '';
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 8.0),
                                      child: Text(text, style: style),
                                    );
                                  },
                                ),
                              ),
                              leftTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            barGroups: [
                              for (var i = 0; i < metrics.barValues.length; i++)
                                _buildBarGroup(
                                  i,
                                  metrics.barValues[i],
                                  metrics.barMax,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  BarChartGroupData _buildBarGroup(int x, double y, double totalIncome) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: const Color(0xFFFCC520),
          width: 16,
          borderRadius: BorderRadius.circular(4),
          backDrawRodData: BackgroundBarChartRodData(
            show: true,
            toY: totalIncome == 0 ? 100.0 : totalIncome * 1.2,
            color: Colors.grey.shade100,
          ),
        ),
      ],
    );
  }

  _ReportMetrics _calculateMetrics(List<DocumentSnapshot> docs) {
    var invoiced = 0.0;
    var paid = 0.0;
    var expenses = 0.0;
    var completed = 0;
    var jobCount = 0;
    final start = _periodStart;
    final end = _periodEndExclusive;
    final buckets = <String, double>{};

    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>? ?? <String, dynamic>{};
      Job job;
      try {
        job = Job.fromMap(data, doc.id);
      } catch (_) {
        continue;
      }
      final jobDate = job.completedAt ?? job.scheduledAt ?? job.createdAt;
      if (jobDate.isBefore(start) || !jobDate.isBefore(end)) continue;

      jobCount++;
      if (job.status == 'Завершено') completed++;
      invoiced += job.invoicedTotal;
      paid += job.paidTotal;
      expenses += _jobExpenses(job);
      final key = _bucketKey(jobDate);
      buckets[key] = (buckets[key] ?? 0) + job.paidTotal;
    }

    final labels = <String>[];
    final values = <double>[];
    _fillBuckets(start, end, buckets, labels, values);
    final maxY = values.fold<double>(0, (m, v) => v > m ? v : m);

    return _ReportMetrics(
      invoiced: invoiced,
      paid: paid,
      due: (invoiced - paid).clamp(0, double.infinity),
      expenses: expenses,
      completedCount: completed,
      jobCount: jobCount,
      barLabels: labels,
      barValues: values,
      barMax: maxY,
    );
  }

  double _jobExpenses(Job job) {
    var expenses = 0.0;
    for (final doc in job.documents) {
      if (!Job.isInvoice(doc)) continue;
      final items = doc['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final qty = (item['qty'] as num?)?.toDouble() ?? 1;
        var cost = (item['costPrice'] as num?)?.toDouble();
        final warehouseId = (item['warehouseItemId'] ?? '').toString();
        if (cost == null && warehouseId.isNotEmpty) {
          cost = _warehouseCosts[warehouseId];
        }
        if (cost != null) {
          expenses += qty * cost;
          continue;
        }
        final type = (item['type'] ?? '').toString().toLowerCase();
        if (type.contains('запчаст') || type.contains('part')) {
          expenses += qty * ((item['price'] as num?)?.toDouble() ?? 0) * 0.4;
        }
      }
    }
    return expenses;
  }

  String _bucketKey(DateTime date) {
    switch (_selectedFilter) {
      case 'Год':
        return '${date.year}-${date.month}';
      default:
        return '${date.year}-${date.month}-${date.day}';
    }
  }

  void _fillBuckets(
    DateTime start,
    DateTime end,
    Map<String, double> buckets,
    List<String> labels,
    List<double> values,
  ) {
    if (_selectedFilter == 'Год') {
      for (var month = 1; month <= 12; month++) {
        labels.add(DateFormat('MMM', AppLocale.instance.dateLocale).format(DateTime(start.year, month)));
        values.add(buckets['${start.year}-$month'] ?? 0);
      }
      return;
    }
    if (_selectedFilter == 'Месяц') {
      var day = start;
      while (day.isBefore(end)) {
        labels.add('${day.day}');
        values.add(buckets['${day.year}-${day.month}-${day.day}'] ?? 0);
        day = day.add(const Duration(days: 1));
      }
      return;
    }
    if (_selectedFilter == 'Неделя') {
      final names = ['Пн'.tr, 'Вт'.tr, 'Ср'.tr, 'Чт'.tr, 'Пт'.tr, 'Сб'.tr, 'Вс'.tr];
      for (var i = 0; i < 7; i++) {
        final day = start.add(Duration(days: i));
        labels.add(names[i]);
        values.add(buckets['${day.year}-${day.month}-${day.day}'] ?? 0);
      }
      return;
    }
    labels.add(DateFormat('d MMM', AppLocale.instance.dateLocale).format(start));
    values.add(buckets['${start.year}-${start.month}-${start.day}'] ?? 0);
  }

  Widget _buildSummaryCard(
    String title,
    double amount,
    Color iconColor,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 4),
              Text(
                title,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_chart_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'За выбранный период нет данных.'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _ReportMetrics {
  final double invoiced;
  final double paid;
  final double due;
  final double expenses;
  final int completedCount;
  final int jobCount;
  final List<String> barLabels;
  final List<double> barValues;
  final double barMax;

  const _ReportMetrics({
    required this.invoiced,
    required this.paid,
    required this.due,
    required this.expenses,
    required this.completedCount,
    required this.jobCount,
    required this.barLabels,
    required this.barValues,
    required this.barMax,
  });
}
