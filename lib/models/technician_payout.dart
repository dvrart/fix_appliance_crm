import 'job.dart';
import 'technician.dart';

/// Источник запчасти в счёте заявки мастера:
/// - `owner` — деталь выдал со склада или купил владелец;
/// - `tech`  — деталь купил сам мастер за свои деньги (требует фото чека).
class PartSource {
  static const String owner = 'owner';
  static const String tech = 'tech';

  static String ofItem(Map item) {
    final explicit = (item['partSource'] ?? '').toString().trim().toLowerCase();
    if (explicit == tech) return tech;
    if (explicit == owner) return owner;
    final warehouseId = (item['warehouseItemId'] ?? '').toString().trim();
    if (warehouseId.isNotEmpty) return owner;
    return owner;
  }

  static String receiptUrlOf(Map item) =>
      (item['receiptUrl'] ?? '').toString().trim();

  static bool hasReceipt(Map item) => receiptUrlOf(item).isNotEmpty;
}

class TechnicianPartLine {
  final String name;
  final double qty;
  final double clientUnitPrice;
  final double unitCost;
  final String source;
  final String receiptUrl;
  final String invoiceNumber;

  const TechnicianPartLine({
    required this.name,
    required this.qty,
    required this.clientUnitPrice,
    required this.unitCost,
    required this.source,
    required this.receiptUrl,
    this.invoiceNumber = '',
  });

  bool get boughtByTech => source == PartSource.tech;
  bool get providedByOwner => source == PartSource.owner;
  bool get hasReceipt => receiptUrl.trim().isNotEmpty;

  /// Подтверждён ли расход запчасти для вычета из чистой прибыли.
  bool get costRecognized => providedByOwner || hasReceipt;

  double get clientTotal => qty * clientUnitPrice;
  double get rawCostTotal => qty * unitCost;
  double get recognizedCostTotal => costRecognized ? rawCostTotal : 0.0;
}

/// Расчёт прибыли и доли к передаче владельцу по одной заявке мастера.
class TechnicianJobPayout {
  final Job job;
  final double invoicedSubtotal;
  final double invoicedTax;
  final double invoicedTotal;
  final double paidExTips;
  final double tips;

  /// Оплаченная выручка без налога HST/GST мастера (база для деления прибыли).
  final double revenueExTax;

  /// Запчасти, выданные владельцем (возвращаются владельцу сверх его доли прибыли).
  final double ownerPartsCost;

  /// Запчасти, купленные мастером и подтверждённые фото чека (остаются у мастера).
  final double techVerifiedPartsCost;

  /// Запчасти «купил мастер», но БЕЗ фото чека — не уменьшают чистую прибыль до загрузки чека.
  final double techUnverifiedPartsCost;

  final double techSharePercent;
  final double netProfit;
  final double techProfit;
  final double ownerProfit;

  /// Сколько денег с этой заявки мастер должен передать владельцу:
  /// `ownerPartsCost + ownerProfit`.
  final double dueToOwner;

  final List<TechnicianPartLine> parts;

  const TechnicianJobPayout({
    required this.job,
    required this.invoicedSubtotal,
    required this.invoicedTax,
    required this.invoicedTotal,
    required this.paidExTips,
    required this.tips,
    required this.revenueExTax,
    required this.ownerPartsCost,
    required this.techVerifiedPartsCost,
    required this.techUnverifiedPartsCost,
    required this.techSharePercent,
    required this.netProfit,
    required this.techProfit,
    required this.ownerProfit,
    required this.dueToOwner,
    this.parts = const [],
  });

  double get recognizedPartsCost => ownerPartsCost + techVerifiedPartsCost;

  double get unpaidClientBalance =>
      (invoicedTotal - paidExTips).clamp(0.0, double.infinity);

  bool get hasUnverifiedTechParts => techUnverifiedPartsCost > 0.009;

  bool get hasPaidActivity => paidExTips > 0.009;
}

/// Сводный баланс мастера по всем его заявкам и переданным расчётам.
class TechnicianBalanceSummary {
  final TechnicianProfile technician;
  final List<TechnicianJobPayout> jobs;
  final List<TechnicianSettlement> settlements;

  final double totalRevenueExTax;
  final double totalOwnerPartsCost;
  final double totalTechVerifiedPartsCost;
  final double totalTechUnverifiedPartsCost;
  final double totalNetProfit;
  final double totalTechProfit;
  final double totalOwnerProfit;
  final double totalGrossDueToOwner;
  final double totalSettled;

  const TechnicianBalanceSummary({
    required this.technician,
    required this.jobs,
    required this.settlements,
    required this.totalRevenueExTax,
    required this.totalOwnerPartsCost,
    required this.totalTechVerifiedPartsCost,
    required this.totalTechUnverifiedPartsCost,
    required this.totalNetProfit,
    required this.totalTechProfit,
    required this.totalOwnerProfit,
    required this.totalGrossDueToOwner,
    required this.totalSettled,
  });

  /// Остаток к передаче в офис на текущий момент.
  double get balanceDueToOwner => totalGrossDueToOwner - totalSettled;

  int get paidJobsCount => jobs.where((j) => j.hasPaidActivity).length;

  int get openJobsCount =>
      jobs.where((j) => !j.job.isDeleted && j.unpaidClientBalance > 0.009).length;
}

class TechnicianPayoutCalculator {
  static double _num(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString()) ?? 0.0;
  }

  static bool _isTipPayment(Map payment) {
    final method = (payment['method'] ?? '').toString().toLowerCase();
    return method.contains('tip') || method.contains('чаевые');
  }

  static bool _isRefundPayment(Map payment) {
    final amount = _num(payment['amount']);
    final method = (payment['method'] ?? '').toString().toLowerCase();
    return amount < -0.009 ||
        method.contains('refund') ||
        method.contains('возврат');
  }

  static ({double paidExTips, double tips}) _paymentsOf(Map doc) {
    final raw = doc['payments'];
    var paid = 0.0;
    var tips = 0.0;
    if (raw is List) {
      for (final p in raw) {
        if (p is! Map) continue;
        final amount = _num(p['amount']);
        if (_isTipPayment(p) && !_isRefundPayment(p)) {
          tips += amount;
        } else {
          paid += amount;
        }
      }
    }
    if (paid == 0 &&
        tips == 0 &&
        doc['stripe'] is Map &&
        doc['stripe']['status'] == 'paid') {
      paid = Job.documentTotal(doc);
    }
    return (paidExTips: paid < 0 ? 0.0 : paid, tips: tips < 0 ? 0.0 : tips);
  }

  static TechnicianJobPayout forJob(
    Job job, {
    required double profitSharePercent,
    Map<String, double> warehouseCosts = const {},
  }) {
    final clampedTechPct = profitSharePercent.clamp(0.0, 100.0);
    final techFraction = clampedTechPct / 100.0;

    var invoicedSubtotal = 0.0;
    var invoicedTax = 0.0;
    var invoicedTotal = 0.0;
    var paidExTips = 0.0;
    var tips = 0.0;
    var revenueExTax = 0.0;
    var ownerPartsCost = 0.0;
    var techVerifiedPartsCost = 0.0;
    var techUnverifiedPartsCost = 0.0;
    final partLines = <TechnicianPartLine>[];

    for (final doc in job.documents) {
      if (!Job.isInvoice(doc) || Job.isDocumentTrashed(doc)) continue;
      final subtotal = Job.documentSubtotal(doc);
      final tax = Job.documentTax(doc);
      final total = subtotal + tax;
      final pay = _paymentsOf(doc);

      invoicedSubtotal += subtotal;
      invoicedTax += tax;
      invoicedTotal += total;
      paidExTips += pay.paidExTips;
      tips += pay.tips;

      final double ratio;
      if (pay.paidExTips <= 0.009) {
        ratio = 0.0;
      } else if (total <= 0.009) {
        ratio = 1.0;
      } else {
        ratio = (pay.paidExTips / total).clamp(0.0, 1.0);
      }

      revenueExTax += subtotal * ratio;

      final invNumber = (doc['number'] ?? '').toString().trim();
      final items = doc['items'];
      if (items is List) {
        for (final rawItem in items) {
          if (rawItem is! Map) continue;
          if (!Job.isPartItem(rawItem)) continue;
          final qty = _num(rawItem['qty'] ?? 1);
          final clientPrice = _num(rawItem['price']);
          final warehouseId =
              (rawItem['warehouseItemId'] ?? '').toString().trim();
          final double unitCost;
          if (rawItem['costPrice'] != null) {
            unitCost = _num(rawItem['costPrice']);
          } else if (warehouseId.isNotEmpty &&
              warehouseCosts.containsKey(warehouseId)) {
            unitCost = warehouseCosts[warehouseId]!;
          } else {
            unitCost = 0.0;
          }
          final source = PartSource.ofItem(rawItem);
          final receiptUrl = PartSource.receiptUrlOf(rawItem);
          final line = TechnicianPartLine(
            name: (rawItem['name'] ?? 'Part').toString(),
            qty: qty,
            clientUnitPrice: clientPrice,
            unitCost: unitCost,
            source: source,
            receiptUrl: receiptUrl,
            invoiceNumber: invNumber,
          );
          partLines.add(line);

          if (ratio > 0) {
            final scaledCost = line.rawCostTotal * ratio;
            if (line.providedByOwner) {
              ownerPartsCost += scaledCost;
            } else if (line.hasReceipt) {
              techVerifiedPartsCost += scaledCost;
            } else if (scaledCost > 0.009) {
              techUnverifiedPartsCost += scaledCost;
            }
          }
        }
      }
    }

    final recognizedParts = ownerPartsCost + techVerifiedPartsCost;
    final netProfit = revenueExTax - recognizedParts;
    final techProfit = netProfit * techFraction;
    final ownerProfit = netProfit - techProfit;
    final dueToOwner = ownerPartsCost + ownerProfit;

    return TechnicianJobPayout(
      job: job,
      invoicedSubtotal: invoicedSubtotal,
      invoicedTax: invoicedTax,
      invoicedTotal: invoicedTotal,
      paidExTips: paidExTips,
      tips: tips,
      revenueExTax: revenueExTax,
      ownerPartsCost: ownerPartsCost,
      techVerifiedPartsCost: techVerifiedPartsCost,
      techUnverifiedPartsCost: techUnverifiedPartsCost,
      techSharePercent: clampedTechPct,
      netProfit: netProfit,
      techProfit: techProfit,
      ownerProfit: ownerProfit,
      dueToOwner: dueToOwner,
      parts: partLines,
    );
  }

  static TechnicianBalanceSummary forTechnician({
    required TechnicianProfile technician,
    required Iterable<Job> jobs,
    required Iterable<TechnicianSettlement> settlements,
    Map<String, double> warehouseCosts = const {},
  }) {
    final assignedJobs = jobs
        .where(
          (j) =>
              !j.isDeleted &&
              !j.isMergedDuplicate &&
              (j.assignedTo ?? '').trim() == technician.uid,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final jobPayouts = [
      for (final job in assignedJobs)
        forJob(
          job,
          profitSharePercent: technician.clampedTechPercent,
          warehouseCosts: warehouseCosts,
        ),
    ];

    final techSettlements = settlements
        .where((s) => s.technicianId == technician.uid)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    var totalRevenueExTax = 0.0;
    var totalOwnerPartsCost = 0.0;
    var totalTechVerifiedPartsCost = 0.0;
    var totalTechUnverifiedPartsCost = 0.0;
    var totalNetProfit = 0.0;
    var totalTechProfit = 0.0;
    var totalOwnerProfit = 0.0;
    var totalGrossDueToOwner = 0.0;

    for (final p in jobPayouts) {
      totalRevenueExTax += p.revenueExTax;
      totalOwnerPartsCost += p.ownerPartsCost;
      totalTechVerifiedPartsCost += p.techVerifiedPartsCost;
      totalTechUnverifiedPartsCost += p.techUnverifiedPartsCost;
      totalNetProfit += p.netProfit;
      totalTechProfit += p.techProfit;
      totalOwnerProfit += p.ownerProfit;
      totalGrossDueToOwner += p.dueToOwner;
    }

    final totalSettled = techSettlements.fold<double>(
      0.0,
      (sum, item) => sum + item.amount,
    );

    return TechnicianBalanceSummary(
      technician: technician,
      jobs: jobPayouts,
      settlements: techSettlements,
      totalRevenueExTax: totalRevenueExTax,
      totalOwnerPartsCost: totalOwnerPartsCost,
      totalTechVerifiedPartsCost: totalTechVerifiedPartsCost,
      totalTechUnverifiedPartsCost: totalTechUnverifiedPartsCost,
      totalNetProfit: totalNetProfit,
      totalTechProfit: totalTechProfit,
      totalOwnerProfit: totalOwnerProfit,
      totalGrossDueToOwner: totalGrossDueToOwner,
      totalSettled: totalSettled,
    );
  }
}
