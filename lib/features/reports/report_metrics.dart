import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/constants.dart';
import '../../models/job.dart';

/// Расчёт отчёта за период — отдельно от экрана, чтобы его можно было
/// проверить тестами. Главное отличие от «просто сумм»: каждая цифра
/// хранит ещё и строки, из которых сложилась, и экран показывает их по
/// нажатию на карточку.
///
/// Правила, на которых держится расчёт:
/// * продажи признаются по дате счёта, деньги — по дате платежа;
/// * чаевые не продажа и не HST: они лежат отдельной строкой;
/// * возврат — отрицательные деньги, он уменьшает «Получено»;
/// * себестоимость запчасти берётся из позиции счёта, иначе со склада,
///   иначе прикидывается как 40% цены — такая строка помечена.

enum ReportPaymentKind { repair, tip, refund }

/// Способ оплаты: наличные, кредитка (карта / Stripe) или электронный перевод (e-Transfer).
enum ReportPayMethod { cash, card, etransfer }

/// Позиция счёта. Запчасть — та, у которой есть себестоимость, склад или
/// тип «Part»; всё остальное считаем работой и выездом.
class ReportItem {
  final String name;
  final double qty;

  /// Цена клиенту за штуку, без HST.
  final double price;

  /// Себестоимость за штуку. У работы нулевая.
  final double unitCost;
  final bool isPart;

  /// Себестоимости не было — прикинули как 40% цены.
  final bool costGuessed;

  /// Работа это или запчасть, решил человек, а не наша догадка.
  final bool classified;
  final String invoiceNumber;
  final String clientName;
  final String jobId;
  final DateTime date;
  final Job? job;
  final int docIndex;
  final int itemIndex;

  const ReportItem({
    required this.name,
    required this.qty,
    required this.price,
    required this.unitCost,
    required this.isPart,
    required this.costGuessed,
    this.classified = true,
    required this.invoiceNumber,
    required this.clientName,
    required this.jobId,
    required this.date,
    this.job,
    this.docIndex = 0,
    this.itemIndex = 0,
  });

  /// Сколько эта позиция стоит для клиента (без HST).
  double get sold => qty * price;

  /// Сколько эта позиция стоила мне (себестоимость запчасти).
  double get cost => qty * unitCost;

  /// Чистыми с этой позиции (наценка на детали или вся сумма работы).
  double get margin => sold - cost;

  ReportItem scale(double factor) {
    if ((factor - 1.0).abs() <= 0.0001) return this;
    return ReportItem(
      name: name,
      qty: qty * factor,
      price: price,
      unitCost: unitCost,
      isPart: isPart,
      costGuessed: costGuessed,
      classified: classified,
      invoiceNumber: invoiceNumber,
      clientName: clientName,
      jobId: jobId,
      date: date,
      job: job,
      docIndex: docIndex,
      itemIndex: itemIndex,
    );
  }
}

/// Счёт, выставленный внутри периода (или внутри заявки).
class ReportInvoice {
  final Job job;
  final int docIndex;
  final String number;
  final DateTime date;
  final double subtotal;
  final double tax;

  /// Деньги по счёту без чаевых, с учётом возвратов. Это состояние счёта
  /// на сегодня, а не только платежи внутри периода.
  final double paid;
  final double cashPaid;
  final double cardPaid;
  final double etransferPaid;
  final double tips;
  final double cashTips;
  final double cardTips;
  final double etransferTips;
  final double partsCost;
  final double partsSales;
  final List<ReportItem> items;

  const ReportInvoice({
    required this.job,
    this.docIndex = 0,
    required this.number,
    required this.date,
    required this.subtotal,
    required this.tax,
    required this.paid,
    required this.cashPaid,
    this.cardPaid = 0,
    this.etransferPaid = 0,
    this.tips = 0,
    this.cashTips = 0,
    this.cardTips = 0,
    this.etransferTips = 0,
    required this.partsCost,
    required this.partsSales,
    this.items = const [],
  });

  double paidBy(ReportPayMethod method) {
    switch (method) {
      case ReportPayMethod.cash:
        return cashPaid;
      case ReportPayMethod.card:
        return cardPaid;
      case ReportPayMethod.etransfer:
        return etransferPaid;
    }
  }

  double tipsBy(ReportPayMethod method) {
    switch (method) {
      case ReportPayMethod.cash:
        return cashTips;
      case ReportPayMethod.card:
        return cardTips;
      case ReportPayMethod.etransfer:
        return etransferTips;
    }
  }

  /// Доля счёта, закрытая выбранным способом оплаты (0..1).
  double methodShare(ReportPayMethod method) {
    final mPaid = paidBy(method);
    if (mPaid <= 0.009) return 0;
    if (total <= 0.009) return 1.0;
    return (mPaid / total).clamp(0.0, 1.0);
  }

  /// Проекция счёта на выбранный способ оплаты.
  ReportInvoice forMethod(ReportPayMethod method) {
    final share = methodShare(method);
    final mPaid = paidBy(method);
    final mTips = tipsBy(method);
    if ((share - 1.0).abs() <= 0.0001) {
      return ReportInvoice(
        job: job,
        docIndex: docIndex,
        number: number,
        date: date,
        subtotal: subtotal,
        tax: tax,
        paid: mPaid,
        cashPaid: method == ReportPayMethod.cash ? cashPaid : 0,
        cardPaid: method == ReportPayMethod.card ? cardPaid : 0,
        etransferPaid: method == ReportPayMethod.etransfer ? etransferPaid : 0,
        tips: mTips,
        cashTips: method == ReportPayMethod.cash ? cashTips : 0,
        cardTips: method == ReportPayMethod.card ? cardTips : 0,
        etransferTips: method == ReportPayMethod.etransfer ? etransferTips : 0,
        partsCost: partsCost,
        partsSales: partsSales,
        items: items,
      );
    }
    return ReportInvoice(
      job: job,
      docIndex: docIndex,
      number: number,
      date: date,
      subtotal: subtotal * share,
      tax: tax * share,
      paid: mPaid,
      cashPaid: method == ReportPayMethod.cash ? cashPaid : 0,
      cardPaid: method == ReportPayMethod.card ? cardPaid : 0,
      etransferPaid: method == ReportPayMethod.etransfer ? etransferPaid : 0,
      tips: mTips,
      cashTips: method == ReportPayMethod.cash ? cashTips : 0,
      cardTips: method == ReportPayMethod.card ? cardTips : 0,
      etransferTips: method == ReportPayMethod.etransfer ? etransferTips : 0,
      partsCost: partsCost * share,
      partsSales: partsSales * share,
      items: [for (final item in items) item.scale(share)],
    );
  }

  List<ReportItem> get parts => items.where((i) => i.isPart).toList();

  List<ReportItem> get labourItems => items.where((i) => !i.isPart).toList();

  /// Грязными с HST (полная сумма счёта для клиента).
  double get total => subtotal + tax;

  /// Грязными без HST (выручка по счёту).
  double get grossExHst => subtotal;

  double get due => (total - paid).clamp(0, double.infinity);

  /// Работа и выезд: всё, что в счёте не помечено запчастью.
  double get labourSales => subtotal - partsSales;

  /// Сколько заработано на запчастях в этом счёте (клиенту − мне).
  double get partsMargin => partsSales - partsCost;

  /// Чистыми по счёту: выручка без HST минус себестоимость запчастей.
  double get netProfit => subtotal - partsCost;

  /// Сколько реально получено от клиента без HST.
  double get paidExHst => total > 0.009 ? paid * (subtotal / total) : paid;

  /// Чистыми деньгами из уже полученных по счёту (получено без HST − запчасти).
  double get paidNetProfit => paidExHst - partsCost;

  bool get isPaid => total > 0.009 && due <= 0.009;

  bool get hasGuessedCost => items.any((i) => i.costGuessed);

  bool get hasUnclassified => items.any((i) => !i.classified);
}

/// Движение денег внутри периода: оплата, чаевые или возврат.
class ReportPayment {
  final Job job;
  final String number;
  final DateTime date;
  final String method;
  final double amount;

  /// Доля платежа без HST и сам HST. У чаевых весь платёж идёт в [net].
  final double net;
  final double hst;
  final ReportPaymentKind kind;
  final bool byCash;
  final ReportPayMethod payMethod;

  const ReportPayment({
    required this.job,
    required this.number,
    required this.date,
    required this.method,
    required this.amount,
    required this.net,
    required this.hst,
    required this.kind,
    required this.byCash,
    this.payMethod = ReportPayMethod.card,
  });
}

/// Заявка с полным раскладом по деньгам, счетам и запчастям.
class ReportJob {
  final Job job;
  final DateTime date;

  /// Грязными с HST (все счета заявки).
  final double invoiced;

  /// Грязными без HST (выручка по счетам заявки).
  final double salesExHst;
  final double tax;
  final double paid;
  final double cashPaid;
  final double tips;

  /// Сколько потрачено на запчасти в этой заявке (для меня).
  final double partsCost;

  /// Сколько запчасти стоили для клиента (без HST).
  final double partsSales;
  final List<ReportInvoice> invoices;
  final List<ReportItem> items;

  const ReportJob({
    required this.job,
    required this.date,
    required this.invoiced,
    this.salesExHst = 0,
    this.tax = 0,
    this.paid = 0,
    this.cashPaid = 0,
    this.tips = 0,
    this.partsCost = 0,
    this.partsSales = 0,
    this.invoices = const [],
    this.items = const [],
  });

  List<ReportItem> get parts => items.where((i) => i.isPart).toList();

  List<ReportItem> get labourItems => items.where((i) => !i.isPart).toList();

  double get due => (invoiced - paid).clamp(0, double.infinity);

  double get labourSales => salesExHst - partsSales;

  double get partsMargin => partsSales - partsCost;

  /// Чистыми по заявке: выручка без HST минус себестоимость запчастей.
  double get netProfit => salesExHst - partsCost;

  /// Реально получено по заявке без HST.
  double get paidExHst =>
      invoiced > 0.009 ? paid * (salesExHst / invoiced) : paid;

  /// Чистыми деньгами из уже полученного по заявке.
  double get paidNetProfit => paidExHst - partsCost;

  bool get hasGuessedCost => items.any((i) => i.costGuessed);

  bool get hasUnclassified => items.any((i) => !i.classified);
}

class ReportMetrics {
  /// Выставлено счетов с HST.
  final double invoiced;

  /// Пришло денег с HST (чаевые не в счёт, возвраты вычтены).
  final double paid;
  final double due;

  /// Себестоимость запчастей, списанных по счетам периода.
  final double partsCost;

  /// Сколько за эти запчасти взяли с клиента, без HST.
  final double partsSales;

  /// Работа и выезд без HST.
  final double labourSales;
  final double tips;
  final double refunds;
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

  final List<ReportInvoice> invoices;
  final List<ReportPayment> payments;
  final List<ReportItem> items;
  final List<ReportJob> invoiceJobs;
  final List<ReportJob> createdJobs;
  final List<ReportJob> completedJobs;

  const ReportMetrics({
    this.invoiced = 0,
    this.paid = 0,
    this.due = 0,
    this.partsCost = 0,
    this.partsSales = 0,
    this.labourSales = 0,
    this.tips = 0,
    this.refunds = 0,
    this.completedCount = 0,
    this.createdCount = 0,
    this.invoiceCount = 0,
    this.salesExHst = 0,
    this.hstCollectible = 0,
    this.cashExHst = 0,
    this.hstReceived = 0,
    this.cashSalesExHst = 0,
    this.cashTax = 0,
    this.cashParts = 0,
    this.cashReceivedExHst = 0,
    this.cashReceivedHst = 0,
    this.jobCount = 0,
    this.invoices = const [],
    this.payments = const [],
    this.items = const [],
    this.invoiceJobs = const [],
    this.createdJobs = const [],
    this.completedJobs = const [],
  });

  static const empty = ReportMetrics();

  double get avgTicket => invoiceCount <= 0 ? 0 : invoiced / invoiceCount;

  double get collectionRate =>
      invoiced <= 0 ? 0 : (paid / invoiced * 100).clamp(0, 999);

  /// Наценка на запчастях: сколько за них взяли с клиентов минус сколько они
  /// стоили мне.
  double get partsMargin => partsSales - partsCost;

  /// Выручка минус себестоимость запчастей. Чеки расходов сюда не входят —
  /// они живут отдельно и вычитаются уже на экране.
  double get grossProfit => salesExHst - partsCost;

  /// То же по реально пришедшим деньгам (без HST) минус себестоимость запчастей.
  double get cashGrossProfit => cashExHst - partsCost;

  /// Оплаты за ремонт без чаевых и возвратов — по ним строится график.
  List<ReportPayment> get repairPayments =>
      payments.where((p) => p.kind == ReportPaymentKind.repair).toList();

  List<ReportPayment> get tipPayments =>
      payments.where((p) => p.kind == ReportPaymentKind.tip).toList();

  List<ReportPayment> get refundPayments =>
      payments.where((p) => p.kind == ReportPaymentKind.refund).toList();

  List<ReportInvoice> get unpaidInvoices =>
      invoices.where((i) => i.due > 0.009).toList();

  List<ReportItem> get parts => items.where((i) => i.isPart).toList();

  List<ReportItem> get labourItems => items.where((i) => !i.isPart).toList();

  bool get hasGuessedCost => items.any((i) => i.costGuessed);

  /// Позиции, которым никто не сказал, работа это или запчасть. Их делёж
  /// держится на догадке, и FIX правит их в «Разобрать позиции».
  List<ReportItem> get unclassifiedItems =>
      items.where((i) => !i.classified).toList();

  static bool _inPeriod(DateTime? date, DateTime start, DateTime end) {
    return date != null && !date.isBefore(start) && date.isBefore(end);
  }

  static double toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static ReportPaymentKind paymentKind(Map payment) {
    final amount = toDouble(payment['amount']);
    final method = (payment['method'] ?? '').toString().toLowerCase();
    if (method.contains('refund') ||
        method.contains('возврат') ||
        amount < -0.009) {
      return ReportPaymentKind.refund;
    }
    if (method.contains('tip') || method.contains('чаев')) {
      return ReportPaymentKind.tip;
    }
    return ReportPaymentKind.repair;
  }

  /// Наличными ли платили. Пустой способ считаем безналичным — так вариант
  /// «без наличных» не занизит доход, если способ забыли проставить.
  static bool isCashPayment(Map payment) {
    final method = (payment['method'] ?? '').toString().toLowerCase();
    return method.contains('cash') || method.contains('налич');
  }

  /// Явно указанный способ оплаты в строке платежа (или null, если там
  /// написано просто «Tip», «Чаевые», «Refund» или пусто).
  static ReportPayMethod? explicitPayMethod(Map payment) {
    final method = (payment['method'] ?? '').toString().toLowerCase();
    if (method.contains('cash') || method.contains('налич')) {
      return ReportPayMethod.cash;
    }
    if (method.contains('transfer') ||
        method.contains('interac') ||
        method.contains('перевод')) {
      return ReportPayMethod.etransfer;
    }
    if (method.contains('stripe') ||
        method.contains('card') ||
        method.contains('credit') ||
        method.contains('debit') ||
        method.contains('link') ||
        method.contains('checkout') ||
        method.contains('карт') ||
        method.contains('кредит') ||
        method.contains('дебет') ||
        method.contains('ссылк') ||
        method.contains('tap to pay') ||
        method.contains('terminal')) {
      return ReportPayMethod.card;
    }
    final hasStripeId =
        (payment['stripePaymentIntentId'] ?? '').toString().trim().isNotEmpty ||
        (payment['stripeSessionId'] ?? '').toString().trim().isNotEmpty ||
        (payment['stripeInvoiceId'] ?? '').toString().trim().isNotEmpty ||
        (payment['stripeRefundId'] ?? '').toString().trim().isNotEmpty;
    if (hasStripeId) return ReportPayMethod.card;
    return null;
  }

  /// Каким способом прошёл платёж: наличные, кредитка (Stripe) или e-Transfer.
  /// Если в самой строке написано «Tip» или «Refund» без способа, берём
  /// способ из соседнего платежа этого же счёта.
  static ReportPayMethod paymentMethodOf(
    Map payment, {
    ReportPayMethod? fallback,
  }) {
    return explicitPayMethod(payment) ?? fallback ?? ReportPayMethod.card;
  }

  /// Способ оплаты по умолчанию для документа (для строк «Tip» / «Refund» без пометки).
  static ReportPayMethod _defaultDocPayMethod(Map doc) {
    final list = doc['payments'];
    if (list is List) {
      for (final payment in list) {
        if (payment is! Map) continue;
        final explicit = explicitPayMethod(payment);
        if (explicit != null) return explicit;
      }
    }
    return ReportPayMethod.card;
  }

  static DateTime? parseAnyDate(dynamic raw) {
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
      return null;
    }
    if (raw is Map) {
      final seconds = raw['_seconds'] ?? raw['seconds'];
      if (seconds is num) {
        return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
      }
    }
    return null;
  }

  static DateTime? invoiceDate(Map doc) {
    return parseAnyDate(doc['createdAt']) ??
        parseAnyDate(doc['issuedAt']) ??
        parseAnyDate(doc['date']);
  }

  /// Разбор одной позиции счёта (деталь или работа).
  static ReportItem itemOf(
    Map item, {
    Map<String, double> warehouseCosts = const {},
    String invoiceNumber = '',
    String clientName = '',
    String jobId = '',
    DateTime? date,
    Job? job,
    int docIndex = 0,
    int itemIndex = 0,
  }) {
    final qty = item['qty'] == null ? 1.0 : toDouble(item['qty']);
    final price = toDouble(item['price']);
    double? cost =
        item['costPrice'] == null ? null : toDouble(item['costPrice']);
    final warehouseId = (item['warehouseItemId'] ?? '').toString();
    if (cost == null && warehouseId.isNotEmpty) {
      cost = warehouseCosts[warehouseId];
    }
    final isPart = Job.isPartItem(item);
    var guessed = false;
    if (cost == null && isPart) {
      cost = price * 0.4;
      guessed = true;
    }
    return ReportItem(
      name: (item['name'] ?? 'Item').toString(),
      qty: qty,
      price: price,
      unitCost: isPart ? (cost ?? 0) : 0,
      isPart: isPart,
      costGuessed: guessed,
      classified: Job.isItemClassified(item),
      invoiceNumber: invoiceNumber,
      clientName: clientName,
      jobId: jobId,
      date: date ?? DateTime.now(),
      job: job,
      docIndex: docIndex,
      itemIndex: itemIndex,
    );
  }

  /// Разбор одного документа (счёта или сметы) со всеми позициями, себестоимостью
  /// запчастей, наценкой и чистым заработком.
  static ReportInvoice invoiceOf(
    Job job,
    Map doc, {
    int docIndex = 0,
    DateTime? fallbackDate,
    Map<String, double> warehouseCosts = const {},
  }) {
    final invDate = invoiceDate(doc) ?? fallbackDate ?? job.createdAt;
    final subtotal = Job.documentSubtotal(doc);
    final tax = Job.documentTax(doc);
    final total = subtotal + tax;
    final number = (doc['number'] ?? doc['docNumber'] ?? '').toString();
    final rows = _itemsOf(
      doc,
      warehouseCosts: warehouseCosts,
      number: number,
      clientName: job.clientName,
      jobId: job.id,
      date: invDate,
      job: job,
      docIndex: docIndex,
    );
    final invoiceParts = rows.fold<double>(
      0,
      (acc, p) => acc + (p.isPart ? p.cost : 0),
    );
    final invoicePartsSales = rows.fold<double>(
      0,
      (acc, p) => acc + (p.isPart ? p.sold : 0),
    );

    // Деньги по счёту — без чаевых, но с вычетом возвратов. Иначе долг
    // по счёту с чаевыми выглядел бы закрытым раньше времени.
    var paidOnDoc = 0.0;
    var cashOnDoc = 0.0;
    var cardOnDoc = 0.0;
    var etransferOnDoc = 0.0;
    var tipsOnDoc = 0.0;
    var cashTipsOnDoc = 0.0;
    var cardTipsOnDoc = 0.0;
    var etransferTipsOnDoc = 0.0;
    var paymentRows = 0;
    final list = doc['payments'];
    if (list is List) {
      var lastMethod = _defaultDocPayMethod(doc);
      for (final payment in list) {
        if (payment is! Map) continue;
        final amount = toDouble(payment['amount']);
        if (amount.abs() <= 0.009) continue;
        paymentRows++;
        final explicit = explicitPayMethod(payment);
        if (explicit != null) lastMethod = explicit;
        final payMethod = explicit ?? lastMethod;
        if (paymentKind(payment) == ReportPaymentKind.tip) {
          tipsOnDoc += amount;
          switch (payMethod) {
            case ReportPayMethod.cash:
              cashTipsOnDoc += amount;
              break;
            case ReportPayMethod.card:
              cardTipsOnDoc += amount;
              break;
            case ReportPayMethod.etransfer:
              etransferTipsOnDoc += amount;
              break;
          }
          continue;
        }
        paidOnDoc += amount;
        switch (payMethod) {
          case ReportPayMethod.cash:
            cashOnDoc += amount;
            break;
          case ReportPayMethod.card:
            cardOnDoc += amount;
            break;
          case ReportPayMethod.etransfer:
            etransferOnDoc += amount;
            break;
        }
      }
    }
    // Оплата прошла Stripe, а строки платежа в документе нет.
    final stripePaidOnly = paymentRows == 0 &&
        doc['stripe'] is Map &&
        doc['stripe']['status'] == 'paid';
    if (stripePaidOnly) {
      paidOnDoc = total;
      cashOnDoc = 0;
      cardOnDoc = total;
      etransferOnDoc = 0;
    }

    return ReportInvoice(
      job: job,
      docIndex: docIndex,
      number: number,
      date: invDate,
      subtotal: subtotal,
      tax: tax,
      paid: paidOnDoc,
      cashPaid: cashOnDoc,
      cardPaid: cardOnDoc,
      etransferPaid: etransferOnDoc,
      tips: tipsOnDoc,
      cashTips: cashTipsOnDoc,
      cardTips: cardTipsOnDoc,
      etransferTips: etransferTipsOnDoc,
      partsCost: invoiceParts,
      partsSales: invoicePartsSales,
      items: rows,
    );
  }

  /// Сводка по заявке из готового списка её счетов.
  static ReportJob jobFromInvoices(
    Job job,
    List<ReportInvoice> invoices, {
    DateTime? date,
  }) {
    var invoiced = 0.0;
    var salesExHst = 0.0;
    var tax = 0.0;
    var paid = 0.0;
    var cashPaid = 0.0;
    var tips = 0.0;
    var partsCost = 0.0;
    var partsSales = 0.0;
    final items = <ReportItem>[];
    for (final inv in invoices) {
      invoiced += inv.total;
      salesExHst += inv.subtotal;
      tax += inv.tax;
      paid += inv.paid;
      cashPaid += inv.cashPaid;
      tips += inv.tips;
      partsCost += inv.partsCost;
      partsSales += inv.partsSales;
      items.addAll(inv.items);
    }
    return ReportJob(
      job: job,
      date: date ??
          (invoices.isNotEmpty
              ? invoices.first.date
              : (job.completedAt ?? job.createdAt)),
      invoiced: invoiced,
      salesExHst: salesExHst,
      tax: tax,
      paid: paid,
      cashPaid: cashPaid,
      tips: tips,
      partsCost: partsCost,
      partsSales: partsSales,
      invoices: invoices,
      items: items,
    );
  }

  /// Полный расклад по заявке (по всем её активным счетам).
  static ReportJob jobOf(
    Job job, {
    DateTime? date,
    Map<String, double> warehouseCosts = const {},
  }) {
    final jobInvoices = <ReportInvoice>[];
    for (var d = 0; d < job.documents.length; d++) {
      final doc = job.documents[d];
      if (!Job.isInvoice(doc) || Job.isDocumentTrashed(doc)) continue;
      jobInvoices.add(
        invoiceOf(
          job,
          doc,
          docIndex: d,
          warehouseCosts: warehouseCosts,
        ),
      );
    }
    return jobFromInvoices(job, jobInvoices, date: date);
  }

  static ReportMetrics build({
    required Iterable<Job> jobs,
    required DateTime start,
    required DateTime endExclusive,
    Map<String, double> warehouseCosts = const {},
  }) {
    var invoiced = 0.0;
    var paid = 0.0;
    var due = 0.0;
    var partsCostTotal = 0.0;
    var partsSalesTotal = 0.0;
    var labourTotal = 0.0;
    var tips = 0.0;
    var refunds = 0.0;
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
    final invoices = <ReportInvoice>[];
    final payments = <ReportPayment>[];
    final itemRows = <ReportItem>[];
    final invoiceJobs = <ReportJob>[];
    final createdJobs = <ReportJob>[];
    final completedJobs = <ReportJob>[];

    for (final job in jobs) {
      if (job.isDeleted) continue;

      final fullJob = jobOf(job, warehouseCosts: warehouseCosts);

      if (_inPeriod(job.createdAt, start, endExclusive)) {
        created++;
        createdJobs.add(
          jobFromInvoices(job, fullJob.invoices, date: job.createdAt),
        );
      }

      if (_inPeriod(job.completedAt, start, endExclusive) &&
          JobStatuses.isCompletedStatus(job.status)) {
        completed++;
        jobsInPeriod.add(job.id);
        completedJobs.add(
          jobFromInvoices(job, fullJob.invoices, date: job.completedAt!),
        );
      }

      final periodJobInvoices = <ReportInvoice>[];

      for (var d = 0; d < job.documents.length; d++) {
        final inv = job.documents[d];
        if (!Job.isInvoice(inv) || Job.isDocumentTrashed(inv)) continue;
        final invDate = invoiceDate(inv);
        final parsed = invoiceOf(
          job,
          inv,
          docIndex: d,
          fallbackDate: invDate ?? job.createdAt,
          warehouseCosts: warehouseCosts,
        );
        final subtotal = parsed.subtotal;
        final tax = parsed.tax;
        final total = parsed.total;
        final number = parsed.number;
        final rows = parsed.items;
        final invoiceParts = parsed.partsCost;
        final invoicePartsSales = parsed.partsSales;
        final paidOnDoc = parsed.paid;
        final cashOnDoc = parsed.cashPaid;

        var paymentRows = 0;
        final list = inv['payments'];
        if (list is List) {
          for (final payment in list) {
            if (payment is! Map) continue;
            final amount = toDouble(payment['amount']);
            if (amount.abs() <= 0.009) continue;
            paymentRows++;
          }
        }
        final stripePaidOnly = paymentRows == 0 &&
            inv['stripe'] is Map &&
            inv['stripe']['status'] == 'paid';

        var periodPaid = 0.0;
        var periodCashPaid = 0.0;
        var periodCardPaid = 0.0;
        var periodEtransferPaid = 0.0;
        var periodTips = 0.0;
        var periodCashTips = 0.0;
        var periodCardTips = 0.0;
        var periodEtransferTips = 0.0;
        var otherPeriodPaid = 0.0;
        DateTime? latestPeriodPayDate;

        void addMoney(
          double amount,
          DateTime when,
          String method,
          ReportPaymentKind kind, {
          required ReportPayMethod payMethod,
        }) {
          final byCash = payMethod == ReportPayMethod.cash;
          // Чаевые — это не продажа, HST в них не сидит.
          final net = kind == ReportPaymentKind.tip
              ? amount
              : (total > 0.009 ? amount * (subtotal / total) : amount);
          payments.add(
            ReportPayment(
              job: job,
              number: number,
              date: when,
              method: method,
              amount: amount,
              net: net,
              hst: amount - net,
              kind: kind,
              byCash: byCash,
              payMethod: payMethod,
            ),
          );
          jobsInPeriod.add(job.id);
          if (latestPeriodPayDate == null ||
              when.isAfter(latestPeriodPayDate!)) {
            latestPeriodPayDate = when;
          }
          if (kind == ReportPaymentKind.tip) {
            tips += amount;
            periodTips += amount;
            switch (payMethod) {
              case ReportPayMethod.cash:
                periodCashTips += amount;
                break;
              case ReportPayMethod.card:
                periodCardTips += amount;
                break;
              case ReportPayMethod.etransfer:
                periodEtransferTips += amount;
                break;
            }
            return;
          }
          if (kind == ReportPaymentKind.refund) refunds += -amount;
          periodPaid += amount;
          switch (payMethod) {
            case ReportPayMethod.cash:
              periodCashPaid += amount;
              break;
            case ReportPayMethod.card:
              periodCardPaid += amount;
              break;
            case ReportPayMethod.etransfer:
              periodEtransferPaid += amount;
              break;
          }
          cashExHst += net;
          hstReceived += amount - net;
          paid += amount;
          if (byCash) {
            cashReceivedExHst += net;
            cashReceivedHst += amount - net;
          }
        }

        if (list is List) {
          var lastMethod = _defaultDocPayMethod(inv);
          for (final payment in list) {
            if (payment is! Map) continue;
            final amount = toDouble(payment['amount']);
            if (amount.abs() <= 0.009) continue;
            final explicit = explicitPayMethod(payment);
            if (explicit != null) lastMethod = explicit;
            final payMethod = explicit ?? lastMethod;
            final kind = paymentKind(payment);
            final payDate = parseAnyDate(payment['date']) ??
                parseAnyDate(payment['createdAt']) ??
                invDate;
            if (!_inPeriod(payDate, start, endExclusive)) {
              if (kind != ReportPaymentKind.tip) {
                otherPeriodPaid += amount;
              }
              continue;
            }
            addMoney(
              amount,
              payDate!,
              (payment['method'] ?? '').toString(),
              kind,
              payMethod: payMethod,
            );
          }
        }
        if (stripePaidOnly) {
          if (_inPeriod(invDate, start, endExclusive)) {
            addMoney(
              paidOnDoc,
              invDate!,
              'Stripe',
              ReportPaymentKind.repair,
              payMethod: ReportPayMethod.card,
            );
          } else {
            otherPeriodPaid += paidOnDoc;
          }
        }

        final invInPeriod = _inPeriod(invDate, start, endExclusive);
        final dueOnDoc = (total - paidOnDoc).clamp(0.0, double.infinity);
        double periodShare = 0.0;
        if (invInPeriod) {
          if (otherPeriodPaid <= 0.009 || total <= 0.009) {
            periodShare = 1.0;
          } else {
            periodShare =
                ((total - otherPeriodPaid) / total).clamp(0.0, 1.0);
          }
        } else if (periodPaid > 0.009 && total > 0.009) {
          periodShare = (periodPaid / total).clamp(0.0, 1.0);
        }

        if (periodShare > 0.0001) {
          final isFullShare = (periodShare - 1.0).abs() <= 0.0001;
          final scaledRows = isFullShare
              ? rows
              : [for (final item in rows) item.scale(periodShare)];
          final periodSubtotal = subtotal * periodShare;
          final periodTax = tax * periodShare;
          final periodTotal = total * periodShare;
          final periodPartsCost = invoiceParts * periodShare;
          final periodPartsSales = invoicePartsSales * periodShare;
          final effectiveCashPaid =
              (isFullShare && otherPeriodPaid <= 0.009)
                  ? cashOnDoc
                  : periodCashPaid;
          final periodInvoice = ReportInvoice(
            job: job,
            docIndex: d,
            number: number,
            date: invInPeriod
                ? invDate!
                : (latestPeriodPayDate ?? parsed.date),
            subtotal: periodSubtotal,
            tax: periodTax,
            paid: (isFullShare && otherPeriodPaid <= 0.009)
                ? paidOnDoc
                : periodPaid,
            cashPaid: effectiveCashPaid,
            cardPaid: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.cardPaid
                : periodCardPaid,
            etransferPaid: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.etransferPaid
                : periodEtransferPaid,
            tips: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.tips
                : periodTips,
            cashTips: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.cashTips
                : periodCashTips,
            cardTips: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.cardTips
                : periodCardTips,
            etransferTips: (isFullShare && otherPeriodPaid <= 0.009)
                ? parsed.etransferTips
                : periodEtransferTips,
            partsCost: periodPartsCost,
            partsSales: periodPartsSales,
            items: scaledRows,
          );

          invoiced += periodTotal;
          salesExHst += periodSubtotal;
          hstCollectible += periodTax;
          invoiceCount++;
          if (invInPeriod) {
            due += dueOnDoc;
          }
          partsCostTotal += periodPartsCost;
          partsSalesTotal += periodPartsSales;
          labourTotal += periodSubtotal - periodPartsSales;
          itemRows.addAll(scaledRows);
          jobsInPeriod.add(job.id);
          invoices.add(periodInvoice);
          periodJobInvoices.add(periodInvoice);

          // Доля счёта, закрытая наличными, — её вычитает выгрузка «без
          // наличных».
          if (effectiveCashPaid > 0.009 && periodTotal > 0.009) {
            final share = (effectiveCashPaid / periodTotal).clamp(0.0, 1.0);
            cashSalesExHst += periodSubtotal * share;
            cashTax += periodTax * share;
            cashParts += periodPartsCost * share;
          }
        }
      }

      if (periodJobInvoices.isNotEmpty) {
        periodJobInvoices.sort((a, b) => b.date.compareTo(a.date));
        invoiceJobs.add(
          jobFromInvoices(
            job,
            periodJobInvoices,
            date: periodJobInvoices.first.date,
          ),
        );
      }
    }

    invoices.sort((a, b) => b.date.compareTo(a.date));
    payments.sort((a, b) => b.date.compareTo(a.date));
    itemRows.sort((a, b) => b.date.compareTo(a.date));
    invoiceJobs.sort((a, b) => b.date.compareTo(a.date));
    createdJobs.sort((a, b) => b.date.compareTo(a.date));
    completedJobs.sort((a, b) => b.date.compareTo(a.date));

    return ReportMetrics(
      invoiced: invoiced,
      paid: paid,
      due: due,
      partsCost: partsCostTotal,
      partsSales: partsSalesTotal,
      labourSales: labourTotal,
      tips: tips,
      refunds: refunds,
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
      invoices: invoices,
      payments: payments,
      items: itemRows,
      invoiceJobs: invoiceJobs,
      createdJobs: createdJobs,
      completedJobs: completedJobs,
    );
  }

  /// Отчёт только по одному способу оплаты: наличные, кредитка (Stripe) или
  /// электронный перевод (e-Transfer). Возвращает полноценный [ReportMetrics],
  /// где все суммы, заявки, инвойсы, детали и платежи пересчитаны по доле
  /// выбранного способа оплаты.
  ReportMetrics forMethod(ReportPayMethod method) {
    final methodInvoices = <ReportInvoice>[
      for (final inv in invoices)
        if (inv.methodShare(method) > 0) inv.forMethod(method),
    ];
    final methodPayments = <ReportPayment>[
      for (final p in payments)
        if (p.payMethod == method) p,
    ];
    final methodItems = <ReportItem>[
      for (final inv in methodInvoices) ...inv.items,
    ];
    final methodInvoiceJobs = <ReportJob>[];
    for (final row in invoiceJobs) {
      final sub = [
        for (final inv in row.invoices)
          if (inv.methodShare(method) > 0) inv.forMethod(method),
      ];
      if (sub.isNotEmpty) {
        methodInvoiceJobs.add(jobFromInvoices(row.job, sub, date: row.date));
      }
    }
    final methodCreatedJobs = <ReportJob>[];
    for (final row in createdJobs) {
      final sub = [
        for (final inv in row.invoices)
          if (inv.methodShare(method) > 0) inv.forMethod(method),
      ];
      if (sub.isNotEmpty) {
        methodCreatedJobs.add(jobFromInvoices(row.job, sub, date: row.date));
      }
    }
    final methodCompletedJobs = <ReportJob>[];
    for (final row in completedJobs) {
      final sub = [
        for (final inv in row.invoices)
          if (inv.methodShare(method) > 0) inv.forMethod(method),
      ];
      if (sub.isNotEmpty) {
        methodCompletedJobs.add(jobFromInvoices(row.job, sub, date: row.date));
      }
    }

    var mInvoiced = 0.0;
    var mSalesExHst = 0.0;
    var mHstCollectible = 0.0;
    var mPartsCost = 0.0;
    var mPartsSales = 0.0;
    var mLabourSales = 0.0;
    final jobsSet = <String>{};

    for (final inv in methodInvoices) {
      mInvoiced += inv.total;
      mSalesExHst += inv.subtotal;
      mHstCollectible += inv.tax;
      mPartsCost += inv.partsCost;
      mPartsSales += inv.partsSales;
      mLabourSales += inv.labourSales;
      jobsSet.add(inv.job.id);
    }

    var mPaid = 0.0;
    var mCashExHst = 0.0;
    var mHstReceived = 0.0;
    var mTips = 0.0;
    var mRefunds = 0.0;
    for (final p in methodPayments) {
      jobsSet.add(p.job.id);
      if (p.kind == ReportPaymentKind.tip) {
        mTips += p.amount;
        continue;
      }
      if (p.kind == ReportPaymentKind.refund) {
        mRefunds += -p.amount;
      }
      mPaid += p.amount;
      mCashExHst += p.net;
      mHstReceived += p.hst;
    }
    for (final row in methodCompletedJobs) {
      jobsSet.add(row.job.id);
    }

    final isCash = method == ReportPayMethod.cash;
    return ReportMetrics(
      invoiced: mInvoiced,
      paid: mPaid,
      due: 0,
      partsCost: mPartsCost,
      partsSales: mPartsSales,
      labourSales: mLabourSales,
      tips: mTips,
      refunds: mRefunds,
      completedCount: methodCompletedJobs.length,
      createdCount: methodCreatedJobs.length,
      invoiceCount: methodInvoices.length,
      salesExHst: mSalesExHst,
      hstCollectible: mHstCollectible,
      cashExHst: mCashExHst,
      hstReceived: mHstReceived,
      cashSalesExHst: isCash ? mSalesExHst : 0,
      cashTax: isCash ? mHstCollectible : 0,
      cashParts: isCash ? mPartsCost : 0,
      cashReceivedExHst: isCash ? mCashExHst : 0,
      cashReceivedHst: isCash ? mHstReceived : 0,
      jobCount: jobsSet.length,
      invoices: methodInvoices,
      payments: methodPayments,
      items: methodItems,
      invoiceJobs: methodInvoiceJobs,
      createdJobs: methodCreatedJobs,
      completedJobs: methodCompletedJobs,
    );
  }

  static List<ReportItem> _itemsOf(
    Map doc, {
    required Map<String, double> warehouseCosts,
    required String number,
    required String clientName,
    required String jobId,
    required DateTime date,
    Job? job,
    int docIndex = 0,
  }) {
    final items = doc['items'];
    if (items is! List) return const [];
    final rows = <ReportItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      rows.add(
        itemOf(
          item,
          warehouseCosts: warehouseCosts,
          invoiceNumber: number,
          clientName: clientName,
          jobId: jobId,
          date: date,
          job: job,
          docIndex: docIndex,
          itemIndex: i,
        ),
      );
    }
    return rows;
  }
}
