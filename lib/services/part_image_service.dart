import 'dart:convert';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';
import '../models/warehouse_item.dart';
import 'ai_service.dart';
import 'auth_service.dart';

/// Картинка детали, которую ИИ нашёл в интернете.
class PartImageFind {
  /// Ссылка в нашем Storage — чужой хост на телефоне часто не отдаёт файл.
  final String imageUrl;

  /// Страница магазина, откуда снимок.
  final String sourceUrl;
  final String sourceHost;

  /// Исходный адрес картинки — чтобы при «поискать ещё» не предлагать ту же.
  final String originalUrl;

  /// Короткое пояснение ИИ, почему это она.
  final String why;

  const PartImageFind({
    required this.imageUrl,
    this.sourceUrl = '',
    this.sourceHost = '',
    this.originalUrl = '',
    this.why = '',
  });
}

/// Найденный в сети снимок до того, как его одобрили.
@visibleForTesting
class PartShot {
  final Uint8List bytes;
  final String image;
  final String page;
  final String title;
  final int score;

  const PartShot({
    required this.bytes,
    required this.image,
    required this.page,
    required this.title,
    required this.score,
  });
}

/// Поиск фотографии запчасти в интернете.
///
/// Ищет **сам телефон**. Сервер это уже умел, но с адресов Google Cloud
/// каталог запчастей отвечает 403, а картинки Bing приезжают вообще от другой
/// темы (в журнале были часы, игры и аниме-раскраски). С обычной сети мастера
/// те же адреса отдают нужную деталь. Функция `findPartImage` осталась
/// запасным ходом на случай, если с телефона в сеть не вышли.
class PartImageService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  static const _catalogSite = 'https://applianceparts.homedepot.ca';

  // Магазины запчастей: их снимок почти всегда «деталь на белом фоне».
  static const _goodHosts = [
    'partselect',
    'repairclinic',
    'appliancepartspros',
    'searspartsdirect',
    'partsdr',
    'reliableparts',
    'encompass',
    'marcone',
    'ereplacementparts',
    'appliancefactoryparts',
    'appliancepartscanada',
    'coastparts',
    'partswarehouse',
    'homedepot',
    'lowes',
    'amazon',
    'walmart',
    'ebayimg',
    'shopify',
  ];

  // Хотлинк оттуда запрещён, либо это заведомо не фото детали.
  static const _badHosts = [
    'pinterest',
    'pinimg',
    'facebook',
    'fbsbx',
    'instagram',
    'youtube',
    'ytimg',
    'tiktok',
    'bing.com',
    'bing.net',
    'gstatic',
    'wikipedia',
    'wikimedia',
  ];

  static const _badWords = [
    'logo',
    'sprite',
    'icon',
    'placeholder',
    'no-image',
    'noimage',
    'banner',
    'avatar',
  ];

  /// Сколько байт берём с одного кандидата и со всех вместе.
  ///
  /// Раньше принимался снимок до 4 МБ, а кандидатов бралось четыре. Дальше
  /// `DataPart` кодирует их в base64 (+⅓) и складывает в одну строку запроса к
  /// ИИ, то есть в памяти лежит и сырое, и закодированное, и тело запроса.
  /// Замер на телефоне мастера: приложение держит ~313 МБ уже в покое, а
  /// свободной памяти в системе было 74 МБ — такой всплеск его убивал, и поиск
  /// запускается на складе сам, без нажатия.
  ///
  /// Каталожное фото 1600×1200 весит 150–400 КБ, так что потолок ниже ничего
  /// не портит: ИИ всё равно смотрит картинку плитками по 768 точек.
  static const maxShotBytes = 1500 * 1024;
  static const maxTotalShotBytes = 4 * 1024 * 1024;

  /// Найти картинку. `null` — не нашлось, нет сети или ИИ забраковал снимки.
  /// Карточка склада должна сохраняться и без неё.
  static Future<PartImageFind?> find({
    required String partNumber,
    String name = '',
    String brand = '',
    String model = '',
    List<String> skip = const [],
  }) async {
    final part = partNumber.trim().toUpperCase();
    if (part.isEmpty && name.trim().length < 4) return null;

    var rows = <PartShot>[];
    try {
      // Каталог по точному номеру — первым: адрес картинки строится от самого
      // номера, поэтому приходит именно эта деталь, а не что-то похожее.
      var found = part.isEmpty ? <PartShot>[] : await _catalog(part);
      if (found.isEmpty) found = await _searchEngine(part, name, brand);
      rows = _rank(found, part: part, name: name, skip: skip);
    } catch (error) {
      debugPrint('PartImageService поиск: $error');
    }

    final loaded = <PartShot>[];
    var budget = 0;
    for (final row in rows) {
      if (loaded.length >= 4) break;
      final shot = await _download(row);
      if (shot == null) continue;
      // Общий потолок: дальше всё это уедет в ИИ одним запросом.
      if (budget + shot.bytes.length > maxTotalShotBytes) continue;
      budget += shot.bytes.length;
      loaded.add(shot);
    }

    if (loaded.isEmpty) {
      // С телефона в сеть не вышли — пусть попробует сервер.
      return _askServer(
        partNumber: part,
        name: name,
        brand: brand,
        model: model,
        skip: skip,
      );
    }

    final (best, why) = await AiService.pickPartPhoto(
      images: [for (final shot in loaded) shot.bytes],
      partNumber: part,
      name: name,
      brand: brand,
    );
    debugPrint(
      'PartImageService: кандидатов ${loaded.length}, выбран $best ($why)',
    );
    if (best < 1) return null;

    final picked = loaded[best - 1];
    final url = await _upload(picked, part.isEmpty ? name : part);
    if (url == null) return null;
    return PartImageFind(
      imageUrl: url,
      sourceUrl: picked.page.isEmpty ? picked.image : picked.page,
      sourceHost: _host(picked.page.isEmpty ? picked.image : picked.page),
      originalUrl: picked.image,
      why: why,
    );
  }

  /// Убрать из Storage картинку, которую FIX не принял. Молча: мусорный файл
  /// не повод ругаться на человека.
  static Future<void> discard(String? imageUrl) async {
    final url = (imageUrl ?? '').trim();
    if (url.isEmpty) return;
    try {
      await FirebaseStorage.instance
          .refFromURL(url)
          .delete()
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      debugPrint('PartImageService.discard: $error');
    }
  }

  // ─── источники ────────────────────────────────────────────────────────────

  /// Каталог запчастей: поиск по точному номеру. Один результат — сайт сам
  /// уводит на карточку товара, несколько — отдаёт список плиток.
  static Future<List<PartShot>> _catalog(String part) async {
    final wanted = WarehouseItem.normalizePart(part);
    if (wanted.length < 4) return const [];
    final response = await http
        .get(
          Uri.parse('$_catalogSite/search?q=${Uri.encodeQueryComponent(part)}'),
          headers: const {'User-Agent': _ua, 'Accept': 'text/html'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      debugPrint('PartImageService каталог: ${response.statusCode}');
      return const [];
    }
    final html = response.body;
    final finalUrl = response.request?.url.toString() ?? '';
    return parseCatalog(html, finalUrl, part);
  }

  /// Разбор ответа каталога. Публичный, чтобы был под тестом.
  @visibleForTesting
  static List<PartShot> parseCatalog(String html, String finalUrl, String part) {
    final wanted = WarehouseItem.normalizePart(part);
    String big(String imageId) =>
        '$_catalogSite/thumbnail/product/$imageId/1600/1200/'
        '${Uri.encodeComponent(part)}.jpg';

    // Карточка товара: сайт сам увёл на неё, значит номер совпал точно.
    if (finalUrl.contains('/product/') &&
        WarehouseItem.normalizePart(html).contains(wanted)) {
      final image = RegExp(r'thumbnail/product/(\d+)').firstMatch(html);
      if (image != null) {
        final title =
            RegExp(r'<title>([^<]{0,120})', caseSensitive: false)
                    .firstMatch(html)
                    ?.group(1)
                    ?.trim() ??
                '';
        return [
          PartShot(
            bytes: Uint8List(0),
            image: big(image.group(1)!),
            page: finalUrl,
            title: title,
            score: 0,
          ),
        ];
      }
    }

    // Список: у каждой плитки свой номер детали в скрипте рядом.
    final labels = <String, String>{};
    final labelRe = RegExp(
      r'product(\d+)\.partNumber\s*=\s*"([^"]+)"[\s\S]{0,300}?'
      r'product\1\.url\s*=\s*"/product/(\d+)"',
    );
    for (final row in labelRe.allMatches(html)) {
      labels[row.group(3)!] = row.group(2)!;
    }
    final tileRe = RegExp(
      r'href="[^"]*/product/(\d+)"[^>]*class="product-image"[^>]*'
      r'thumbnail/product/(\d+)/',
    );
    final rows = <PartShot>[];
    for (final tile in tileRe.allMatches(html)) {
      final label = labels[tile.group(1)!] ?? '';
      // Похожие товары в выдаче не нужны: берём только точный номер.
      if (label.isNotEmpty &&
          !WarehouseItem.normalizePart(label).contains(wanted)) {
        continue;
      }
      rows.add(
        PartShot(
          bytes: Uint8List(0),
          image: big(tile.group(2)!),
          page: '$_catalogSite/product/${tile.group(1)}',
          title: label,
          score: 0,
        ),
      );
      if (rows.length >= 4) break;
    }
    return rows;
  }

  /// Запасной источник: картинки Bing.
  static Future<List<PartShot>> _searchEngine(
    String part,
    String name,
    String brand,
  ) async {
    final query = part.isNotEmpty
        ? '"$part" appliance part'
        : '$brand $name appliance part'.trim();
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://www.bing.com/images/search'
              '?q=${Uri.encodeQueryComponent(query)}&form=HDRSC2&first=1',
            ),
            headers: const {
              'User-Agent': _ua,
              'Accept': 'text/html',
              'Accept-Language': 'en-CA,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return const [];
      return parseBing(response.body);
    } catch (error) {
      debugPrint('PartImageService поиск картинок: $error');
      return const [];
    }
  }

  /// Разбор выдачи картинок Bing. Публичный, чтобы был под тестом.
  @visibleForTesting
  static List<PartShot> parseBing(String html) {
    final rows = <PartShot>[];
    for (final match in RegExp(r'm="([^"]+)"').allMatches(html)) {
      final raw = _decodeEntities(match.group(1)!);
      if (!raw.contains('murl')) continue;
      try {
        final data = json.decode(raw);
        if (data is! Map) continue;
        final image = '${data['murl'] ?? ''}'.trim();
        if (image.isEmpty) continue;
        rows.add(
          PartShot(
            bytes: Uint8List(0),
            image: image,
            page: '${data['purl'] ?? ''}'.trim(),
            title: '${data['t'] ?? ''}'.trim(),
            score: 0,
          ),
        );
        if (rows.length >= 40) break;
      } catch (_) {
        continue;
      }
    }
    return rows;
  }

  // ─── отбор и загрузка ─────────────────────────────────────────────────────

  static List<PartShot> _rank(
    List<PartShot> rows, {
    required String part,
    required String name,
    required List<String> skip,
  }) {
    final seen = <String>{};
    final scored = <PartShot>[];
    for (final row in rows) {
      if (skip.contains(row.image)) continue;
      final score = _score(row, part: part, name: name);
      if (score < 0) continue;
      final key = '${_host(row.image)}|${row.image.split('/').last}';
      if (!seen.add(key)) continue;
      scored.add(
        PartShot(
          bytes: row.bytes,
          image: row.image,
          page: row.page,
          title: row.title,
          score: score,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored;
  }

  static int _score(PartShot row, {required String part, required String name}) {
    final image = row.image;
    final low = image.toLowerCase();
    final host = _host(image).toLowerCase();
    if (!low.startsWith('http')) return -1;
    if (RegExp(r'\.(svg|gif|bmp|ico)(\?|$)').hasMatch(low)) return -1;
    if (_badHosts.any(host.contains)) return -1;
    if (_badWords.any(low.contains)) return -1;

    var score = 0;
    if (_goodHosts.any(host.contains)) score += 30;
    final wanted = WarehouseItem.normalizePart(part);
    if (wanted.length >= 4) {
      if (WarehouseItem.normalizePart(image).contains(wanted)) score += 40;
      if (WarehouseItem.normalizePart(row.page).contains(wanted)) score += 25;
      if (WarehouseItem.normalizePart(row.title).contains(wanted)) score += 15;
    }
    final first = name
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 3)
        .firstOrNull;
    if (first != null && row.title.toLowerCase().contains(first)) score += 8;
    if (RegExp(r'\.(jpg|jpeg|png|webp)(\?|$)').hasMatch(low)) score += 5;
    return score;
  }

  static Future<PartShot?> _download(PartShot row) async {
    try {
      final response = await http
          .get(
            Uri.parse(row.image),
            headers: const {'User-Agent': _ua, 'Accept': 'image/*'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final mime = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (!RegExp(r'^image/(jpeg|jpg|png|webp)$').hasMatch(mime)) return null;
      final bytes = response.bodyBytes;
      // Меньше 8 КБ — значок или заглушка.
      if (bytes.length < 8 * 1024 || bytes.length > maxShotBytes) return null;
      return PartShot(
        bytes: bytes,
        image: row.image,
        page: row.page,
        title: row.title,
        score: row.score,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _upload(PartShot shot, String part) async {
    try {
      final safe = WarehouseItem.normalizePart(part);
      final name =
          'web_${DateTime.now().millisecondsSinceEpoch}_${safe.isEmpty ? 'part' : safe}.jpg';
      final ref = FirebaseStorage.instance.ref().child('warehouse').child(name);
      await ref
          .putData(shot.bytes, SettableMetadata(contentType: 'image/jpeg'))
          .timeout(const Duration(seconds: 25));
      return await ref.getDownloadURL().timeout(const Duration(seconds: 15));
    } catch (error) {
      debugPrint('PartImageService.upload: $error');
      return null;
    }
  }

  // ─── запасной ход через сервер ────────────────────────────────────────────

  static Future<PartImageFind?> _askServer({
    required String partNumber,
    required String name,
    required String brand,
    required String model,
    required List<String> skip,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/findPartImage'),
            headers: await AuthService.headers(),
            body: json.encode({
              'partNumber': partNumber,
              'name': name,
              'brand': brand,
              'model': model,
              if (skip.isNotEmpty) 'skip': skip,
            }),
          )
          .timeout(const Duration(seconds: 60));
      final body = response.body.isNotEmpty
          ? json.decode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final url = (body['imageUrl'] ?? '').toString().trim();
      if (response.statusCode != 200 || body['success'] != true || url.isEmpty) {
        debugPrint(
          'PartImageService сервер: ${body['error'] ?? body['reason'] ?? response.statusCode}',
        );
        return null;
      }
      return PartImageFind(
        imageUrl: url,
        sourceUrl: (body['sourceUrl'] ?? '').toString().trim(),
        sourceHost: (body['sourceHost'] ?? '').toString().trim(),
        originalUrl: (body['originalUrl'] ?? '').toString().trim(),
        why: (body['why'] ?? '').toString().trim(),
      );
    } catch (error) {
      debugPrint('PartImageService сервер: $error');
      return null;
    }
  }

  // ─── мелочи ───────────────────────────────────────────────────────────────

  static String _host(String url) {
    try {
      return Uri.parse(url).host.replaceFirst('www.', '');
    } catch (_) {
      return '';
    }
  }

  static String _decodeEntities(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
