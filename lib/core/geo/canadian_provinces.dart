import 'package:google_maps_flutter/google_maps_flutter.dart';

class CanadianProvince {
  final String name;
  final String code;
  final LatLng center;
  final double zoom;

  const CanadianProvince({
    required this.name,
    required this.code,
    required this.center,
    required this.zoom,
  });

  static const List<CanadianProvince> all = [
    CanadianProvince(
      name: 'Ontario',
      code: 'ON',
      center: LatLng(44.5, -79.4),
      zoom: 6.2,
    ),
    CanadianProvince(
      name: 'Quebec',
      code: 'QC',
      center: LatLng(46.8, -71.2),
      zoom: 5.8,
    ),
    CanadianProvince(
      name: 'British Columbia',
      code: 'BC',
      center: LatLng(53.7, -127.6),
      zoom: 5.4,
    ),
    CanadianProvince(
      name: 'Alberta',
      code: 'AB',
      center: LatLng(53.9, -116.6),
      zoom: 5.8,
    ),
    CanadianProvince(
      name: 'Manitoba',
      code: 'MB',
      center: LatLng(53.8, -98.8),
      zoom: 5.8,
    ),
    CanadianProvince(
      name: 'Saskatchewan',
      code: 'SK',
      center: LatLng(52.9, -106.5),
      zoom: 5.8,
    ),
    CanadianProvince(
      name: 'Nova Scotia',
      code: 'NS',
      center: LatLng(44.7, -63.7),
      zoom: 7.0,
    ),
    CanadianProvince(
      name: 'New Brunswick',
      code: 'NB',
      center: LatLng(46.5, -66.5),
      zoom: 7.0,
    ),
    CanadianProvince(
      name: 'Newfoundland and Labrador',
      code: 'NL',
      center: LatLng(53.1, -57.7),
      zoom: 5.4,
    ),
    CanadianProvince(
      name: 'Prince Edward Island',
      code: 'PE',
      center: LatLng(46.25, -63.13),
      zoom: 8.0,
    ),
    CanadianProvince(
      name: 'Northwest Territories',
      code: 'NT',
      center: LatLng(64.8, -124.8),
      zoom: 4.4,
    ),
    CanadianProvince(
      name: 'Nunavut',
      code: 'NU',
      center: LatLng(70.3, -83.1),
      zoom: 3.8,
    ),
    CanadianProvince(
      name: 'Yukon',
      code: 'YT',
      center: LatLng(64.3, -135.0),
      zoom: 5.0,
    ),
  ];

  static CanadianProvince byName(String? name) {
    final needle = (name ?? '').trim().toLowerCase();
    return all.firstWhere(
      (item) =>
          item.name.toLowerCase() == needle ||
          item.code.toLowerCase() == needle,
      orElse: () => all.first,
    );
  }
}
