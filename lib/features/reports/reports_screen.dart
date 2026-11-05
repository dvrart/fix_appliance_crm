import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/utils/app_date_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/job.dart';
import '../../models/expense.dart';
import '../../services/firestore_service.dart';
import '../../services/settings_service.dart';
import '../../services/stripe_service.dart';
import '../../services/warehouse_service.dart';
import '../../services/expense_service.dart';
import '../../services/job_service.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import 'classify_items_page.dart';
import 'odsp_report.dart';
import 'report_breakdown_page.dart';
import 'report_metrics.dart';
import 'tax_workbook_view.dart';
import 'tax_writeoff_guide_page.dart';
import '../expenses/expenses_screen.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/dispose_on_close.dart';
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
  bool _t2Mode = false;

  /// «HST и налоги» в финансовом отчёте. Выключено (по умолчанию) — суммы
  /// без налога и без строк про HST. Помнится на телефоне.
  static const _showTaxKey = 'reports_show_tax_v1';
  bool _showTax = false;
  ReportPayMethod? _selectedPayMethod;
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
    unawaited(_loadShowTax());
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

  Future<void> _loadShowTax() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_showTaxKey) ?? false;
    if (!mounted || value == _showTax) return;
    setState(() => _showTax = value);
  }

  void _setShowTax(bool value) {
    setState(() => _showTax = value);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool(_showTaxKey, value),
      ),
    );
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

    final salesShare = metrics.salesExHst > 0.009
        ? (less(metrics.salesExHst, metrics.cashSalesExHst) / metrics.salesExHst)
            .clamp(0.0, 1.0)
        : 1.0;

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
      partsSales: withCash
          ? metrics.partsSales
          : metrics.partsSales * salesShare,
      labourSales: withCash
          ? metrics.labourSales
          : metrics.labourSales * salesShare,
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
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: context.tr('Отчёт для ODSP', 'ODSP report'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OdspReportPage()),
            ),
            icon: const Icon(Icons.fact_check_outlined),
          ),
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
            color: AppColors.card,
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
                          color: isSelected ? Colors.white : AppColors.ink,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: const Color(0xFF14557F),
                      backgroundColor: AppColors.cardMuted,
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
            color: AppColors.card,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.chevron_left,
                    size: 30,
                    color: AppColors.primaryOnCard,
                  ),
                  onPressed: () => _shiftPeriod(-1),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: Icon(
                      Icons.calendar_month,
                      color: AppColors.primaryOnCard,
                    ),
                    label: Text(
                      _periodLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                    onPressed: _pickPeriodDate,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.chevron_right,
                    size: 30,
                    color: AppColors.primaryOnCard,
                  ),
                  onPressed: () => _shiftPeriod(1),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: AppColors.card,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(context.tr('Финансовый отчёт', 'Financial report')),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(context.tr('Для T2 / налогов', 'For T2 / tax')),
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

  // ─────────────────────── вкладка «Финансовый отчёт» ───────────────────────

  String _methodTitle(ReportPayMethod? method) {
    switch (method) {
      case null:
        return context.tr('Все способы оплаты', 'All payment methods');
      case ReportPayMethod.cash:
        return context.tr('Наличные', 'Cash');
      case ReportPayMethod.card:
        return context.tr('Кредитка (карта / Stripe)', 'Credit card (Stripe)');
      case ReportPayMethod.etransfer:
        return context.tr(
          'Электронный перевод (e-Transfer)',
          'Electronic transfer (e-Transfer)',
        );
    }
  }

  String _methodShortTitle(ReportPayMethod? method) {
    switch (method) {
      case null:
        return context.tr('Все', 'All');
      case ReportPayMethod.cash:
        return context.tr('Наличные', 'Cash');
      case ReportPayMethod.card:
        return context.tr('Кредитка', 'Credit card');
      case ReportPayMethod.etransfer:
        return context.tr('Эл. перевод', 'e-Transfer');
    }
  }

  Color _methodColor(ReportPayMethod? method) {
    switch (method) {
      case null:
        return const Color(0xFF14557F);
      case ReportPayMethod.cash:
        return const Color(0xFF2E7D32);
      case ReportPayMethod.card:
        return const Color(0xFF5E35B1);
      case ReportPayMethod.etransfer:
        return const Color(0xFF00897B);
    }
  }

  IconData _methodIcon(ReportPayMethod? method) {
    switch (method) {
      case null:
        return Icons.account_balance_wallet_outlined;
      case ReportPayMethod.cash:
        return Icons.payments_outlined;
      case ReportPayMethod.card:
        return Icons.credit_card;
      case ReportPayMethod.etransfer:
        return Icons.account_balance_outlined;
    }
  }

  double _methodNetEarned(ReportMetrics sub) {
    if (sub.salesExHst > 0.009 || sub.partsCost > 0.009) {
      return sub.grossProfit;
    }
    return sub.cashGrossProfit;
  }

  double _methodGrossExHst(ReportMetrics sub) {
    if (sub.salesExHst > 0.009) return sub.salesExHst;
    return sub.cashExHst;
  }

  double _methodGrossInclHst(ReportMetrics sub) {
    if (sub.invoiced > 0.009) return sub.invoiced;
    return sub.paid;
  }

  /// Доля без HST в счетах периода: по ней долг и средний чек показываются
  /// без налога, когда «HST и налоги» выключено.
  double _exHstShare(ReportMetrics m) => m.invoiced > 0.009
      ? (m.salesExHst / m.invoiced).clamp(0.0, 1.0)
      : 1.0;

  Widget _buildActivity(ReportMetrics allMetrics) {
    final receipts = _receipts;
    final hasMethodFilter = _selectedPayMethod != null;
    final m = hasMethodFilter
        ? allMetrics.forMethod(_selectedPayMethod!)
        : allMetrics;
    final bars = _bars(m);
    final tax = _showTax;
    final share = _exHstShare(m);
    final invoicedShown = tax
        ? (hasMethodFilter ? _methodGrossInclHst(m) : m.invoiced)
        : (hasMethodFilter ? _methodGrossExHst(m) : m.salesExHst);
    final paidShown = tax ? m.paid : m.cashExHst;
    final dueShown = tax ? m.due : m.due * share;
    final avgShown = m.invoiceCount <= 0
        ? 0.0
        : (tax ? m.avgTicket : m.salesExHst / m.invoiceCount);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (allMetrics.unclassifiedItems.isNotEmpty) ...[
            _classifyBanner(allMetrics.unclassifiedItems.length),
            const SizedBox(height: 12),
          ],
          _payMethodSelector(allMetrics, receipts),
          const SizedBox(height: 6),
          _taxSwitch(),
          const SizedBox(height: 10),
          _profitCard(m, receipts, allMetrics: allMetrics),
          const SizedBox(height: 18),
          _sectionTitle(context.tr('Деньги', 'Money')),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _moneyCard(
                  tax ? 'Счета с HST'.tr : context.tr('Счета', 'Invoices'),
                  invoicedShown,
                  Colors.blue,
                  Icons.receipt_long,
                  () => _openInvoices(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCard(
                  tax ? 'Получено с HST'.tr : context.tr('Получено', 'Received'),
                  paidShown,
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
                  dueShown,
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
          const SizedBox(height: 18),
          _sectionTitle(context.tr('Из чего выручка', 'Where revenue comes from')),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _moneyCardWithHint(
                  title: context.tr('Работа и выезд', 'Labour and call-out'),
                  amount: m.labourSales,
                  hint: context.tr(
                    '${m.labourItems.length} поз.',
                    '${m.labourItems.length} lines',
                  ),
                  iconColor: const Color(0xFF00897B),
                  icon: Icons.handyman_outlined,
                  onTap: () => _openLabour(m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _moneyCardWithHint(
                  title: context.tr('Запчасти клиенту', 'Parts to clients'),
                  amount: m.partsSales,
                  hint:
                      '${context.tr('Закупка', 'Cost')}: ${_money(m.partsCost)}\n${context.tr('Наценка', 'Margin')}: ${_money(m.partsMargin)}',
                  iconColor: const Color(0xFF3949AB),
                  icon: Icons.sell_outlined,
                  onTap: () => _openPartsSold(m),
                ),
              ),
            ],
          ),
          if (m.hasGuessedCost) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openPartsCost(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 15,
                      color: Color(0xFFB26A00),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        context.tr(
                          'У части деталей нет закупки (взято 40%) — уточнить',
                          'Some parts have no cost (40% assumed) — set it',
                        ),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB26A00),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          _sectionTitle(context.tr('Работа', 'Work')),
          const SizedBox(height: 10),
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
                  '\$${avgShown.toStringAsFixed(0)}',
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
          const SizedBox(height: 18),
          _sectionTitle(context.tr('Подробно', 'Details')),
          const SizedBox(height: 10),
          Material(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            elevation: 1.5,
            shadowColor: Colors.black12,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _detailRow(
                  icon: Icons.assignment_outlined,
                  color: const Color(0xFF14557F),
                  title: context.tr('Заявки', 'Jobs'),
                  count: m.invoiceJobs.length,
                  onTap: () => _openJobsBreakdown(m),
                ),
                const Divider(height: 1, indent: 56),
                _detailRow(
                  icon: Icons.receipt_long_outlined,
                  color: const Color(0xFF00897B),
                  title: context.tr('Инвойсы', 'Invoices'),
                  count: m.invoiceCount,
                  onTap: () => _openInvoices(m),
                ),
                const Divider(height: 1, indent: 56),
                _detailRow(
                  icon: Icons.build_circle_outlined,
                  color: const Color(0xFF3949AB),
                  title: context.tr('Детали', 'Parts'),
                  count: m.parts.length,
                  onTap: () => _openAllParts(m),
                ),
                const Divider(height: 1, indent: 56),
                _detailRow(
                  icon: Icons.receipt,
                  color: const Color(0xFF6D4C41),
                  title: context.tr('Чеки расходов', 'Receipts'),
                  count: _periodExpenses.length,
                  onTap: () => _openReceipts(m, receipts),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _buildStripeCard(),
          const SizedBox(height: 12),
          _buildOpenT2Card(),
          const SizedBox(height: 26),
          Text(
            tax ? 'Выручка без HST'.tr : context.tr('Выручка', 'Revenue'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryOnCard,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 250,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
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

  /// «HST и налоги»: выключено — все суммы без налога и ни строчки про HST;
  /// включено — суммы с HST и отдельные строки налога.
  Widget _taxSwitch() {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _setShowTax(!_showTax),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              Icon(
                Icons.percent_rounded,
                size: 18,
                color: _showTax ? AppColors.primaryOnCard : AppColors.inkMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('HST и налоги', 'HST and taxes'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
              Switch(
                value: _showTax,
                onChanged: _setShowTax,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppColors.primaryOnCard,
      ),
    );
  }

  Widget _comparisonLine(
    String label,
    String value, {
    required Color color,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.ink,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: bold ? 15 : 14,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Строка раздела «Подробно»: что внутри и сколько штук. Суммы уже стоят
  /// в карточках выше — здесь их не повторяем.
  Widget _detailRow({
    required IconData icon,
    required Color color,
    required String title,
    required int count,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }

  /// Старые счета метки «работа / запчасть» не имеют, и делёж выручки по ним
  /// держится на догадке. Пока такие позиции есть — это видно на экране.
  Widget _classifyBanner(int count) {
    return Material(
      color: AppColors.tint(const Color(0xFFFFB300), 0.16),
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

  /// Выбор способа оплаты (Все / Наличные / Кредитка / Эл. перевод) с суммами.
  Widget _payMethodSelector(ReportMetrics allMetrics, ExpenseRollup receipts) {
    final options = <ReportPayMethod?>[
      null,
      ReportPayMethod.cash,
      ReportPayMethod.card,
      ReportPayMethod.etransfer,
    ];
    final allNet = allMetrics.grossProfit - receipts.operatingTotal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final method in options)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Builder(
                    builder: (context) {
                      final selected = _selectedPayMethod == method;
                      final sub = method == null
                          ? allMetrics
                          : allMetrics.forMethod(method);
                      final amount = method == null
                          ? allNet
                          : _methodNetEarned(sub);
                      final color = _methodColor(method);
                      return Material(
                        color: selected ? color : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              _selectedPayMethod =
                                  (_selectedPayMethod == method && method != null)
                                      ? null
                                      : method;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected ? color : Colors.grey.shade300,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _methodIcon(method),
                                  size: 17,
                                  color: selected ? Colors.white : color,
                                ),
                                const SizedBox(width: 6),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _methodShortTitle(method),
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        color: selected
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                    Text(
                                      _money(amount),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900,
                                        color: selected ? Colors.white : color,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Итог периода: выручка, минус закупка запчастей и чеки — чистыми.
  /// Строки нажимаются и открывают свою расшифровку, вся карточка — общую.
  /// Строки налога — только при включённом «HST и налоги».
  Widget _profitCard(
    ReportMetrics m,
    ExpenseRollup receipts, {
    required ReportMetrics allMetrics,
  }) {
    final hasMethodFilter = _selectedPayMethod != null;
    final net = hasMethodFilter
        ? _methodNetEarned(m)
        : m.grossProfit - receipts.operatingTotal;
    final cardColor = hasMethodFilter
        ? _methodColor(_selectedPayMethod)
        : const Color(0xFF14557F);
    void openMain() => hasMethodFilter
        ? _openMethodBreakdown(allMetrics, _selectedPayMethod!)
        : _openProfit(m, receipts, allMetrics: allMetrics);
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: openMain,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hasMethodFilter
                          ? '${context.tr('Чистыми', 'Net')} · ${_methodTitle(_selectedPayMethod)}'
                          : context.tr('Чистыми за период', 'Net for the period'),
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
                context.tr('Выручка', 'Revenue'),
                hasMethodFilter ? _methodGrossExHst(m) : m.salesExHst,
                onTap: hasMethodFilter
                    ? openMain
                    : () => _openGross(m, receipts, allMetrics: allMetrics),
              ),
              _profitRow(
                context.tr('− Запчасти (закупка)', '− Parts (my cost)'),
                -m.partsCost,
                onTap: () => _openPartsCost(m),
              ),
              if (!hasMethodFilter)
                _profitRow(
                  context.tr('− Чеки расходов', '− Receipt expenses'),
                  -receipts.operatingTotal,
                  onTap: () => _openReceipts(m, receipts),
                ),
              if (_showTax) ...[
                const Divider(color: Colors.white24, height: 14),
                _profitRow(
                  context.tr('HST в счетах', 'HST on invoices'),
                  m.hstCollectible,
                  muted: true,
                ),
                _profitRow(
                  context.tr('HST получено — отдать CRA', 'HST received — owed to CRA'),
                  m.hstReceived,
                  muted: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _profitRow(
    String label,
    double amount, {
    bool muted = false,
    VoidCallback? onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: muted ? Colors.white70 : Colors.white,
                fontSize: 13,
              ),
            ),
          ),
          Text(
            ReportBreakdownPage.money(amount),
            style: TextStyle(
              color: muted ? Colors.white70 : Colors.white,
              fontSize: 13,
              fontWeight: muted ? FontWeight.w600 : FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
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

  void _openJob(Job job, {int tab = 0, int? openDocumentIndex}) {
    AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
        initialTab: tab,
        openDocumentIndex: openDocumentIndex,
      ),
    );
  }

  BreakdownRow _jobRow(ReportJob row, {bool showNetAsPrimary = true}) {
    final hasInvoices = row.invoices.isNotEmpty || row.invoiced > 0.009;
    return BreakdownRow(
      title: row.job.clientName.trim().isEmpty
          ? context.tr('Без имени', 'No name')
          : row.job.clientName,
      subtitle:
          '${_fmtDay(row.date)} · ${row.job.applianceType} · ${trAny(row.job.status)}',
      amount: hasInvoices
          ? (showNetAsPrimary ? row.netProfit : row.invoiced)
          : null,
      amountText: hasInvoices ? null : context.tr('без счёта', 'no invoice'),
      amountLabel: hasInvoices
          ? (showNetAsPrimary
              ? context.tr('чистыми', 'net')
              : context.tr('с HST', 'incl. HST'))
          : null,
      chips: hasInvoices
          ? [
              '${context.tr('Грязными без HST', 'Gross excl. HST')} ${_money(row.salesExHst)}',
              '${context.tr('С HST', 'Incl. HST')} ${_money(row.invoiced)}',
              '${context.tr('Запчасти мне', 'Parts my cost')} ${_money(row.partsCost)}',
              '${context.tr('Запчасти клиенту', 'Parts client')} ${_money(row.partsSales)}',
              '${context.tr('Работа', 'Labour')} ${_money(row.labourSales)}',
              '${context.tr('Чистыми', 'Net')} ${_money(row.netProfit)}',
              if (row.due > 0.009)
                '${context.tr('долг', 'due')} ${_money(row.due)}',
            ]
          : const [],
      warning: row.hasGuessedCost
          ? context.tr(
              'В этой заявке есть деталь без точной закупки (взято 40% цены). Нажмите, чтобы открыть и уточнить.',
              'This job has a part without exact cost (40% assumed). Tap to open and set it.',
            )
          : null,
      onTap: () => _openSingleJobBreakdown(row),
    );
  }

  BreakdownRow _invoiceRow(ReportInvoice inv, {bool showNetAsPrimary = false}) {
    final mark = inv.due <= 0.009
        ? context.tr('оплачен', 'paid')
        : inv.paid > 0.009
            ? '${context.tr('остаток', 'due')} ${_money(inv.due)}'
            : context.tr('не оплачен', 'unpaid');
    return BreakdownRow(
      title: _invoiceTitle(inv),
      subtitle: '${_fmtDay(inv.date)} · ${inv.job.applianceType}',
      amount: showNetAsPrimary ? inv.netProfit : inv.total,
      amountLabel: showNetAsPrimary
          ? context.tr('чистыми', 'net')
          : context.tr('с HST', 'incl. HST'),
      chips: [
        '${context.tr('Грязными без HST', 'Gross excl. HST')} ${_money(inv.subtotal)}',
        '${context.tr('С HST', 'Incl. HST')} ${_money(inv.total)}',
        '${context.tr('Запчасти мне', 'Parts my cost')} ${_money(inv.partsCost)}',
        '${context.tr('Запчасти клиенту', 'Parts client')} ${_money(inv.partsSales)}',
        '${context.tr('Работа', 'Labour')} ${_money(inv.labourSales)}',
        '${context.tr('Чистыми', 'Net')} ${_money(inv.netProfit)}',
        mark,
      ],
      warning: inv.hasGuessedCost
          ? context.tr(
              'Есть деталь без точной закупки (взято 40%). Нажмите, чтобы посмотреть детали счёта.',
              'Has a part without exact cost (40% assumed). Tap to inspect the invoice lines.',
            )
          : null,
      onTap: () => _openSingleInvoiceBreakdown(inv),
    );
  }

  BreakdownRow _itemRow(
    ReportItem item, {
    required bool byCost,
    bool byMargin = false,
  }) {
    final qty = item.qty == item.qty.roundToDouble()
        ? item.qty.toStringAsFixed(0)
        : item.qty.toStringAsFixed(2);
    final number = item.invoiceNumber.isEmpty ? '' : '#${item.invoiceNumber} · ';
    final amount = !item.isPart
        ? item.sold
        : byMargin
            ? item.margin
            : (byCost ? item.cost : item.sold);
    final amountLabel = !item.isPart
        ? context.tr('работа', 'labour')
        : byMargin
            ? context.tr('наценка', 'margin')
            : (byCost
                ? context.tr('для меня', 'my cost')
                : context.tr('клиенту', 'client'));
    return BreakdownRow(
      title: item.name,
      subtitle: '$number${item.clientName} · ${_fmtDay(item.date)}',
      amount: amount,
      amountLabel: amountLabel,
      chips: [
        if (item.isPart) ...[
          '${context.tr('Для меня', 'My cost')}: $qty × ${_money(item.unitCost)} = ${_money(item.cost)}',
          '${context.tr('Для клиента', 'For client')}: $qty × ${_money(item.price)} = ${_money(item.sold)}',
          '${context.tr('Чистыми с детали', 'Net on part')}: ${_money(item.margin)}',
        ] else
          '${context.tr('Для клиента', 'For client')}: $qty × ${_money(item.price)} = ${_money(item.sold)}',
      ],
      warning: !item.classified
          ? context.tr(
              'Метки нет — работа это или запчасть, отчёт угадал. Нажмите на строку, чтобы указать точно.',
              'No label — service or part was guessed. Tap to set it.',
            )
          : item.costGuessed
              ? context.tr(
                  'Себестоимость не указана — взято 40% цены. Нажмите на деталь, чтобы вписать вашу закупку.',
                  'No cost on this part — 40% of price assumed. Tap the part to enter your purchase cost.',
                )
              : null,
      onTap: () => _openItemSheet(item),
    );
  }

  /// Открыть карточку одной детали/позиции счёта: видно сколько стоила мне,
  /// сколько клиенту, сколько чистыми, можно сразу поправить закупку или
  /// перейти в сам инвойс / заявку.
  Future<void> _openItemSheet(ReportItem item) async {
    final qtyStr = item.qty == item.qty.roundToDouble()
        ? item.qty.toStringAsFixed(0)
        : item.qty.toStringAsFixed(2);
    final costCtrl = TextEditingController(
      text: item.isPart && !item.costGuessed
          ? item.unitCost.toStringAsFixed(2)
          : '',
    );
    var isPart = item.isPart;
    var saving = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return DisposeOnClose(
          disposables: [costCtrl],
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              final typedUnitCost = double.tryParse(
                costCtrl.text.trim().replaceAll(',', '.'),
              );
              final effectiveUnitCost = !isPart
                  ? 0.0
                  : (typedUnitCost ?? (item.price * 0.4));
              final totalMyCost = item.qty * effectiveUnitCost;
              final totalClient = item.sold;
              final netOnPart = totalClient - totalMyCost;
              final isGuess = isPart && typedUnitCost == null;

              Future<void> saveCost() async {
                final job = item.job;
                if (job == null || saving) return;
                if (item.docIndex < 0 || item.docIndex >= job.documents.length) {
                  return;
                }
                setSheet(() => saving = true);
                try {
                  final docs = [
                    for (final d in job.documents) Map<String, dynamic>.from(d),
                  ];
                  final doc = docs[item.docIndex];
                  final rawItems = [
                    for (final line in doc['items'] as List? ?? [])
                      if (line is Map) Map<String, dynamic>.from(line) else line,
                  ];
                  if (item.itemIndex >= 0 && item.itemIndex < rawItems.length) {
                    final raw = rawItems[item.itemIndex];
                    if (raw is Map<String, dynamic>) {
                      raw['type'] = isPart ? 'Part' : 'Service';
                      if (isPart && typedUnitCost != null) {
                        raw['costPrice'] = typedUnitCost;
                      } else if (!isPart) {
                        raw.remove('costPrice');
                      }
                      rawItems[item.itemIndex] = raw;
                      doc['items'] = rawItems;
                      await JobService.updateDocuments(job.id, docs);
                    }
                  }
                  if (!sheetCtx.mounted) return;
                  Navigator.pop(sheetCtx);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        context.tr(
                          'Сохранено — отчёт пересчитан',
                          'Saved — report updated',
                        ),
                      ),
                    ),
                  );
                } finally {
                  if (sheetCtx.mounted) setSheet(() => saving = false);
                }
              }

              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                ),
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.primaryOnCard,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item.invoiceNumber.isEmpty ? '' : 'Invoice #${item.invoiceNumber} · '}${item.clientName} · ${_fmtDay(item.date)}',
                                    style: TextStyle(
                                      color: AppColors.inkMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetCtx),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.cardMuted,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            children: [
                              _comparisonLine(
                                '${ctx.tr('Стоит для клиента', 'Price for client')} ($qtyStr × ${_money(item.price)})',
                                _money(totalClient),
                                color: const Color(0xFF3949AB),
                              ),
                              if (isPart)
                                _comparisonLine(
                                  '${ctx.tr('Стоило для меня', 'My cost')} ($qtyStr × ${_money(effectiveUnitCost)}${isGuess ? ctx.tr(' · прикидка 40%', ' · 40% guess') : ''})',
                                  _money(totalMyCost),
                                  color: Colors.orange.shade900,
                                ),
                              const Divider(height: 14),
                              _comparisonLine(
                                ctx.tr(
                                  'Чистыми заработал на этой позиции',
                                  'Net earned on this line',
                                ),
                                _money(netOnPart),
                                color: const Color(0xFF2E7D32),
                                bold: true,
                              ),
                            ],
                          ),
                        ),
                        if (item.job != null) ...[
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(
                                  value: false,
                                  icon: const Icon(
                                    Icons.handyman_outlined,
                                    size: 18,
                                  ),
                                  label: Text(ctx.tr('Работа', 'Service')),
                                ),
                                ButtonSegment(
                                  value: true,
                                  icon: const Icon(
                                    Icons.settings_outlined,
                                    size: 18,
                                  ),
                                  label: Text(ctx.tr('Запчасть', 'Part')),
                                ),
                              ],
                              selected: {isPart},
                              onSelectionChanged: (next) =>
                                  setSheet(() => isPart = next.first),
                            ),
                          ),
                          if (isPart) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: costCtrl,
                              onChanged: (_) => setSheet(() {}),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: ctx.tr(
                                  'Сколько стоила мне за 1 шт. (закупка)',
                                  'My purchase cost per unit',
                                ),
                                prefixText: '\$ ',
                                helperText: ctx.tr(
                                  'Впишите точную закупочную цену детали и нажмите «Сохранить».',
                                  'Enter the exact purchase cost of the part and tap Save.',
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: saving ? null : saveCost,
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: Text(
                                ctx.tr(
                                  'Сохранить закупку / тип позиции',
                                  'Save cost / line type',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2E7D32),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(sheetCtx);
                                    _openJob(
                                      item.job!,
                                      tab: 1,
                                      openDocumentIndex: item.docIndex,
                                    );
                                  },
                                  icon: const Icon(Icons.receipt_long, size: 18),
                                  label: Text(
                                    ctx.tr('Открыть инвойс', 'Open invoice'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(sheetCtx);
                                    _openJob(item.job!, tab: 0);
                                  },
                                  icon: const Icon(Icons.assignment, size: 18),
                                  label: Text(
                                    ctx.tr('Открыть заявку', 'Open job'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _openSingleJobBreakdown(ReportJob row) {
    final title = row.job.clientName.trim().isEmpty
        ? context.tr('Заявка', 'Job')
        : row.job.clientName;
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: title,
      periodLabel:
          '${_fmtDay(row.date)} · ${row.job.applianceType} · ${trAny(row.job.status)}',
      headline: _money(row.netProfit),
      headlineLabel: context.tr(
        'чистыми заработано по этой заявке',
        'net earned on this job',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(row.salesExHst)} (${context.tr('с HST', 'incl. HST')} ${_money(row.invoiced)}) · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(row.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${_money(row.partsSales)}',
      color: const Color(0xFF14557F),
      icon: Icons.assignment_outlined,
      actionLabel: context.tr('Открыть карточку заявки', 'Open job card'),
      actionIcon: Icons.open_in_new,
      onAction: () => _openJob(row.job),
      formula: [
        (
          context.tr('Грязными (счета с HST)', 'Gross (invoices incl. HST)'),
          _money(row.invoiced),
        ),
        (
          '− ${context.tr('HST (налог)', 'HST (tax)')}',
          _money(-row.tax),
        ),
        (
          '= ${context.tr('Грязными (выручка без HST)', 'Gross (revenue excl. HST)')}',
          _money(row.salesExHst),
        ),
        (
          context.tr('Работа и выезд', 'Labour and call-out'),
          _money(row.labourSales),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          _money(row.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}',
          _money(-row.partsCost),
        ),
        (
          context.tr(
            'Наценка на запчастях (клиенту − мне)',
            'Parts margin (client − cost)',
          ),
          _money(row.partsMargin),
        ),
        (
          '= ${context.tr('Чистыми с этой заявки', 'Net on this job')}',
          _money(row.netProfit),
        ),
        (
          context.tr('Оплачено клиентом (с HST)', 'Paid by client (incl. HST)'),
          _money(row.paid),
        ),
        (
          context.tr(
            'Чистыми деньгами из оплаченного',
            'Net from money received',
          ),
          _money(row.paidNetProfit),
        ),
        if (row.due > 0.009)
          (context.tr('Остаток долга', 'Amount due'), _money(row.due)),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Инвойсы в этой заявке', 'Invoices on this job')} (${row.invoices.length})',
          hint: context.tr(
            'Нажмите на инвойс, чтобы посмотреть его разбор или открыть в заявке.',
            'Tap an invoice to inspect its breakdown or open it in the job.',
          ),
          empty: context.tr('Счетов по заявке нет.', 'No invoices on this job.'),
          total: row.invoices.isEmpty ? null : row.invoiced,
          totalLabel: context.tr('Всего по счетам с HST', 'Total incl. HST'),
          rows: [for (final inv in row.invoices) _invoiceRow(inv)],
        ),
        BreakdownSection(
          title:
              '${context.tr('Запчасти в этой заявке', 'Parts on this job')} (${row.parts.length})',
          hint: context.tr(
            'Нажмите на деталь, чтобы посмотреть или поправить её закупочную цену.',
            'Tap a part to inspect or edit its purchase cost.',
          ),
          empty: context.tr(
            'Запчастей в этой заявке нет.',
            'No parts on this job.',
          ),
          total: row.parts.isEmpty ? null : row.partsCost,
          totalLabel: context.tr(
            'Потрачено мной на запчасти',
            'My total parts cost',
          ),
          rows: [
            for (final item in row.parts) _itemRow(item, byCost: true),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('Работа и выезд', 'Labour and call-out')} (${row.labourItems.length})',
          empty: context.tr('Позиций работы нет.', 'No labour lines.'),
          total: row.labourItems.isEmpty ? null : row.labourSales,
          totalLabel: context.tr('Итого работа', 'Total labour'),
          rows: [
            for (final item in row.labourItems) _itemRow(item, byCost: false),
          ],
        ),
      ],
    );
  }

  void _openSingleInvoiceBreakdown(ReportInvoice inv) {
    final numLabel = inv.number.isEmpty ? '${inv.docIndex + 1}' : inv.number;
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: 'Invoice #$numLabel',
      periodLabel:
          '${inv.job.clientName} · ${_fmtDay(inv.date)} · ${inv.job.applianceType}',
      headline: _money(inv.netProfit),
      headlineLabel: context.tr(
        'чистыми заработано по этому инвойсу',
        'net earned on this invoice',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(inv.subtotal)} (${context.tr('с HST', 'incl. HST')} ${_money(inv.total)}) · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(inv.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${_money(inv.partsSales)}',
      color: const Color(0xFF00897B),
      icon: Icons.receipt_long,
      actionLabel: context.tr(
        'Открыть этот инвойс в заявке',
        'Open this invoice in job',
      ),
      actionIcon: Icons.open_in_new,
      onAction: () => _openJob(
        inv.job,
        tab: 1,
        openDocumentIndex: inv.docIndex,
      ),
      formula: [
        (
          context.tr('Грязными (счёт с HST)', 'Gross (invoice incl. HST)'),
          _money(inv.total),
        ),
        (
          '− ${context.tr('HST (налог)', 'HST (tax)')}',
          _money(-inv.tax),
        ),
        (
          '= ${context.tr('Грязными (выручка без HST)', 'Gross (revenue excl. HST)')}',
          _money(inv.subtotal),
        ),
        (
          context.tr('Работа и выезд', 'Labour and call-out'),
          _money(inv.labourSales),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          _money(inv.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}',
          _money(-inv.partsCost),
        ),
        (
          context.tr(
            'Наценка на запчастях (клиенту − мне)',
            'Parts margin (client − cost)',
          ),
          _money(inv.partsMargin),
        ),
        (
          '= ${context.tr('Чистыми с этого инвойса', 'Net on this invoice')}',
          _money(inv.netProfit),
        ),
        (
          context.tr('Оплачено клиентом (с HST)', 'Paid by client (incl. HST)'),
          _money(inv.paid),
        ),
        (
          context.tr(
            'Чистыми деньгами из оплаченного',
            'Net from money received',
          ),
          _money(inv.paidNetProfit),
        ),
        if (inv.due > 0.009)
          (context.tr('Остаток долга', 'Amount due'), _money(inv.due)),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Детали (запчасти) в инвойсе', 'Parts on this invoice')} (${inv.parts.length})',
          hint: context.tr(
            'По каждой детали видно: сколько она стоила для меня, сколько для клиента и сколько чистыми принесла. Нажмите на деталь, чтобы изменить закупку.',
            'Each part shows my cost, client price, and net margin. Tap a part to edit its cost.',
          ),
          empty: context.tr(
            'Запчастей в этом инвойсе нет.',
            'No parts on this invoice.',
          ),
          total: inv.parts.isEmpty ? null : inv.partsCost,
          totalLabel: context.tr(
            'Потрачено мной на запчасти',
            'My total parts cost',
          ),
          rows: [for (final item in inv.parts) _itemRow(item, byCost: true)],
        ),
        BreakdownSection(
          title:
              '${context.tr('Работа и выезд в инвойсе', 'Labour on this invoice')} (${inv.labourItems.length})',
          empty: context.tr('Позиций работы нет.', 'No labour lines.'),
          total: inv.labourItems.isEmpty ? null : inv.labourSales,
          totalLabel: context.tr('Итого работа', 'Total labour'),
          rows: [
            for (final item in inv.labourItems) _itemRow(item, byCost: false),
          ],
        ),
      ],
    );
  }

  void _openJobsBreakdown(ReportMetrics m) {
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: context.tr('В каждой заявке', 'Every job'),
      periodLabel: _periodLabel,
      headline: _money(m.grossProfit),
      headlineLabel: context.tr(
        'чистыми по заявкам периода (до чеков)',
        'net across period jobs (before receipts)',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(m.salesExHst)} (${context.tr('с HST', 'incl. HST')} ${_money(m.invoiced)}) · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(m.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${_money(m.partsSales)}',
      color: const Color(0xFF14557F),
      icon: Icons.assignment_outlined,
      explain: [
        context.tr(
          'Каждая заявка, по которой в выбранном периоде выставлен счёт. Под каждой заявкой видно: сколько грязными, сколько стоили запчасти для меня, сколько для клиента и сколько заработано чистыми.',
          'Every job with an invoice in the selected period. Each row shows gross, what parts cost me, what parts cost the client, and net earned.',
        ),
        context.tr(
          'Нажмите на любую заявку, чтобы увидеть все её инвойсы и каждую деталь внутри.',
          'Tap any job to see all its invoices and every part inside.',
        ),
      ],
      formula: [
        (
          context.tr('Грязными (счета с HST)', 'Gross (invoices incl. HST)'),
          _money(m.invoiced),
        ),
        (
          context.tr('Грязными (выручка без HST)', 'Gross (revenue excl. HST)'),
          _money(m.salesExHst),
        ),
        (
          context.tr('Работа и выезд', 'Labour and call-out'),
          _money(m.labourSales),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          _money(m.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}',
          _money(-m.partsCost),
        ),
        (
          '= ${context.tr('Чистыми по заявкам', 'Net on jobs')}',
          _money(m.grossProfit),
        ),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Заявки со счетами', 'Jobs with invoices')} (${m.invoiceJobs.length})',
          hint: context.tr(
            'Справа — ваш чистый заработок по заявке. Нажмите на заявку для подробного просмотра.',
            'On the right — your net profit on the job. Tap a job for details.',
          ),
          empty: context.tr(
            'Заявок со счетами за этот период нет.',
            'No invoiced jobs in this period.',
          ),
          total: m.invoiceJobs.isEmpty ? null : m.grossProfit,
          totalLabel: context.tr('Итого чистыми по заявкам', 'Total net on jobs'),
          rows: [
            for (final row in m.invoiceJobs)
              _jobRow(row, showNetAsPrimary: true),
          ],
        ),
      ],
    );
  }

  void _openAllParts(ReportMetrics m) {
    final parts = m.parts;
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: context.tr('На каждой детали', 'Every part'),
      periodLabel: _periodLabel,
      headline: '+${_money(m.partsMargin)}',
      headlineLabel: context.tr(
        'чистыми заработано на запчастях (наценка)',
        'net earned on parts (margin)',
      ),
      headlineHint:
          '${context.tr('Стоило для меня', 'My cost')}: ${_money(m.partsCost)} · ${context.tr('Стоит для клиента', 'For client')}: ${_money(m.partsSales)} · ${context.tr('Деталей', 'Parts')}: ${parts.length}',
      color: const Color(0xFF3949AB),
      icon: Icons.build_circle_outlined,
      explain: [
        context.tr(
          'Здесь собрана каждая запчасть из всех инвойсов периода. В каждой строке видно: сколько деталь стоила вам (закупка), сколько она стоила клиенту и сколько вы заработали чистыми на этой детали.',
          'Every part from all invoices in the period. Each row shows what the part cost you, what it cost the client, and your net margin.',
        ),
        context.tr(
          'Нажмите на любую деталь, чтобы посмотреть подробности, вписать точную закупочную цену или открыть сам инвойс.',
          'Tap any part to view details, set the exact purchase cost, or open the invoice.',
        ),
      ],
      formula: [
        (
          context.tr(
            'Запчасти — стоит для клиента (в счетах)',
            'Parts — billed to clients',
          ),
          _money(m.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня (закупка)', 'Parts — what it cost me')}',
          _money(-m.partsCost),
        ),
        (
          '= ${context.tr('Чистыми с запчастей (наценка)', 'Net margin on parts')}',
          _money(m.partsMargin),
        ),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Все детали периода', 'All parts in the period')} (${parts.length})',
          hint: context.tr(
            'Нажмите на деталь — откроется её карточка с ценой для вас, ценой для клиента и кнопкой перехода в счёт.',
            'Tap a part to open its card with your cost, client price, and a link to the invoice.',
          ),
          empty: context.tr(
            'Запчастей в счетах за этот период нет.',
            'No parts on invoices in this period.',
          ),
          total: parts.isEmpty ? null : m.partsMargin,
          totalLabel: context.tr(
            'Итого наценка на деталях',
            'Total parts margin',
          ),
          rows: [
            for (final item in parts)
              _itemRow(item, byCost: false, byMargin: true),
          ],
        ),
        if (m.unclassifiedItems.isNotEmpty) _classifySection(m),
      ],
    );
  }

  BreakdownRow _paymentMethodBreakdownRow(
    ReportMetrics allMetrics,
    ReportPayMethod method, {
    required bool showNetAsPrimary,
  }) {
    final sub = allMetrics.forMethod(method);
    final net = _methodNetEarned(sub);
    final grossEx = _methodGrossExHst(sub);
    final grossIncl = _methodGrossInclHst(sub);
    final payCount = sub.repairPayments.where((p) => p.amount > 0).length;
    return BreakdownRow(
      title: _methodTitle(method),
      subtitle:
          '${context.tr('Оплат', 'Payments')}: $payCount · ${context.tr('Инвойсов', 'Invoices')}: ${sub.invoiceCount}',
      amount: showNetAsPrimary ? net : grossEx,
      amountLabel: showNetAsPrimary
          ? context.tr('чистыми', 'net')
          : context.tr('без HST', 'excl. HST'),
      chips: [
        '${context.tr('Грязными без HST', 'Gross excl. HST')} ${_money(grossEx)}',
        '${context.tr('С HST', 'Incl. HST')} ${_money(grossIncl)}',
        '${context.tr('Пришло', 'Received')} ${_money(sub.paid)}',
        '${context.tr('Запчасти мне', 'Parts my cost')} ${_money(sub.partsCost)}',
        '${context.tr('Запчасти клиенту', 'Parts client')} ${_money(sub.partsSales)}',
        '${context.tr('Чистыми', 'Net')} ${_money(net)}',
        if (sub.tips > 0.009)
          '${context.tr('Чаевые', 'Tips')} ${_money(sub.tips)}',
      ],
      onTap: () => _openMethodBreakdown(allMetrics, method),
    );
  }

  BreakdownSection _paymentMethodsBreakdownSection(
    ReportMetrics allMetrics, {
    required bool showNetAsPrimary,
  }) {
    const methods = [
      ReportPayMethod.cash,
      ReportPayMethod.card,
      ReportPayMethod.etransfer,
    ];
    return BreakdownSection(
      title: context.tr(
        'По способам оплаты (наличные, кредитка, эл. перевод)',
        'By payment method (cash, credit card, e-Transfer)',
      ),
      hint: context.tr(
        'Нажмите на способ оплаты, чтобы увидеть все его оплаты, инвойсы, заявки и запчасти.',
        'Tap a payment method to see all its payments, invoices, jobs, and parts.',
      ),
      rows: [
        for (final method in methods)
          _paymentMethodBreakdownRow(
            allMetrics,
            method,
            showNetAsPrimary: showNetAsPrimary,
          ),
      ],
    );
  }

  void _openMethodBreakdown(ReportMetrics allMetrics, ReportPayMethod method) {
    final sub = allMetrics.forMethod(method);
    final net = _methodNetEarned(sub);
    final grossEx = _methodGrossExHst(sub);
    final grossIncl = _methodGrossInclHst(sub);
    final incoming = sub.repairPayments
        .where((p) => p.amount > 0)
        .fold<double>(0, (s, p) => s + p.amount);
    final isCurrentlyFiltered = _selectedPayMethod == method;

    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: _methodTitle(method),
      periodLabel: _periodLabel,
      headline: _money(net),
      headlineLabel: context.tr(
        'чистыми заработано этим способом оплаты',
        'net earned via this payment method',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(grossEx)} (${context.tr('с HST', 'incl. HST')}: ${_money(grossIncl)}) · ${context.tr('Пришло с HST', 'Received incl. HST')}: ${_money(sub.paid)} · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(sub.partsCost)}',
      color: _methodColor(method),
      icon: _methodIcon(method),
      actionLabel: isCurrentlyFiltered
          ? context.tr(
              'Показать в отчёте все способы оплаты',
              'Show all payment methods in report',
            )
          : '${context.tr('Оставить в отчёте только', 'Filter report to')}: ${_methodShortTitle(method)}',
      actionIcon:
          isCurrentlyFiltered ? Icons.filter_alt_off : Icons.filter_alt_outlined,
      onAction: () {
        setState(() {
          _selectedPayMethod = isCurrentlyFiltered ? null : method;
        });
        Navigator.pop(context);
      },
      explain: [
        context.tr(
          'Полный расклад по выбранному способу оплаты (${_methodTitle(method)}): сколько пришло грязными с HST и без HST, сколько стоили запчасти для вас и для клиента, и сколько осталось чистыми.',
          'Full breakdown for ${_methodTitle(method)}: gross incl. and excl. HST, what parts cost you and the client, and net earned.',
        ),
        context.tr(
          'Если один счёт оплачивали двумя способами (например, депозит переводом, а остаток наличными), в каждый способ идёт его точная доля.',
          'If an invoice was split across two methods (e.g. deposit by e-Transfer, balance in cash), each method gets its exact share.',
        ),
      ],
      formula: [
        (
          context.tr('Грязными по счетам (с HST)', 'Invoiced (incl. HST)'),
          _money(sub.invoiced),
        ),
        (
          '− ${context.tr('HST в счетах', 'HST on invoices')}',
          _money(-sub.hstCollectible),
        ),
        (
          '= ${context.tr('Грязными (выручка без HST)', 'Gross (revenue excl. HST)')}',
          _money(sub.salesExHst),
        ),
        (
          context.tr('Работа и выезд', 'Labour and call-out'),
          _money(sub.labourSales),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          _money(sub.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}',
          _money(-sub.partsCost),
        ),
        (
          '= ${context.tr('Чистыми по счетам этого способа', 'Net on invoices for this method')}',
          _money(sub.grossProfit),
        ),
        (
          context.tr('Пришло деньгами за период (с HST)', 'Money received in period (incl. HST)'),
          _money(sub.paid),
        ),
        (
          context.tr('из них без HST (выручка)', 'of that, excl. HST (revenue)'),
          _money(sub.cashExHst),
        ),
        (
          context.tr('из них HST (налог CRA)', 'of that, HST (CRA tax)'),
          _money(sub.hstReceived),
        ),
        (
          '= ${context.tr('Чистыми из полученных денег', 'Net from money received')}',
          _money(sub.cashGrossProfit),
        ),
        if (sub.tips > 0.009)
          ('+ ${context.tr('Чаевые этим способом', 'Tips via this method')}', _money(sub.tips)),
        if (sub.refunds > 0.009)
          ('− ${context.tr('Возвраты этим способом', 'Refunds via this method')}', _money(-sub.refunds)),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Оплаты этим способом', 'Payments via this method')} (${sub.repairPayments.where((p) => p.amount > 0).length})',
          empty: context.tr(
            'Оплат этим способом в выбранном периоде не было.',
            'No payments with this method in the selected period.',
          ),
          total: incoming > 0.009 ? incoming : null,
          totalLabel: context.tr('Итого получено с HST', 'Total received incl. HST'),
          rows: [
            for (final p in sub.repairPayments.where((p) => p.amount > 0))
              BreakdownRow(
                title: p.job.clientName.isEmpty
                    ? context.tr('Без имени', 'No name')
                    : p.job.clientName,
                subtitle:
                    '${_fmtDayTime(p.date)}${p.number.isEmpty ? '' : ' · #${p.number}'}',
                amount: p.amount,
                amountLabel: context.tr('с HST', 'incl. HST'),
                chips: [
                  p.method.isEmpty ? _methodShortTitle(method) : p.method,
                  '${context.tr('без HST', 'excl. HST')} ${_money(p.net)}',
                  'HST ${_money(p.hst)}',
                ],
                onTap: () => _openJob(p.job, tab: 1),
              ),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждой заявке', 'By job')} (${sub.invoiceJobs.length})',
          hint: context.tr(
            'Нажмите на заявку, чтобы увидеть её счета и запчасти.',
            'Tap a job to see its invoices and parts.',
          ),
          empty: context.tr(
            'Заявок с оплатой этим способом нет.',
            'No jobs paid with this method.',
          ),
          total: sub.invoiceJobs.isEmpty ? null : sub.grossProfit,
          totalLabel: context.tr('Чистыми по заявкам', 'Net across jobs'),
          rows: [
            for (final row in sub.invoiceJobs)
              _jobRow(row, showNetAsPrimary: true),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждому инвойсу', 'By invoice')} (${sub.invoices.length})',
          empty: context.tr(
            'Инвойсов с оплатой этим способом нет.',
            'No invoices paid with this method.',
          ),
          total: sub.invoices.isEmpty ? null : sub.grossProfit,
          totalLabel: context.tr('Чистыми по инвойсам', 'Net across invoices'),
          rows: [
            for (final inv in sub.invoices)
              _invoiceRow(inv, showNetAsPrimary: true),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждой детали', 'By part')} (${sub.parts.length})',
          empty: context.tr(
            'Запчастей в этих счетах нет.',
            'No parts on these invoices.',
          ),
          total: sub.parts.isEmpty ? null : sub.partsMargin,
          totalLabel: context.tr(
            'Наценка на запчастях (клиенту − мне)',
            'Parts margin (client − cost)',
          ),
          rows: [
            for (final item in sub.parts)
              _itemRow(item, byCost: false, byMargin: true),
          ],
        ),
        if (sub.tipPayments.isNotEmpty)
          BreakdownSection(
            title: '${context.tr('Чаевые', 'Tips')} (${sub.tipPayments.length})',
            total: sub.tips,
            rows: [
              for (final p in sub.tipPayments)
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
        if (sub.refundPayments.isNotEmpty)
          BreakdownSection(
            title:
                '${context.tr('Возвраты', 'Refunds')} (${sub.refundPayments.length})',
            total: -sub.refunds,
            rows: [
              for (final p in sub.refundPayments)
                BreakdownRow(
                  title: p.job.clientName.isEmpty
                      ? context.tr('Без имени', 'No name')
                      : p.job.clientName,
                  subtitle:
                      '${_fmtDayTime(p.date)}${p.number.isEmpty ? '' : ' · #${p.number}'}',
                  amount: p.amount,
                  negative: true,
                  onTap: () => _openJob(p.job, tab: 1),
                ),
            ],
          ),
      ],
    );
  }

  void _openGross(
    ReportMetrics m,
    ExpenseRollup receipts, {
    ReportMetrics? allMetrics,
  }) {
    final net = m.grossProfit - receipts.operatingTotal;
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: context.tr('Грязными за период', 'Gross for the period'),
      periodLabel: _periodLabel,
      headline: _money(m.salesExHst),
      headlineLabel: context.tr(
        'грязными без HST (с HST: ${_money(m.invoiced)})',
        'gross excl. HST (incl. HST: ${_money(m.invoiced)})',
      ),
      headlineHint:
          '${context.tr('Реально пришло деньгами с HST', 'Cash received incl. HST')}: ${_money(m.paid)} (${context.tr('без HST', 'excl. HST')}: ${_money(m.cashExHst)}) · ${context.tr('Ещё должны', 'Still owed')}: ${_money(m.due)}',
      color: const Color(0xFF1565C0),
      icon: Icons.account_balance_wallet_outlined,
      explain: [
        context.tr(
          'Грязными — это вся выручка до вычета ваших затрат на запчасти и чеки расходов.',
          'Gross is your total revenue before subtracting your part costs and receipt expenses.',
        ),
        context.tr(
          'Выручка компании считается без HST (${_money(m.salesExHst)}), потому что HST (${_money(m.hstCollectible)}) — это налог CRA. Полная сумма счетов с HST — ${_money(m.invoiced)}.',
          'Company revenue is excl. HST (${_money(m.salesExHst)}) because HST (${_money(m.hstCollectible)}) is CRA tax. Total billed incl. HST is ${_money(m.invoiced)}.',
        ),
      ],
      formula: [
        (
          context.tr('Работа и выезд (без HST)', 'Labour and call-out (excl. HST)'),
          _money(m.labourSales),
        ),
        (
          context.tr(
            'Запчасти — цена для клиента (без HST)',
            'Parts — client price (excl. HST)',
          ),
          _money(m.partsSales),
        ),
        (
          '= ${context.tr('Грязными без HST (выручка)', 'Gross excl. HST (revenue)')}',
          _money(m.salesExHst),
        ),
        (
          '+ ${context.tr('HST в счетах', 'HST on invoices')}',
          _money(m.hstCollectible),
        ),
        (
          '= ${context.tr('Грязными с HST (всего по счетам)', 'Gross incl. HST (total billed)')}',
          _money(m.invoiced),
        ),
        (
          '− ${context.tr('Запчасти (стоило для меня)', 'Parts (what it cost me)')}',
          _money(-m.partsCost),
        ),
        (
          '− ${context.tr('Расходы по чекам', 'Receipt expenses')}',
          _money(-receipts.operatingTotal),
        ),
        (
          '= ${context.tr('Чистыми (остаётся вам)', 'Net (what you keep)')}',
          _money(net),
        ),
      ],
      sections: [
        _paymentMethodsBreakdownSection(
          allMetrics ?? m,
          showNetAsPrimary: false,
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждой заявке', 'By job')} (${m.invoiceJobs.length})',
          hint: context.tr(
            'Нажмите на заявку, чтобы увидеть её счета и детали.',
            'Tap a job to see its invoices and parts.',
          ),
          empty: context.tr('Заявок со счетами нет.', 'No jobs with invoices.'),
          total: m.invoiceJobs.isEmpty ? null : m.invoiced,
          totalLabel: context.tr('Грязными с HST', 'Gross incl. HST'),
          rows: [
            for (final row in m.invoiceJobs)
              _jobRow(row, showNetAsPrimary: false),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждому инвойсу', 'By invoice')} (${m.invoiceCount})',
          empty: context.tr('Счетов не было.', 'No invoices.'),
          total: m.invoices.isEmpty ? null : m.invoiced,
          totalLabel: context.tr('Грязными с HST', 'Gross incl. HST'),
          rows: [
            for (final inv in m.invoices)
              _invoiceRow(inv, showNetAsPrimary: false),
          ],
        ),
      ],
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
      showTax: _showTax,
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
          'В каждой строке видно: грязными, сколько ушло на запчасти для меня, сколько для клиента и сколько заработано чистыми.',
          'Each row shows gross, what parts cost me, what parts cost the client, and net earned.',
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Заявки периода', 'Jobs in the period'),
          hint: context.tr(
            'Нажмите на заявку, чтобы открыть её расклад по инвойсам и запчастям.',
            'Tap a job to open its invoice and parts breakdown.',
          ),
          empty: context.tr('Новых заявок не было.', 'No new jobs.'),
          rows: [
            for (final row in m.createdJobs)
              _jobRow(row, showNetAsPrimary: true),
          ],
        ),
      ],
    );
  }

  void _openCompletedJobs(ReportMetrics m) {
    final totalNet =
        m.completedJobs.fold<double>(0, (s, r) => s + r.netProfit);
    final totalGross =
        m.completedJobs.fold<double>(0, (s, r) => s + r.invoiced);
    final totalPartsCost =
        m.completedJobs.fold<double>(0, (s, r) => s + r.partsCost);
    final totalPartsSales =
        m.completedJobs.fold<double>(0, (s, r) => s + r.partsSales);
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
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
      formula: [
        (
          context.tr('Грязными с HST', 'Gross incl. HST'),
          _money(totalGross),
        ),
        (
          context.tr('Запчасти — стоило для меня', 'Parts — my cost'),
          _money(totalPartsCost),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          _money(totalPartsSales),
        ),
        (
          '= ${context.tr('Чистыми по завершённым заявкам', 'Net on completed jobs')}',
          _money(totalNet),
        ),
      ],
      sections: [
        BreakdownSection(
          title: context.tr('Завершённые заявки', 'Completed jobs'),
          empty: context.tr('Завершённых заявок нет.', 'No completed jobs.'),
          total: totalNet > 0.009 ? totalNet : null,
          totalLabel: context.tr('Чистыми по ним', 'Net on them'),
          rows: [
            for (final row in m.completedJobs)
              _jobRow(row, showNetAsPrimary: true),
          ],
        ),
      ],
    );
  }

  void _openAvgTicket(ReportMetrics m) {
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
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
      showTax: _showTax,
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
      showTax: _showTax,
      title: context.tr('Каждый инвойс', 'Every invoice'),
      periodLabel: _periodLabel,
      headline: _money(m.invoiced),
      headlineLabel: context.tr(
        'выставлено счетов с HST (чистыми: ${_money(m.grossProfit)})',
        'invoiced incl. HST (net: ${_money(m.grossProfit)})',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(m.salesExHst)} · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(m.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${_money(m.partsSales)}',
      color: Colors.blue,
      icon: Icons.receipt_long,
      explain: [
        context.tr(
          'Все инвойсы периода. В каждой строке видно: грязными без HST и с HST, сколько стоили запчасти для вас, сколько для клиента, сколько заработано чистыми.',
          'All invoices in the period. Each row shows gross excl. and incl. HST, what parts cost you, what they cost the client, and net earned.',
        ),
        context.tr(
          'Нажмите на любой инвойс, чтобы увидеть каждую деталь внутри или открыть сам счёт в заявке.',
          'Tap any invoice to see every part inside or open the invoice in the job.',
        ),
      ],
      formula: [
        (context.tr('Работа и выезд', 'Labour and call-out'), _money(m.labourSales)),
        (context.tr('Запчасти — стоит для клиента', 'Parts — client price'), _money(m.partsSales)),
        ('= ${context.tr('Грязными без HST', 'Gross excl. HST')}', _money(m.salesExHst)),
        ('+ ${context.tr('HST с счетов', 'HST on invoices')}', _money(m.hstCollectible)),
        ('= ${context.tr('Грязными с HST (всего по счетам)', 'Invoices incl. HST')}', _money(m.invoiced)),
        ('− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}', _money(-m.partsCost)),
        ('= ${context.tr('Чистыми по счетам (до чеков)', 'Net on invoices (before receipts)')}', _money(m.grossProfit)),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Инвойсы периода', 'Invoices in the period')} (${m.invoices.length})',
          hint: context.tr(
            'Нажмите на строку — откроется подробный разбор инвойса со всеми деталями.',
            'Tap a row to open the detailed breakdown of the invoice with all parts.',
          ),
          empty: context.tr('Счетов не выставляли.', 'No invoices issued.'),
          total: m.invoiced,
          totalLabel: context.tr('Всего с HST', 'Total incl. HST'),
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
      showTax: _showTax,
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
        (context.tr('из них без HST (ваша выручка)', 'of that, excl. HST (your revenue)'), _money(m.cashExHst)),
        (context.tr('из них HST (налог CRA)', 'of that, HST (CRA tax)'), _money(m.hstReceived)),
        ('− ${context.tr('Запчасти (стоило для меня)', 'Parts (my cost)')}', _money(-m.partsCost)),
        ('= ${context.tr('Чистыми полученными деньгами (до чеков)', 'Net cash after parts')}', _money(m.cashGrossProfit)),
      ],
      sections: [
        if (_selectedPayMethod == null)
          _paymentMethodsBreakdownSection(m, showNetAsPrimary: false),
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
      showTax: _showTax,
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
                  '${context.tr('запчасти мне', 'parts my cost')} ${_money(inv.partsCost)}',
                  if (inv.job.contactPhone.isNotEmpty) inv.job.contactPhone,
                ],
                onTap: () => _openSingleInvoiceBreakdown(inv),
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
      showTax: _showTax,
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
      showTax: _showTax,
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
          'Нажмите на любую строку, чтобы посмотреть подробности или пометить позицию запчастью.',
          'Tap any line to see details or reclassify it as a part.',
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
      showTax: _showTax,
      title: context.tr(
        'Запчасти: сколько стоит для клиента',
        'Parts: what it costs the client',
      ),
      periodLabel: _periodLabel,
      headline: _money(m.partsSales),
      headlineLabel: context.tr(
        'взято с клиентов за запчасти (без HST)',
        'charged to clients for parts (excl. HST)',
      ),
      headlineHint:
          '${context.tr('Стоило для меня (закупка)', 'Cost to me')}: ${_money(m.partsCost)} · ${context.tr('Чистыми с деталей (наценка)', 'Net margin')}: +${_money(m.partsMargin)}',
      color: const Color(0xFF3949AB),
      icon: Icons.sell_outlined,
      explain: [
        context.tr(
          'Сколько вы выставили клиентам за сами запчасти (без HST). В каждой строке ниже видно и цену для клиента, и вашу закупку, и ваш чистый заработок на детали.',
          'What you billed clients for the parts (excl. HST). Each row below shows the client price, your cost, and your net margin on the part.',
        ),
        context.tr(
          'Нажмите на любую деталь, чтобы посмотреть подробности, поправить закупку или открыть счёт.',
          'Tap any part to view details, edit the purchase cost, or open the invoice.',
        ),
      ],
      formula: [
        (
          context.tr('Стоит для клиента (в счетах)', 'Billed to clients'),
          _money(m.partsSales),
        ),
        (
          '− ${context.tr('Стоило для меня (закупка)', 'What it cost me')}',
          _money(-m.partsCost),
        ),
        (
          '= ${context.tr('Чистыми с запчастей (наценка)', 'Net margin on parts')}',
          _money(m.partsMargin),
        ),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Каждая запчасть (цена для клиента)', 'Every part (client price)')} (${parts.length})',
          empty: context.tr('Запчастей в счетах нет.', 'No parts on invoices.'),
          total: m.partsSales,
          totalLabel: context.tr('Итого для клиента', 'Total for clients'),
          rows: [for (final item in parts) _itemRow(item, byCost: false)],
        ),
        if (m.unclassifiedItems.isNotEmpty) _classifySection(m),
      ],
    );
  }

  void _openPartsCost(ReportMetrics m) {
    final parts = m.parts;
    final receiptParts = _periodExpenses
        .where((e) => e.category == ExpenseCategories.parts.id)
        .toList();
    final receiptPartsTotal =
        receiptParts.fold<double>(0, (s, e) => s + e.amountExHst);
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: context.tr(
        'Запчасти: сколько стоило для меня',
        'Parts: what it cost me',
      ),
      periodLabel: _periodLabel,
      headline: _money(m.partsCost),
      headlineLabel: context.tr(
        'потрачено мной на запчасти (по счетам)',
        'my cost for parts used on invoices',
      ),
      headlineHint:
          '${context.tr('Стоит для клиента', 'Billed to clients')}: ${_money(m.partsSales)} · ${context.tr('Чистыми с деталей (наценка)', 'Net margin')}: +${_money(m.partsMargin)}',
      color: Colors.orange.shade800,
      icon: Icons.inventory_2_outlined,
      explain: [
        context.tr(
          'Сколько стоили лично вам запчасти, поставленные в счетах периода (ваша закупочная цена). Нажмите на любую деталь ниже, чтобы посмотреть или вписать точную закупку.',
          'What the parts used on this period’s invoices cost you personally (your purchase price). Tap any part below to view or enter its exact cost.',
        ),
        context.tr(
          'Себестоимость берётся из позиции счёта, иначе со склада; если нигде не указана — прикидывается как 40% цены и помечается.',
          'Cost comes from the invoice line, otherwise from the warehouse; if neither is set, 40% of price is assumed and flagged.',
        ),
      ],
      formula: [
        (
          context.tr(
            'Стоило для меня (списано по счетам)',
            'My cost (used on invoices)',
          ),
          _money(m.partsCost),
        ),
        (
          context.tr('Стоит для клиента (в счетах)', 'Billed to clients'),
          _money(m.partsSales),
        ),
        (
          '= ${context.tr('Чистыми с запчастей (наценка)', 'Net margin on parts')}',
          _money(m.partsMargin),
        ),
        if (receiptPartsTotal > 0.009)
          (
            context.tr(
              'Чеки магазина запчастей (справочно)',
              'Parts store receipts (reference)',
            ),
            _money(receiptPartsTotal),
          ),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Каждая запчасть (моя закупка)', 'Every part (my cost)')} (${parts.length})',
          hint: context.tr(
            'Справа — сколько деталь стоила вам. Нажмите на деталь, чтобы поправить закупку или открыть инвойс.',
            'On the right — what the part cost you. Tap a part to edit its cost or open the invoice.',
          ),
          empty: context.tr('Запчастей в счетах нет.', 'No parts on invoices.'),
          total: m.partsCost,
          totalLabel: context.tr('Итого стоило для меня', 'Total cost to me'),
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
                onTap: () => _openExpenses(),
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
      showTax: _showTax,
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

  void _openProfit(
    ReportMetrics m,
    ExpenseRollup receipts, {
    ReportMetrics? allMetrics,
  }) {
    final net = m.grossProfit - receipts.operatingTotal;
    final cashNet = m.cashGrossProfit - receipts.operatingTotal;
    ReportBreakdownPage.open(
      context,
      showTax: _showTax,
      title: context.tr('Чистыми за период', 'Net for the period'),
      periodLabel: _periodLabel,
      headline: _money(net),
      headlineLabel: context.tr(
        'заработано чистыми по счетам (деньгами на руках: ${_money(cashNet)})',
        'net earned on invoices (cash in hand: ${_money(cashNet)})',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${_money(m.salesExHst)} (${context.tr('с HST', 'incl. HST')} ${_money(m.invoiced)}) · ${context.tr('Запчасти мне', 'Parts my cost')}: ${_money(m.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${_money(m.partsSales)}',
      color: const Color(0xFF14557F),
      icon: Icons.savings_outlined,
      explain: [
        context.tr(
          'Чистыми — это то, что остаётся вам после вычета закупочной цены всех запчастей (${_money(m.partsCost)}) и расходов по чекам (${_money(receipts.operatingTotal)}).',
          'Net is what stays with you after subtracting the purchase cost of all parts (${_money(m.partsCost)}) and receipt expenses (${_money(receipts.operatingTotal)}).',
        ),
        context.tr(
          'Ниже можно открыть каждый способ оплаты, каждую заявку, каждый инвойс и каждую деталь, чтобы увидеть, откуда сложилась каждая копейка.',
          'Below you can open every payment method, every job, every invoice, and every part to see where every dollar came from.',
        ),
      ],
      formula: [
        (
          context.tr('Грязными (счета с HST)', 'Gross (invoices incl. HST)'),
          _money(m.invoiced),
        ),
        (
          '− ${context.tr('HST в счетах (налог CRA)', 'HST on invoices (CRA tax)')}',
          _money(-m.hstCollectible),
        ),
        (
          '= ${context.tr('Грязными (выручка без HST)', 'Gross (revenue excl. HST)')}',
          _money(m.salesExHst),
        ),
        (
          context.tr('из них работа и выезд', 'of that, labour and call-out'),
          _money(m.labourSales),
        ),
        (
          context.tr('из них запчасти (стоит для клиента)', 'of that, parts (client price)'),
          _money(m.partsSales),
        ),
        (
          '− ${context.tr('Запчасти (стоило для меня / закупка)', 'Parts (what it cost me)')}',
          _money(-m.partsCost),
        ),
        (
          '= ${context.tr('Чистыми после запчастей (валовая прибыль)', 'Net after parts (gross profit)')}',
          _money(m.grossProfit),
        ),
        (
          '− ${context.tr('Расходы по чекам', 'Receipt expenses')}',
          _money(-receipts.operatingTotal),
        ),
        (
          '= ${context.tr('Чистыми заработал (по счетам)', 'Net profit (on invoices)')}',
          _money(net),
        ),
        (
          context.tr('Чистыми из уже пришедших денег (без долгов)', 'Net from money already received'),
          _money(cashNet),
        ),
        if (m.tips > 0.009) ...[
          ('+ ${context.tr('Чаевые', 'Tips')}', _money(m.tips)),
          (
            '= ${context.tr('Всего с чаевыми', 'Total with tips')}',
            _money(net + m.tips),
          ),
        ],
      ],
      sections: [
        _paymentMethodsBreakdownSection(
          allMetrics ?? m,
          showNetAsPrimary: true,
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждой заявке', 'Every job')} (${m.invoiceJobs.length})',
          hint: context.tr(
            'Нажмите на заявку — увидите её грязными, запчасти (для меня и для клиента) и чистыми.',
            'Tap a job to see its gross, parts (my cost and client price) and net.',
          ),
          empty: context.tr('Заявок со счетами нет.', 'No jobs with invoices.'),
          total: m.invoiceJobs.isEmpty ? null : m.grossProfit,
          totalLabel: context.tr('Чистыми по заявкам', 'Net across jobs'),
          rows: [
            for (final row in m.invoiceJobs)
              _jobRow(row, showNetAsPrimary: true),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждому инвойсу', 'Every invoice')} (${m.invoiceCount})',
          hint: context.tr(
            'Нажмите на инвойс — увидите все его позиции и детали.',
            'Tap an invoice to see all its lines and parts.',
          ),
          empty: context.tr('Счетов не выставляли.', 'No invoices issued.'),
          total: m.invoices.isEmpty ? null : m.grossProfit,
          totalLabel: context.tr('Чистыми по инвойсам', 'Net across invoices'),
          rows: [
            for (final inv in m.invoices)
              _invoiceRow(inv, showNetAsPrimary: true),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('По каждой детали', 'Every part')} (${m.parts.length})',
          hint: context.tr(
            'Нажмите на деталь — увидите сколько она стоила вам и клиенту, и сможете поправить закупку.',
            'Tap a part to see what it cost you and the client, and edit its cost.',
          ),
          empty: context.tr('Запчастей в счетах нет.', 'No parts on invoices.'),
          total: m.parts.isEmpty ? null : m.partsMargin,
          totalLabel: context.tr(
            'Наценка на запчастях (клиенту − мне)',
            'Parts margin (client − cost)',
          ),
          rows: [
            for (final item in m.parts)
              _itemRow(item, byCost: false, byMargin: true),
          ],
        ),
        BreakdownSection(
          title: context.tr('Деньгами на руках (касса и банк)', 'Cash in hand'),
          hint: context.tr(
            'Сверху — по выставленным счетам. Здесь — только по деньгам, которые клиенты уже реально заплатили.',
            'Above is based on issued invoices. Here is based only on money already paid by clients.',
          ),
          rows: [
            BreakdownRow(
              title: context.tr('Пришло с HST', 'Received incl. HST'),
              amount: m.paid,
              onTap: () {
                Navigator.pop(context);
                _openReceived(m);
              },
            ),
            BreakdownRow(
              title: context.tr(
                'Пришло грязными без HST (ваша выручка)',
                'Received excl. HST (your revenue)',
              ),
              amount: m.cashExHst,
            ),
            BreakdownRow(
              title: context.tr(
                'Пришло HST (налог CRA, не ваше)',
                'HST received (CRA tax, not yours)',
              ),
              amount: m.hstReceived,
            ),
            BreakdownRow(
              title: context.tr(
                '− Запчасти (стоило для меня)',
                '− Parts (what it cost me)',
              ),
              amount: -m.partsCost,
              negative: true,
              onTap: () {
                Navigator.pop(context);
                _openPartsCost(m);
              },
            ),
            BreakdownRow(
              title: context.tr('− Расходы по чекам', '− Receipt expenses'),
              amount: -receipts.operatingTotal,
              negative: true,
              onTap: () {
                Navigator.pop(context);
                _openReceipts(m, receipts);
              },
            ),
            BreakdownRow(
              title: context.tr(
                '= Чистыми полученными деньгами',
                '= Net from received money',
              ),
              amount: cashNet,
            ),
            BreakdownRow(
              title: context.tr('Ещё должны клиенты', 'Still owed by clients'),
              amount: m.due,
              negative: true,
              onTap: () {
                Navigator.pop(context);
                _openDue(m);
              },
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
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _t2Mode = true),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.primaryOnCard, width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.account_balance, color: AppColors.primaryOnCard),
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
                Icon(Icons.chevron_right, color: AppColors.primaryOnCard),
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
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: AppColors.inkMuted),
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
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: AppColors.inkMuted),
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

  Widget _moneyCardWithHint({
    required String title,
    required double amount,
    required String hint,
    required Color iconColor,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return _tappableCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 17),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: AppColors.inkMuted),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            ReportBreakdownPage.money(amount),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: iconColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(
              color: AppColors.inkMuted,
              fontSize: 11.5,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tappableCard({required Widget child, required VoidCallback onTap}) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      elevation: 1.5,
      shadowColor: Colors.black12,
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
