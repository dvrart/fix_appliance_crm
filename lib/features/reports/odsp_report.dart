import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/app_date_picker.dart';
import '../../models/expense.dart';
import '../../models/job.dart';
import '../../services/error_log_service.dart';
import '../../services/expense_service.dart';
import '../../services/firestore_service.dart';
import '../../services/settings_service.dart';
import '../../services/warehouse_service.dart';
import 'report_metrics.dart';

/// Что вошло в строку «Other expenses (specify)» — на форме её просят
/// расшифровать.
class OdspOtherSpec {
  final String labelRu;
  final String labelEn;
  final double amount;

  const OdspOtherSpec({
    required this.labelRu,
    required this.labelEn,
    required this.amount,
  });
}

/// Цифры для месячной формы ODSP «Business Income and Expenses Report»
/// (3083E). Имена строк повторяют английскую форму, чтобы число можно было
/// переписать напротив поля, не переводя в уме.
///
/// Откуда что берётся (решение FIX, 05.11.2026):
/// * доход — ТОЛЬКО безналичные поступления (кредитные/дебетовые карты,
///   e-Transfer, оплата по ссылке Stripe). Наличные платежи и заработок
///   (наценка) с продажи запчастей полностью исключаются (sale of goods = 0).
///   Работа и выезд безналом → service income, чаевые безналом → other
///   business income (HST — не доход), вопрос про GST/HST отвечается тоже по
///   безналичной доле;
/// * расход — ВСЁ: чеки из раздела «Расходы» без HST плюс закупка запчастей
///   по счетам целиком, независимо от того, как клиент расплатился;
///   инструмент-«капитал» (CCA) сюда не входит, это не расход месяца;
/// * километры машины в CRM не хранятся — вписываются на форму от руки.
class OdspReportFigures {
  final String companyName;
  final String hstNumber;
  final DateTime periodStart;
  final DateTime periodEndInclusive;

  /// На форме 0: заработок на запчастях в доход не плюсуется.
  final double saleOfGoods;

  /// Работа и выезд без HST — только оплата картой и e-Transfer (без наличных).
  final double serviceIncome;

  /// Чаевые месяца по карте и e-Transfer (без наличных).
  final double otherIncome;

  /// Закупка запчастей: из счетов плюс сфотографированные чеки запчастей.
  final double costOfGoodsPurchased;
  final double costFromInvoices;
  final double costFromReceipts;

  /// Расходники и инструмент (не CCA).
  final double suppliesAndEquipment;
  final double accountingFees;
  final double advertising;
  final double bankCharges;
  final double vehicleExpense;
  final double rent;
  final double telephone;
  final double businessInsurance;

  /// Прочее + еда + зарплата — на форме это одна строка с расшифровкой.
  final double otherExpenses;
  final List<OdspOtherSpec> otherSpec;

  /// HST с безналичной доли счетов месяца (ответ на вопрос формы).
  final double hstCollected;

  /// Инструмент/оборудование CCA за месяц — подсказка, в расходы не входит.
  final double capitalTotal;
  final int receiptCount;

  const OdspReportFigures({
    required this.companyName,
    required this.hstNumber,
    required this.periodStart,
    required this.periodEndInclusive,
    this.saleOfGoods = 0,
    this.serviceIncome = 0,
    this.otherIncome = 0,
    this.costOfGoodsPurchased = 0,
    this.costFromInvoices = 0,
    this.costFromReceipts = 0,
    this.suppliesAndEquipment = 0,
    this.accountingFees = 0,
    this.advertising = 0,
    this.bankCharges = 0,
    this.vehicleExpense = 0,
    this.rent = 0,
    this.telephone = 0,
    this.businessInsurance = 0,
    this.otherExpenses = 0,
    this.otherSpec = const [],
    this.hstCollected = 0,
    this.capitalTotal = 0,
    this.receiptCount = 0,
  });

  /// HST-номер заведён в настройках документов — значит налог собирается.
  bool get collectsHst => hstNumber.isNotEmpty;

  double get totalIncome => saleOfGoods + serviceIncome + otherIncome;

  double get totalExpenses =>
      costOfGoodsPurchased +
      suppliesAndEquipment +
      accountingFees +
      advertising +
      bankCharges +
      vehicleExpense +
      rent +
      telephone +
      businessInsurance +
      otherExpenses;

  double get netBusinessIncome => totalIncome - totalExpenses;

  /// Название месяца, как пишут на форме: October 2026. Список английских
  /// названий свой, без локали intl — форма всегда английская, независимо
  /// от языка приложения.
  static const _monthNamesEn = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String get periodLabelEn =>
      '${_monthNamesEn[periodStart.month - 1]} ${periodStart.year}';

  String get dateRangeEn =>
      '${DateFormat('yyyy-MM-dd').format(periodStart)} to ${DateFormat('yyyy-MM-dd').format(periodEndInclusive)}';

  /// [metrics] — полный отчёт месяца, из него берутся расходы (закупка
  /// запчастей целиком). В доход идут только оплаты картой и e-Transfer
  /// (`forMethod(ReportPayMethod.card)` + `forMethod(ReportPayMethod.etransfer)`);
  /// наличные в доход не входят. [expenses] — уже отобранные чеки месяца.
  static OdspReportFigures build({
    required String companyName,
    required String hstNumber,
    required DateTime periodStart,
    required DateTime periodEndInclusive,
    required ReportMetrics metrics,
    ReportMetrics? cardMetrics,
    ReportMetrics? etransferMetrics,
    required List<Expense> expenses,
  }) {
    final card = cardMetrics ?? metrics.forMethod(ReportPayMethod.card);
    final etransfer =
        etransferMetrics ?? metrics.forMethod(ReportPayMethod.etransfer);
    double sumCategory(String id) {
      var total = 0.0;
      for (final item in expenses) {
        if (item.category != id || item.capitalAsset) continue;
        total += item.amountExHst;
      }
      return total;
    }

    // Запчасти с чеков складываются с закупкой по счетам: и то и другое —
    // деньги, ушедшие на товар в этом месяце. Разбивка видна на экране, так
    // что двойной учёт (чек той же детали, что и в счёте) можно заметить.
    final partsReceipts = sumCategory(ExpenseCategories.parts.id);

    final other = sumCategory(ExpenseCategories.other.id);
    final meals = sumCategory(ExpenseCategories.meals.id);
    final wages = sumCategory(ExpenseCategories.wages.id);
    final spec = <OdspOtherSpec>[
      if (other > 0.009)
        OdspOtherSpec(
          labelRu: ExpenseCategories.other.labelRu,
          labelEn: ExpenseCategories.other.labelEn,
          amount: other,
        ),
      if (meals > 0.009)
        OdspOtherSpec(
          labelRu: ExpenseCategories.meals.labelRu,
          labelEn: 'Meals (100%)',
          amount: meals,
        ),
      if (wages > 0.009)
        OdspOtherSpec(
          labelRu: ExpenseCategories.wages.labelRu,
          labelEn: ExpenseCategories.wages.labelEn,
          amount: wages,
        ),
    ];

    var capital = 0.0;
    for (final item in expenses) {
      if (item.capitalAsset) capital += item.amountExHst;
    }

    return OdspReportFigures(
      companyName: companyName,
      hstNumber: hstNumber,
      periodStart: periodStart,
      periodEndInclusive: periodEndInclusive,
      saleOfGoods: 0,
      serviceIncome: card.labourSales + etransfer.labourSales,
      otherIncome: card.tips + etransfer.tips,
      costOfGoodsPurchased: metrics.partsCost + partsReceipts,
      costFromInvoices: metrics.partsCost,
      costFromReceipts: partsReceipts,
      suppliesAndEquipment:
          sumCategory(ExpenseCategories.supplies.id) +
              sumCategory(ExpenseCategories.tools.id),
      accountingFees: sumCategory(ExpenseCategories.accounting.id),
      advertising: sumCategory(ExpenseCategories.advertising.id),
      bankCharges: sumCategory(ExpenseCategories.fees.id),
      vehicleExpense: sumCategory(ExpenseCategories.vehicle.id),
      rent: sumCategory(ExpenseCategories.rent.id),
      telephone: sumCategory(ExpenseCategories.phone.id),
      businessInsurance: sumCategory(ExpenseCategories.insurance.id),
      otherExpenses: other + meals + wages,
      otherSpec: spec,
      hstCollected: card.hstCollectible + etransfer.hstCollectible,
      capitalTotal: capital,
      receiptCount: expenses.length,
    );
  }

  static String _m(double v) => v.toStringAsFixed(2);

  /// Текст для буфера: строки ровно в порядке бумажной формы.
  String clipboardText() {
    final hstLine = collectsHst
        ? 'Are you collecting GST/HST? Yes — collected this month: \$${_m(hstCollected)}'
        : 'Are you collecting GST/HST? No';
    final specify = otherSpec.isEmpty
        ? ''
        : ' (${otherSpec.map((s) => '${s.labelEn} \$${_m(s.amount)}').join(', ')})';
    return [
      'ODSP — Business Income and Expenses Report (form 3083E)',
      'Name of Business: $companyName',
      'Report for Period: $periodLabelEn (Month)',
      'Dates: $dateRangeEn',
      '',
      '=== Business Income / Cash Receipts ===',
      'Sale of goods: \$${_m(saleOfGoods)}',
      'Service income: \$${_m(serviceIncome)}',
      'Commissions, fees: \$0.00',
      'Interest income: \$0.00',
      'PST collected: \$0.00',
      'Other business income: \$${_m(otherIncome)}',
      'Total Income: \$${_m(totalIncome)}',
      hstLine,
      '',
      '=== Business Expenses / Cash Expenses (less GST/HST paid) ===',
      'Cost of goods purchased: \$${_m(costOfGoodsPurchased)}',
      'Supplies and equipment: \$${_m(suppliesAndEquipment)}',
      'Repairs and maintenance: \$0.00',
      'Accounting, bookkeeping, legal fees: \$${_m(accountingFees)}',
      'Advertising, business cards: \$${_m(advertising)}',
      'Licences, fees: \$0.00',
      'Delivery, freight, express costs: \$0.00',
      'Bank charges (other than NSF cheques): \$${_m(bankCharges)}',
      'PST submitted to Minister of Finance: \$0.00',
      'Mandatory income tax installments (current year): \$0.00',
      'Approved business loan repayments: \$0.00',
      'Vehicle expense: \$${_m(vehicleExpense)}',
      'Number (#) of business kilometres: fill in by hand',
      'Approved reinvestment: \$0.00',
      'Rent, mortgage, taxes (business only): \$${_m(rent)}',
      'Utilities (heating, water, hydro, business only): \$0.00',
      'Telephone: \$${_m(telephone)}',
      'Business insurance: \$${_m(businessInsurance)}',
      'Other expenses: \$${_m(otherExpenses)}$specify',
      'Total Expenses: \$${_m(totalExpenses)}',
      '',
      'Net Business Income (income less expenses): \$${_m(netBusinessIncome)}',
      'Expenses paid with loan / re-investment money: No',
      if (capitalTotal > 0.009)
        'Note: tools/equipment counted as capital (CCA), not a monthly expense: \$${_m(capitalTotal)}',
      '',
      'Basis: income counts only cashless payments (credit/debit cards, e-Transfer, payment link) — cash payments and parts sales/markup are excluded. Expenses are counted in full.',
      'Numbers from Fix Appliance CRM (invoices + receipts). Copy onto form 3083E.',
    ].join('\n');
  }
}

/// Страница «Отчёт для ODSP»: выбор месяца и готовая форма 3083E.
class OdspReportPage extends StatefulWidget {
  const OdspReportPage({super.key});

  @override
  State<OdspReportPage> createState() => _OdspReportPageState();
}

class _OdspReportPageState extends State<OdspReportPage> {
  /// Форму подают за прошедший месяц (отчёт за октябрь пишут в ноябре),
  /// поэтому по умолчанию открываем предыдущий.
  late DateTime _month = _previousMonth();

  Map<String, double> _warehouseCosts = const {};
  String _hstNumber = '';
  String _companyName = '';
  List<Expense> _expenses = const [];
  StreamSubscription<List<Expense>>? _expenseSub;
  late final _jobsStream = FirestoreService.jobsRef.snapshots();

  static DateTime _previousMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month - 1, 1);
  }

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Отчёт ODSP');
    _loadWarehouseCosts();
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

  Future<void> _loadCompany() async {
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() {
      _hstNumber = docs.hstNumber.trim();
      _companyName = docs.companyName.trim();
    });
  }

  DateTime get _start => DateTime(_month.year, _month.month, 1);

  DateTime get _endExclusive => DateTime(_month.year, _month.month + 1, 1);

  void _shiftMonth(int direction) {
    setState(() {
      _month = DateTime(_month.year, _month.month + direction, 1);
    });
  }

  Future<void> _pickMonth() async {
    final picked = await showAppDateSheet(
      context: context,
      initial: _month,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() => _month = DateTime(picked.year, picked.month, 1));
  }

  OdspReportFigures _figures(List<DocumentSnapshot> docs) {
    final jobs = <Job>[];
    for (final snap in docs) {
      final data = snap.data() as Map<String, dynamic>? ?? <String, dynamic>{};
      try {
        jobs.add(Job.fromMap(data, snap.id));
      } catch (_) {
        continue;
      }
    }
    final metrics = ReportMetrics.build(
      jobs: jobs,
      start: _start,
      endExclusive: _endExclusive,
      warehouseCosts: _warehouseCosts,
    );
    return OdspReportFigures.build(
      companyName: _companyName,
      hstNumber: _hstNumber,
      periodStart: _start,
      periodEndInclusive: _endExclusive.subtract(const Duration(days: 1)),
      metrics: metrics,
      expenses: ExpenseService.inPeriod(_expenses, _start, _endExclusive),
    );
  }

  Future<void> _copy(OdspReportFigures figures) async {
    await Clipboard.setData(ClipboardData(text: figures.clipboardText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Скопировано', 'Copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.tr('Отчёт для ODSP', 'ODSP report'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
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
                  onPressed: () => _shiftMonth(-1),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: Icon(
                      Icons.calendar_month,
                      color: AppColors.primaryOnCard,
                    ),
                    label: Text(
                      DateFormat(
                        'LLLL yyyy',
                        AppLocale.instance.dateLocale,
                      ).format(_month),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                    onPressed: _pickMonth,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.chevron_right,
                    size: 30,
                    color: AppColors.primaryOnCard,
                  ),
                  onPressed: () => _shiftMonth(1),
                ),
              ],
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
                final figures = _figures(snapshot.data?.docs ?? const []);
                return OdspReportView(
                  figures: figures,
                  onCopy: () => _copy(figures),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Заполненная форма 3083E: строки как на бумаге, суммы из CRM.
class OdspReportView extends StatelessWidget {
  final OdspReportFigures figures;
  final VoidCallback? onCopy;

  const OdspReportView({super.key, required this.figures, this.onCopy});

  static Future<void> sharePdf(OdspReportFigures f) async {
    final bytes = await _buildPdf(f);
    final stamp = DateFormat('yyyy_MM').format(f.periodStart);
    await Printing.sharePdf(bytes: bytes, filename: 'ODSP_3083E_$stamp.pdf');
  }

  static Future<Uint8List> _buildPdf(OdspReportFigures f) async {
    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    String m(double v) => v.toStringAsFixed(2);

    pw.Widget line(String label, double amount, {bool bold2 = false}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                label,
                style: pw.TextStyle(
                  font: bold2 ? bold : regular,
                  fontSize: 10,
                ),
              ),
            ),
            pw.Text(
              '\$${m(amount)}',
              style: pw.TextStyle(font: bold, fontSize: bold2 ? 12 : 10),
            ),
          ],
        ),
      );
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(36),
          theme: pw.ThemeData.withFont(base: regular, bold: bold),
        ),
        build: (context) => [
          pw.Text(
            'ODSP — Business Income and Expenses Report (form 3083E)',
            style: pw.TextStyle(
              font: bold,
              fontSize: 15,
              color: const PdfColor.fromInt(0xFF14557F),
            ),
          ),
          pw.SizedBox(height: 6),
          if (f.companyName.isNotEmpty) pw.Text('Name of Business: ${f.companyName}'),
          pw.Text('Report for Period: ${f.periodLabelEn} (Month)'),
          pw.Text('Dates: ${f.dateRangeEn}'),
          pw.SizedBox(height: 8),
          pw.Text(
            'Copy these numbers onto the paper form. Kilometres are not in the CRM — write them by hand.',
            style: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'Business Income / Cash Receipts',
            style: pw.TextStyle(font: bold, fontSize: 13),
          ),
          pw.SizedBox(height: 6),
          line('Sale of goods', f.saleOfGoods),
          line('Service income', f.serviceIncome),
          line('Commissions, fees', 0),
          line('Interest income', 0),
          line('PST collected', 0),
          line('Other business income', f.otherIncome),
          line('Total Income', f.totalIncome, bold2: true),
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
              f.collectsHst
                  ? 'Are you collecting GST/HST? Yes — collected this month: \$${m(f.hstCollected)}'
                  : 'Are you collecting GST/HST? No',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'Business Expenses / Cash Expenses (less GST/HST paid)',
            style: pw.TextStyle(font: bold, fontSize: 13),
          ),
          pw.SizedBox(height: 6),
          line('Cost of goods purchased', f.costOfGoodsPurchased),
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 14, bottom: 3),
            child: pw.Text(
              'from invoices \$${m(f.costFromInvoices)} · from receipts \$${m(f.costFromReceipts)}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ),
          line('Supplies and equipment', f.suppliesAndEquipment),
          line('Repairs and maintenance', 0),
          line('Accounting, bookkeeping, legal fees', f.accountingFees),
          line('Advertising, business cards', f.advertising),
          line('Licences, fees', 0),
          line('Delivery, freight, express costs', 0),
          line('Bank charges (other than NSF cheques)', f.bankCharges),
          line('PST submitted to Minister of Finance', 0),
          line('Mandatory income tax installments (current year)', 0),
          line('Approved business loan repayments', 0),
          line('Vehicle expense', f.vehicleExpense),
          line('Approved reinvestment', 0),
          line('Rent, mortgage, taxes (business only)', f.rent),
          line('Utilities (heating, water, hydro, business only)', 0),
          line('Telephone', f.telephone),
          line('Business insurance', f.businessInsurance),
          line('Other expenses', f.otherExpenses),
          if (f.otherSpec.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 14, bottom: 3),
              child: pw.Text(
                'specify: ${f.otherSpec.map((s) => '${s.labelEn} \$${m(s.amount)}').join(', ')}',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          line('Total Expenses', f.totalExpenses, bold2: true),
          pw.SizedBox(height: 10),
          line(
            'Net Business Income (income less expenses)',
            f.netBusinessIncome,
            bold2: true,
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Number (#) of business kilometres: write by hand. '
            'Expenses paid with loan / re-investment money: No.',
            style: const pw.TextStyle(fontSize: 9),
          ),
          if (f.capitalTotal > 0.009)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                'Tools/equipment counted as capital (CCA), not a monthly expense: \$${m(f.capitalTotal)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),
          pw.SizedBox(height: 10),
          pw.Text(
            'Basis: income counts only cashless payments (credit/debit cards, e-Transfer, payment link) — cash payments and parts sales/markup are excluded. Expenses are counted in full.',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.Text(
            'Numbers from Fix Appliance CRM (invoices + receipts). Not a government form.',
            style: const pw.TextStyle(fontSize: 8),
          ),
        ],
      ),
    );
    return pdf.save();
  }

  @override
  Widget build(BuildContext context) {
    final f = figures;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        _howto(context),
        const SizedBox(height: 16),
        _headerCard(context, f),
        const SizedBox(height: 16),
        _sectionTitle(
          context.tr('Business Income / Cash Receipts', 'Business Income / Cash Receipts'),
        ),
        const SizedBox(height: 10),
        _incomeCard(context, f),
        const SizedBox(height: 16),
        _sectionTitle(
          context.tr('Business Expenses / Cash Expenses', 'Business Expenses / Cash Expenses'),
        ),
        const SizedBox(height: 10),
        _expensesCard(context, f),
        const SizedBox(height: 16),
        _netCard(context, f),
        const SizedBox(height: 16),
        _actions(context, f),
      ],
    );
  }

  Widget _howto(BuildContext context) {
    final steps = <String>[
      context.tr(
        'Форма 3083E помесячная: стрелками сверху выберите месяц отчёта.',
        'Form 3083E is monthly: pick the report month with the arrows above.',
      ),
      context.tr(
        'Доход — только безналичные поступления (карты, e-Transfer, оплата по ссылке) за работу и выезд: наличные платежи и заработок (наценка) на запчастях полностью исключены. Расход — все чеки раздела «Расходы» и вся закупка запчастей.',
        'Income is cashless payments only (cards, e-Transfer, payment link) for labour and call-out: cash payments and parts markup are excluded. Expenses are all receipts and all parts cost.',
      ),
      context.tr(
        'Перепишите числа на бумажную форму, скопируйте текстом или скачайте PDF. Километры машины впишите от руки — их в CRM нет.',
        'Copy the numbers onto the paper form, copy as text, or download the PDF. Vehicle kilometres are written by hand — the CRM has no mileage log.',
      ),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14557F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('Как с этим работать', 'How to use this'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${i + 1}. ${steps[i]}',
                style: const TextStyle(
                  color: Colors.white,
                  height: 1.35,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerCard(BuildContext context, OdspReportFigures f) {
    return _card(
      child: Column(
        children: [
          _infoRow(
            context.tr('Name of Business', 'Name of Business'),
            f.companyName.isEmpty ? 'FIX-APPLIANCE.CA' : f.companyName,
          ),
          _infoRow(
            context.tr('Report for Period', 'Report for Period'),
            f.periodLabelEn,
          ),
          _infoRow(
            context.tr('Total Amount (на форме отмечен месяц)', 'Total Amount (Month is checked)'),
            'Month ☑',
          ),
        ],
      ),
    );
  }

  Widget _incomeCard(BuildContext context, OdspReportFigures f) {
    return _card(
      child: Column(
        children: [
          _moneyRow(
            context,
            'Sale of goods',
            f.saleOfGoods,
            hint: context.tr(
              'доход и наценка с продажи запчастей исключены',
              'parts sales and markup are excluded',
            ),
          ),
          _moneyRow(
            context,
            'Service income',
            f.serviceIncome,
            hint: context.tr(
              'безнал за работу и выезд: карты, e-Transfer, оплата по ссылке (без наличных, без запчастей и без HST)',
              'cashless labour and call-out: cards, e-Transfer, payment link (no cash, no parts, no HST)',
            ),
          ),
          _moneyRow(context, 'Commissions, fees', 0),
          _moneyRow(context, 'Interest income', 0),
          _moneyRow(context, 'PST collected', 0),
          _moneyRow(
            context,
            'Other business income',
            f.otherIncome,
            hint: context.tr(
              'безналичные чаевые (карты, e-Transfer, оплата по ссылке)',
              'cashless tips (cards, e-Transfer, payment link)',
            ),
          ),
          const Divider(),
          _moneyRow(
            context,
            'Total Income',
            f.totalIncome,
            bold: true,
            hint: context.tr(
              'только безнал (карты, e-Transfer, оплата по ссылке) — без наличных и без наценки на запчастях',
              'cashless only (cards, e-Transfer, payment link) — no cash and no parts markup',
            ),
          ),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Are you collecting GST/HST?',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
              Text(
                f.collectsHst ? 'Yes — \$${f.hstCollected.toStringAsFixed(2)}' : 'No',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: AppColors.primaryOnCard,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              f.collectsHst
                  ? context.tr(
                      'Ответ «Да»: в настройках указан HST-номер, сумма — налог с безналичной доли счетов месяца.',
                      'Yes: an HST number is set in settings; the amount is tax on the card and e-Transfer part of the month’s invoices.',
                    )
                  : context.tr(
                      'Ответ «Нет»: HST-номер в настройках не указан.',
                      'No: no HST number in settings.',
                    ),
              style: TextStyle(
                color: AppColors.inkMuted,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expensesCard(BuildContext context, OdspReportFigures f) {
    return _card(
      child: Column(
        children: [
          _moneyRow(
            context,
            'Cost of goods purchased',
            f.costOfGoodsPurchased,
            hint: context.tr(
              'закупка запчастей: по счетам \$${f.costFromInvoices.toStringAsFixed(2)} · по чекам \$${f.costFromReceipts.toStringAsFixed(2)}',
              'parts cost: invoices \$${f.costFromInvoices.toStringAsFixed(2)} · receipts \$${f.costFromReceipts.toStringAsFixed(2)}',
            ),
          ),
          _moneyRow(
            context,
            'Supplies and equipment',
            f.suppliesAndEquipment,
            hint: context.tr('расходники и инструмент', 'supplies and tools'),
          ),
          _moneyRow(context, 'Repairs and maintenance', 0),
          _moneyRow(context, 'Accounting, bookkeeping, legal fees', f.accountingFees),
          _moneyRow(context, 'Advertising, business cards', f.advertising),
          _moneyRow(context, 'Licences, fees', 0),
          _moneyRow(context, 'Delivery, freight, express costs', 0),
          _moneyRow(
            context,
            'Bank charges (other than NSF cheques)',
            f.bankCharges,
            hint: context.tr('комиссии банка и Stripe', 'bank and Stripe fees'),
          ),
          _moneyRow(context, 'PST submitted to Minister of Finance', 0),
          _moneyRow(context, 'Mandatory income tax installments (current year)', 0),
          _moneyRow(context, 'Approved business loan repayments', 0),
          _moneyRow(
            context,
            'Vehicle expense',
            f.vehicleExpense,
            hint: context.tr(
              'машина и бензин; число километров впишите от руки',
              'vehicle and fuel; write kilometres by hand',
            ),
          ),
          _moneyRow(context, 'Approved reinvestment', 0),
          _moneyRow(context, 'Rent, mortgage, taxes (business only)', f.rent),
          _moneyRow(context, 'Utilities (heating, water, hydro, business only)', 0),
          _moneyRow(context, 'Telephone', f.telephone),
          _moneyRow(context, 'Business insurance', f.businessInsurance),
          _moneyRow(
            context,
            'Other expenses (specify)',
            f.otherExpenses,
            hint: f.otherSpec.isEmpty
                ? null
                : f.otherSpec
                    .map(
                      (s) =>
                          '${AppLocale.instance.isEn ? s.labelEn : s.labelRu} \$${s.amount.toStringAsFixed(2)}',
                    )
                    .join(' · '),
          ),
          const Divider(),
          _moneyRow(context, 'Total Expenses', f.totalExpenses, bold: true),
          if (f.capitalTotal > 0.009) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.tr(
                  'Инструмент-«капитал» (CCA) за месяц: \$${f.capitalTotal.toStringAsFixed(2)} — на форму не идёт, это не расход месяца.',
                  'Capital tools/equipment (CCA) this month: \$${f.capitalTotal.toStringAsFixed(2)} — not on the form, not a monthly expense.',
                ),
                style: TextStyle(
                  color: AppColors.inkMuted,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _netCard(BuildContext context, OdspReportFigures f) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF14557F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            context.tr(
              'Net Business Income (income less expenses)',
              'Net Business Income (income less expenses)',
            ),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '\$${f.netBusinessIncome.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Color(0xFFFCC520),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _netRow('Total Income', f.totalIncome),
          _netRow('− Total Expenses', -f.totalExpenses),
          const SizedBox(height: 6),
          Text(
            context.tr(
              'Вопрос «расходы оплачены кредитом / накоплениями?» — ответ No.',
              'The “paid with loan / re-investment money?” question — answer No.',
            ),
            style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _netRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, OdspReportFigures f) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy),
            label: Text(context.tr('Копировать', 'Copy')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () => sharePdf(f),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF14557F),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.ios_share),
            label: Text(context.tr('Скачать PDF', 'Download PDF')),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: AppColors.primaryOnCard,
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13.5,
                color: AppColors.ink,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _moneyRow(
    BuildContext context,
    String label,
    double amount, {
    String? hint,
    bool bold = false,
  }) {
    final zero = amount.abs() <= 0.009;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                    fontSize: 13.5,
                    color: bold
                        ? AppColors.primaryOnCard
                        : zero
                            ? AppColors.inkMuted
                            : AppColors.ink,
                  ),
                ),
              ),
              Text(
                '\$${amount.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: bold ? 17 : 14,
                  color: bold
                      ? AppColors.primaryOnCard
                      : zero
                          ? AppColors.inkMuted
                          : AppColors.ink,
                ),
              ),
            ],
          ),
          if (hint != null && hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint,
                style: TextStyle(
                  color: AppColors.inkMuted,
                  fontSize: 11.5,
                  height: 1.25,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
