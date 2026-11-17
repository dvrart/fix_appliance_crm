import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/tester_build.dart';
import '../models/care_plan.dart';
import '../models/contact.dart';
import '../models/expense.dart';
import '../models/home_appliance.dart';
import '../models/job.dart';
import '../models/location.dart';
import 'auth_service.dart';
import 'status_service.dart';

/// Набор демонстрационных данных для новой базы тестировщика.
class TesterDemoSeedBundle {
  final List<Map<String, dynamic>> clients;
  final List<Map<String, dynamic>> jobs;
  final List<Map<String, dynamic>> warehouseItems;
  final List<Map<String, dynamic>> expenses;
  final List<Map<String, dynamic>> calls;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> carePlans;
  final List<Map<String, dynamic>> appliances;

  const TesterDemoSeedBundle({
    required this.clients,
    required this.jobs,
    required this.warehouseItems,
    required this.expenses,
    required this.calls,
    required this.messages,
    required this.carePlans,
    required this.appliances,
  });
}

/// Однократное наполнение базы тестировщика (`companies/tester_<uid>`)
/// реалистичными клиентами, заявками на текущую неделю, складом, счетами,
/// расходами и историей связи при первой установке.
class TesterDemoSeedService {
  TesterDemoSeedService._();

  static const int currentSeedVersion = 1;
  static const String seedConfigKey = 'demoSeedVersion';

  static final Map<String, Future<void>> _inFlight = {};

  /// Запускает наполнение базы тестировщика, если оно ещё не выполнялось.
  static Future<void> ensureSeeded({String? companyId}) {
    if (!kTesterAppBuild) return Future.value();
    final targetCompany = (companyId ?? AuthService.currentCompanyId).trim();
    if (targetCompany.isEmpty ||
        targetCompany == 'fix_appliance_ca' ||
        targetCompany == 'tester_offline' ||
        !targetCompany.startsWith('tester_')) {
      return Future.value();
    }
    return _inFlight[targetCompany] ??= _seedIfNeeded(targetCompany)
        .whenComplete(() => _inFlight.remove(targetCompany));
  }

  static Future<void> _seedIfNeeded(String companyId) async {
    try {
      final db = FirebaseFirestore.instance;
      final companyRef = db.collection('companies').doc(companyId);
      final configRef = companyRef.collection('settings').doc('config');

      final configSnap = await configRef
          .get()
          .timeout(const Duration(seconds: 8));
      final configData = configSnap.data() ?? const <String, dynamic>{};
      final seededVersion = (configData[seedConfigKey] as num?)?.toInt() ?? 0;
      if (seededVersion >= currentSeedVersion) return;

      final bundle = buildSeedBundle();
      final batch = db.batch();

      for (final client in bundle.clients) {
        final id = client['id'] as String;
        final data = Map<String, dynamic>.from(client)..remove('id');
        batch.set(
          companyRef.collection('clients').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final item in bundle.warehouseItems) {
        final id = item['id'] as String;
        final data = Map<String, dynamic>.from(item)..remove('id');
        batch.set(
          companyRef.collection('warehouse').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final job in bundle.jobs) {
        final id = job['id'] as String;
        final data = Map<String, dynamic>.from(job)..remove('id');
        batch.set(
          companyRef.collection('jobs').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final exp in bundle.expenses) {
        final id = exp['id'] as String;
        final data = Map<String, dynamic>.from(exp)..remove('id');
        batch.set(
          companyRef.collection('expenses').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final call in bundle.calls) {
        final id = call['id'] as String;
        final data = Map<String, dynamic>.from(call)..remove('id');
        batch.set(
          companyRef.collection('calls').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final msg in bundle.messages) {
        final id = msg['id'] as String;
        final data = Map<String, dynamic>.from(msg)..remove('id');
        batch.set(
          companyRef.collection('messages').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final plan in bundle.carePlans) {
        final id = plan['id'] as String;
        final data = Map<String, dynamic>.from(plan)..remove('id');
        batch.set(
          companyRef.collection('care_plans').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      for (final app in bundle.appliances) {
        final id = app['id'] as String;
        final data = Map<String, dynamic>.from(app)..remove('id');
        batch.set(
          companyRef.collection('appliances').doc(id),
          data,
          SetOptions(merge: true),
        );
      }

      batch.set(
        configRef,
        {
          seedConfigKey: currentSeedVersion,
          'demoSeededAt': FieldValue.serverTimestamp(),
          'nextInvoiceNumber': 1014,
          'nextEstimateNumber': 2004,
          'completedJobsBefore2026_08_17': 1,
        },
        SetOptions(merge: true),
      );

      await batch.commit();
      unawaited(StatusService.loadDefsOnce());
    } catch (e) {
      debugPrint('TesterDemoSeedService._seedIfNeeded: $e');
    }
  }

  /// Чистая сборка демо-набора относительно переданной даты [now]:
  /// - 10 клиентов (у одного 3 заявки, у другого 2 заявки, у остальных 8 по 1 заявке);
  /// - у всех 8 клиентов с 1 заявкой заявки уже выполнены (`Завершено` + оплаченный счёт);
  /// - у клиентов с 2 и 3 заявками — 5 заявок в разных активных статусах
  ///   (`Вызов`, `Ожидание запчасти`, `Установка`, `Депозит`, `Ожидание оплаты`);
  /// - на календаре текущей недели распределено 15 выездов (включая повторные выезды);
  /// - склад наполнен 12 ходовыми запчастями по всем категориям.
  @visibleForTesting
  static TesterDemoSeedBundle buildSeedBundle({DateTime? now}) {
    final anchor = now ?? DateTime.now();
    final today = DateTime(anchor.year, anchor.month, anchor.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));

    DateTime slot(int dayOffset, int hour, [int minute = 0]) => DateTime(
      monday.year,
      monday.month,
      monday.day + dayOffset,
      hour,
      minute,
    );

    final clients = _buildClients(monday);
    final warehouseItems = _buildWarehouseItems(monday);
    final jobs = _buildJobs(monday, slot);
    final expenses = _buildExpenses(monday);
    final calls = _buildCalls(monday, slot);
    final messages = _buildMessages(monday, slot);
    final carePlans = _buildCarePlans(monday);
    final appliances = _buildAppliances(monday);

    return TesterDemoSeedBundle(
      clients: clients,
      jobs: jobs,
      warehouseItems: warehouseItems,
      expenses: expenses,
      calls: calls,
      messages: messages,
      carePlans: carePlans,
      appliances: appliances,
    );
  }

  static List<Map<String, dynamic>> _buildClients(DateTime monday) {
    Map<String, dynamic> makeClient({
      required String id,
      required String fullName,
      required String phone,
      required String email,
      required String street,
      required String city,
      required String postalCode,
      required double lat,
      required double lng,
      String? unit,
      String? companyName,
      String? notes,
      String source = 'Google',
      bool isRegular = false,
      List<Location> extraLocations = const [],
      int createdDaysAgo = 14,
    }) {
      final createdAt = monday.subtract(Duration(days: createdDaysAgo));
      final primaryLoc = Location(
        id: 'loc_${id}_1',
        street: street,
        city: city,
        postalCode: postalCode,
        unit: unit,
        notes: notes,
        createdAt: createdAt,
        lat: lat,
        lng: lng,
        geoAddress: [
          if (unit != null && unit.isNotEmpty) unit,
          street,
          city,
          postalCode,
        ].join(', '),
        contacts: [
          Contact(
            id: 'cnt_${id}_1',
            name: fullName,
            phone: phone,
            role: 'owner',
            isPrimary: true,
          ),
        ],
      );
      final locations = [primaryLoc, ...extraLocations];
      return {
        'id': id,
        'name': fullName,
        'fullName': fullName,
        'phone': phone,
        'extraPhones': const <String>[],
        'email': email,
        'company': companyName ?? '',
        'companyName': companyName,
        'notes': notes ?? '',
        'source': source,
        'isRegular': isRegular,
        'createdByAi': false,
        'address': primaryLoc.fullAddress,
        'locations': [for (final loc in locations) loc.toMap()],
        'createdAt': Timestamp.fromDate(createdAt),
        'lastActiveAt': Timestamp.fromDate(monday),
        'updatedAt': Timestamp.fromDate(monday),
      };
    }

    return [
      // Клиент 1 — 3 заявки (в разных статусах: Вызов, Ожидание запчасти, Установка)
      makeClient(
        id: 'demo_client_01',
        fullName: 'Robert MacKenzie',
        phone: '+15197524101',
        email: 'r.mackenzie@grandriverprops.ca',
        street: '142 Dalhousie St',
        city: 'Brantford',
        postalCode: 'N3T 2J4',
        lat: 43.1394,
        lng: -80.2644,
        companyName: 'Grand River Properties',
        notes: 'Постоянный клиент (3 объекта). Код домофона #1402.',
        source: 'Постоянный клиент',
        isRegular: true,
        createdDaysAgo: 60,
        extraLocations: [
          Location(
            id: 'loc_demo_client_01_2',
            street: '88 Colborne St W',
            city: 'Brantford',
            postalCode: 'N3T 1K5',
            unit: 'Unit 4B',
            notes: 'Арендная квартира, звонить арендатору за 30 мин.',
            createdAt: monday.subtract(const Duration(days: 45)),
            lat: 43.1362,
            lng: -80.2718,
            geoAddress: 'Unit 4B, 88 Colborne St W, Brantford, N3T 1K5',
            contacts: [
              Contact(
                id: 'cnt_demo_client_01_2',
                name: 'Kevin Miller (Tenant)',
                phone: '+15197528890',
                role: 'tenant',
                isPrimary: true,
              ),
            ],
          ),
        ],
      ),
      // Клиент 2 — 2 заявки (в разных статусах: Депозит, Ожидание оплаты)
      makeClient(
        id: 'demo_client_02',
        fullName: 'Sarah Jenkins',
        phone: '+15194426312',
        email: 'sarah.jenkins@outlook.com',
        street: '45 Grand River St N',
        city: 'Paris',
        postalCode: 'N3L 2M2',
        lat: 43.1942,
        lng: -80.3845,
        notes: 'Частный дом, парковка у гаража. Есть собака во дворе.',
        source: 'Google',
        isRegular: true,
        createdDaysAgo: 35,
      ),
      // Клиенты 3..10 — по 1 заявке, все уже выполнены (Завершено)
      makeClient(
        id: 'demo_client_03',
        fullName: 'Michael Thompson',
        phone: '+15194265183',
        email: 'm.thompson82@gmail.com',
        street: '190 Argyle St',
        city: 'Simcoe',
        postalCode: 'N3Y 1W4',
        lat: 42.8373,
        lng: -80.3041,
        notes: 'Вход со стороны парковки.',
        source: 'Google',
        createdDaysAgo: 20,
      ),
      makeClient(
        id: 'demo_client_04',
        fullName: 'Elena Kowalski',
        phone: '+19055287419',
        email: 'elena.kowalski@bell.net',
        street: '312 King St W',
        city: 'Hamilton',
        postalCode: 'L8P 1B1',
        lat: 43.2584,
        lng: -79.8789,
        notes: 'Подземный гостевой паркинг P1.',
        source: 'Рекомендация',
        isRegular: true,
        createdDaysAgo: 28,
      ),
      makeClient(
        id: 'demo_client_05',
        fullName: 'David Chen',
        phone: '+15196219044',
        email: 'david.chen@techworks.ca',
        street: '74 Hespeler Rd',
        city: 'Cambridge',
        postalCode: 'N1R 3G6',
        lat: 43.3862,
        lng: -80.3221,
        notes: 'Просит писать SMS перед выездом.',
        source: 'Сайт',
        createdDaysAgo: 15,
      ),
      makeClient(
        id: 'demo_client_06',
        fullName: 'Amanda Morales',
        phone: '+15197593320',
        email: 'amanda.morales@gmail.com',
        street: '215 King George Rd',
        city: 'Brantford',
        postalCode: 'N3R 5L4',
        lat: 43.1715,
        lng: -80.2810,
        notes: 'Удобнее в первой половине дня.',
        source: 'Google',
        createdDaysAgo: 12,
      ),
      makeClient(
        id: 'demo_client_07',
        fullName: 'Daniel O\'Connor',
        phone: '+15195394417',
        email: 'doconnor@oxfordmail.ca',
        street: '518 Dundas St',
        city: 'Woodstock',
        postalCode: 'N4S 1C5',
        lat: 43.1306,
        lng: -80.7467,
        notes: 'Свой дом, техника на первом этаже.',
        source: 'Google',
        createdDaysAgo: 10,
      ),
      makeClient(
        id: 'demo_client_08',
        fullName: 'Priya Patel',
        phone: '+19056482905',
        email: 'priya.patel@mcgillalumni.ca',
        street: '62 Wilson St E',
        city: 'Ancaster',
        postalCode: 'L9G 2B4',
        lat: 43.2185,
        lng: -79.9872,
        notes: 'Предпочитает оплату картой или e-Transfer.',
        source: 'Рекомендация',
        createdDaysAgo: 9,
      ),
      makeClient(
        id: 'demo_client_09',
        fullName: 'Lucas VanderBerg',
        phone: '+15194437781',
        email: 'lucas.vb@norfolkfarms.ca',
        street: '28 Alice St',
        city: 'Waterford',
        postalCode: 'N0E 1Y0',
        lat: 42.9317,
        lng: -80.2895,
        notes: 'Большая прачечная у заднего входа.',
        source: 'Google',
        createdDaysAgo: 8,
      ),
      makeClient(
        id: 'demo_client_10',
        fullName: 'Natalie Brooks',
        phone: '+19057653910',
        email: 'natalie.brooks@rogers.com',
        street: '104 Argyle St N',
        city: 'Caledonia',
        postalCode: 'N3W 1B8',
        lat: 43.0748,
        lng: -79.9516,
        notes: 'Дома после 11:30.',
        source: 'Сайт',
        createdDaysAgo: 7,
      ),
    ];
  }

  static List<Map<String, dynamic>> _buildWarehouseItems(DateTime monday) {
    Map<String, dynamic> makePart({
      required String id,
      required String name,
      required String partNumber,
      required String modelNumber,
      required String category,
      required double price,
      required double costPrice,
      required int quantity,
      int minQuantity = 2,
      List<String> interchange = const [],
      String other = '',
    }) {
      return {
        'id': id,
        'name': name,
        'partNumber': partNumber,
        'modelNumber': modelNumber,
        'barcode': partNumber,
        'category': category,
        'price': price,
        'costPrice': costPrice,
        'quantity': quantity,
        'minQuantity': minQuantity,
        'imageUrl': null,
        'photos': const <String>[],
        'webImageUrl': null,
        'webImageSource': null,
        'coverUrl': null,
        'other': other,
        'isUsed': false,
        'interchange': interchange,
        'createdAt': Timestamp.fromDate(monday.subtract(const Duration(days: 20))),
        'updatedAt': Timestamp.fromDate(monday),
      };
    }

    return [
      makePart(
        id: 'demo_part_01',
        name: 'Evaporator Fan Motor (Мотор обдува испарителя)',
        partNumber: 'WPW10311524',
        modelNumber: 'WRF555SDFZ',
        category: 'Холодильник',
        price: 115.0,
        costPrice: 42.0,
        quantity: 4,
        interchange: const ['W10311524', 'AP6019257', 'PS11752563'],
        other: 'Whirlpool / KitchenAid / Maytag French Door',
      ),
      makePart(
        id: 'demo_part_02',
        name: 'Ice Maker Assembly (Льдогенератор в сборе)',
        partNumber: 'DA97-17376B',
        modelNumber: 'RF28R7351SR',
        category: 'Холодильник',
        price: 185.0,
        costPrice: 78.0,
        quantity: 2,
        interchange: const ['DA97-17376A', 'AP6241527', 'PS12082640'],
        other: 'Samsung Ice Master',
      ),
      makePart(
        id: 'demo_part_03',
        name: 'Defrost Heater & Thermostat Kit (ТЭН оттайки)',
        partNumber: 'WR51X10055',
        modelNumber: 'GSS25GSHSS',
        category: 'Холодильник',
        price: 85.0,
        costPrice: 24.0,
        quantity: 5,
        interchange: const ['AP3183311', 'PS303781', 'WR51X10030'],
        other: 'GE / Hotpoint Side-by-Side',
      ),
      makePart(
        id: 'demo_part_04',
        name: 'Drain Pump Motor (Сливной насос)',
        partNumber: '4681EA2001T',
        modelNumber: 'WM3600HVA',
        category: 'Стиральная машина',
        price: 110.0,
        costPrice: 34.0,
        quantity: 6,
        interchange: const ['4681EA1007G', 'AP5328388', 'PS3579318'],
        other: 'LG / Kenmore Front Load Washer',
      ),
      makePart(
        id: 'demo_part_05',
        name: 'Door Boot Seal Bellow (Манжета люка)',
        partNumber: 'W10820048',
        modelNumber: 'WFW75HEFW',
        category: 'Стиральная машина',
        price: 165.0,
        costPrice: 68.0,
        quantity: 1,
        minQuantity: 2,
        interchange: const ['WPW10820048', 'W10381562', 'AP5989716'],
        other: 'Whirlpool Duet / Maytag — осталась 1 шт (нужен дозаказ)',
      ),
      makePart(
        id: 'demo_part_06',
        name: 'Shift Actuator (Актуатор переключения режимов)',
        partNumber: 'W11481722',
        modelNumber: 'WTW5000DW',
        category: 'Стиральная машина',
        price: 95.0,
        costPrice: 31.0,
        quantity: 3,
        interchange: const ['W10913953', 'W10597177', 'AP6993354'],
        other: 'Whirlpool / Maytag / Amana VMW',
      ),
      makePart(
        id: 'demo_part_07',
        name: 'Dryer Heating Element 240V (ТЭН сушилки)',
        partNumber: '279838',
        modelNumber: 'WED4815EW',
        category: 'Сушилка',
        price: 95.0,
        costPrice: 28.0,
        quantity: 5,
        interchange: const ['3398064', 'WP279837', 'AP3094254'],
        other: 'Whirlpool / Roper / Inglis / Kenmore',
      ),
      makePart(
        id: 'demo_part_08',
        name: 'Dryer Maintenance Kit: Rollers, Belt, Pulley (Ремкомплект)',
        partNumber: '4392067',
        modelNumber: 'MEDC465HW',
        category: 'Сушилка',
        price: 120.0,
        costPrice: 39.0,
        quantity: 4,
        interchange: const ['4392067VP', 'AP3109602', 'PS373088'],
        other: '29" Whirlpool / Maytag Dryer Kit',
      ),
      makePart(
        id: 'demo_part_09',
        name: 'Dryer Heater Assembly (Нагревательный блок)',
        partNumber: 'DC97-14486A',
        modelNumber: 'DVE45R6100C',
        category: 'Сушилка',
        price: 145.0,
        costPrice: 52.0,
        quantity: 0,
        minQuantity: 2,
        interchange: const ['DC47-00019A', 'AP4342351'],
        other: 'Samsung Dryer — закончились, ждём поставку',
      ),
      makePart(
        id: 'demo_part_10',
        name: 'Oven Bake Igniter (Запальник духовки)',
        partNumber: '5303935066',
        modelNumber: 'FGGF3036TF',
        category: 'Плита/Духовка',
        price: 110.0,
        costPrice: 32.0,
        quantity: 4,
        interchange: const ['316489403', 'AP2150412', 'PS470129'],
        other: 'Frigidaire / Electrolux Gas Range',
      ),
      makePart(
        id: 'demo_part_11',
        name: 'Dishwasher Drain Pump (Помпа слива посудомойки)',
        partNumber: '00631200',
        modelNumber: 'SHPM65Z55N',
        category: 'Посудомойка',
        price: 125.0,
        costPrice: 45.0,
        quantity: 3,
        interchange: const ['631200', 'AP5972147', 'PS11704119'],
        other: 'Bosch / Thermador / Gaggenau',
      ),
      makePart(
        id: 'demo_part_12',
        name: 'Thermal Fuse & High-Limit Thermostat Kit (Термопредохранитель)',
        partNumber: 'WP3392519',
        modelNumber: 'Universal',
        category: 'Универсальное',
        price: 45.0,
        costPrice: 12.0,
        quantity: 8,
        interchange: const ['3392519', '279816', 'AP6008325'],
        other: 'Ходовой расходник в машине мастера',
      ),
    ];
  }

  static List<Map<String, dynamic>> _buildJobs(
    DateTime monday,
    DateTime Function(int dayOffset, int hour, [int minute]) slot,
  ) {
    Map<String, dynamic> makeInvoice({
      required String number,
      required DateTime createdAt,
      required List<Map<String, dynamic>> items,
      required List<Map<String, dynamic>> payments,
      double taxRate = TaxRates.hst,
      String taxScope = 'all',
      bool stockApplied = true,
      String? fromEstimateNumber,
    }) {
      return {
        'type': 'Invoice',
        'number': number,
        'items': items,
        'taxRate': taxRate,
        'taxScope': taxScope,
        'payments': payments,
        'stockApplied': stockApplied,
        'createdAt': createdAt.toIso8601String(),
        'fromEstimateNumber': ?fromEstimateNumber,
      };
    }

    Map<String, dynamic> makeEstimate({
      required String number,
      required DateTime createdAt,
      required List<Map<String, dynamic>> items,
      String estimateStatus = 'sent',
      double taxRate = TaxRates.hst,
      String taxScope = 'all',
    }) {
      return {
        'type': 'Estimate',
        'number': number,
        'items': items,
        'taxRate': taxRate,
        'taxScope': taxScope,
        'estimateStatus': estimateStatus,
        'payments': const <Map<String, dynamic>>[],
        'createdAt': createdAt.toIso8601String(),
      };
    }

    Map<String, dynamic> serviceItem(String name, double price) => {
      'name': name,
      'type': 'Service',
      'qty': 1,
      'price': price,
    };

    Map<String, dynamic> partItem({
      required String name,
      required String partNumber,
      required String warehouseItemId,
      required double price,
      required double costPrice,
      int qty = 1,
    }) => {
      'name': name,
      'partNumber': partNumber,
      'warehouseItemId': warehouseItemId,
      'type': 'Part',
      'qty': qty,
      'price': price,
      'costPrice': costPrice,
    };

    Map<String, dynamic> payment({
      required double amount,
      required String method,
      required DateTime date,
    }) => {
      'amount': amount,
      'method': method,
      'date': date.toIso8601String(),
    };

    Map<String, dynamic> makeJob({
      required String id,
      required String clientId,
      required String clientName,
      required String clientPhone,
      required String clientAddress,
      required String clientEmail,
      required String city,
      required List<JobAppliance> appliances,
      required String description,
      required String status,
      required List<JobVisit> visits,
      String solution = '',
      String priority = JobPriorities.low,
      bool clientIsRegular = false,
      bool hasJobSite = false,
      String? jobSiteName,
      String? jobSitePhone,
      String? jobSiteAddress,
      DateTime? completedAt,
      DateTime? createdAt,
      List<Map<String, dynamic>> documents = const [],
      String source = 'phone',
      String packingNotes = '',
      List<JobTrackingOrder> trackingOrders = const [],
      DateTime? promisedPartAt,
      List<String> applianceIds = const [],
      String carePlanId = '',
      String carePlanKind = '',
    }) {
      final job = Job(
        id: id,
        clientId: clientId,
        clientName: clientName,
        clientPhone: clientPhone,
        clientAddress: clientAddress,
        clientEmail: clientEmail,
        clientIsRegular: clientIsRegular,
        hasJobSite: hasJobSite,
        jobSiteName: jobSiteName,
        jobSitePhone: jobSitePhone,
        jobSiteAddress: jobSiteAddress,
        appliances: appliances,
        description: description,
        solution: solution,
        status: status,
        priority: priority,
        visits: visits,
        completedAt: completedAt,
        createdAt: createdAt ?? monday.subtract(const Duration(days: 2)),
        documents: documents,
        city: city,
        source: source,
        packingNotes: packingNotes,
        trackingOrders: trackingOrders,
        promisedPartAt: promisedPartAt,
        applianceIds: applianceIds,
        carePlanId: carePlanId,
        carePlanKind: carePlanKind,
      );
      final map = job.toMap();
      map['id'] = id;
      map['createdAt'] = Timestamp.fromDate(job.createdAt);
      map['updatedAt'] = Timestamp.fromDate(monday);
      if (completedAt != null) {
        map['completedAt'] = Timestamp.fromDate(completedAt);
      }
      if (promisedPartAt != null) {
        map['promisedPartAt'] = Timestamp.fromDate(promisedPartAt);
      }
      return map;
    }

    return [
      // =====================================================================
      // КЛИЕНТ 1 (Robert MacKenzie) — 3 заявки в разных статусах:
      // 1) Вызов (Суббота 10:00)
      // 2) Ожидание запчасти (Вторник 15:00 диагностика -> Суббота 13:30 визит)
      // 3) Установка (Понедельник 15:00 диагностика -> Пятница 13:00 установка)
      // =====================================================================
      makeJob(
        id: 'demo_job_01',
        clientId: 'demo_client_01',
        clientName: 'Robert MacKenzie',
        clientPhone: '+15197524101',
        clientAddress: '142 Dalhousie St, Brantford, N3T 2J4',
        clientEmail: 'r.mackenzie@grandriverprops.ca',
        city: 'Brantford',
        clientIsRegular: true,
        status: JobStatuses.call,
        priority: JobPriorities.high,
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Холодильник',
            brand: 'KitchenAid',
            model: 'KRFC704FPS',
            serialNumber: 'K94108271',
            issue: 'Тепло в холодильной камере, морозилка морозит нормально',
          ),
        ],
        description:
            'Холодильная камера +11°C, слышен треск льда у задней стенки испарителя. Проверить мотор обдува WPW10311524 и датчик оттайки.',
        packingNotes: 'WPW10311524, тестер, парогенератор',
        applianceIds: const ['d2m8p4k9x7'],
        carePlanId: 'demo_plan_01',
        carePlanKind: CarePlan.kindRepair,
        visits: [
          JobVisit(
            id: 'v_job01_1',
            startAt: slot(5, 10, 0),
            durationMinutes: 120,
            note: 'Основной дом клиента, позвонить за 20 минут',
            outcome: JobVisit.scheduled,
            smsConfirmStatus: JobVisit.confirmConfirmed,
          ),
        ],
        documents: [
          makeEstimate(
            number: 'EST-2001',
            createdAt: slot(4, 16, 0),
            items: [
              serviceItem('Diagnostic & Evaporator Fan Replacement Labour', 135.0),
              partItem(
                name: 'Evaporator Fan Motor WPW10311524',
                partNumber: 'WPW10311524',
                warehouseItemId: 'demo_part_01',
                price: 115.0,
                costPrice: 42.0,
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_02',
        clientId: 'demo_client_01',
        clientName: 'Robert MacKenzie',
        clientPhone: '+15197524101',
        clientAddress: '142 Dalhousie St, Brantford, N3T 2J4',
        clientEmail: 'r.mackenzie@grandriverprops.ca',
        city: 'Brantford',
        clientIsRegular: true,
        status: JobStatuses.waitingPart,
        priority: JobPriorities.medium,
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Плита/Духовка',
            brand: 'GE Profile',
            model: 'PGS930YPFS',
            serialNumber: 'GP2048192',
            issue: 'Ошибка F350, духовка отключается при нагреве выше 350°F',
          ),
        ],
        description:
            'При разогреве свыше 350°F выдаёт код F350 (Cooling Fan Speed Error). Заказана крыльчатка и плата управления вентилятором WB26X32608.',
        solution:
            'Выполнена диагностика, подтверждён обрыв таходатчика вентилятора охлаждения. Деталь заказана.',
        packingNotes: 'WB26X32608 Cooling Fan Assembly',
        promisedPartAt: slot(5, 12, 0),
        trackingOrders: const [
          JobTrackingOrder(
            id: 'trk_demo_01',
            part: 'WB26X32608 Cooling Fan Assembly',
            carrier: 'amazon',
            trackingNumber: 'TBA319048571204',
            orderId: '702-4918273-8812241',
            status: 'В пути (доставка в пятницу)',
          ),
        ],
        visits: [
          JobVisit(
            id: 'v_job02_1',
            startAt: slot(1, 15, 0),
            durationMinutes: 120,
            note: 'Первичная диагностика ошибки F350',
            outcome: JobVisit.done,
          ),
          JobVisit(
            id: 'v_job02_2',
            startAt: slot(5, 13, 30),
            durationMinutes: 120,
            note: 'Повторный выезд после получения вентилятора WB26X32608',
            outcome: JobVisit.scheduled,
          ),
        ],
        documents: [
          makeEstimate(
            number: 'EST-2002',
            createdAt: slot(1, 16, 30),
            estimateStatus: 'approved',
            items: [
              serviceItem('Oven Cooling Fan Replacement Labour', 160.0),
              {
                'name': 'GE Cooling Fan Assembly WB26X32608',
                'partNumber': 'WB26X32608',
                'type': 'Part',
                'qty': 1,
                'price': 195.0,
                'costPrice': 92.0,
              },
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_03',
        clientId: 'demo_client_01',
        clientName: 'Robert MacKenzie',
        clientPhone: '+15197524101',
        clientAddress: '142 Dalhousie St, Brantford, N3T 2J4',
        clientEmail: 'r.mackenzie@grandriverprops.ca',
        city: 'Brantford',
        clientIsRegular: true,
        hasJobSite: true,
        jobSiteName: 'Kevin Miller (Tenant)',
        jobSitePhone: '+15197528890',
        jobSiteAddress: 'Unit 4B, 88 Colborne St W, Brantford, N3T 1K5',
        status: JobStatuses.install,
        priority: JobPriorities.medium,
        source: 'sms',
        appliances: [
          JobAppliance(
            type: 'Стиральная машина',
            brand: 'Maytag',
            model: 'MHW5630HW',
            serialNumber: 'MY8837120',
            issue: 'Подтекает вода из-под дверцы люка во время стирки',
          ),
        ],
        description:
            'Арендная квартира Unit 4B. Порвана манжета люка снизу. Взят депозит \$120, манжета W10820048 со склада отложена на установку в пятницу.',
        solution:
            'Осмотр выявил порез нижней складки манжеты W10820048. Назначена установка детали.',
        packingNotes: 'W10820048 Door Boot Seal, щипцы для пружинного хомута',
        visits: [
          JobVisit(
            id: 'v_job03_1',
            startAt: slot(0, 15, 0),
            durationMinutes: 120,
            note: 'Диагностика у арендатора Kevin (Unit 4B)',
            outcome: JobVisit.done,
          ),
          JobVisit(
            id: 'v_job03_2',
            startAt: slot(4, 13, 0),
            durationMinutes: 120,
            note: 'Установка манжеты люка W10820048',
            outcome: JobVisit.scheduled,
            smsConfirmStatus: JobVisit.confirmConfirmed,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1009',
            createdAt: slot(0, 16, 40),
            items: [
              serviceItem('Door Boot Seal Installation Labour', 145.0),
              partItem(
                name: 'Door Boot Seal Bellow W10820048',
                partNumber: 'W10820048',
                warehouseItemId: 'demo_part_05',
                price: 165.0,
                costPrice: 68.0,
              ),
            ],
            payments: [
              payment(
                amount: 120.0,
                method: 'e-Transfer',
                date: slot(0, 16, 45),
              ),
            ],
          ),
        ],
      ),

      // =====================================================================
      // КЛИЕНТ 2 (Sarah Jenkins) — 2 заявки в разных статусах:
      // 4) Депозит (Пятница 09:30)
      // 5) Ожидание оплаты (Четверг 15:00)
      // =====================================================================
      makeJob(
        id: 'demo_job_04',
        clientId: 'demo_client_02',
        clientName: 'Sarah Jenkins',
        clientPhone: '+15194426312',
        clientAddress: '45 Grand River St N, Paris, N3L 2M2',
        clientEmail: 'sarah.jenkins@outlook.com',
        city: 'Paris',
        clientIsRegular: true,
        status: JobStatuses.deposit,
        priority: JobPriorities.medium,
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Холодильник',
            brand: 'Samsung',
            model: 'RF28R7351SR',
            serialNumber: '08924JKN9012',
            issue: 'Льдогенератор намёрз глыбой льда и перестал выдавать лёд',
          ),
        ],
        description:
            'Замена льдогенератора DA97-17376B и герметизация ледяной шахты. Клиент внесла депозит \$100 по e-Transfer.',
        packingNotes: 'DA97-17376B Ice Maker, пищевой силиконовый герметик',
        visits: [
          JobVisit(
            id: 'v_job04_1',
            startAt: slot(4, 9, 30),
            durationMinutes: 120,
            note: 'Замена льдогенератора Samsung',
            outcome: JobVisit.scheduled,
            smsConfirmStatus: JobVisit.confirmConfirmed,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1010',
            createdAt: slot(2, 18, 0),
            items: [
              serviceItem('Ice Maker Replacement & Ice Room Seal Service', 135.0),
              partItem(
                name: 'Ice Maker Assembly DA97-17376B',
                partNumber: 'DA97-17376B',
                warehouseItemId: 'demo_part_02',
                price: 185.0,
                costPrice: 78.0,
              ),
            ],
            payments: [
              payment(
                amount: 100.0,
                method: 'e-Transfer',
                date: slot(2, 18, 15),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_05',
        clientId: 'demo_client_02',
        clientName: 'Sarah Jenkins',
        clientPhone: '+15194426312',
        clientAddress: '45 Grand River St N, Paris, N3L 2M2',
        clientEmail: 'sarah.jenkins@outlook.com',
        city: 'Paris',
        clientIsRegular: true,
        status: JobStatuses.waitingPayment,
        priority: JobPriorities.low,
        source: 'website',
        appliances: [
          JobAppliance(
            type: 'Посудомойка',
            brand: 'KitchenAid',
            model: 'KDTM404KPS',
            serialNumber: 'FA9281743',
            issue: 'Не сливает воду в конце цикла, мигает индикатор Clean',
          ),
        ],
        description:
            'Очистка крыльчатки сливной помпы от осколка стекла и замена обратного клапана. Счёт выставлен, клиент оплатит вечером переводом.',
        solution:
            'Извлечён осколок бокала из улитки насоса, проверен полный цикл слива и герметичность.',
        visits: [
          JobVisit(
            id: 'v_job05_1',
            startAt: slot(3, 15, 0),
            durationMinutes: 120,
            note: 'Ремонт слива посудомойки KitchenAid',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1011',
            createdAt: slot(3, 16, 30),
            items: [
              serviceItem('Dishwasher Drain System Repair & Test', 165.0),
            ],
            payments: const [],
          ),
        ],
      ),

      // =====================================================================
      // КЛИЕНТЫ 3..10 (8 клиентов) — у каждого ровно по 1 заявке,
      // все уже ВЫПОЛНЕНЫ (Завершено / Готово) и оплачены
      // =====================================================================
      makeJob(
        id: 'demo_job_06',
        clientId: 'demo_client_03',
        clientName: 'Michael Thompson',
        clientPhone: '+15194265183',
        clientAddress: '190 Argyle St, Simcoe, N3Y 1W4',
        clientEmail: 'm.thompson82@gmail.com',
        city: 'Simcoe',
        status: JobStatuses.completed,
        completedAt: slot(0, 10, 50),
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Холодильник',
            brand: 'Whirlpool',
            model: 'WRF555SDFZ',
            serialNumber: 'K81920411',
            issue: 'Шумит вентилятор и плохо охлаждает верхнюю полку',
          ),
        ],
        description: 'Гул за задней панелью холодильного отделения, слабый поток воздуха.',
        solution:
            'Заменён мотор вентилятора испарителя WPW10311524, выполнена разморозка дренажа. Температура в норме (+3°C / -18°C).',
        visits: [
          JobVisit(
            id: 'v_job06_1',
            startAt: slot(0, 9, 0),
            durationMinutes: 120,
            note: 'Замена мотора обдува WPW10311524',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1001',
            createdAt: slot(0, 10, 45),
            items: [
              serviceItem('Diagnostic & Evaporator Fan Replacement', 140.0),
              partItem(
                name: 'Evaporator Fan Motor WPW10311524',
                partNumber: 'WPW10311524',
                warehouseItemId: 'demo_part_01',
                price: 115.0,
                costPrice: 42.0,
              ),
            ],
            payments: [
              payment(
                amount: 288.15,
                method: 'e-Transfer',
                date: slot(0, 10, 50),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_07',
        clientId: 'demo_client_04',
        clientName: 'Elena Kowalski',
        clientPhone: '+19055287419',
        clientAddress: '312 King St W, Hamilton, L8P 1B1',
        clientEmail: 'elena.kowalski@bell.net',
        city: 'Hamilton',
        clientIsRegular: true,
        status: JobStatuses.completed,
        completedAt: slot(0, 13, 45),
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Стиральная машина',
            brand: 'LG',
            model: 'WM3600HVA',
            serialNumber: '104KWAT09812',
            issue: 'Код ошибки OE — вода остаётся в барабане',
          ),
        ],
        description: 'Стиральная машина останавливается перед отжимом с ошибкой OE.',
        solution:
            'Заменён сливной насос 4681EA2001T, очищен фильтр уловителя монет. Проверен цикл полоскания и отжима.',
        visits: [
          JobVisit(
            id: 'v_job07_1',
            startAt: slot(0, 12, 0),
            durationMinutes: 120,
            note: 'Ошибка OE — взять помпу LG 4681EA2001T',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1002',
            createdAt: slot(0, 13, 40),
            items: [
              serviceItem('Washer Drain Pump Replacement Labour', 135.0),
              partItem(
                name: 'Drain Pump Motor 4681EA2001T',
                partNumber: '4681EA2001T',
                warehouseItemId: 'demo_part_04',
                price: 110.0,
                costPrice: 34.0,
              ),
            ],
            payments: [
              payment(
                amount: 276.85,
                method: 'Stripe (card present)',
                date: slot(0, 13, 45),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_08',
        clientId: 'demo_client_05',
        clientName: 'David Chen',
        clientPhone: '+15196219044',
        clientAddress: '74 Hespeler Rd, Cambridge, N1R 3G6',
        clientEmail: 'david.chen@techworks.ca',
        city: 'Cambridge',
        status: JobStatuses.completed,
        completedAt: slot(1, 10, 40),
        source: 'website',
        appliances: [
          JobAppliance(
            type: 'Сушилка',
            brand: 'Whirlpool',
            model: 'WED4815EW',
            serialNumber: 'M92174920',
            issue: 'Барабан крутится, но бельё остаётся холодным и сырым',
          ),
        ],
        description: 'Нет нагрева в сушильной машине, питание 240V на розетке есть.',
        solution:
            'Обрыв спирали нагревательного элемента. Установлен новый ТЭН 279838 и термопредохранитель WP3392519, прочищен воздуховод.',
        visits: [
          JobVisit(
            id: 'v_job08_1',
            startAt: slot(1, 9, 0),
            durationMinutes: 120,
            note: 'Замена ТЭНа 279838',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1003',
            createdAt: slot(1, 10, 35),
            items: [
              serviceItem('Dryer Heating System Repair Labour', 130.0),
              partItem(
                name: 'Dryer Heating Element 279838',
                partNumber: '279838',
                warehouseItemId: 'demo_part_07',
                price: 95.0,
                costPrice: 28.0,
              ),
              partItem(
                name: 'Thermal Fuse Kit WP3392519',
                partNumber: 'WP3392519',
                warehouseItemId: 'demo_part_12',
                price: 45.0,
                costPrice: 12.0,
              ),
            ],
            payments: [
              payment(
                amount: 305.10,
                method: 'Cash',
                date: slot(1, 10, 40),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_09',
        clientId: 'demo_client_06',
        clientName: 'Amanda Morales',
        clientPhone: '+15197593320',
        clientAddress: '215 King George Rd, Brantford, N3R 5L4',
        clientEmail: 'amanda.morales@gmail.com',
        city: 'Brantford',
        status: JobStatuses.completed,
        completedAt: slot(1, 13, 50),
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Посудомойка',
            brand: 'Bosch',
            model: 'SHPM65Z55N',
            serialNumber: 'FD990401822',
            issue: 'Ошибка E24 / E25 на дисплее, не сливает воду',
          ),
        ],
        description: 'Посудомойка Bosch останавливается через 10 минут после старта с кодом E25.',
        solution:
            'Заклинило ротор сливной помпы из-за выработки втулки. Заменена помпа 00631200 и защёлка крышки импеллера.',
        visits: [
          JobVisit(
            id: 'v_job09_1',
            startAt: slot(1, 12, 0),
            durationMinutes: 120,
            note: 'Bosch E25 — помпа 00631200 в машине',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1004',
            createdAt: slot(1, 13, 45),
            items: [
              serviceItem('Bosch Dishwasher Pump Replacement', 145.0),
              partItem(
                name: 'Dishwasher Drain Pump 00631200',
                partNumber: '00631200',
                warehouseItemId: 'demo_part_11',
                price: 125.0,
                costPrice: 45.0,
              ),
            ],
            payments: [
              payment(
                amount: 305.10,
                method: 'e-Transfer',
                date: slot(1, 13, 50),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_10',
        clientId: 'demo_client_07',
        clientName: 'Daniel O\'Connor',
        clientPhone: '+15195394417',
        clientAddress: '518 Dundas St, Woodstock, N4S 1C5',
        clientEmail: 'doconnor@oxfordmail.ca',
        city: 'Woodstock',
        status: JobStatuses.completed,
        completedAt: slot(2, 10, 45),
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Плита/Духовка',
            brand: 'Frigidaire',
            model: 'FGGF3036TF',
            serialNumber: 'VF03491822',
            issue: 'Газовая духовка не зажигается, верхние конфорки работают',
          ),
        ],
        description: 'Запальник духовки светится тускло, но газовый клапан не открывается (ток 1.9A).',
        solution:
            'Установлен новый запальник духовки 5303935066 (ток накала 3.5A), горелка зажигается за 35 секунд.',
        visits: [
          JobVisit(
            id: 'v_job10_1',
            startAt: slot(2, 9, 0),
            durationMinutes: 120,
            note: 'Замена запальника духовки 5303935066',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1005',
            createdAt: slot(2, 10, 40),
            items: [
              serviceItem('Gas Oven Bake Igniter Replacement', 135.0),
              partItem(
                name: 'Oven Bake Igniter 5303935066',
                partNumber: '5303935066',
                warehouseItemId: 'demo_part_10',
                price: 110.0,
                costPrice: 32.0,
              ),
            ],
            payments: [
              payment(
                amount: 276.85,
                method: 'Cash',
                date: slot(2, 10, 45),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_11',
        clientId: 'demo_client_08',
        clientName: 'Priya Patel',
        clientPhone: '+19056482905',
        clientAddress: '62 Wilson St E, Ancaster, L9G 2B4',
        clientEmail: 'priya.patel@mcgillalumni.ca',
        city: 'Ancaster',
        status: JobStatuses.completed,
        completedAt: slot(2, 14, 15),
        source: 'sms',
        appliances: [
          JobAppliance(
            type: 'Холодильник',
            brand: 'GE',
            model: 'GSS25GSHSS',
            serialNumber: 'GH4192831',
            issue: 'Намерзает шуба на задней стенке морозильной камеры',
          ),
        ],
        description: 'Обмерзание испарителя морозилки, не срабатывает автоматическая оттайка.',
        solution:
            'Перегорел кварцевый ТЭН оттайки. Заменён комплект WR51X10055, разморожен испаритель.',
        visits: [
          JobVisit(
            id: 'v_job11_1',
            startAt: slot(2, 12, 30),
            durationMinutes: 120,
            note: 'Ремонт системы оттайки GE WR51X10055',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1006',
            createdAt: slot(2, 14, 10),
            items: [
              serviceItem('Defrost System Repair & Steaming', 140.0),
              partItem(
                name: 'Defrost Heater & Thermostat Kit WR51X10055',
                partNumber: 'WR51X10055',
                warehouseItemId: 'demo_part_03',
                price: 85.0,
                costPrice: 24.0,
              ),
            ],
            payments: [
              payment(
                amount: 254.25,
                method: 'Stripe (card present)',
                date: slot(2, 14, 15),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_12',
        clientId: 'demo_client_09',
        clientName: 'Lucas VanderBerg',
        clientPhone: '+15194437781',
        clientAddress: '28 Alice St, Waterford, N0E 1Y0',
        clientEmail: 'lucas.vb@norfolkfarms.ca',
        city: 'Waterford',
        status: JobStatuses.completed,
        completedAt: slot(3, 10, 45),
        source: 'phone',
        appliances: [
          JobAppliance(
            type: 'Сушилка',
            brand: 'Maytag',
            model: 'MEDC465HW',
            serialNumber: 'M03819274',
            issue: 'Сильный гул и скрип при вращении барабана',
          ),
        ],
        description: 'Громкий стук опорных роликов и свист натяжного ролика ремня.',
        solution:
            'Установлен полный ремкомплект 4392067 (2 опорных ролика, натяжной ролик и ремень), очищена внутренняя полость от ворса.',
        visits: [
          JobVisit(
            id: 'v_job12_1',
            startAt: slot(3, 9, 0),
            durationMinutes: 120,
            note: 'Ремкомплект сушилки 4392067',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1007',
            createdAt: slot(3, 10, 40),
            items: [
              serviceItem('Dryer Full Overhaul & Lint Cleaning', 135.0),
              partItem(
                name: 'Dryer Maintenance Kit 4392067',
                partNumber: '4392067',
                warehouseItemId: 'demo_part_08',
                price: 120.0,
                costPrice: 39.0,
              ),
            ],
            payments: [
              payment(
                amount: 288.15,
                method: 'e-Transfer',
                date: slot(3, 10, 45),
              ),
            ],
          ),
        ],
      ),

      makeJob(
        id: 'demo_job_13',
        clientId: 'demo_client_10',
        clientName: 'Natalie Brooks',
        clientPhone: '+19057653910',
        clientAddress: '104 Argyle St N, Caledonia, N3W 1B8',
        clientEmail: 'natalie.brooks@rogers.com',
        city: 'Caledonia',
        status: JobStatuses.completed,
        completedAt: slot(3, 13, 50),
        source: 'website',
        appliances: [
          JobAppliance(
            type: 'Стиральная машина',
            brand: 'Whirlpool',
            model: 'WTW5000DW',
            serialNumber: 'C92817405',
            issue: 'Не переключается на отжим, щёлкает снизу',
          ),
        ],
        description: 'Вертикальная стиральная машина набирает и сливает воду, но не выходит на обороты отжима (ошибка F7E5).',
        solution:
            'Заменён актуатор переключения режимов W11481722, выполнена калибровка через сервисный режим.',
        visits: [
          JobVisit(
            id: 'v_job13_1',
            startAt: slot(3, 12, 0),
            durationMinutes: 120,
            note: 'Замена актуатора W11481722 и калибровка',
            outcome: JobVisit.done,
          ),
        ],
        documents: [
          makeInvoice(
            number: 'INV-1008',
            createdAt: slot(3, 13, 45),
            items: [
              serviceItem('Shift Actuator Replacement & Calibration', 130.0),
              partItem(
                name: 'Shift Actuator W11481722',
                partNumber: 'W11481722',
                warehouseItemId: 'demo_part_06',
                price: 95.0,
                costPrice: 31.0,
              ),
            ],
            payments: [
              payment(
                amount: 254.25,
                method: 'Stripe (card present)',
                date: slot(3, 13, 50),
              ),
            ],
          ),
        ],
      ),
    ];
  }

  static List<Map<String, dynamic>> _buildExpenses(DateTime monday) {
    Map<String, dynamic> makeExpense({
      required String id,
      required String vendor,
      required DateTime date,
      required double amountExHst,
      required String categoryId,
      required String note,
      required String receiptNo,
    }) {
      final info = ExpenseCategories.byId(categoryId);
      final hst = double.parse((amountExHst * 0.13).toStringAsFixed(2));
      final total = double.parse((amountExHst + hst).toStringAsFixed(2));
      return {
        'id': id,
        'vendor': vendor,
        'date': Timestamp.fromDate(date),
        'amountExHst': amountExHst,
        'hst': hst,
        'total': total,
        'category': info.id,
        'gifi': info.gifi,
        'note': note,
        'photoUrl': '',
        'fileMime': '',
        'fileHash': '',
        'receiptNo': receiptNo,
        'capitalAsset': false,
        'needsReview': false,
        'confidence': 1.0,
        'createdAt': Timestamp.fromDate(date),
        'updatedAt': Timestamp.fromDate(monday),
      };
    }

    return [
      makeExpense(
        id: 'demo_exp_01',
        vendor: 'Shell Canada — King George Rd',
        date: monday,
        amountExHst: 74.34,
        categoryId: ExpenseCategories.vehicle.id,
        note: 'Заправка рабочего фургона (Brantford — Hamilton — Simcoe)',
        receiptNo: 'SH-482910',
      ),
      makeExpense(
        id: 'demo_exp_02',
        vendor: 'Reliable Parts Hamilton',
        date: monday.add(const Duration(days: 1)),
        amountExHst: 186.50,
        categoryId: ExpenseCategories.parts.id,
        note: 'Пополнение ходовых запчастей на склад (помпы и ТЭНы)',
        receiptNo: 'RP-904182',
      ),
      makeExpense(
        id: 'demo_exp_03',
        vendor: 'The Home Depot Pro',
        date: monday.add(const Duration(days: 2)),
        amountExHst: 48.00,
        categoryId: ExpenseCategories.supplies.id,
        note: 'Хомуты, термостойкая лента, силиконовый герметик и очиститель',
        receiptNo: 'HD-773104',
      ),
      makeExpense(
        id: 'demo_exp_04',
        vendor: 'Petro-Canada Woodstock',
        date: monday.add(const Duration(days: 3)),
        amountExHst: 68.14,
        categoryId: ExpenseCategories.vehicle.id,
        note: 'Топливо (выезды Woodstock / Waterford / Paris)',
        receiptNo: 'PC-119042',
      ),
      makeExpense(
        id: 'demo_exp_05',
        vendor: 'Bell Mobility Business',
        date: monday,
        amountExHst: 85.00,
        categoryId: ExpenseCategories.phone.id,
        note: 'Связь и мобильный интернет мастера на месяц',
        receiptNo: 'BM-552019',
      ),
    ];
  }

  static List<Map<String, dynamic>> _buildCalls(
    DateTime monday,
    DateTime Function(int dayOffset, int hour, [int minute]) slot,
  ) {
    return [
      {
        'id': 'demo_call_01',
        'callSid': 'CA_demo_0001',
        'fromNumber': '+15197524101',
        'toNumber': '+15489000688',
        'direction': 'inbound',
        'startTime': Timestamp.fromDate(slot(0, 8, 35)),
        'endTime': Timestamp.fromDate(slot(0, 8, 37)),
        'durationSeconds': 118,
        'status': 'completed',
        'aiStatus': 'completed',
        'answeredBy': 'ai',
        'reviewed': true,
        'clientId': 'demo_client_01',
        'createdJobId': 'demo_job_01',
        'summary':
            'Постоянный клиент Robert MacKenzie (142 Dalhousie St, Brantford). Холодильник KitchenAid перестал охлаждать верхнюю камеру, записан на субботу 10:00.',
        'transcription':
            'Sarah (AI): Thank you for calling Appliance Repair, this is Sarah. How can I help you today?\n'
            'Caller: Hi, it is Robert MacKenzie on 142 Dalhousie Street in Brantford. My KitchenAid fridge is warm on top.\n'
            'Sarah (AI): I have your address on file, Robert. We can book a technician for Saturday between 10:00 and 12:00. Does that work for you?\n'
            'Caller: Yes, Saturday at 10 AM is great, thank you!',
        'transcriptionRu':
            'Сара (ИИ): Спасибо за звонок в мастерскую, это Сара. Чем могу помочь?\n'
            'Клиент: Здравствуйте, это Robert MacKenzie, 142 Dalhousie St, Brantford. Холодильник KitchenAid перестал холодить сверху.\n'
            'Сара (ИИ): Ваш адрес есть в карточке, Роберт. Могу записать мастера на субботу с 10:00 до 12:00. Вам удобно?\n'
            'Клиент: Да, суббота в 10 утра отлично подходит, спасибо!',
        'aiReception': {
          'engine': 'gemini-3.8-live',
          'completed': true,
        },
      },
      {
        'id': 'demo_call_02',
        'callSid': 'CA_demo_0002',
        'fromNumber': '+15194426312',
        'toNumber': '+15489000688',
        'direction': 'inbound',
        'startTime': Timestamp.fromDate(slot(2, 17, 40)),
        'endTime': Timestamp.fromDate(slot(2, 17, 43)),
        'durationSeconds': 164,
        'status': 'completed',
        'aiStatus': 'completed',
        'answeredBy': 'master',
        'reviewed': true,
        'clientId': 'demo_client_02',
        'createdJobId': 'demo_job_04',
        'summary':
            'Sarah Jenkins (Paris): замёрз льдогенератор в холодильнике Samsung RF28R7351SR. Договорились о замене льдогенератора в пятницу 09:30 и предоплате \$100.',
      },
      {
        'id': 'demo_call_03',
        'callSid': 'CA_demo_0003',
        'fromNumber': '+15489000688',
        'toNumber': '+15194265183',
        'direction': 'outbound',
        'startTime': Timestamp.fromDate(slot(0, 8, 45)),
        'endTime': Timestamp.fromDate(slot(0, 8, 46)),
        'durationSeconds': 52,
        'status': 'completed',
        'aiStatus': 'none',
        'answeredBy': 'master',
        'reviewed': true,
        'clientId': 'demo_client_03',
        'createdJobId': 'demo_job_06',
        'summary': 'Предупредил клиента Michael Thompson о выезде через 20 минут.',
      },
      {
        'id': 'demo_call_04',
        'callSid': 'CA_demo_0004',
        'fromNumber': '+19055287419',
        'toNumber': '+15489000688',
        'direction': 'inbound',
        'startTime': Timestamp.fromDate(slot(0, 11, 15)),
        'endTime': Timestamp.fromDate(slot(0, 11, 17)),
        'durationSeconds': 95,
        'status': 'completed',
        'aiStatus': 'completed',
        'answeredBy': 'ai',
        'reviewed': true,
        'clientId': 'demo_client_04',
        'createdJobId': 'demo_job_07',
        'summary':
            'Elena Kowalski (Hamilton): стиральная машина LG показывает ошибку OE и не сливает воду.',
      },
    ];
  }

  static List<Map<String, dynamic>> _buildMessages(
    DateTime monday,
    DateTime Function(int dayOffset, int hour, [int minute]) slot,
  ) {
    return [
      {
        'id': 'demo_msg_01',
        'sid': 'SM_demo_0001',
        'from': '+15489000688',
        'to': '+15197524101',
        'body':
            'Hi Robert! Your visit is booked for Saturday 10:00–12:00 at 142 Dalhousie St, Brantford. See you then!',
        'bodyRu':
            'Здравствуйте, Robert! Визит назначен на субботу 10:00–12:00 по адресу 142 Dalhousie St, Brantford.',
        'direction': 'outbound',
        'status': 'delivered',
        'clientId': 'demo_client_01',
        'jobId': 'demo_job_01',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(0, 8, 38)),
      },
      {
        'id': 'demo_msg_02',
        'sid': 'SM_demo_0002',
        'from': '+15197524101',
        'to': '+15489000688',
        'fromName': 'Robert MacKenzie',
        'body':
            'Thank you! Also for Unit 4B on 88 Colborne St, tenant Kevin will be home Friday afternoon for the washer boot seal install.',
        'bodyRu':
            'Спасибо! И по квартире Unit 4B на 88 Colborne St — арендатор Kevin будет дома в пятницу днём для установки манжеты.',
        'direction': 'inbound',
        'status': 'received',
        'clientId': 'demo_client_01',
        'jobId': 'demo_job_03',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(0, 9, 10)),
      },
      {
        'id': 'demo_msg_03',
        'sid': 'SM_demo_0003',
        'from': '+15489000688',
        'to': '+15194426312',
        'body':
            'Hi Sarah! We received your \$100.00 deposit for Invoice INV-1010. Your Samsung ice maker installation is scheduled for Friday at 09:30.',
        'bodyRu':
            'Здравствуйте, Sarah! Получили ваш депозит \$100.00 по счёту INV-1010. Установка льдогенератора Samsung назначена на пятницу в 09:30.',
        'direction': 'outbound',
        'status': 'delivered',
        'clientId': 'demo_client_02',
        'jobId': 'demo_job_04',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(2, 18, 20)),
      },
      {
        'id': 'demo_msg_04',
        'sid': 'SM_demo_0004',
        'from': '+15194426312',
        'to': '+15489000688',
        'fromName': 'Sarah Jenkins',
        'body': 'Perfect, thank you! I will send the e-Transfer for the dishwasher invoice tonight.',
        'bodyRu': 'Отлично, спасибо! Оплату по счёту за посудомойку отправлю сегодня вечером.',
        'direction': 'inbound',
        'status': 'received',
        'clientId': 'demo_client_02',
        'jobId': 'demo_job_05',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(3, 16, 50)),
      },
      {
        'id': 'demo_msg_05',
        'sid': 'SM_demo_0005',
        'from': '+15489000688',
        'to': '+15194265183',
        'body':
            'Hi Michael! Your repair is complete. Thank you for choosing our workshop!',
        'bodyRu':
            'Здравствуйте, Michael! Ремонт завершён. Спасибо, что выбрали нашу мастерскую!',
        'direction': 'outbound',
        'status': 'delivered',
        'clientId': 'demo_client_03',
        'jobId': 'demo_job_06',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(0, 10, 55)),
      },
      {
        'id': 'demo_msg_06',
        'sid': 'SM_demo_0006',
        'from': '+19056482905',
        'to': '+15489000688',
        'fromName': 'Priya Patel',
        'body': 'Fridge is working great now, no more frost buildup. Thanks again!',
        'bodyRu': 'Холодильник работает отлично, наледи больше нет. Ещё раз спасибо!',
        'direction': 'inbound',
        'status': 'received',
        'clientId': 'demo_client_08',
        'jobId': 'demo_job_11',
        'channel': 'sms',
        'read': true,
        'createdAt': Timestamp.fromDate(slot(2, 18, 05)),
      },
    ];
  }

  static List<Map<String, dynamic>> _buildCarePlans(DateTime monday) {
    final signedAt = monday.subtract(const Duration(days: 60));
    final nextDue = monday.add(const Duration(days: 305));
    return [
      {
        'id': 'demo_plan_01',
        'clientId': 'demo_client_01',
        'clientName': 'Robert MacKenzie',
        'phones': const ['5197524101', '5197528890'],
        'address': '142 Dalhousie St, Brantford, N3T 2J4',
        'status': CarePlan.active,
        'contractNumber': 'CP-2026-014',
        'signedAt': Timestamp.fromDate(signedAt),
        'monthlyPrice': 10.0,
        'discountPercent': 100.0,
        'minTermMonths': 12,
        'waitingDays': 30,
        'coolingOffDays': 10,
        'maintenanceMonths': 12,
        'firstMaintenanceDays': 30,
        'lastMaintenanceAt': Timestamp.fromDate(
          monday.subtract(const Duration(days: 30)),
        ),
        'nextMaintenanceDue': Timestamp.fromDate(nextDue),
        'createdAt': Timestamp.fromDate(signedAt),
        'updatedAt': Timestamp.fromDate(monday),
      },
    ];
  }

  static List<Map<String, dynamic>> _buildAppliances(DateTime monday) {
    final createdAt = monday.subtract(const Duration(days: 60));
    final maintDate = monday.subtract(const Duration(days: 30));
    return [
      {
        'id': 'd2m8p4k9x7',
        'clientId': 'demo_client_01',
        'planId': 'demo_plan_01',
        'type': 'Холодильник',
        'brand': 'KitchenAid',
        'model': 'KRFC704FPS',
        'serialNumber': 'K94108271',
        'manufactureDate': '2022-05',
        'placement': 'Main Kitchen',
        'notes': 'French Door Counter-Depth Refrigerator',
        'status': HomeAppliance.statusActive,
        'createdAt': Timestamp.fromDate(createdAt),
        'stickerPrintedAt': Timestamp.fromDate(createdAt),
        'serviceLog': [
          ServiceLogEntry(
            date: maintDate,
            kind: ServiceLogEntry.kindMaintenance,
            items: const [
              'Cleaned condenser coils & checked door gaskets',
              'Verified freezer (-18°C) and fresh food (+3°C) temperatures',
            ],
            note: 'Плановое годовое ТО по подписке Care Plan',
          ).toMap(),
        ],
      },
    ];
  }
}
