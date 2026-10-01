import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/network_status_service.dart';
import '../core/api_keys.dart';
import '../core/geo/service_area.dart';
import '../core/l10n/app_locale.dart';
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
  final configFuture = SettingsService.loadConfig();

  /// Одна выдача Google: [circle] — круг поиска, [strict] режет всё снаружи.
  Future<List<Map<String, dynamic>>> fetchOnce(
    String query, {
    AreaSearchCircle? circle,
    bool strict = false,
  }) async {
    final url = StringBuffer(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=${Uri.encodeComponent(query)}'
      '&key=$kGoogleMapsApiKey'
      '&language=${AppLocale.instance.isEn ? 'en' : 'ru'}'
      '&components=country:ca',
    );
    if (circle != null) {
      url.write(
        '&location=${circle.center.latitude},${circle.center.longitude}'
        '&radius=${circle.radiusMeters.round()}',
      );
      if (strict) url.write('&strictbounds=true');
    }
    try {
      final response = await getWithTimeout(Uri.parse(url.toString()));
      if (response.statusCode != 200) return const [];
      final data = json.decode(response.body);
      if (data['status'] != 'OK') return const [];
      return List<Map<String, dynamic>>.from(data['predictions']);
    } catch (e) {
      debugPrint('${'Ошибка Autocomplete'.tr}: $e');
      return const [];
    }
  }

  /// Подсказки. [restrict] — только зона: круги с карты, которые её накрывают.
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
    if (!restrict) {
      return fetchOnce(
        query,
        circle: AreaSearchCircle(
          area.center,
          math.min(area.radiusMeters, ServiceArea.maxStrictRadiusMeters),
        ),
      );
    }
    final circles = area.searchCircles;
    final batches = await Future.wait([
      for (final circle in circles)
        fetchOnce(query, circle: circle, strict: true),
    ]);
    // Чередуем выдачи кругов, чтобы лучшее совпадение каждого было сверху.
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    final depth = batches.fold<int>(0, (max, list) => math.max(max, list.length));
    for (var i = 0; i < depth; i++) {
      for (final batch in batches) {
        if (i >= batch.length) continue;
        final item = batch[i];
        final id = (item['place_id'] ?? '').toString();
        if (id.isNotEmpty && !seen.add(id)) continue;
        merged.add(item);
      }
    }
    return merged;
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
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
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
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF14557F),
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

                          final detailsUrl =
                              'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$kGoogleMapsApiKey&language=ru';
                          try {
                            final response = await getWithTimeout(Uri.parse(detailsUrl));
                            if (disposed || !sheetContext.mounted ||
                                request != lookupGeneration) {
                              return;
                            }
                            if (response.statusCode == 200) {
                              final data = json.decode(response.body);
                              if (data['status'] == 'OK') {
                                final result = data['result'];
                                final components =
                                    result['address_components'] as List;

                                String sNum = '';
                                String rName = '';
                                String cName = '';
                                String zCode = '';
                                String unit = unitCtrl.text;

                                for (var c in components) {
                                  final types = c['types'] as List;
                                  if (types.contains('street_number')) {
                                    sNum = c['long_name'];
                                  }
                                  if (types.contains('route')) {
                                    rName = c['long_name'];
                                  }
                                  if (types.contains('locality') ||
                                      types.contains('administrative_area_level_3')) {
                                    cName = c['long_name'];
                                  }
                                  if (types.contains('postal_code')) {
                                    zCode = c['long_name'];
                                  }
                                  if (types.contains('subpremise')) {
                                    unit = c['long_name'];
                                  }
                                }

                                final lat = result['geometry']['location']['lat'];
                                final lng = result['geometry']['location']['lng'];
                                final inside = area.contains(
                                  LatLng(
                                    (lat as num).toDouble(),
                                    (lng as num).toDouble(),
                                  ),
                                );

                                setSheetState(() {
                                  streetCtrl.text = '$sNum $rName'.trim();
                                  if (unit.trim().isNotEmpty) unitCtrl.text = unit.trim();
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
