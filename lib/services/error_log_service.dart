import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

/// Журнал ошибок приложения.
///
/// Ошибка сначала ложится на телефон (переживает вылет), потом уезжает в
/// Firestore `companies/{id}/app_errors`. Оттуда её читает и экран
/// «Настройки → Данные → Ошибки», и агент в Cursor через `appErrors`.
class ErrorLogService {
  static const _kPending = 'error_log_pending_v1';
  static const _kSessionOpen = 'error_log_session_open_v1';
  static const _kLastScreen = 'error_log_last_screen_v1';
  static const int keepPending = 40;

  static String _screen = '';
  static String _version = '';
  static bool _installed = false;

  /// Куда смотрел мастер, когда всё сломалось. Ставится при открытии экрана.
  static void markScreen(String name) {
    _screen = name;
    unawaited(_rememberScreen(name));
  }

  static Future<void> _rememberScreen(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastScreen, name);
    } catch (_) {}
  }

  /// Ставится в `main()` до `runApp`.
  static void install() {
    if (_installed) return;
    _installed = true;

    final flutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      flutterOnError?.call(details);
      record(
        details.exception,
        details.stack,
        kind: 'flutter',
        context: details.context?.toString(),
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, kind: 'dart');
      return false;
    };
  }

  static final Map<String, DateTime> _recent = {};

  /// Ручная запись: `catch (e, s) { ErrorLogService.record(e, s, kind: 'склад'); }`
  static void record(
    Object error,
    StackTrace? stack, {
    String kind = 'app',
    String? context,
  }) {
    // Одна и та же ошибка в цикле перерисовки летит десятками в секунду.
    // Пишем её раз в минуту, иначе журнал станет бесполезным.
    final signature = '$kind|${_trim(error.toString(), 120)}';
    final now = DateTime.now();
    final seen = _recent[signature];
    if (seen != null && now.difference(seen) < const Duration(minutes: 1)) {
      return;
    }
    _recent[signature] = now;
    if (_recent.length > 40) {
      _recent.remove(_recent.entries.first.key);
    }

    final entry = <String, dynamic>{
      'at': now.toIso8601String(),
      'kind': kind,
      'message': _trim(error.toString(), 600),
      'screen': _screen,
      'version': _version,
      if (context != null && context.isNotEmpty)
        'context': _trim(context, 200),
      if (stack != null) 'stack': _topFrames(stack, 12),
    };
    debugPrint('Ошибка [$kind] на «$_screen»: ${entry['message']}');
    unawaited(_stash(entry));
  }

  /// Старт приложения: помечаем сессию, замечаем прошлый вылет, шлём накопленное.
  static Future<void> onAppStart() async {
    try {
      _version = await _appVersion();
      final prefs = await SharedPreferences.getInstance();

      // Флаг остался с прошлого раза — значит приложение не закрылось само,
      // а умерло. Так ловятся вылеты, до которых Flutter не доживает.
      if (prefs.getBool(_kSessionOpen) == true) {
        final screen = prefs.getString(_kLastScreen) ?? '';
        await _stash({
          'at': DateTime.now().toIso8601String(),
          'kind': 'crash',
          'message': screen.isEmpty
              ? 'Приложение закрылось само (вылет)'
              : 'Приложение закрылось само на экране «$screen»',
          'screen': screen,
          'version': _version,
        });
      }
      await prefs.setBool(_kSessionOpen, true);
    } catch (error) {
      debugPrint('ErrorLog start: $error');
    }
    unawaited(flush());
  }

  /// Приложение уходит в фон штатно — вылета не было.
  static Future<void> markCleanPause() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSessionOpen, false);
    } catch (_) {}
  }

  static Future<void> markResumed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSessionOpen, true);
    } catch (_) {}
    unawaited(flush());
  }

  // ------------------------------------------------------------------ хранение

  static Future<void> _stash(Map<String, dynamic> entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _readPending(prefs)..add(entry);
      final trimmed = list.length > keepPending
          ? list.sublist(list.length - keepPending)
          : list;
      await prefs.setString(_kPending, jsonEncode(trimmed));
    } catch (error) {
      debugPrint('ErrorLog stash: $error');
    }
    unawaited(flush());
  }

  static List<Map<String, dynamic>> _readPending(SharedPreferences prefs) {
    final raw = prefs.getString(_kPending);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static bool _flushing = false;

  /// Отправляет накопленное в Firestore. Без сети просто ждём следующего раза.
  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = _readPending(prefs);
      if (pending.isEmpty) return;
      final collection = FirebaseFirestore.instance
          .collection('companies')
          .doc(kCompanyId)
          .collection('app_errors');
      for (final entry in pending) {
        // Запись уходит в локальный кэш сразу; на сервер — когда будет связь.
        unawaited(
          collection.doc().set(entry).catchError((Object error) {
            debugPrint('ErrorLog send: $error');
          }),
        );
      }
      await prefs.setString(_kPending, '[]');
    } catch (error) {
      debugPrint('ErrorLog flush: $error');
    } finally {
      _flushing = false;
    }
  }

  /// Для экрана «Ошибки».
  static Stream<List<AppErrorEntry>> watch({int limit = 60}) {
    return FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('app_errors')
        .snapshots()
        .map((snapshot) {
      final items = <AppErrorEntry>[];
      for (final doc in snapshot.docs) {
        final item = AppErrorEntry.fromMap(doc.id, doc.data());
        if (item != null) items.add(item);
      }
      items.sort((a, b) => b.at.compareTo(a.at));
      return items.take(limit).toList();
    });
  }

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPending, '[]');
      final collection = FirebaseFirestore.instance
          .collection('companies')
          .doc(kCompanyId)
          .collection('app_errors');
      final snapshot = await collection.get();
      for (final doc in snapshot.docs) {
        unawaited(doc.reference.delete().catchError((_) {}));
      }
    } catch (error) {
      debugPrint('ErrorLog clear: $error');
    }
  }

  // ------------------------------------------------------------------ мелочи

  static Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  static String _trim(String value, int max) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= max ? clean : '${clean.substring(0, max)}…';
  }

  /// Верхушка стека — там почти всегда и лежит причина.
  static String _topFrames(StackTrace stack, int count) {
    final lines = stack
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(count)
        .toList();
    return lines.join('\n');
  }
}

class AppErrorEntry {
  final String id;
  final DateTime at;
  final String kind;
  final String message;
  final String screen;
  final String version;
  final String stack;

  const AppErrorEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.message,
    required this.screen,
    required this.version,
    required this.stack,
  });

  static AppErrorEntry? fromMap(String id, Map<String, dynamic> data) {
    final at = DateTime.tryParse('${data['at']}');
    if (at == null) return null;
    return AppErrorEntry(
      id: id,
      at: at,
      kind: (data['kind'] ?? 'app').toString(),
      message: (data['message'] ?? '').toString(),
      screen: (data['screen'] ?? '').toString(),
      version: (data['version'] ?? '').toString(),
      stack: (data['stack'] ?? '').toString(),
    );
  }

  bool get isCrash => kind == 'crash';

  String get asText {
    final buffer = StringBuffer()
      ..writeln('[$kind] ${at.toIso8601String()}')
      ..writeln(message);
    if (screen.isNotEmpty) buffer.writeln('экран: $screen');
    if (version.isNotEmpty) buffer.writeln('версия: $version');
    if (stack.isNotEmpty) buffer.writeln(stack);
    return buffer.toString();
  }
}
