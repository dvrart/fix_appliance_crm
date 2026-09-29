import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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
  static const _kScreenAt = 'error_log_screen_at_v1';
  static const _kVitals = 'error_log_vitals_v1';
  static const int keepPending = 40;

  /// Как часто снимаем показания, пока приложение открыто. Замер уходит в
  /// SharedPreferences, поэтому он переживает и вылет, и OOM-kill.
  static const vitalsPeriod = Duration(seconds: 30);

  /// Насколько метка экрана считается свежей. Раньше метка не сбрасывалась
  /// никогда, и любой вылет за месяц подписывался последним экраном, который
  /// её ставил, — журнал уверенно врал про «Склад».
  static const screenIsFreshFor = Duration(minutes: 3);

  static String _screen = '';
  static String _version = '';
  static bool _installed = false;
  static Timer? _vitalsTimer;
  static int _baselineRss = 0;

  /// Куда смотрел мастер, когда всё сломалось. Ставится при открытии экрана.
  static void markScreen(String name) {
    _screen = name;
    unawaited(_rememberScreen(name));
  }

  static Future<void> _rememberScreen(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastScreen, name);
      await prefs.setInt(_kScreenAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  // ------------------------------------------------------- замер состояния

  /// Память процесса и картинки в кэше. Именно это отличает OOM-kill от
  /// любой другой причины: у вылета по памяти замер перед смертью большой.
  static AppVitals vitals() {
    var rss = 0;
    try {
      rss = ProcessInfo.currentRss;
    } catch (_) {}
    // Первый замер сеанса становится точкой отсчёта.
    if (_baselineRss == 0 && rss > 0) _baselineRss = rss;
    var imageBytes = 0;
    var imageCount = 0;
    try {
      final cache = PaintingBinding.instance.imageCache;
      imageBytes = cache.currentSizeBytes;
      imageCount = cache.currentSize;
    } catch (_) {}
    return AppVitals(
      at: DateTime.now(),
      screen: _screen,
      rssBytes: rss,
      baselineRssBytes: _baselineRss,
      imageCacheBytes: imageBytes,
      imageCount: imageCount,
    );
  }

  /// Пока приложение на экране — раз в полминуты записываем показания.
  static void startVitals() {
    _vitalsTimer?.cancel();
    unawaited(_writeVitals());
    _vitalsTimer = Timer.periodic(vitalsPeriod, (_) => _writeVitals());
  }

  static void stopVitals() {
    _vitalsTimer?.cancel();
    _vitalsTimer = null;
  }

  static Future<void> _writeVitals() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kVitals, jsonEncode(vitals().toMap()));
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
        final screenAt = prefs.getInt(_kScreenAt);
        final last = AppVitals.tryParse(prefs.getString(_kVitals));
        await _stash({
          'at': DateTime.now().toIso8601String(),
          'kind': 'crash',
          'message': describeCrash(
            screen: screen,
            screenAt: screenAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(screenAt),
            last: last,
            now: DateTime.now(),
          ),
          // Экран пишем в поле только если метке можно верить.
          'screen': screenAt != null &&
                  DateTime.now()
                          .difference(
                            DateTime.fromMillisecondsSinceEpoch(screenAt),
                          )
                          .abs() <=
                      screenIsFreshFor
              ? screen
              : '',
          'version': _version,
        });
      }
      await prefs.setBool(_kSessionOpen, true);
      await prefs.remove(_kVitals);
    } catch (error) {
      debugPrint('ErrorLog start: $error');
    }
    startVitals();
    unawaited(flush());
  }

  /// Человекочитаемый разбор вылета. Чистая функция — закрыта тестом, потому
  /// что прежний вариант («на экране Склад») месяц уводил в сторону.
  @visibleForTesting
  static String describeCrash({
    required String screen,
    required DateTime? screenAt,
    required AppVitals? last,
    required DateTime now,
  }) {
    final parts = <String>['Приложение закрылось само'];
    if (screen.isEmpty || screenAt == null) {
      parts.add('экран неизвестен');
    } else {
      final age = now.difference(screenAt).abs();
      parts.add(
        age <= screenIsFreshFor
            ? 'на экране «$screen»'
            : 'последний отмеченный экран «$screen», но метке уже '
                '${_humanAge(age)} — верить ей нельзя',
      );
    }
    if (last == null) {
      parts.add('замера памяти нет');
    } else {
      final age = now.difference(last.at).abs();
      final growth = last.baselineRssBytes > 0
          ? ', в начале сеанса ${last.baselineRssMb} МБ '
              '(${last.rssGrowthMb >= 0 ? '+' : ''}${last.rssGrowthMb} МБ)'
          : '';
      parts.add(
        'замер за ${_humanAge(age)} до конца: память ${last.rssMb} МБ$growth, '
        'картинки в кэше ${last.imageCacheMb} МБ (${last.imageCount} шт)',
      );
      if (last.looksLikeOutOfMemory) {
        parts.add('память заметно росла — похоже на нехватку памяти');
      }
    }
    return '${parts.join('. ')}.';
  }

  static String _humanAge(Duration age) {
    if (age.inSeconds < 60) return '${age.inSeconds} с';
    if (age.inMinutes < 60) return '${age.inMinutes} мин';
    if (age.inHours < 24) return '${age.inHours} ч';
    return '${age.inDays} дн';
  }

  /// Приложение уходит в фон штатно — вылета не было.
  static Future<void> markCleanPause() async {
    stopVitals();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSessionOpen, false);
    } catch (_) {}
  }

  static Future<void> markResumed() async {
    startVitals();
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

/// Снимок состояния приложения. Пишется раз в полминуты, чтобы после
/// вылета было видно, сколько памяти держало приложение перед смертью.
class AppVitals {
  final DateTime at;
  final String screen;
  final int rssBytes;

  /// Сколько памяти держало приложение в начале сеанса. Абсолютное число
  /// ни о чём не говорит: живой замер на телефоне мастера дал 440 МБ RSS
  /// сразу после запуска, то есть любой фиксированный порог кричал бы «OOM»
  /// на каждом вылете. Смотреть надо на рост внутри сеанса.
  final int baselineRssBytes;
  final int imageCacheBytes;
  final int imageCount;

  const AppVitals({
    required this.at,
    required this.screen,
    required this.rssBytes,
    required this.baselineRssBytes,
    required this.imageCacheBytes,
    required this.imageCount,
  });

  int get rssMb => (rssBytes / (1024 * 1024)).round();
  int get baselineRssMb => (baselineRssBytes / (1024 * 1024)).round();
  int get imageCacheMb => (imageCacheBytes / (1024 * 1024)).round();

  /// Насколько выросла память с начала сеанса.
  int get rssGrowthMb => rssMb - baselineRssMb;

  /// Такой рост внутри одного сеанса — это уже не обычная работа, а утечка
  /// или разовый всплеск (пачка картинок в ИИ, полноразмерное фото).
  ///
  /// Величина привязана к живому замеру: `ProcessInfo.currentRss` отдаёт по
  /// этому приложению ~176 МБ, тогда как `dumpsys` для того же процесса
  /// показывает 460 МБ. То есть Dart видит свою часть, а не весь процесс, и
  /// сравнивать надо только с его же началом сеанса.
  static const suspiciousGrowthMb = 150;

  /// Кэш картинок Flutter по умолчанию упирается в 100 МБ. Почти полный кэш
  /// значит, что экран забит крупными снимками — второй признак OOM, который
  /// в Dart-RSS может и не проявиться: битмапы живут за его пределами.
  static const saturatedImageCacheMb = 90;

  bool get looksLikeOutOfMemory =>
      (baselineRssBytes > 0 && rssGrowthMb >= suspiciousGrowthMb) ||
      imageCacheMb >= saturatedImageCacheMb;

  Map<String, dynamic> toMap() => {
    'at': at.toIso8601String(),
    'screen': screen,
    'rss': rssBytes,
    'base': baselineRssBytes,
    'img': imageCacheBytes,
    'imgCount': imageCount,
  };

  static AppVitals? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final at = DateTime.tryParse('${map['at']}');
      if (at == null) return null;
      return AppVitals(
        at: at,
        screen: (map['screen'] ?? '').toString(),
        rssBytes: (map['rss'] as num?)?.toInt() ?? 0,
        baselineRssBytes: (map['base'] as num?)?.toInt() ?? 0,
        imageCacheBytes: (map['img'] as num?)?.toInt() ?? 0,
        imageCount: (map['imgCount'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
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
