import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_keys.dart';
import '../core/constants.dart';
import 'import_export_service.dart';

class BackupFile {
  final File file;
  final DateTime createdAt;
  final int bytes;

  const BackupFile({
    required this.file,
    required this.createdAt,
    required this.bytes,
  });

  String get name => file.uri.pathSegments.last;
}

/// Копия, которую сервер каждую неделю кладёт в Firebase Storage.
class CloudBackup {
  final DateTime createdAt;
  final String url;
  final int bytes;
  final int totalDocs;

  const CloudBackup({
    required this.createdAt,
    required this.url,
    required this.bytes,
    required this.totalDocs,
  });

  static CloudBackup? fromMap(String id, Map<String, dynamic> data) {
    final url = (data['url'] ?? '').toString();
    if (url.isEmpty) return null;
    final raw = data['createdAt'];
    final created = raw is Timestamp
        ? raw.toDate()
        : DateTime.tryParse('$raw') ?? DateTime.tryParse(id);
    if (created == null) return null;
    return CloudBackup(
      createdAt: created,
      url: url,
      bytes: (data['bytes'] as num?)?.toInt() ?? 0,
      totalDocs: (data['totalDocs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Автокопия базы на сам телефон. Firestore и так в облаке, но копия спасает,
/// если что-то удалили или испортили импортом.
class BackupService {
  static const _kIntervalDays = 'autoBackupDays';
  static const _kLastAt = 'autoBackupLastAt';
  static const int keepCount = 5;

  /// 0 — автокопия выключена.
  static const List<int> intervalOptions = [0, 1, 7, 30];

  static Future<int> intervalDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kIntervalDays) ?? 7;
  }

  static Future<void> setIntervalDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIntervalDays, days);
  }

  static Future<DateTime?> lastBackupAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Полный путь к папке с копиями — показываем его на экране «Копия».
  static Future<String> folderPath() async {
    try {
      return (await _dir()).path;
    } catch (error) {
      debugPrint('Backup folder: $error');
      return '';
    }
  }

  static String _stamp(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}';
  }

  static Future<BackupFile?> createNow() async {
    try {
      final json = await ImportExportService.buildBackupJson();
      final dir = await _dir();
      final now = DateTime.now();
      final file = File('${dir.path}/fix_backup_${_stamp(now)}.json');
      await file.writeAsString(json, flush: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastAt, now.toIso8601String());
      await _prune();
      return BackupFile(
        file: file,
        createdAt: now,
        bytes: await file.length(),
      );
    } catch (error) {
      debugPrint('Backup create: $error');
      return null;
    }
  }

  static Future<List<BackupFile>> list() async {
    try {
      final dir = await _dir();
      final files = <BackupFile>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final stat = await entity.stat();
        files.add(
          BackupFile(
            file: entity,
            createdAt: stat.modified,
            bytes: stat.size,
          ),
        );
      }
      files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return files;
    } catch (error) {
      debugPrint('Backup list: $error');
      return const [];
    }
  }

  static Future<void> _prune() async {
    final files = await list();
    for (final old in files.skip(keepCount)) {
      try {
        await old.file.delete();
      } catch (_) {}
    }
  }

  static Future<void> delete(BackupFile backup) async {
    try {
      await backup.file.delete();
    } catch (error) {
      debugPrint('Backup delete: $error');
    }
  }

  static Future<void> share(BackupFile backup) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            backup.file.path,
            mimeType: 'application/json',
            name: backup.name,
          ),
        ],
        title: backup.name,
        text: backup.name,
      ),
    );
  }

  /// Вызывается на старте приложения: копию делаем, только если пришёл срок.
  static Future<void> runIfDue() async {
    try {
      final days = await intervalDays();
      if (days <= 0) return;
      final last = await lastBackupAt();
      if (last != null && DateTime.now().difference(last).inDays < days) return;
      await createNow();
    } catch (error) {
      debugPrint('Backup schedule: $error');
    }
  }

  // ---------------------------------------------------------------- облако

  /// Копии, которые сервер делает по воскресеньям. Телефон при этом может быть
  /// выключен — их пишет `weeklyCloudBackup`, а не приложение.
  static Stream<List<CloudBackup>> watchCloud() {
    return FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('backups')
        .snapshots()
        .map((snapshot) {
      final items = <CloudBackup>[];
      for (final doc in snapshot.docs) {
        final item = CloudBackup.fromMap(doc.id, doc.data());
        if (item != null) items.add(item);
      }
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    });
  }

  /// Просит сервер сделать копию прямо сейчас.
  static Future<CloudBackup?> createCloudNow() async {
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/runCloudBackupNow'),
            headers: const {'Content-Type': 'application/json'},
            body: '{}',
          )
          .timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        debugPrint('Cloud backup: HTTP ${response.statusCode}');
        return null;
      }
      final body = json.decode(response.body) as Map<String, dynamic>;
      if (body['success'] != true) return null;
      return CloudBackup.fromMap('', body);
    } catch (error) {
      debugPrint('Cloud backup: $error');
      return null;
    }
  }

  static Future<void> openCloud(CloudBackup backup) async {
    final uri = Uri.tryParse(backup.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
