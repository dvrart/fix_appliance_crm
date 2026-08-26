import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';
import 'maps_service.dart';

class GeoTimeInfo {
  final String timeZoneId;
  final String timeZoneName;
  final int offsetSeconds;
  final DateTime localNow;

  const GeoTimeInfo({
    required this.timeZoneId,
    required this.timeZoneName,
    required this.offsetSeconds,
    required this.localNow,
  });
}

class GeoTimeDetectResult {
  final GeoTimeInfo? info;
  final String? error;

  const GeoTimeDetectResult({this.info, this.error});
}

/// Текущее время приложения: с телефона или по геолокации.
class AppTimeService {
  static const String sourceManual = 'manual';
  static const String sourceGeolocation = 'geolocation';
  static const String defaultLocation = 'America/Toronto';

  static String timeSource = sourceManual;
  static String? timeZoneId;
  static String? timeZoneName;
  static int? offsetSeconds;
  static bool _tzReady = false;

  static bool get usesGeolocation => timeSource == sourceGeolocation;

  static void applyConfig(Map<String, dynamic> config) {
    timeSource = config['timeSource'] == sourceGeolocation
        ? sourceGeolocation
        : sourceManual;
    timeZoneId = config['timeZoneId'] as String?;
    timeZoneName = config['timeZoneName'] as String?;
    final offset = config['timeOffsetSeconds'];
    if (offset is int) {
      offsetSeconds = offset;
    } else if (offset is num) {
      offsetSeconds = offset.toInt();
    } else {
      offsetSeconds = null;
    }
    if (_tzReady) _applyLocation();
  }

  static Future<void> ensureInitialized() async {
    _ensureTz();
  }

  static void _ensureTz() {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    _tzReady = true;
    _applyLocation();
  }

  static tz.Location _location() {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    final id = timeZoneId?.trim();
    if (id != null && id.contains('/')) {
      try {
        return tz.getLocation(id);
      } catch (_) {}
    }
    return tz.getLocation(defaultLocation);
  }

  static void _applyLocation() {
    try {
      tz.setLocalLocation(_location());
    } catch (_) {
      tz.setLocalLocation(tz.getLocation(defaultLocation));
    }
  }

  /// Стена часов в поясе компании (Торонто), не телефона.
  static DateTime wallClock(DateTime value) {
    final zoned = tz.TZDateTime.from(value, _location());
    return DateTime(
      zoned.year,
      zoned.month,
      zoned.day,
      zoned.hour,
      zoned.minute,
      zoned.second,
    );
  }

  static String format(
    DateTime value,
    String pattern, {
    String? locale,
  }) {
    return DateFormat(pattern, locale).format(wallClock(value));
  }

  static DateTime now() {
    if (usesGeolocation && offsetSeconds != null) {
      return DateTime.now().toUtc().add(Duration(seconds: offsetSeconds!));
    }
    return DateTime.now();
  }

  static tz.TZDateTime nowInZone() {
    _ensureTz();
    return tz.TZDateTime.now(_location());
  }

  static DateTime atWall(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
  ]) {
    _ensureTz();
    return tz.TZDateTime(_location(), year, month, day, hour, minute);
  }

  static GeoTimeInfo _fromDeviceClock() {
    final now = DateTime.now();
    return GeoTimeInfo(
      timeZoneId: now.timeZoneName,
      timeZoneName: 'Местное время по GPS',
      offsetSeconds: now.timeZoneOffset.inSeconds,
      localNow: now,
    );
  }

  static void _remember(GeoTimeInfo info) {
    timeZoneId = info.timeZoneId;
    timeZoneName = info.timeZoneName;
    offsetSeconds = info.offsetSeconds;
  }

  static Future<GeoTimeDetectResult> detectFromLocation() async {
    final location = await MapsService.getCurrentPositionResult();
    if (location.position == null) {
      return GeoTimeDetectResult(
        error: location.error ?? 'Не удалось определить геолокацию',
      );
    }

    final position = location.position!;
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.https('maps.googleapis.com', '/maps/api/timezone/json', {
      'location': '${position.latitude},${position.longitude}',
      'timestamp': '$timestamp',
      'language': 'ru',
      'key': kGoogleApiKey,
    });

    try {
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['status'] == 'OK') {
          final rawOffset = (data['rawOffset'] as num?)?.toInt() ?? 0;
          final dstOffset = (data['dstOffset'] as num?)?.toInt() ?? 0;
          final offset = rawOffset + dstOffset;
          final info = GeoTimeInfo(
            timeZoneId: (data['timeZoneId'] as String?) ?? '',
            timeZoneName: (data['timeZoneName'] as String?) ?? 'По GPS',
            offsetSeconds: offset,
            localNow: DateTime.now().toUtc().add(Duration(seconds: offset)),
          );
          _remember(info);
          return GeoTimeDetectResult(info: info);
        }
      }
    } catch (_) {
      // дальше запасной вариант по часам телефона
    }

    final fallback = _fromDeviceClock();
    _remember(fallback);
    return GeoTimeDetectResult(info: fallback);
  }
}
