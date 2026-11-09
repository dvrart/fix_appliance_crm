import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/sms_text.dart';
import '../services/app_time_service.dart';
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

/// Заказанная запчасть для отслеживания доставки (Amazon, Reliable Parts и др.).
class JobTrackingOrder {
  final String id;
  final String part;
  final String carrier;
  final String trackingNumber;
  final String orderId;
  final String status;

  const JobTrackingOrder({
    this.id = '',
    this.part = '',
    this.carrier = '',
    this.trackingNumber = '',
    this.orderId = '',
    this.status = '',
  });

  bool get isEmpty =>
      part.trim().isEmpty &&
      carrier.trim().isEmpty &&
      trackingNumber.trim().isEmpty &&
      orderId.trim().isEmpty &&
      status.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  String get effectiveCarrier {
    if (isEmpty) return '';
    final c = carrier.trim();
    if (c.isNotEmpty) return c;
    if (orderId.trim().isNotEmpty ||
        trackingNumber.trim().toUpperCase().startsWith('TBA')) {
      return 'amazon';
    }
    return 'other';
  }

  JobTrackingOrder copyWith({
    String? id,
    String? part,
    String? carrier,
    String? trackingNumber,
    String? orderId,
    String? status,
  }) {
    return JobTrackingOrder(
      id: id ?? this.id,
      part: part ?? this.part,
      carrier: carrier ?? this.carrier,
      trackingNumber: trackingNumber ?? this.trackingNumber,
      orderId: orderId ?? this.orderId,
      status: status ?? this.status,
    );
  }

  factory JobTrackingOrder.fromMap(Map<String, dynamic> map) {
    final orderId =
        (map['orderId'] ?? map['amazonOrderId'] ?? map['trackingOrderId'] ?? '')
            .toString()
            .trim();
    return JobTrackingOrder(
      id: (map['id'] ?? '').toString().trim(),
      part: (map['part'] ?? map['trackingPart'] ?? '').toString().trim(),
      carrier:
          (map['carrier'] ?? map['trackingCarrier'] ?? map['supplier'] ?? '')
              .toString()
              .trim(),
      trackingNumber: (map['trackingNumber'] ?? map['number'] ?? '')
          .toString()
          .trim(),
      orderId: orderId,
      status: (map['status'] ?? map['trackingStatus'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() {
    final resolvedCarrier = effectiveCarrier;
    return {
      if (id.trim().isNotEmpty) 'id': id.trim(),
      'part': part.trim(),
      'carrier': resolvedCarrier,
      'trackingNumber': trackingNumber.trim(),
      'orderId': orderId.trim(),
      'amazonOrderId': orderId.trim(),
      if (status.trim().isNotEmpty) 'status': status.trim(),
    };
  }

  static List<JobTrackingOrder> parseList(Map<String, dynamic> map) {
    final raw = map['trackingOrders'];
    if (raw is List && raw.isNotEmpty) {
      final parsed = <JobTrackingOrder>[];
      for (final item in raw) {
        if (item is Map) {
          final order = JobTrackingOrder.fromMap(
            Map<String, dynamic>.from(item),
          );
          if (order.isNotEmpty) parsed.add(order);
        }
      }
      if (parsed.isNotEmpty) return parsed;
    }
    final legacy = JobTrackingOrder(
      part: (map['trackingPart'] ?? '').toString().trim(),
      carrier: (map['trackingCarrier'] ?? '').toString().trim(),
      trackingNumber: (map['trackingNumber'] ?? '').toString().trim(),
      orderId: (map['amazonOrderId'] ?? '').toString().trim(),
      status: (map['trackingStatus'] ?? '').toString().trim(),
    );
    if (legacy.isNotEmpty) return [legacy];
    return const [];
  }

  @override
  bool operator ==(Object other) =>
      other is JobTrackingOrder &&
      part.trim() == other.part.trim() &&
      effectiveCarrier == other.effectiveCarrier &&
      trackingNumber.trim() == other.trackingNumber.trim() &&
      orderId.trim() == other.orderId.trim() &&
      status.trim() == other.status.trim();

  @override
  int get hashCode => Object.hash(
    part.trim(),
    effectiveCarrier,
    trackingNumber.trim(),
    orderId.trim(),
    status.trim(),
  );
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
  final Map<String, dynamic> smsBooking;
  final String smsBookingDayKey;
  final String smsBookingSlotKey;
  final DateTime? smsBookingSentAt;
  final DateTime? smsBookingPendingAt;
  final DateTime? smsReminderSentAt;

  /// Какие напоминания сервер уже отправил (`morning`, `24h`, `2h` → когда).
  /// Поле серверное; приложение его только проносит, чтобы не стереть при
  /// сохранении — иначе напоминание уходило повторно.
  final Map<String, dynamic> smsReminders;
  final String smsConfirmStatus;
  final String smsConfirmNotifiedStatus;
  final DateTime? ownerSoonAt;
  final String smsDialog;
  final bool smsBookingPending;
  final bool smsBookingSentSms;
  final bool smsBookingSentEmail;
  final String smsBookingVia;

  const JobVisit({
    required this.id,
    required this.startAt,
    this.durationMinutes = kDefaultVisitMinutes,
    this.note = '',
    this.outcome = scheduled,
    this.smsBooking = const {},
    this.smsBookingDayKey = '',
    this.smsBookingSlotKey = '',
    this.smsBookingSentAt,
    this.smsBookingPendingAt,
    this.smsReminderSentAt,
    this.smsReminders = const {},
    this.smsConfirmStatus = '',
    this.smsConfirmNotifiedStatus = '',
    this.ownerSoonAt,
    this.smsDialog = '',
    this.smsBookingPending = false,
    this.smsBookingSentSms = false,
    this.smsBookingSentEmail = false,
    this.smsBookingVia = '',
  });

  DateTime get endAt =>
      startAt.add(Duration(minutes: durationMinutes.clamp(15, 8 * 60)));

  bool get isDone => outcome == done;
  bool get isScheduled => outcome == scheduled;
  bool get isCancelled =>
      outcome == cancelled || smsConfirmStatus == confirmCancelled;
  bool get isActiveSlot => isScheduled && !isCancelled;

  static String _bookingKey(String raw) => raw.trim().replaceFirstMapped(
    RegExp(r'^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})$'),
    (match) => '${match[1]}T${match[2]}',
  );

  String get bookingSmsState {
    final slotKey = AppTimeService.bookingSlotKey(startAt);
    if (smsBooking.isNotEmpty) {
      final nestedSlotKey = _bookingKey((smsBooking['slotKey'] ?? '').toString());
      return nestedSlotKey == slotKey
          ? (smsBooking['state'] ?? '').toString()
          : '';
    }
    final legacySlotKey = _bookingKey(smsBookingSlotKey);
    if (legacySlotKey.isNotEmpty && legacySlotKey != slotKey) return '';
    if (smsBookingPending) return 'pending';
    final via = smsBookingVia.trim().toLowerCase();
    if (smsBookingSentAt != null &&
        (smsBookingSentSms || via.isEmpty || via == 'sms' || via == 'both')) {
      return 'sent';
    }
    return '';
  }

  bool get bookingSmsInProgress {
    final state = bookingSmsState;
    return state == 'approved' || state == 'sending';
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
      smsBooking: map['smsBooking'] is Map
          ? Map<String, dynamic>.from(map['smsBooking'] as Map)
          : const {},
      smsBookingDayKey: (map['smsBookingDayKey'] ?? '').toString(),
      smsBookingSlotKey: (map['smsBookingSlotKey'] ?? '').toString(),
      smsBookingSentAt: _parseDate(map['smsBookingSentAt']),
      smsBookingPendingAt: _parseDate(map['smsBookingPendingAt']),
      smsReminderSentAt: _parseDate(map['smsReminderSentAt']),
      smsReminders: map['smsReminders'] is Map
          ? Map<String, dynamic>.from(map['smsReminders'] as Map)
          : const {},
      smsConfirmStatus: (map['smsConfirmStatus'] ?? '').toString(),
      smsConfirmNotifiedStatus:
          (map['smsConfirmNotifiedStatus'] ?? '').toString(),
      ownerSoonAt: _parseDate(map['ownerSoonAt']),
      smsDialog: (map['smsDialog'] ?? '').toString(),
      smsBookingPending: map['smsBookingPending'] == true,
      smsBookingSentSms: map['smsBookingSentSms'] == true,
      smsBookingSentEmail: map['smsBookingSentEmail'] == true,
      smsBookingVia: (map['smsBookingVia'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'startAt': startAt,
      'durationMinutes': durationMinutes.clamp(15, 8 * 60),
      'note': note,
      'outcome': outcome,
      'smsBooking': smsBooking,
      'smsBookingDayKey': smsBookingDayKey,
      'smsBookingSlotKey': smsBookingSlotKey,
      'smsBookingSentAt': smsBookingSentAt,
      'smsBookingPendingAt': smsBookingPendingAt,
      'smsReminderSentAt': smsReminderSentAt,
      'smsReminders': smsReminders,
      'smsConfirmStatus': smsConfirmStatus,
      if (smsConfirmNotifiedStatus.isNotEmpty)
        'smsConfirmNotifiedStatus': smsConfirmNotifiedStatus,
      if (ownerSoonAt != null) 'ownerSoonAt': ownerSoonAt,
      'smsDialog': smsDialog,
      'smsBookingPending': smsBookingPending,
      'smsBookingSentSms': smsBookingSentSms,
      'smsBookingSentEmail': smsBookingSentEmail,
      'smsBookingVia': smsBookingVia,
    };
  }

  JobVisit copyWith({
    DateTime? startAt,
    int? durationMinutes,
    String? note,
    String? outcome,
    Map<String, dynamic>? smsBooking,
    String? smsBookingDayKey,
    String? smsBookingSlotKey,
    DateTime? smsBookingSentAt,
    DateTime? smsBookingPendingAt,
    DateTime? smsReminderSentAt,
    Map<String, dynamic>? smsReminders,
    String? smsConfirmStatus,
    String? smsConfirmNotifiedStatus,
    DateTime? ownerSoonAt,
    String? smsDialog,
    bool? smsBookingPending,
    bool? smsBookingSentSms,
    bool? smsBookingSentEmail,
    String? smsBookingVia,
    bool clearSms = false,
    bool clearSmsDialog = false,
  }) {
    return JobVisit(
      id: id,
      startAt: startAt ?? this.startAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      note: note ?? this.note,
      outcome: outcome ?? this.outcome,
      smsBooking: clearSms ? const {} : (smsBooking ?? this.smsBooking),
      smsBookingDayKey:
          clearSms ? '' : (smsBookingDayKey ?? this.smsBookingDayKey),
      smsBookingSlotKey:
          clearSms ? '' : (smsBookingSlotKey ?? this.smsBookingSlotKey),
      smsBookingSentAt:
          clearSms ? null : (smsBookingSentAt ?? this.smsBookingSentAt),
      smsBookingPendingAt:
          clearSms ? null : (smsBookingPendingAt ?? this.smsBookingPendingAt),
      smsReminderSentAt:
          clearSms ? null : (smsReminderSentAt ?? this.smsReminderSentAt),
      smsReminders: clearSms ? const {} : (smsReminders ?? this.smsReminders),
      smsConfirmStatus:
          clearSms ? '' : (smsConfirmStatus ?? this.smsConfirmStatus),
      smsConfirmNotifiedStatus: clearSms
          ? ''
          : (smsConfirmNotifiedStatus ?? this.smsConfirmNotifiedStatus),
      ownerSoonAt: clearSms ? null : (ownerSoonAt ?? this.ownerSoonAt),
      smsDialog: clearSms || clearSmsDialog
          ? ''
          : (smsDialog ?? this.smsDialog),
      smsBookingPending: clearSms
          ? false
          : (smsBookingPending ?? this.smsBookingPending),
      smsBookingSentSms: clearSms
          ? false
          : (smsBookingSentSms ?? this.smsBookingSentSms),
      smsBookingSentEmail: clearSms
          ? false
          : (smsBookingSentEmail ?? this.smsBookingSentEmail),
      smsBookingVia: clearSms ? '' : (smsBookingVia ?? this.smsBookingVia),
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
  final String? clientEmail;
  final bool clientIsRegular;

  // Job Site (место работы, если отличается от адреса владельца)
  final bool hasJobSite;
  final String? jobSiteName;
  final String? jobSitePhone;
  final String? jobSiteAddress;
  final String? jobSiteEmail;
  final List<String> extraPhones;

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
  final String trackingPart;
  final String trackingStatus;
  final String amazonOrderId;
  final List<JobTrackingOrder> trackingOrders;
  /// Исходная заявка, если это повторный вызов по той же неисправности.
  final String? repeatOfJobId;
  /// Заявка, в которую сервер слил этот дубляж (сама заявка при этом закрыта).
  final String mergedIntoJobId;
  /// Дубляжи, которые сервер слил сюда.
  final List<String> mergedFromJobIds;
  /// Похоже на дубляж: тот же номер, меньше 48 часов, но соединять автоматом
  /// нельзя — решает мастер кнопкой в карточке.
  final String possibleDuplicateOfJobId;
  /// Мастер сказал «не дубляж» — больше не предлагаем.
  final bool duplicateDismissed;
  final DateTime? deletedAt;

  /// Паспорта техники клиента (коды с наклеек), к которым относится заявка.
  /// Отдельным полем, а не внутри `appliances`: редактор техники переписывает
  /// `appliances` целиком и потерял бы привязку.
  final List<String> applianceIds;

  /// Care Plan, по которому идёт заявка, и вид вызова: `maintenance`
  /// (плановое ТО) или `repair` (ремонт по плану). Пусто — обычный вызов.
  final String carePlanId;
  final String carePlanKind;

  /// День, к которому клиенту обещали запчасть. Не слот календаря: визит
  /// ставится отдельно, когда запчасть уже есть.
  final DateTime? promisedPartAt;
  final DateTime? reminderAt;

  /// Просрочена ли дата «Когда обещал»: если выбрана только дата (00:00) —
  /// со следующего дня; если выбраны дата и время — сразу после этого времени.
  static bool isPromisedOverdue(DateTime? promised, [DateTime? now]) {
    if (promised == null) return false;
    final current = now ?? DateTime.now();
    if (promised.hour == 0 && promised.minute == 0) {
      final startOfToday = DateTime(current.year, current.month, current.day);
      return promised.isBefore(startOfToday);
    }
    return promised.isBefore(current);
  }

  Job({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    required this.clientAddress,
    this.clientEmail,
    this.clientIsRegular = false,
    this.hasJobSite = false,
    this.jobSiteName,
    this.jobSitePhone,
    this.jobSiteAddress,
    this.jobSiteEmail,
    this.extraPhones = const [],
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
    this.trackingPart = '',
    this.trackingStatus = '',
    this.amazonOrderId = '',
    List<JobTrackingOrder>? trackingOrders,
    this.repeatOfJobId,
    this.mergedIntoJobId = '',
    this.mergedFromJobIds = const [],
    this.possibleDuplicateOfJobId = '',
    this.duplicateDismissed = false,
    this.deletedAt,
    this.applianceIds = const [],
    this.carePlanId = '',
    this.carePlanKind = '',
    this.promisedPartAt,
    this.reminderAt,
  }) : trackingOrders = trackingOrders != null
           ? trackingOrders.where((o) => o.isNotEmpty).toList()
           : [
               if (trackingNumber.trim().isNotEmpty ||
                   trackingCarrier.trim().isNotEmpty ||
                   trackingPart.trim().isNotEmpty ||
                   trackingStatus.trim().isNotEmpty ||
                   amazonOrderId.trim().isNotEmpty)
                 JobTrackingOrder(
                   part: trackingPart.trim(),
                   carrier: trackingCarrier.trim(),
                   trackingNumber: trackingNumber.trim(),
                   orderId: amazonOrderId.trim(),
                   status: trackingStatus.trim(),
                 ),
             ];

  /// Закрытый дубляж: его данные уже переехали в другую заявку.
  bool get isMergedDuplicate => mergedIntoJobId.trim().isNotEmpty;

  /// Ждёт решения мастера: соединить с [possibleDuplicateOfJobId] или нет.
  bool get hasDuplicateHint =>
      !duplicateDismissed &&
      !isMergedDuplicate &&
      possibleDuplicateOfJobId.trim().isNotEmpty;

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

  /// Адрес для навигации (Job Site или адрес клиента).
  ///
  /// Галочка «другое место работы» иногда стоит, а адрес туда не вписан —
  /// тогда едем к клиенту, иначе маршрут открывался бы в пустоту.
  String get workAddress {
    final site = (jobSiteAddress ?? '').trim();
    if (hasJobSite && site.isNotEmpty) return site;
    return clientAddress;
  }

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

  /// Контактное имя на месте. Телефон сюда не подставляется: пустое имя — это
  /// сам клиент, а не его номер.
  String get contactName {
    final site = SmsText.stripClientWord(jobSiteName);
    if (hasJobSite &&
        site.isNotEmpty &&
        !SmsText.isPlaceholderName(site)) {
      return site;
    }
    final owner = SmsText.stripClientWord(clientName);
    if (owner.isNotEmpty && !SmsText.isPlaceholderName(owner)) return owner;
    if (hasJobSite && site.isNotEmpty) return site;
    return owner;
  }

  /// Контактный телефон на месте
  String get contactPhone =>
      hasJobSite && (jobSitePhone ?? '').trim().isNotEmpty
          ? jobSitePhone!
          : clientPhone;

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

  /// Когда счёт или смета были выставлены. Приложение и `estimateConfirm`
  /// пишут сюда строку ISO, но ранние документы могли приехать Timestamp —
  /// на этой дате держится сортировка списка «Счета», молча ронять её нельзя.
  static DateTime? documentCreatedAt(Map doc) {
    final raw = doc['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

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

  /// Тип для картинки/иконки: если приборов несколько — общая картинка «Техника»
  String get appliancePictureType =>
      appliances.length > 1 ? 'Техника' : applianceType;

  /// Бренд техники для отображения
  String get applianceBrand => primaryAppliance?.brand ?? '';

  /// Иконка техники
  IconData get applianceIcon =>
      ApplianceCategories.getIcon(appliancePictureType);

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
    for (final order in trackingOrders) {
      add(order.part);
    }
    if (trackingPart.trim().isNotEmpty) {
      add(trackingPart);
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

  List<JobVisit> get activeVisits {
    if (isDeleted || JobStatuses.isClosed(status)) return const [];
    return coalescedVisits.where((visit) => visit.isActiveSlot).toList();
  }

  JobVisit? nextActiveVisit({DateTime? now}) {
    final instant = (now ?? DateTime.now()).toUtc();
    for (final visit in activeVisits) {
      if (visit.endAt.toUtc().isAfter(instant)) return visit;
    }
    return null;
  }

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

  /// Старые выезды показываем как «Перенесено», последний — текущий статус заявки.
  String displayStatusForVisit(JobVisit? visit) {
    if (JobStatuses.isCancelledStatus(status)) return status;
    final items = coalescedVisits;
    if (visit == null || items.length < 2) return status;
    final latest = latestVisit;
    if (latest == null) return status;
    if (visit.startAt.isBefore(latest.startAt)) return JobStatuses.rescheduled;
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
      final qty = _toDouble(item['qty'] ?? 1);
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

  /// Позиция счёта: запчасть или работа.
  ///
  /// `Part` / `Service` проставляет мастер в редакторе позиции — по этой
  /// метке отчёты делят выручку на работу и запчасти. У старых счетов метки
  /// нет, и тогда это догадка по складу и себестоимости; такие позиции
  /// показываются в «Разобрать позиции», чтобы их пометили руками.
  /// Возвращает `part`, `service` или пустую строку.
  static String itemKind(Map item) {
    final type = (item['type'] ?? '').toString().toLowerCase().trim();
    if (type.isEmpty) return '';
    if (type.contains('part') || type.contains('запчаст')) return 'part';
    if (type.contains('service') ||
        type.contains('labour') ||
        type.contains('labor') ||
        type.contains('работ') ||
        type.contains('услуг')) {
      return 'service';
    }
    return '';
  }

  /// Метку поставил человек (или склад), а не угадали мы.
  static bool isItemClassified(Map item) => itemKind(item).isNotEmpty;

  static bool isPartItem(Map item) {
    final kind = itemKind(item);
    if (kind.isNotEmpty) return kind == 'part';
    // Старая позиция без метки: со склада или с себестоимостью — запчасть.
    return (item['warehouseItemId'] ?? '').toString().isNotEmpty ||
        item['costPrice'] != null;
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

  /// Клиент реально внёс часть суммы по счёту — это депозит.
  /// Выставленная ссылка Stripe (`mode: deposit`) без денег сюда не попадает,
  /// частичный возврат по оплаченному счёту — тоже.
  static bool documentDepositTaken(Map doc) {
    if (!isInvoice(doc) || isDocumentTrashed(doc)) return false;
    if (_hasRefundPayment(doc)) return false;
    final stripe = doc['stripe'];
    final stripeStatus =
        stripe is Map ? (stripe['status'] ?? '').toString() : '';
    if (stripeStatus == 'refunded' || stripeStatus == 'partially_refunded') {
      return false;
    }
    final total = documentTotal(doc);
    if (total <= 0.009) return false;
    final paid = documentPaid(doc);
    return paid > 0.009 && total - paid > 0.009;
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

    final clientPhone = (map['clientPhone'] ?? '').toString();
    final rawSitePhone = map['jobSitePhone']?.toString();
    final rawSiteName = map['jobSiteName']?.toString();
    final extraPhonesList = <String>[];
    final rawExtraPhones = map['extraPhones'];
    if (rawExtraPhones is List) {
      final seen = <String>{};
      for (final base in [clientPhone, rawSitePhone ?? '']) {
        final d = base.replaceAll(RegExp(r'\D'), '');
        if (d.isNotEmpty) {
          seen.add(d.length > 10 ? d.substring(d.length - 10) : d);
        }
      }
      for (final item in rawExtraPhones) {
        final s = (item ?? '').toString().trim();
        if (s.isEmpty) continue;
        final d = s.replaceAll(RegExp(r'\D'), '');
        final key = d.length > 10 ? d.substring(d.length - 10) : d;
        if (key.isEmpty || !seen.add(key)) continue;
        extraPhonesList.add(s);
      }
    }

    return Job(
      id: docId,
      clientId: map['clientId'] ?? '',
      clientName: SmsText.stripClientWord(
        (map['clientName'] ?? map['name'] ?? '').toString(),
      ),
      clientPhone: clientPhone,
      clientAddress: map['clientAddress'] ?? '',
      clientEmail: (map['clientEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (map['clientEmail'] ?? '').toString().trim(),
      clientIsRegular:
          map['clientIsRegular'] == true || map['isRegular'] == true,
      hasJobSite: map['hasJobSite'] ?? false,
      jobSiteName: rawSiteName == null
          ? null
          : SmsText.stripClientWord(rawSiteName),
      jobSitePhone: rawSitePhone,
      jobSiteAddress: map['jobSiteAddress'],
      jobSiteEmail: (map['jobSiteEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (map['jobSiteEmail'] ?? '').toString().trim(),
      extraPhones: extraPhonesList,
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
      trackingPart: (map['trackingPart'] ?? '').toString(),
      trackingStatus: (map['trackingStatus'] ?? '').toString(),
      amazonOrderId: (map['amazonOrderId'] ?? '').toString(),
      trackingOrders: JobTrackingOrder.parseList(map),
      repeatOfJobId: (map['repeatOfJobId'] ?? '').toString().trim().isEmpty
          ? null
          : (map['repeatOfJobId'] ?? '').toString().trim(),
      mergedIntoJobId: (map['mergedIntoJobId'] ?? '').toString().trim(),
      mergedFromJobIds: (map['mergedFromJobIds'] is List)
          ? (map['mergedFromJobIds'] as List)
                .map((id) => id.toString().trim())
                .where((id) => id.isNotEmpty)
                .toList()
          : const [],
      possibleDuplicateOfJobId: (map['possibleDuplicateOfJobId'] ?? '')
          .toString()
          .trim(),
      duplicateDismissed: map['duplicateDismissed'] == true,
      deletedAt: parseDate(map['deletedAt']),
      applianceIds: (map['applianceIds'] is List)
          ? (map['applianceIds'] as List)
                .map((id) => id.toString().trim())
                .where((id) => id.isNotEmpty)
                .toList()
          : const [],
      carePlanId: (map['carePlanId'] ?? '').toString().trim(),
      carePlanKind: (map['carePlanKind'] ?? '').toString().trim(),
      promisedPartAt:
          parseDate(map['promisedPartAt']) ?? parseDate(map['agreedReturnAt']),
      reminderAt: parseDate(map['reminderAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'clientId': clientId,
      'clientName': clientName,
      'clientPhone': clientPhone,
      'clientAddress': clientAddress,
      if (clientEmail != null) 'clientEmail': clientEmail,
      'clientIsRegular': clientIsRegular,
      'hasJobSite': hasJobSite,
      'jobSiteName': jobSiteName,
      'jobSitePhone': jobSitePhone,
      'jobSiteAddress': jobSiteAddress,
      'jobSiteEmail': jobSiteEmail,
      if (extraPhones.isNotEmpty) 'extraPhones': extraPhones,
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
      'trackingPart': trackingPart,
      'trackingStatus': trackingStatus,
      'amazonOrderId': amazonOrderId,
      'trackingOrders': [
        for (final order in trackingOrders)
          if (order.isNotEmpty) order.toMap(),
      ],
      'repeatOfJobId': repeatOfJobId,
      'mergedIntoJobId': mergedIntoJobId,
      'mergedFromJobIds': mergedFromJobIds,
      'possibleDuplicateOfJobId': possibleDuplicateOfJobId,
      'duplicateDismissed': duplicateDismissed,
      if (applianceIds.isNotEmpty) 'applianceIds': applianceIds,
      if (carePlanId.isNotEmpty) 'carePlanId': carePlanId,
      if (carePlanKind.isNotEmpty) 'carePlanKind': carePlanKind,
      'promisedPartAt': promisedPartAt,
      if (reminderAt != null) 'reminderAt': reminderAt!.toIso8601String(),
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
    String? clientEmail,
    bool? clientIsRegular,
    bool? hasJobSite,
    String? jobSiteName,
    String? jobSitePhone,
    String? jobSiteAddress,
    String? jobSiteEmail,
    List<String>? extraPhones,
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
    String? trackingPart,
    String? trackingStatus,
    String? amazonOrderId,
    List<JobTrackingOrder>? trackingOrders,
    String? repeatOfJobId,
    String? mergedIntoJobId,
    List<String>? mergedFromJobIds,
    String? possibleDuplicateOfJobId,
    bool? duplicateDismissed,
    DateTime? deletedAt,
    List<String>? applianceIds,
    String? carePlanId,
    String? carePlanKind,
    DateTime? promisedPartAt,
    bool clearPromisedPartAt = false,
    DateTime? reminderAt,
    bool clearReminderAt = false,
  }) {
    return Job(
      id: id ?? this.id,
      clientId: clientId ?? this.clientId,
      clientName: clientName ?? this.clientName,
      clientPhone: clientPhone ?? this.clientPhone,
      clientAddress: clientAddress ?? this.clientAddress,
      clientEmail: clientEmail ?? this.clientEmail,
      clientIsRegular: clientIsRegular ?? this.clientIsRegular,
      hasJobSite: hasJobSite ?? this.hasJobSite,
      jobSiteName: jobSiteName ?? this.jobSiteName,
      jobSitePhone: jobSitePhone ?? this.jobSitePhone,
      jobSiteAddress: jobSiteAddress ?? this.jobSiteAddress,
      jobSiteEmail: jobSiteEmail ?? this.jobSiteEmail,
      extraPhones: extraPhones ?? this.extraPhones,
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
      trackingPart: trackingPart ?? this.trackingPart,
      trackingStatus: trackingStatus ?? this.trackingStatus,
      amazonOrderId: amazonOrderId ?? this.amazonOrderId,
      trackingOrders: trackingOrders ?? this.trackingOrders,
      repeatOfJobId: repeatOfJobId ?? this.repeatOfJobId,
      mergedIntoJobId: mergedIntoJobId ?? this.mergedIntoJobId,
      mergedFromJobIds: mergedFromJobIds ?? this.mergedFromJobIds,
      possibleDuplicateOfJobId:
          possibleDuplicateOfJobId ?? this.possibleDuplicateOfJobId,
      duplicateDismissed: duplicateDismissed ?? this.duplicateDismissed,
      deletedAt: deletedAt ?? this.deletedAt,
      applianceIds: applianceIds ?? this.applianceIds,
      carePlanId: carePlanId ?? this.carePlanId,
      carePlanKind: carePlanKind ?? this.carePlanKind,
      promisedPartAt:
          clearPromisedPartAt ? null : (promisedPartAt ?? this.promisedPartAt),
      reminderAt:
          clearReminderAt ? null : (reminderAt ?? this.reminderAt),
    );
  }
}
