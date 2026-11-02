import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/care_plan.dart';
import '../models/home_appliance.dart';
import '../models/job.dart';
import 'auth_service.dart';
import 'firestore_service.dart';
import 'job_service.dart';
import 'network_status_service.dart';
import 'settings_service.dart';

/// Care Plan (подписка на гарантийное обслуживание) и цифровые паспорта
/// техники.
///
/// Обе коллекции маленькие, поэтому приложение держит их целиком в памяти —
/// одна подписка на всё приложение ([start]). Так значок «Care Plan» на
/// экране входящего звонка, в истории звонков и в карточке заявки
/// появляется сразу, без запроса на каждый номер. [revision] растёт на
/// каждое изменение — по нему перестраиваются значки.
class CarePlanService {
  CarePlanService._();

  static CollectionReference get plansRef =>
      FirestoreService.companyRef.collection('care_plans');

  static CollectionReference get appliancesRef =>
      FirestoreService.companyRef.collection('appliances');

  /// Ключ в SharedPreferences: номер (10 цифр) → подпись для шторки
  /// входящего звонка. Читает `IncomingCallNotifier` в нативе, пока
  /// Flutter ещё не поднялся.
  static const String callerLabelsKey = 'care_plan_callers';
  static const String callerLabel = 'CARE PLAN';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static List<CarePlan> _plans = const [];
  static List<HomeAppliance> _appliances = const [];
  static CarePlanTerms _terms = const CarePlanTerms();
  static bool _loaded = false;

  static StreamSubscription<QuerySnapshot>? _plansSub;
  static StreamSubscription<QuerySnapshot>? _appliancesSub;
  static bool _started = false;
  static String _syncedLabels = '';

  static List<CarePlan> get plans => _plans;
  static List<HomeAppliance> get appliances => _appliances;
  static CarePlanTerms get terms => _terms;

  /// Первый снимок пришёл — до этого «нет плана» значит «ещё не знаем».
  static bool get loaded => _loaded;

  // ------------------------------------------------------------- подписка

  static void start() {
    if (_started) return;
    _started = true;
    AuthService.user.addListener(_bindUser);
    _bindUser();
  }

  static void _bindUser() {
    if (AuthService.user.value == null) {
      _cancel();
      return;
    }
    if (_plansSub != null) return;
    _plansSub = plansRef.snapshots().listen(
      _onPlans,
      onError: (Object error) => debugPrint('CarePlanService plans: $error'),
    );
    _appliancesSub = appliancesRef.snapshots().listen(
      _onAppliances,
      onError: (Object error) =>
          debugPrint('CarePlanService appliances: $error'),
    );
    unawaited(loadTerms());
  }

  static void _cancel() {
    _plansSub?.cancel();
    _appliancesSub?.cancel();
    _plansSub = null;
    _appliancesSub = null;
  }

  static void _onPlans(QuerySnapshot snapshot) {
    final list = <CarePlan>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data is! Map) continue;
      try {
        list.add(CarePlan.fromMap(Map<String, dynamic>.from(data), doc.id));
      } catch (_) {}
    }
    list.sort(
      (a, b) => a.clientName.toLowerCase().compareTo(b.clientName.toLowerCase()),
    );
    _plans = list;
    _loaded = true;
    _bump();
    unawaited(_syncCallerLabels());
  }

  static void _onAppliances(QuerySnapshot snapshot) {
    final list = <HomeAppliance>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data is! Map) continue;
      try {
        list.add(HomeAppliance.fromMap(Map<String, dynamic>.from(data), doc.id));
      } catch (_) {}
    }
    list.sort((a, b) {
      final at = a.createdAt ?? DateTime(2000);
      final bt = b.createdAt ?? DateTime(2000);
      return at.compareTo(bt);
    });
    _appliances = list;
    _bump();
  }

  /// Тестам: подставить планы и технику без Firestore.
  @visibleForTesting
  static void debugSetData({
    List<CarePlan> plans = const [],
    List<HomeAppliance> appliances = const [],
    CarePlanTerms terms = const CarePlanTerms(),
  }) {
    _plans = plans;
    _appliances = appliances;
    _terms = terms;
    _loaded = true;
    _bump();
  }

  static void _bump() {
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.persistentCallbacks ||
          phase == SchedulerPhase.midFrameMicrotasks) {
        Future.microtask(() => revision.value++);
        return;
      }
    } catch (_) {}
    revision.value++;
  }

  // -------------------------------------------------------------- поиск

  /// План, по которому клиент сейчас пользуется льготами (активен или
  /// с просроченным платежом). Сначала по карточке клиента, потом по номеру.
  static CarePlan? memberPlanFor({String? clientId, String? phone}) {
    final id = (clientId ?? '').trim();
    final key = CarePlan.phoneKey(phone ?? '');
    if (id.isEmpty && key.isEmpty) return null;
    CarePlan? byPhone;
    for (final plan in _plans) {
      if (!plan.isMember) continue;
      if (id.isNotEmpty && plan.clientId == id) return plan;
      if (byPhone == null && key.isNotEmpty && plan.phones.contains(key)) {
        byPhone = plan;
      }
    }
    return byPhone;
  }

  static bool isMember({String? clientId, String? phone}) =>
      memberPlanFor(clientId: clientId, phone: phone) != null;

  /// Все планы клиента, свежие сверху (отменённые — в конце).
  static List<CarePlan> plansForClient(String clientId) {
    final id = clientId.trim();
    if (id.isEmpty) return const [];
    final list = [
      for (final plan in _plans)
        if (plan.clientId == id) plan,
    ];
    list.sort((a, b) {
      if (a.isCancelled != b.isCancelled) return a.isCancelled ? 1 : -1;
      return b.signedAt.compareTo(a.signedAt);
    });
    return list;
  }

  static CarePlan? planById(String id) {
    for (final plan in _plans) {
      if (plan.id == id) return plan;
    }
    return null;
  }

  static List<HomeAppliance> appliancesForClient(
    String clientId, {
    bool includeRetired = false,
  }) {
    final id = clientId.trim();
    if (id.isEmpty) return const [];
    return [
      for (final a in _appliances)
        if (a.clientId == id && (includeRetired || a.isActive)) a,
    ];
  }

  static List<HomeAppliance> appliancesForPlan(String planId) => [
    for (final a in _appliances)
      if (a.planId == planId && a.isActive) a,
  ];

  static HomeAppliance? applianceById(String code) {
    for (final a in _appliances) {
      if (a.id == code) return a;
    }
    return null;
  }

  /// Планы, которые ждут действия мастера: платёж не прошёл, пора или скоро
  /// ТО, договор подписан, а оплаты нет. Важное — сверху.
  static List<(CarePlan, CarePlanAttention)> attentionPlans([DateTime? now]) {
    final at = now ?? DateTime.now();
    final list = <(CarePlan, CarePlanAttention)>[];
    for (final plan in _plans) {
      final reason = plan.attention(at, remindDays: _terms.remindDays);
      if (reason != CarePlanAttention.none) list.add((plan, reason));
    }
    list.sort((a, b) {
      final byReason = a.$2.index.compareTo(b.$2.index);
      if (byReason != 0) return byReason;
      return a.$1.maintenanceDue.compareTo(b.$1.maintenanceDue);
    });
    return list;
  }

  static String passportUrl(String code) =>
      PassportCode.url(_terms.passportBaseUrl, code);

  /// Последние 10 цифр всех номеров карточки клиента — по ним сервер и
  /// приложение узнают звонящего члена плана.
  static List<String> phonesOfClient(Map<String, dynamic> client) {
    final keys = <String>[];
    void add(Object? raw) {
      final key = CarePlan.phoneKey((raw ?? '').toString());
      if (key.isNotEmpty && !keys.contains(key)) keys.add(key);
    }

    add(client['phone']);
    final locations = client['locations'];
    if (locations is List) {
      for (final loc in locations) {
        if (loc is! Map) continue;
        final contacts = loc['contacts'];
        if (contacts is! List) continue;
        for (final contact in contacts) {
          if (contact is Map) add(contact['phone']);
        }
      }
    }
    return keys;
  }

  // ------------------------------------------------------------ условия

  static Future<CarePlanTerms> loadTerms() async {
    final config = await SettingsService.loadConfig();
    _terms = CarePlanTerms.fromConfig(config);
    _bump();
    return _terms;
  }

  static Future<void> saveTerms(CarePlanTerms next) async {
    _terms = next;
    _bump();
    await SettingsService.updateConfigMap(next.toConfig());
  }

  // --------------------------------------------------------------- планы

  /// Новый план из бумажного договора. Цена и сроки фиксируются в плане
  /// на день подписания — смена условий в настройках старых договоров не
  /// трогает.
  static Future<String> createPlan({
    required String clientId,
    required String clientName,
    required List<String> phones,
    required String address,
    required String contractNumber,
    required DateTime signedAt,
    DateTime? nextMaintenanceDue,
    String notes = '',
    CarePlanTerms? terms,
  }) async {
    final t = terms ?? _terms;
    final ref = plansRef.doc();
    final plan = CarePlan(
      id: ref.id,
      clientId: clientId,
      clientName: clientName,
      phones: phones,
      address: address,
      status: CarePlan.pending,
      contractNumber: contractNumber,
      signedAt: signedAt,
      monthlyPrice: t.monthlyPrice,
      discountPercent: t.discountPercent,
      minTermMonths: t.minTermMonths,
      waitingDays: t.waitingDays,
      coolingOffDays: t.coolingOffDays,
      maintenanceMonths: t.maintenanceMonths,
      firstMaintenanceDays: t.firstMaintenanceDays,
      nextMaintenanceDue: nextMaintenanceDue,
      notes: notes,
    );
    await settleWrite(
      ref.set({
        ...plan.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
    return ref.id;
  }

  static Future<void> updatePlan(CarePlan plan) async {
    await settleWrite(
      plansRef.doc(plan.id).set({
        ...plan.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  static Future<void> setStatus(
    String planId,
    String status, {
    String reason = '',
  }) async {
    await settleWrite(
      plansRef.doc(planId).set({
        'status': status,
        if (status == CarePlan.cancelled) ...{
          'cancelledAt': FieldValue.serverTimestamp(),
          'cancelReason': reason,
        } else ...{
          'cancelledAt': FieldValue.delete(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  /// Номера клиента поменялись — план должен узнавать звонящего по новым.
  static Future<void> syncPhones(CarePlan plan, List<String> phones) async {
    if (phones.isEmpty || listEquals(phones, plan.phones)) return;
    await settleWrite(
      plansRef.doc(plan.id).set({
        'phones': phones,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  /// Удалить ошибочно заведённый план. Паспорта техники остаются у
  /// клиента — снимается только привязка к плану.
  static Future<void> deletePlan(String planId) async {
    final batch = FirebaseFirestore.instance.batch();
    for (final a in appliancesForPlan(planId)) {
      batch.update(appliancesRef.doc(a.id), {
        'planId': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.delete(plansRef.doc(planId));
    await settleWrite(batch.commit());
  }

  /// ТО сделано: дата следующего — через [CarePlan.maintenanceMonths], а в
  /// историю каждого паспорта ложится запись с тем, что сделано.
  static Future<void> markMaintenanceDone({
    required CarePlan plan,
    required List<HomeAppliance> serviced,
    Map<String, List<String>> checklist = const {},
    String jobId = '',
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    final next = CarePlan.addMonths(when, plan.maintenanceMonths);
    final batch = FirebaseFirestore.instance.batch();
    batch.set(plansRef.doc(plan.id), {
      'lastMaintenanceAt': Timestamp.fromDate(when),
      'nextMaintenanceDue': Timestamp.fromDate(next),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    for (final appliance in serviced) {
      final entry = ServiceLogEntry(
        date: when,
        kind: ServiceLogEntry.kindMaintenance,
        items: checklist[appliance.id] ??
            MaintenanceChecklist.forType(appliance.type),
        jobId: jobId,
      );
      batch.set(appliancesRef.doc(appliance.id), {
        'serviceLog': FieldValue.arrayUnion([entry.toMap()]),
        'lastServiceAt': Timestamp.fromDate(when),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    await settleWrite(batch.commit());
  }

  /// Заявка на ремонт по плану одной единицы техники — без даты визита.
  /// Мастер открыл паспорт холодильника и нажал «Заявка на ремонт»: заявка
  /// сразу на этот паспорт, скидку плана посчитает карточка заявки.
  static Future<(String, Job)> createRepairJob({
    required CarePlan plan,
    required HomeAppliance appliance,
    String clientPhone = '',
    String clientAddress = '',
    String? clientEmail,
  }) => _createPlanJob(
    plan: plan,
    appliances: [appliance],
    kind: CarePlan.kindRepair,
    issue: 'Ремонт по Care Plan',
    description: 'Ремонт по Care Plan: '
        '${appliance.displayName.isEmpty ? 'техника' : appliance.displayName}',
    clientPhone: clientPhone,
    clientAddress: clientAddress,
    clientEmail: clientEmail,
  );

  /// Заявка на плановое ТО — без даты визита, с техникой из паспортов:
  /// она встаёт в «Без даты визита», дату мастер ставит сам.
  static Future<(String, Job)> createMaintenanceJob({
    required CarePlan plan,
    required List<HomeAppliance> appliances,
    String clientPhone = '',
    String clientAddress = '',
    String? clientEmail,
  }) async {
    return _createPlanJob(
      plan: plan,
      appliances: appliances,
      kind: CarePlan.kindMaintenance,
      issue: 'Плановое ТО (Care Plan)',
      description:
          'Плановое ТО по Care Plan: ${appliances.isEmpty ? 1 : appliances.length} ед. техники',
      clientPhone: clientPhone,
      clientAddress: clientAddress,
      clientEmail: clientEmail,
    );
  }

  static Future<(String, Job)> _createPlanJob({
    required CarePlan plan,
    required List<HomeAppliance> appliances,
    required String kind,
    required String issue,
    required String description,
    String clientPhone = '',
    String clientAddress = '',
    String? clientEmail,
  }) async {
    final items = appliances.isEmpty
        ? [JobAppliance(type: 'Техника', issue: issue)]
        : [
            for (final a in appliances)
              JobAppliance(
                type: a.type.isEmpty ? 'Техника' : a.type,
                brand: a.brand,
                model: a.model,
                serialNumber: a.serialNumber,
                issue: issue,
              ),
          ];
    final job = Job(
      id: '',
      clientId: plan.clientId,
      clientName: plan.clientName,
      clientPhone: clientPhone.isNotEmpty
          ? clientPhone
          : (plan.phones.isNotEmpty ? plan.phones.first : ''),
      clientAddress: clientAddress.isNotEmpty ? clientAddress : plan.address,
      clientEmail: clientEmail,
      appliances: items,
      description: description,
      status: JobStatuses.call,
      createdAt: DateTime.now(),
      applianceIds: [for (final a in appliances) a.id],
      carePlanId: plan.id,
      carePlanKind: kind,
    );
    final id = await JobService.create(job);
    return (id, job.copyWith(id: id));
  }

  // ------------------------------------------------------------- техника

  /// Свободный код паспорта. Совпадение почти невозможно, но проверяем.
  static Future<String> newPassportCode() async {
    for (var i = 0; i < 4; i++) {
      final code = PassportCode.generate();
      if (applianceById(code) != null) continue;
      try {
        final snap = await appliancesRef
            .doc(code)
            .get()
            .timeout(const Duration(seconds: 3));
        if (snap.exists) continue;
      } catch (_) {
        // Нет сети — 50 бит случайности хватает и без проверки.
      }
      return code;
    }
    return PassportCode.generate();
  }

  static Future<void> saveAppliance(
    HomeAppliance appliance, {
    bool isNew = false,
  }) async {
    await settleWrite(
      appliancesRef.doc(appliance.id).set({
        ...appliance.toMap(),
        if (isNew) 'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  static Future<void> markStickerPrinted(String code) async {
    await settleWrite(
      appliancesRef.doc(code).set({
        'stickerPrintedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  /// Техника больше не у клиента (заменили) — паспорт уходит в архив,
  /// страница по наклейке остаётся.
  static Future<void> setApplianceRetired(String code, bool retired) async {
    await settleWrite(
      appliancesRef.doc(code).set({
        'status': retired
            ? HomeAppliance.statusRetired
            : HomeAppliance.statusActive,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
  }

  static Future<String?> uploadNameplate(String code, Uint8List bytes) async {
    try {
      final ref = FirebaseStorage.instance.ref().child(
        'companies/$kCompanyId/appliances/$code/nameplate_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await ref
          .putData(bytes, SettableMetadata(contentType: 'image/jpeg'))
          .timeout(const Duration(seconds: 60));
      return await ref.getDownloadURL();
    } catch (error) {
      debugPrint('CarePlanService.uploadNameplate: $error');
      return null;
    }
  }

  // -------------------------------------------------------------- заявки

  /// Поля, которые [JobService.create] дописывает новой заявке клиента на
  /// плане: план, вид «ремонт по плану» и паспорт, если по типу техники он
  /// у клиента ровно один.
  static Map<String, dynamic> autoTagFields(Job job) {
    if (job.carePlanId.isNotEmpty) return const {};
    final plan = memberPlanFor(clientId: job.clientId, phone: job.clientPhone);
    if (plan == null) return const {};
    final fields = <String, dynamic>{
      'carePlanId': plan.id,
      'carePlanKind': job.carePlanKind.isNotEmpty
          ? job.carePlanKind
          : CarePlan.kindRepair,
    };
    if (job.applianceIds.isEmpty) {
      final ids = matchAppliances(
        appliancesForClient(plan.clientId),
        [for (final a in job.appliances) a.type],
      );
      if (ids.isNotEmpty) fields['applianceIds'] = ids;
    }
    return fields;
  }

  /// Паспорта под типы техники заявки. Только однозначные совпадения: два
  /// холодильника у клиента — не угадываем, мастер выберет сам.
  static List<String> matchAppliances(
    List<HomeAppliance> owned,
    List<String> jobTypes,
  ) {
    final ids = <String>[];
    for (final type in jobTypes) {
      final want = ApplianceEnglish.of(type);
      if (want == 'Appliance') continue;
      final hits = [
        for (final a in owned)
          if (ApplianceEnglish.of(a.type) == want) a,
      ];
      if (hits.length == 1 && !ids.contains(hits.first.id)) {
        ids.add(hits.first.id);
      }
    }
    return ids;
  }

  static Future<void> setJobPlan(
    String jobId, {
    required String planId,
    required String kind,
  }) => JobService.update(jobId, {
    'carePlanId': kind.isEmpty ? '' : planId,
    'carePlanKind': kind,
  });

  static Future<void> setJobAppliances(String jobId, List<String> ids) =>
      JobService.update(jobId, {'applianceIds': ids});

  // ------------------------------------------------------------ слияние

  /// Дубль клиента слили в основную карточку — его планы и паспорта
  /// переезжают туда же, иначе Care Plan пропал бы из карточки.
  static Future<void> reassignClient({
    required String fromId,
    required String toId,
    required String toName,
  }) async {
    if (fromId.isEmpty || toId.isEmpty || fromId == toId) return;
    final plans = await plansRef.where('clientId', isEqualTo: fromId).get();
    final items =
        await appliancesRef.where('clientId', isEqualTo: fromId).get();
    if (plans.docs.isEmpty && items.docs.isEmpty) return;
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in plans.docs) {
      batch.update(doc.reference, {
        'clientId': toId,
        'clientName': toName,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    for (final doc in items.docs) {
      batch.update(doc.reference, {
        'clientId': toId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await settleWrite(batch.commit());
  }

  // ------------------------------------------------- шторка входящего

  /// Номера членов плана → подпись для нативной шторки входящего звонка.
  @visibleForTesting
  static Map<String, String> callerLabels(List<CarePlan> plans) => {
    for (final plan in plans)
      if (plan.isMember)
        for (final phone in plan.phones) phone: callerLabel,
  };

  static Future<void> _syncCallerLabels() async {
    try {
      final encoded = jsonEncode(callerLabels(_plans));
      if (encoded == _syncedLabels) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(callerLabelsKey, encoded);
      _syncedLabels = encoded;
    } catch (error) {
      debugPrint('CarePlanService caller labels: $error');
    }
  }
}
