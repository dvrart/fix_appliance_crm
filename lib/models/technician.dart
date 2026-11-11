import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'document_settings.dart';

/// UID основного аккаунта владельца (совпадает с firestore.rules и auth_guard.js).
const String kOwnerUid = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';

/// Сборка для мастеров (`--dart-define=TECH_APP=true`): отключает авто-вход
/// под вшитыми реквизитами владельца и всегда открывает экран входа мастера.
const bool kTechnicianAppBuild = bool.fromEnvironment(
  'TECH_APP',
  defaultValue: false,
);

DateTime? _parseTechDate(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Профиль независимого мастера (частного подрядчика).
/// Хранится в `companies/{companyId}/technicians/{uid}`, где id документа = Firebase Auth UID.
class TechnicianProfile {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final int colorValue;

  /// Процент чистой прибыли, который остаётся мастеру (0..100).
  /// Доля владельца = `100 - profitSharePercent`.
  final double profitSharePercent;

  /// Реквизиты ИП мастера для его счетов клиентам (чтобы выручка и HST не шли на владельца).
  final String businessName;
  final bool collectsHst;
  final String hstNumber;
  final String etransferEmail;

  final bool active;
  final DateTime? createdAt;

  const TechnicianProfile({
    required this.uid,
    required this.name,
    required this.email,
    this.phone = '',
    this.colorValue = 0xFF00897B,
    this.profitSharePercent = 50,
    this.businessName = '',
    this.collectsHst = false,
    this.hstNumber = '',
    this.etransferEmail = '',
    this.active = true,
    this.createdAt,
  });

  static const List<int> palette = [
    0xFF00897B,
    0xFF3949AB,
    0xFF8E24AA,
    0xFFE64A19,
    0xFF2E7D32,
    0xFF00838F,
    0xFF6D4C41,
    0xFFAD1457,
  ];

  Color get color => Color(colorValue);

  double get clampedTechPercent => profitSharePercent.clamp(0.0, 100.0);

  double get ownerSharePercent => (100.0 - clampedTechPercent).clamp(0.0, 100.0);

  String get displayName => name.trim().isNotEmpty ? name.trim() : email.trim();

  String get effectiveBusinessName =>
      businessName.trim().isNotEmpty ? businessName.trim() : displayName;

  String get effectiveHstNumber =>
      collectsHst ? hstNumber.trim() : '';

  bool get hasOwnTax => effectiveHstNumber.isNotEmpty;

  String get initials {
    final parts = displayName
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'М';
    if (parts.length == 1) {
      final word = parts.first;
      return word.substring(0, word.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  /// Подставляет реквизиты частного мастера в шаблон счетов и смет,
  /// полностью убирая налоговый номер, адрес и почту владельца.
  DocumentSettings applyToDocumentSettings(DocumentSettings shop) {
    final payMail = etransferEmail.trim();
    final baseTerms = shop.invoiceTerms.trim();
    final extraLines = <String>[
      if (payMail.isNotEmpty) 'Interac e-Transfer: $payMail',
      if (shop.companyName.trim().isNotEmpty &&
          effectiveBusinessName.toLowerCase() !=
              shop.companyName.trim().toLowerCase())
        'Service dispatched via ${shop.companyName.trim()}.',
    ];
    final terms = extraLines.isEmpty
        ? baseTerms
        : '${extraLines.join('  ')}\n$baseTerms'.trim();

    return shop.copyWith(
      companyName: effectiveBusinessName,
      companyEmail: payMail,
      companyAddress: '',
      technicianName: displayName,
      hstNumber: effectiveHstNumber,
      invoiceTerms: terms,
    );
  }

  factory TechnicianProfile.fromMap(Map<String, dynamic> map, String docId) {
    final rawPercent = map['profitSharePercent'];
    final percent = rawPercent is num
        ? rawPercent.toDouble()
        : (double.tryParse((rawPercent ?? '').toString()) ?? 50.0);
    final rawColor = map['colorValue'];
    final color = rawColor is num
        ? rawColor.toInt()
        : (int.tryParse((rawColor ?? '').toString()) ?? palette.first);
    final hst = (map['hstNumber'] ?? '').toString().trim();
    final collects = map['collectsHst'] is bool
        ? map['collectsHst'] as bool
        : hst.isNotEmpty;

    return TechnicianProfile(
      uid: (map['uid'] ?? docId).toString().trim().isEmpty
          ? docId
          : (map['uid'] ?? docId).toString().trim(),
      name: (map['name'] ?? '').toString().trim(),
      email: (map['email'] ?? '').toString().trim(),
      phone: (map['phone'] ?? '').toString().trim(),
      colorValue: color,
      profitSharePercent: percent.clamp(0.0, 100.0),
      businessName: (map['businessName'] ?? '').toString().trim(),
      collectsHst: collects,
      hstNumber: hst,
      etransferEmail: (map['etransferEmail'] ?? '').toString().trim(),
      active: map['active'] != false,
      createdAt: _parseTechDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name.trim(),
      'email': email.trim(),
      'phone': phone.trim(),
      'colorValue': colorValue,
      'profitSharePercent': clampedTechPercent,
      'businessName': businessName.trim(),
      'collectsHst': collectsHst,
      'hstNumber': hstNumber.trim(),
      'etransferEmail': etransferEmail.trim(),
      'active': active,
      if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
    };
  }

  TechnicianProfile copyWith({
    String? uid,
    String? name,
    String? email,
    String? phone,
    int? colorValue,
    double? profitSharePercent,
    String? businessName,
    bool? collectsHst,
    String? hstNumber,
    String? etransferEmail,
    bool? active,
    DateTime? createdAt,
  }) {
    return TechnicianProfile(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      colorValue: colorValue ?? this.colorValue,
      profitSharePercent: profitSharePercent ?? this.profitSharePercent,
      businessName: businessName ?? this.businessName,
      collectsHst: collectsHst ?? this.collectsHst,
      hstNumber: hstNumber ?? this.hstNumber,
      etransferEmail: etransferEmail ?? this.etransferEmail,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Запись о принятом владельцем расчёте от мастера («Принял расчёт»).
class TechnicianSettlement {
  final String id;
  final String technicianId;
  final String technicianName;
  final double amount;
  final String note;
  final List<String> jobIds;
  final DateTime createdAt;

  const TechnicianSettlement({
    required this.id,
    required this.technicianId,
    this.technicianName = '',
    required this.amount,
    this.note = '',
    this.jobIds = const [],
    required this.createdAt,
  });

  factory TechnicianSettlement.fromMap(
    Map<String, dynamic> map,
    String docId,
  ) {
    final rawAmount = map['amount'];
    final amount = rawAmount is num
        ? rawAmount.toDouble()
        : (double.tryParse((rawAmount ?? '').toString()) ?? 0.0);
    final rawJobs = map['jobIds'];
    return TechnicianSettlement(
      id: docId,
      technicianId: (map['technicianId'] ?? '').toString().trim(),
      technicianName: (map['technicianName'] ?? '').toString().trim(),
      amount: amount,
      note: (map['note'] ?? '').toString().trim(),
      jobIds: rawJobs is List
          ? rawJobs.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
          : const [],
      createdAt: _parseTechDate(map['createdAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'technicianId': technicianId.trim(),
      'technicianName': technicianName.trim(),
      'amount': amount,
      'note': note.trim(),
      if (jobIds.isNotEmpty) 'jobIds': jobIds,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
