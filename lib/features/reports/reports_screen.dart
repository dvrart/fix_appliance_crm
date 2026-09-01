import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import '../../models/job.dart';
import '../../models/expense.dart';
import '../../services/firestore_service.dart';
import '../../services/settings_service.dart';
import '../../services/stripe_service.dart';
import '../../services/warehouse_service.dart';
import '../../services/expense_service.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import 'tax_workbook_view.dart';
import 'tax_writeoff_guide_page.dart';
import '../expenses/expenses_screen.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _selectedFilter = 'Год';
  final List<String> _filters = ['День', 'Неделя', 'Месяц', 'Квартал', 'Год'];
  DateTime _selectedDate = DateTime.now();
  Map<String, double> _warehouseCosts = const {};
  StripeAccountBalance? _stripeBalance;
  String _hstNumber = '';
  String _companyName = '';
  String _companyAddress = '';
  double _inventoryAtCost = 0;
  bool _t2Mode = true;
  _ReportMetrics? _latestMetrics;
  List<Expense> _expenses = const [];
  StreamSubscription<List<Expense>>? _expenseSub;

  @override
  void initState() {
    super.initState();
    _loadWarehouseCosts();
    _loadStripeBalance();
    _loadCompany();
    _expenseSub = ExpenseService.streamAll().listen((items) {
      if (!mounted) return;
      setState(() => _expenses = items);
    });
  }

  @override
  void dispose() {
    _expenseSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCompany() async {
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() {
      _hstNumber = docs.hstNumber.trim();
      _companyName = docs.companyName.trim();
      _companyAddress = docs.companyAddress.trim();
    });
  }

  Future<void> _loadStripeBalance() async {
    try {
      final balance = await StripeService.fetchBalance();
      if (!mounted) return;
      setState(() => _stripeBalance = balance);
    } catch (_) {}
  }

  Future<void> _loadWarehouseCosts() async {
    final items = await WarehouseService.streamAll().first;
    if (!mounted) return;
    setState(() {
      _warehouseCosts = {
        for (final item in items)
          if (item.costPrice != null) item.id: item.costPrice!,
      };
      _inventoryAtCost = items.fold<double>(
        0,
        (sum, item) => sum + item.quantity * (item.costPrice ?? 0),
      );
    });
  }

  DateTime get _periodStart {
    final date = _selectedDate;
    switch (_selectedFilter) {
      case 'Неделя':
        final monday = DateTime(date.year, date.month, date.day)
            .subtract(Duration(days: date.weekday - 1));
        return monday;
      case 'Квартал':
        final month = ((date.month - 1) ~/ 3) * 3 + 1;
        return DateTime(date.year, month, 1);
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
      case 'Квартал':
        return DateTime(_periodStart.year, _periodStart.month + 3, 1);
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
      case 'Квартал':
        final q = ((_periodStart.month - 1) ~/ 3) + 1;
        final end = _periodEndExclusive.subtract(const Duration(days: 1));
        return '${q} ${'кв.'.tr} ${_periodStart.year} (${DateFormat('d MMM', AppLocale.instance.dateLocale).format(_periodStart)} – ${DateFormat('d MMM', AppLocale.instance.dateLocale).format(end)})';
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
        case 'Квартал':
          _selectedDate = DateTime(
            _selectedDate.year,
            _selectedDate.month + 3 * direction,
            1,
          );
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

  Future<void> _openExpenses({bool camera = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExpensesScreen(startWithCamera: camera),
      ),
    );
  }

  Future<void> _scanReceipt() => _openExpenses(camera: true);

  /// [withCash] = false убирает из всех строк ту долю, что закрыта наличными,
  /// вместе с её HST и запчастями — чтобы валовая прибыль сходилась.
  TaxWorkbookFigures _figures(_ReportMetrics metrics, {bool withCash = true}) {
    double less(double value, double cash) =>
        withCash ? value : (value - cash).clamp(0, double.infinity);

    return TaxWorkbookFigures(
      companyName: _companyName,
      companyAddress: _companyAddress,
      hstNumber: _hstNumber,
      periodLabel: _periodLabel,
      periodStart: _periodStart,
      periodEndInclusive: _periodEndExclusive.subtract(const Duration(days: 1)),
      isFullYear: _selectedFilter == 'Год',
      salesExHst: less(metrics.salesExHst, metrics.cashSalesExHst),
      hstCollectible: less(metrics.hstCollectible, metrics.cashTax),
      cashExHst: less(metrics.cashExHst, metrics.cashReceivedExHst),
      hstReceived: less(metrics.hstReceived, metrics.cashReceivedHst),
      partsCost: less(metrics.expenses, metrics.cashParts),
      inventoryAtCost: _inventoryAtCost,
      stripeAvailable: _stripeBalance?.available,
      cashSalesExHst: metrics.cashSalesExHst,
      includesCash: withCash,
      receipts: ExpenseRollup.fromList(
        ExpenseService.inPeriod(
          _expenses,
          _periodStart,
          _periodEndExclusive,
        ),
      ),
    );
  }

  static const _emptyMetrics = _ReportMetrics(
    invoiced: 0,
    paid: 0,
    due: 0,
    expenses: 0,
    completedCount: 0,
    createdCount: 0,
    invoiceCount: 0,
    salesExHst: 0,
    hstCollectible: 0,
    cashExHst: 0,
    hstReceived: 0,
    jobCount: 0,
    barLabels: <String>[],
    barValues: <double>[],
    barMax: 0,
    barWidth: 16,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _t2Mode
              ? context.tr('Пакет для T2', 'T2 workbook')
              : 'Финансовый отчет'.tr,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: context.tr('Лайфхак', 'Lifehack'),
            onPressed: () => TaxWriteoffGuidePage.open(context),
            icon: const Icon(Icons.lightbulb_outline),
          ),
          if (_t2Mode) ...[
            IconButton(
              tooltip: context.tr('Копировать', 'Copy'),
              onPressed: _latestMetrics == null
                  ? null
                  : () async {
                      final done = await TaxWorkbookView.shareWithCashChoice(
                        context,
                        _figures(_latestMetrics!),
                        _figures(_latestMetrics!, withCash: false),
                        copyInstead: true,
                      );
                      if (!done || !context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.tr('Скопировано', 'Copied'))),
                      );
                    },
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: context.tr('Скачать PDF', 'Download PDF'),
              onPressed: _latestMetrics == null
                  ? null
                  : () => TaxWorkbookView.shareWithCashChoice(
                      context,
                      _figures(_latestMetrics!),
                      _figures(_latestMetrics!, withCash: false),
                    ),
              icon: const Icon(Icons.ios_share),
            ),
          ],
        ],
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
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(context.tr('Для T2', 'For T2')),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(context.tr('Операции', 'Activity')),
                ),
              ],
              selected: {_t2Mode},
              onSelectionChanged: (next) {
                setState(() => _t2Mode = next.first);
              },
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
                  _latestMetrics = _emptyMetrics;
                  if (_t2Mode) {
                    return TaxWorkbookView(
                      figures: _figures(_emptyMetrics),
                      figuresWithoutCash: _figures(
                        _emptyMetrics,
                        withCash: false,
                      ),
                      onSwitchToYear: () => setState(() => _selectedFilter = 'Год'),
                      onOpenExpenses: _openExpenses,
                      onScanReceipt: _scanReceipt,
                    );
                  }
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: _buildStripeCard(),
                      ),
                      Expanded(child: _buildEmptyState()),
                    ],
                  );
                }

                final metrics = _calculateMetrics(snapshot.data!.docs);
                _latestMetrics = metrics;
                if (_t2Mode) {
                  return TaxWorkbookView(
                    figures: _figures(metrics),
                    figuresWithoutCash: _figures(metrics, withCash: false),
                    onSwitchToYear: () => setState(() => _selectedFilter = 'Год'),
                    onOpenExpenses: _openExpenses,
                    onScanReceipt: _scanReceipt,
                  );
                }
                if (metrics.jobCount == 0 &&
                    metrics.invoiced == 0 &&
                    metrics.paid == 0 &&
                    metrics.createdCount == 0 &&
                    _selectedFilter != 'День') {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: _buildStripeCard(),
                      ),
                      Expanded(child: _buildEmptyState()),
                    ],
                  );
                }

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStripeCard(),
                      const SizedBox(height: 12),
                      _buildOpenT2Card(),
                      const SizedBox(height: 20),
                      Text(
                        context.tr('Операции', 'Shop activity'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF14557F),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildKpiCard(
                              'Новые заявки'.tr,
                              '${metrics.createdCount}',
                              Colors.blueGrey,
                              Icons.post_add,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildKpiCard(
                              'Завершено работ'.tr,
                              '${metrics.completedCount}',
                              Colors.teal,
                              Icons.task_alt,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildKpiCard(
                              'Средний чек'.tr,
                              '\$${metrics.avgTicket.toStringAsFixed(0)}',
                              Colors.indigo,
                              Icons.receipt,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildKpiCard(
                              'Собрано'.tr,
                              '${metrics.collectionRate.toStringAsFixed(0)}%',
                              Colors.green.shade700,
                              Icons.percent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              'Счета с HST'.tr,
                              metrics.invoiced,
                              Colors.blue,
                              Icons.receipt_long,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Получено с HST'.tr,
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
                              'После запчастей'.tr,
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
                              'С HST, не для налогов. Для CRA — блок выше.'.tr,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      Text(
                        'Выручка без HST'.tr,
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
                            groupsSpace: _selectedFilter == 'День' ? 2 : 8,
                            maxY: metrics.barMax == 0
                                ? 100.0
                                : metrics.barMax * 1.2,
                            barTouchData: BarTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 28,
                                  interval: 1,
                                  getTitlesWidget:
                                      (double value, TitleMeta meta) {
                                    const style = TextStyle(
                                      color: Colors.grey,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
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
                                  metrics.barWidth,
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

  BarChartGroupData _buildBarGroup(
    int x,
    double y,
    double totalIncome,
    double barWidth,
  ) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: const Color(0xFFFCC520),
          width: barWidth,
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

  DateTime? _parseAnyDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is num) {
      final value = raw.toDouble();
      if (value > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value.round());
      }
      if (value > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
      }
    }
    if (raw is Map) {
      final seconds = raw['_seconds'] ?? raw['seconds'];
      if (seconds is num) {
        return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
      }
    }
    return null;
  }

  DateTime? _invoiceDate(Map doc) {
    return _parseAnyDate(doc['createdAt']) ??
        _parseAnyDate(doc['issuedAt']) ??
        _parseAnyDate(doc['date']);
  }

  DateTime? _paymentDate(Map payment, DateTime? fallback) {
    return _parseAnyDate(payment['date']) ??
        _parseAnyDate(payment['createdAt']) ??
        fallback;
  }

  bool _inPeriod(DateTime? date, DateTime start, DateTime end) {
    return date != null && !date.isBefore(start) && date.isBefore(end);
  }

  _ReportMetrics _calculateMetrics(List<DocumentSnapshot> docs) {
    var invoiced = 0.0;
    var paid = 0.0;
    var due = 0.0;
    var expenses = 0.0;
    var completed = 0;
    var created = 0;
    var invoiceCount = 0;
    var salesExHst = 0.0;
    var hstCollectible = 0.0;
    var cashExHst = 0.0;
    var hstReceived = 0.0;
    var cashSalesExHst = 0.0;
    var cashTax = 0.0;
    var cashParts = 0.0;
    var cashReceivedExHst = 0.0;
    var cashReceivedHst = 0.0;
    final jobsInPeriod = <String>{};
    final start = _periodStart;
    final end = _periodEndExclusive;
    final buckets = <String, double>{};

    void addCash(
      double amount,
      double subtotal,
      double tax,
      DateTime when, {
      bool byCash = false,
    }) {
      final total = subtotal + tax;
      final net = total > 0.009 ? amount * (subtotal / total) : amount;
      final hst = amount - net;
      cashExHst += net;
      hstReceived += hst;
      paid += amount;
      if (byCash) {
        cashReceivedExHst += net;
        cashReceivedHst += hst;
      }
      final key = _bucketKey(when);
      buckets[key] = (buckets[key] ?? 0) + net;
    }

    for (final snap in docs) {
      final data = snap.data() as Map<String, dynamic>? ?? <String, dynamic>{};
      Job job;
      try {
        job = Job.fromMap(data, snap.id);
      } catch (_) {
        continue;
      }
      if (job.isDeleted) continue;

      if (_inPeriod(job.createdAt, start, end)) {
        created++;
      }

      if (_inPeriod(job.completedAt, start, end) &&
          JobStatuses.isCompletedStatus(job.status)) {
        completed++;
        jobsInPeriod.add(job.id);
      }

      for (final inv in job.documents) {
        if (!Job.isInvoice(inv)) continue;
        final invDate = _invoiceDate(inv);
        final subtotal = Job.documentSubtotal(inv);
        final tax = Job.documentTax(inv);
        final total = subtotal + tax;
        final paidOnDoc = Job.documentPaid(inv);
        final invoiceParts = _invoiceExpenses(inv);
        if (_inPeriod(invDate, start, end)) {
          invoiced += total;
          salesExHst += subtotal;
          hstCollectible += tax;
          invoiceCount++;
          due += (total - paidOnDoc).clamp(0, double.infinity);
          expenses += invoiceParts;
          jobsInPeriod.add(job.id);

          // Доля счёта, закрытая наличными, — её вычитает выгрузка «без
          // наличных». Дату платежа тут не смотрим: продажи признаём по
          // дате счёта, а вопрос один — чем за этот счёт заплатили.
          final cashOnDoc = _cashPaidOn(inv);
          if (cashOnDoc > 0.009 && total > 0.009) {
            final share = (cashOnDoc / total).clamp(0.0, 1.0);
            cashSalesExHst += subtotal * share;
            cashTax += tax * share;
            cashParts += invoiceParts * share;
          }
        }

        final payments = inv['payments'];
        var attributedPaid = 0.0;
        if (payments is List) {
          for (final payment in payments) {
            if (payment is! Map) continue;
            final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
            if (amount <= 0) continue;
            final payDate = _paymentDate(payment, invDate);
            if (!_inPeriod(payDate, start, end)) continue;
            attributedPaid += amount;
            jobsInPeriod.add(job.id);
            addCash(
              amount,
              subtotal,
              tax,
              payDate!,
              byCash: _isCashPayment(payment),
            );
          }
        }
        if (attributedPaid == 0 &&
            paidOnDoc > 0 &&
            _inPeriod(invDate, start, end)) {
          jobsInPeriod.add(job.id);
          addCash(paidOnDoc, subtotal, tax, invDate!);
        }
      }
    }

    final labels = <String>[];
    final values = <double>[];
    _fillBuckets(start, end, buckets, labels, values);
    final maxY = values.fold<double>(0, (m, v) => v > m ? v : m);

    return _ReportMetrics(
      invoiced: invoiced,
      paid: paid,
      due: due,
      expenses: expenses,
      completedCount: completed,
      createdCount: created,
      invoiceCount: invoiceCount,
      salesExHst: salesExHst,
      hstCollectible: hstCollectible,
      cashExHst: cashExHst,
      hstReceived: hstReceived,
      cashSalesExHst: cashSalesExHst,
      cashTax: cashTax,
      cashParts: cashParts,
      cashReceivedExHst: cashReceivedExHst,
      cashReceivedHst: cashReceivedHst,
      jobCount: jobsInPeriod.length,
      barLabels: labels,
      barValues: values,
      barMax: maxY,
      barWidth: _selectedFilter == 'День' ? 6 : 16,
    );
  }

  /// Наличными ли платили. Пустой способ считаем безналичным — так вариант
  /// «без наличных» не занизит доход, если способ забыли проставить.
  bool _isCashPayment(Map payment) {
    final method = (payment['method'] ?? '').toString().toLowerCase();
    return method.contains('cash') || method.contains('налич');
  }

  double _cashPaidOn(Map doc) {
    final payments = doc['payments'];
    if (payments is! List) return 0;
    var sum = 0.0;
    for (final payment in payments) {
      if (payment is! Map) continue;
      if (!_isCashPayment(payment)) continue;
      final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
      if (amount <= 0) continue;
      sum += amount;
    }
    return sum;
  }

  double _invoiceExpenses(Map doc) {
    var expenses = 0.0;
    final items = doc['items'];
    if (items is! List) return 0;
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
    return expenses;
  }

  String _bucketKey(DateTime date) {
    switch (_selectedFilter) {
      case 'Год':
        return '${date.year}-${date.month}';
      case 'День':
        return '${date.year}-${date.month}-${date.day}-${date.hour}';
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
    if (_selectedFilter == 'Квартал') {
      var day = start;
      var week = 1;
      while (day.isBefore(end)) {
        var sum = 0.0;
        for (var i = 0; i < 7 && day.isBefore(end); i++) {
          sum += buckets['${day.year}-${day.month}-${day.day}'] ?? 0;
          day = day.add(const Duration(days: 1));
        }
        labels.add('W$week');
        values.add(sum);
        week++;
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
    for (var hour = 0; hour < 24; hour++) {
      labels.add(hour % 3 == 0 ? hour.toString().padLeft(2, '0') : '');
      values.add(buckets['${start.year}-${start.month}-${start.day}-$hour'] ?? 0);
    }
  }

  Widget _buildStripeCard() {
    final balance = _stripeBalance;
    if (balance == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A2540),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'На счёте Stripe'.tr,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            '${balance.currency} \$${balance.available.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (balance.pending.abs() > 0.009) ...[
            const SizedBox(height: 6),
            Text(
              '${'Ожидает Stripe'.tr}: \$${balance.pending.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOpenT2Card() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _t2Mode = true),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF14557F), width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.account_balance, color: Color(0xFF14557F)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.tr(
                      'Пакет для UFile T2 / TurboTax — куда какую цифру вписать',
                      'UFile T2 / TurboTax pack — what number goes where',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700, height: 1.3),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFF14557F)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKpiCard(String title, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
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
  final int createdCount;
  final int invoiceCount;
  final double salesExHst;
  final double hstCollectible;
  final double cashExHst;
  final double hstReceived;

  /// Доли периода, оплаченные наличными. Нужны, чтобы выгрузить второй
  /// вариант отчёта — только банк и Stripe.
  final double cashSalesExHst;
  final double cashTax;
  final double cashParts;
  final double cashReceivedExHst;
  final double cashReceivedHst;
  final int jobCount;
  final List<String> barLabels;
  final List<double> barValues;
  final double barMax;
  final double barWidth;

  const _ReportMetrics({
    required this.invoiced,
    required this.paid,
    required this.due,
    required this.expenses,
    required this.completedCount,
    required this.createdCount,
    required this.invoiceCount,
    required this.salesExHst,
    required this.hstCollectible,
    required this.cashExHst,
    required this.hstReceived,
    this.cashSalesExHst = 0,
    this.cashTax = 0,
    this.cashParts = 0,
    this.cashReceivedExHst = 0,
    this.cashReceivedHst = 0,
    required this.jobCount,
    required this.barLabels,
    required this.barValues,
    required this.barMax,
    required this.barWidth,
  });

  double get avgTicket => invoiceCount <= 0 ? 0 : invoiced / invoiceCount;

  double get collectionRate => invoiced <= 0 ? 0 : (paid / invoiced * 100).clamp(0, 999);
}
