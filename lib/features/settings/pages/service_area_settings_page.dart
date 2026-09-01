import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/geo/canadian_provinces.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/maps_service.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';

enum _AreaSection { hub, province, map }

class ServiceAreaSettingsPage extends StatefulWidget {
  const ServiceAreaSettingsPage({super.key}) : _sectionIndex = 0;

  const ServiceAreaSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _AreaSection get _section => _AreaSection.values[_sectionIndex.clamp(0, 2)];

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

  void _open(_AreaSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServiceAreaSettingsPage._at(section.index),
      ),
    );
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

  Future<void> _pickProvince() async {
    final code = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                context.tr('Провинция', 'Province'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final province in CanadianProvince.all)
              ListTile(
                title: Text('${province.name} (${province.code})'),
                trailing: province.code == _province.code
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, province.code),
              ),
          ],
        ),
      ),
    );
    if (code == null || !mounted) return;
    await _selectProvince(CanadianProvince.byName(code));
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
    if (_loading) {
      return SettingsPageScaffold(
        title: context.tr('Зона обслуживания', 'Service area'),
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    switch (widget._section) {
      case _AreaSection.hub:
        return _buildHub();
      case _AreaSection.province:
        return _buildProvince();
      case _AreaSection.map:
        return _buildMap();
    }
  }

  Widget _buildHub() {
    return SettingsPageScaffold(
      title: context.tr('Зона обслуживания', 'Service area'),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              context.tr(
                'Секретарь на звонках берёт зону отсюда.',
                'The phone secretary uses this area.',
              ),
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          SettingsTileSection(
            title: context.tr('Зона', 'Area'),
            tiles: [
              SettingsHubTile(
                title: context.tr('Провинция', 'Province'),
                subtitle: _province.code,
                icon: Icons.map_outlined,
                color: Colors.orange,
                onTap: _pickProvince,
              ),
              SettingsHubTile(
                title: context.tr('Карта', 'Map'),
                subtitle: _points.isEmpty
                    ? context.tr('Не отмечена', 'Not marked')
                    : '${_points.length} ${'точек'.tr}',
                icon: Icons.edit_location_alt,
                color: AppColors.primary,
                active: _points.length >= 3,
                onTap: () => _open(_AreaSection.map),
              ),
              SettingsHubTile(
                title: context.tr('Отменить', 'Undo'),
                subtitle: context.tr('Точку', 'Point'),
                icon: Icons.undo,
                color: Colors.blueGrey,
                onTap: _points.isEmpty ? () {} : _undo,
              ),
              SettingsHubTile(
                title: context.tr('Очистить', 'Clear'),
                subtitle: '',
                icon: Icons.delete_outline,
                color: Colors.red,
                onTap: _points.isEmpty ? () {} : _clear,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProvince() {
    return SettingsPageScaffold(
      title: context.tr('Провинция', 'Province'),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('Провинция', 'Province'),
            tiles: [
              for (final province in CanadianProvince.all)
                SettingsHubTile(
                  title: province.code,
                  subtitle: province.name,
                  icon: Icons.map_outlined,
                  color: Colors.orange,
                  active: province.code == _province.code,
                  onTap: () => _selectProvince(province),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    return SettingsPageScaffold(
      title: context.tr('Карта', 'Map'),
      dirty: _dirty,
      onSave: _save,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              context.tr(
                'Нажимайте по карте, чтобы поставить точки.',
                'Tap the map to drop points.',
              ),
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _points.isNotEmpty ? _points.first : _province.center,
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
            padding: const EdgeInsets.all(16),
            child: Text(
              _points.isEmpty
                  ? context.tr('Район ещё не отмечен', 'No area marked yet')
                  : '${'Точек'.tr}: ${_points.length}',
              style: const TextStyle(color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}
