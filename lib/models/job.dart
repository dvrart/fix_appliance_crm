import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/status_service.dart';

/// Единица техники в заявке
class JobAppliance {
  final String type;
  final String brand;
  final String model;
  final String serialNumber;
  final String issue;

  JobAppliance({
    required this.type,
    this.brand = '',
    this.model = '',
    this.serialNumber = '',
    this.issue = '',
  });

  factory JobAppliance.fromMap(Map<String, dynamic> map) {
    return JobAppliance(
      type: map['type'] ?? map['applianceType'] ?? '',
      brand: map['brand'] ?? '',
      model: map['model'] ?? '',
      serialNumber: map['serialNumber'] ?? '',
      issue: map['issue'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'brand': brand,
      'model': model,
      'serialNumber': serialNumber,
      'issue': issue,
    };
  }

  String get displayName {
    if (brand.isNotEmpty) return '$type $brand';
    return type;
  }
}

/// Один выезд внутри заявки (диагностика, повтор после запчасти и т.д.).
class JobVisit {
  static const String scheduled = 'scheduled';
  static const String done = 'done';
  static const String cancelled = 'cancelled';

  static const String confirmPending = 'pending';
  static const String confirmConfirmed = 'confirmed';
  static const String confirmReschedule = 'reschedule';
  static const String confirmCancelled = 'cancelled';

  final String id;
  final DateTime startAt;
  final int durationMinutes;
  final String note;
  final String outcome;
  final String smsBookingDayKey;
  final String smsBookingSlotKey;
  final DateTime? smsBookingSentAt;
  final DateTime? smsReminderSentAt;
  final String smsConfirmStatus;
  final String smsDialog;

  const JobVisit({
    required this.id,
    required this.startAt,
    this.durationMinutes = kDefaultVisitMinutes,
    this.note = '',
    this.outcome = scheduled,
    this.smsBookingDayKey = '',
    this.smsBookingSlotKey = '',
    this.smsBookingSentAt,
    this.smsReminderSentAt,
    this.smsConfirmStatus = '',
    this.smsDialog = '',
  });

  DateTime get endAt =>
      startAt.add(Duration(minutes: durationMinutes.clamp(15, 8 * 60)));

  bool get isDone => outcome == done;
  bool get isScheduled => outcome == scheduled;
  bool get isCancelled =>
      outcome == cancelled || smsConfirmStatus == confirmCancelled;
  bool get isActiveSlot => isScheduled && !isCancelled;

  /// pending / confirmed / reschedule / cancelled.
  String get effectiveConfirmStatus {
    if (smsConfirmStatus == confirmConfirmed ||
        smsConfirmStatus == confirmReschedule ||
        smsConfirmStatus == confirmCancelled) {
      return smsConfirmStatus;
    }
    if (smsConfirmStatus == confirmPending ||
        smsBookingSentAt != null ||
        smsReminderSentAt != null) {
      return confirmPending;
    }
    return '';
  }

  factory JobVisit.create({
    required DateTime startAt,
    int durationMinutes = kDefaultVisitMinutes,
    String note = '',
    String outcome = scheduled,
    String smsConfirmStatus = '',
  }) {
    return JobVisit(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      startAt: startAt,
      durationMinutes: durationMinutes.clamp(15, 8 * 60),
      note: note.trim(),
      outcome: outcome,
      smsConfirmStatus: smsConfirmStatus,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory JobVisit.fromMap(Map<String, dynamic> map) {
    final startAt = _parseDate(map['startAt']) ?? DateTime.now();
    var id = (map['id'] ?? '').toString();
    if (id.isEmpty) {
      id = 'v${startAt.microsecondsSinceEpoch}';
    }
    return JobVisit(
      id: id,
      startAt: startAt,
      durationMinutes: (map['durationMinutes'] as num?)?.toInt() ?? kDefaultVisitMinutes,
      note: (map['note'] ?? '').toString(),
      outcome: (map['outcome'] ?? scheduled).toString(),
      smsBookingDayKey: (map['smsBookingDayKey'] ?? '').toString(),
      smsBookingSlotKey: (map['smsBookingSlotKey'] ?? '').toString(),
      smsBookingSentAt: _parseDate(map['smsBookingSentAt']),
      smsReminderSentAt: _parseDate(map['smsReminderSentAt']),
      smsConfirmStatus: (map['smsConfirmStatus'] ?? '').toString(),
      smsDialog: (map['smsDialog'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'startAt': startAt,
      'durationMinutes': durationMinutes.clamp(15, 8 * 60),
      'note': note,
      'outcome': outcome,
      'smsBookingDayKey': smsBookingDayKey,
      'smsBookingSlotKey': smsBookingSlotKey,
      'smsBookingSentAt': smsBookingSentAt,
      'smsReminderSentAt': smsReminderSentAt,
      'smsConfirmStatus': smsConfirmStatus,
      'smsDialog': smsDialog,
    };
  }

  JobVisit copyWith({
    DateTime? startAt,
    int? durationMinutes,
    String? note,
    String? outcome,
    String? smsBookingDayKey,
    String? smsBookingSlotKey,
    DateTime? smsBookingSentAt,
    DateTime? smsReminderSentAt,
    String? smsConfirmStatus,
    String? smsDialog,
    bool clearSms = false,
    bool clearSmsDialog = false,
  }) {
    return JobVisit(
      id: id,
      startAt: startAt ?? this.startAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      note: note ?? this.note,
      outcome: outcome ?? this.outcome,
      smsBookingDayKey:
          clearSms ? '' : (smsBookingDayKey ?? this.smsBookingDayKey),
      smsBookingSlotKey:
          clearSms ? '' : (smsBookingSlotKey ?? this.smsBookingSlotKey),
      smsBookingSentAt:
          clearSms ? null : (smsBookingSentAt ?? this.smsBookingSentAt),
      smsReminderSentAt:
          clearSms ? null : (smsReminderSentAt ?? this.smsReminderSentAt),
      smsConfirmStatus:
          clearSms ? '' : (smsConfirmStatus ?? this.smsConfirmStatus),
      smsDialog: clearSms || clearSmsDialog
          ? ''
          : (smsDialog ?? this.smsDialog),
    );
  }

  JobVisit withManualConfirm(String status) {
    final next = status.trim().isEmpty ? confirmPending : status;
    var nextOutcome = outcome;
    if (outcome != done) {
      if (next == confirmCancelled) {
        nextOutcome = cancelled;
      } else if (outcome == cancelled) {
        nextOutcome = scheduled;
      }
    }
    return copyWith(
      smsConfirmStatus: next,
      outcome: nextOutcome,
      clearSmsDialog: true,
    );
  }

  static List<JobVisit> coalesce(
    List<JobVisit> visits, {
    DateTime? scheduledAt,
    int durationMinutes = kDefaultVisitMinutes,
  }) {
    if (visits.isNotEmpty) {
      final copy = [...visits]..sort((a, b) => a.startAt.compareTo(b.startAt));
      return copy;
    }
    if (scheduledAt == null) return const [];
    return [
      JobVisit(
        id: 'legacy',
        startAt: scheduledAt,
        durationMinutes: durationMinutes.clamp(15, 8 * 60),
      ),
    ];
  }

  /// Поля для Firestore: визиты + ближайший слот для старого кода.
  static Map<String, dynamic> syncFields(
    List<JobVisit> visits, {
    int defaultDuration = kDefaultVisitMinutes,
    bool upcomingOnly = false,
  }) {
    final sorted = [...visits]..sort((a, b) => a.startAt.compareTo(b.startAt));
    final now = DateTime.now();
    final planned = sorted.where((v) => v.isScheduled).toList();
    final JobVisit? next;
    if (upcomingOnly) {
      final upcoming = planned.where((v) => !v.startAt.isBefore(now)).toList();
      next = upcoming.isNotEmpty ? _latestScheduled(upcoming) : null;
    } else {
      next = _latestScheduled(planned.isNotEmpty ? planned : sorted);
    }
    return {
      'visits': sorted.map((v) => v.toMap()).toList(),
      'scheduledAt': next?.startAt,
      'scheduledDate': next?.startAt,
      'durationMinutes': next?.durationMinutes ?? defaultDuration,
    };
  }

  static bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static JobVisit? _latestScheduled(List<JobVisit> visits) {
    if (visits.isEmpty) return null;
    return visits.reduce((a, b) {
      final cmp = a.startAt.compareTo(b.startAt);
      if (cmp != 0) return cmp > 0 ? a : b;
      return a.id.compareTo(b.id) >= 0 ? a : b;
    });
  }

  /// Найти визит для карточки календаря (id, затем дата/время).
  static JobVisit? matchForAppointment(
    List<JobVisit> visits,
    String visitId,
    DateTime startTime,
  ) {
    for (final visit in visits) {
      if (visit.id == visitId) return visit;
    }
    for (final visit in visits) {
      if (visit.startAt == startTime) return visit;
    }
    for (final visit in visits) {
      if (isSameDay(visit.startAt, startTime) &&
          visit.startAt.hour == startTime.hour &&
          visit.startAt.minute == startTime.minute) {
        return visit;
      }
    }
    return null;
  }

  static String appointmentId(String jobId, String visitId) => '$jobId|$visitId';

  static String jobIdFromAppointment(Object? id) {
    final raw = id.toString();
    final i = raw.indexOf('|');
    return i < 0 ? raw : raw.substring(0, i);
  }

  static String visitIdFromAppointment(Object? id) {
    final raw = id.toString();
    final i = raw.indexOf('|');
    return i < 0 ? 'legacy' : raw.substring(i + 1);
  }

  static List<JobVisit> markLatestScheduledDone(List<JobVisit> visits) {
    final sorted = [...visits]..sort((a, b) => a.startAt.compareTo(b.startAt));
    final now = DateTime.now();
    var idx = -1;
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i].isScheduled && !sorted[i].startAt.isAfter(now)) {
        idx = i;
      }
    }
    if (idx < 0) {
      final hasDone = sorted.any((v) => v.isDone);
      if (hasDone) return sorted;
      for (var i = 0; i < sorted.length; i++) {
        if (sorted[i].isScheduled) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) return sorted;
    sorted[idx] = sorted[idx].copyWith(outcome: done);
    return sorted;
  }

  static List<JobVisit> markAllScheduledDone(List<JobVisit> visits) {
    return visits
        .map((v) => v.isScheduled ? v.copyWith(outcome: done) : v)
        .toList();
  }

  static List<JobVisit> markAllScheduledCancelled(List<JobVisit> visits) {
    return visits
        .map(
          (v) => v.isScheduled
              ? v.copyWith(
                  outcome: cancelled,
                  smsConfirmStatus: confirmCancelled,
                )
              : v,
        )
        .toList();
  }
}

/// Заявка / работа
/// Deposit and balance payment methods for an invoice card / list row.
class DocumentPayMethods {
  final String deposit;
  final String balance;

  const DocumentPayMethods({this.deposit = '', this.balance = ''});

  bool get hasAny => deposit.isNotEmpty || balance.isNotEmpty;
}

class Job {
  final String id;
  final String clientId;
  final String clientName;
  final String clientPhone;
  final String clientAddress;

  // Job Site (место работы, если отличается от адреса владельца)
  final bool hasJobSite;
  final String? jobSiteName;
  final String? jobSitePhone;
  final String? jobSiteAddress;
  final String? jobSiteEmail;

  final List<JobAppliance> appliances;
  final String description;
  final String solution;
  final String status;
  final String priority;
  final String? assignedTo; // ID мастера (для 1-3 мастеров)

  final DateTime? scheduledAt;
  final List<JobVisit> visits;
  final DateTime? completedAt;
  final DateTime createdAt;

  final List<Map<String, dynamic>> documents; // invoices, estimates
  final List<Map<String, dynamic>> attachments; // фото
  final String? city; // для группировки
  final bool needsReview;
  final bool createdByAi;
  final String? sourceCallId;
  final String? sourceEmailId;
  /// `phone` / `email` when the job came from a call or a letter.
  final String source;
  final String sourceEmailFrom;
  final String sourceEmailSubject;
  final String sourceEmailPreview;
  final int durationMinutes;
  final String packingNotes;
  final String trackingNumber;
  final String trackingCarrier;
  final String trackingStatus;
  final String amazonOrderId;
  /// Исходная заявка, если это повторный вызов по той же неисправности.
  final String? repeatOfJobId;
  final DateTime? deletedAt;

  Job({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    required this.clientAddress,
    this.hasJobSite = false,
    this.jobSiteName,
    this.jobSitePhone,
    this.jobSiteAddress,
    this.jobSiteEmail,
    this.appliances = const [],
    this.description = '',
    this.solution = '',
    this.status = 'Вызов',
    this.priority = '🟢 Обычный',
    this.assignedTo,
    this.scheduledAt,
    this.visits = const [],
    this.completedAt,
    required this.createdAt,
    this.documents = const [],
    this.attachments = const [],
    this.city,
    this.needsReview = false,
    this.createdByAi = false,
    this.sourceCallId,
    this.sourceEmailId,
    this.source = '',
    this.sourceEmailFrom = '',
    this.sourceEmailSubject = '',
    this.sourceEmailPreview = '',
    this.durationMinutes = kDefaultVisitMinutes,
    this.packingNotes = '',
    this.trackingNumber = '',
    this.trackingCarrier = '',
    this.trackingStatus = '',
    this.amazonOrderId = '',
    this.repeatOfJobId,
    this.deletedAt,
  });

  bool get isRepeatCall =>
      repeatOfJobId != null && repeatOfJobId!.trim().isNotEmpty;

  /// `phone`, `email`, or empty for a job created in the app.
  String get intakeSource => intakeSourceOf(
        null,
        source: source,
        sourceCallId: sourceCallId,
        sourceEmailId: sourceEmailId,
      );

  /// Secretary / SMS / email draft that FIX has not confirmed yet.
  bool get isUnconfirmedAuto => isUnconfirmedAutoMap({
        'needsReview': needsReview,
        'createdByAi': createdByAi,
        'source': source,
        'sourceCallId': sourceCallId,
        'sourceEmailId': sourceEmailId,
      });

  static bool isUnconfirmedAutoMap(Map<String, dynamic>? map) {
    if (map == null) return false;
    if (map['needsReview'] != true) return false;
    if (map['createdByAi'] == true) return true;
    return intakeSourceOf(map).isNotEmpty;
  }

  static String intakeSourceOf(
    Map<String, dynamic>? map, {
    String? source,
    String? sourceCallId,
    String? sourceEmailId,
  }) {
    final data = map ?? const <String, dynamic>{};
    final raw = (source ?? data['source'] ?? '').toString().trim().toLowerCase();
    if (raw == 'website' || raw == 'web' || raw == 'сайт') return 'website';
    if (raw == 'email' || raw == 'mail' || raw == 'почта') return 'email';
    if (raw == 'sms' || raw == 'text' || raw == 'смс') return 'sms';
    if (raw == 'phone' || raw == 'call' || raw == 'телефон') return 'phone';
    final emailId =
        (sourceEmailId ?? data['sourceEmailId'] ?? '').toString().trim();
    if (emailId.isNotEmpty) return 'email';
    final callId =
        (sourceCallId ?? data['sourceCallId'] ?? '').toString().trim();
    if (callId.isNotEmpty) return 'phone';
    return '';
  }

  static String intakeSourceLabel(String source) {
    switch (source) {
      case 'website':
        return 'Сайт';
      case 'email':
        return 'Почта';
      case 'sms':
        return 'SMS';
      case 'phone':
        return 'Телефон';
      default:
        return '';
    }
  }

  static IconData intakeSourceIcon(String source) {
    switch (source) {
      case 'website':
        return Icons.language;
      case 'email':
        return Icons.email_outlined;
      case 'sms':
        return Icons.sms_outlined;
      case 'phone':
        return Icons.phone_in_talk;
      default:
        return Icons.flag_outlined;
    }
  }

  static Color intakeSourceColor(String source) {
    switch (source) {
      case 'website':
        return const Color(0xFF6A1B9A);
      case 'email':
        return const Color(0xFF2E7D32);
      case 'sms':
        return const Color(0xFF0277BD);
      case 'phone':
        return const Color(0xFF008F3B);
      default:
        return const Color(0xFF546E7A);
    }
  }

  /// Адрес для навигации (Job Site или адрес клиента)
  String get workAddress => hasJobSite ? (jobSiteAddress ?? clientAddress) : clientAddress;

  /// Город для шторки и группировки: поле city или кусок адреса.
  String get displayCity {
    final raw = (city ?? '').trim();
    if (raw.isNotEmpty) return raw;
    return cityFromAddress(workAddress);
  }

  static String cityFromAddress(String address) {
    final parts = address
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final postalRe = RegExp(r'^[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d$');
    if (parts.length >= 2 && postalRe.hasMatch(parts.last)) {
      return parts.length >= 3 ? parts[parts.length - 2] : '';
    }
    if (parts.length >= 2) return parts.last;
    return '';
  }

  /// Контактное имя на месте
  String get contactName => hasJobSite ? (jobSiteName ?? clientName) : clientName;

  /// Контактный телефон на месте
  String get contactPhone => hasJobSite ? (jobSitePhone ?? clientPhone) : clientPhone;

  /// В корзине 30 дней после удаления.
  bool get isDeleted => deletedAt != null;

  static DateTime? documentDeletedAt(Map doc) {
    final raw = doc['deletedAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  static bool isDocumentTrashed(Map doc) => documentDeletedAt(doc) != null;

  static int documentTrashDaysLeft(Map doc) {
    final deleted = documentDeletedAt(doc);
    if (deleted == null) return 0;
    final days =
        deleted.add(const Duration(days: trashKeepDays)).difference(DateTime.now()).inDays;
    return days < 0 ? 0 : days;
  }

  static const trashKeepDays = 30;

  DateTime? get trashExpiresAt =>
      deletedAt?.add(const Duration(days: trashKeepDays));

  int get trashDaysLeft {
    final exp = trashExpiresAt;
    if (exp == null) return 0;
    final days = exp.difference(DateTime.now()).inDays;
    if (days < 0) return 0;
    return days;
  }

  /// Открытые заявки без даты визита (ещё не в календаре).
  bool get isUnscheduled {
    if (isDeleted) return false;
    if (JobStatuses.isClosed(status)) return false;
    return coalescedVisits.isEmpty;
  }

  /// Заявки без даты визита — раньше жили в «корзине».
  bool get isBasketItem => isUnscheduled;

  /// Основная техника (первая в списке)
  JobAppliance? get primaryAppliance => appliances.isNotEmpty ? appliances.first : null;

  /// Тип техники для отображения
  String get applianceType => primaryAppliance?.type ?? 'Техника';

  /// Бренд техники для отображения
  String get applianceBrand => primaryAppliance?.brand ?? '';

  /// Иконка техники
  IconData get applianceIcon => ApplianceCategories.getIcon(applianceType);

  /// Что взять с собой: техника + позиции из счетов/смет.
  List<String> get packingList {
    final names = <String>[];
    final seen = <String>{};

    void add(String raw) {
      final text = raw.trim();
      if (text.isEmpty) return;
      final key = text.toLowerCase();
      if (seen.contains(key)) return;
      seen.add(key);
      names.add(text);
    }

    for (final appliance in appliances) {
      add(appliance.displayName);
    }
    if (names.isEmpty && description.trim().isNotEmpty) {
      add(description.trim());
    }
    for (final note in packingNotes.split(RegExp(r'[,;\n]'))) {
      add(note);
    }
    for (final doc in documents) {
      final status = (doc['status'] ?? '').toString().toLowerCase();
      if (status.contains('void') ||
          status.contains('cancel') ||
          status.contains('отмен')) {
        continue;
      }
      final items = doc['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is Map) {
          add((item['name'] ?? '').toString());
        }
      }
    }
    return names;
  }

  /// Запчасти, которых ждём по заявке (заметки и позиции счетов).
  List<String> get expectedParts {
    final names = <String>[];
    final seen = <String>{};

    void add(String raw) {
      final text = raw.trim();
      if (text.isEmpty) return;
      final key = text.toLowerCase();
      if (seen.contains(key)) return;
      seen.add(key);
      names.add(text);
    }

    for (final note in packingNotes.split(RegExp(r'[,;\n]'))) {
      add(note);
    }
    for (final doc in documents) {
      final status = (doc['status'] ?? '').toString().toLowerCase();
      if (status.contains('void') ||
          status.contains('cancel') ||
          status.contains('отмен')) {
        continue;
      }
      final items = doc['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is Map) {
          add((item['name'] ?? '').toString());
        }
      }
    }
    return names;
  }

  DateTime? get scheduledEnd {
    if (scheduledAt == null) return null;
    return scheduledAt!.add(Duration(minutes: durationMinutes.clamp(15, 8 * 60)));
  }

  List<JobVisit> get coalescedVisits => JobVisit.coalesce(
        visits,
        scheduledAt: scheduledAt,
        durationMinutes: durationMinutes,
      );

  /// Последний по дате визит — текущий слот заявки.
  JobVisit? get latestVisit {
    final items = coalescedVisits;
    if (items.isEmpty) return null;
    return items.reduce((a, b) {
      final cmp = a.startAt.compareTo(b.startAt);
      if (cmp != 0) return cmp > 0 ? a : b;
      return a.id.compareTo(b.id) >= 0 ? a : b;
    });
  }

  /// Старые выезды показываем как «Перенос», последний — текущий статус заявки.
  String displayStatusForVisit(JobVisit? visit) {
    if (JobStatuses.isCancelledStatus(status)) return status;
    final items = coalescedVisits;
    if (visit == null || items.length < 2) return status;
    final latest = latestVisit;
    if (latest == null) return status;
    if (visit.id == latest.id || visit.startAt == latest.startAt) return status;
    return JobStatuses.rescheduled;
  }

  JobVisit? visitOn(DateTime day) {
    for (final visit in coalescedVisits) {
      if (JobVisit.isSameDay(visit.startAt, day)) return visit;
    }
    return null;
  }

  bool hasVisitOn(DateTime day) => visitOn(day) != null;

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double documentSubtotal(Map doc) {
    final items = doc['items'];
    if (items is! List) return 0;
    var total = 0.0;
    for (final item in items) {
      if (item is! Map) continue;
      final qty = _toDouble(item['qty'] == null ? 1 : item['qty']);
      total += qty * _toDouble(item['price']);
    }
    return total;
  }

  static double documentTotal(Map doc) {
    return documentSubtotal(doc) + documentTax(doc);
  }

  static double documentTax(Map doc) {
    return documentSubtotal(doc) * _toDouble(doc['taxRate']);
  }

  static double documentPaid(Map doc) {
    final payments = doc['payments'];
    if (payments is! List) return 0;
    var total = 0.0;
    for (final payment in payments) {
      if (payment is Map) total += _toDouble(payment['amount']);
    }
    if (total == 0 && (doc['stripe'] is Map) && doc['stripe']['status'] == 'paid') {
      return documentTotal(doc);
    }
    return total;
  }

  static bool isInvoice(Map doc) {
    final type = (doc['type'] ?? 'Invoice').toString();
    if (type == 'Estimate') return false;
    final status = (doc['status'] ?? '').toString().toLowerCase();
    if (status.contains('cancel') || status.contains('void') || status.contains('отмен')) {
      return false;
    }
    return true;
  }

  /// Invoice payment mark for lists: `paid`, `deposit`, `unpaid`, `refunded`. Empty for estimates.
  static String documentPayMark(Map doc) {
    if (!isInvoice(doc) || isDocumentTrashed(doc)) return '';
    final total = documentTotal(doc);
    final paid = documentPaid(doc);
    final due = (total - paid);
    final stripe = doc['stripe'];
    final stripeStatus =
        stripe is Map ? (stripe['status'] ?? '').toString() : '';
    if (stripeStatus == 'refunded' ||
        (paid <= 0.009 && _hasRefundPayment(doc))) {
      return 'refunded';
    }
    if (total > 0 && due <= 0.009) return 'paid';
    final mode = stripe is Map ? (stripe['mode'] ?? '').toString() : '';
    if (mode == 'deposit' ||
        stripeStatus == 'partially_refunded' ||
        (paid > 0.009 && due > 0.009)) {
      return 'deposit';
    }
    return 'unpaid';
  }

  /// Deposit vs balance payment methods from the payments list.
  /// Partial payments → deposit; the payment that closes the invoice → balance.
  /// A single full payment is balance only.
  static DocumentPayMethods documentPayMethods(Map doc) {
    if (!isInvoice(doc)) return const DocumentPayMethods();
    final total = documentTotal(doc);
    final rows = <({double amount, String method, DateTime at})>[];
    final payments = doc['payments'];
    if (payments is List) {
      for (final payment in payments) {
        if (payment is! Map) continue;
        final amount = _toDouble(payment['amount']);
        final method = (payment['method'] ?? '').toString().trim();
        final lower = method.toLowerCase();
        if (amount <= 0.009) continue;
        if (lower.contains('tip') ||
            lower.contains('чаевые') ||
            lower.contains('refund') ||
            lower.contains('возврат')) {
          continue;
        }
        rows.add((
          amount: amount,
          method: method.isEmpty ? 'Payment' : method,
          at: _paymentDate(payment['date']),
        ));
      }
    }
    rows.sort((a, b) => a.at.compareTo(b.at));

    final deposit = <String>[];
    final balance = <String>[];
    var paid = 0.0;
    for (final row in rows) {
      if (total > 0 && paid >= total - 0.009) break;
      final after = paid + row.amount;
      final closes = total <= 0 || after >= total - 0.009;
      final label = paymentMethodLabel(row.method);
      if (closes) {
        _appendUnique(balance, label);
      } else {
        _appendUnique(deposit, label);
      }
      paid = after;
    }

    if (deposit.isEmpty &&
        balance.isEmpty &&
        doc['stripe'] is Map &&
        (doc['stripe']['status'] ?? '').toString() == 'paid') {
      final mode = (doc['stripe']['mode'] ?? '').toString();
      _appendUnique(
        balance,
        paymentMethodLabel(mode == 'deposit' ? 'Stripe (deposit)' : 'Stripe'),
      );
    }

    return DocumentPayMethods(
      deposit: deposit.join(' · '),
      balance: balance.join(' · '),
    );
  }

  /// Short label for lists: Cash, e-Transfer, Stripe, …
  static String paymentMethodLabel(String method) {
    final m = method.trim();
    final lower = m.toLowerCase();
    if (lower == 'наличные' || lower == 'cash') return 'Cash';
    if (lower == 'e-transfer' || lower == 'etransfer' || lower == 'interac') {
      return 'e-Transfer';
    }
    if (lower.contains('stripe (card present)')) return 'Stripe (card)';
    if (lower.contains('stripe (deposit)')) return 'Stripe';
    if (lower.contains('stripe')) return 'Stripe';
    if (lower == 'оплата' || lower == 'payment') return 'Payment';
    return m;
  }

  static void _appendUnique(List<String> list, String value) {
    if (value.isEmpty || list.contains(value)) return;
    list.add(value);
  }

  static DateTime _paymentDate(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is Timestamp) return raw.toDate();
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime(1970);
    return DateTime(1970);
  }

  static bool _hasRefundPayment(Map doc) {
    final payments = doc['payments'];
    if (payments is! List) return false;
    for (final payment in payments) {
      if (payment is! Map) continue;
      final amount = _toDouble(payment['amount']);
      final method = (payment['method'] ?? '').toString().toLowerCase();
      if (amount < -0.009 ||
          method.contains('refund') ||
          method.contains('возврат')) {
        return true;
      }
    }
    return false;
  }

  double get invoicedTotal {
    var total = 0.0;
    for (final doc in documents) {
      if (isInvoice(doc)) total += documentTotal(doc);
    }
    return total;
  }

  double get paidTotal {
    var total = 0.0;
    for (final doc in documents) {
      if (isInvoice(doc)) total += documentPaid(doc);
    }
    return total;
  }

  double get dueTotal => (invoicedTotal - paidTotal).clamp(0, double.infinity);

  bool get isUnpaid => invoicedTotal > 0 && dueTotal > 0.009;

  String get paymentLabel {
    if (invoicedTotal <= 0) return 'Нет счёта';
    if (dueTotal <= 0.009) return 'Оплачено';
    if (paidTotal > 0) return 'Частично';
    return 'Неоплачено';
  }

  /// Цвет статуса
  Color get statusColor => StatusService.colorOf(status);

  /// Цвет приоритета
  Color get priorityColor => JobPriorities.getColor(priority);

  factory Job.fromMap(Map<String, dynamic> map, String docId) {
    List<JobAppliance> appliancesList = [];

    try {
      final rawAppliances = map['appliances'] ?? map['appliancesList'];
      if (rawAppliances is List && rawAppliances.isNotEmpty) {
        appliancesList = rawAppliances
            .whereType<Map>()
            .map((a) => JobAppliance.fromMap(Map<String, dynamic>.from(a)))
            .toList();
      }
    } catch (_) {}

    if (appliancesList.isEmpty &&
        (map['applianceType'] != null || map['brand'] != null || map['model'] != null)) {
      appliancesList.add(JobAppliance(
        type: map['applianceType'] ?? '',
        brand: map['brand'] ?? '',
        model: map['model'] ?? '',
        serialNumber: map['serialNumber'] ?? '',
        issue: map['description'] ?? '',
      ));
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value);
      return null;
    }

    List<Map<String, dynamic>> asMapList(dynamic value) {
      if (value is! List) return [];
      return value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }

    final scheduledAt = parseDate(map['scheduledAt']) ?? parseDate(map['scheduledDate']);
    final durationMinutes = (map['durationMinutes'] as num?)?.toInt() ?? kDefaultVisitMinutes;
    final parsedVisits = asMapList(map['visits']).map(JobVisit.fromMap).toList();
    final visits = JobVisit.coalesce(
      parsedVisits,
      scheduledAt: scheduledAt,
      durationMinutes: durationMinutes,
    );
    final synced = JobVisit.syncFields(visits, defaultDuration: durationMinutes);

    return Job(
      id: docId,
      clientId: map['clientId'] ?? '',
      clientName: (map['clientName'] ?? map['name'] ?? '').toString(),
      clientPhone: map['clientPhone'] ?? '',
      clientAddress: map['clientAddress'] ?? '',
      hasJobSite: map['hasJobSite'] ?? false,
      jobSiteName: map['jobSiteName'],
      jobSitePhone: map['jobSitePhone'],
      jobSiteAddress: map['jobSiteAddress'],
      jobSiteEmail: (map['jobSiteEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (map['jobSiteEmail'] ?? '').toString().trim(),
      appliances: appliancesList,
      description: map['description'] ?? '',
      solution: (map['solution'] ?? '').toString(),
      status: map['status'] ?? 'Вызов',
      priority: map['priority'] ?? '🟢 Обычный',
      assignedTo: map['assignedTo'],
      scheduledAt: synced['scheduledAt'] as DateTime?,
      visits: visits,
      completedAt: parseDate(map['completedAt']),
      createdAt: parseDate(map['createdAt']) ?? DateTime.now(),
      documents: asMapList(map['documents']),
      attachments: asMapList(map['attachments']),
      city: map['city'] ?? map['displayCity'],
      needsReview: map['needsReview'] == true,
      createdByAi: map['createdByAi'] == true,
      sourceCallId: map['sourceCallId'] as String?,
      sourceEmailId: map['sourceEmailId'] as String?,
      source: (map['source'] ?? '').toString(),
      sourceEmailFrom: (map['sourceEmailFrom'] ?? '').toString(),
      sourceEmailSubject: (map['sourceEmailSubject'] ?? '').toString(),
      sourceEmailPreview: (map['sourceEmailPreview'] ?? '').toString(),
      durationMinutes: (synced['durationMinutes'] as int?) ?? durationMinutes,
      packingNotes: (map['packingNotes'] as String?) ?? '',
      trackingNumber: (map['trackingNumber'] ?? '').toString(),
      trackingCarrier: (map['trackingCarrier'] ?? '').toString(),
      trackingStatus: (map['trackingStatus'] ?? '').toString(),
      amazonOrderId: (map['amazonOrderId'] ?? '').toString(),
      repeatOfJobId: (map['repeatOfJobId'] ?? '').toString().trim().isEmpty
          ? null
          : (map['repeatOfJobId'] ?? '').toString().trim(),
      deletedAt: parseDate(map['deletedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'clientId': clientId,
      'clientName': clientName,
      'clientPhone': clientPhone,
      'clientAddress': clientAddress,
      'hasJobSite': hasJobSite,
      'jobSiteName': jobSiteName,
      'jobSitePhone': jobSitePhone,
      'jobSiteAddress': jobSiteAddress,
      'jobSiteEmail': jobSiteEmail,
      'appliances': appliances.map((a) => a.toMap()).toList(),
      // Для обратной совместимости
      'applianceType': applianceType,
      'brand': applianceBrand,
      'model': primaryAppliance?.model ?? '',
      'serialNumber': primaryAppliance?.serialNumber ?? '',
      'description': description,
      'solution': solution,
      'status': status,
      'priority': priority,
      'assignedTo': assignedTo,
      'completedAt': completedAt,
      'documents': documents,
      'attachments': attachments,
      'city': city,
      'needsReview': needsReview,
      'createdByAi': createdByAi,
      'sourceCallId': sourceCallId,
      'sourceEmailId': sourceEmailId,
      'source': source,
      'sourceEmailFrom': sourceEmailFrom,
      'sourceEmailSubject': sourceEmailSubject,
      'sourceEmailPreview': sourceEmailPreview,
      'packingNotes': packingNotes,
      'trackingNumber': trackingNumber,
      'trackingCarrier': trackingCarrier,
      'trackingStatus': trackingStatus,
      'amazonOrderId': amazonOrderId,
      'repeatOfJobId': repeatOfJobId,
      'updatedAt': FieldValue.serverTimestamp(),
      ...JobVisit.syncFields(
        coalescedVisits,
        defaultDuration: durationMinutes,
      ),
    };
  }

  Job copyWith({
    String? id,
    String? clientId,
    String? clientName,
    String? clientPhone,
    String? clientAddress,
    bool? hasJobSite,
    String? jobSiteName,
    String? jobSitePhone,
    String? jobSiteAddress,
    String? jobSiteEmail,
    List<JobAppliance>? appliances,
    String? description,
    String? solution,
    String? status,
    String? priority,
    String? assignedTo,
    DateTime? scheduledAt,
    List<JobVisit>? visits,
    DateTime? completedAt,
    DateTime? createdAt,
    List<Map<String, dynamic>>? documents,
    List<Map<String, dynamic>>? attachments,
    String? city,
    bool? needsReview,
    bool? createdByAi,
    String? sourceCallId,
    String? sourceEmailId,
    String? source,
    String? sourceEmailFrom,
    String? sourceEmailSubject,
    String? sourceEmailPreview,
    int? durationMinutes,
    String? packingNotes,
    String? trackingNumber,
    String? trackingCarrier,
    String? trackingStatus,
    String? amazonOrderId,
    String? repeatOfJobId,
    DateTime? deletedAt,
  }) {
    return Job(
      id: id ?? this.id,
      clientId: clientId ?? this.clientId,
      clientName: clientName ?? this.clientName,
      clientPhone: clientPhone ?? this.clientPhone,
      clientAddress: clientAddress ?? this.clientAddress,
      hasJobSite: hasJobSite ?? this.hasJobSite,
      jobSiteName: jobSiteName ?? this.jobSiteName,
      jobSitePhone: jobSitePhone ?? this.jobSitePhone,
      jobSiteAddress: jobSiteAddress ?? this.jobSiteAddress,
      jobSiteEmail: jobSiteEmail ?? this.jobSiteEmail,
      appliances: appliances ?? this.appliances,
      description: description ?? this.description,
      solution: solution ?? this.solution,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      assignedTo: assignedTo ?? this.assignedTo,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      visits: visits ?? this.visits,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
      documents: documents ?? this.documents,
      attachments: attachments ?? this.attachments,
      city: city ?? this.city,
      needsReview: needsReview ?? this.needsReview,
      createdByAi: createdByAi ?? this.createdByAi,
      sourceCallId: sourceCallId ?? this.sourceCallId,
      sourceEmailId: sourceEmailId ?? this.sourceEmailId,
      source: source ?? this.source,
      sourceEmailFrom: sourceEmailFrom ?? this.sourceEmailFrom,
      sourceEmailSubject: sourceEmailSubject ?? this.sourceEmailSubject,
      sourceEmailPreview: sourceEmailPreview ?? this.sourceEmailPreview,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      packingNotes: packingNotes ?? this.packingNotes,
      trackingNumber: trackingNumber ?? this.trackingNumber,
      trackingCarrier: trackingCarrier ?? this.trackingCarrier,
      trackingStatus: trackingStatus ?? this.trackingStatus,
      amazonOrderId: amazonOrderId ?? this.amazonOrderId,
      repeatOfJobId: repeatOfJobId ?? this.repeatOfJobId,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
