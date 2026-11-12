import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../core/constants.dart';
import '../core/geo/service_area.dart';
import '../core/l10n/app_locale.dart';
import 'firestore_service.dart';
import 'network_status_service.dart';

/// Точка для навигации: что показать в поле «куда» и чем это подтвердить.
///
/// `placeId` важнее текста: Google Maps по нему открывает ровно то здание,
/// даже если в адресе не хватает города.
class MapPlace {
  const MapPlace({
    required this.address,
    this.placeId,
    this.location,
    this.isHouse = false,
    this.insideServiceArea,
  });

  final String address;
  final String? placeId;
  final LatLng? location;

  /// Точный дом найден геокодером (а не просто город, индекс или улица).
  final bool isHouse;

  /// Входит ли найденная точка в зону обслуживания (`null`, если полигон не
  /// задан или координаты не получены).
  final bool? insideServiceArea;

  MapPlace withAreaCheck(ServiceArea area) {
    if (location == null || !area.hasPolygon) return this;
    final inside = area.contains(location!);
    if (inside == insideServiceArea) return this;
    return MapPlace(
      address: address,
      placeId: placeId,
      location: location,
      isHouse: isHouse,
      insideServiceArea: inside,
    );
  }
}

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

      // Адрес разбираем тем же геокодером, что и кнопка «Проложить маршрут»:
      // иначе на карточке висит время до одного места, а навигатор везёт в
      // другое. Почтовый индекс не выбрасываем — он и есть самая точная часть.
      final place = await resolvePlace(destinationAddress);
      if (place == null) return null;
      final point = place.location;
      final destination = point != null
          ? '${point.latitude},${point.longitude}'
          : place.address;

      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/distancematrix/json',
        {
          'origins': origin,
          'destinations': destination,
          'region': 'ca',
          'language': AppLocale.instance.isEn ? 'en' : 'ru',
          'key': kGoogleApiKey,
        },
      );

      final response = await getWithTimeout(uri);
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

  /// Координаты адреса через Geocoding API — с привязкой к зоне обслуживания.
  static Future<LatLng?> geocodeAddress(String address) async {
    final place = await resolvePlace(address);
    return place?.location;
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
      final response = await getWithTimeout(Uri.parse(url));
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
    final names = await Future.wait(
      samples.take(8).map(reverseGeocodeLocality),
    );
    for (final name in names) {
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

  static List<LatLng> polygonFromConfig(dynamic raw) =>
      ServiceArea.pointsFrom(raw);

  static Future<String> describeServiceAreaFromConfig(
    Map<String, dynamic> config,
  ) {
    return describeServiceArea(
      provinceName: (config['serviceRegion'] ?? '').toString(),
      points: polygonFromConfig(config['servicePolygon']),
    );
  }

  /// Подписи, которые лежат в поле адреса вместо адреса.
  static final RegExp _placeholderAddress = RegExp(
    r'^(не\s*указан[а-яё]*|нет\s*адреса|адрес\s*не\s*указан[а-яё]*|неизвестн[а-яё]*|'
    r'not\s*specified|no\s*address|unknown|n/?a|[-—.?]+)$',
    caseSensitive: false,
  );

  /// Квартира, офис, подъезд. Геокодер Google на них спотыкается и отдаёт
  /// либо ZERO_RESULTS, либо соседнее здание, поэтому в запрос их не кладём.
  static final RegExp _unitPart = RegExp(
    r'^(unit|apt|apartment|suite|ste|bsmt|basement|кв|кварт\w*|оф|офис)'
    r'\s*[:.#-]?\s*[\w-]*$|^#\s*[\w-]+$',
    caseSensitive: false,
  );

  /// Провинция или штат отдельным куском адреса («ON», «Ontario»).
  static final RegExp _provincePart = RegExp(
    r'^(ab|bc|mb|nb|nl|ns|nt|nu|on|pe|qc|sk|yt)$',
    caseSensitive: false,
  );

  /// Google Maps берёт не больше девяти промежуточных точек.
  static const int maxMapsWaypoints = 9;

  /// Адрес в том виде, в каком его поймёт Google: без заглушек и квартир,
  /// с провинцией и страной, если их не вписали.
  ///
  /// Пустой ответ означает «ехать некуда» — ссылку строить нельзя, иначе
  /// Google Maps откроется с пустой формой поиска.
  static String navigationQuery(String address, {String region = ''}) {
    final text = address.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty || _placeholderAddress.hasMatch(text)) return '';
    final parts = text
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && !_unitPart.hasMatch(part))
        .toList();
    if (parts.isEmpty) return '';
    // Одно слово без цифр («Toronto») — не адрес дома, но ехать по нему можно;
    // отсекаем только мусор вроде «???».
    if (!RegExp(r'[0-9a-zA-Zа-яА-Я]').hasMatch(parts.join())) return '';

    final lower = parts.map((part) => part.toLowerCase()).toList();
    final province = region.trim();
    final hasProvince =
        lower.any(_provincePart.hasMatch) ||
        (province.isNotEmpty &&
            lower.any((part) => part.contains(province.toLowerCase())));
    if (!hasProvince && province.isNotEmpty) parts.add(province);
    if (!lower.contains('canada')) parts.add('Canada');
    return parts.join(', ');
  }

  /// Есть ли куда ехать: адрес не пустой и не подпись-заглушка.
  static bool hasRoutableAddress(String address) =>
      navigationQuery(address).isNotEmpty;

  static final RegExp _canadianPostal = RegExp(
    r'\b[A-Za-z]\d[A-Za-z]\s*\d[A-Za-z]\d\b',
  );

  /// Номера домов из строки адреса (без почтового индекса и квартиры).
  static Set<String> houseNumbersInAddress(String address) {
    final cleaned = address.replaceAll(_canadianPostal, ' ');
    final numbers = <String>{};
    for (final rawPart in cleaned.split(',')) {
      var part = rawPart.trim();
      if (part.isEmpty || _unitPart.hasMatch(part)) continue;
      part = part.replaceFirst(
        RegExp(
          r'^(?:unit|apt|apartment|suite|ste|bsmt|basement|кв|кварт\w*|оф|офис|#)\s*[:.#-]?\s*[\w-]+\s+',
          caseSensitive: false,
        ),
        '',
      );
      if (!RegExp(r'[a-zA-Zа-яА-Я]').hasMatch(part)) continue;
      for (final m in RegExp(r'\b(\d+)[a-zA-Z]?\b').allMatches(part)) {
        final digits = m.group(1);
        if (digits != null && digits.isNotEmpty) numbers.add(digits);
      }
    }
    return numbers;
  }

  /// Вписан ли в адрес номер дома с улицей (а не только город или индекс).
  static bool hasHouseNumber(String address) =>
      houseNumbersInAddress(address).isNotEmpty;

  /// Разбор ответа Google Geocoding с проверкой, найден ли именно этот дом.
  static MapPlace parseGeocodeResult(
    Map<String, dynamic> first, {
    required String queryAddress,
    ServiceArea? area,
  }) {
    final loc = first['geometry']?['location'];
    final location = loc is Map
        ? LatLng(
            (loc['lat'] as num).toDouble(),
            (loc['lng'] as num).toDouble(),
          )
        : null;
    final placeIdRaw = (first['place_id'] ?? '').toString().trim();
    final components = first['address_components'] as List?;
    final streetNumber = _component(components, const ['street_number']) ?? '';
    final route = _component(components, const ['route']) ?? '';
    final premise =
        _component(components, const ['premise', 'subpremise']) ?? '';
    final resultTypes = (first['types'] is List)
        ? (first['types'] as List).map((e) => e.toString()).toSet()
        : const <String>{};
    final locationType =
        (first['geometry']?['location_type'] ?? '').toString().trim();
    final partialMatch = first['partial_match'] == true;

    final queryNumbers = houseNumbersInAddress(queryAddress);
    final geocodeDigits = RegExp(r'\d+')
        .allMatches('$streetNumber $premise')
        .map((m) => m.group(0)!)
        .toSet();
    final numberMatched =
        queryNumbers.isNotEmpty &&
        geocodeDigits.isNotEmpty &&
        queryNumbers.any(geocodeDigits.contains);
    final hasStreetBuilding =
        (streetNumber.isNotEmpty && route.isNotEmpty) ||
        resultTypes.contains('street_address') ||
        resultTypes.contains('premise') ||
        resultTypes.contains('subpremise');
    final preciseEnough =
        locationType == 'ROOFTOP' ||
        locationType == 'RANGE_INTERPOLATED' ||
        (!partialMatch &&
            (resultTypes.contains('street_address') ||
                resultTypes.contains('premise') ||
                resultTypes.contains('subpremise')));

    final isHouse =
        location != null &&
        numberMatched &&
        hasStreetBuilding &&
        preciseEnough;

    final insideArea = (location != null && area != null && area.hasPolygon)
        ? area.contains(location)
        : null;

    return MapPlace(
      address: (first['formatted_address'] ?? queryAddress).toString(),
      placeId: placeIdRaw.isEmpty ? null : placeIdRaw,
      location: location,
      isHouse: isHouse,
      insideServiceArea: insideArea,
    );
  }

  static ServiceArea? _area;
  static DateTime? _areaAt;
  static const Duration _areaTtl = Duration(minutes: 10);

  /// Зона обслуживания из настроек — ею же ограничен поиск адреса и секретарь.
  static Future<ServiceArea> serviceAreaBias() async {
    final cached = _area;
    final at = _areaAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _areaTtl) {
      return cached;
    }
    _areaAt = DateTime.now();
    try {
      final doc = await FirestoreService.configRef.get();
      final data = doc.data() as Map<String, dynamic>?;
      _area = data == null ? ServiceArea.empty : ServiceArea.fromConfig(data);
    } catch (_) {
      _area = ServiceArea.empty;
    }
    return _area!;
  }

  static final Map<String, MapPlace> _placeCache = {};

  /// Адрес → точка на карте. Геокодер зовётся с привязкой к зоне обслуживания
  /// и к Канаде, поэтому «Main St» не уезжает в другую провинцию.
  static Future<MapPlace?> resolvePlace(String address) async {
    final area = await serviceAreaBias();
    final query = navigationQuery(address, region: area.region);
    if (query.isEmpty) return null;
    if (kGoogleApiKey.isEmpty) return MapPlace(address: query);
    final cached = _placeCache[query];
    if (cached != null) return cached.withAreaCheck(area);

    final bounds = area.boundingBox;
    final base = {
      'address': query,
      'region': 'ca',
      'key': kGoogleApiKey,
      if (bounds != null)
        'bounds':
            '${bounds.southwest.latitude},${bounds.southwest.longitude}'
            '|${bounds.northeast.latitude},${bounds.northeast.longitude}',
    };

    // Сначала строго по Канаде, потом без фильтра — редкий адрес лучше найти
    // хоть как-то, чем не найти совсем.
    for (final params in [
      {...base, 'components': 'country:CA'},
      base,
    ]) {
      final place = await _geocodeOnce(params, area: area);
      if (place != null) {
        _placeCache[query] = place;
        return place;
      }
    }
    // Геокодер молчит (нет сети, редкий адрес) — не запоминаем неудачу,
    // пусть следующее нажатие попробует ещё раз. Едем по тексту.
    return MapPlace(address: query);
  }

  static Future<MapPlace?> _geocodeOnce(
    Map<String, String> params, {
    ServiceArea? area,
  }) async {
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/geocode/json',
        params,
      );
      final response = await getWithTimeout(uri);
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;
      final first = results.first as Map<String, dynamic>;
      return parseGeocodeResult(
        first,
        queryAddress: (params['address'] ?? '').toString(),
        area: area,
      );
    } catch (_) {
      return null;
    }
  }

  /// Ссылка «проложить маршрут» по готовым точкам. Последняя — конечная,
  /// остальные промежуточные. `null`, если ехать некуда: без `destination`
  /// Google Maps открывает пустую форму поиска, а не маршрут.
  static Uri? routeUri(List<MapPlace> stops) {
    if (stops.isEmpty) return null;
    final trimmed = stops.length > maxMapsWaypoints + 1
        ? [...stops.take(maxMapsWaypoints), stops.last]
        : stops;
    final destination = trimmed.last;
    if (destination.address.trim().isEmpty) return null;
    final waypoints = trimmed.sublist(0, trimmed.length - 1);
    final withIds = waypoints.every((stop) => stop.placeId != null);
    return Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'travelmode': 'driving',
      'destination': destination.address,
      if (destination.placeId != null)
        'destination_place_id': destination.placeId!,
      if (waypoints.isNotEmpty)
        'waypoints': waypoints.map((stop) => stop.address).join('|'),
      if (waypoints.isNotEmpty && withIds)
        'waypoint_place_ids': waypoints.map((stop) => stop.placeId!).join('|'),
    });
  }

  /// Открыть навигатор (Google Maps). `false` — адреса нет или он не разобран,
  /// и об этом надо сказать вслух, а не открывать карту в никуда.
  static Future<bool> openNavigator(String address) async {
    final place = await resolvePlace(address);
    if (place == null) return false;
    return _launch(routeUri([place]));
  }

  /// Открыть построенный маршрут (несколько точек) во внешнем Google Maps
  static Future<bool> openRouteInMaps(List<String> orderedAddresses) async {
    final stops = <MapPlace>[];
    for (final address in orderedAddresses) {
      final place = await resolvePlace(address);
      if (place != null) stops.add(place);
    }
    return _launch(routeUri(stops));
  }

  static Future<bool> _launch(Uri? uri) async {
    if (uri == null) return false;
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
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

      final response = await getWithTimeout(Uri.parse(url));
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

      final response = await getWithTimeout(Uri.parse(url));
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

  /// Статическая карта по точным координатам найденного дома.
  static String getStaticMapUrlForPoint(
    LatLng point, {
    int width = 600,
    int height = 220,
    int zoom = 16,
    LatLng? center,
  }) {
    final lat = point.latitude;
    final lng = point.longitude;
    final c = center ?? point;
    return 'https://maps.googleapis.com/maps/api/staticmap'
        '?center=${c.latitude},${c.longitude}&zoom=$zoom&size=${width}x$height&scale=2'
        '&markers=color:red%7C$lat,$lng&key=$kGoogleApiKey';
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
      // Адреса сначала разбираем сами, с привязкой к зоне: Directions ищет
      // текст по всему миру и на «Main St» без города уводит маршрут в другую
      // провинцию. Что разобрали — отдаём координатами.
      final area = await serviceAreaBias();
      final waypoints = <String>[];
      for (final address in addresses) {
        final place = await resolvePlace(address);
        final point = place?.location;
        final text = place?.address ?? navigationQuery(address, region: area.region);
        waypoints.add(
          point != null
              ? '${point.latitude},${point.longitude}'
              : (text.isEmpty ? address.trim() : text),
        );
      }
      final waypointsParam = waypoints.join('|');
      final optimizePrefix = optimize ? 'optimize:true|' : '';

      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/directions/json',
        {
          'origin': originStr,
          'destination': originStr,
          'waypoints': '$optimizePrefix$waypointsParam',
          'region': 'ca',
          'language': AppLocale.instance.isEn ? 'en' : 'ru',
          'key': kGoogleApiKey,
        },
      );

      final response = await getWithTimeout(uri);
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
