import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firestore_service.dart';

/// Очередь изменений заявок и фото, если в поле нет сети.
class OfflineQueueService {
  static const _key = 'offline_ops_v1';
  static bool _flushing = false;

  static Future<void> enqueueJobUpdate(
    String jobId,
    Map<String, dynamic> data,
  ) async {
    await _add({
      'type': 'jobUpdate',
      'jobId': jobId,
      'data': _jsonSafe(data),
    });
  }

  static Future<void> enqueuePhoto({
    required String jobId,
    required String localPath,
    required String fileName,
  }) async {
    await _add({
      'type': 'photo',
      'jobId': jobId,
      'localPath': localPath,
      'fileName': fileName,
    });
  }

  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final remaining = <Map<String, dynamic>>[];
      for (final op in _read(prefs)) {
        final ok = await _run(op);
        if (!ok) remaining.add(op);
      }
      await prefs.setString(_key, jsonEncode(remaining));
    } finally {
      _flushing = false;
    }
  }

  static List<Map<String, dynamic>> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _add(Map<String, dynamic> op) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _read(prefs)..add(op);
    await prefs.setString(_key, jsonEncode(list));
  }

  static Future<bool> _run(Map<String, dynamic> op) async {
    try {
      final type = op['type'];
      if (type == 'jobUpdate') {
        final jobId = op['jobId'] as String;
        final data = Map<String, dynamic>.from(op['data'] as Map);
        await FirestoreService.jobsRef.doc(jobId).update({
          ...data,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      }
      if (type == 'photo') {
        final jobId = op['jobId'] as String;
        final localPath = op['localPath'] as String;
        final fileName = op['fileName'] as String;
        final file = File(localPath);
        if (!file.existsSync()) return true;
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('jobs/$jobId/attachments/$fileName');
        await storageRef.putFile(file);
        final url = await storageRef.getDownloadURL();
        await FirestoreService.jobsRef.doc(jobId).update({
          'attachments': FieldValue.arrayUnion([
            {
              'url': url,
              'name': fileName,
              'uploadedAt': DateTime.now().toIso8601String(),
            },
          ]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      }
    } catch (e) {
      debugPrint('OfflineQueue flush failed: $e');
    }
    return false;
  }

  static Map<String, dynamic> _jsonSafe(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((key, value) {
      if (value is FieldValue) return;
      out[key] = _jsonValue(value);
    });
    return out;
  }

  static dynamic _jsonValue(dynamic value) {
    if (value is DateTime) return value.toIso8601String();
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is Map) {
      return _jsonSafe(Map<String, dynamic>.from(value));
    }
    if (value is List) {
      return [
        for (final item in value)
          if (item is Map)
            _jsonSafe(Map<String, dynamic>.from(item))
          else
            _jsonValue(item),
      ];
    }
    return value;
  }
}
