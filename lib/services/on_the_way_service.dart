import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/job.dart';
import '../core/constants.dart';
import 'job_service.dart';
import 'local_notification_service.dart';
import 'maps_service.dart';
import 'settings_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';
import '../core/l10n/app_locale.dart';

class OnTheWayOffer {
  final Job fromJob;
  final Job nextJob;

  const OnTheWayOffer({required this.fromJob, required this.nextJob});
}

/// После визита: отъехали на 2 км — спрашиваем, отправить ли SMS следующему.
class OnTheWayService extends ChangeNotifier {
  static final OnTheWayService instance = OnTheWayService._();
  OnTheWayService._();

  static const _arriveMeters = 180.0;

  StreamSubscription<Position>? _sub;
  List<Job> _todayJobs = [];
  List<Job> _remaining = [];
  List<Job> _previousRemaining = [];
  final Map<String, LatLng> _coords = {};
  Job? _originJob;
  LatLng? _originCoord;
  Position? _lastPosition;
  String _dayKey = '';
  final Set<String> _prompted = {};
  final Set<String> _statusPrompted = {};
  OnTheWayOffer? pending;
  Job? pendingStatus;
  bool _starting = false;
  double _leaveMeters = 2000;
  bool _smsPromptEnabled = true;

  Future<void> sync(List<Job> allJobs) async {
    final config = await SettingsService.loadConfig();
    _leaveMeters = SettingsService.readOnTheWayMeters(config).toDouble();
    _smsPromptEnabled = SettingsService.boolFlag(config, 'onTheWayPromptEnabled');

    final today = DateTime.now();
    final key = '${today.year}-${today.month}-${today.day}';
    _todayJobs = JobService.activeForDay(allJobs, today);

    if (key != _dayKey) {
      _dayKey = key;
      _originJob = null;
      _originCoord = null;
      _prompted.clear();
      _statusPrompted.clear();
      pending = null;
      pendingStatus = null;
      _previousRemaining = [];
      await _loadDayState();
    }

    final remaining = JobService.activeForDay(allJobs, today).where((job) {
      final visit = job.visitOn(today);
      return visit == null || !visit.isDone;
    }).toList();
    for (final old in _previousRemaining) {
      final stillOpen = remaining.any((job) => job.id == old.id);
      if (!stillOpen) {
        _setOrigin(old, coord: _coordFromLastGps() ?? _coords[old.id]);
      }
    }
    _previousRemaining = List<Job>.from(remaining);
    _remaining = remaining;

    await _ensureCoords(_todayJobs);
    await _restoreOriginIfNeeded();

    if (_originJob != null && _originCoord == null) {
      _originCoord = _coords[_originJob!.id];
    }

    if (remaining.isEmpty) {
      _originJob = null;
      _originCoord = null;
      await _saveDayState();
      await stop();
      return;
    }
    if (pending != null || pendingStatus != null) {
      notifyListeners();
    }
    await start();
  }

  Future<void> start() async {
    if (_sub != null || _starting) return;
    _starting = true;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final allowed = await Geolocator.checkPermission();
      if (allowed == LocationPermission.denied ||
          allowed == LocationPermission.deniedForever) {
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;

      _sub = Geolocator.getPositionStream(
        locationSettings: defaultTargetPlatform == TargetPlatform.android
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 80,
                intervalDuration: const Duration(seconds: 20),
                foregroundNotificationConfig: ForegroundNotificationConfig(
                  notificationTitle: 'Fix Appliance',
                  notificationText:
                      'Когда отъедете, спросим статус заявки и SMS следующему клиенту'.tr,
                  notificationChannelName: 'Маршрут'.tr,
                  enableWakeLock: true,
                  setOngoing: true,
                ),
              )
            : const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 80,
              ),
      ).listen(_onPosition, onError: (_) {});
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    var changed = false;
    if (pending != null) {
      pending = null;
      changed = true;
    }
    if (pendingStatus != null) {
      pendingStatus = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> dismissPending() async {
    final offer = pending;
    if (offer != null) {
      _prompted.add(offer.nextJob.id);
      await _saveDayState();
    }
    pending = null;
    notifyListeners();
  }

  Future<void> dismissStatusPrompt() async {
    final job = pendingStatus;
    pendingStatus = null;
    if (job != null) {
      _statusPrompted.add(job.id);
    }
    await _saveDayState();
    notifyListeners();
    if (job != null) await _offerSmsIfNeeded(job);
  }

  Future<bool> sendPendingSms() async {
    final offer = pending;
    if (offer == null) return false;
    final phone = offer.nextJob.contactPhone.trim();
    if (phone.isEmpty) return false;
    final templates = await SettingsService.loadSmsTemplates();
    final config = await SettingsService.loadConfig();
    final custom = SettingsService.readOnTheWayText(config);
    final body = (custom.isNotEmpty
            ? custom
            : (templates['on_way'] ??
                'Здравствуйте, это мастер. Буду у вас через 30 минут.'.tr))
        .trim();
    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: offer.nextJob.clientId,
    );
    if (ok) {
      _prompted.add(offer.nextJob.id);
      await _saveDayState();
      pending = null;
      notifyListeners();
    }
    return ok;
  }

  void _setOrigin(Job job, {LatLng? coord}) {
    _originJob = job;
    _originCoord = coord ?? _coords[job.id];
    unawaited(_saveDayState());
  }

  LatLng? _coordFromLastGps() {
    final pos = _lastPosition;
    if (pos == null) return null;
    return LatLng(pos.latitude, pos.longitude);
  }

  Future<void> _onPosition(Position position) async {
    _lastPosition = position;
    if (pending != null || pendingStatus != null) return;
    if (TwilioService.activeCall != null) return;

    Job? nearest;
    var nearestMeters = double.infinity;
    for (final job in _remaining) {
      final coord = _coords[job.id];
      if (coord == null) continue;
      final meters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        coord.latitude,
        coord.longitude,
      );
      if (meters < nearestMeters) {
        nearestMeters = meters;
        nearest = job;
      }
    }

    if (nearest != null && nearestMeters <= _arriveMeters) {
      _setOrigin(
        nearest,
        coord: LatLng(position.latitude, position.longitude),
      );
      return;
    }

    final origin = _originJob;
    final originCoord =
        _originCoord ?? (origin != null ? _coords[origin.id] : null);
    if (origin == null || originCoord == null) return;

    final leftMeters = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      originCoord.latitude,
      originCoord.longitude,
    );
    if (leftMeters < _leaveMeters) return;

    _originJob = null;
    _originCoord = null;
    await _saveDayState();
    await _onLeftClient(origin);
  }

  Future<void> _onLeftClient(Job left) async {
    if (!JobStatuses.isClosed(left.status) &&
        !_statusPrompted.contains(left.id)) {
      pendingStatus = left;
      notifyListeners();
      await _saveDayState();
      await LocalNotificationService.showLeaveStatus(
        title: 'Изменить статус заявки?'.tr,
        body: AppLocale.instance.isEn
            ? '${left.contactName} · ${left.applianceType} — now “${left.status}”'
            : '${left.contactName} · ${left.applianceType} — сейчас «${left.status}»',
        jobId: left.id,
      );
      return;
    }
    await _offerSmsIfNeeded(left);
  }

  Future<void> _offerSmsIfNeeded(Job left) async {
    if (!_smsPromptEnabled) return;
    if (pending != null || pendingStatus != null) return;
    final next = _nextJob(left);
    if (next == null) return;
    if (_prompted.contains(next.id)) return;
    if (next.contactPhone.trim().isEmpty) return;

    pending = OnTheWayOffer(fromJob: left, nextJob: next);
    notifyListeners();
    await _saveDayState();
    await LocalNotificationService.showOnTheWay(
      title: 'Отправить, что вы едете?'.tr,
      body: AppLocale.instance.isEn
          ? 'Send ${next.contactName} a message that you are on the way?'
          : 'Хотите отправить ${next.contactName} уведомление, что вы в пути?',
      jobId: next.id,
    );
  }

  Job? _nextJob(Job left) {
    final today = DateTime.now();
    final rest = _remaining.where((job) {
      if (job.id == left.id) return false;
      if (_prompted.contains(job.id)) return false;
      final visit = job.visitOn(today);
      if (visit != null && visit.isDone) return false;
      return true;
    }).toList();
    if (rest.isEmpty) return null;
    rest.sort((a, b) {
      final leftTime = a.visitOn(today)?.startAt ?? a.scheduledAt ?? DateTime(0);
      final rightTime = b.visitOn(today)?.startAt ?? b.scheduledAt ?? DateTime(0);
      return leftTime.compareTo(rightTime);
    });
    final leftTime = left.visitOn(today)?.startAt ?? left.scheduledAt;
    if (leftTime == null) return rest.first;
    final after = rest.where((job) {
      final time = job.visitOn(today)?.startAt ?? job.scheduledAt;
      return time != null && time.isAfter(leftTime);
    }).toList();
    return after.isEmpty ? null : after.first;
  }

  Job? _jobById(String id) {
    for (final job in _todayJobs) {
      if (job.id == id) return job;
    }
    for (final job in _remaining) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<void> _ensureCoords(Iterable<Job> jobs) async {
    for (final job in jobs) {
      if (_coords.containsKey(job.id)) continue;
      if (job.workAddress.trim().isEmpty) continue;
      final coord = await MapsService.geocodeAddress(job.workAddress);
      if (coord != null) _coords[job.id] = coord;
    }
  }

  Future<void> _restoreOriginIfNeeded() async {
    if (_originJob != null) return;
    final prefs = await SharedPreferences.getInstance();
    final originId = prefs.getString('on_way_origin_id_$_dayKey');
    if (originId == null || originId.isEmpty) return;
    final job = _jobById(originId);
    if (job == null) return;
    _originJob = job;
    final lat = prefs.getDouble('on_way_origin_lat_$_dayKey');
    final lng = prefs.getDouble('on_way_origin_lng_$_dayKey');
    if (lat != null && lng != null) {
      _originCoord = LatLng(lat, lng);
    }
  }

  Future<void> _loadDayState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('on_way_prompted_$_dayKey') ?? const [];
    _prompted
      ..clear()
      ..addAll(raw);
    final statusRaw =
        prefs.getStringList('on_way_status_prompted_$_dayKey') ?? const [];
    _statusPrompted
      ..clear()
      ..addAll(statusRaw);
    await _restoreOriginIfNeeded();
    await _restorePendingIfNeeded(prefs);
  }

  Future<void> _restorePendingIfNeeded(SharedPreferences prefs) async {
    final statusId = prefs.getString('on_way_pending_status_$_dayKey') ?? '';
    if (statusId.isNotEmpty) {
      pendingStatus = _jobById(statusId);
    }
    final nextId = prefs.getString('on_way_pending_sms_next_$_dayKey') ?? '';
    final fromId = prefs.getString('on_way_pending_sms_from_$_dayKey') ?? '';
    if (nextId.isNotEmpty && fromId.isNotEmpty) {
      final next = _jobById(nextId);
      final from = _jobById(fromId);
      if (next != null && from != null) {
        pending = OnTheWayOffer(fromJob: from, nextJob: next);
      }
    }
  }

  Future<void> _saveDayState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('on_way_prompted_$_dayKey', _prompted.toList());
    await prefs.setStringList(
      'on_way_status_prompted_$_dayKey',
      _statusPrompted.toList(),
    );
    final status = pendingStatus;
    if (status == null) {
      await prefs.remove('on_way_pending_status_$_dayKey');
    } else {
      await prefs.setString('on_way_pending_status_$_dayKey', status.id);
    }
    final offer = pending;
    if (offer == null) {
      await prefs.remove('on_way_pending_sms_next_$_dayKey');
      await prefs.remove('on_way_pending_sms_from_$_dayKey');
    } else {
      await prefs.setString('on_way_pending_sms_next_$_dayKey', offer.nextJob.id);
      await prefs.setString('on_way_pending_sms_from_$_dayKey', offer.fromJob.id);
    }
    final origin = _originJob;
    if (origin == null) {
      await prefs.remove('on_way_origin_id_$_dayKey');
      await prefs.remove('on_way_origin_lat_$_dayKey');
      await prefs.remove('on_way_origin_lng_$_dayKey');
      return;
    }
    await prefs.setString('on_way_origin_id_$_dayKey', origin.id);
    final coord = _originCoord;
    if (coord != null) {
      await prefs.setDouble('on_way_origin_lat_$_dayKey', coord.latitude);
      await prefs.setDouble('on_way_origin_lng_$_dayKey', coord.longitude);
    }
  }
}
