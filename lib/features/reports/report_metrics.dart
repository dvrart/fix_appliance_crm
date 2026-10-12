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
  });

  double get sold => qty * price;

  double get cost => qty * unitCost;

  double get margin => sold - cost;
}

/// Счёт, выставленный внутри периода.
class ReportInvoice {
  final Job job;
  final String number;
  final DateTime date;
  final double subtotal;
  final double tax;

  /// Деньги по счёту без чаевых, с учётом возвратов. Это состояние счёта
  /// на сегодня, а не только платежи внутри периода.
  final double paid;
  final double cashPaid;
  final double partsCost;
  final double partsSales;
  final List<ReportItem> items;

  const ReportInvoice({
    required this.job,
    required this.number,
    required this.date,
    required this.subtotal,
    required this.tax,
    required this.paid,
    required this.cashPaid,
    required this.partsCost,
    required this.partsSales,
    this.items = const [],
  });

  List<ReportItem> get parts => items.where((i) => i.isPart).toList();

  List<ReportItem> get labourItems => items.where((i) => !i.isPart).toList();

  double get total => subtotal + tax;

  double get due => (total - paid).clamp(0, double.infinity);

  /// Работа и выезд: всё, что в счёте не помечено запчастью.
  double get labourSales => subtotal - partsSales;

  bool get isPaid => total > 0.009 && due <= 0.009;
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
  });
}

/// Заявка, попавшая в период по созданию или по завершению.
class ReportJob {
  final Job job;
  final DateTime date;
  final double invoiced;

  const ReportJob({
    required this.job,
    required this.date,
    required this.invoiced,
  });
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
    this.createdJobs = const [],
    this.completedJobs = const [],
  });

  static const empty = ReportMetrics();

  double get avgTicket => invoiceCount <= 0 ? 0 : invoiced / invoiceCount;

  double get collectionRate =>
      invoiced <= 0 ? 0 : (paid / invoiced * 100).clamp(0, 999);

  /// Выручка минус себестоимость запчастей. Чеки расходов сюда не входят —
  /// они живут отдельно и вычитаются уже на экране.
  double get grossProfit => salesExHst - partsCost;

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
    final createdJobs = <ReportJob>[];
    final completedJobs = <ReportJob>[];

    for (final job in jobs) {
      if (job.isDeleted) continue;

      if (_inPeriod(job.createdAt, start, endExclusive)) {
        created++;
        createdJobs.add(
          ReportJob(job: job, date: job.createdAt, invoiced: job.invoicedTotal),
        );
      }

      if (_inPeriod(job.completedAt, start, endExclusive) &&
          JobStatuses.isCompletedStatus(job.status)) {
        completed++;
        jobsInPeriod.add(job.id);
        completedJobs.add(
          ReportJob(
            job: job,
            date: job.completedAt!,
            invoiced: job.invoicedTotal,
          ),
        );
      }

      for (final inv in job.documents) {
        if (!Job.isInvoice(inv)) continue;
        final invDate = invoiceDate(inv);
        final subtotal = Job.documentSubtotal(inv);
        final tax = Job.documentTax(inv);
        final total = subtotal + tax;
        final number = (inv['number'] ?? inv['docNumber'] ?? '').toString();
        final rows = _itemsOf(
          inv,
          warehouseCosts: warehouseCosts,
          number: number,
          clientName: job.clientName,
          jobId: job.id,
          date: invDate ?? job.createdAt,
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
        var paymentRows = 0;
        final list = inv['payments'];
        if (list is List) {
          for (final payment in list) {
            if (payment is! Map) continue;
            final amount = toDouble(payment['amount']);
            if (amount.abs() <= 0.009) continue;
            paymentRows++;
            if (paymentKind(payment) == ReportPaymentKind.tip) continue;
            paidOnDoc += amount;
            if (isCashPayment(payment)) cashOnDoc += amount;
          }
        }
        // Оплата прошла Stripe, а строки платежа в документе нет.
        final stripePaidOnly = paymentRows == 0 &&
            inv['stripe'] is Map &&
            inv['stripe']['status'] == 'paid';
        if (stripePaidOnly) {
          paidOnDoc = total;
          cashOnDoc = 0;
        }

        if (_inPeriod(invDate, start, endExclusive)) {
          invoiced += total;
          salesExHst += subtotal;
          hstCollectible += tax;
          invoiceCount++;
          due += (total - paidOnDoc).clamp(0, double.infinity);
          partsCostTotal += invoiceParts;
          partsSalesTotal += invoicePartsSales;
          labourTotal += subtotal - invoicePartsSales;
          itemRows.addAll(rows);
          jobsInPeriod.add(job.id);
          invoices.add(
            ReportInvoice(
              job: job,
              number: number,
              date: invDate!,
              subtotal: subtotal,
              tax: tax,
              paid: paidOnDoc,
              cashPaid: cashOnDoc,
              partsCost: invoiceParts,
              partsSales: invoicePartsSales,
              items: rows,
            ),
          );

          // Доля счёта, закрытая наличными, — её вычитает выгрузка «без
          // наличных». Дату платежа тут не смотрим: продажи признаём по
          // дате счёта, а вопрос один — чем за этот счёт заплатили.
          if (cashOnDoc > 0.009 && total > 0.009) {
            final share = (cashOnDoc / total).clamp(0.0, 1.0);
            cashSalesExHst += subtotal * share;
            cashTax += tax * share;
            cashParts += invoiceParts * share;
          }
        }

        void addMoney(
          double amount,
          DateTime when,
          String method,
          ReportPaymentKind kind, {
          required bool byCash,
        }) {
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
            ),
          );
          jobsInPeriod.add(job.id);
          if (kind == ReportPaymentKind.tip) {
            tips += amount;
            return;
          }
          if (kind == ReportPaymentKind.refund) refunds += -amount;
          cashExHst += net;
          hstReceived += amount - net;
          paid += amount;
          if (byCash) {
            cashReceivedExHst += net;
            cashReceivedHst += amount - net;
          }
        }

        if (list is List) {
          for (final payment in list) {
            if (payment is! Map) continue;
            final amount = toDouble(payment['amount']);
            if (amount.abs() <= 0.009) continue;
            final payDate = parseAnyDate(payment['date']) ??
                parseAnyDate(payment['createdAt']) ??
                invDate;
            if (!_inPeriod(payDate, start, endExclusive)) continue;
            addMoney(
              amount,
              payDate!,
              (payment['method'] ?? '').toString(),
              paymentKind(payment),
              byCash: isCashPayment(payment),
            );
          }
        }
        if (stripePaidOnly && _inPeriod(invDate, start, endExclusive)) {
          addMoney(
            paidOnDoc,
            invDate!,
            'Stripe',
            ReportPaymentKind.repair,
            byCash: false,
          );
        }
      }
    }

    invoices.sort((a, b) => b.date.compareTo(a.date));
    payments.sort((a, b) => b.date.compareTo(a.date));
    itemRows.sort((a, b) => b.date.compareTo(a.date));
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
      createdJobs: createdJobs,
      completedJobs: completedJobs,
    );
  }

  static List<ReportItem> _itemsOf(
    Map doc, {
    required Map<String, double> warehouseCosts,
    required String number,
    required String clientName,
    required String jobId,
    required DateTime date,
  }) {
    final items = doc['items'];
    if (items is! List) return const [];
    final rows = <ReportItem>[];
    for (final item in items) {
      if (item is! Map) continue;
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
      rows.add(
        ReportItem(
          name: (item['name'] ?? 'Item').toString(),
          qty: qty,
          price: price,
          unitCost: isPart ? (cost ?? 0) : 0,
          isPart: isPart,
          costGuessed: guessed,
          classified: Job.isItemClassified(item),
          invoiceNumber: number,
          clientName: clientName,
          jobId: jobId,
          date: date,
        ),
      );
    }
    return rows;
  }
}
