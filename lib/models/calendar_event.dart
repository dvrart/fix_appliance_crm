import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Приоритет мероприятия: красный срочно, жёлтый средне, синий не срочно.
enum CalendarEventPriority {
  high,
  medium,
  low;

  static const defaultValue = CalendarEventPriority.medium;

  static CalendarEventPriority fromRaw(dynamic raw) {
    switch ((raw ?? '').toString().trim().toLowerCase()) {
      case 'high':
      case 'red':
      case 'urgent':
      case 'срочно':
        return CalendarEventPriority.high;
      case 'low':
      case 'blue':
      case 'normal':
      case 'не срочно':
        return CalendarEventPriority.low;
      case 'medium':
      case 'yellow':
      case 'amber':
      default:
        return CalendarEventPriority.medium;
    }
  }

  String get raw => name;

  Color get color => switch (this) {
        CalendarEventPriority.high => const Color(0xFFE53935),
        CalendarEventPriority.medium => const Color(0xFFF9A825),
        CalendarEventPriority.low => const Color(0xFF1E88E5),
      };

  String get labelRu => switch (this) {
        CalendarEventPriority.high => 'Срочно',
        CalendarEventPriority.medium => 'Не сильно срочно',
        CalendarEventPriority.low => 'Вообще не срочно',
      };
}

class CalendarEvent {
  static const appointmentPrefix = 'calEvent|';

  final String id;
  final String title;
  final DateTime startAt;
  final int durationMinutes;
  final String photoUrl;
  final CalendarEventPriority priority;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.startAt,
    this.durationMinutes = 60,
    this.photoUrl = '',
    this.priority = CalendarEventPriority.defaultValue,
  });

  DateTime get endAt =>
      startAt.add(Duration(minutes: durationMinutes.clamp(15, 12 * 60)));

  static bool isAppointmentId(Object? id) =>
      id.toString().startsWith(appointmentPrefix);

  static String appointmentIdOf(String id) => '$appointmentPrefix$id';

  static String idFromAppointment(Object? id) {
    final raw = id.toString();
    return raw.startsWith(appointmentPrefix)
        ? raw.substring(appointmentPrefix.length)
        : raw;
  }

  factory CalendarEvent.fromMap(Map<String, dynamic> map, String id) {
    return CalendarEvent(
      id: id,
      title: (map['title'] ?? '').toString().trim(),
      startAt: _readDate(map['startAt']) ?? DateTime.now(),
      durationMinutes: (map['durationMinutes'] as num?)?.toInt() ?? 60,
      photoUrl: (map['photoUrl'] ?? '').toString().trim(),
      priority: CalendarEventPriority.fromRaw(map['priority']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'startAt': Timestamp.fromDate(startAt),
      'durationMinutes': durationMinutes.clamp(15, 12 * 60),
      'photoUrl': photoUrl,
      'priority': priority.raw,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  CalendarEvent copyWith({
    String? id,
    String? title,
    DateTime? startAt,
    int? durationMinutes,
    String? photoUrl,
    CalendarEventPriority? priority,
  }) {
    return CalendarEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      startAt: startAt ?? this.startAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      photoUrl: photoUrl ?? this.photoUrl,
      priority: priority ?? this.priority,
    );
  }

  static DateTime? _readDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }
}
