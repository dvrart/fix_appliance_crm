import 'package:fix_appliance_crm/core/geo/service_area.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Та же форма зоны, что в functions/voice_facts.test.js:
/// прямоугольник вокруг Брантфорда и Тилсонбурга.
const _zonePolygon = [
  {'lat': 43.3, 'lng': -81.0},
  {'lat': 43.3, 'lng': -79.9},
  {'lat': 42.7, 'lng': -79.9},
  {'lat': 42.7, 'lng': -81.0},
];

void main() {
  group('зона обслуживания', () {
    final area = ServiceArea.fromConfig({
      'servicePolygon': _zonePolygon,
      'serviceRegion': 'Ontario',
      'serviceAreaLabel': 'Ontario: Brantford, Tillsonburg',
    });

    test('город внутри и снаружи зоны', () {
      expect(area.contains(const LatLng(42.8623, -80.728)), isTrue); // Tillsonburg
      expect(area.contains(const LatLng(43.1394, -80.2644)), isTrue); // Brantford
      expect(area.contains(const LatLng(43.6532, -79.3832)), isFalse); // Toronto
      expect(area.contains(const LatLng(42.9849, -81.2453)), isFalse); // London
    });

    test('без полигона ограничений нет', () {
      const empty = ServiceArea.empty;
      expect(empty.hasPolygon, isFalse);
      expect(empty.canRestrictSearch, isFalse);
      expect(empty.contains(const LatLng(43.6532, -79.3832)), isTrue);
    });

    test('круги поиска накрывают зону и влезают в лимит Google', () {
      expect(area.center.latitude, closeTo(43.0, 0.01));
      expect(area.center.longitude, closeTo(-80.45, 0.01));
      expect(area.canRestrictSearch, isTrue);
      expect(area.title, 'Ontario: Brantford, Tillsonburg');

      final circles = area.searchCircles;
      expect(circles, isNotEmpty);
      for (final circle in circles) {
        expect(circle.radiusMeters,
            lessThanOrEqualTo(ServiceArea.maxStrictRadiusMeters));
        expect(area.contains(circle.center), isTrue);
      }
      // Каждый угол зоны попадает хотя бы в один круг поиска.
      for (final corner in area.polygon) {
        expect(
          circles.any(
            (circle) =>
                ServiceArea.distanceMeters(circle.center, corner) <=
                circle.radiusMeters,
          ),
          isTrue,
          reason: 'угол $corner не накрыт',
        );
      }
    });

    test('маленькая зона ищется одним кругом', () {
      final small = ServiceArea.fromConfig({
        'servicePolygon': const [
          {'lat': 43.20, 'lng': -80.35},
          {'lat': 43.20, 'lng': -80.15},
          {'lat': 43.05, 'lng': -80.15},
          {'lat': 43.05, 'lng': -80.35},
        ],
      });
      expect(small.searchCircles, hasLength(1));
      expect(small.searchCircles.first.radiusMeters,
          lessThanOrEqualTo(ServiceArea.maxStrictRadiusMeters));
    });

    test('подпись падает на провинцию, если городов нет', () {
      final noLabel = ServiceArea.fromConfig({
        'servicePolygon': _zonePolygon,
        'serviceRegion': 'Ontario',
      });
      expect(noLabel.title, 'Ontario');
    });
  });
}
