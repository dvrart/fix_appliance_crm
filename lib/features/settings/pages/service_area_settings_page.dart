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

  /// Вложенная страница — отдельный экземпляр со своим списком точек.
  /// После возврата перечитываем базу, иначе хаб показывает старое.
  Future<void> _open(_AreaSection section) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServiceAreaSettingsPage._at(section.index),
      ),
    );
    if (mounted) await _load();
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

  void _movePoint(int index, LatLng point) {
    if (index < 0 || index >= _points.length) return;
    setState(() {
      _points[index] = point;
      _dirty = true;
    });
  }

  void _removePoint(int index) {
    if (index < 0 || index >= _points.length) return;
    setState(() {
      _points.removeAt(index);
      _dirty = true;
    });
  }

  Future<void> _onMarkerTap(int index) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '${context.tr('Точка', 'Point')} ${index + 1}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                context.tr(
                  'Чтобы сдвинуть — зажмите маркер и тяните.',
                  'Long-press the marker and drag to move it.',
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                context.tr('Удалить точку', 'Delete point'),
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(sheet, true),
            ),
          ],
        ),
      ),
    );
    if (remove == true && mounted) _removePoint(index);
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
          draggable: true,
          onDragEnd: (point) => _movePoint(i, point),
          onTap: () => _onMarkerTap(i),
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
                'Тап по карте — новая точка. Зажмите маркер и тяните, чтобы '
                    'сдвинуть. Тап по маркеру — удалить.',
                'Tap the map to add a point. Long-press a marker and drag to '
                    'move it. Tap a marker to delete it.',
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _points.isEmpty
                        ? context.tr('Район ещё не отмечен', 'No area marked yet')
                        : '${'Точек'.tr}: ${_points.length}',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
                TextButton.icon(
                  onPressed: _points.isEmpty ? null : _undo,
                  icon: const Icon(Icons.undo, size: 18),
                  label: Text(context.tr('Отменить', 'Undo')),
                  style: TextButton.styleFrom(foregroundColor: Colors.blueGrey),
                ),
                TextButton.icon(
                  onPressed: _points.isEmpty ? null : _clear,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(context.tr('Очистить', 'Clear')),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
