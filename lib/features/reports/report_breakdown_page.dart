import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';

/// Одна строка расшифровки: что это было, когда и на сколько.
class BreakdownRow {
  final String title;
  final String subtitle;
  final double? amount;

  /// Если цифра не деньги (например «8 заявок») — показываем её текстом.
  final String? amountText;

  /// Мелкие подписи под строкой: «Без HST $200 · HST $26».
  final List<String> chips;

  /// Красная сумма: возврат, долг, расход.
  final bool negative;
  final String? warning;
  final VoidCallback? onTap;

  const BreakdownRow({
    required this.title,
    this.subtitle = '',
    this.amount,
    this.amountText,
    this.chips = const [],
    this.negative = false,
    this.warning,
    this.onTap,
  });
}

/// Блок расшифровки: заголовок, строки и своя сумма.
class BreakdownSection {
  final String title;
  final String hint;
  final List<BreakdownRow> rows;
  final double? total;
  final String totalLabel;
  final String empty;

  const BreakdownSection({
    required this.title,
    this.hint = '',
    this.rows = const [],
    this.total,
    this.totalLabel = '',
    this.empty = '',
  });
}

/// Экран «из чего сложилась эта цифра». Открывается по нажатию на любую
/// карточку отчёта. Если расшифровывать нечего (процент, средний чек) —
/// остаются пояснение и формула, и карточка всё равно нажимается: FIX
/// просил, чтобы ни одна плитка не была глухой.
class ReportBreakdownPage extends StatelessWidget {
  final String title;
  final String periodLabel;
  final String headline;
  final String headlineLabel;
  final String headlineHint;
  final Color color;
  final IconData icon;

  /// Человеческим языком: что это за цифра и откуда она берётся.
  final List<String> explain;

  /// Строки формулы: («Выручка без HST», «$1 820.00»).
  final List<(String, String)> formula;
  final List<BreakdownSection> sections;

  const ReportBreakdownPage({
    super.key,
    required this.title,
    required this.periodLabel,
    required this.headline,
    required this.headlineLabel,
    required this.color,
    required this.icon,
    this.headlineHint = '',
    this.explain = const [],
    this.formula = const [],
    this.sections = const [],
  });

  static Future<void> open(
    BuildContext context, {
    required String title,
    required String periodLabel,
    required String headline,
    required String headlineLabel,
    required Color color,
    required IconData icon,
    String headlineHint = '',
    List<String> explain = const [],
    List<(String, String)> formula = const [],
    List<BreakdownSection> sections = const [],
  }) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReportBreakdownPage(
          title: title,
          periodLabel: periodLabel,
          headline: headline,
          headlineLabel: headlineLabel,
          headlineHint: headlineHint,
          color: color,
          icon: icon,
          explain: explain,
          formula: formula,
          sections: sections,
        ),
      ),
    );
  }

  static String money(double value) {
    final sign = value < -0.004 ? '−' : '';
    return '$sign\$${value.abs().toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          _headCard(),
          if (explain.isNotEmpty) ...[
            const SizedBox(height: 12),
            _explainCard(context),
          ],
          if (formula.isNotEmpty) ...[
            const SizedBox(height: 12),
            _formulaCard(context),
          ],
          for (final section in sections) ...[
            const SizedBox(height: 18),
            _sectionTitle(section),
            const SizedBox(height: 8),
            _sectionBody(context, section),
          ],
        ],
      ),
    );
  }

  Widget _headCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  headlineLabel,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  periodLabel,
                  style: const TextStyle(color: Colors.black45, fontSize: 13),
                ),
                if (headlineHint.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    headlineHint,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _explainCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF5FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBBD4E6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, size: 18, color: Color(0xFF14557F)),
              const SizedBox(width: 6),
              Text(
                context.tr('Что это за цифра', 'What this number is'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14557F),
                ),
              ),
            ],
          ),
          for (final line in explain)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                line,
                style: const TextStyle(height: 1.35, color: Colors.black87),
              ),
            ),
        ],
      ),
    );
  }

  Widget _formulaCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 2),
            child: Text(
              context.tr('Как посчитано', 'How it is calculated'),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF14557F),
              ),
            ),
          ),
          for (final (label, value) in formula)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        height: 1.3,
                        fontWeight:
                            label.startsWith('=') ? FontWeight.w800 : null,
                        color: label.startsWith('=')
                            ? const Color(0xFF14557F)
                            : Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    value,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: label.startsWith('=')
                          ? const Color(0xFF14557F)
                          : Colors.black,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BreakdownSection section) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          section.title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF14557F),
          ),
        ),
        if (section.hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              section.hint,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }

  Widget _sectionBody(BuildContext context, BreakdownSection section) {
    if (section.rows.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          section.empty.isEmpty
              ? context.tr('Пусто за этот период.', 'Nothing in this period.')
              : section.empty,
          style: const TextStyle(color: Colors.black54, height: 1.35),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (var i = 0; i < section.rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14),
            _rowTile(section.rows[i]),
          ],
          if (section.total != null) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      section.totalLabel.isEmpty
                          ? context.tr('Итого', 'Total')
                          : section.totalLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF14557F),
                      ),
                    ),
                  ),
                  Text(
                    money(section.total!),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      color: Color(0xFF14557F),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rowTile(BreakdownRow row) {
    final value = row.amountText ??
        (row.amount == null ? '' : money(row.amount!));
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (row.subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.subtitle,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                if (row.chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final chip in row.chips)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0F3F6),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              chip,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.black87,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (row.warning != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 14,
                          color: Color(0xFFB26A00),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            row.warning!,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFB26A00),
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (value.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: row.negative ? const Color(0xFFC62828) : Colors.black,
              ),
            ),
          ],
          if (row.onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 2),
              child: Icon(Icons.chevron_right, size: 18, color: Colors.black26),
            ),
        ],
      ),
    );
    if (row.onTap == null) return content;
    return InkWell(onTap: row.onTap, child: content);
  }
}
