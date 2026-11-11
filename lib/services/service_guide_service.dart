import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';

import 'firestore_service.dart';
import 'network_status_service.dart';

/// Серверный справочник мастера: коды ошибок, тестовые режимы, диагностика и Омы.
/// Хранится в Firestore (`companies/{companyId}/service_guide`), при старте
/// синхронизирует базовые карточки и имеет резервную копию в локальном ассете.
class ServiceGuideService {
  static const assetPath = 'assets/diagnostics/service_guide.json';
  static const int currentSeedVersion = 4;

  static List<Map<String, dynamic>>? _assetCache;
  static List<Map<String, dynamic>>? _serverCache;
  static Future<void>? _syncFuture;

  static const _brandAliases = <String, List<String>>{
    'whirlpool': [
      'whirlpool',
      'wfw',
      'vmw',
      'wtw',
      'mvw',
      'ntw',
      'itw',
      'duet',
      'cabrio',
      'bravos',
      'inglis',
      'roper',
      'w11448643',
      'w11580994',
      'w11580995',
      'вирпул',
      'уирлпул',
      'инглис',
    ],
    'maytag': ['maytag', 'mvw', 'mvwc', 'mvwb', 'мейтег', 'майтег'],
    'kitchenaid': ['kitchenaid', 'kitchen aid', 'kdtm', 'китченэйд'],
    'kenmore': ['kenmore', 'кенмор'],
    'amana': ['amana', 'ntw', 'амана'],
    'samsung': ['samsung', 'самсунг', 'bespoke', 'waterwall', 'twin cooling'],
    'lg': ['lg', 'элджи', 'direct drive', 'washtower', 'quadwash', 'truesteam', 'flowsense'],
    'ge': [
      'ge',
      'profile',
      'cafe',
      'hotpoint',
      'moffat',
      'hydrowave',
      'gfw',
      'gtw',
      'ptw',
      'htw',
      'gdf',
      'gdt',
      'gfd',
      'gtd',
      'джии',
      'хотпоинт',
    ],
    'frigidaire': ['frigidaire', 'electrolux', 'elfw', 'efls', 'fftw', 'фриджидейр', 'электролюкс'],
    'electrolux': ['electrolux', 'frigidaire', 'elfw', 'efls', 'электролюкс'],
    'bosch': ['bosch', 'thermador', 'gaggenau', 'siemens', 'ascenta', 'бош', 'термадор'],
    'miele': ['miele', 'миле'],
    'blomberg': ['blomberg', 'beko', 'бломберг', 'блумберг', 'беко'],
    'speed queen': ['speed queen', 'speedqueen', 'huebsch', 'alliance', 'спид квин', 'спидквин', 'tr5', 'tr7', 'tc5', 'ff7'],
    'fisher': ['fisher', 'paykel', 'dishdrawer', 'фишер'],
    'sub-zero': ['sub-zero', 'subzero', 'wolf', 'сабзиро', 'вульф'],
    'midea': ['midea', 'insignia', 'hisense', 'danby', 'haier', 'comfee', 'мидеа', 'инсигния', 'хайер', 'данби'],
    'panasonic': ['panasonic', 'sharp', 'панасоник', 'шарп'],
    'insinkerator': ['insinkerator', 'disposal', 'диспоузер', 'измельчитель'],
  };

  static const _applianceAliases = <String, List<String>>{
    'fridge': [
      'refrigerat',
      'fridge',
      'холод',
      'ледогенератор',
      'льдогенератор',
      'ice maker',
    ],
    'freezer': [
      'freezer',
      'морозил',
      'ларь',
      'upright freezer',
      'chest freezer',
    ],
    'washer': [
      'washing',
      'washer',
      'стирал',
      'стирк',
      'vmw',
      'wfw',
    ],
    'dryer': [
      'dryer',
      'суши',
      'сушк',
    ],
    'dishwasher': [
      'dishwasher',
      'dishdrawer',
      'посудомо',
      'посуд',
    ],
    'range': [
      'range',
      'oven',
      'stove',
      'плит',
      'духов',
      'печ',
    ],
    'cooktop': [
      'cooktop',
      'induction',
      'radiant',
      'вароч',
      'индукц',
      'конфорк',
    ],
    'microwave': [
      'microwave',
      'magnetron',
      'микроволн',
      'свч',
      'магнетрон',
    ],
    'other': [
      'disposal',
      'insinkerator',
      'hood',
      'wine',
      'вытяжк',
      'измельчит',
      'диспоузер',
      'винн',
    ],
  };

  /// Загрузить базовый набор из встроенного JSON-файла.
  static Future<List<Map<String, dynamic>>> loadAssetRecords() async {
    if (_assetCache != null) return _assetCache!;
    final raw = await rootBundle.loadString(assetPath);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _assetCache = [
      for (final item in (data['records'] as List))
        _normalizeRecord(Map<String, dynamic>.from(item as Map)),
    ];
    return _assetCache!;
  }

  static Map<String, dynamic> _normalizeRecord(
    Map<String, dynamic> raw, [
    String? docId,
  ]) {
    final id = (docId ?? raw['id'] ?? '').toString().trim();
    final kind = (raw['kind'] ?? 'field_guide').toString().trim();
    final category = (raw['category'] ?? '').toString().trim();
    final appliance = (raw['appliance'] ?? _inferApplianceKey(category)).toString().trim();
    final brand = (raw['brand'] ?? '').toString().trim();
    final platform = (raw['platform'] ?? '').toString().trim();
    final codes = (raw['codes'] ?? '').toString().trim();
    final topic = (raw['topic'] ?? '').toString().trim();
    final entry = (raw['entry'] ?? '').toString().trim();
    final procedure = (raw['procedure'] ?? '').toString().trim();
    final tests = (raw['tests'] ?? '').toString().trim();
    final specs = (raw['specs'] ?? '').toString().trim();
    final fix = (raw['fix'] ?? '').toString().trim();
    final exit = (raw['exit'] ?? '').toString().trim();
    final notes = (raw['notes'] ?? '').toString().trim();
    final search = [
      kind,
      appliance,
      category,
      brand,
      platform,
      codes,
      topic,
      entry,
      procedure,
      tests,
      specs,
      fix,
      exit,
      notes,
    ].join(' ').toLowerCase();

    return <String, dynamic>{
      'id': id,
      'kind': kind,
      'appliance': appliance,
      'category': category,
      'brand': brand,
      'platform': platform,
      'codes': codes,
      'topic': topic,
      'entry': entry,
      'procedure': procedure,
      'tests': tests,
      'specs': specs,
      'fix': fix,
      'exit': exit,
      'notes': notes,
      'builtin': raw['builtin'] == true,
      'custom': raw['custom'] == true,
      'search': search,
    };
  }

  static String _inferApplianceKey(String category) {
    final c = category.toLowerCase();
    if (c.contains('морозил') || c.contains('freezer')) return 'freezer';
    if (c.contains('холод') || c.contains('refrig')) return 'fridge';
    if (c.contains('стирал') || c.contains('wash')) return 'washer';
    if (c.contains('суш') || c.contains('dryer')) return 'dryer';
    if (c.contains('посуд') || c.contains('dish')) return 'dishwasher';
    if (c.contains('вароч') || c.contains('индукц') || c.contains('cooktop')) {
      return 'cooktop';
    }
    if (c.contains('микроволн') || c.contains('microwave') || c.contains('свч')) {
      return 'microwave';
    }
    if (c.contains('плит') || c.contains('духов') || c.contains('range') || c.contains('oven')) {
      return 'range';
    }
    if (c.contains('вытяж') || c.contains('измельч') || c.contains('винн')) {
      return 'other';
    }
    return 'all';
  }

  /// Однократная фоновая синхронизация базовых карточек с сервером Firestore.
  static Future<void> ensureServerSeeded({bool force = false}) {
    if (!force && _syncFuture != null) return _syncFuture!;
    _syncFuture = _syncToServer(force: force);
    return _syncFuture!;
  }

  static Future<void> _syncToServer({bool force = false}) async {
    try {
      final metaSnap = await FirestoreService.serviceGuideMetaRef.get();
      final meta = metaSnap.data() as Map<String, dynamic>?;
      final serverVersion = (meta?['version'] as num?)?.toInt() ?? 0;
      final serverCount = (meta?['recordCount'] as num?)?.toInt() ?? 0;
      final assetRecords = await loadAssetRecords();

      if (!force &&
          serverVersion >= currentSeedVersion &&
          serverCount >= assetRecords.length) {
        return;
      }

      final existingSnap = await FirestoreService.serviceGuideRef.get();
      final existingCustomIds = <String>{};
      for (final doc in existingSnap.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data?['custom'] == true) {
          existingCustomIds.add(doc.id);
        }
      }

      final batch = FirebaseFirestore.instance.batch();
      for (final rec in assetRecords) {
        final id = rec['id'] as String;
        if (id.isEmpty || existingCustomIds.contains(id)) continue;
        batch.set(
          FirestoreService.serviceGuideRef.doc(id),
          {
            ...rec,
            'builtin': true,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
      batch.set(
        FirestoreService.serviceGuideMetaRef,
        {
          'version': currentSeedVersion,
          'recordCount': assetRecords.length,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await batch.commit();
    } catch (_) {
      // В офлайне работаем по локальному кэшу Firestore + ассету.
    }
  }

  /// Живой поток всех карточек с сервера Firestore (объединённый с базовыми на случай первого старта).
  static Stream<List<Map<String, dynamic>>> streamAll() {
    unawaited(ensureServerSeeded());
    return FirestoreService.serviceGuideRef.snapshots().asyncMap((snapshot) async {
      final assetRecords = await loadAssetRecords();
      final byId = <String, Map<String, dynamic>>{
        for (final r in assetRecords) r['id'] as String: r,
      };
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data == null) continue;
        if (data['deleted'] == true) {
          byId.remove(doc.id);
          continue;
        }
        byId[doc.id] = _normalizeRecord(data, doc.id);
      }
      final list = byId.values.toList();
      _sortRecords(list);
      _serverCache = list;
      return list;
    });
  }

  static void _sortRecords(List<Map<String, dynamic>> list) {
    const kindOrder = {
      'error_codes': 0,
      'test_modes': 1,
      'field_guide': 2,
      'electrical': 3,
    };
    const appOrder = {
      'fridge': 0,
      'freezer': 1,
      'washer': 2,
      'dryer': 3,
      'dishwasher': 4,
      'range': 5,
      'cooktop': 6,
      'microwave': 7,
      'other': 8,
      'all': 9,
    };
    list.sort((a, b) {
      if (a['custom'] == true && b['custom'] != true) return -1;
      if (b['custom'] == true && a['custom'] != true) return 1;
      final ka = kindOrder[a['kind']] ?? 9;
      final kb = kindOrder[b['kind']] ?? 9;
      if (ka != kb) return ka.compareTo(kb);
      final aa = appOrder[a['appliance']] ?? 9;
      final ab = appOrder[b['appliance']] ?? 9;
      if (aa != ab) return aa.compareTo(ab);
      return (a['topic'] ?? '').toString().compareTo((b['topic'] ?? '').toString());
    });
  }

  /// Загрузить все карточки с сервера (с мгновенным откатом на кэш/ассет).
  static Future<List<Map<String, dynamic>>> load() async {
    if (_serverCache != null && _serverCache!.isNotEmpty) {
      return _serverCache!;
    }
    unawaited(ensureServerSeeded());
    final assetRecords = await loadAssetRecords();
    try {
      final snap = await FirestoreService.serviceGuideRef
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.docs.isNotEmpty) {
        final byId = <String, Map<String, dynamic>>{
          for (final r in assetRecords) r['id'] as String: r,
        };
        for (final doc in snap.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data == null) continue;
          if (data['deleted'] == true) {
            byId.remove(doc.id);
            continue;
          }
          byId[doc.id] = _normalizeRecord(data, doc.id);
        }
        final list = byId.values.toList();
        _sortRecords(list);
        _serverCache = list;
        return list;
      }
    } catch (_) {}
    _serverCache = assetRecords;
    return assetRecords;
  }

  /// Сохранить или обновить карточку на сервере Firestore.
  static Future<String> saveRecord(Map<String, dynamic> record) async {
    final rawId = (record['id'] ?? '').toString().trim();
    final docRef = rawId.isEmpty
        ? FirestoreService.serviceGuideRef.doc()
        : FirestoreService.serviceGuideRef.doc(rawId);
    final normalized = _normalizeRecord(
      {
        ...record,
        'id': docRef.id,
        'custom': record['builtin'] == true ? false : true,
        'deleted': false,
      },
      docRef.id,
    );
    await settleWrite(
      docRef.set(
        {
          ...normalized,
          'deleted': false,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ),
    );
    _serverCache = null;
    return docRef.id;
  }

  /// Удалить карточку с сервера.
  static Future<void> deleteRecord(String id) async {
    if (id.trim().isEmpty) return;
    await settleWrite(
      FirestoreService.serviceGuideRef.doc(id).set(
        {
          'deleted': true,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ),
    );
    _serverCache = null;
  }

  /// Поиск для голосового помогатора (`lookup_service_guide`) и быстрого фильтра.
  static Future<Map<String, dynamic>> lookup({
    required String query,
    String brand = '',
    String appliance = '',
    String code = '',
    String kind = '',
    String model = '',
    String techSheet = '',
  }) async {
    final records = await load();
    final q = [query.trim(), model.trim(), techSheet.trim()]
        .where((s) => s.isNotEmpty)
        .join(' ');
    final brandQ = brand.trim();
    final applianceQ = appliance.trim();
    var codeQ = code.trim();
    if (codeQ.isEmpty) codeQ = techSheet.trim();
    if (codeQ.isEmpty) codeQ = _extractCode(q);
    final kindQ = _normalizeKind(kind, q, codeQ);
    final tokens = _tokens('$q $brandQ $applianceQ $codeQ');
    if (tokens.isEmpty && codeQ.isEmpty && kindQ.isEmpty) {
      return {
        'found': false,
        'message': 'Нужен бренд, тип техники, код ошибки или что тестировать.',
      };
    }

    final scored = <({int score, Map<String, dynamic> rec})>[];
    for (final rec in records) {
      final hay = (rec['search'] ?? '').toString();
      if (hay.isEmpty) continue;
      var score = 0;

      if (kindQ.isNotEmpty) {
        if (rec['kind'] == kindQ) {
          score += 14;
        } else if (kindQ == 'error_codes' && rec['kind'] == 'field_guide') {
          score += 4;
        } else {
          score -= 4;
        }
      }

      if (codeQ.isNotEmpty) {
        final needle = codeQ.toLowerCase().replaceAll(RegExp(r'[\s\-]'), '');
        final codesStr = (rec['codes'] ?? '').toString().toLowerCase();
        final compactCodes = codesStr.replaceAll(RegExp(r'[\s\-]'), '');
        final compactHay = hay.replaceAll(RegExp(r'[\s\-]'), '');
        if (compactCodes.contains(needle) || codesStr.contains(codeQ.toLowerCase())) {
          score += 60;
        } else if (compactHay.contains(needle) || hay.contains(codeQ.toLowerCase())) {
          score += 40;
        }
      }

      score += _brandScore(hay, brandQ, tokens);
      score += _applianceScore(
        hay,
        rec['appliance']?.toString() ?? '',
        rec['category']?.toString() ?? '',
        applianceQ,
        tokens,
      );

      for (final token in tokens) {
        if (token.length < 2) continue;
        if (hay.contains(token)) {
          score += token.length >= 4 ? 4 : 2;
        }
      }

      if (score >= 10) scored.add((score: score, rec: rec));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final hits = scored
        .take(5)
        .map((item) => _public(item.rec, item.score))
        .toList();
    return {
      'found': hits.isNotEmpty,
      'count': hits.length,
      'hits': hits,
      if (hits.isEmpty)
        'message':
            'В справочнике мастера нет такой карточки. Не выдумывай сервисный режим — скажи, что точной записи нет.',
    };
  }

  static String _normalizeKind(String kind, String query, String code) {
    final k = kind.trim().toLowerCase();
    if (k == 'error_codes' ||
        k == 'test_modes' ||
        k == 'field_guide' ||
        k == 'electrical') {
      return k;
    }
    if (k == 'errors' || k == 'codes') return 'error_codes';
    final q = query.toLowerCase();
    final wantsTest = q.contains('тест') ||
        q.contains('сервис') ||
        q.contains('калибр') ||
        q.contains('diagnostic mode') ||
        q.contains('test mode') ||
        q.contains('service mode') ||
        q.contains('вход в') ||
        q.contains('как войти');
    final wantsError = code.isNotEmpty ||
        q.contains('ошиб') ||
        q.contains('error') ||
        q.contains('fault') ||
        q.contains('код');
    final wantsOhms = q.contains('ом') ||
        q.contains('ohm') ||
        q.contains('сопротив') ||
        q.contains('thermistor') ||
        q.contains('термистор') ||
        q.contains('resistance');
    if (wantsOhms && !wantsTest && !wantsError) return 'electrical';
    if (wantsTest && !wantsError) return 'test_modes';
    if (wantsError && !wantsTest) return 'error_codes';
    return '';
  }

  static int _brandScore(String hay, String brand, Set<String> tokens) {
    var score = 0;
    final blob = '${brand.toLowerCase()} ${tokens.join(' ')}';
    for (final entry in _brandAliases.entries) {
      final mentioned = blob.contains(entry.key) ||
          tokens.contains(entry.key) ||
          brand.toLowerCase().contains(entry.key) ||
          entry.value.any((alias) => blob.contains(alias));
      if (mentioned) {
        if (_hayHasBrand(hay, entry.key)) score += 22;
        for (final alias in entry.value) {
          if (alias.length > 2 && hay.contains(alias)) score += 6;
        }
      }
    }
    return score;
  }

  static bool _hayHasBrand(String hay, String key) {
    if (key.length <= 2) {
      return RegExp('\\b${RegExp.escape(key)}\\b').hasMatch(hay);
    }
    return hay.contains(key);
  }

  static int _applianceScore(
    String hay,
    String recAppliance,
    String category,
    String appliance,
    Set<String> tokens,
  ) {
    var score = 0;
    final blob = '${appliance.toLowerCase()} ${tokens.join(' ')}'.toLowerCase();
    for (final entry in _applianceAliases.entries) {
      final mentioned = blob.contains(entry.key) ||
          entry.value.any((alias) => blob.contains(alias));
      if (!mentioned) continue;
      if (recAppliance == entry.key) {
        score += 24;
      } else if (hay.contains(entry.key) ||
          entry.value.any(
            (alias) =>
                hay.contains(alias) || category.toLowerCase().contains(alias),
          )) {
        score += 14;
      }
    }
    return score;
  }

  static String _extractCode(String query) {
    final compact = query.toUpperCase();
    final match = RegExp(
      r'\b(W\d{7,9}[A-Z]?|ER\s*[A-Z]{2}|5Y\s*[A-Z]{2}|SY\s*[A-Z]{2}|F\d{1,2}\s*E[A-Z0-9]{1,2}|F-\d{1,2}|C-[A-Z0-9]{2}|E-\d{2}|H9[789]|[A-Z]{1,3}\d{1,3}[A-Z]?|\d{1,2}[A-Z]\d?\b|T\d{2}|E\d{1,3}|I\d{2})\b',
      caseSensitive: false,
    ).firstMatch(compact);
    return match?.group(1)?.trim() ?? '';
  }

  static Set<String> _tokens(String text) {
    final raw = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zа-я0-9ё\-\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toSet();
    final expanded = <String>{...raw};
    for (final t in raw) {
      if (RegExp(r'[а-яё]').hasMatch(t) && t.length >= 5) {
        final stem = t.replaceFirst(
          RegExp(r'(ого|ему|ому|ыми|ими|ую|юю|ая|яя|ое|ее|ые|ие|ой|ей|ом|ем|ах|ях|ам|ям|ов|ев|у|ю|а|я|е|и|ы)$'),
          '',
        );
        if (stem.length >= 4) expanded.add(stem);
      }
    }
    return expanded;
  }

  static Map<String, dynamic> _public(Map<String, dynamic> rec, int score) {
    String clip(String? value) {
      final text = (value ?? '').trim();
      if (text.length <= 3800) return text;
      return '${text.substring(0, 3800)}…';
    }

    return {
      'id': rec['id'],
      'kind': rec['kind'],
      'appliance': rec['appliance'],
      'category': rec['category'],
      'brand': rec['brand'],
      'platform': rec['platform'],
      'codes': clip(rec['codes'] as String?),
      'topic': rec['topic'],
      'entry': clip(rec['entry'] as String?),
      'procedure': clip(rec['procedure'] as String?),
      'tests': clip(rec['tests'] as String?),
      'exit': clip(rec['exit'] as String?),
      'specs': clip(rec['specs'] as String?),
      'fix': clip(rec['fix'] as String?),
      'notes': clip(rec['notes'] as String?),
      'score': score,
    };
  }
}
