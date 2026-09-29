import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Круг для поиска Google: центр и радиус в метрах.
class AreaSearchCircle {
  const AreaSearchCircle(this.center, this.radiusMeters);

  final LatLng center;
  final double radiusMeters;
}

/// Зона обслуживания из «Настройки → Зона»: полигон с карты, провинция и подпись.
///
/// Тем же полигоном сервер ограничивает секретаря (`functions/service_area.js`),
/// поэтому ручной поиск адреса в приложении должен смотреть в ту же зону.
class ServiceArea {
  const ServiceArea({
    this.polygon = const [],
    this.region = '',
    this.label = '',
  });

  final List<LatLng> polygon;
  final String region;
  final String label;

  static const ServiceArea empty = ServiceArea();

  /// Google Places не принимает strictbounds больше 50 км.
  static const double maxStrictRadiusMeters = 50000;

  factory ServiceArea.fromConfig(Map<String, dynamic> config) {
    return ServiceArea(
      polygon: pointsFrom(config['servicePolygon']),
      region: (config['serviceRegion'] ?? '').toString().trim(),
      label: (config['serviceAreaLabel'] ?? '').toString().trim(),
    );
  }

  static List<LatLng> pointsFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final map = Map<String, dynamic>.from(item);
          return LatLng(
            (map['lat'] as num?)?.toDouble() ?? 0,
            (map['lng'] as num?)?.toDouble() ?? 0,
          );
        })
        .where((point) => point.latitude != 0 || point.longitude != 0)
        .toList();
  }

  bool get hasPolygon => polygon.length >= 3;

  /// Подпись для шапки: города с карты, иначе хотя бы провинция.
  String get title => label.isNotEmpty ? label : region;

  /// Середина описанного прямоугольника — центр круга для поиска Google.
  LatLng get center {
    if (polygon.isEmpty) return const LatLng(0, 0);
    var minLat = polygon.first.latitude;
    var maxLat = minLat;
    var minLng = polygon.first.longitude;
    var maxLng = minLng;
    for (final point in polygon) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }
    return LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
  }

  /// Радиус круга, который накрывает всю зону (с небольшим запасом).
  double get radiusMeters {
    if (!hasPolygon) return 0;
    final middle = center;
    var radius = 0.0;
    for (final point in polygon) {
      radius = math.max(radius, distanceMeters(middle, point));
    }
    return radius * 1.05;
  }

  /// Зону можно жёстко ограничить кругами поиска.
  bool get canRestrictSearch => hasPolygon;

  /// Круги, которые вместе накрывают зону. Один запрос Google — один круг,
  /// потому что strictbounds принимает не больше 50 км.
  List<AreaSearchCircle> get searchCircles {
    if (!hasPolygon) return const [];
    if (radiusMeters <= maxStrictRadiusMeters) {
      return [AreaSearchCircle(center, radiusMeters)];
    }
    var minLat = polygon.first.latitude;
    var maxLat = minLat;
    var minLng = polygon.first.longitude;
    var maxLng = minLng;
    for (final point in polygon) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }
    final middle = center;
    final height = distanceMeters(
      LatLng(minLat, middle.longitude),
      LatLng(maxLat, middle.longitude),
    );
    final width = distanceMeters(
      LatLng(middle.latitude, minLng),
      LatLng(middle.latitude, maxLng),
    );
    // Режем зону на клетки, пока половина диагонали клетки не влезет в лимит.
    var rows = 1;
    var cols = 1;
    double cellRadius() =>
        _hypot(width / cols, height / rows) / 2 * 1.05;
    while (cellRadius() > maxStrictRadiusMeters && rows * cols < 64) {
      if (width / cols >= height / rows) {
        cols++;
      } else {
        rows++;
      }
    }
    final radius = math.min(cellRadius(), maxStrictRadiusMeters);
    final latStep = (maxLat - minLat) / rows;
    final lngStep = (maxLng - minLng) / cols;
    final circles = <AreaSearchCircle>[];
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        circles.add(
          AreaSearchCircle(
            LatLng(
              minLat + latStep * (row + 0.5),
              minLng + lngStep * (col + 0.5),
            ),
            radius,
          ),
        );
      }
    }
    return circles;
  }

  /// Точка внутри зоны. Если зона не нарисована — ограничений нет.
  bool contains(LatLng point) {
    if (!hasPolygon) return true;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crosses = (a.latitude > point.latitude) !=
          (b.latitude > point.latitude);
      if (!crosses) continue;
      final x = (b.longitude - a.longitude) *
              (point.latitude - a.latitude) /
              (b.latitude - a.latitude) +
          a.longitude;
      if (point.longitude < x) inside = !inside;
    }
    return inside;
  }

  static double distanceMeters(LatLng from, LatLng to) {
    const earthRadius = 6371000.0;
    final dLat = _rad(to.latitude - from.latitude);
    final dLng = _rad(to.longitude - from.longitude);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(from.latitude)) *
            math.cos(_rad(to.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadius * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _hypot(double a, double b) => math.sqrt(a * a + b * b);

  static double _rad(double degrees) => degrees * math.pi / 180;
}
