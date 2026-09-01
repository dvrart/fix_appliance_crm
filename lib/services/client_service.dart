import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/app_commands.dart';
import '../core/constants.dart';
import '../models/client.dart';
import '../models/location.dart';
import 'firestore_service.dart';
import 'client_job_sync.dart';
import 'network_status_service.dart';

/// Сервис для работы с клиентами
class ClientService {
  static final _ref = FirestoreService.clientsRef;

  /// Стрим всех клиентов
  static Stream<List<Client>> streamAll() {
    return _ref.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => Client.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .where((client) => !client.isDeleted)
          .toList();
    });
  }

  static Stream<List<Client>> streamTrashed() {
    return _ref.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => Client.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .where((client) => client.isDeleted)
          .toList();
    });
  }

  /// Получить клиента по ID
  static Future<Client?> getById(String id) async {
    final doc = await _ref.doc(id).get();
    if (!doc.exists) return null;
    return Client.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  /// Поиск клиентов по телефону (для автозаполнения)
  static Future<List<Client>> searchByPhone(String phone, {String? excludeId}) async {
    final query = normalizePhone(phone);
    if (query.length < 3) return [];

    final now = DateTime.now();
    if (_phoneCache == null ||
        _phoneCacheAt == null ||
        now.difference(_phoneCacheAt!) > const Duration(seconds: 45)) {
      _phoneCache = await loadAllOnce();
      _phoneCacheAt = now;
    }

    final matches = _phoneCache!
        .where((client) => client.id != excludeId && hasPhone(client, phone))
        .toList();
    matches.sort((a, b) {
      final pa = normalizePhone(a.phone);
      final pb = normalizePhone(b.phone);
      final scoreA = pa == query || pa.endsWith(query) ? 0 : 1;
      final scoreB = pb == query || pb.endsWith(query) ? 0 : 1;
      return scoreA.compareTo(scoreB);
    });
    return matches.take(8).toList();
  }

  static List<Client>? _phoneCache;
  static DateTime? _phoneCacheAt;

  static void invalidateCache() {
    _phoneCache = null;
    _phoneCacheAt = null;
  }

  static bool hasPhone(Client client, String input) {
    final query = normalizePhone(input);
    if (query.length < 3) return false;
    bool match(String raw) {
      final phone = normalizePhone(raw);
      if (phone.length < 3 || query.length < 3) return false;
      if (phone == query) return true;
      return phone.contains(query) || query.contains(phone);
    }

    if (match(client.phone)) return true;
    for (final location in client.locations) {
      for (final contact in location.contacts) {
        if (match(contact.phone)) return true;
      }
    }
    return false;
  }

  /// Создать нового клиента. Id генерируем сами, чтобы карточка открывалась
  /// сразу и без сети.
  static Future<String> create(Client client) async {
    final docRef = _ref.doc();
    await settleWrite(
      docRef.set({
        ...client.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
      }),
    );
    invalidateCache();
    return docRef.id;
  }

  static Future<List<Client>> loadAllOnce() async {
    final snapshot = await _ref.get();
    return snapshot.docs
        .map((doc) => Client.fromMap(doc.data() as Map<String, dynamic>, doc.id))
        .where((client) => !client.isDeleted)
        .toList();
  }

  /// Обновить клиента
  static Future<void> update(String id, Map<String, dynamic> data) async {
    final name = (data['fullName'] ?? data['name'] ?? data['clientName'])
        ?.toString()
        .trim();
    final payload = <String, dynamic>{
      ...data,
      if (name != null && name.isNotEmpty) ...{
        'fullName': name,
        'name': name,
        'clientName': name,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await settleWrite(_ref.doc(id).update(payload));
    invalidateCache();
    await ClientJobSync.apply(
      clientId: id,
      name: name,
      phone: data['phone']?.toString(),
      address: data['address']?.toString(),
      email: data['email']?.toString(),
    );
  }

  /// Address string plus the first entry in [locations], if any.
  static Map<String, dynamic> addressFields({
    required String street,
    required String city,
    required String postal,
    String unit = '',
    Map<String, dynamic>? currentData,
  }) {
    final unitValue = unit.trim();
    final streetPart = [
      if (street.trim().isNotEmpty) street.trim(),
      if (unitValue.isNotEmpty)
        (RegExp(r'^(?:unit|apt|suite|#)\b', caseSensitive: false).hasMatch(unitValue)
            ? unitValue
            : 'Unit $unitValue'),
    ].join(', ');
    final full = [streetPart, city.trim(), postal.trim()]
        .where((s) => s.isNotEmpty)
        .join(', ');
    final data = <String, dynamic>{'address': full};
    final raw = currentData?['locations'];
    final locations = raw is List ? List<dynamic>.from(raw) : <dynamic>[];
    if (locations.isNotEmpty && locations.first is Map) {
      final loc = Map<String, dynamic>.from(locations.first as Map);
      loc['street'] = street.trim();
      loc['city'] = city.trim();
      loc['postalCode'] = postal.trim();
      loc['unit'] = unitValue.isEmpty ? null : unitValue;
      locations[0] = loc;
      data['locations'] = locations;
    } else {
      data['locations'] = [
        {
          'id': 'primary',
          'street': street.trim(),
          'city': city.trim(),
          'postalCode': postal.trim(),
          'unit': unitValue.isEmpty ? null : unitValue,
        },
      ];
    }
    return data;
  }

  static Future<void> updateAddress(
    String id, {
    required String street,
    required String city,
    required String postal,
    String unit = '',
    Map<String, dynamic>? currentData,
  }) {
    return update(
      id,
      addressFields(
        street: street,
        city: city,
        postal: postal,
        unit: unit,
        currentData: currentData,
      ),
    );
  }

  /// Обновить lastActiveAt (при создании заявки)
  static Future<void> touchActivity(String id) async {
    await _ref.doc(id).update({
      'lastActiveAt': FieldValue.serverTimestamp(),
    });
  }

  /// Добавить объект (Location) клиенту
  static Future<void> addLocation(String clientId, Location location) async {
    final client = await getById(clientId);
    if (client == null) return;

    final newLocations = [...client.locations, location];
    await settleWrite(
      _ref.doc(clientId).update({
        'locations': newLocations.map((l) => l.toMap()).toList(),
      }),
    );
  }

  /// Сохранить координаты объектов клиента (кэш геокодинга для карты).
  static Future<void> saveLocations(String clientId, List<Location> locations) {
    return _ref.doc(clientId).update({
      'locations': locations.map((l) => l.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Обновить объект клиента
  static Future<void> updateLocation(
    String clientId,
    String locationId,
    Location newLocation,
  ) async {
    final client = await getById(clientId);
    if (client == null) return;

    final newLocations = client.locations.map((l) {
      return l.id == locationId ? newLocation : l;
    }).toList();

    await settleWrite(
      _ref.doc(clientId).update({
        'locations': newLocations.map((l) => l.toMap()).toList(),
      }),
    );
  }

  /// В корзину на 30 дней
  static Future<void> delete(String id, {bool react = true}) async {
    if (react) AppCommands.reactAngry();
    await settleWrite(
      _ref.doc(id).update({
        'deletedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
    invalidateCache();
  }

  static Future<void> restore(String id) async {
    await settleWrite(
      _ref.doc(id).update({
        'deletedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
    invalidateCache();
  }

  /// Discarded unconfirmed AI job: trash the auto-created contact if nothing
  /// else keeps them (other live jobs, or a client FIX added by hand).
  static Future<void> trashOrphanAutoClient({
    required String clientId,
    required String discardedJobId,
    required bool jobWasUnconfirmedAuto,
  }) async {
    if (!jobWasUnconfirmedAuto) return;
    final id = clientId.trim();
    if (id.isEmpty) return;
    try {
      final client = await getById(id);
      if (client == null || client.isDeleted) return;
      if (!client.createdByAi && !Client.isPlaceholderName(client.fullName)) {
        return;
      }
      final snap = await FirestoreService.jobsRef
          .where('clientId', isEqualTo: id)
          .get();
      for (final doc in snap.docs) {
        if (doc.id == discardedJobId) continue;
        final data = doc.data();
        if (data is! Map) continue;
        final map = Map<String, dynamic>.from(data);
        if (map['deletedAt'] != null) continue;
        final status = (map['status'] ?? '').toString();
        if (JobStatuses.isCancelledStatus(status)) continue;
        return;
      }
      await delete(id, react: false);
    } catch (_) {}
  }

  static Future<void> deleteForever(String id) async {
    await _ref.doc(id).delete();
    invalidateCache();
  }

  static Future<void> purgeExpiredTrash() async {
    final cutoff = DateTime.now().subtract(const Duration(days: Client.trashKeepDays));
    final snapshot = await _ref.get();
    for (final doc in snapshot.docs) {
      final client = Client.fromMap(doc.data() as Map<String, dynamic>, doc.id);
      if (client.deletedAt != null && client.deletedAt!.isBefore(cutoff)) {
        await deleteForever(client.id);
      }
    }
  }

  static Future<void> deleteMany(Iterable<String> ids) async {
    AppCommands.reactAngry();
    final list = ids.where((id) => id.isNotEmpty).toSet().toList();
    const chunk = 450;
    for (var i = 0; i < list.length; i += chunk) {
      final end = (i + chunk > list.length) ? list.length : i + chunk;
      final batch = FirebaseFirestore.instance.batch();
      for (final id in list.sublist(i, end)) {
        batch.update(_ref.doc(id), {
          'deletedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }
    invalidateCache();
  }

  /// Создать или обновить клиента (для формы создания заявки)
  static Future<String> createOrUpdate({
    String? existingId,
    required String fullName,
    required String phone,
    required String address,
    String? email,
    String? companyName,
    String? notes,
    String? source,
    bool createdByAi = false,
  }) async {
    if (existingId != null) {
      await update(existingId, {
        'fullName': fullName,
        'name': fullName,
        'clientName': fullName,
        'phone': phone,
        'address': address,
        'email': email,
        'companyName': companyName,
        'notes': notes,
        'source': source,
      });
      return existingId;
    }

    final client = Client(
      id: '',
      fullName: fullName,
      phone: phone,
      email: email,
      companyName: companyName,
      notes: notes,
      source: source,
      createdByAi: createdByAi,
      locations: [
        Location(
          id: 'primary',
          street: address,
          city: '',
          postalCode: '',
        ),
      ],
    );

    return await create(client);
  }

  static String normalizePhone(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  /// Поиск по телефону без скобок, пробелов и чёрточек.
  static bool queryMatchesPhone(String storedPhone, String query) {
    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 3) return false;
    final phone = normalizePhone(storedPhone);
    if (phone.length < 3) return false;
    return phone.contains(digits) || digits.contains(phone);
  }

  static Future<Client?> findByPhone(String phone) async {
    final normalized = normalizePhone(phone);
    if (normalized.length < 7) return null;
    final snapshot = await _ref.get();
    for (final doc in snapshot.docs) {
      try {
        final client = Client.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (hasPhone(client, phone)) return client;
      } catch (_) {}
    }
    return null;
  }

  static Future<Client?> findExisting({String? phone, String? email}) async {
    final byPhone = await findByPhone(phone ?? '');
    if (byPhone != null) return byPhone;
    return findByEmail(email ?? '');
  }

  static Future<Client?> findByEmail(String email) async {
    final want = email.trim().toLowerCase();
    if (!want.contains('@')) return null;
    final snapshot = await _ref.get();
    for (final doc in snapshot.docs) {
      try {
        final client = Client.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (client.isDeleted) continue;
        if ((client.email ?? '').trim().toLowerCase() == want) return client;
      } catch (_) {}
    }
    return null;
  }

  static bool matchesClient(Client client, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final digits = q.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 3 && hasPhone(client, query)) return true;
    return _searchBlob(client).contains(q);
  }

  static bool matchesMap(Map<String, dynamic> data, String id, String query) {
    try {
      return matchesClient(Client.fromMap(data, id), query);
    } catch (_) {
      return false;
    }
  }

  static String _searchBlob(Client client) {
    final parts = <String>[
      client.fullName,
      client.phone,
      client.email ?? '',
      client.companyName ?? '',
      client.notes ?? '',
      client.source ?? '',
      client.address,
    ];
    for (final location in client.locations) {
      parts.addAll([
        location.fullAddress,
        location.street,
        location.city,
        location.postalCode,
        location.unit ?? '',
        location.notes ?? '',
        location.geoAddress ?? '',
      ]);
      for (final contact in location.contacts) {
        parts.addAll([contact.name, contact.phone, contact.role]);
      }
    }
    return parts.join(' ').toLowerCase();
  }

  static Future<List<Client>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final snapshot = await _ref.get();
    final matches = <Client>[];
    for (final doc in snapshot.docs) {
      try {
        final client = Client.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (matchesClient(client, q)) matches.add(client);
      } catch (_) {}
      if (matches.length >= 15) break;
    }
    return matches;
  }
}
