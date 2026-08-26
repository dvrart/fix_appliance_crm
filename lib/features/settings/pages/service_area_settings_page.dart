import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/geo/canadian_provinces.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/maps_service.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../widgets/settings_ui.dart';

class ServiceAreaSettingsPage extends StatefulWidget {
  const ServiceAreaSettingsPage({super.key});

  @override
  State<ServiceAreaSettingsPage> createState() =>
      _ServiceAreaSettingsPageState();
}

class _ServiceAreaSettingsPageState extends State<ServiceAreaSettingsPage> {
  GoogleMapController? _map;
  CanadianProvince _province = CanadianProvince.all.first;
  final List<LatLng> _points = [];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _map?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await SettingsService.loadConfig();
    if (!mounted) return;
    _province = CanadianProvince.byName(data['serviceRegion'] as String?);
    final raw = data['servicePolygon'];
    if (raw is List) {
      _points
        ..clear()
        ..addAll(
          raw.whereType<Map>().map((item) {
            final map = Map<String, dynamic>.from(item);
            return LatLng(
              (map['lat'] as num?)?.toDouble() ?? 0,
              (map['lng'] as num?)?.toDouble() ?? 0,
            );
          }).where((point) => point.latitude != 0 || point.longitude != 0),
        );
    }
    setState(() {
      _loading = false;
      _dirty = false;
    });
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      final label = await MapsService.describeServiceArea(
        provinceName: _province.name,
        points: _points,
      );
      await SettingsService.updateConfigMap({
        'serviceRegion': _province.name,
        'serviceProvinceCode': _province.code,
        'servicePolygon': _points
            .map((point) => {'lat': point.latitude, 'lng': point.longitude})
            .toList(),
        'serviceAreaLabel': label,
      });
      await SettingsService.syncSecretaryServiceArea();
      if (!mounted) return false;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Зона обслуживания сохранена', 'Service area saved'),
          ),
          backgroundColor: Colors.green,
        ),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectProvince(CanadianProvince province) async {
    setState(() {
      _province = province;
      _dirty = true;
    });
    await _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: province.center, zoom: province.zoom),
      ),
    );
  }

  void _addPoint(LatLng point) {
    setState(() {
      _points.add(point);
      _dirty = true;
    });
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() {
      _points.removeLast();
      _dirty = true;
    });
  }

  void _clear() {
    setState(() {
      _points.clear();
      _dirty = true;
    });
  }

  Set<Polygon> get _polygons {
    if (_points.length < 3) return {};
    return {
      Polygon(
        polygonId: const PolygonId('service_area'),
        points: _points,
        strokeWidth: 2,
        strokeColor: AppColors.primary,
        fillColor: AppColors.primary.withValues(alpha: 0.18),
      ),
    };
  }

  Set<Marker> get _markers {
    return {
      for (var i = 0; i < _points.length; i++)
        Marker(
          markerId: MarkerId('p$i'),
          position: _points[i],
          infoWindow: InfoWindow(title: '${i + 1}'),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Зона обслуживания', 'Service area'),
      dirty: _dirty,
      onSave: _save,
      actions: [
        AppBarSaveButton(
          dirty: _dirty,
          saving: _saving,
          onPressed: () { _save(); },
        ),
      ],
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr(
                          'Выберите провинцию и отметьте район на карте. Нажимайте по карте, чтобы поставить точки. Секретарь на звонках берёт зону отсюда.',
                          'Pick a province and mark your area on the map. Tap the map to drop points. The phone secretary uses this area.',
                        ),
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _province.code,
                        decoration: InputDecoration(
                          labelText: context.tr('Провинция', 'Province'),
                          prefixIcon: const Icon(Icons.map_outlined),
                          filled: true,
                          fillColor: Colors.white,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          for (final province in CanadianProvince.all)
                            DropdownMenuItem(
                              value: province.code,
                              child: Text('${province.name} (${province.code})'),
                            ),
                        ],
                        onChanged: (code) {
                          if (code == null) return;
                          _selectProvince(CanadianProvince.byName(code));
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: _points.isNotEmpty
                              ? _points.first
                              : _province.center,
                          zoom: _points.isNotEmpty ? 10 : _province.zoom,
                        ),
                        polygons: _polygons,
                        markers: _markers,
                        myLocationButtonEnabled: true,
                        myLocationEnabled: true,
                        onMapCreated: (controller) => _map = controller,
                        onTap: _addPoint,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  child: Column(
                    children: [
                      Text(
                        _points.isEmpty
                            ? context.tr(
                                'Район ещё не отмечен',
                                'No area marked yet',
                              )
                            : context.tr(
                                '${'Точек'.tr}: ${_points.length}',
                                'Points: ${_points.length}',
                              ),
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _points.isEmpty ? null : _undo,
                              child: Text(context.tr('Отменить точку', 'Undo point')),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _points.isEmpty ? null : _clear,
                              child: Text(context.tr('Очистить', 'Clear')),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
