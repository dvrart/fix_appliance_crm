import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/l10n/app_locale.dart';
import '../../models/expense.dart';
import 'tax_writeoff_guide_page.dart';

/// Цифры из CRM для T2 / GST, без смешивания HST в доход.
class TaxWorkbookFigures {
  final String companyName;
  final String companyAddress;
  final String hstNumber;
  final String periodLabel;
  final DateTime periodStart;
  final DateTime periodEndInclusive;
  final bool isFullYear;
  final double salesExHst;
  final double hstCollectible;
  final double cashExHst;
  final double hstReceived;
  final double partsCost;
  final double inventoryAtCost;
  final double? stripeAvailable;
  final ExpenseRollup receipts;

  const TaxWorkbookFigures({
    required this.companyName,
    required this.companyAddress,
    required this.hstNumber,
    required this.periodLabel,
    required this.periodStart,
    required this.periodEndInclusive,
    required this.isFullYear,
    required this.salesExHst,
    required this.hstCollectible,
    required this.cashExHst,
    required this.hstReceived,
    required this.partsCost,
    required this.inventoryAtCost,
    this.stripeAvailable,
    this.receipts = ExpenseRollup.empty,
  });

  double get grossProfit => salesExHst - partsCost;

  double get profitAfterReceipts => grossProfit - receipts.operatingTotal;

  String get dateRangeEn =>
      '${DateFormat('yyyy-MM-dd').format(periodStart)} to ${DateFormat('yyyy-MM-dd').format(periodEndInclusive)}';
}

class TaxWorkbookView extends StatelessWidget {
  final TaxWorkbookFigures figures;
  final VoidCallback onSwitchToYear;
  final VoidCallback? onOpenExpenses;
  final VoidCallback? onScanReceipt;

  const TaxWorkbookView({
    super.key,
    required this.figures,
    required this.onSwitchToYear,
    this.onOpenExpenses,
    this.onScanReceipt,
  });

  static String clipboardText(TaxWorkbookFigures f) {
    String m(double v) => v.toStringAsFixed(2);
    return [
      'Fix Appliance — T2 / GST workbook from CRM',
      f.companyName,
      if (f.hstNumber.isNotEmpty) 'HST: ${f.hstNumber}',
      'Period: ${f.periodLabel}',
      'Dates: ${f.dateRangeEn}',
      '',
      '=== T2 / UFile T2 / TurboTax Business (GIFI Schedule 125) ===',
      'Do NOT enter HST as income.',
      'SIMPLE METHOD (no full inventory): leave 8300 and 8500 blank.',
      'GIFI 8000  Sales of goods and services (no HST): ${m(f.salesExHst)}',
      'GIFI 8299  Total revenue (usually same as 8000): ${m(f.salesExHst)}',
      'GIFI 8320  Purchases / materials (parts used on invoices): ${m(f.partsCost)}',
      'GIFI 8518  Cost of sales (software often calculates this): ${m(f.partsCost)}',
      'GIFI 8519  Gross profit (check): ${m(f.grossProfit)}',
      if (f.receipts.operatingLines.isNotEmpty) ...[
        '',
        '=== Operating expenses from photographed receipts ===',
        for (final line in f.receipts.operatingLines)
          'GIFI ${line.gifi}  ${line.labelEn}: ${m(line.amount)}',
        'Total receipt expenses (excl. HST, excl. parts/CCA): ${m(f.receipts.operatingTotal)}',
        'Profit after those expenses: ${m(f.profitAfterReceipts)}',
      ],
      if (f.receipts.partsTotal > 0)
        'Parts from receipts (do not also add to 8320 if already in invoices): ${m(f.receipts.partsTotal)}',
      if (f.receipts.capitalTotal > 0)
        'Tools/equipment flagged CCA (not an expense): ${m(f.receipts.capitalTotal)}',
      'Do not also type warehouse stock into 8500 on the simple method.',
      'Warehouse at cost TODAY (only if this date is year-end AND you use inventory): ${m(f.inventoryAtCost)}',
      'GIFI 8300 opening inventory: not in CRM — count at start of the tax year.',
      'Cash received excluding HST (not a T2 GIFI line; for your check): ${m(f.cashExHst)}',
      '',
      '=== GST/HST return (GST34) — separate CRA filing, not T2 ===',
      'Line 101  Sales excluding HST: ${m(f.salesExHst)}',
      'Line 103  HST collectible on invoices: ${m(f.hstCollectible)}',
      'Line 108  ITCs (HST on photographed receipts): ${m(f.receipts.itc)}',
      'HST already received from clients: ${m(f.hstReceived)}',
      'Net HST before other ITCs ≈ 103 minus 108: ${m(f.hstCollectible - f.receipts.itc)}',
      '',
      'Still enter from bank if you did not photograph the receipt: remaining vehicle, rent, wages.',
      'Bookkeeping summary only. Not tax advice.',
    ].join('\n');
  }

  static Future<void> sharePdf(TaxWorkbookFigures f) async {
    final bytes = await _buildPdf(f);
    final year = f.periodStart.year;
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'Fix_Appliance_T2_workbook_$year.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = figures;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        _howto(context),
        if (!f.isFullYear) ...[
          const SizedBox(height: 12),
          _yearBanner(context),
        ],
        const SizedBox(height: 16),
        _sectionTitle(context.tr('1. Как в QuickBooks — прибыль и убыток', '1. Profit and loss (QuickBooks style)')),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'HST в доход не входит. Это то, что корпорация заработала на ремонте, минус запчасти.',
            'HST is not income. This is repair revenue minus parts.',
          ),
          style: const TextStyle(color: Colors.black54, height: 1.35),
        ),
        const SizedBox(height: 10),
        _plCard(context, f),
        const SizedBox(height: 12),
        _receiptActions(context),
        const SizedBox(height: 20),
        _sectionTitle(context.tr('2. Куда вписать в UFile T2 или TurboTax', '2. Where to type it in UFile T2 or TurboTax')),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'Откройте Financial statements → Income statement (GIFI). В обеих программах одни и те же коды CRA.',
            'Open Financial statements → Income statement (GIFI). Both programs use the same CRA codes.',
          ),
          style: const TextStyle(color: Colors.black54, height: 1.35),
        ),
        const SizedBox(height: 10),
        _mappingCard(context, f),
        const SizedBox(height: 20),
        _sectionTitle(context.tr('3. GST/HST — другая декларация', '3. GST/HST — a different return')),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'T2 — налог на прибыль корпорации. GST/HST (GST34) сдаёте отдельно, обычно раз в квартал. Не кладите HST в строку продаж T2.',
            'T2 is corporate income tax. GST/HST (GST34) is filed separately, usually quarterly. Do not put HST into T2 sales.',
          ),
          style: const TextStyle(color: Colors.black54, height: 1.35),
        ),
        const SizedBox(height: 10),
        _gstCard(context, f),
        const SizedBox(height: 20),
        _sectionTitle(context.tr('4. Расходы с чеков', '4. Expenses from receipts')),
        const SizedBox(height: 8),
        _receiptsCard(context, f),
        const SizedBox(height: 16),
        _sectionTitle(context.tr('5. Если чека ещё нет', '5. If you have not photographed it yet')),
        const SizedBox(height: 8),
        _missingCard(context, f),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: () => TaxWriteoffGuidePage.open(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF14557F),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              child: const Icon(Icons.lightbulb_outline),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: clipboardText(f)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.tr('Скопировано', 'Copied'))),
                  );
                },
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
                label: Text(context.tr('PDF для подачи', 'PDF for filing')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _howto(BuildContext context) {
    final steps = <String>[
      context.tr(
        'Выберите налоговый год корпорации (вкладка Год). Если year-end не 31 декабря — поставьте тот период, что в T2.',
        'Select the corporation tax year (Year). If year-end is not December 31, match the T2 period.',
      ),
      context.tr(
        'Откройте UFile T2 или TurboTax Business Incorporation → T2 корпорации → Financial statements → Income statement (GIFI). Коды одинаковые в обеих программах.',
        'Open UFile T2 or TurboTax Business Incorporation → corporation T2 → Financial statements → Income statement (GIFI). Codes are the same in both.',
      ),
      context.tr(
        'Продажи = без HST. HST — только в GST/HST декларацию.',
        'Sales = excluding HST. HST goes only on the GST/HST return.',
      ),
      context.tr(
        'Чеки фотографируйте в меню Расходы. ИИ ставит бензин, страховку, инструмент. В конце года PDF уже с этими строками GIFI.',
        'Photograph receipts under Expenses. AI files fuel, insurance, tools. Year-end PDF already has those GIFI lines.',
      ),
      context.tr(
        'Кнопкой PDF сохраните пакет и держите рядом, пока заполняете программу. Это не налоговая консультация.',
        'Save the PDF and keep it beside you while you fill the software. This is not tax advice.',
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
                style: const TextStyle(color: Colors.white, height: 1.35, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _yearBanner(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF3CD),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onSwitchToYear,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: Color(0xFF7A5C00)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.tr(
                    'Сейчас выбран не год. Для T2 нажмите сюда и поставьте Год.',
                    'This is not a full year. Tap here and switch to Year for T2.',
                  ),
                  style: const TextStyle(
                    color: Color(0xFF7A5C00),
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
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
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: Color(0xFF14557F),
      ),
    );
  }

  Widget _plCard(BuildContext context, TaxWorkbookFigures f) {
    return _card(
      child: Column(
        children: [
          _moneyRow(context.tr('Выручка от ремонта (без HST)', 'Repair sales (no HST)'), f.salesExHst),
          _moneyRow(context.tr('− Запчасти (себестоимость)', '− Parts (cost)'), f.partsCost),
          const Divider(),
          _moneyRow(
            context.tr('Валовая прибыль', 'Gross profit'),
            f.grossProfit,
            bold: true,
          ),
          if (f.receipts.operatingLines.isNotEmpty) ...[
            const Divider(),
            for (final line in f.receipts.operatingLines)
              _moneyRow(
                '− GIFI ${line.gifi} · ${AppLocale.instance.isEn ? line.labelEn : line.labelRu}',
                line.amount,
              ),
            _moneyRow(
              context.tr('Прибыль после чеков', 'Profit after receipts'),
              f.profitAfterReceipts,
              bold: true,
            ),
          ],
          const Divider(),
          _moneyRow(
            context.tr('Деньги с клиентов без HST (проверка, не строка T2)', 'Cash from clients excl. HST (check, not a T2 line)'),
            f.cashExHst,
          ),
          if (f.stripeAvailable != null)
            _moneyRow(
              context.tr('Остаток Stripe (касса, не доход)', 'Stripe balance (cash, not income)'),
              f.stripeAvailable!,
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              f.receipts.operatingLines.isEmpty
                  ? context.tr(
                      'Сфотографируйте чеки — машина, связь, страховка появятся здесь как в QuickBooks.',
                      'Photograph receipts — vehicle, phone, insurance will show here like QuickBooks.',
                    )
                  : context.tr(
                      'Суммы с чеков без HST. Запчасти со счетов уже выше. Чеки запчастей в 8320 не дублируйте.',
                      'Receipt amounts exclude HST. Invoice parts are already above. Do not duplicate parts receipts into 8320.',
                    ),
              style: const TextStyle(color: Colors.black45, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mappingCard(BuildContext context, TaxWorkbookFigures f) {
    final rows = <_MapRow>[
      _MapRow(
        what: context.tr('Продажи ремонта без HST — вписать', 'Repair sales, no HST — type this'),
        amount: f.salesExHst,
        where: context.tr(
          'Income statement → Sales of goods and services',
          'Income statement → Sales of goods and services',
        ),
        gifi: '8000',
      ),
      _MapRow(
        what: context.tr('Итого выручка (часто само)', 'Total revenue (often auto)'),
        amount: f.salesExHst,
        where: context.tr('Total revenue', 'Total revenue'),
        gifi: '8299',
      ),
      _MapRow(
        what: context.tr('Запчасти со счетов — вписать сюда', 'Parts on invoices — type here'),
        amount: f.partsCost,
        where: context.tr(
          'Purchases / cost of materials. Simple method: leave inventory blank.',
          'Purchases / cost of materials. Simple method: leave inventory blank.',
        ),
        gifi: '8320',
      ),
      _MapRow(
        what: context.tr('Себестоимость продаж (проверка)', 'Cost of sales (check)'),
        amount: f.partsCost,
        where: context.tr(
          'Often calculated: 0 + 8320 − 0. Should match parts.',
          'Often calculated: 0 + 8320 − 0. Should match parts.',
        ),
        gifi: '8518',
      ),
      _MapRow(
        what: context.tr('Валовая прибыль (проверка)', 'Gross profit (check)'),
        amount: f.grossProfit,
        where: context.tr('Gross profit / loss = 8000 minus 8518', 'Gross profit / loss = 8000 minus 8518'),
        gifi: '8519',
      ),
    ];
    return _card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              context.tr(
                'Простой способ для T2: вписать 8000 и 8320, склад (8300 и 8500) не трогать. Иначе себестоимость посчитается неправильно.',
                'Simple T2 method: type 8000 and 8320, leave inventory (8300 and 8500) blank. Filling stock as well would distort cost of sales.',
              ),
              style: const TextStyle(color: Colors.black54, height: 1.35, fontSize: 13),
            ),
          ),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 20),
            _mapTile(rows[i]),
          ],
          for (final line in f.receipts.operatingLines) ...[
            const Divider(height: 20),
            _mapTile(
              _MapRow(
                what: AppLocale.instance.isEn ? line.labelEn : line.labelRu,
                amount: line.amount,
                where: context.tr(
                  'Expenses — type this GIFI from photographed receipts',
                  'Expenses — type this GIFI from photographed receipts',
                ),
                gifi: line.gifi,
              ),
            ),
          ],
          const Divider(height: 20),
          _mapTile(
            _MapRow(
              what: context.tr(
                'Склад сегодня — не вписывать в простой метод',
                'Warehouse today — skip on the simple method',
              ),
              amount: f.inventoryAtCost,
              where: context.tr(
                'GIFI 8500 only if this date is year-end and you also have opening stock (8300) and real supplier purchases. CRM has today’s qty × cost, not a year-end count.',
                'GIFI 8500 only if this date is year-end and you also have opening stock (8300) and real supplier purchases. CRM has today’s qty × cost, not a year-end count.',
              ),
              gifi: '8500',
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapTile(_MapRow row) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(row.what, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            Text(
              '\$${row.amount.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'GIFI ${row.gifi}',
          style: const TextStyle(
            color: Color(0xFF14557F),
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        Text(
          row.where,
          style: const TextStyle(color: Colors.black54, fontSize: 12, height: 1.3),
        ),
      ],
    );
  }

  Widget _gstCard(BuildContext context, TaxWorkbookFigures f) {
    return _card(
      child: Column(
        children: [
          _moneyRow(context.tr('GST34 строка 101 · продажи без HST', 'GST34 line 101 · sales excl. HST'), f.salesExHst),
          _moneyRow(
            context.tr('GST34 строка 103 · HST с счетов', 'GST34 line 103 · HST on invoices'),
            f.hstCollectible,
            bold: true,
          ),
          _moneyRow(
            context.tr('GST34 строка 108 · HST с ваших чеков (ITC)', 'GST34 line 108 · HST on your receipts (ITC)'),
            f.receipts.itc,
          ),
          _moneyRow(
            context.tr('К уплате ≈ 103 − 108', 'Amount owing ≈ 103 − 108'),
            f.hstCollectible - f.receipts.itc,
            bold: true,
          ),
          _moneyRow(context.tr('HST уже пришёл от клиентов', 'HST already received'), f.hstReceived),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.tr(
                'Есть чеки без фото — их ITC допишите. Кварталы: янв–мар, апр–июн, июл–сен, окт–дек.',
                'Add ITC for receipts you did not photograph. Quarters: Jan–Mar, Apr–Jun, Jul–Sep, Oct–Dec.',
              ),
              style: const TextStyle(color: Colors.black45, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiptActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onScanReceipt,
            icon: const Icon(Icons.photo_camera),
            label: Text(context.tr('Фото чека', 'Photo receipt')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onOpenExpenses,
            icon: const Icon(Icons.receipt_long),
            label: Text(context.tr('Все расходы', 'All expenses')),
          ),
        ),
      ],
    );
  }

  Widget _receiptsCard(BuildContext context, TaxWorkbookFigures f) {
    if (f.receipts.isEmpty) {
      return _card(
        child: Text(
          context.tr(
            'Пока нет чеков за этот период. Нажмите «Фото чека»: бензин станет 9281, страховка 8690, инструмент 9270.',
            'No receipts in this period yet. Tap Photo receipt: fuel becomes 9281, insurance 8690, tools 9270.',
          ),
          style: const TextStyle(height: 1.35),
        ),
      );
    }
    return _card(
      child: Column(
        children: [
          Text(
            context.tr(
              '${f.receipts.count} чек(ов). В T2 вписываете коды ниже. HST с чеков — строка 108, не расход.',
              '${f.receipts.count} receipt(s). Type the codes below on T2. HST on receipts is line 108, not an expense.',
            ),
            style: const TextStyle(color: Colors.black54, height: 1.35, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final line in f.receipts.operatingLines)
            _moneyRow(
              'GIFI ${line.gifi} · ${AppLocale.instance.isEn ? line.labelEn : line.labelRu}',
              line.amount,
            ),
          const Divider(),
          _moneyRow(
            context.tr('Итого расходы с чеков', 'Total receipt expenses'),
            f.receipts.operatingTotal,
            bold: true,
          ),
          if (f.receipts.partsTotal > 0)
            _moneyRow(
              context.tr('Запчасти с чеков (не дублировать 8320)', 'Parts receipts (do not duplicate 8320)'),
              f.receipts.partsTotal,
            ),
          if (f.receipts.capitalTotal > 0)
            _moneyRow(
              context.tr('Оборудование CCA (не расход года)', 'CCA equipment (not this year’s expense)'),
              f.receipts.capitalTotal,
            ),
        ],
      ),
    );
  }

  Widget _missingCard(BuildContext context, TaxWorkbookFigures f) {
    final filled = {for (final line in f.receipts.operatingLines) line.gifi};
    final items = <String>[
      context.tr('Банковская выписка корпорации за год', 'Corporate bank statement for the year'),
      if (!filled.contains('8715'))
        context.tr('Stripe: выплаты и комиссии (fees — GIFI 8715)', 'Stripe payouts and fees (GIFI 8715)'),
      if (!filled.contains('9281'))
        context.tr('Машина и бензин — GIFI 9281', 'Vehicle and fuel — GIFI 9281'),
      if (!filled.contains('8690'))
        context.tr('Страховка — GIFI 8690', 'Insurance — GIFI 8690'),
      if (!filled.contains('9225'))
        context.tr('Телефон / интернет — GIFI 9225', 'Phone / internet — GIFI 9225'),
      if (!filled.contains('8862'))
        context.tr('Бухгалтер / UFile / TurboTax — GIFI 8862', 'Accountant / UFile / TurboTax — GIFI 8862'),
      if (!filled.contains('8521'))
        context.tr('Реклама — GIFI 8521', 'Advertising — GIFI 8521'),
      if (!filled.contains('8911'))
        context.tr('Аренда, если есть — GIFI 8911', 'Rent, if any — GIFI 8911'),
      if (!filled.contains('9060'))
        context.tr('Зарплата, если платили — GIFI 9060', 'Wages, if paid — GIFI 9060'),
      if (f.receipts.capitalTotal == 0 && !filled.contains('9270'))
        context.tr('Инструменты и оборудование (CCA, не сразу расход)', 'Tools and equipment (CCA, not always an expense)'),
    ];
    if (items.length == 1) {
      items.add(
        context.tr(
          'Основные чеки уже в отчёте. Сверьте с банком, ничего ли не забыли.',
          'Main receipts are already in the report. Check the bank statement for anything missed.',
        ),
      );
    }
    return _card(
      child: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_box_outline_blank, size: 18, color: Colors.black45),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, style: const TextStyle(height: 1.3))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: child,
    );
  }

  Widget _moneyRow(String label, double amount, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                color: bold ? const Color(0xFF14557F) : Colors.black87,
              ),
            ),
          ),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: bold ? 18 : 15,
              color: bold ? const Color(0xFF14557F) : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  static Future<Uint8List> _buildPdf(TaxWorkbookFigures f) async {
    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final pdf = pw.Document();
    pw.Widget moneyRow(String label, String gifi, double amount) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 48,
              child: pw.Text(gifi, style: pw.TextStyle(font: bold, fontSize: 10)),
            ),
            pw.Expanded(
              child: pw.Text(label, style: pw.TextStyle(font: regular, fontSize: 10)),
            ),
            pw.Text(
              '\$${amount.toStringAsFixed(2)}',
              style: pw.TextStyle(font: bold, fontSize: 10),
            ),
          ],
        ),
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(36),
          theme: pw.ThemeData.withFont(base: regular, bold: bold),
        ),
        build: (context) => [
          pw.Text(
            'T2 / GST workbook (from Fix Appliance CRM)',
            style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColor.fromInt(0xFF14557F)),
          ),
          pw.SizedBox(height: 6),
          pw.Text(f.companyName.isEmpty ? 'Fix Appliance' : f.companyName),
          if (f.companyAddress.isNotEmpty) pw.Text(f.companyAddress),
          if (f.hstNumber.isNotEmpty) pw.Text('HST: ${f.hstNumber}'),
          pw.Text('Period: ${f.periodLabel}'),
          pw.Text('Dates: ${f.dateRangeEn}'),
          pw.SizedBox(height: 8),
          pw.Text(
            'Use this beside UFile T2 or TurboTax Business Incorporation. '
            'Enter GIFI codes on the income statement. Do not treat HST as sales. '
            'Not tax advice.',
            style: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
          ),
          pw.SizedBox(height: 16),
          pw.Text('1. Profit and loss (QuickBooks style)', style: pw.TextStyle(font: bold, fontSize: 13)),
          pw.SizedBox(height: 6),
          moneyRow('Repair sales excluding HST', '8000', f.salesExHst),
          moneyRow('Parts used (cost)', '8320', f.partsCost),
          moneyRow('Gross profit', '8519', f.grossProfit),
          for (final line in f.receipts.operatingLines)
            moneyRow(line.labelEn, line.gifi, line.amount),
          if (f.receipts.operatingTotal > 0)
            moneyRow('Profit after receipt expenses', '', f.profitAfterReceipts),
          moneyRow('Total revenue', '8299', f.salesExHst),
          pw.SizedBox(height: 14),
          pw.Text(
            '2. Where to type in UFile T2 / TurboTax Business',
            style: pw.TextStyle(font: bold, fontSize: 13),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Financial statements → Income statement (GIFI / Schedule 125). '
            'Same codes in both programs. Simple method: type 8000 and 8320; '
            'leave 8300 and 8500 blank so cost of sales is not distorted.',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          moneyRow('Sales of goods and services — TYPE THIS', '8000', f.salesExHst),
          moneyRow('Total revenue (often auto)', '8299', f.salesExHst),
          moneyRow('Purchases / cost of materials — TYPE THIS', '8320', f.partsCost),
          moneyRow('Cost of sales (check; often auto)', '8518', f.partsCost),
          moneyRow('Gross profit / loss (check)', '8519', f.grossProfit),
          for (final line in f.receipts.operatingLines)
            moneyRow('${line.labelEn} — TYPE THIS', line.gifi, line.amount),
          pw.Text(
            'Warehouse at cost TODAY (GIFI 8500 — skip unless year-end inventory method): '
            '\$${f.inventoryAtCost.toStringAsFixed(2)}. Opening inventory 8300 is not in the CRM.',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Cash received excluding HST (check only, not a GIFI sales line): \$${f.cashExHst.toStringAsFixed(2)}',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 14),
          pw.Text('3. GST/HST return (GST34) — not T2', style: pw.TextStyle(font: bold, fontSize: 13)),
          pw.SizedBox(height: 6),
          moneyRow('Sales excluding HST', '101', f.salesExHst),
          moneyRow('HST collectible on invoices', '103', f.hstCollectible),
          moneyRow('ITCs from photographed receipts', '108', f.receipts.itc),
          pw.Text(
            'HST already received from clients: \$${f.hstReceived.toStringAsFixed(2)}. '
            'Amount owing ≈ line 103 minus 108. Add any receipts not photographed.',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 14),
          pw.Text('4. Receipt expenses and anything still missing', style: pw.TextStyle(font: bold, fontSize: 13)),
          pw.SizedBox(height: 6),
          if (f.receipts.operatingLines.isEmpty)
            pw.Text(
              'No photographed receipts in this period. Photograph fuel, insurance, tools, phone during the year.',
              style: const pw.TextStyle(fontSize: 9),
            )
          else ...[
            for (final line in f.receipts.operatingLines)
              moneyRow(line.labelEn, line.gifi, line.amount),
            moneyRow('Total from receipts (excl. HST)', '', f.receipts.operatingTotal),
          ],
          if (f.receipts.partsTotal > 0)
            pw.Text(
              'Parts from receipts (do not duplicate GIFI 8320 if already from invoices): \$${f.receipts.partsTotal.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          if (f.receipts.capitalTotal > 0)
            pw.Text(
              'Equipment flagged for CCA, not expensed: \$${f.receipts.capitalTotal.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          pw.SizedBox(height: 8),
          pw.Text('Still check the corporate bank statement for anything not photographed.', style: const pw.TextStyle(fontSize: 9)),
          if (f.stripeAvailable != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8),
              child: pw.Text(
                'Stripe balance at export (cash, not income): \$${f.stripeAvailable!.toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),
        ],
      ),
    );
    return pdf.save();
  }
}

class _MapRow {
  final String what;
  final double amount;
  final String where;
  final String gifi;

  _MapRow({
    required this.what,
    required this.amount,
    required this.where,
    required this.gifi,
  });
}
