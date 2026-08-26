import 'package:cloud_firestore/cloud_firestore.dart';
import 'contact.dart';

/// Объект (адрес) клиента — дом, квартира, офис
class Location {
  final String id;
  final String street;
  final String city;
  final String postalCode;
  final String? unit; // квартира, офис
  final String? notes;
  final List<Contact> contacts;
  final DateTime? createdAt;
  final double? lat;
  final double? lng;
  final String? geoAddress;

  Location({
    required this.id,
    required this.street,
    required this.city,
    required this.postalCode,
    this.unit,
    this.notes,
    this.contacts = const [],
    this.createdAt,
    this.lat,
    this.lng,
    this.geoAddress,
  });

  bool get hasCoords => lat != null && lng != null;

  String get fullAddress {
    final parts = <String>[];
    if (unit != null && unit!.isNotEmpty) parts.add(unit!);
    if (street.isNotEmpty) parts.add(street);
    if (city.isNotEmpty) parts.add(city);
    if (postalCode.isNotEmpty) parts.add(postalCode);
    return parts.join(', ');
  }

  String get shortAddress {
    if (street.isNotEmpty && city.isNotEmpty) {
      return '$street, $city';
    }
    return fullAddress;
  }

  Contact? get primaryContact {
    try {
      return contacts.firstWhere((c) => c.isPrimary);
    } catch (_) {
      return contacts.isNotEmpty ? contacts.first : null;
    }
  }

  factory Location.fromMap(Map<String, dynamic> map, [String? docId]) {
    List<Contact> contactsList = [];
    final rawContacts = map['contacts'];
    if (rawContacts is List) {
      contactsList = [
        for (final item in rawContacts)
          if (item is Map)
            Contact.fromMap(Map<String, dynamic>.from(item)),
      ];
    }

    DateTime? createdAt;
    final rawCreated = map['createdAt'];
    if (rawCreated is Timestamp) {
      createdAt = rawCreated.toDate();
    } else if (rawCreated is DateTime) {
      createdAt = rawCreated;
    }

    return Location(
      id: docId ?? map['id']?.toString() ?? '',
      street: map['street']?.toString() ?? '',
      city: map['city']?.toString() ?? '',
      postalCode: map['postalCode']?.toString() ?? map['postal']?.toString() ?? '',
      unit: map['unit']?.toString(),
      notes: map['notes']?.toString(),
      contacts: contactsList,
      createdAt: createdAt,
      lat: (map['lat'] as num?)?.toDouble(),
      lng: (map['lng'] as num?)?.toDouble(),
      geoAddress: map['geoAddress']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'street': street,
      'city': city,
      'postalCode': postalCode,
      'unit': unit,
      'notes': notes,
      'contacts': contacts.map((c) => c.toMap()).toList(),
      // FieldValue.serverTimestamp() внутри массивов (поле "locations"
      // клиента) не поддерживается Firestore — используем обычный Timestamp.
      'createdAt': Timestamp.fromDate(createdAt ?? DateTime.now()),
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (geoAddress != null && geoAddress!.isNotEmpty) 'geoAddress': geoAddress,
    };
  }

  Location copyWith({
    String? id,
    String? street,
    String? city,
    String? postalCode,
    String? unit,
    String? notes,
    List<Contact>? contacts,
    DateTime? createdAt,
    double? lat,
    double? lng,
    String? geoAddress,
  }) {
    return Location(
      id: id ?? this.id,
      street: street ?? this.street,
      city: city ?? this.city,
      postalCode: postalCode ?? this.postalCode,
      unit: unit ?? this.unit,
      notes: notes ?? this.notes,
      contacts: contacts ?? this.contacts,
      createdAt: createdAt ?? this.createdAt,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      geoAddress: geoAddress ?? this.geoAddress,
    );
  }
}
