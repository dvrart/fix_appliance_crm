import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/utils/app_date_picker.dart';
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
import '../../core/l10n/app_locale.dart';
import 'classify_items_page.dart';
import 'report_breakdown_page.dart';
import 'report_metrics.dart';
import 'tax_workbook_view.dart';
import 'tax_writeoff_guide_page.dart';
import '../expenses/expenses_screen.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../../shared/app_nav.dart';
import '../../services/error_log_service.dart';

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
  ReportMetrics? _latestMetrics;
  List<Expense> _expenses = const [];
  StreamSubscription<List<Expense>>? _expenseSub;
  late final _jobsStream = FirestoreService.jobsRef.snapshots();

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Отчёты');
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
        return '$q ${'кв.'.tr} ${_periodStart.year} (${DateFormat('d MMM', AppLocale.instance.dateLocale).format(_periodStart)} – ${DateFormat('d MMM', AppLocale.instance.dateLocale).format(end)})';
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
    final picked = await showAppDateSheet(
      context: context,
      initial: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
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

  List<Expense> get _periodExpenses =>
      ExpenseService.inPeriod(_expenses, _periodStart, _periodEndExclusive);

  ExpenseRollup get _receipts => ExpenseRollup.fromList(_periodExpenses);

  /// [withCash] = false убирает из всех строк ту долю, что закрыта наличными,
  /// вместе с её HST и запчастями — чтобы валовая прибыль сходилась.
  TaxWorkbookFigures _figures(ReportMetrics metrics, {bool withCash = true}) {
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
      partsCost: less(metrics.partsCost, metrics.cashParts),
      tips: metrics.tips,
      inventoryAtCost: _inventoryAtCost,
      stripeAvailable: _stripeBalance?.available,
      cashSalesExHst: metrics.cashSalesExHst,
      includesCash: withCash,
      receipts: _receipts,
    );
  }

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
              stream: _jobsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                }

                final metrics = snapshot.hasData
                    ? _calculateMetrics(snapshot.data!.docs)
                    : ReportMetrics.empty;
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

                final empty = metrics.jobCount == 0 &&
                    metrics.invoiced == 0 &&
                    metrics.paid == 0 &&
                    metrics.createdCount == 0;
                if (empty && _selectedFilter != 'День') {
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

                return _buildActivity(metrics);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── вкладка «Операции» ───────────────────────────

  Widget _buildActivity(ReportMetrics m) {
    final receipts = _receipts;
    final bars = _bars(m);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStripeCard(),
          const SizedBox(height: 12),
          _buildOpenT2Card(),
          const SizedBox(height: 10),
          Text(
            context.tr(
              'Нажмите на любую карточку — откроется расшифровка: из чего сложилась цифра и как она считается.',
              'Tap any card to see the breakdown: what makes up the number and how it is calculated.',
            ),
            style: const TextStyle(color: Colors.black54, fontSize: 12.5, height: 1.35),
          ),
          if (m.unclassifiedItems.isNotEmpty) ...[
            const SizedBox(height: 12),
            _classifyBanner(m.unclassifiedItems.length),
          ],
          const SizedBox(height: 18),
          _sectionTitle(context.tr('Операции', 'Shop activity')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _kpiCard(
                  'Новые заявки'.tr,
                  '${m.createdCount}',
                  Colors.blueGrey,
                  Icons.post_add,
                  () => _openCreatedJobs(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _kpiCard(
                  'Завершено работ'.tr,
                  '${m.completedCount}',
                  Colors.teal,
                  Icons.task_alt,
                  () => _openCompletedJobs(m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _kpiCard(
                  'Средний чек'.tr,
                  '\$${m.avgTicket.toStringAsFixed(0)}',
                  Colors.indigo,
                  Icons.receipt,
                  () => _openAvgTicket(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _kpiCard(
                  'Собрано'.tr,
                  '${m.collectionRate.toStringAsFixed(0)}%',
                  Colors.green.shade700,
                  Icons.percent,
                  () => _openCollection(m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _sectionTitle(context.tr('Деньги', 'Money')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _moneyCard(
                  'Счета с HST'.tr,
                  m.invoiced,
                  Colors.blue,
                  Icons.receipt_long,
                  () => _openInvoices(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCard(
                  'Получено с HST'.tr,
                  m.paid,
                  Colors.green,
                  Icons.payments,
                  () => _openReceived(m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _moneyCard(
                  'Долг'.tr,
                  m.due,
                  Colors.red,
                  Icons.warning_amber,
                  () => _openDue(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCard(
                  context.tr('Чаевые', 'Tips'),
                  m.tips,
                  const Color(0xFF8E24AA),
                  Icons.volunteer_activism,
                  () => _openTips(m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _sectionTitle(context.tr('Из чего выручка (без HST)', 'Revenue split (no HST)')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _moneyCard(
                  context.tr('Работа и выезд', 'Labour and call-out'),
                  m.labourSales,
                  const Color(0xFF00897B),
                  Icons.handyman_outlined,
                  () => _openLabour(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCard(
                  context.tr('Запчасти клиенту', 'Parts billed'),
                  m.partsSales,
                  const Color(0xFF3949AB),
                  Icons.settings_outlined,
                  () => _openPartsSold(m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _sectionTitle(context.tr('Расходы', 'Costs')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _moneyCard(
                  'Запчасти (себест.)'.tr,
                  m.partsCost,
                  Colors.orange,
                  Icons.inventory_2,
                  () => _openPartsCost(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCard(
                  context.tr('Чеки расходов', 'Receipt expenses'),
                  receipts.operatingTotal,
                  const Color(0xFF6D4C41),
                  Icons.receipt,
                  () => _openReceipts(m, receipts),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _profitCard(m, receipts),
          const SizedBox(height: 30),
          Text(
            'Выручка без HST'.tr,
            style: const TextStyle(
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
                maxY: bars.max == 0 ? 100.0 : bars.max * 1.2,
                barTouchData: const BarTouchData(enabled: false),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (double value, TitleMeta meta) {
                        const style = TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        );
                        final index = value.toInt();
                        final text = index >= 0 && index < bars.labels.length
                            ? bars.labels[index]
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
                  for (var i = 0; i < bars.values.length; i++)
                    _buildBarGroup(i, bars.values[i], bars.max, bars.width),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Color(0xFF14557F),
      ),
    );
  }

  /// Старые счета метки «работа / запчасть» не имеют, и делёж выручки по ним
  /// держится на догадке. Пока такие позиции есть — это видно на экране.
  Widget _classifyBanner(int count) {
    return Material(
      color: const Color(0xFFFFF3CD),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => ClassifyItemsPage.open(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.rule, color: Color(0xFF7A5C00)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${context.tr('Позиций без метки', 'Unlabelled lines')}: $count',
                      style: const TextStyle(
                        color: Color(0xFF7A5C00),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.tr(
                        'Работа это или запчасть, пока решает догадка. Нажмите, чтобы разобрать старые счета.',
                        'Service or part is still a guess there. Tap to classify the old invoices.',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF7A5C00),
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF7A5C00)),
            ],
          ),
        ),
      ),
    );
  }

  /// Итог периода: выручка минус запчасти минус чеки. Отдельной строкой —
  /// чаевые: это не продажа и в прибыль от ремонта они не входят.
  Widget _profitCard(ReportMetrics m, ExpenseRollup receipts) {
    final net = m.grossProfit - receipts.operatingTotal;
    return Material(
      color: const Color(0xFF14557F),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openProfit(m, receipts),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Чистыми за период', 'Net for the period'),
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white54),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '\$${net.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Color(0xFFFCC520),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              _profitRow(
                context.tr('Выручка без HST', 'Revenue excl. HST'),
                m.salesExHst,
              ),
              _profitRow(
                context.tr('− Запчасти (себест.)', '− Parts (cost)'),
                -m.partsCost,
              ),
              _profitRow(
                context.tr('− Расходы по чекам', '− Receipt expenses'),
                -receipts.operatingTotal,
              ),
              if (m.tips > 0.009)
                _profitRow(
                  context.tr('+ Чаевые (сверх ремонта)', '+ Tips (on top)'),
                  m.tips,
                ),
              const SizedBox(height: 8),
              Text(
                context.tr(
                  'Без HST — это деньги компании, не налог. Для CRA цифры в «Для T2».',
                  'HST excluded — this is the company’s money, not tax. CRA figures are in the T2 tab.',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profitRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          Text(
            ReportBreakdownPage.money(amount),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── расшифровки ─────────────────────────────

  String _fmtDay(DateTime date) =>
      DateFormat('d MMM yyyy', AppLocale.instance.dateLocale).format(date);

  String _fmtDayTime(DateTime date) =>
      DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(date);

  String _money(double value) => ReportBreakdownPage.money(value);

  String _invoiceTitle(ReportInvoice inv) {
    final number = inv.number.isEmpty ? '' : '#${inv.number} · ';
    final client = inv.job.clientName.trim();
    return '$number${client.isEmpty ? context.tr('Без имени', 'No name') : client}';
  }

  void _openJob(Job job, {int tab = 0}) {
    AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
        initialTab: tab,
      ),
    );
  }

  BreakdownRow _invoiceRow(ReportInvoice inv) {
    final mark = inv.due <= 0.009
        ? context.tr('оплачен', 'paid')
        : inv.paid > 0.009
            ? '${context.tr('остаток', 'due')} ${_money(inv.due)}'
            : context.tr('не оплачен', 'unpaid');
    return BreakdownRow(
      title: _invoiceTitle(inv),
      subtitle: '${_fmtDay(inv.date)} · ${inv.job.applianceType}',
      amount: inv.total,
      chips: [
        '${context.tr('Без HST', 'Excl. HST')} ${_money(inv.subtotal)}',
        'HST ${_money(inv.tax)}',
        mark,
      ],
      onTap: () => _openJob(inv.job, tab: 1),
    );
  }

  BreakdownRow _itemRow(ReportItem item, {required bool byCost}) {
    final qty = item.qty == item.qty.roundToDouble()
        ? item.qty.toStringAsFixed(0)
        : item.qty.toStringAsFixed(2);
    final number = item.invoiceNumber.isEmpty ? '' : '#${item.invoiceNumber} · ';
    return BreakdownRow(
      title: item.name,
      subtitle: '$number${item.clientName} · ${_fmtDay(item.date)}',
      amount: byCost ? item.cost : item.sold,
      chips: [
        '$qty × ${_money(byCost ? item.unitCost : item.price)}',
        if (item.isPart && byCost)
          '${context.tr('продано за', 'billed')} ${_money(item.sold)}',
        if (item.isPart && !byCost)
          '${context.tr('себест.', 'cost')} ${_money(item.cost)}',
        if (item.isPart)
          '${context.tr('наценка', 'margin')} ${_money(item.margin)}',
      ],
      warning: !item.classified
          ? context.tr(
              'Метки нет — работа это или запчасть, отчёт угадал. Нажмите «Разобрать позиции» выше.',
              'No label — service or part was guessed. Use “Classify lines” above.',
            )
          : item.costGuessed
              ? context.tr(
                  'Себестоимость не указана — взято 40% цены. Проставьте закупку, и цифра станет точной.',
                  'No cost on this part — 40% of price assumed. Set the purchase cost for an exact figure.',
                )
              : null,
    );
  }

  /// Секция «разобрать старые позиции» — её видно там, где догадка искажает
  /// цифру: в запчастях и в работе.
  BreakdownSection _classifySection(ReportMetrics m) {
    final rows = m.unclassifiedItems;
    return BreakdownSection(
      title: context.tr('Без метки — отчёт угадал', 'Unlabelled — guessed'),
      hint: context.tr(
        'У этих позиций никто не выбрал «Работа / Запчасть». Нажмите на любую, чтобы разобрать старые счета.',
        'Nobody picked Service / Part for these. Tap any of them to classify the old invoices.',
      ),
      empty: context.tr(
        'Все позиции периода размечены.',
        'Every line in this period is labelled.',
      ),
      rows: [
        for (final item in rows)
          BreakdownRow(
            title: item.name,
            subtitle:
                '${item.clientName} · ${_fmtDay(item.date)} · ${item.isPart ? context.tr('угадано: запчасть', 'guessed: part') : context.tr('угадано: работа', 'guessed: service')}',
            amount: item.sold,
            onTap: () {
              Navigator.pop(context);
              ClassifyItemsPage.open(context);
            },
          ),
      ],
    );
  }

  void _openCreatedJobs(ReportMetrics m) {
    ReportBreakdownPage.open(
      context,
      title: 'Новые заявки'.tr,
      periodLabel: _periodLabel,
      headline: '${m.createdCount}',
      headlineLabel: context.tr('заявок создано', 'jobs created'),
      color: Colors.blueGrey,
      icon: Icons.post_add,
      explain: [
        context.tr(
          'Сколько карточек заявок появилось в CRM за период — по дате создания, неважно, выполнены они уже или нет.',
          'How many job cards were created in this period, by creation date, finished or not.',
        ),
        context.tr(
          'Денег здесь нет: у новой заявки счёта может ещё не быть.',
          'No money here: a fresh job may have no invoice yet.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Заявки периода', 'Jobs in the period'),
          hint: context.tr(
            'Справа — сколько по заявке выставлено всего, за всё время.',
            'On the right — total invoiced on that job, all time.',
          ),
          empty: context.tr('Новых заявок не было.', 'No new jobs.'),
          rows: [
            for (final row in m.createdJobs)
              BreakdownRow(
                title: row.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : row.job.clientName,
                subtitle:
                    '${_fmtDayTime(row.date)} · ${row.job.applianceType} · ${trAny(row.job.status)}',
                amount: row.invoiced > 0.009 ? row.invoiced : null,
                amountText: row.invoiced > 0.009
                    ? null
                    : context.tr('без счёта', 'no invoice'),
                onTap: () => _openJob(row.job),
              ),
          ],
        ),
      ],
    );
  }

  void _openCompletedJobs(ReportMetrics m) {
    final total = m.completedJobs.fold<double>(0, (s, r) => s + r.invoiced);
    ReportBreakdownPage.open(
      context,
      title: 'Завершено работ'.tr,
      periodLabel: _periodLabel,
      headline: '${m.completedCount}',
      headlineLabel: context.tr('заявок завершено', 'jobs completed'),
      color: Colors.teal,
      icon: Icons.task_alt,
      explain: [
        context.tr(
          'Заявки, у которых дата завершения попала в период и статус — завершающий.',
          'Jobs whose completion date falls in the period and whose status is a closing one.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Завершённые заявки', 'Completed jobs'),
          empty: context.tr('Завершённых заявок нет.', 'No completed jobs.'),
          total: total > 0.009 ? total : null,
          totalLabel: context.tr('Выставлено по ним', 'Invoiced on them'),
          rows: [
            for (final row in m.completedJobs)
              BreakdownRow(
                title: row.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : row.job.clientName,
                subtitle:
                    '${_fmtDayTime(row.date)} · ${row.job.applianceType} · ${trAny(row.job.status)}',
                amount: row.invoiced,
                onTap: () => _openJob(row.job),
              ),
          ],
        ),
      ],
    );
  }

  void _openAvgTicket(ReportMetrics m) {
    ReportBreakdownPage.open(
      context,
      title: 'Средний чек'.tr,
      periodLabel: _periodLabel,
      headline: '\$${m.avgTicket.toStringAsFixed(2)}',
      headlineLabel: context.tr('средний счёт с HST', 'average invoice incl. HST'),
      color: Colors.indigo,
      icon: Icons.receipt,
      explain: [
        context.tr(
          'Все счета периода с HST, делённые на их количество. Сметы не в счёт, отменённые счета тоже.',
          'All invoices of the period including HST, divided by their count. Estimates and cancelled invoices are out.',
        ),
      ],
      formula: [
        (context.tr('Счета с HST', 'Invoices incl. HST'), _money(m.invoiced)),
        (context.tr('Счетов, шт', 'Invoice count'), '${m.invoiceCount}'),
        ('= ${context.tr('Средний чек', 'Average ticket')}', _money(m.avgTicket)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Все счета периода', 'Every invoice in the period'),
          empty: context.tr('Счетов не было.', 'No invoices.'),
          total: m.invoiced,
          rows: [for (final inv in m.invoices) _invoiceRow(inv)],
        ),
      ],
    );
  }

  void _openCollection(ReportMetrics m) {
    final paid = m.invoices.where((i) => i.due <= 0.009).toList();
    final open = m.unpaidInvoices;
    ReportBreakdownPage.open(
      context,
      title: 'Собрано'.tr,
      periodLabel: _periodLabel,
      headline: '${m.collectionRate.toStringAsFixed(0)}%',
      headlineLabel: context.tr('выставленного уже пришло', 'of invoiced is collected'),
      color: Colors.green.shade700,
      icon: Icons.percent,
      explain: [
        context.tr(
          'Доля денег, которые уже пришли, от суммы выставленных счетов. 100% — всё оплачено.',
          'Share of money already received against invoices issued. 100% means everything is paid.',
        ),
        context.tr(
          'Больше 100% бывает, когда в период пришла оплата по счёту прошлого периода.',
          'Over 100% happens when a payment for an older invoice lands in this period.',
        ),
      ],
      formula: [
        (context.tr('Получено с HST', 'Collected incl. HST'), _money(m.paid)),
        (context.tr('Счета с HST', 'Invoices incl. HST'), _money(m.invoiced)),
        ('= ${context.tr('Собрано', 'Collected')}', '${m.collectionRate.toStringAsFixed(1)}%'),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Закрытые счета', 'Settled invoices'),
          empty: context.tr('Полностью оплаченных нет.', 'Nothing fully paid.'),
          rows: [for (final inv in paid) _invoiceRow(inv)],
        ),
        BreakdownSection(
          title: context.tr('Ещё не закрыты', 'Still open'),
          empty: context.tr('Долгов по периоду нет.', 'No open balance.'),
          total: open.fold<double>(0, (s, i) => s + i.due),
          totalLabel: context.tr('Остаток', 'Outstanding'),
          rows: [for (final inv in open) _invoiceRow(inv)],
        ),
      ],
    );
  }

  void _openInvoices(ReportMetrics m) {
    ReportBreakdownPage.open(
      context,
      title: 'Счета с HST'.tr,
      periodLabel: _periodLabel,
      headline: _money(m.invoiced),
      headlineLabel: context.tr('выставлено счетов', 'invoiced'),
      headlineHint: context.tr(
        'Это выставлено, а не получено. Сколько реально пришло — в карточке «Получено с HST».',
        'This is billed, not received. Money actually in is on the Collected card.',
      ),
      color: Colors.blue,
      icon: Icons.receipt_long,
      explain: [
        context.tr(
          'Сумма всех счетов, выписанных внутри периода, вместе с HST. Считаем по дате счёта, а не по дате оплаты.',
          'Total of all invoices issued inside the period, HST included. Counted by invoice date, not payment date.',
        ),
        context.tr(
          'Сметы и отменённые счета сюда не попадают.',
          'Estimates and cancelled invoices are excluded.',
        ),
      ],
      formula: [
        (context.tr('Работа и выезд', 'Labour and call-out'), _money(m.labourSales)),
        (context.tr('Запчасти клиенту', 'Parts billed'), _money(m.partsSales)),
        (context.tr('HST с счетов', 'HST on invoices'), _money(m.hstCollectible)),
        ('= ${context.tr('Счета с HST', 'Invoices incl. HST')}', _money(m.invoiced)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Счета', 'Invoices'),
          hint: context.tr(
            'Нажмите на строку — откроется счёт в заявке.',
            'Tap a row to open the invoice inside the job.',
          ),
          empty: context.tr('Счетов не выставляли.', 'No invoices issued.'),
          total: m.invoiced,
          rows: [for (final inv in m.invoices) _invoiceRow(inv)],
        ),
      ],
    );
  }

  void _openReceived(ReportMetrics m) {
    final repair = m.repairPayments;
    final refunds = m.refundPayments;
    final incoming = repair
        .where((p) => p.amount > 0)
        .fold<double>(0, (s, p) => s + p.amount);
    ReportBreakdownPage.open(
      context,
      title: 'Получено с HST'.tr,
      periodLabel: _periodLabel,
      headline: _money(m.paid),
      headlineLabel: context.tr('пришло денег', 'money received'),
      headlineHint: context.tr(
        'Чаевых здесь нет — они отдельной карточкой. Возвраты вычтены.',
        'Tips are not here — they have their own card. Refunds are subtracted.',
      ),
      color: Colors.green,
      icon: Icons.payments,
      explain: [
        context.tr(
          'Деньги, пришедшие внутри периода, по дате платежа. Счёт мог быть выставлен и раньше.',
          'Money that arrived inside the period, by payment date. The invoice itself may be older.',
        ),
        context.tr(
          'В сумме сидит HST: клиент платит его вместе с ремонтом. Чистая часть — в строке «Без HST».',
          'HST is inside this amount: the client pays it together with the repair. The clean part is the excl. HST line.',
        ),
      ],
      formula: [
        (context.tr('Поступления', 'Payments in'), _money(incoming)),
        if (m.refunds > 0.009)
          (context.tr('Возвраты', 'Refunds'), _money(-m.refunds)),
        ('= ${context.tr('Получено с HST', 'Collected incl. HST')}', _money(m.paid)),
        (context.tr('из них без HST', 'of that, excl. HST'), _money(m.cashExHst)),
        (context.tr('из них HST', 'of that, HST'), _money(m.hstReceived)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Оплаты', 'Payments'),
          empty: context.tr('Денег за период не приходило.', 'No money came in.'),
          total: incoming,
          rows: [
            for (final p in repair.where((p) => p.amount > 0))
              BreakdownRow(
                title: p.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : p.job.clientName,
                subtitle:
                    '${_fmtDayTime(p.date)}${p.number.isEmpty ? '' : ' · #${p.number}'}',
                amount: p.amount,
                chips: [
                  p.method.isEmpty
                      ? context.tr('способ не указан', 'method not set')
                      : p.method,
                  '${context.tr('без HST', 'excl. HST')} ${_money(p.net)}',
                  'HST ${_money(p.hst)}',
                ],
                onTap: () => _openJob(p.job, tab: 1),
              ),
          ],
        ),
        BreakdownSection(
          title: context.tr('Возвраты', 'Refunds'),
          hint: context.tr(
            'Эти деньги ушли обратно клиенту и уже вычтены сверху.',
            'This money went back to the client and is already subtracted above.',
          ),
          empty: context.tr('Возвратов не было.', 'No refunds.'),
          total: refunds.isEmpty ? null : -m.refunds,
          rows: [
            for (final p in refunds)
              BreakdownRow(
                title: p.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : p.job.clientName,
                subtitle:
                    '${_fmtDayTime(p.date)}${p.number.isEmpty ? '' : ' · #${p.number}'}',
                amount: p.amount,
                negative: true,
                chips: [
                  p.method.isEmpty
                      ? context.tr('возврат', 'refund')
                      : p.method,
                ],
                onTap: () => _openJob(p.job, tab: 1),
              ),
          ],
        ),
      ],
    );
  }

  void _openDue(ReportMetrics m) {
    final open = m.unpaidInvoices;
    ReportBreakdownPage.open(
      context,
      title: 'Долг'.tr,
      periodLabel: _periodLabel,
      headline: _money(m.due),
      headlineLabel: context.tr('не оплачено по счетам периода', 'unpaid on this period’s invoices'),
      color: Colors.red,
      icon: Icons.warning_amber,
      explain: [
        context.tr(
          'Сколько осталось получить по счетам, выписанным в этом периоде. Состояние на сегодня: если клиент заплатит завтра, цифра уменьшится.',
          'What is still to be collected on invoices issued in this period. As of today: once the client pays, it drops.',
        ),
        context.tr(
          'Депозит уже вычтен — в строке видно, сколько внесли и сколько осталось.',
          'Deposits are already subtracted — each row shows paid and remaining.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Кто должен', 'Who owes'),
          empty: context.tr('Долгов нет — всё закрыто.', 'No debt — everything is settled.'),
          total: m.due,
          totalLabel: context.tr('Всего долг', 'Total owing'),
          rows: [
            for (final inv in open)
              BreakdownRow(
                title: _invoiceTitle(inv),
                subtitle: '${_fmtDay(inv.date)} · ${inv.job.applianceType}',
                amount: inv.due,
                negative: true,
                chips: [
                  '${context.tr('счёт', 'invoice')} ${_money(inv.total)}',
                  '${context.tr('внесено', 'paid')} ${_money(inv.paid)}',
                  if (inv.job.contactPhone.isNotEmpty) inv.job.contactPhone,
                ],
                onTap: () => _openJob(inv.job, tab: 1),
              ),
          ],
        ),
      ],
    );
  }

  void _openTips(ReportMetrics m) {
    final tips = m.tipPayments;
    ReportBreakdownPage.open(
      context,
      title: context.tr('Чаевые', 'Tips'),
      periodLabel: _periodLabel,
      headline: _money(m.tips),
      headlineLabel: context.tr('чаевых за период', 'tips in the period'),
      headlineHint: context.tr(
        'Чаевые не часть счёта и не облагаются HST, поэтому в «Получено с HST» их нет.',
        'Tips are not part of the invoice and carry no HST, so they are not in Collected.',
      ),
      color: const Color(0xFF8E24AA),
      icon: Icons.volunteer_activism,
      explain: [
        context.tr(
          'Клиент выбирает чаевые на экране оплаты до списания. В заявке они лежат отдельной строкой платежа с методом Tip.',
          'The client picks a tip on the payment screen before the charge. In the job it is a separate payment line with method Tip.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Кто оставил', 'Who tipped'),
          empty: context.tr('Чаевых за период нет.', 'No tips in this period.'),
          total: m.tips,
          rows: [
            for (final p in tips)
              BreakdownRow(
                title: p.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : p.job.clientName,
                subtitle:
                    '${_fmtDayTime(p.date)}${p.number.isEmpty ? '' : ' · #${p.number}'}',
                amount: p.amount,
                onTap: () => _openJob(p.job, tab: 1),
              ),
          ],
        ),
      ],
    );
  }

  void _openLabour(ReportMetrics m) {
    final items = m.labourItems;
    ReportBreakdownPage.open(
      context,
      title: context.tr('Работа и выезд', 'Labour and call-out'),
      periodLabel: _periodLabel,
      headline: _money(m.labourSales),
      headlineLabel: context.tr('работа в счетах, без HST', 'labour billed, excl. HST'),
      color: const Color(0xFF00897B),
      icon: Icons.handyman_outlined,
      explain: [
        context.tr(
          'Всё в счетах, что не запчасть: диагностика, выезд, работа. Это чистая выручка — своих затрат у неё нет.',
          'Everything on the invoices that is not a part: diagnostics, call-out, labour. This is clean revenue with no direct cost.',
        ),
        context.tr(
          'Позиция считается запчастью, если у неё стоит себестоимость, она со склада или помечена типом Part.',
          'A line counts as a part when it has a cost, comes from the warehouse, or is typed as Part.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Позиции счетов', 'Invoice lines'),
          empty: context.tr('Работы в счетах не было.', 'No labour lines.'),
          total: m.labourSales,
          rows: [for (final item in items) _itemRow(item, byCost: false)],
        ),
        if (m.unclassifiedItems.isNotEmpty) _classifySection(m),
      ],
    );
  }

  void _openPartsSold(ReportMetrics m) {
    final parts = m.parts;
    ReportBreakdownPage.open(
      context,
      title: context.tr('Запчасти клиенту', 'Parts billed'),
      periodLabel: _periodLabel,
      headline: _money(m.partsSales),
      headlineLabel: context.tr('запчастей продано, без HST', 'parts billed, excl. HST'),
      color: const Color(0xFF3949AB),
      icon: Icons.settings_outlined,
      explain: [
        context.tr(
          'Сколько вы взяли с клиентов за сами запчасти, без HST. Во сколько они обошлись вам — в карточке «Запчасти (себест.)».',
          'What you charged clients for the parts themselves, excl. HST. What they cost you is on the Parts (cost) card.',
        ),
      ],
      formula: [
        (context.tr('Продано запчастей', 'Parts billed'), _money(m.partsSales)),
        (context.tr('Себестоимость', 'Cost'), _money(-m.partsCost)),
        ('= ${context.tr('Наценка на запчастях', 'Parts margin')}', _money(m.partsSales - m.partsCost)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Какие запчасти', 'Which parts'),
          empty: context.tr('Запчастей в счетах нет.', 'No parts on invoices.'),
          total: m.partsSales,
          rows: [for (final item in parts) _itemRow(item, byCost: false)],
        ),
        if (m.unclassifiedItems.isNotEmpty) _classifySection(m),
      ],
    );
  }

  void _openPartsCost(ReportMetrics m) {
    final parts = m.parts;
    final receiptParts =
        _periodExpenses.where((e) => e.category == ExpenseCategories.parts.id).toList();
    final receiptPartsTotal =
        receiptParts.fold<double>(0, (s, e) => s + e.amountExHst);
    ReportBreakdownPage.open(
      context,
      title: 'Запчасти (себест.)'.tr,
      periodLabel: _periodLabel,
      headline: _money(m.partsCost),
      headlineLabel: context.tr('запчасти обошлись', 'parts cost you'),
      headlineHint: context.tr(
        'Это запчасти, списанные по счетам периода, по закупочной цене.',
        'Parts written off on this period’s invoices, at purchase cost.',
      ),
      color: Colors.orange,
      icon: Icons.inventory_2,
      explain: [
        context.tr(
          'Себестоимость берётся из позиции счёта, если она там есть; иначе — со склада; если нигде нет, прикидывается как 40% цены, и такая строка помечена.',
          'Cost comes from the invoice line if present, otherwise from the warehouse; if neither, 40% of price is assumed and the row is flagged.',
        ),
        context.tr(
          'Закупки по чекам — это другая цифра: там деньги, потраченные в магазине, даже если запчасть ещё лежит на складе.',
          'Receipt purchases are a different number: money spent at the shop, even if the part is still on the shelf.',
        ),
      ],
      formula: [
        (context.tr('Списано по счетам', 'Used on invoices'), _money(m.partsCost)),
        (context.tr('Куплено по чекам', 'Bought on receipts'), _money(receiptPartsTotal)),
        (context.tr('Продано клиентам за', 'Billed to clients'), _money(m.partsSales)),
        ('= ${context.tr('Наценка на запчастях', 'Parts margin')}', _money(m.partsSales - m.partsCost)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Списано по счетам', 'Used on invoices'),
          empty: context.tr('Запчастей в счетах нет.', 'No parts on invoices.'),
          total: m.partsCost,
          rows: [for (final item in parts) _itemRow(item, byCost: true)],
        ),
        BreakdownSection(
          title: context.tr('Куплено по чекам', 'Bought on receipts'),
          hint: context.tr(
            'Суммы без HST. В прибыль они не вычитаются второй раз — иначе запчасть ушла бы в расход дважды.',
            'Amounts excl. HST. Not subtracted from profit again — that would expense a part twice.',
          ),
          empty: context.tr('Чеков на запчасти нет.', 'No parts receipts.'),
          total: receiptParts.isEmpty ? null : receiptPartsTotal,
          rows: [
            for (final e in receiptParts)
              BreakdownRow(
                title: e.vendor.isEmpty ? context.tr('Чек', 'Receipt') : e.vendor,
                subtitle: '${_fmtDay(e.date)}${e.note.isEmpty ? '' : ' · ${e.note}'}',
                amount: e.amountExHst,
                chips: ['HST ${_money(e.hst)}'],
              ),
          ],
        ),
        if (m.unclassifiedItems.isNotEmpty) _classifySection(m),
      ],
    );
  }

  void _openReceipts(ReportMetrics m, ExpenseRollup receipts) {
    final items = _periodExpenses
        .where((e) => !e.capitalAsset && e.category != ExpenseCategories.parts.id)
        .toList();
    final capital = _periodExpenses.where((e) => e.capitalAsset).toList();
    ReportBreakdownPage.open(
      context,
      title: context.tr('Чеки расходов', 'Receipt expenses'),
      periodLabel: _periodLabel,
      headline: _money(receipts.operatingTotal),
      headlineLabel: context.tr('расходов по чекам, без HST', 'receipt expenses, excl. HST'),
      color: const Color(0xFF6D4C41),
      icon: Icons.receipt,
      explain: [
        context.tr(
          'Сфотографированные чеки: бензин, страховка, связь, инструмент. Суммы без HST — HST с них возвращается через ITC в GST/HST декларации.',
          'Photographed receipts: fuel, insurance, phone, tools. Amounts excl. HST — the HST comes back as an ITC on the GST/HST return.',
        ),
        context.tr(
          'Еда идёт в расход наполовину, запчасти с чеков и оборудование под CCA в этот итог не входят.',
          'Meals count at 50%; parts receipts and CCA equipment are not in this total.',
        ),
      ],
      formula: [
        for (final line in receipts.operatingLines)
          (
            'GIFI ${line.gifi} · ${AppLocale.instance.isEn ? line.labelEn : line.labelRu}',
            _money(line.amount),
          ),
        ('= ${context.tr('Итого расходы', 'Total expenses')}', _money(receipts.operatingTotal)),
        (context.tr('HST к возврату (ITC)', 'HST to reclaim (ITC)'), _money(receipts.itc)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Чеки', 'Receipts'),
          empty: context.tr(
            'Чеков нет. Снимите их в меню «Расходы» — ИИ сам разложит по статьям.',
            'No receipts. Photograph them under Expenses — the AI files them by category.',
          ),
          total: items.isEmpty ? null : receipts.operatingTotal,
          rows: [
            for (final e in items)
              BreakdownRow(
                title: e.vendor.isEmpty ? context.tr('Чек', 'Receipt') : e.vendor,
                subtitle: '${_fmtDay(e.date)} · ${e.categoryInfo.label(AppLocale.instance.isEn)}',
                amount: e.t2Amount,
                chips: [
                  'GIFI ${e.gifi}',
                  if ((e.t2Amount - e.amountExHst).abs() > 0.009)
                    '${context.tr('с чека', 'on receipt')} ${_money(e.amountExHst)}',
                  'HST ${_money(e.hst)}',
                ],
                onTap: () => _openExpenses(),
              ),
          ],
        ),
        BreakdownSection(
          title: context.tr('Оборудование (CCA)', 'Equipment (CCA)'),
          hint: context.tr(
            'Списывается годами, в расход периода не идёт.',
            'Written off over years, not an expense of this period.',
          ),
          empty: context.tr('Покупок оборудования нет.', 'No equipment purchases.'),
          total: capital.isEmpty ? null : receipts.capitalTotal,
          rows: [
            for (final e in capital)
              BreakdownRow(
                title: e.vendor.isEmpty ? context.tr('Чек', 'Receipt') : e.vendor,
                subtitle: _fmtDay(e.date),
                amount: e.amountExHst,
              ),
          ],
        ),
      ],
    );
  }

  void _openProfit(ReportMetrics m, ExpenseRollup receipts) {
    final net = m.grossProfit - receipts.operatingTotal;
    ReportBreakdownPage.open(
      context,
      title: context.tr('Чистыми за период', 'Net for the period'),
      periodLabel: _periodLabel,
      headline: _money(net),
      headlineLabel: context.tr('заработано чистыми', 'net earnings'),
      headlineHint: context.tr(
        'Это бухгалтерская прибыль по счетам, а не остаток на счёте: часть денег может быть ещё в долгах.',
        'Accounting profit on invoices, not your bank balance: part of it may still be owed to you.',
      ),
      color: const Color(0xFF14557F),
      icon: Icons.savings_outlined,
      explain: [
        context.tr(
          'Считается по счетам периода: выручка без HST минус запчасти по себестоимости минус расходы по чекам.',
          'Based on the period’s invoices: revenue excl. HST, minus parts at cost, minus receipt expenses.',
        ),
        context.tr(
          'HST в прибыль не входит никогда: это деньги CRA, вы их только собираете.',
          'HST is never profit: it is the CRA’s money, you only collect it.',
        ),
        context.tr(
          'Чаевые показаны отдельно — это не продажа ремонта.',
          'Tips are shown separately — they are not repair sales.',
        ),
      ],
      formula: [
        (context.tr('Работа и выезд', 'Labour and call-out'), _money(m.labourSales)),
        (context.tr('Запчасти клиенту', 'Parts billed'), _money(m.partsSales)),
        ('= ${context.tr('Выручка без HST', 'Revenue excl. HST')}', _money(m.salesExHst)),
        ('− ${context.tr('Запчасти (себест.)', 'Parts (cost)')}', _money(-m.partsCost)),
        ('= ${context.tr('Валовая прибыль', 'Gross profit')}', _money(m.grossProfit)),
        ('− ${context.tr('Расходы по чекам', 'Receipt expenses')}', _money(-receipts.operatingTotal)),
        ('= ${context.tr('Чистая прибыль', 'Net profit')}', _money(net)),
        ('+ ${context.tr('Чаевые', 'Tips')}', _money(m.tips)),
        ('= ${context.tr('Всего на руки', 'Total in hand')}', _money(net + m.tips)),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Куда нажать дальше', 'Where to dig deeper'),
          rows: [
            BreakdownRow(
              title: context.tr('Выручка без HST', 'Revenue excl. HST'),
              subtitle: context.tr('по счетам периода', 'from this period’s invoices'),
              amount: m.salesExHst,
              onTap: () {
                Navigator.pop(context);
                _openInvoices(m);
              },
            ),
            BreakdownRow(
              title: 'Запчасти (себест.)'.tr,
              subtitle: context.tr('что списано по счетам', 'written off on invoices'),
              amount: -m.partsCost,
              negative: true,
              onTap: () {
                Navigator.pop(context);
                _openPartsCost(m);
              },
            ),
            BreakdownRow(
              title: context.tr('Расходы по чекам', 'Receipt expenses'),
              subtitle: context.tr('бензин, связь, страховка', 'fuel, phone, insurance'),
              amount: -receipts.operatingTotal,
              negative: true,
              onTap: () {
                Navigator.pop(context);
                _openReceipts(m, receipts);
              },
            ),
            BreakdownRow(
              title: context.tr('Чаевые', 'Tips'),
              subtitle: context.tr('не продажа, сверх ремонта', 'not sales, on top of the repair'),
              amount: m.tips,
              onTap: () {
                Navigator.pop(context);
                _openTips(m);
              },
            ),
          ],
        ),
        BreakdownSection(
          title: context.tr('Деньгами, а не по счетам', 'Cash view, not invoices'),
          hint: context.tr(
            'Прибыль выше — по выставленным счетам. Здесь то, что физически пришло за период.',
            'The profit above is on invoices issued. Here is what physically arrived in the period.',
          ),
          rows: [
            BreakdownRow(
              title: context.tr('Пришло без HST', 'Received excl. HST'),
              amount: m.cashExHst,
            ),
            BreakdownRow(
              title: context.tr('Пришло HST (не ваше)', 'HST received (not yours)'),
              amount: m.hstReceived,
            ),
            BreakdownRow(
              title: context.tr('Ещё должны', 'Still owed to you'),
              amount: m.due,
              negative: true,
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────────── расчёт и график ─────────────────────────────

  ReportMetrics _calculateMetrics(List<DocumentSnapshot> docs) {
    final jobs = <Job>[];
    for (final snap in docs) {
      final data = snap.data() as Map<String, dynamic>? ?? <String, dynamic>{};
      try {
        jobs.add(Job.fromMap(data, snap.id));
      } catch (_) {
        continue;
      }
    }
    return ReportMetrics.build(
      jobs: jobs,
      start: _periodStart,
      endExclusive: _periodEndExclusive,
      warehouseCosts: _warehouseCosts,
    );
  }

  _BarData _bars(ReportMetrics metrics) {
    final buckets = <String, double>{};
    for (final payment in metrics.repairPayments) {
      final key = _bucketKey(payment.date);
      buckets[key] = (buckets[key] ?? 0) + payment.net;
    }
    final labels = <String>[];
    final values = <double>[];
    _fillBuckets(_periodStart, _periodEndExclusive, buckets, labels, values);
    return _BarData(
      labels: labels,
      values: values,
      max: values.fold<double>(0, (m, v) => v > m ? v : m),
      width: _selectedFilter == 'День' ? 6 : 16,
    );
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

  // ───────────────────────────── карточки ─────────────────────────────

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

  Widget _kpiCard(
    String title,
    String value,
    Color color,
    IconData icon,
    VoidCallback onTap,
  ) {
    return _tappableCard(
      onTap: onTap,
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
              const Icon(Icons.chevron_right, size: 16, color: Colors.black26),
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

  Widget _moneyCard(
    String title,
    double amount,
    Color iconColor,
    IconData icon,
    VoidCallback onTap,
  ) {
    return _tappableCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              const Icon(Icons.chevron_right, size: 16, color: Colors.black26),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _tappableCard({required Widget child, required VoidCallback onTap}) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 1.5,
      shadowColor: Colors.grey.shade300,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.insert_chart_outlined, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            'За выбранный период нет данных.'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _BarData {
  final List<String> labels;
  final List<double> values;
  final double max;
  final double width;

  const _BarData({
    required this.labels,
    required this.values,
    required this.max,
    required this.width,
  });
}
