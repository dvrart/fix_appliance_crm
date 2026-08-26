import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/constants.dart';
import '../../core/geo/canadian_provinces.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/client.dart';
import '../../models/location.dart';
import '../../services/client_service.dart';
import '../../services/maps_service.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../calls/call_screen.dart';
import 'client_details_screen.dart';

class ClientsMapScreen extends StatefulWidget {
  const ClientsMapScreen({super.key});

  @override
  State<ClientsMapScreen> createState() => _ClientsMapScreenState();
}

class _ClientPin {
  final Client client;
  final Location location;
  final LatLng coord;

  const _ClientPin({
    required this.client,
    required this.location,
    required this.coord,
  });
}

class _ClientsMapScreenState extends State<ClientsMapScreen> {
  static final LatLng _fallback = CanadianProvince.all.first.center;

  GoogleMapController? _map;
  final List<_ClientPin> _pins = [];
  Set<Marker> _markers = {};
  _ClientPin? _selected;

  bool _loading = true;
  int _pending = 0;
  int _done = 0;
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clients = await ClientService.loadAllOnce();
    if (!mounted) return;

    final toGeocode = <({Client client, int index, Location location})>[];
    final ready = <_ClientPin>[];

    for (final client in clients) {
      if (client.locations.isEmpty) continue;
      for (var i = 0; i < client.locations.length; i++) {
        final location = client.locations[i];
        final address = location.fullAddress.trim();
        if (address.isEmpty) continue;
        if (location.hasCoords &&
            (location.geoAddress == null ||
                location.geoAddress == address)) {
          ready.add(
            _ClientPin(
              client: client,
              location: location,
              coord: LatLng(location.lat!, location.lng!),
            ),
          );
        } else {
          toGeocode.add((client: client, index: i, location: location));
        }
      }
    }

    _pins
      ..clear()
      ..addAll(ready);
    _pending = toGeocode.length;
    _done = 0;
    _rebuildMarkers();
    setState(() => _loading = _pending > 0 && _pins.isEmpty);
    _fitBounds();

    if (toGeocode.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final dirty = <String, List<Location>>{};
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= toGeocode.length) return;
        final item = toGeocode[i];
        final address = item.location.fullAddress.trim();
        final coord = await MapsService.geocodeAddress(address);
        if (!mounted) return;
        if (coord == null) {
          _failed++;
        } else {
          final updated = item.location.copyWith(
            lat: coord.latitude,
            lng: coord.longitude,
            geoAddress: address,
          );
          final locations = List<Location>.from(
            dirty[item.client.id] ?? item.client.locations,
          );
          if (item.index >= 0 && item.index < locations.length) {
            locations[item.index] = updated;
          }
          dirty[item.client.id] = locations;
          _pins.add(
            _ClientPin(
              client: item.client,
              location: updated,
              coord: coord,
            ),
          );
        }
        _done++;
        _rebuildMarkers();
        if (mounted) setState(() => _loading = false);
        if (_done == 1 || _done == _pending || _done % 8 == 0) {
          _fitBounds();
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (!mounted) return;
    _fitBounds();
    setState(() {});

    for (final entry in dirty.entries) {
      try {
        await ClientService.saveLocations(entry.key, entry.value);
      } catch (_) {}
    }
  }

  void _rebuildMarkers() {
    _markers = {
      for (var i = 0; i < _pins.length; i++)
        Marker(
          markerId: MarkerId(
            '${_pins[i].client.id}_${_pins[i].location.id}_$i',
          ),
          position: _pins[i].coord,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
          infoWindow: InfoWindow(
            title: _pins[i].client.fullName.isEmpty
                ? 'Без имени'.tr
                : _pins[i].client.fullName,
            snippet: _pins[i].location.shortAddress,
          ),
          onTap: () => setState(() => _selected = _pins[i]),
        ),
    };
  }

  void _fitBounds() {
    final map = _map;
    if (map == null || _pins.isEmpty) return;

    if (_pins.length == 1) {
      map.animateCamera(
        CameraUpdate.newLatLngZoom(_pins.first.coord, 14),
      );
      return;
    }

    var minLat = _pins.first.coord.latitude;
    var maxLat = minLat;
    var minLng = _pins.first.coord.longitude;
    var maxLng = minLng;
    for (final pin in _pins) {
      final lat = pin.coord.latitude;
      final lng = pin.coord.longitude;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        72,
      ),
    );
  }

  Map<String, dynamic> _clientData(Client client) {
    final data = client.toMap();
    data.remove('updatedAt');
    data['id'] = client.id;
    data['name'] = client.fullName;
    return data;
  }

  void _openClient(_ClientPin pin) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientDetailsScreen(
          clientId: pin.client.id,
          clientData: _clientData(pin.client),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final geocoding = _pending > 0 && _done < _pending;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(
          _pins.isEmpty
              ? 'Клиенты на карте'.tr
              : '${'Клиенты на карте'.tr} · ${_pins.length}',
        ),
      ),
      body: Column(
        children: [
          if (geocoding)
            LinearProgressIndicator(
              value: _pending == 0 ? null : _done / _pending,
              color: AppColors.accent,
              backgroundColor: AppColors.accent.withOpacity(0.2),
            ),
          if (_failed > 0 && !geocoding)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '${'Не удалось отметить часть адресов'.tr}: $_failed',
                style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
              ),
            ),
          Expanded(
            child: _loading
                ? const AppLoading()
                : _pins.isEmpty && !geocoding
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Нет клиентов с адресом'.tr,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ),
                      )
                    : Stack(
                        children: [
                          GoogleMap(
                            initialCameraPosition: CameraPosition(
                              target: _pins.isNotEmpty
                                  ? _pins.first.coord
                                  : _fallback,
                              zoom: _pins.length == 1 ? 14 : 8,
                            ),
                            markers: _markers,
                            myLocationEnabled: true,
                            myLocationButtonEnabled: true,
                            zoomControlsEnabled: false,
                            onMapCreated: (controller) {
                              _map = controller;
                              _fitBounds();
                            },
                            onTap: (_) => setState(() => _selected = null),
                          ),
                          if (_selected != null)
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: _PinCard(
                                pin: _selected!,
                                onClose: () => setState(() => _selected = null),
                                onOpen: () => _openClient(_selected!),
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _PinCard extends StatelessWidget {
  final _ClientPin pin;
  final VoidCallback onClose;
  final VoidCallback onOpen;

  const _PinCard({
    required this.pin,
    required this.onClose,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final name = pin.client.fullName.isEmpty
        ? 'Без имени'.tr
        : pin.client.fullName;
    final phone = pin.client.phone.trim();
    final address = pin.location.fullAddress;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (address.isNotEmpty)
                  Text(
                    address,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Позвонить'.tr,
                      onPressed: phone.isEmpty
                          ? null
                          : () => CallScreen.open(
                                context,
                                phoneNumber: phone,
                                contactName: name,
                              ),
                      icon: const Icon(Icons.phone, color: Colors.green),
                    ),
                    IconButton(
                      tooltip: 'Навигация'.tr,
                      onPressed: address.isEmpty
                          ? null
                          : () => MapsService.openNavigator(address),
                      icon: Icon(
                        Icons.directions,
                        color: AppColors.primary,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: onOpen,
                      child: Text('Открыть клиента'.tr),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
