import 'dart:convert';

import 'package:flutter/services.dart';

/// Локальный справочник мастера: тестовые режимы, ошибки, омы.
class ServiceGuideService {
  static const assetPath = 'assets/diagnostics/service_guide.json';
  static List<Map<String, dynamic>>? _cache;

  static const _brandAliases = <String, List<String>>{
    'whirlpool': ['whirlpool', 'wfw', 'vmw', 'duet'],
    'maytag': ['maytag'],
    'kitchenaid': ['kitchenaid', 'kitchen aid'],
    'kenmore': ['kenmore'],
    'amana': ['amana'],
    'samsung': ['samsung'],
    'lg': ['lg', 'direct drive'],
    'ge': ['ge', 'profile', 'cafe', 'gfw', 'gtw', 'gdf', 'gdt'],
    'frigidaire': ['frigidaire', 'electrolux'],
    'electrolux': ['electrolux', 'frigidaire'],
    'bosch': ['bosch', 'ascenta'],
  };

  static const _applianceAliases = <String, List<String>>{
    'fridge': [
      'refrigerat',
      'freezer',
      'fridge',
      'холод',
      'морозил',
    ],
    'washer': ['washing', 'washer', 'стирал'],
    'dryer': ['dryer', 'суши'],
    'dishwasher': ['dishwasher', 'посудомо'],
    'range': [
      'range',
      'oven',
      'cooktop',
      'induction',
      'плит',
      'духов',
      'вароч',
    ],
  };

  static Future<List<Map<String, dynamic>>> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString(assetPath);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _cache = [
      for (final item in (data['records'] as List))
        Map<String, dynamic>.from(item as Map),
    ];
    return _cache!;
  }

  static Future<Map<String, dynamic>> lookup({
    required String query,
    String brand = '',
    String appliance = '',
    String code = '',
    String kind = '',
  }) async {
    final records = await load();
    final q = query.trim();
    final brandQ = brand.trim();
    final applianceQ = appliance.trim();
    var codeQ = code.trim();
    if (codeQ.isEmpty) codeQ = _extractCode(q);
    final kindQ = _normalizeKind(kind, q);
    final tokens = _tokens('$q $brandQ $applianceQ $codeQ');
    if (tokens.isEmpty && codeQ.isEmpty) {
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
          score += 10;
        } else {
          score -= 4;
        }
      }

      if (codeQ.isNotEmpty) {
        final needle = codeQ.toLowerCase().replaceAll(' ', '');
        final compactHay = hay.replaceAll(' ', '');
        if (compactHay.contains(needle) || hay.contains(codeQ.toLowerCase())) {
          score += 45;
        }
      }

      score += _brandScore(hay, brandQ, tokens);
      score += _applianceScore(hay, rec['category']?.toString() ?? '', applianceQ, tokens);

      for (final token in tokens) {
        if (token.length < 3) continue;
        if (hay.contains(token)) score += 3;
      }

      if (score >= 12) scored.add((score: score, rec: rec));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final hits = scored.take(4).map((item) => _public(item.rec, item.score)).toList();
    return {
      'found': hits.isNotEmpty,
      'count': hits.length,
      'hits': hits,
      if (hits.isEmpty)
        'message':
            'В справочнике мастера нет карточки. Не выдумывай сервисный режим — скажи, что нет записи.',
    };
  }

  static String _normalizeKind(String kind, String query) {
    final k = kind.trim().toLowerCase();
    if (k == 'test_modes' || k == 'field_guide' || k == 'electrical') return k;
    final q = query.toLowerCase();
    final wantsTest = q.contains('тест') ||
        q.contains('сервис') ||
        q.contains('diagnostic mode') ||
        q.contains('test mode') ||
        q.contains('вход в');
    final wantsError = q.contains('ошиб') ||
        q.contains('error') ||
        q.contains('fault') ||
        q.contains('код');
    final wantsOhms = q.contains('ом') ||
        q.contains('ohm') ||
        q.contains('сопротив') ||
        q.contains('thermistor') ||
        q.contains('resistance');
    if (wantsOhms && !wantsTest && !wantsError) return 'electrical';
    if (wantsTest && !wantsError) return 'test_modes';
    if (wantsError && !wantsTest) return 'field_guide';
    return '';
  }

  static int _brandScore(String hay, String brand, Set<String> tokens) {
    var score = 0;
    final blob = '${brand.toLowerCase()} ${tokens.join(' ')}';
    for (final entry in _brandAliases.entries) {
      final mentioned = blob.contains(entry.key) ||
          tokens.contains(entry.key) ||
          brand.toLowerCase().contains(entry.key);
      if (mentioned) {
        if (_hayHasBrand(hay, entry.key)) score += 20;
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
    String category,
    String appliance,
    Set<String> tokens,
  ) {
    var score = 0;
    final blob = '${appliance.toLowerCase()} ${tokens.join(' ')} $category'.toLowerCase();
    for (final entry in _applianceAliases.entries) {
      final mentioned = blob.contains(entry.key) ||
          entry.value.any((alias) => blob.contains(alias));
      if (!mentioned) continue;
      if (hay.contains(entry.key) ||
          entry.value.any((alias) => hay.contains(alias) || category.toLowerCase().contains(alias))) {
        score += 16;
      }
    }
    return score;
  }

  static String _extractCode(String query) {
    final compact = query.toUpperCase();
    final match = RegExp(
      r'\b(F\d{1,2}\s*E\d{1,2}|[A-Z]{1,3}\d{1,3}|\d[A-Z]\b|T\d{2}|E\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(compact);
    return match?.group(1)?.replaceAll(' ', '') ?? '';
  }

  static Set<String> _tokens(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zа-я0-9ё\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toSet();
  }

  static Map<String, dynamic> _public(Map<String, dynamic> rec, int score) {
    String clip(String? value) {
      final text = (value ?? '').trim();
      if (text.length <= 900) return text;
      return '${text.substring(0, 900)}…';
    }

    return {
      'kind': rec['kind'],
      'category': rec['category'],
      'brand': rec['brand'],
      'platform': rec['platform'],
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
