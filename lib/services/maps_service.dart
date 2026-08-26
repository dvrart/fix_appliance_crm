import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../core/constants.dart';
import '../core/l10n/app_locale.dart';

/// Результат построения маршрута через Google Directions API
class OptimizedRoute {
  /// Индексы точек (из исходного списка адресов) в оптимальном порядке
  final List<int> order;

  /// Координаты остановок в оптимальном порядке (для маркеров)
  final List<LatLng> stopLocations;

  /// Точки полилинии всего маршрута (для отрисовки на карте)
  final List<LatLng> polylinePoints;

  /// Расстояние/время до каждой остановки (от предыдущей точки)
  final List<String> legDistances;
  final List<String> legDurations;

  final String totalDistanceText;
  final String totalDurationText;

  OptimizedRoute({
    required this.order,
    required this.stopLocations,
    required this.polylinePoints,
    required this.legDistances,
    required this.legDurations,
    required this.totalDistanceText,
    required this.totalDurationText,
  });
}

class LocationResult {
  final Position? position;
  final String? error;

  const LocationResult({this.position, this.error});
}

/// Сервис для работы с картами и геолокацией
class MapsService {
  /// Получить текущую позицию
  static Future<Position?> getCurrentPosition() async {
    final result = await getCurrentPositionResult();
    return result.position;
  }

  static Future<LocationResult> getCurrentPositionResult() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return LocationResult(
          error: 'Включите геолокацию в настройках телефона'.tr,
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return LocationResult(
          error: 'Нет доступа к геолокации. Разрешите её для приложения.'.tr,
        );
      }
      if (permission == LocationPermission.deniedForever) {
        return LocationResult(
          error: 'Геолокация запрещена. Откройте настройки приложения и включите доступ к месту.'.tr,
        );
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 12),
          ),
        );
        return LocationResult(position: position);
      } on TimeoutException {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LocationResult(position: last);
        return LocationResult(
          error: 'Не удалось получить координаты. Повторите на открытом месте.'.tr,
        );
      }
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LocationResult(position: last);
      } catch (_) {}
      return LocationResult(
        error: 'Не удалось получить координаты. Проверьте GPS.'.tr,
      );
    }
  }

  /// Рассчитать время в пути до адреса
  static Future<String?> getTravelTime(String destinationAddress) async {
    if (destinationAddress.isEmpty || kGoogleApiKey.isEmpty) {
      return null;
    }

    try {
      final position = await getCurrentPosition();
      if (position == null) return null;

      final origin = '${position.latitude},${position.longitude}';

      // Очищаем адрес от почтового индекса для лучшего геокодинга
      String cleanAddress = destinationAddress
          .replaceAll(RegExp(r'[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d'), '')
          .trim();
      if (cleanAddress.isEmpty || cleanAddress.length < 5) {
        cleanAddress = destinationAddress;
      }

      final destination = Uri.encodeComponent(cleanAddress);
      final url =
          'https://maps.googleapis.com/maps/api/distancematrix/json?origins=$origin&destinations=$destination&language=ru&key=$kGoogleApiKey';

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;

      final elements = data['rows']?[0]?['elements'];
      if (elements == null || elements.isEmpty) return null;

      final element = elements[0];
      if (element['status'] != 'OK') return null;

      return element['duration']?['text'];
    } catch (e) {
      return null;
    }
  }

  /// Координаты адреса через Geocoding API.
  static Future<LatLng?> geocodeAddress(String address) async {
    final query = address.trim();
    if (query.length < 5 || kGoogleApiKey.isEmpty) return null;
    try {
      final url =
          'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(query)}&region=ca&key=$kGoogleApiKey';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;
      final loc = results.first['geometry']?['location'];
      if (loc == null) return null;
      return LatLng(
        (loc['lat'] as num).toDouble(),
        (loc['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _component(List<dynamic>? components, List<String> types) {
    if (components == null) return null;
    for (final item in components) {
      if (item is! Map) continue;
      final typeList = item['types'];
      if (typeList is! List) continue;
      final names = typeList.map((value) => value.toString()).toSet();
      if (types.any(names.contains)) {
        final name = (item['long_name'] ?? '').toString().trim();
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }

  static Future<String?> reverseGeocodeLocality(LatLng point) async {
    if (kGoogleApiKey.isEmpty) return null;
    try {
      final url =
          'https://maps.googleapis.com/maps/api/geocode/json?latlng=${point.latitude},${point.longitude}&key=$kGoogleApiKey';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;
      final components = results.first['address_components'] as List?;
      return _component(components, const ['locality', 'postal_town']) ??
          _component(components, const ['sublocality', 'neighborhood']) ??
          _component(components, const ['administrative_area_level_3']);
    } catch (_) {
      return null;
    }
  }

  /// Названия населённых пунктов внутри нарисованного полигона.
  static Future<String> describeServiceArea({
    required String provinceName,
    required List<LatLng> points,
  }) async {
    final province = provinceName.trim();
    if (points.length < 3) return '';
    var lat = 0.0;
    var lng = 0.0;
    for (final point in points) {
      lat += point.latitude;
      lng += point.longitude;
    }
    final samples = <LatLng>[
      LatLng(lat / points.length, lng / points.length),
    ];
    final step = (points.length / 6).ceil().clamp(1, points.length);
    for (var i = 0; i < points.length; i += step) {
      samples.add(points[i]);
    }
    final towns = <String>{};
    for (final sample in samples.take(8)) {
      final name = await reverseGeocodeLocality(sample);
      if (name != null && name.isNotEmpty) towns.add(name);
    }
    if (towns.isEmpty) {
      return province.isEmpty
          ? ''
          : '$province, area marked on the service map';
    }
    final list = towns.join(', ');
    if (province.isEmpty) return list;
    return '$province: $list';
  }

  static List<LatLng> polygonFromConfig(dynamic raw) {
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

  static Future<String> describeServiceAreaFromConfig(
    Map<String, dynamic> config,
  ) {
    return describeServiceArea(
      provinceName: (config['serviceRegion'] ?? '').toString(),
      points: polygonFromConfig(config['servicePolygon']),
    );
  }

  /// Открыть навигатор (Google Maps)
  static Future<void> openNavigator(String address) async {
    final encodedAddress = Uri.encodeComponent(address);
    final url = 'https://www.google.com/maps/dir/?api=1&destination=$encodedAddress';

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Открыть построенный маршрут (несколько точек) во внешнем приложении Google Maps
  static Future<void> openRouteInMaps(List<String> orderedAddresses) async {
    if (orderedAddresses.isEmpty) return;

    final destination = Uri.encodeComponent(orderedAddresses.last);
    var url =
        'https://www.google.com/maps/dir/?api=1&destination=$destination&travelmode=driving';

    if (orderedAddresses.length > 1) {
      final waypoints = orderedAddresses
          .sublist(0, orderedAddresses.length - 1)
          .map(Uri.encodeComponent)
          .join('|');
      url += '&waypoints=$waypoints';
    }

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Позвонить
  static Future<void> makeCall(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Открыть SMS
  static Future<void> openSms(String phone, [String? body]) async {
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: body != null ? {'body': body} : null,
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Google Places Autocomplete
  static Future<List<Map<String, dynamic>>> searchPlaces(String query) async {
    if (query.length < 3 || kGoogleApiKey.isEmpty) return [];

    try {
      final url =
          'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${Uri.encodeComponent(query)}&key=$kGoogleApiKey&language=ru&components=country:ca';

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return [];

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return [];

      return List<Map<String, dynamic>>.from(data['predictions']);
    } catch (e) {
      return [];
    }
  }

  /// Получить детали места по placeId
  static Future<Map<String, String>?> getPlaceDetails(String placeId) async {
    if (kGoogleApiKey.isEmpty) return null;

    try {
      final url =
          'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$kGoogleApiKey&language=ru&fields=address_components,formatted_address';

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;

      final components = data['result']['address_components'] as List;
      String street = '';
      String city = '';
      String postal = '';
      String streetNumber = '';

      for (final comp in components) {
        final types = List<String>.from(comp['types']);
        if (types.contains('street_number')) {
          streetNumber = comp['long_name'];
        } else if (types.contains('route')) {
          street = comp['long_name'];
        } else if (types.contains('locality')) {
          city = comp['long_name'];
        } else if (types.contains('postal_code')) {
          postal = comp['long_name'];
        }
      }

      if (streetNumber.isNotEmpty) {
        street = '$streetNumber $street';
      }

      return {
        'street': street.trim(),
        'city': city,
        'postal': postal,
      };
    } catch (e) {
      return null;
    }
  }

  /// Получить статическую карту (URL изображения)
  static String getStaticMapUrl(String address, {int width = 400, int height = 200}) {
    final encodedAddress = Uri.encodeComponent(address);
    return 'https://maps.googleapis.com/maps/api/staticmap?center=$encodedAddress&zoom=15&size=${width}x$height&markers=color:red%7C$encodedAddress&key=$kGoogleApiKey';
  }

  /// Построить маршрут по нескольким адресам через Google Directions API.
  ///
  /// Если [optimize] = true (по умолчанию), Google сам подбирает лучший
  /// порядок посещения точек (аналог решения задачи коммивояжёра).
  /// Если false — порядок точек берётся как есть (после ручной сортировки).
  /// Причина последней неудачи [getOptimizedRoute] (для диагностики в UI)
  static String? lastRouteError;

  static Future<OptimizedRoute?> getOptimizedRoute({
    required LatLng origin,
    required List<String> addresses,
    bool optimize = true,
  }) async {
    lastRouteError = null;

    if (addresses.isEmpty) {
      lastRouteError = 'Список адресов пуст'.tr;
      return null;
    }
    if (kGoogleApiKey.isEmpty) {
      lastRouteError = 'Не задан Google API ключ'.tr;
      return null;
    }

    try {
      final originStr = '${origin.latitude},${origin.longitude}';
      final waypointsParam = addresses.map(Uri.encodeComponent).join('|');
      final optimizePrefix = optimize ? 'optimize:true|' : '';

      final url = 'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=$originStr'
          '&destination=$originStr'
          '&waypoints=$optimizePrefix$waypointsParam'
          '&language=ru&key=$kGoogleApiKey';

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        lastRouteError = 'HTTP ${response.statusCode}';
        return null;
      }

      final data = json.decode(response.body);
      if (data['status'] != 'OK') {
        final errorMessage = data['error_message'];
        lastRouteError = errorMessage != null
            ? '${data['status']}: $errorMessage'
            : '${data['status']}';
        return null;
      }

      final routes = data['routes'] as List;
      if (routes.isEmpty) {
        lastRouteError = 'Google не вернул ни одного маршрута'.tr;
        return null;
      }
      final route = routes[0];
      final legs = route['legs'] as List;

      final waypointOrder = optimize
          ? List<int>.from(
              route['waypoint_order'] ?? List.generate(addresses.length, (i) => i))
          : List.generate(addresses.length, (i) => i);

      final stopLocations = <LatLng>[];
      final legDistances = <String>[];
      final legDurations = <String>[];
      int totalSeconds = 0;
      double totalMeters = 0;

      for (var i = 0; i < addresses.length && i < legs.length; i++) {
        final leg = legs[i];
        final endLoc = leg['end_location'];
        stopLocations.add(LatLng(
          (endLoc['lat'] as num).toDouble(),
          (endLoc['lng'] as num).toDouble(),
        ));
        legDistances.add(leg['distance']?['text'] ?? '');
        legDurations.add(leg['duration']?['text'] ?? '');
        totalSeconds += (leg['duration']?['value'] ?? 0) as int;
        totalMeters += ((leg['distance']?['value'] ?? 0) as num).toDouble();
      }

      // Последний "leg" — возврат от последней точки к началу маршрута
      if (legs.length > addresses.length) {
        final lastLeg = legs[addresses.length];
        totalSeconds += (lastLeg['duration']?['value'] ?? 0) as int;
        totalMeters += ((lastLeg['distance']?['value'] ?? 0) as num).toDouble();
      }

      final overviewPolyline = route['overview_polyline']?['points'];
      final polylinePoints =
          overviewPolyline != null ? _decodePolyline(overviewPolyline) : <LatLng>[];

      return OptimizedRoute(
        order: waypointOrder,
        stopLocations: stopLocations,
        polylinePoints: polylinePoints,
        legDistances: legDistances,
        legDurations: legDurations,
        totalDistanceText: '${(totalMeters / 1000).toStringAsFixed(1)} ${'км'.tr}',
        totalDurationText: _formatDuration(totalSeconds),
      );
    } catch (e) {
      lastRouteError = e.toString();
      return null;
    }
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h ${'ч'.tr} $m ${'мин'.tr}';
    return '$m ${'мин'.tr}';
  }

  /// Декодирование encoded polyline (алгоритм Google)
  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0;
    final len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }
}
