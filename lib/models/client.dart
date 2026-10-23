import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/sms_text.dart';
import 'location.dart';
import 'contact.dart';

/// Клиент — физическое или юридическое лицо
class Client {
  final String id;
  final String fullName;
  final String phone;
  final String? email;
  final String? companyName;
  final String? notes;
  final String? source;
  final bool isRegular;
  final bool createdByAi;
  final List<Location> locations;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;
  final DateTime? deletedAt;

  Client({
    required this.id,
    required this.fullName,
    required this.phone,
    this.email,
    this.companyName,
    this.notes,
    this.source,
    this.isRegular = false,
    this.createdByAi = false,
    this.locations = const [],
    this.createdAt,
    this.lastActiveAt,
    this.deletedAt,
  });

  /// Основной адрес (первый в списке)
  Location? get primaryLocation => locations.isNotEmpty ? locations.first : null;

  /// Полный адрес для отображения (из основного объекта)
  String get address => primaryLocation?.fullAddress ?? '';

  bool get isDeleted => deletedAt != null;

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

  /// Placeholder from the phone secretary before the caller said a name.
  /// Одно определение на всё приложение — им же проверяется обращение в SMS.
  static bool isPlaceholderName(String? name) => SmsText.isPlaceholderName(name);

  static String stripClientWord(String? name, [String? fallbackPhone]) =>
      SmsText.stripClientWord(name, fallbackPhone);

  /// Извлекает настоящее имя клиента из любых полей карточки (fullName, name,
  /// clientName, contactName, firstName/lastName, locations.contacts), не
  /// подставляя раньше времени номер телефона вместо имени.
  static String extractName(
    Map<String, dynamic> map, {
    String fallback = 'Без имени',
  }) {
    final phone = (map['phone'] ?? '').toString().trim();
    final firstLast = [
      (map['firstName'] ?? '').toString().trim(),
      (map['lastName'] ?? '').toString().trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    final candidates = <String?>[
      map['fullName']?.toString(),
      map['name']?.toString(),
      map['clientName']?.toString(),
      map['contactName']?.toString(),
      if (firstLast.isNotEmpty) firstLast,
    ];

    final rawLocations = map['locations'];
    if (rawLocations is List) {
      for (final loc in rawLocations) {
        if (loc is! Map) continue;
        final contacts = loc['contacts'];
        if (contacts is! List) continue;
        for (final contact in contacts) {
          if (contact is Map) {
            candidates.add(contact['name']?.toString());
          }
        }
      }
    }

    // 1. Сначала ищем настоящее человеческое имя (не телефон и не «Клиент ...»).
    for (final raw in candidates) {
      final cleaned = SmsText.stripClientWord(raw);
      if (cleaned.isNotEmpty && !isPlaceholderName(cleaned)) {
        return cleaned;
      }
    }

    // 2. Если настоящего имени нет — берём любое непустое значение без слова «Клиент».
    for (final raw in candidates) {
      final cleaned = SmsText.stripClientWord(raw);
      if (cleaned.isNotEmpty) return cleaned;
    }

    if (phone.isNotEmpty) return phone;
    return fallback;
  }

  /// Инициалы для аватара
  String get initials {
    if (fullName.isEmpty || isPlaceholderName(fullName)) return '?';
    final parts = fullName.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return fullName[0].toUpperCase();
  }

  factory Client.fromMap(Map<String, dynamic> map, String docId) {
    final phone = (map['phone'] ?? '').toString();
    final fullName = extractName(map, fallback: '');
    List<Location> locationsList = [];
    final rawLocations = map['locations'];
    if (rawLocations is List) {
      locationsList = [
        for (final item in rawLocations)
          if (item is Map)
            Location.fromMap(Map<String, dynamic>.from(item)),
      ];
    }

    // Миграция: если locations пустой, но есть старое поле address
    if (locationsList.isEmpty && map['address'] != null && map['address'].toString().isNotEmpty) {
      final addressParts = map['address'].toString().split(',');
      locationsList.add(Location(
        id: 'primary',
        street: addressParts.isNotEmpty ? addressParts[0].trim() : '',
        city: addressParts.length > 1 ? addressParts[1].trim() : '',
        postalCode: addressParts.length > 2 ? addressParts[2].trim() : '',
        contacts: [
          Contact(
            id: 'owner',
            name: fullName,
            phone: phone,
            role: 'owner',
            isPrimary: true,
          ),
        ],
      ));
    }

    return Client(
      id: docId,
      fullName: fullName,
      phone: phone,
      email: map['email'],
      companyName: map['companyName'] ?? map['company'],
      notes: map['notes'] ?? map['description'],
      source: map['source'] ?? map['referralSource'],
      isRegular: map['isRegular'] == true,
      createdByAi: map['createdByAi'] == true,
      locations: locationsList,
      createdAt: map['createdAt'] is Timestamp
          ? (map['createdAt'] as Timestamp).toDate()
          : null,
      lastActiveAt: map['lastActiveAt'] is Timestamp
          ? (map['lastActiveAt'] as Timestamp).toDate()
          : null,
      deletedAt: map['deletedAt'] is Timestamp
          ? (map['deletedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toUiMap() {
    return {
      'id': id,
      'fullName': fullName,
      'name': fullName,
      'phone': phone,
      'email': email,
      'companyName': companyName,
      'company': companyName,
      'notes': notes,
      'source': source,
      'isRegular': isRegular,
      'address': address,
      'locations': locations.map((l) => l.toMap()).toList(),
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'fullName': fullName,
      'phone': phone,
      'email': email,
      'companyName': companyName,
      'notes': notes,
      'source': source,
      'isRegular': isRegular,
      'createdByAi': createdByAi,
      'locations': locations.map((l) => l.toMap()).toList(),
      // Для обратной совместимости
      'address': address,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Client copyWith({
    String? id,
    String? fullName,
    String? phone,
    String? email,
    String? companyName,
    String? notes,
    String? source,
    bool? isRegular,
    bool? createdByAi,
    List<Location>? locations,
    DateTime? createdAt,
    DateTime? lastActiveAt,
    DateTime? deletedAt,
  }) {
    return Client(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      companyName: companyName ?? this.companyName,
      notes: notes ?? this.notes,
      source: source ?? this.source,
      isRegular: isRegular ?? this.isRegular,
      createdByAi: createdByAi ?? this.createdByAi,
      locations: locations ?? this.locations,
      createdAt: createdAt ?? this.createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
