import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../models/job.dart';
import '../../services/services.dart';
import 'job_details/job_details_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/job_agenda_card.dart';

/// Режим сортировки остановок на экране маршрута.
enum RouteSortMode { time, distance, manual }

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

  /// Сортировка заявок по времени визита на выбранный день.
  /// Визиты с назначенным временем идут первыми по возрастанию времени,
  /// визиты без времени — после них.
  static List<Job> sortJobsByVisitTime(List<Job> jobs, DateTime day) {
    final originalPos = <String, int>{
      for (var i = 0; i < jobs.length; i++) jobs[i].id: i,
    };
    return [...jobs]..sort((a, b) {
      final va = a.visitOn(day);
      final vb = b.visitOn(day);
      final aTimed = va?.hasTime ?? false;
      final bTimed = vb?.hasTime ?? false;
      if (aTimed != bTimed) return aTimed ? -1 : 1;
      final ta = va?.startAt ?? DateTime(0);
      final tb = vb?.startAt ?? DateTime(0);
      final cmp = ta.compareTo(tb);
      if (cmp != 0) return cmp;
      return (originalPos[a.id] ?? 0).compareTo(originalPos[b.id] ?? 0);
    });
  }

  /// Применение сохранённого ручного порядка остановок.
  static List<Job> applyManualOrder(List<Job> jobs, List<String> savedIds) {
    if (savedIds.isEmpty) return [...jobs];
    final rank = <String, int>{
      for (var i = 0; i < savedIds.length; i++) savedIds[i]: i,
    };
    if (!jobs.any((j) => rank.containsKey(j.id))) return [...jobs];
    final originalPos = <String, int>{
      for (var i = 0; i < jobs.length; i++) jobs[i].id: i,
    };
    return [...jobs]..sort((a, b) {
      final ra = rank[a.id] ?? (100000 + (originalPos[a.id] ?? 0));
      final rb = rank[b.id] ?? (100000 + (originalPos[b.id] ?? 0));
      return ra.compareTo(rb);
    });
  }

  @override
  State<RouteMapView> createState() => _RouteMapViewState();
}

class _RouteMapViewState extends State<RouteMapView> {
  RouteSortMode _sortMode = RouteSortMode.time;
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

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
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
            openMaps: _openInMaps,
            refresh: _reoptimizeRoute,
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

  String _manualOrderKey(DateTime day) =>
      'routeManualOrder_${day.year}-${day.month}-${day.day}';

  String _jobsAddressSig(List<Job> jobs) {
    final entries = [
      for (final j in jobs)
        '${j.id}:${j.workAddress.trim()}:${_sortMode == RouteSortMode.time ? (j.visitOn(widget.day)?.startAt.millisecondsSinceEpoch ?? 0) : ''}',
    ]..sort();
    return entries.join('|');
  }

  Future<void> _saveManualOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _manualOrderKey(widget.day),
      [for (final job in _orderedJobs) job.id],
    );
  }

  Future<void> _reoptimizeRoute() async {
    await _loadRoute(keepMap: true);
  }

  Future<void> _selectSortMode(RouteSortMode mode) async {
    if (_sortMode == mode && !_loading && !_recomputing) return;
    HapticFeedback.selectionClick();
    setState(() {
      _sortMode = mode;
      if (mode == RouteSortMode.time && _orderedJobs.isNotEmpty) {
        _orderedJobs = RouteMapView.sortJobsByVisitTime(
          _orderedJobs,
          widget.day,
        );
      }
    });
    if (mode == RouteSortMode.manual) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final savedIds = prefs.getStringList(_manualOrderKey(widget.day));
      if (savedIds == null || savedIds.isEmpty) {
        await _saveManualOrder();
        return;
      }
    }
    await _loadRoute(keepMap: true);
  }

  @override
  void didUpdateWidget(RouteMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!JobVisit.isSameDay(oldWidget.day, widget.day) ||
        _jobsAddressSig(oldWidget.jobs) != _jobsAddressSig(widget.jobs)) {
      _loadRoute(keepMap: JobVisit.isSameDay(oldWidget.day, widget.day));
      return;
    }
    final paintChanged = _paintSig(oldWidget.jobs) != _paintSig(widget.jobs);
    _syncJobsFromWidget();
    if (paintChanged) {
      _buildMarkersAndPolylines();
    }
  }

  Future<void> _loadRoute({bool keepMap = false}) async {
    if (!mounted) return;
    final showOverlay = keepMap && !_loading && _orderedJobs.isNotEmpty;
    setState(() {
      if (showOverlay) {
        _recomputing = true;
      } else {
        _loading = true;
      }
      _error = null;
    });

    var jobsWithAddress = widget.jobs
        .where((j) => MapsService.hasRoutableAddress(j.workAddress))
        .toList();
    _skippedCount = widget.jobs.length - jobsWithAddress.length;

    if (_sortMode == RouteSortMode.time) {
      jobsWithAddress = RouteMapView.sortJobsByVisitTime(
        jobsWithAddress,
        widget.day,
      );
    } else if (_sortMode == RouteSortMode.manual && jobsWithAddress.length > 1) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final savedIds = prefs.getStringList(_manualOrderKey(widget.day));
      if (savedIds != null && savedIds.isNotEmpty) {
        jobsWithAddress = RouteMapView.applyManualOrder(
          jobsWithAddress,
          savedIds,
        );
      } else if (_orderedJobs.isNotEmpty) {
        jobsWithAddress = RouteMapView.applyManualOrder(
          jobsWithAddress,
          [for (final job in _orderedJobs) job.id],
        );
      }
    } else {
      jobsWithAddress = RouteMapView.sortJobsByVisitTime(
        jobsWithAddress,
        widget.day,
      );
    }

    _orderedJobs = jobsWithAddress;

    if (_orderedJobs.isEmpty) {
      _route = null;
      _notifyChrome();
      if (mounted) {
        setState(() {
          _loading = false;
          _recomputing = false;
        });
      }
      return;
    }

    final positionFuture = MapsService.getCurrentPosition();
    final placesFuture = Future.wait(
      _orderedJobs.map((j) => MapsService.resolvePlace(j.workAddress)),
    );
    final position = await positionFuture;
    final places = await placesFuture;
    if (!mounted) return;

    final routableJobs = <Job>[];
    final unresolvedJobs = <Job>[];
    final unresolvedLabels = <String>[];
    LatLng? firstResolvedPoint;
    for (var i = 0; i < _orderedJobs.length; i++) {
      final job = _orderedJobs[i];
      final point = places[i]?.location;
      if (point != null) {
        firstResolvedPoint ??= point;
        routableJobs.add(job);
      } else {
        unresolvedJobs.add(job);
        unresolvedLabels.add(
          '${i + 1}. ${job.clientName} (${job.workAddress.trim()})',
        );
      }
    }

    if (position != null) {
      _origin = LatLng(position.latitude, position.longitude);
    } else if (firstResolvedPoint != null) {
      _origin = firstResolvedPoint;
    } else {
      _origin = const LatLng(43.1394, -80.2644);
    }

    final unresolvedWarning = unresolvedLabels.isEmpty
        ? null
        : '${'Не найден адрес (укажите город)'.tr}: ${unresolvedLabels.join(', ')}';

    if (routableJobs.isEmpty) {
      _route = null;
      _markers = {
        Marker(
          markerId: const MarkerId('origin'),
          position: _origin!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueViolet,
          ),
          infoWindow: InfoWindow(title: 'Вы здесь'.tr),
        ),
      };
      _polylines = const {};
      _notifyChrome();
      setState(() {
        _loading = false;
        _recomputing = false;
        _error =
            unresolvedWarning ??
            '${'Не удалось построить маршрут.'.tr}\n${'Проверьте адреса заявок.'.tr}';
      });
      return;
    }

    final optimizeByDistance =
        _sortMode == RouteSortMode.distance && routableJobs.length > 1;
    final route = await MapsService.getOptimizedRoute(
      origin: _origin!,
      addresses: routableJobs.map((j) => j.workAddress).toList(),
      stopLabels: [
        for (var i = 0; i < routableJobs.length; i++)
          '${i + 1}. ${routableJobs[i].clientName} (${routableJobs[i].workAddress.trim()})',
      ],
      optimize: optimizeByDistance,
    );
    if (!mounted) return;

    if (route == null) {
      _route = null;
      _notifyChrome();
      setState(() {
        _loading = false;
        _recomputing = false;
        _error =
            '${'Не удалось построить маршрут.'.tr}\n'
            '${MapsService.lastRouteError ?? 'Проверьте адреса заявок.'.tr}';
      });
      return;
    }

    _route = route;
    final orderedRoutable = optimizeByDistance
        ? route.order.map((i) => routableJobs[i]).toList()
        : routableJobs;
    _orderedJobs = [...orderedRoutable, ...unresolvedJobs];
    _error = unresolvedWarning;
    await _buildMarkersAndPolylines();
    if (!mounted) return;
    _notifyChrome();
    setState(() {
      _loading = false;
      _recomputing = false;
    });
  }

  /// Google Maps берёт не больше девяти промежуточных точек — об остальных
  /// предупреждаем, иначе они молча выпадут из маршрута.
  Future<void> _openInMaps() async {
    final addresses = _orderedJobs.map((j) => j.workAddress).toList();
    final extra = addresses.length - (MapsService.maxMapsWaypoints + 1);
    final opened = await MapsService.openRouteInMaps(addresses);
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Google Maps не нашла эти адреса'.tr)),
      );
      return;
    }
    if (extra > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$extra ${'остановок не влезли в Google Maps — она берёт девять'.tr}',
          ),
        ),
      );
    }
  }

  Future<void> _applyTimesFromRoute() async {
    if (_orderedJobs.isEmpty) return;
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
      cursor = cursor.add(Duration(minutes: duration));
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
      _sortMode = RouteSortMode.manual;
      final job = _orderedJobs.removeAt(from);
      _orderedJobs.insert(to, job);
    });
    unawaited(_saveManualOrder());
    _recomputeForManualOrder();
  }

  Future<void> _recomputeForManualOrder() async {
    if (_origin == null || _orderedJobs.isEmpty) return;
    setState(() => _recomputing = true);

    final places = await Future.wait(
      _orderedJobs.map((j) => MapsService.resolvePlace(j.workAddress)),
    );
    if (!mounted) return;
    final routableJobs = <Job>[
      for (var i = 0; i < _orderedJobs.length; i++)
        if (places[i]?.location != null) _orderedJobs[i],
    ];
    final route = routableJobs.isEmpty
        ? null
        : await MapsService.getOptimizedRoute(
            origin: _origin!,
            addresses: routableJobs.map((j) => j.workAddress).toList(),
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
        if (_error != null)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.location_off, size: 18, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Попробовать снова'.tr,
                  onPressed: () => _loadRoute(keepMap: true),
                ),
              ],
            ),
          ),
        if (_skippedCount > 0)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.12),
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
                  target: _origin ?? const LatLng(43.1394, -80.2644),
                  zoom: 12,
                ),
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                zoomControlsEnabled: true,
                scrollGesturesEnabled: true,
                zoomGesturesEnabled: true,
                rotateGesturesEnabled: true,
                tiltGesturesEnabled: true,
                gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
                  Factory<OneSequenceGestureRecognizer>(
                    EagerGestureRecognizer.new,
                  ),
                },
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
                left: 10,
                bottom: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _mapAction(
                      icon: Icons.map_outlined,
                      tooltip: 'Открыть в Google Maps'.tr,
                      onTap: _openInMaps,
                    ),
                    const SizedBox(width: 8),
                    _mapAction(
                      icon: Icons.schedule,
                      tooltip: 'Расставить время по маршруту'.tr,
                      onTap: _applyTimesFromRoute,
                    ),
                    const SizedBox(width: 8),
                    _mapAction(
                      icon: Icons.refresh,
                      tooltip: 'Оптимизировать заново'.tr,
                      onTap: _reoptimizeRoute,
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
        _buildSortBar(),
        Expanded(child: _buildStopsList()),
      ],
    );
  }

  Widget _buildSortBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            _buildSortOption(
              mode: RouteSortMode.time,
              icon: Icons.schedule,
              label: 'По времени'.tr,
            ),
            const SizedBox(width: 4),
            _buildSortOption(
              mode: RouteSortMode.distance,
              icon: Icons.route,
              label: 'По расстоянию'.tr,
            ),
            const SizedBox(width: 4),
            _buildSortOption(
              mode: RouteSortMode.manual,
              icon: Icons.drag_indicator_rounded,
              label: 'Вручную'.tr,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortOption({
    required RouteSortMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _sortMode == mode;
    final fg = selected ? Colors.white : AppColors.ink;
    return Expanded(
      child: Material(
        color: selected ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _selectSortMode(mode),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStopsList() {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      header: _sortMode == RouteSortMode.manual
          ? Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Text(
                'Зажмите карточку, чтобы поменять порядок остановок'.tr,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            )
          : null,
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
        padding: const EdgeInsets.only(bottom: 6),
        child: JobAgendaCard(
          job: job,
          visit: visit,
          forceCompact: true,
          routeIndex: index + 1,
          reorderIndex: index,
          routeIndexColor: _statusColorFor(job),
          footer: footer.isEmpty ? null : footer,
          onTap: () {
            AppNav.openCard(
              context,
              key: AppNav.jobKey(job.id),
              builder: (_) => JobDetailsScreen(
                jobId: job.id,
                clientId: job.clientId,
                jobData: job.toMap(),
              ),
            );
          },
        ),
      ),
    );
  }
}
