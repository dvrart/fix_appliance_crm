import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import 'firestore_service.dart';

class JobStatusDef {
  final String id;
  final String label;
  final int colorValue;
  final bool builtin;

  const JobStatusDef({
    required this.id,
    required this.label,
    required this.colorValue,
    required this.builtin,
  });

  Color get color => Color(colorValue);

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'color': colorValue,
    'builtin': builtin,
  };

  JobStatusDef copyWith({String? label, int? colorValue}) {
    return JobStatusDef(
      id: id,
      label: label ?? this.label,
      colorValue: colorValue ?? this.colorValue,
      builtin: builtin,
    );
  }
}

/// Статусы заявок: название, цвет, свои статусы. Базовые id не меняются.
class StatusService {
  static DocumentReference get _ref =>
      FirestoreService.settingsRef.doc('job_statuses');

  static const List<String> builtins = JobStatuses.all;

  static const Map<String, int> _builtinColors = {
    JobStatuses.call: 0xFF1E88E5,
    JobStatuses.inProgress: 0xFFFCC520,
    JobStatuses.rescheduled: 0xFF7E57C2,
    JobStatuses.waitingPart: 0xFFFB8C00,
    JobStatuses.install: 0xFF3F51B5,
    JobStatuses.callBack: 0xFF00897B,
    JobStatuses.repeat: 0xFF8E24AA,
    JobStatuses.completed: 0xFF43A047,
    JobStatuses.cancelled: 0xFFE53935,
  };

  static const List<int> extraPalette = [
    0xFF00897B,
    0xFF8E24AA,
    0xFF3949AB,
    0xFF6D4C41,
    0xFF00ACC1,
    0xFFE64A19,
    0xFF5E35B1,
    0xFF2E7D32,
    0xFF3F51B5,
    0xFF1565C0,
  ];

  static List<JobStatusDef> _cache = [
    for (final id in builtins)
      JobStatusDef(
        id: id,
        label: JobStatuses.defaultLabel(id),
        colorValue: _builtinColors[id] ?? 0xFF14557F,
        builtin: true,
      ),
  ];

  static Future<void>? _seedFuture;

  static bool isBuiltin(String status) => builtins.contains(status);

  static Color colorOf(String status) {
    for (final item in _cache) {
      if (item.id == status || item.label == status) return item.color;
    }
    return JobStatuses.fallbackColor(status);
  }

  static String labelOf(String status) {
    for (final item in _cache) {
      if (item.id == status || item.label == status) return item.label;
    }
    return status;
  }

  static Future<void> _ensureSeeded() {
    _seedFuture ??= _seed();
    return _seedFuture!;
  }

  static Future<void> _seed() async {
    try {
      final snap = await _ref.get();
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null || data['items'] == null) {
        await _ref.set({
          'items': [
            for (final id in builtins)
              {
                'id': id,
                'label': JobStatuses.defaultLabel(id),
                'color': _builtinColors[id] ?? 0xFF14557F,
                'builtin': true,
              },
          ],
        }, SetOptions(merge: true));
      } else {
        final parsed = _parse(data['items']);
        if (_needsPersist(data['items'], parsed)) {
          await _ref.set({
            'items': [for (final item in parsed) item.toMap()],
          }, SetOptions(merge: true));
        }
      }
    } catch (_) {}
  }

  static List<JobStatusDef> _parse(dynamic raw) {
    final byId = <String, JobStatusDef>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is String) {
          final id = item.trim();
          if (id.isEmpty) continue;
          byId[id] = JobStatusDef(
            id: id,
            label: JobStatuses.defaultLabel(id),
            colorValue:
                _builtinColors[id] ?? JobStatuses.fallbackColor(id).toARGB32(),
            builtin: builtins.contains(id),
          );
        } else if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final id = (map['id'] ?? map['name'] ?? map['label'] ?? '')
              .toString()
              .trim();
          if (id.isEmpty) continue;
          final colorRaw = map['color'];
          final colorValue = colorRaw is int
              ? colorRaw
              : (colorRaw is num
                    ? colorRaw.toInt()
                    : (_builtinColors[id] ??
                          JobStatuses.fallbackColor(id).toARGB32()));
          byId[id] = JobStatusDef(
            id: id,
            label: (map['label'] ?? map['name'] ?? id).toString().trim().isEmpty
                ? id
                : (map['label'] ?? map['name'] ?? id).toString().trim(),
            colorValue: colorValue,
            builtin: map['builtin'] == true || builtins.contains(id),
          );
        }
      }
    }
    byId.remove(JobStatuses.inProgress);
    final result = <JobStatusDef>[];
    for (final id in builtins) {
      result.add(
        _normalizeBuiltin(
          byId.remove(id) ??
              JobStatusDef(
                id: id,
                label: JobStatuses.defaultLabel(id),
                colorValue: _builtinColors[id] ?? 0xFF14557F,
                builtin: true,
              ),
        ),
      );
    }
    result.addAll(byId.values);
    return result;
  }

  static bool _isOldInstallPink(int value) {
    return value == 0xFFD81B60 ||
        value == 0xD81B60 ||
        (value & 0x00FFFFFF) == 0xD81B60;
  }

  static JobStatusDef _normalizeBuiltin(JobStatusDef item) {
    if (item.id == JobStatuses.completed) {
      if (item.label.trim().isEmpty ||
          item.label == JobStatuses.completed ||
          JobStatuses.isInstallStatus(item.label)) {
        return item.copyWith(
          label: JobStatuses.defaultLabel(JobStatuses.completed),
        );
      }
    }
    if (item.id == JobStatuses.cancelled) {
      if (item.label.trim().isEmpty || item.label == JobStatuses.cancelled) {
        return item.copyWith(
          label: JobStatuses.defaultLabel(JobStatuses.cancelled),
        );
      }
    }
    if (item.id == JobStatuses.repeat) {
      if (item.label.trim().isEmpty || item.label == JobStatuses.repeat) {
        return item.copyWith(
          label: JobStatuses.defaultLabel(JobStatuses.repeat),
        );
      }
    }
    if (item.id == JobStatuses.install && _isOldInstallPink(item.colorValue)) {
      return item.copyWith(colorValue: _builtinColors[JobStatuses.install]!);
    }
    return item;
  }

  static bool _needsPersist(dynamic raw, List<JobStatusDef> parsed) {
    if (raw is List && raw.any((item) => item is String)) return true;
    final rawIds = <String>{};
    var completedLooksLikeInstall = false;
    var repeatNeedsRename = false;
    var installNeedsRecolor = false;
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final id = (map['id'] ?? map['name'] ?? map['label'] ?? '')
              .toString();
          rawIds.add(id);
          final label = (map['label'] ?? map['name'] ?? id).toString();
          if (id == JobStatuses.completed &&
              (JobStatuses.isInstallStatus(label) ||
                  label == JobStatuses.completed)) {
            completedLooksLikeInstall = true;
          }
          if (id == JobStatuses.repeat &&
              (label.trim().isEmpty || label == JobStatuses.repeat)) {
            repeatNeedsRename = true;
          }
          if (id == JobStatuses.install) {
            final colorRaw = map['color'];
            final colorValue = colorRaw is int
                ? colorRaw
                : (colorRaw is num ? colorRaw.toInt() : 0xFFD81B60);
            if (_isOldInstallPink(colorValue)) installNeedsRecolor = true;
          }
        } else if (item is String) {
          rawIds.add(item);
        }
      }
    }
    if (completedLooksLikeInstall) return true;
    if (repeatNeedsRename) return true;
    if (installNeedsRecolor) return true;
    if (rawIds.contains(JobStatuses.inProgress)) return true;
    if (!rawIds.contains(JobStatuses.install)) return true;
    if (!rawIds.contains(JobStatuses.callBack)) return true;
    if (!rawIds.contains(JobStatuses.repeat)) return true;
    final parsedIds = {for (final item in parsed) item.id};
    if (!parsedIds.contains(JobStatuses.install)) return true;
    if (!parsedIds.contains(JobStatuses.callBack)) return true;
    if (!parsedIds.contains(JobStatuses.repeat)) return true;
    return false;
  }

  static List<String> idsForStatusMenu(List<String> ids, {String? current}) {
    final result = <String>[];
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) continue;
      if (id == current) {
        result.add(id);
        continue;
      }
      if (JobStatuses.hideFromPicker.contains(id)) continue;
      if (JobStatuses.isPickerAlias(id)) continue;
      result.add(id);
    }
    return result;
  }

  static void _remember(List<JobStatusDef> items) {
    _cache = items;
  }

  static Stream<List<String>> streamAll() {
    return streamDefs().map((items) => [for (final item in items) item.id]);
  }

  static Stream<List<JobStatusDef>> streamDefs() {
    _ensureSeeded();
    return _ref.snapshots().map((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      final items = _parse(data?['items']);
      _remember(items);
      return items;
    });
  }

  static Future<List<String>> loadOnce() async {
    final items = await loadDefsOnce();
    return [for (final item in items) item.id];
  }

  static Future<List<JobStatusDef>> loadDefsOnce() async {
    await _ensureSeeded();
    final snap = await _ref.get();
    final data = snap.data() as Map<String, dynamic>?;
    final items = _parse(data?['items']);
    _remember(items);
    return items;
  }

  static Future<void> _save(List<JobStatusDef> items) async {
    _remember(items);
    await _ref.set({
      'items': [for (final item in items) item.toMap()],
    });
  }

  static Future<void> add(String status, {int? colorValue}) async {
    final trimmed = status.trim();
    if (trimmed.isEmpty) return;
    final items = await loadDefsOnce();
    if (items.any((item) => item.id == trimmed || item.label == trimmed))
      return;
    final used = {for (final item in items) item.colorValue};
    var color = colorValue ?? extraPalette.first;
    for (final candidate in extraPalette) {
      if (!used.contains(candidate)) {
        color = candidate;
        break;
      }
    }
    await _save([
      ...items,
      JobStatusDef(
        id: trimmed,
        label: trimmed,
        colorValue: color,
        builtin: false,
      ),
    ]);
  }

  static Future<void> remove(String status) async {
    if (isBuiltin(status)) return;
    final items = await loadDefsOnce();
    await _save([
      for (final item in items)
        if (item.id != status) item,
    ]);
  }

  static Future<void> rename(String from, String to) async {
    final next = to.trim();
    if (next.isEmpty || from == next) return;
    final items = await loadDefsOnce();
    await _save([
      for (final item in items)
        if (item.id == from) item.copyWith(label: next) else item,
    ]);
  }

  static Future<void> update({
    required String id,
    String? label,
    int? colorValue,
  }) async {
    final items = await loadDefsOnce();
    await _save([
      for (final item in items)
        if (item.id == id)
          item.copyWith(
            label: label?.trim().isEmpty == true
                ? item.label
                : (label ?? item.label),
            colorValue: colorValue,
          )
        else
          item,
    ]);
  }
}
