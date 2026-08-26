import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/constants.dart';
import '../../models/job.dart';
import '../../services/services.dart';
import 'job_details/job_details_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/job_agenda_card.dart';

/// Карта оптимального маршрута на сегодня + список остановок
/// с возможностью вручную поменять порядок (drag & drop).
class RouteMapChrome {
  final String distanceText;
  final VoidCallback applyTimes;
  final VoidCallback openMaps;
  final VoidCallback refresh;

  const RouteMapChrome({
    required this.distanceText,
    required this.applyTimes,
    required this.openMaps,
    required this.refresh,
  });
}

class RouteMapView extends StatefulWidget {
  final List<Job> jobs;
  final DateTime day;
  final ValueChanged<RouteMapChrome?>? onChromeChanged;

  const RouteMapView({
    super.key,
    required this.jobs,
    required this.day,
    this.onChromeChanged,
  });

  @override
  State<RouteMapView> createState() => _RouteMapViewState();
}

class _RouteMapViewState extends State<RouteMapView> {
  List<Job> _orderedJobs = [];
  int _skippedCount = 0;
  OptimizedRoute? _route;
  LatLng? _origin;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  GoogleMapController? _mapController;

  bool _loading = true;
  bool _recomputing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRoute();
  }

  void _notifyChrome() {
    final callback = widget.onChromeChanged;
    if (callback == null) return;
    final distance = _route?.totalDistanceText;
    final chrome = (distance == null || distance.isEmpty)
        ? null
        : RouteMapChrome(
            distanceText: distance,
            applyTimes: _applyTimesFromRoute,
            openMaps: () {
              MapsService.openRouteInMaps(
                _orderedJobs.map((j) => j.workAddress).toList(),
              );
            },
            refresh: _loadRoute,
          );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      callback(chrome);
    });
  }

  String _paintSig(List<Job> jobs) => jobs
      .map((job) {
        final visit = job.visitOn(widget.day);
        return '${job.id}:${job.displayStatusForVisit(visit)}';
      })
      .join('|');

  void _syncJobsFromWidget() {
    final byId = {for (final job in widget.jobs) job.id: job};
    _orderedJobs = [for (final job in _orderedJobs) byId[job.id] ?? job];
  }

  @override
  void didUpdateWidget(RouteMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.jobs.map((j) => j.id).join(',');
    final newIds = widget.jobs.map((j) => j.id).join(',');
    if (oldIds != newIds || !JobVisit.isSameDay(oldWidget.day, widget.day)) {
      _loadRoute();
      return;
    }
    final paintChanged = _paintSig(oldWidget.jobs) != _paintSig(widget.jobs);
    _syncJobsFromWidget();
    if (paintChanged) {
      _buildMarkersAndPolylines();
    }
  }

  Future<void> _loadRoute() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final jobsWithAddress = widget.jobs
        .where((j) => j.workAddress.trim().isNotEmpty)
        .toList();
    _skippedCount = widget.jobs.length - jobsWithAddress.length;
    _orderedJobs = jobsWithAddress;

    if (_orderedJobs.isEmpty) {
      _route = null;
      _notifyChrome();
      if (mounted) setState(() => _loading = false);
      return;
    }

    final position = await MapsService.getCurrentPosition();
    if (!mounted) return;
    if (position == null) {
      final firstAddress = _orderedJobs.first.workAddress;
      final fallback = await MapsService.geocodeAddress(firstAddress);
      if (!mounted) return;
      if (fallback == null) {
        _route = null;
        _notifyChrome();
        setState(() {
          _loading = false;
          _error =
              '${'Не удалось определить ваше местоположение.'.tr}\n'
              '${'Разрешите доступ к геолокации в настройках телефона.'.tr}';
        });
        return;
      }
      _origin = fallback;
    } else {
      _origin = LatLng(position.latitude, position.longitude);
    }

    final route = await MapsService.getOptimizedRoute(
      origin: _origin!,
      addresses: _orderedJobs.map((j) => j.workAddress).toList(),
    );
    if (!mounted) return;

    if (route == null) {
      _route = null;
      _notifyChrome();
      setState(() {
        _loading = false;
        _error =
            '${'Не удалось построить маршрут.'.tr}\n'
            '${MapsService.lastRouteError ?? 'Проверьте адреса заявок.'.tr}';
      });
      return;
    }

    _route = route;
    _orderedJobs = route.order.map((i) => _orderedJobs[i]).toList();
    await _buildMarkersAndPolylines();
    if (!mounted) return;
    _notifyChrome();
    setState(() => _loading = false);
  }

  Future<void> _applyTimesFromRoute() async {
    if (_orderedJobs.isEmpty) return;
    final config = await SettingsService.loadConfig();
    final buffer = SettingsService.readTravelBufferMinutes(config);
    final day = widget.day;
    var cursor =
        _orderedJobs.first.visitOn(day)?.startAt ??
        DateTime(day.year, day.month, day.day, 9, 0);
    cursor = DateTime(
      cursor.year,
      cursor.month,
      cursor.day,
      cursor.hour,
      cursor.minute,
    );
    for (final job in _orderedJobs) {
      final visits = [...job.coalescedVisits];
      final idx = visits.indexWhere((v) => JobVisit.isSameDay(v.startAt, day));
      if (idx >= 0) {
        visits[idx] = visits[idx].copyWith(startAt: cursor);
      } else {
        visits.add(
          JobVisit.create(
            startAt: cursor,
            durationMinutes: job.durationMinutes,
          ),
        );
      }
      await JobService.saveVisits(
        job.id,
        visits,
        defaultDuration: job.durationMinutes,
      );
      final duration = idx >= 0
          ? visits[idx].durationMinutes
          : job.durationMinutes;
      cursor = cursor.add(Duration(minutes: duration + buffer));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Время заявок расставлено по маршруту'.tr),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _moveStop(int from, int to) {
    if (to < 0 || to >= _orderedJobs.length || from == to) return;
    HapticFeedback.selectionClick();
    setState(() {
      final job = _orderedJobs.removeAt(from);
      _orderedJobs.insert(to, job);
    });
    _recomputeForManualOrder();
  }

  Future<void> _recomputeForManualOrder() async {
    if (_origin == null || _orderedJobs.isEmpty) return;
    setState(() => _recomputing = true);

    final route = await MapsService.getOptimizedRoute(
      origin: _origin!,
      addresses: _orderedJobs.map((j) => j.workAddress).toList(),
      optimize: false,
    );

    if (!mounted) return;
    if (route != null) {
      _route = route;
      await _buildMarkersAndPolylines();
    }
    if (!mounted) return;
    _notifyChrome();
    setState(() => _recomputing = false);
  }

  Future<void> _buildMarkersAndPolylines() async {
    if (_route == null || _origin == null) return;

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('origin'),
        position: _origin!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        infoWindow: InfoWindow(title: 'Вы здесь'.tr),
      ),
    };

    for (
      var i = 0;
      i < _orderedJobs.length && i < _route!.stopLocations.length;
      i++
    ) {
      final job = _orderedJobs[i];
      final icon = await _createNumberedMarker(i + 1, _statusColorFor(job));
      markers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: _route!.stopLocations[i],
          icon: icon,
          infoWindow: InfoWindow(
            title: '${i + 1}. ${job.clientName}',
            snippet: job.workAddress,
          ),
        ),
      );
    }

    final polylines = <Polyline>{
      Polyline(
        polylineId: const PolylineId('route'),
        points: _route!.polylinePoints,
        color: AppColors.primary,
        width: 4,
      ),
    };

    if (!mounted) return;
    setState(() {
      _markers = markers;
      _polylines = polylines;
    });

    _fitBounds();
  }

  void _fitBounds() {
    if (_mapController == null || _markers.isEmpty) return;

    double? minLat, maxLat, minLng, maxLng;
    for (final m in _markers) {
      final lat = m.position.latitude;
      final lng = m.position.longitude;
      minLat = (minLat == null) ? lat : (lat < minLat ? lat : minLat);
      maxLat = (maxLat == null) ? lat : (lat > maxLat ? lat : maxLat);
      minLng = (minLng == null) ? lng : (lng < minLng ? lng : minLng);
      maxLng = (maxLng == null) ? lng : (lng > maxLng ? lng : maxLng);
    }
    if (minLat == null) return;

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng!),
      northeast: LatLng(maxLat!, maxLng!),
    );

    Future.delayed(const Duration(milliseconds: 200), () {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    });
  }

  Color _statusColorFor(Job job) {
    final visit = job.visitOn(widget.day);
    return StatusService.colorOf(job.displayStatusForVisit(visit));
  }

  Widget _mapAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(icon, color: AppColors.primary, size: 22),
          ),
        ),
      ),
    );
  }

  Future<BitmapDescriptor> _createNumberedMarker(
    int number,
    Color color,
  ) async {
    const double size = 50;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final fillPaint = Paint()..color = color;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, fillPaint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 2,
      borderPaint,
    );

    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);
    textPainter.text = TextSpan(
      text: '$number',
      style: const TextStyle(
        fontSize: 22,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((size - textPainter.width) / 2, (size - textPainter.height) / 2),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_off, size: 56, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadRoute,
                icon: const Icon(Icons.refresh),
                label: Text('Попробовать снова'.tr),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_orderedJobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Нет запланированных заявок на эту дату\nс указанным адресом.'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_skippedCount > 0)
          Container(
            width: double.infinity,
            color: Colors.orange.withOpacity(0.12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '$_skippedCount ${'заявок без адреса не включены в маршрут'.tr}',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
        SizedBox(
          height: 260,
          child: Stack(
            children: [
              GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _origin ?? const LatLng(43.6532, -79.3832),
                  zoom: 12,
                ),
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                zoomControlsEnabled: false,
                onMapCreated: (controller) {
                  _mapController = controller;
                  _fitBounds();
                },
              ),
              if (_recomputing)
                Container(
                  color: Colors.black26,
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  ),
                ),
              Positioned(
                right: 10,
                top: 10,
                child: Column(
                  children: [
                    _mapAction(
                      icon: Icons.map_outlined,
                      tooltip: 'Открыть в Google Maps'.tr,
                      onTap: () {
                        MapsService.openRouteInMaps(
                          _orderedJobs.map((j) => j.workAddress).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    _mapAction(
                      icon: Icons.schedule,
                      tooltip: 'Расставить время по маршруту'.tr,
                      onTap: _applyTimesFromRoute,
                    ),
                    const SizedBox(height: 8),
                    _mapAction(
                      icon: Icons.refresh,
                      tooltip: 'Оптимизировать заново'.tr,
                      onTap: _loadRoute,
                    ),
                  ],
                ),
              ),
              if (_route?.totalDistanceText != null)
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _route!.totalDistanceText,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _buildStopsList()),
      ],
    );
  }

  Widget _buildStopsList() {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      header: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(
          'Зажмите карточку, чтобы поменять порядок остановок'.tr,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ),
      itemCount: _orderedJobs.length,
      proxyDecorator: (child, _, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(animation.value);
            return Material(
              elevation: 1 + 8 * t,
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              shadowColor: Colors.black26,
              child: child,
            );
          },
        );
      },
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        _moveStop(oldIndex, newIndex);
      },
      itemBuilder: (context, index) => _buildStopCard(index),
    );
  }

  Widget _buildStopCard(int index) {
    final job = _orderedJobs[index];
    final visit = job.visitOn(widget.day);
    final legDistance = _route != null && index < _route!.legDistances.length
        ? _route!.legDistances[index]
        : null;
    final legDuration = _route != null && index < _route!.legDurations.length
        ? _route!.legDurations[index]
        : null;
    final footer = [
      if (legDistance != null && legDistance.isNotEmpty) legDistance,
      if (legDuration != null && legDuration.isNotEmpty) legDuration,
    ].join(' · ');

    return ReorderableDelayedDragStartListener(
      key: ValueKey(job.id),
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: JobAgendaCard(
          job: job,
          visit: visit,
          routeIndex: index + 1,
          routeIndexColor: _statusColorFor(job),
          footer: footer.isEmpty ? null : footer,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => JobDetailsScreen(
                  jobId: job.id,
                  clientId: job.clientId,
                  jobData: job.toMap(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
