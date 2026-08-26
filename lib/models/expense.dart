import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ExpenseCategory {
  final String id;
  final String gifi;
  final String labelRu;
  final String labelEn;
  final IconData icon;
  final bool operating;

  const ExpenseCategory({
    required this.id,
    required this.gifi,
    required this.labelRu,
    required this.labelEn,
    required this.icon,
    this.operating = true,
  });

  String label(bool english) => english ? labelEn : labelRu;
}

class ExpenseCategories {
  static const vehicle = ExpenseCategory(
    id: 'vehicle',
    gifi: '9281',
    labelRu: 'Машина / бензин',
    labelEn: 'Vehicle / fuel',
    icon: Icons.local_gas_station,
  );
  static const insurance = ExpenseCategory(
    id: 'insurance',
    gifi: '8690',
    labelRu: 'Страховка',
    labelEn: 'Insurance',
    icon: Icons.health_and_safety_outlined,
  );
  static const phone = ExpenseCategory(
    id: 'phone',
    gifi: '9225',
    labelRu: 'Телефон / интернет',
    labelEn: 'Phone / internet',
    icon: Icons.phone_iphone,
  );
  static const fees = ExpenseCategory(
    id: 'fees',
    gifi: '8715',
    labelRu: 'Банк / Stripe',
    labelEn: 'Bank / Stripe fees',
    icon: Icons.account_balance,
  );
  static const accounting = ExpenseCategory(
    id: 'accounting',
    gifi: '8862',
    labelRu: 'Бухгалтер',
    labelEn: 'Accounting',
    icon: Icons.calculate_outlined,
  );
  static const advertising = ExpenseCategory(
    id: 'advertising',
    gifi: '8521',
    labelRu: 'Реклама',
    labelEn: 'Advertising',
    icon: Icons.campaign_outlined,
  );
  static const rent = ExpenseCategory(
    id: 'rent',
    gifi: '8911',
    labelRu: 'Аренда',
    labelEn: 'Rent',
    icon: Icons.storefront_outlined,
  );
  static const wages = ExpenseCategory(
    id: 'wages',
    gifi: '9060',
    labelRu: 'Зарплата',
    labelEn: 'Wages',
    icon: Icons.badge_outlined,
  );
  static const tools = ExpenseCategory(
    id: 'tools',
    gifi: '9270',
    labelRu: 'Инструмент',
    labelEn: 'Tools',
    icon: Icons.handyman_outlined,
  );
  static const supplies = ExpenseCategory(
    id: 'supplies',
    gifi: '9200',
    labelRu: 'Расходники',
    labelEn: 'Supplies',
    icon: Icons.cleaning_services_outlined,
  );
  static const meals = ExpenseCategory(
    id: 'meals',
    gifi: '8523',
    labelRu: 'Еда (50%)',
    labelEn: 'Meals (50%)',
    icon: Icons.restaurant,
  );
  static const parts = ExpenseCategory(
    id: 'parts',
    gifi: '8320',
    labelRu: 'Запчасти с чека',
    labelEn: 'Parts from receipt',
    icon: Icons.settings_outlined,
    operating: false,
  );
  static const other = ExpenseCategory(
    id: 'other',
    gifi: '9270',
    labelRu: 'Прочее',
    labelEn: 'Other',
    icon: Icons.receipt_long,
  );

  static const List<ExpenseCategory> all = [
    vehicle,
    insurance,
    phone,
    fees,
    accounting,
    advertising,
    rent,
    wages,
    tools,
    supplies,
    meals,
    parts,
    other,
  ];

  static ExpenseCategory byId(String id) {
    for (final item in all) {
      if (item.id == id) return item;
    }
    return other;
  }
}

class ExpenseGifiLine {
  final String gifi;
  final String labelRu;
  final String labelEn;
  final double amount;

  const ExpenseGifiLine({
    required this.gifi,
    required this.labelRu,
    required this.labelEn,
    required this.amount,
  });
}

class ExpenseRollup {
  final List<ExpenseGifiLine> operatingLines;
  final double operatingTotal;
  final double partsTotal;
  final double capitalTotal;
  final double itc;
  final int count;

  const ExpenseRollup({
    this.operatingLines = const [],
    this.operatingTotal = 0,
    this.partsTotal = 0,
    this.capitalTotal = 0,
    this.itc = 0,
    this.count = 0,
  });

  static const empty = ExpenseRollup();

  bool get isEmpty => count == 0;

  static ExpenseRollup fromList(Iterable<Expense> items) {
    final list = items.toList();
    final byGifi = <String, double>{};
    final ru = <String, String>{};
    final en = <String, String>{};
    var itc = 0.0;
    var parts = 0.0;
    var capital = 0.0;
    var operating = 0.0;
    for (final item in list) {
      itc += item.hst;
      if (item.capitalAsset) {
        capital += item.amountExHst;
        continue;
      }
      if (item.category == ExpenseCategories.parts.id) {
        parts += item.amountExHst;
        continue;
      }
      final amount = item.t2Amount;
      if (amount == 0) continue;
      operating += amount;
      final gifi = item.gifi;
      byGifi[gifi] = (byGifi[gifi] ?? 0) + amount;
      final info = item.categoryInfo;
      ru[gifi] = ru[gifi] == null || ru[gifi] == info.labelRu
          ? info.labelRu
          : '${ru[gifi]!}; ${info.labelRu}';
      en[gifi] = en[gifi] == null || en[gifi] == info.labelEn
          ? info.labelEn
          : '${en[gifi]!}; ${info.labelEn}';
    }
    final lines = [
      for (final gifi in byGifi.keys)
        ExpenseGifiLine(
          gifi: gifi,
          labelRu: ru[gifi] ?? gifi,
          labelEn: en[gifi] ?? gifi,
          amount: byGifi[gifi]!,
        ),
    ]..sort((a, b) => a.gifi.compareTo(b.gifi));
    return ExpenseRollup(
      operatingLines: lines,
      operatingTotal: operating,
      partsTotal: parts,
      capitalTotal: capital,
      itc: itc,
      count: list.length,
    );
  }
}

class Expense {
  final String id;
  final String vendor;
  final DateTime date;
  final double amountExHst;
  final double hst;
  final double total;
  final String category;
  final String gifi;
  final String note;
  final String photoUrl;
  final String fileMime;
  final bool capitalAsset;
  final bool needsReview;
  final double confidence;
  final DateTime createdAt;

  const Expense({
    required this.id,
    required this.vendor,
    required this.date,
    required this.amountExHst,
    required this.hst,
    required this.total,
    required this.category,
    required this.gifi,
    this.note = '',
    this.photoUrl = '',
    this.fileMime = '',
    this.capitalAsset = false,
    this.needsReview = false,
    this.confidence = 1,
    required this.createdAt,
  });

  ExpenseCategory get categoryInfo => ExpenseCategories.byId(category);

  bool get isPdf {
    final mime = fileMime.toLowerCase();
    if (mime.contains('pdf')) return true;
    return photoUrl.toLowerCase().contains('.pdf');
  }

  bool get hasFile => photoUrl.trim().isNotEmpty;

  /// Amount for T2 income statement (HST out; meals 50%).
  double get t2Amount {
    if (capitalAsset) return 0;
    if (category == ExpenseCategories.parts.id) return 0;
    if (category == ExpenseCategories.meals.id) return amountExHst * 0.5;
    return amountExHst;
  }

  factory Expense.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value) ?? DateTime.now();
      }
      return DateTime.now();
    }

    final category = (map['category'] ?? 'other').toString();
    final info = ExpenseCategories.byId(category);
    return Expense(
      id: id,
      vendor: (map['vendor'] ?? '').toString(),
      date: parseDate(map['date']),
      amountExHst: (map['amountExHst'] as num?)?.toDouble() ?? 0,
      hst: (map['hst'] as num?)?.toDouble() ?? 0,
      total: (map['total'] as num?)?.toDouble() ?? 0,
      category: info.id,
      gifi: (map['gifi'] ?? info.gifi).toString(),
      note: (map['note'] ?? '').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      fileMime: (map['fileMime'] ?? '').toString(),
      capitalAsset: map['capitalAsset'] == true,
      needsReview: map['needsReview'] == true,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 1,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    final info = categoryInfo;
    return {
      'vendor': vendor,
      'date': Timestamp.fromDate(date),
      'amountExHst': amountExHst,
      'hst': hst,
      'total': total,
      'category': info.id,
      'gifi': info.gifi,
      'note': note,
      'photoUrl': photoUrl,
      'fileMime': fileMime,
      'capitalAsset': capitalAsset,
      'needsReview': needsReview,
      'confidence': confidence,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Expense copyWith({
    String? id,
    String? vendor,
    DateTime? date,
    double? amountExHst,
    double? hst,
    double? total,
    String? category,
    String? gifi,
    String? note,
    String? photoUrl,
    String? fileMime,
    bool? capitalAsset,
    bool? needsReview,
    double? confidence,
  }) {
    final nextCategory = ExpenseCategories.byId(category ?? this.category);
    return Expense(
      id: id ?? this.id,
      vendor: vendor ?? this.vendor,
      date: date ?? this.date,
      amountExHst: amountExHst ?? this.amountExHst,
      hst: hst ?? this.hst,
      total: total ?? this.total,
      category: nextCategory.id,
      gifi: gifi ?? nextCategory.gifi,
      note: note ?? this.note,
      photoUrl: photoUrl ?? this.photoUrl,
      fileMime: fileMime ?? this.fileMime,
      capitalAsset: capitalAsset ?? this.capitalAsset,
      needsReview: needsReview ?? this.needsReview,
      confidence: confidence ?? this.confidence,
      createdAt: createdAt,
    );
  }
}
