import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

class StatPoint {
  final DateTime at;
  final double amount;

  const StatPoint(this.at, [this.amount = 0]);
}

class StatisticsDetailPage extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String filter;
  final DateTime selectedDate;
  final List<StatPoint> points;

  const StatisticsDetailPage({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.filter,
    required this.selectedDate,
    required this.points,
  });

  @override
  State<StatisticsDetailPage> createState() => _StatisticsDetailPageState();
}

class _StatisticsDetailPageState extends State<StatisticsDetailPage> {
  late String _filter;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _filter = widget.filter;
    _selectedDate = widget.selectedDate;
  }

  DateTime get _periodStart {
    final date = _selectedDate;
    switch (_filter) {
      case 'Неделя':
        return DateTime(date.year, date.month, date.day)
            .subtract(Duration(days: date.weekday - 1));
      case 'Месяц':
        return DateTime(date.year, date.month, 1);
      default:
        return DateTime(date.year, date.month, date.day);
    }
  }

  DateTime get _periodEndExclusive {
    switch (_filter) {
      case 'Неделя':
        return _periodStart.add(const Duration(days: 7));
      case 'Месяц':
        return DateTime(_selectedDate.year, _selectedDate.month + 1, 1);
      default:
        return _periodStart.add(const Duration(days: 1));
    }
  }

  String get _periodLabel {
    switch (_filter) {
      case 'Неделя':
        final end = _periodEndExclusive.subtract(const Duration(days: 1));
        return '${DateFormat('d MMM', AppLocale.instance.dateLocale).format(_periodStart)} – ${DateFormat('d MMM yyyy', AppLocale.instance.dateLocale).format(end)}';
      case 'Месяц':
        return DateFormat('LLLL yyyy', AppLocale.instance.dateLocale)
            .format(_selectedDate);
      default:
        return DateFormat('d MMMM yyyy', AppLocale.instance.dateLocale)
            .format(_selectedDate);
    }
  }

  void _shift(int direction) {
    setState(() {
      switch (_filter) {
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
        default:
          _selectedDate = _selectedDate.add(Duration(days: direction));
      }
    });
  }

  Future<void> _pickDate() async {
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

  bool _inPeriod(DateTime date) {
    return !date.isBefore(_periodStart) && date.isBefore(_periodEndExclusive);
  }

  List<_Bucket> get _buckets {
    final start = _periodStart;
    final end = _periodEndExclusive;
    final buckets = <_Bucket>[];
    if (_filter == 'День') {
      for (var hour = 0; hour < 24; hour++) {
        buckets.add(
          _Bucket(
            start: DateTime(start.year, start.month, start.day, hour),
            label: '${hour.toString().padLeft(2, '0')}:00',
          ),
        );
      }
    } else if (_filter == 'Неделя') {
      final names = ['Пн'.tr, 'Вт'.tr, 'Ср'.tr, 'Чт'.tr, 'Пт'.tr, 'Сб'.tr, 'Вс'.tr];
      for (var i = 0; i < 7; i++) {
        final day = start.add(Duration(days: i));
        buckets.add(_Bucket(start: day, label: names[i]));
      }
    } else {
      var day = start;
      while (day.isBefore(end)) {
        buckets.add(
          _Bucket(
            start: day,
            label: '${day.day}',
          ),
        );
        day = day.add(const Duration(days: 1));
      }
    }

    for (final point in widget.points) {
      if (!_inPeriod(point.at)) continue;
      final index = _indexFor(point.at, buckets.length);
      if (index < 0 || index >= buckets.length) continue;
      buckets[index].count += 1;
      buckets[index].amount += point.amount;
    }
    return buckets;
  }

  int _indexFor(DateTime date, int length) {
    switch (_filter) {
      case 'Неделя':
        return (date.weekday - 1).clamp(0, 6);
      case 'Месяц':
        return (date.day - 1).clamp(0, length - 1);
      default:
        return date.hour.clamp(0, 23);
    }
  }

  @override
  Widget build(BuildContext context) {
    final buckets = _buckets;
    final total = buckets.fold<int>(0, (sum, b) => sum + b.count);
    final moneyTotal = buckets.fold<double>(0, (sum, b) => sum + b.amount);
    final maxCount = buckets.fold<int>(0, (m, b) => b.count > m ? b.count : m);
    final withData = buckets.where((b) => b.count > 0).toList();
    final peak = withData.isEmpty
        ? null
        : withData.reduce((a, b) => a.count >= b.count ? a : b);
    final low = withData.isEmpty
        ? null
        : withData.reduce((a, b) => a.count <= b.count ? a : b);
    final quiet = _quietRanges(buckets);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final showMoney = moneyTotal > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                for (final filter in const ['День', 'Неделя', 'Месяц'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        trAny(filter),
                        style: TextStyle(
                          color: _filter == filter ? Colors.white : Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: _filter == filter,
                      selectedColor: const Color(0xFF14557F),
                      backgroundColor: Colors.grey.shade200,
                      onSelected: (selected) {
                        if (!selected) return;
                        setState(() => _filter = filter);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 30, color: Color(0xFF14557F)),
                  onPressed: () => _shift(-1),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.calendar_month, color: Color(0xFF14557F)),
                    label: Text(
                      _periodLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF14557F),
                      ),
                    ),
                    onPressed: _pickDate,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 30, color: Color(0xFF14557F)),
                  onPressed: () => _shift(1),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _summaryCard(
                  total: total,
                  money: showMoney ? money.format(moneyTotal) : null,
                ),
                const SizedBox(height: 12),
                if (peak != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _highlightCard(
                          title: 'Больше всего'.tr,
                          value: peak.label,
                          count: peak.count,
                          color: AppColors.accent,
                          icon: Icons.trending_up,
                          money: showMoney && peak.amount > 0
                              ? money.format(peak.amount)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _highlightCard(
                          title: 'Меньше всего'.tr,
                          value: (low ?? peak).label,
                          count: (low ?? peak).count,
                          color: const Color(0xFF546E7A),
                          icon: Icons.trending_down,
                          money: showMoney && (low ?? peak).amount > 0
                              ? money.format((low ?? peak).amount)
                              : null,
                        ),
                      ),
                    ],
                  ),
                  if (quiet.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _quietCard(quiet),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    _filter == 'День' ? 'По часам'.tr : 'По дням'.tr,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF14557F),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _chart(buckets, maxCount),
                  const SizedBox(height: 16),
                  for (final bucket in buckets.where((b) => b.count > 0))
                    _row(
                      bucket: bucket,
                      maxCount: maxCount,
                      isPeak: peak.count == bucket.count,
                      isLow: low != null &&
                          low.count == bucket.count &&
                          low.count != peak.count,
                      money: showMoney && bucket.amount > 0
                          ? money.format(bucket.amount)
                          : null,
                    ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Center(
                      child: Text(
                        'Нет данных за этот период'.tr,
                        style: const TextStyle(color: Colors.black54, fontSize: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard({required int total, String? money}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: widget.color.withValues(alpha: 0.12),
            child: Icon(widget.icon, color: widget.color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$total',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: widget.color,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (money != null)
                  Text(
                    money,
                    style: TextStyle(
                      color: widget.color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _highlightCard({
    required String title,
    required String value,
    required int count,
    required Color color,
    required IconData icon,
    String? money,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.black54,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          Text(
            '$count',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          if (money != null)
            Text(
              money,
              style: TextStyle(
                color: color.withValues(alpha: 0.85),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  Widget _quietCard(String ranges) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.nightlight_round, color: Color(0xFF78909C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _filter == 'День' ? 'Тихие часы'.tr : 'Тихие дни'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF455A64),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ranges,
                  style: const TextStyle(color: Colors.black54, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chart(List<_Bucket> buckets, int maxCount) {
    final maxY = maxCount <= 0 ? 4.0 : (maxCount < 4 ? 4.0 : (maxCount * 1.2).ceilToDouble());
    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => const Color(0xE61A1A1A),
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                if (group.x < 0 || group.x >= buckets.length) return null;
                return BarTooltipItem(
                  '${buckets[group.x].label}\n${rod.toY.toInt()}',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
                  final step = buckets.length > 16 ? 4 : (_filter == 'День' ? 3 : 1);
                  if (i % step != 0) return const SizedBox.shrink();
                  return Text(
                    buckets[i].label,
                    style: const TextStyle(fontSize: 10, color: Colors.black54),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: buckets[i].count.toDouble(),
                    width: _filter == 'День' ? 6 : 10,
                    color: buckets[i].count == maxCount && maxCount > 0
                        ? AppColors.accent
                        : widget.color.withValues(
                            alpha: buckets[i].count == 0
                                ? 0.12
                                : 0.35 + 0.65 * (buckets[i].count / maxCount),
                          ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required _Bucket bucket,
    required int maxCount,
    required bool isPeak,
    required bool isLow,
    String? money,
  }) {
    final t = maxCount == 0 ? 0.0 : bucket.count / maxCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: isPeak
              ? Border.all(color: AppColors.accent, width: 1.4)
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(
                bucket.label,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: t.clamp(0, 1),
                  minHeight: 10,
                  backgroundColor: const Color(0xFFE8EEF3),
                  color: isPeak ? AppColors.accent : widget.color,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${bucket.count}',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            if (isPeak || isLow) ...[
              const SizedBox(width: 6),
              Icon(
                isPeak ? Icons.arrow_upward : Icons.arrow_downward,
                size: 16,
                color: isPeak ? const Color(0xFFC9A218) : const Color(0xFF546E7A),
              ),
            ],
            if (money != null) ...[
              const SizedBox(width: 8),
              Text(
                money,
                style: TextStyle(
                  color: widget.color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _quietRanges(List<_Bucket> buckets) {
    final zeroIndexes = <int>[];
    for (var i = 0; i < buckets.length; i++) {
      if (buckets[i].count == 0) zeroIndexes.add(i);
    }
    if (zeroIndexes.isEmpty || zeroIndexes.length == buckets.length) return '';

    final parts = <String>[];
    var runStart = zeroIndexes.first;
    var prev = zeroIndexes.first;
    for (var i = 1; i < zeroIndexes.length; i++) {
      if (zeroIndexes[i] == prev + 1) {
        prev = zeroIndexes[i];
        continue;
      }
      parts.add(_rangeLabel(buckets, runStart, prev));
      runStart = zeroIndexes[i];
      prev = zeroIndexes[i];
    }
    parts.add(_rangeLabel(buckets, runStart, prev));
    return parts.join(', ');
  }

  String _rangeLabel(List<_Bucket> buckets, int from, int to) {
    if (from == to) return buckets[from].label;
    if (_filter == 'День') {
      final endHour = buckets[to].start.hour;
      return '${buckets[from].label}–${endHour.toString().padLeft(2, '0')}:59';
    }
    return '${buckets[from].label}–${buckets[to].label}';
  }
}

class _Bucket {
  final DateTime start;
  final String label;
  int count = 0;
  double amount = 0;

  _Bucket({required this.start, required this.label});
}
