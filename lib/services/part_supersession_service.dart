import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/warehouse_item.dart';

/// Итог сверки двух артикулов у живого каталога запчастей.
enum SupersessionVerdict {
  /// Один и тот же номер (дефисы/пробелы не считаются).
  same,

  /// Каталог: один номер заменяет другой — страница товара одна.
  replaces,

  /// Каталог знает ОБА номера, и ведёт их на разные товары.
  different,

  /// Нет сети либо каталог про номера ничего не сказал. Блокировать нельзя:
  /// в подвале без сети склад обязан работать как раньше.
  unknown,
}

/// Что каталог знает про один номер.
@visibleForTesting
class PartCatalogHit {
  /// Номер, под которым деталь продаётся сейчас (`Part #:` на странице).
  final String canonical;

  /// Номер из `?replaces=` в адресе — каталог сам сказал, что искали старый.
  final String replacesFromUrl;

  const PartCatalogHit({this.canonical = '', this.replacesFromUrl = ''});

  String get canonicalNorm => WarehouseItem.normalizePart(canonical);
}

/// Проверка «деталь B реально заменяет деталь A» по живому каталогу.
///
/// Зачем: ИИ иногда выдумывает номера замен, и такой номер однажды попал в
/// колонку «Заменяет номер» чужой карточки — после чего склад кричал
/// «уже есть замена» на деталь, которая с той общего ничего не имеет.
/// Теперь любую подставленную пару сверяем с каталогом (движок PartSelect за
/// applianceparts.homedepot.ca): запрос старого номера сам переадресует на
/// страницу нового (`?replaces=...`). Вердикт `different` ставим только когда
/// каталог знает оба номера и это явно разные товары — во всех сомнительных
/// случаях `unknown`, чтобы ничего лишнего не прятать.
class PartSupersessionService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  static const _catalogSite = 'https://applianceparts.homedepot.ca';

  /// Ответы каталога в этой сессии — один номер не спрашиваем дважды.
  /// null — каталог его не знает (или не было сети, тогда при следующем
  /// запросе попробуем опять: см. [lookup]).
  static final _cache = <String, PartCatalogHit?>{};

  /// Что каталог скажет про номер. null — не знает / нет сети.
  static Future<PartCatalogHit?> lookup(String part) async {
    final p = part.trim();
    final key = WarehouseItem.normalizePart(p);
    if (key.isEmpty) return null;
    if (_cache.containsKey(key)) return _cache[key];
    PartCatalogHit? hit;
    try {
      final response = await http
          .get(
            Uri.parse(
              '$_catalogSite/search?q=${Uri.encodeQueryComponent(p)}',
            ),
            headers: const {'User-Agent': _ua, 'Accept': 'text/html'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        hit = parseLookup(
          response.body,
          response.request?.url.toString() ?? '',
          p,
        );
      } else {
        debugPrint('Замена: каталог ответил ${response.statusCode}');
      }
    } catch (error) {
      // Нет сети — не запоминаем, иначе до конца сессии всё будет «не знаем».
      debugPrint('Замена: запрос к каталогу не прошёл: $error');
      return null;
    }
    _cache[key] = hit;
    return hit;
  }

  /// Разбор ответа каталога. Публичный, чтобы был под тестом.
  @visibleForTesting
  static PartCatalogHit? parseLookup(String html, String finalUrl, String part) {
    final wanted = WarehouseItem.normalizePart(part);
    // Поиск с точным совпадением сам уводит на страницу товара — иногда
    // уже на новый номер с пометкой ?replaces=старый в адресе.
    if (finalUrl.contains('/product/')) {
      final byHeader = RegExp(r'Part #:\s*([A-Za-z0-9][A-Za-z0-9\-]{2,24})')
          .firstMatch(html);
      final bySku = byHeader ??
          RegExp(r'"sku"\s*:\s*"([^"]{4,25})"').firstMatch(html);
      final canonical = (bySku?.group(1) ?? '').trim();
      if (canonical.isEmpty) return null;
      String replaces = '';
      try {
        replaces = Uri.parse(finalUrl).queryParameters['replaces'] ?? '';
      } catch (_) {}
      return PartCatalogHit(canonical: canonical, replacesFromUrl: replaces);
    }
    // Страница выдачи: у каждой плитки свой номер в скрипте. Сначала ищем
    // точное совпадение, потом номер внутри подписи («SMG DC47-00018A»);
    // «похожие» плитки без нашего номера не считаем.
    final labelRe = RegExp(
      r'product\d+\.partNumber\s*=\s*"([^"]+)"',
    );
    final labels = [
      for (final row in labelRe.allMatches(html)) row.group(1)!.trim(),
    ];
    String? exact;
    String? loose;
    for (final label in labels) {
      final norm = WarehouseItem.normalizePart(label);
      if (norm.length < 4) continue;
      if (norm == wanted) {
        exact = label;
        break;
      }
      if (loose == null && wanted.length >= 5 && norm.contains(wanted)) {
        loose = label;
      }
    }
    final found = exact ?? loose;
    return found == null ? null : PartCatalogHit(canonical: found);
  }

  /// Совпадает ли канонический номер из каталога с введённым: точно или
  /// тот лежит внутри подписи («SMG W10861000» — всё та же деталь).
  static bool _sameNumber(String canon, String norm) {
    if (canon == norm) return true;
    return norm.length >= 5 && canon.contains(norm);
  }

  /// Чистое решение по двум ответам каталога. Публичное — под тестом.
  @visibleForTesting
  static SupersessionVerdict decide(
    String wantedNorm,
    String candidateNorm, {
    PartCatalogHit? wantedHit,
    PartCatalogHit? candidateHit,
  }) {
    // Каталог знает оба номера — ему верим даже против локальной эвристики.
    final wCanon = wantedHit?.canonicalNorm ?? '';
    final cCanon = candidateHit?.canonicalNorm ?? '';
    if (wCanon.isNotEmpty && cCanon.isNotEmpty) {
      if (_sameNumber(wCanon, cCanon) ||
          _sameNumber(wCanon, candidateNorm) ||
          _sameNumber(cCanon, wantedNorm)) {
        return SupersessionVerdict.replaces;
      }
      return SupersessionVerdict.different;
    }
    if (wCanon.isNotEmpty && _sameNumber(wCanon, candidateNorm)) {
      return SupersessionVerdict.replaces;
    }
    if (cCanon.isNotEmpty && _sameNumber(cCanon, wantedNorm)) {
      return SupersessionVerdict.replaces;
    }
    // Каталог промолчал — хотя бы родной префикс Whirlpool (WP… ↔ …).
    for (final n in WarehouseItem.localSupersessions(wantedNorm)) {
      if (WarehouseItem.normalizePart(n) == candidateNorm) {
        return SupersessionVerdict.replaces;
      }
    }
    return SupersessionVerdict.unknown;
  }

  /// Реально ли номер [candidate] заменяет [wanted].
  static Future<SupersessionVerdict> check(
    String wanted,
    String candidate,
  ) async {
    final w = WarehouseItem.normalizePart(wanted);
    final c = WarehouseItem.normalizePart(candidate);
    if (w.isEmpty || c.isEmpty) return SupersessionVerdict.unknown;
    if (w == c) return SupersessionVerdict.same;

    // Оба номера спрашиваем сразу: без найденной карточки «второго» не
    // выносим вердикт «разные» — каталог мог просто её не знать.
    final hits = await Future.wait([lookup(wanted), lookup(candidate)]);
    return decide(
      w,
      c,
      wantedHit: hits[0],
      candidateHit: hits[1],
    );
  }

  /// Из списка догадок ИИ оставить те, что подтверждены (каталогом или
  /// родным префиксом). Пустой список — не позор: лучше пустое поле
  /// «Заменяет номера», чем выдуманный номер в чужой карточке.
  static Future<List<String>> verifiedOnly(
    String part,
    List<String> guessed,
  ) async {
    if (guessed.isEmpty) return const [];
    final out = <String>[];
    final verdicts = await Future.wait([
      for (final number in guessed.take(8)) check(part, number),
    ]);
    for (var i = 0; i < verdicts.length; i++) {
      if (verdicts[i] == SupersessionVerdict.replaces ||
          verdicts[i] == SupersessionVerdict.same) {
        out.add(guessed[i]);
      }
    }
    return out;
  }
}
