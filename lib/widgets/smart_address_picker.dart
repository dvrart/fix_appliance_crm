import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../services/network_status_service.dart';
import '../core/api_keys.dart';
import '../core/constants.dart';
import '../core/geo/service_area.dart';
import '../core/l10n/app_locale.dart';
import '../core/motion.dart';
import '../services/settings_service.dart';
import '../shared/widgets/app_bar_save.dart';
import '../shared/widgets/dirty_leave_scope.dart';
import '../shared/widgets/keyboard_safe.dart';

final _unitPrefix = RegExp(
  r'^(?:unit|apt|suite|#)\s*[:.]?\s*(.+)$',
  caseSensitive: false,
);

/// Street plus optional unit peeled from "Unit 5" / "Apt 12" fragments.
({String street, String unit}) peelUnit(String street) {
  final parts = street
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  var unit = '';
  final kept = <String>[];
  for (final part in parts) {
    final match = _unitPrefix.firstMatch(part);
    if (match != null && unit.isEmpty) {
      unit = match.group(1)!.trim();
    } else {
      kept.add(part);
    }
  }
  return (street: kept.join(', '), unit: unit);
}

String unitFromLocations(Map<String, dynamic>? data) {
  final raw = data?['locations'];
  if (raw is List && raw.isNotEmpty && raw.first is Map) {
    return ((raw.first as Map)['unit'] ?? '').toString().trim();
  }
  return '';
}

/// Splits a stored address into street / city / postal.
/// If the last part is not a Canadian postal code, it is treated as the city.
List<String> splitAddress(String full) {
  final parts = full
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return const ['', '', ''];
  final postalRe = RegExp(r'^[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d$');
  if (parts.length >= 2 && postalRe.hasMatch(parts.last)) {
    final city = parts.length >= 3 ? parts[parts.length - 2] : '';
    final street = parts.length >= 3
        ? parts.sublist(0, parts.length - 2).join(', ')
        : parts.first;
    return [street, city, parts.last];
  }
  if (parts.length >= 2) {
    return [parts.sublist(0, parts.length - 1).join(', '), parts.last, ''];
  }
  return [parts.first, '', ''];
}

String _unitLabel(String unit) {
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return '';
  if (_unitPrefix.hasMatch(trimmed) || trimmed.startsWith('#')) return trimmed;
  return 'Unit $trimmed';
}

String joinAddress(String street, String city, String postal, [String unit = '']) {
  final streetPart = [
    if (street.trim().isNotEmpty) street.trim(),
    if (_unitLabel(unit).isNotEmpty) _unitLabel(unit),
  ].join(', ');
  return [streetPart, city.trim(), postal.trim()].where((s) => s.isNotEmpty).join(', ');
}

void showSmartAddressPicker({
  required BuildContext context,
  required String initialStreet,
  required String initialCity,
  required String initialPostal,
  String initialUnit = '',
  required void Function(String street, String city, String postal, String unit)
      onSaved,
}) {
  final peeled = peelUnit(initialStreet);
  final initialStreetValue = peeled.street;
  final initialUnitValue =
      initialUnit.trim().isNotEmpty ? initialUnit.trim() : peeled.unit;
  final streetCtrl = TextEditingController(text: initialStreetValue);
  final unitCtrl = TextEditingController(text: initialUnitValue);
  final cityCtrl = TextEditingController(text: initialCity);
  final postalCtrl = TextEditingController(text: initialPostal);
  String? staticMapUrl;
  var isFetching = false;
  var predictions = <Map<String, dynamic>>[];
  Timer? searchDebounce;
  var disposed = false;
  var lookupGeneration = 0;
  final searchCtrl = TextEditingController();
  // Зона обслуживания с карты в настройках: поиск смотрит только в неё.
  var area = ServiceArea.empty;
  // В зоне ничего не нашлось — в списке лежат адреса снаружи.
  var widenedSearch = false;
  // Выбранный адрес оказался вне зоны.
  var outsideArea = false;
  // Один токен на всё окно: Google считает все подсказки одной сессией
  // (так дешевле, чем платить за каждый нажатый символ отдельно).
  final sessionToken = _uuidV4();
  final configFuture = SettingsService.loadConfig();

  /// Одна выдача Google: [bounds] — прямоугольник, [strict] режет всё снаружи.
  Future<List<Map<String, dynamic>>> fetchOnce(
    String query, {
    LatLngBounds? bounds,
    bool strict = false,
  }) async {
    final body = <String, dynamic>{
      'input': query,
      // Только адреса: дома, улицы, здания и индексы — без магазинов и парков.
      'includedPrimaryTypes': const [
        'street_address',
        'route',
        'premise',
        'subpremise',
        'postal_code',
      ],
      'includedRegionCodes': const ['ca'],
      'languageCode': AppLocale.instance.isEn ? 'en' : 'ru',
      'sessionToken': sessionToken,
      if (bounds != null && strict)
        'locationRestriction': _rectangle(bounds),
      if (bounds != null && !strict)
        'locationBias': _rectangle(bounds),
    };
    try {
      final response = await http
          .post(
            Uri.https('places.googleapis.com', '/v1/places:autocomplete'),
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': kGoogleMapsApiKey,
              // Только то, что рисуем в списке: подпись и идентификатор места.
              'X-Goog-FieldMask': 'suggestions.placePrediction.placeId,'
                  'suggestions.placePrediction.text.text',
            },
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return const [];
      final data = json.decode(response.body);
      final suggestions = data['suggestions'] as List? ?? const [];
      return [
        for (final item in suggestions)
          if (item is Map && item['placePrediction'] is Map)
            {
              'place_id': (item['placePrediction']['placeId'] ?? '').toString(),
              'description':
                  (item['placePrediction']['text']?['text'] ?? '').toString(),
            },
      ];
    } catch (e) {
      debugPrint('${'Ошибка Autocomplete'.tr}: $e');
      return const [];
    }
  }

  /// Подсказки. [restrict] — только зона: прямоугольник, который её накрывает.
  Future<List<Map<String, dynamic>>> fetchPredictions(
    String query, {
    required bool restrict,
  }) async {
    if (!area.hasPolygon) {
      var input = query;
      if (area.region.isNotEmpty &&
          !input.toLowerCase().contains(area.region.toLowerCase())) {
        input = '$input, ${area.region}';
      }
      return fetchOnce(input);
    }
    return fetchOnce(
      query,
      bounds: area.boundingBox,
      strict: restrict,
    );
  }

  bool isDirty() {
    return streetCtrl.text.trim() != initialStreetValue.trim() ||
        cityCtrl.text.trim() != initialCity.trim() ||
        postalCtrl.text.trim() != initialPostal.trim() ||
        unitCtrl.text.trim() != initialUnitValue.trim() ||
        staticMapUrl != null;
  }

  Future<bool> persist() async {
    onSaved(
      streetCtrl.text.trim(),
      cityCtrl.text.trim(),
      postalCtrl.text.trim(),
      unitCtrl.text.trim(),
    );
    return true;
  }

  showModalBottomSheet(
    sheetAnimationStyle: AppMotion.sheet,
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (builderContext, setSheetState) {
          return FutureBuilder<Map<String, dynamic>>(
            future: configFuture,
            builder: (fbContext, snapshot) {
              if (snapshot.hasData) {
                area = ServiceArea.fromConfig(snapshot.data!);
              }

              return DirtyLeaveScope(
                dirty: isDirty(),
                onSave: persist,
                onDispose: () {
                  disposed = true;
                  searchDebounce?.cancel();
                  for (final controller in [
                    streetCtrl, unitCtrl, cityCtrl, postalCtrl, searchCtrl,
                  ]) {
                    controller.dispose();
                  }
                },
                child: Builder(
                  builder: (context) {
                    return KeyboardAvoidingSheet(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Поиск адреса'.tr,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryOnCard,
                                  ),
                                ),
                                if (area.title.isNotEmpty)
                                  Text(
                                    '${'Зона:'.tr} ${area.title}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () =>
                                DirtyLeaveScope.of(context)?.requestLeave(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      TextField(
                        controller: searchCtrl,
                        decoration: InputDecoration(
                          labelText: 'Начните вводить адрес (поиск)'.tr,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Color(0xFFFCC520),
                          ),
                        ),
                        onChanged: (value) {
                          final request = ++lookupGeneration;
                          searchDebounce?.cancel();
                          if (isFetching) {
                            setSheetState(() => isFetching = false);
                          }
                          if (value.trim().length < 3) {
                            setSheetState(() {
                              predictions = [];
                              widenedSearch = false;
                              outsideArea = false;
                            });
                            return;
                          }
                          searchDebounce = Timer(
                            const Duration(milliseconds: 280),
                            () async {
                              // Сначала строго внутри зоны. Если там пусто —
                              // показываем ближайшие, но помечаем как «вне зоны».
                              var found =
                                  await fetchPredictions(value, restrict: true);
                              var widened = false;
                              if (disposed || !sheetContext.mounted ||
                                  request != lookupGeneration) {
                                return;
                              }
                              if (found.isEmpty && area.canRestrictSearch) {
                                found = await fetchPredictions(
                                  value,
                                  restrict: false,
                                );
                                widened = found.isNotEmpty;
                              }
                              // Медленный ответ не должен затирать новый запрос.
                              if (disposed || !sheetContext.mounted ||
                                  request != lookupGeneration ||
                                  searchCtrl.text != value) {
                                return;
                              }
                              setSheetState(() {
                                predictions = found;
                                widenedSearch = widened;
                                outsideArea = false;
                              });
                            },
                          );
                        },
                      ),
                      if (widenedSearch || outsideArea)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 18,
                                color: outsideArea
                                    ? Colors.red.shade700
                                    : Colors.orange.shade800,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  outsideArea
                                      ? 'Адрес вне зоны обслуживания'.tr
                                      : 'В зоне ничего не нашлось — показываю ближайшие'
                                          .tr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: outsideArea
                                        ? Colors.red.shade700
                                        : Colors.orange.shade800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (predictions.isNotEmpty)
                        Expanded(
                          child: ListView.builder(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            itemCount: predictions.length,
                            itemBuilder: (context, index) {
                              final selection = predictions[index];
                              return ListTile(
                                leading: const Icon(Icons.place_outlined),
                                title: Text(
                                  (selection['description'] ?? '').toString(),
                                ),
                                onTap: () async {
                          final placeId = selection['place_id'];
                          final request = ++lookupGeneration;
                          searchDebounce?.cancel();
                          setSheetState(() => isFetching = true);

                          final detailsUri = Uri.https(
                            'places.googleapis.com',
                            '/v1/places/$placeId',
                            {
                              'languageCode': 'ru',
                              'sessionToken': sessionToken,
                            },
                          );
                          try {
                            final response = await getWithTimeout(
                              detailsUri,
                              headers: {
                                'X-Goog-Api-Key': kGoogleMapsApiKey,
                                // Только адрес и координаты — остальное не нужно.
                                'X-Goog-FieldMask':
                                    'location,addressComponents',
                              },
                            );
                            if (disposed || !sheetContext.mounted ||
                                request != lookupGeneration) {
                              return;
                            }
                            if (response.statusCode == 200) {
                              final data =
                                  json.decode(response.body)
                                      as Map<String, dynamic>;
                              final components =
                                  data['addressComponents'] as List? ??
                                  const [];

                              String sNum = '';
                              String rName = '';
                              String cName = '';
                              String zCode = '';
                              String unit = unitCtrl.text;

                              for (final raw in components) {
                                final c = raw as Map<String, dynamic>;
                                final types = c['types'] as List? ?? const [];
                                final name =
                                    (c['longText'] ?? '').toString();
                                if (types.contains('street_number')) {
                                  sNum = name;
                                }
                                if (types.contains('route')) {
                                  rName = name;
                                }
                                if (types.contains('locality') ||
                                    types.contains(
                                      'administrative_area_level_3',
                                    )) {
                                  cName = name;
                                }
                                if (types.contains('postal_code')) {
                                  zCode = name;
                                }
                                if (types.contains('subpremise')) {
                                  unit = name;
                                }
                              }

                              final location =
                                  data['location'] as Map<String, dynamic>? ??
                                  const {};
                              final lat = location['latitude'] as num?;
                              final lng = location['longitude'] as num?;
                              if (lat != null && lng != null) {
                                final inside = area.contains(
                                  LatLng(lat.toDouble(), lng.toDouble()),
                                );

                                setSheetState(() {
                                  streetCtrl.text = '$sNum $rName'.trim();
                                  if (unit.trim().isNotEmpty) {
                                    unitCtrl.text = unit.trim();
                                  }
                                  cityCtrl.text = cName;
                                  postalCtrl.text = zCode;
                                  searchCtrl.text = streetCtrl.text;
                                  predictions = [];
                                  widenedSearch = false;
                                  outsideArea = !inside;
                                  staticMapUrl =
                                      'https://maps.googleapis.com/maps/api/staticmap?center=$lat,$lng&zoom=16&size=600x300&markers=color:red%7C$lat,$lng&key=$kGoogleMapsApiKey';
                                  isFetching = false;
                                });
                              }
                            }
                          } catch (_) {
                          } finally {
                            if (!disposed && sheetContext.mounted &&
                                request == lookupGeneration) {
                              setSheetState(() => isFetching = false);
                            }
                          }
                                },
                              );
                            },
                          ),
                        )
                      else ...[
                      const SizedBox(height: 16),

                      if (isFetching)
                        const SizedBox(
                          height: 120,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF14557F),
                            ),
                          ),
                        )
                      else if (staticMapUrl != null)
                        Container(
                          height: 120,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade300),
                            image: DecorationImage(
                              image: NetworkImage(staticMapUrl!),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),

                      if (staticMapUrl != null) const SizedBox(height: 16),

                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: TextField(
                                      controller: streetCtrl,
                                      onChanged: (_) => setSheetState(() {}),
                                      decoration: InputDecoration(
                                        labelText: 'Улица и дом'.tr,
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: TextField(
                                      controller: unitCtrl,
                                      onChanged: (_) => setSheetState(() {}),
                                      decoration: InputDecoration(
                                        labelText: 'Unit'.tr,
                                        hintText: '5, 12A…',
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: TextField(
                                      controller: cityCtrl,
                                      onChanged: (_) => setSheetState(() {}),
                                      decoration: InputDecoration(
                                        labelText: 'Город'.tr,
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 4,
                                    child: TextField(
                                      controller: postalCtrl,
                                      onChanged: (_) => setSheetState(() {}),
                                      decoration: InputDecoration(
                                        labelText: 'Индекс'.tr,
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ],
                      // Подтверждение внизу, зелёной кнопкой, как на остальных
                      // экранах. Раньше это было «Готово» в правом верхнем углу
                      // — мелкой ссылкой рядом с крестиком закрытия.
                      SafeArea(
                        minimum: const EdgeInsets.only(bottom: 10),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kConfirmGreen,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(52),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () async {
                              if (await persist() && sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            },
                            icon: const Icon(Icons.check_rounded, size: 26),
                            label: Text(
                              'Готово'.tr,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                    );
                  },
                ),
              );
            },
          );
        },
      );
    },
  );
}

/// Прямоугольник для Places API (New): юго-запад и северо-восток зоны.
Map<String, dynamic> _rectangle(LatLngBounds bounds) => {
      'rectangle': {
        'low': {
          'latitude': bounds.southwest.latitude,
          'longitude': bounds.southwest.longitude,
        },
        'high': {
          'latitude': bounds.northeast.latitude,
          'longitude': bounds.northeast.longitude,
        },
      },
    };

/// Случайный идентификатор сессии подсказок (uuid v4, без внешних пакетов).
String _uuidV4() {
  final rnd = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
