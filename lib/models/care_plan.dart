import 'package:cloud_firestore/cloud_firestore.dart';

/// Условия Care Plan (`settings/config`). Решение FIX 28.10.2026: $10 в
/// месяц, диагностика и ремонт бесплатно, клиент платит только за запчасти,
/// ТО раз в год. Скидка относится к работе — при 100% работа выходит в ноль.
/// Срок «отказа без причины» 10 дней — закон Онтарио для
/// договоров, подписанных у клиента дома; минимум 12 месяцев и 30 дней
/// ожидания — защита от «подписался, получил ТО и отменил».
class CarePlanTerms {
  final double monthlyPrice;
  final double discountPercent;
  final int minTermMonths;
  final int waitingDays;
  final int coolingOffDays;
  final int maintenanceMonths;
  final int firstMaintenanceDays;
  final int remindDays;
  final String passportBaseUrl;

  const CarePlanTerms({
    this.monthlyPrice = 10,
    this.discountPercent = 100,
    this.minTermMonths = 12,
    this.waitingDays = 30,
    this.coolingOffDays = 10,
    this.maintenanceMonths = 12,
    this.firstMaintenanceDays = 30,
    this.remindDays = 14,
    this.passportBaseUrl = defaultPassportBaseUrl,
  });

  /// Домен Firebase Hosting магазина: `/a/<код>` отдаёт функция `p`.
  static const String defaultPassportBaseUrl = 'https://doc.fix-appliance.ca/a/';

  static double _double(Object? raw, double fallback, double min, double max) {
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString().trim() ?? '') ?? fallback;
    if (value.isNaN) return fallback;
    return value.clamp(min, max).toDouble();
  }

  static int _int(Object? raw, int fallback, int min, int max) {
    final value = raw is num
        ? raw.round()
        : int.tryParse(raw?.toString().trim() ?? '') ?? fallback;
    return value.clamp(min, max);
  }

  factory CarePlanTerms.fromConfig(Map<String, dynamic> config) {
    const d = CarePlanTerms();
    final base = (config['passportBaseUrl'] ?? '').toString().trim();
    return CarePlanTerms(
      monthlyPrice: _double(config['carePlanPrice'], d.monthlyPrice, 0, 10000),
      discountPercent:
          _double(config['carePlanDiscountPercent'], d.discountPercent, 0, 100),
      minTermMonths:
          _int(config['carePlanMinTermMonths'], d.minTermMonths, 0, 60),
      waitingDays: _int(config['carePlanWaitingDays'], d.waitingDays, 0, 365),
      coolingOffDays:
          _int(config['carePlanCoolingOffDays'], d.coolingOffDays, 0, 60),
      maintenanceMonths:
          _int(config['carePlanMaintenanceMonths'], d.maintenanceMonths, 1, 36),
      firstMaintenanceDays: _int(
        config['carePlanFirstMaintenanceDays'],
        d.firstMaintenanceDays,
        0,
        365,
      ),
      remindDays: _int(config['carePlanRemindDays'], d.remindDays, 1, 90),
      passportBaseUrl: base.startsWith('http') ? base : d.passportBaseUrl,
    );
  }

  Map<String, dynamic> toConfig() => {
    'carePlanPrice': monthlyPrice,
    'carePlanDiscountPercent': discountPercent,
    'carePlanMinTermMonths': minTermMonths,
    'carePlanWaitingDays': waitingDays,
    'carePlanCoolingOffDays': coolingOffDays,
    'carePlanMaintenanceMonths': maintenanceMonths,
    'carePlanFirstMaintenanceDays': firstMaintenanceDays,
    'carePlanRemindDays': remindDays,
    'passportBaseUrl': passportBaseUrl,
  };
}

/// Почему план требует внимания мастера (значок в шапке календаря и
/// ежедневный push). Порядок — от важного к менее важному.
enum CarePlanAttention { none, paymentFailed, maintenanceOverdue, maintenanceSoon, awaitingPayment }

/// Подписка клиента на гарантийное обслуживание — один дом (адрес).
///
/// Лежит в `companies/{id}/care_plans/{planId}`, отдельно от карточки
/// клиента: правки и слияние карточек её не затирают, а сервер (Stripe,
/// напоминания, секретарь) читает одну маленькую коллекцию. `phones` —
/// последние 10 цифр всех номеров клиента, по ним сервер узнаёт звонящего.
class CarePlan {
  static const String pending = 'pending';
  static const String active = 'active';
  static const String pastDue = 'past_due';
  static const String paused = 'paused';
  static const String cancelled = 'cancelled';

  static const List<String> statuses = [pending, active, pastDue, paused, cancelled];

  /// Заявка по плану: плановое ТО или ремонт по поломке.
  static const String kindMaintenance = 'maintenance';
  static const String kindRepair = 'repair';

  final String id;
  final String clientId;
  final String clientName;
  final List<String> phones;
  final String address;
  final String status;
  final String contractNumber;
  final DateTime signedAt;
  final double monthlyPrice;
  final double discountPercent;
  final int minTermMonths;
  final int waitingDays;
  final int coolingOffDays;
  final int maintenanceMonths;
  final int firstMaintenanceDays;
  final DateTime? lastMaintenanceAt;
  final DateTime? nextMaintenanceDue;
  final String notes;
  final DateTime? cancelledAt;
  final String cancelReason;
  final Map<String, dynamic> stripe;
  final DateTime? createdAt;

  const CarePlan({
    required this.id,
    required this.clientId,
    this.clientName = '',
    this.phones = const [],
    this.address = '',
    this.status = pending,
    this.contractNumber = '',
    required this.signedAt,
    this.monthlyPrice = 10,
    this.discountPercent = 100,
    this.minTermMonths = 12,
    this.waitingDays = 30,
    this.coolingOffDays = 10,
    this.maintenanceMonths = 12,
    this.firstMaintenanceDays = 30,
    this.lastMaintenanceAt,
    this.nextMaintenanceDue,
    this.notes = '',
    this.cancelledAt,
    this.cancelReason = '',
    this.stripe = const {},
    this.createdAt,
  });

  /// Клиент на плане: льготы действуют. Просрочка платежа ещё не отмена —
  /// мастер видит её отдельно и решает сам.
  bool get isMember => status == active || status == pastDue;
  bool get isCancelled => status == cancelled;

  DateTime get minTermUntil => addMonths(signedAt, minTermMonths);
  DateTime get coolingOffUntil => addDays(signedAt, coolingOffDays);
  DateTime get waitingUntil => addDays(signedAt, waitingDays);

  bool inCoolingOff(DateTime now) => _dayOf(now).isBefore(coolingOffUntil);
  bool inWaiting(DateTime now) => _dayOf(now).isBefore(waitingUntil);

  /// Когда следующее ТО: сохранённая дата, иначе по правилам плана.
  DateTime get maintenanceDue =>
      nextMaintenanceDue ??
      computeNextMaintenanceDue(
        signedAt: signedAt,
        lastMaintenanceAt: lastMaintenanceAt,
        maintenanceMonths: maintenanceMonths,
        firstMaintenanceDays: firstMaintenanceDays,
      );

  /// Дней до ТО по календарю: 0 — сегодня, меньше нуля — просрочено.
  int daysToMaintenance(DateTime now) => daysBetween(now, maintenanceDue);

  /// Подпись срока ТО на паспорте техники: «На плане, ТО 20.11.2027»,
  /// а когда срок близко — «ТО через 5 дн. · 20.11.2027». Пусто, если план
  /// не активен: техника в отменённой подписке ничем не выделяется.
  String maintenanceDueLine(DateTime now, {int remindDays = 14}) {
    if (!isMember) return '';
    final due = '${maintenanceDue.day.toString().padLeft(2, '0')}.'
        '${maintenanceDue.month.toString().padLeft(2, '0')}.'
        '${maintenanceDue.year}';
    final days = daysToMaintenance(now);
    if (days < 0) return 'Пора ТО — срок $due';
    if (days == 0) return 'Пора ТО — сегодня · $due';
    if (days <= remindDays) return 'ТО через $days дн. · $due';
    return 'На плане, ТО $due';
  }

  CarePlanAttention attention(DateTime now, {int remindDays = 14}) {
    if (status == pastDue) return CarePlanAttention.paymentFailed;
    if (isMember) {
      final days = daysToMaintenance(now);
      if (days <= 0) return CarePlanAttention.maintenanceOverdue;
      if (days <= remindDays) return CarePlanAttention.maintenanceSoon;
      return CarePlanAttention.none;
    }
    if (status == pending && daysBetween(signedAt, now) >= 2) {
      return CarePlanAttention.awaitingPayment;
    }
    return CarePlanAttention.none;
  }

  /// Скидка, которую надо дать по ремонту: только члену плана и только
  /// после периода ожидания.
  bool repairBenefitsActive(DateTime now) => isMember && !inWaiting(now);

  double monthlyTotal(double taxRate) =>
      ((monthlyPrice * (1 + taxRate)) * 100).round() / 100;

  String get stripeSubscriptionId =>
      (stripe['subscriptionId'] ?? '').toString().trim();
  String get stripeCheckoutUrl => (stripe['checkoutUrl'] ?? '').toString().trim();
  DateTime? get lastPaymentAt => parseDate(stripe['lastPaymentAt']);
  double get lastPaymentAmount {
    final raw = stripe['lastPaymentAmount'];
    return raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}') ?? 0;
  }

  static DateTime _dayOf(DateTime value) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// +N календарных дней. Не `add(Duration(days: N))`: через перевод часов
  /// (1 ноября в Торонто) сутки длятся 25 часов, и дата съезжала на
  /// 23:00 предыдущего дня.
  static DateTime addDays(DateTime value, int days) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day + days);
  }

  /// Разница в календарных днях (по UTC-полуночам — без перевода часов).
  static int daysBetween(DateTime from, DateTime to) {
    final a = from.toLocal();
    final b = to.toLocal();
    return DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;
  }

  static DateTime? parseDate(Object? value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is num) {
      final ms = value > 1e12 ? value.toInt() : (value * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return null;
  }

  /// +N месяцев с прижатием к концу месяца: 31 января + 1 = 28/29 февраля.
  static DateTime addMonths(DateTime value, int months) {
    final local = value.toLocal();
    final total = local.month - 1 + months;
    final year = local.year + (total >= 0 ? total ~/ 12 : (total - 11) ~/ 12);
    final month = total % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = local.day > lastDay ? lastDay : local.day;
    return DateTime(year, month, day);
  }

  /// Первое ТО — через [firstMaintenanceDays] после подписания (не раньше,
  /// чем пройдёт срок отказа), дальше — раз в [maintenanceMonths].
  static DateTime computeNextMaintenanceDue({
    required DateTime signedAt,
    DateTime? lastMaintenanceAt,
    int maintenanceMonths = 12,
    int firstMaintenanceDays = 30,
  }) {
    if (lastMaintenanceAt != null) {
      return addMonths(lastMaintenanceAt, maintenanceMonths);
    }
    return addDays(signedAt, firstMaintenanceDays);
  }

  /// Последние 10 цифр, как `SmsService.normalizePhone`.
  static String phoneKey(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : '';
  }

  factory CarePlan.fromMap(Map<String, dynamic> map, String id) {
    double num0(Object? raw, double fallback) => raw is num
        ? raw.toDouble()
        : double.tryParse('${raw ?? ''}') ?? fallback;
    int int0(Object? raw, int fallback) =>
        raw is num ? raw.round() : int.tryParse('${raw ?? ''}') ?? fallback;
    final phones = map['phones'] is List
        ? [
            for (final p in map['phones'] as List)
              if (p.toString().trim().isNotEmpty) p.toString().trim(),
          ]
        : const <String>[];
    final rawStatus = (map['status'] ?? pending).toString().trim();
    return CarePlan(
      id: id,
      clientId: (map['clientId'] ?? '').toString(),
      clientName: (map['clientName'] ?? '').toString(),
      phones: phones,
      address: (map['address'] ?? '').toString(),
      status: statuses.contains(rawStatus) ? rawStatus : pending,
      contractNumber: (map['contractNumber'] ?? '').toString(),
      signedAt: parseDate(map['signedAt']) ??
          parseDate(map['createdAt']) ??
          DateTime.now(),
      monthlyPrice: num0(map['monthlyPrice'], 10),
      discountPercent: num0(map['discountPercent'], 100),
      minTermMonths: int0(map['minTermMonths'], 12),
      waitingDays: int0(map['waitingDays'], 30),
      coolingOffDays: int0(map['coolingOffDays'], 10),
      maintenanceMonths: int0(map['maintenanceMonths'], 12),
      firstMaintenanceDays: int0(map['firstMaintenanceDays'], 30),
      lastMaintenanceAt: parseDate(map['lastMaintenanceAt']),
      nextMaintenanceDue: parseDate(map['nextMaintenanceDue']),
      notes: (map['notes'] ?? '').toString(),
      cancelledAt: parseDate(map['cancelledAt']),
      cancelReason: (map['cancelReason'] ?? '').toString(),
      stripe: map['stripe'] is Map
          ? Map<String, dynamic>.from(map['stripe'] as Map)
          : const {},
      createdAt: parseDate(map['createdAt']),
    );
  }

  /// Поля, которые пишет приложение. `stripe` и отметки напоминаний ведёт
  /// сервер — их здесь нет, чтобы правка плана их не затирала.
  Map<String, dynamic> toMap() => {
    'clientId': clientId,
    'clientName': clientName,
    'phones': phones,
    'address': address,
    'status': status,
    'contractNumber': contractNumber,
    'signedAt': Timestamp.fromDate(signedAt),
    'monthlyPrice': monthlyPrice,
    'discountPercent': discountPercent,
    'minTermMonths': minTermMonths,
    'waitingDays': waitingDays,
    'coolingOffDays': coolingOffDays,
    'maintenanceMonths': maintenanceMonths,
    'firstMaintenanceDays': firstMaintenanceDays,
    'lastMaintenanceAt': lastMaintenanceAt == null
        ? null
        : Timestamp.fromDate(lastMaintenanceAt!),
    'nextMaintenanceDue': Timestamp.fromDate(maintenanceDue),
    'notes': notes,
  };
}
