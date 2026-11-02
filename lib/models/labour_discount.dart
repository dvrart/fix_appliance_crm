import 'job.dart';

/// Скидка только на работу мастера, не на запчасти (решение FIX 28.10.2026):
/// по Care Plan работа бесплатна, либо любая другая скидка, которую мастер
/// поставит сам.
///
/// Это обычная строка счёта с отрицательной ценой и меткой `Service`, поэтому
/// итог, HST, оплата и Stripe считаются как раньше, а в отчётах уменьшается
/// именно выручка за работу. База — только позиции, явно помеченные как
/// работа (`Job.itemKind == 'service'`): деталь без метки скидку не получит.
class LabourDiscount {
  static const String marker = 'labourDiscount';

  static bool isDiscountLine(Map item) => item[marker] == true;

  static double _num(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _round(double value) => (value * 100).roundToDouble() / 100;

  /// Сумма работы в счёте (без строки скидки и без запчастей).
  static double labourBase(List<Map> items) {
    var total = 0.0;
    for (final item in items) {
      if (isDiscountLine(item) || Job.itemKind(item) != 'service') continue;
      final line = _num(item['qty'], 1) * _num(item['price'], 0);
      if (line > 0) total += line;
    }
    return _round(total);
  }

  static double amount(List<Map> items, double percent) =>
      _round(labourBase(items) * percent.clamp(0, 100) / 100);

  static double? percentOf(List<Map> items) {
    for (final item in items) {
      if (isDiscountLine(item)) return _num(item['discountPercent'], 0);
    }
    return null;
  }

  static Map<String, dynamic> line(double percent, double amount, {bool carePlan = false}) {
    final pct = percent == percent.roundToDouble()
        ? percent.toStringAsFixed(0)
        : percent.toStringAsFixed(1);
    return {
      'name': 'Labour discount $pct%${carePlan ? ' (Care Plan)' : ''}',
      'qty': 1,
      'price': -amount,
      'type': 'Service',
      marker: true,
      'discountPercent': percent,
      'carePlan': carePlan,
    };
  }

  /// Новый список позиций: прежняя строка скидки убрана, новая — в конце.
  /// [percent] 0 — скидка просто снимается.
  static List<Map<String, dynamic>> apply(
    List<Map<String, dynamic>> items,
    double percent, {
    bool carePlan = false,
  }) {
    final rest = [
      for (final item in items)
        if (!isDiscountLine(item)) item,
    ];
    final value = amount(rest, percent);
    if (percent <= 0 || value <= 0) return rest;
    return [...rest, line(percent, value, carePlan: carePlan)];
  }

  /// Работа по Care Plan бесплатна, когда заявка привязана к паспорту со
  /// стикером. Строка скидки дописывается сама на все 100% работы, запчасти
  /// не трогает. Уже выставленная вручную скидка не переписывается.
  static List<Map<String, dynamic>> coverLabour(
    List<Map<String, dynamic>> items,
  ) {
    if (percentOf(items) != null) return refresh(items);
    if (labourBase(items) <= 0) return items;
    return apply(items, 100, carePlan: true);
  }

  /// Пересчитать строку скидки по её проценту — после того как работу в
  /// счёте поменяли. Порядок и число позиций не меняются.
  static List<Map<String, dynamic>> refresh(List<Map<String, dynamic>> items) {
    final percent = percentOf(items);
    if (percent == null) return items;
    final value = amount(items, percent);
    return [
      for (final item in items)
        if (isDiscountLine(item))
          {...item, 'price': -value}
        else
          item,
    ];
  }
}
