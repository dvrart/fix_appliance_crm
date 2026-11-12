import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';
import '../core/l10n/app_locale.dart';
import '../models/warehouse_item.dart';
import 'part_supersession_service.dart';
import 'warehouse_service.dart';

class PartOffer {
  final String store;
  final String url;
  final String title;
  final String matchedPartNumber;
  final double? price;
  final String currency;
  final bool inStock;
  final String stockNote;
  final bool? isOem;
  final String verificationMethod;

  const PartOffer({
    required this.store,
    required this.url,
    required this.title,
    required this.matchedPartNumber,
    this.price,
    this.currency = 'CAD',
    required this.inStock,
    this.stockNote = '',
    this.isOem,
    required this.verificationMethod,
  });

  double? get effectiveCadPrice {
    final p = price;
    if (p == null || p <= 0) return null;
    if (currency.toUpperCase() == 'USD') return p * 1.38;
    return p;
  }

  String get formattedPrice {
    final p = price;
    if (p == null || p <= 0) return '';
    final cur = currency.toUpperCase();
    return '\$${p.toStringAsFixed(2)} $cur';
  }

  Map<String, dynamic> toToolJson() => {
    'store': store,
    'url': url,
    'title': title,
    'part_number': matchedPartNumber,
    if (price != null) 'price': price,
    'currency': currency,
    'in_stock': inStock,
    if (stockNote.isNotEmpty) 'stock_note': stockNote,
    if (isOem != null) 'type': isOem! ? 'OEM' : 'aftermarket',
    'verified_by': verificationMethod,
  };
}

class WarehousePartMatch {
  final String id;
  final String name;
  final String partNumber;
  final int quantity;
  final double price;
  final double? costPrice;
  final bool exact;

  const WarehousePartMatch({
    required this.id,
    required this.name,
    required this.partNumber,
    required this.quantity,
    required this.price,
    this.costPrice,
    required this.exact,
  });

  Map<String, dynamic> toToolJson() => {
    'name': name,
    'part_number': partNumber,
    'quantity': quantity,
    'price': price,
    if (costPrice != null) 'cost_price': costPrice,
    'match': exact ? 'exact' : 'interchange',
  };
}

class PartSearchResult {
  final bool ok;
  final bool needsClarification;
  final String clarificationMessage;
  final String querySummary;
  final String partNumber;
  final String partName;
  final String applianceType;
  final String brand;
  final String model;
  final bool? fitsModelVerified;
  final String compatibilityNote;
  final List<String> interchangeNumbers;
  final List<WarehousePartMatch> warehouseMatches;
  final List<PartOffer> offers;
  final int checkedSourcesCount;
  final int rejectedCount;
  final List<String> checksPerformed;

  const PartSearchResult({
    required this.ok,
    this.needsClarification = false,
    this.clarificationMessage = '',
    this.querySummary = '',
    this.partNumber = '',
    this.partName = '',
    this.applianceType = '',
    this.brand = '',
    this.model = '',
    this.fitsModelVerified,
    this.compatibilityNote = '',
    this.interchangeNumbers = const [],
    this.warehouseMatches = const [],
    this.offers = const [],
    this.checkedSourcesCount = 0,
    this.rejectedCount = 0,
    this.checksPerformed = const [],
  });

  PartOffer? get cheapestOverall => offers.isEmpty ? null : offers.first;

  PartOffer? get cheapestAftermarket {
    for (final offer in offers) {
      if (offer.isOem == false) return offer;
    }
    return null;
  }

  PartOffer? get cheapestOem {
    for (final offer in offers) {
      if (offer.isOem == true) return offer;
    }
    return null;
  }

  String get amazonSearchUrl => partNumber.trim().isEmpty
      ? ''
      : 'https://www.amazon.ca/s?k=${Uri.encodeQueryComponent(partNumber.trim())}';

  Map<String, dynamic> toToolJson() {
    if (needsClarification) {
      return {
        'ok': false,
        'needs_clarification': true,
        'message': clarificationMessage,
        if (applianceType.isNotEmpty) 'appliance_type': applianceType,
        if (brand.isNotEmpty) 'brand': brand,
        if (model.isNotEmpty) 'model': model,
      };
    }
    if (!ok) {
      return {
        'ok': false,
        'error': clarificationMessage.isNotEmpty
            ? clarificationMessage
            : 'Не удалось найти проверенные предложения в наличии.',
        if (partNumber.isNotEmpty) 'part_number': partNumber,
      };
    }
    return {
      'ok': true,
      'screen_opened': true,
      'part_number': partNumber,
      'part_name': partName,
      if (applianceType.isNotEmpty) 'appliance_type': applianceType,
      if (brand.isNotEmpty) 'brand': brand,
      if (model.isNotEmpty) 'model': model,
      if (fitsModelVerified != null) 'fits_model_verified': fitsModelVerified,
      if (compatibilityNote.isNotEmpty) 'compatibility_note': compatibilityNote,
      if (interchangeNumbers.isNotEmpty) 'replaces': interchangeNumbers,
      if (warehouseMatches.isNotEmpty)
        'in_own_warehouse': [
          for (final item in warehouseMatches) item.toToolJson(),
        ],
      'checked_sources': checkedSourcesCount,
      'filtered_out_unverified_or_unavailable': rejectedCount,
      'verified_in_stock_count': offers.length,
      if (cheapestOverall != null)
        'cheapest_in_stock': cheapestOverall!.toToolJson(),
      if (cheapestAftermarket != null)
        'cheapest_aftermarket_or_amazon': cheapestAftermarket!.toToolJson(),
      if (cheapestOem != null) 'cheapest_oem_in_stock': cheapestOem!.toToolJson(),
      if (amazonSearchUrl.isNotEmpty) 'amazon_ca_search_url': amazonSearchUrl,
      'offers': [for (final offer in offers.take(10)) offer.toToolJson()],
    };
  }
}

class PartSearchSession extends ChangeNotifier {
  static final ValueNotifier<PartSearchSession?> current =
      ValueNotifier<PartSearchSession?>(null);

  static PartSearchSession? get active => current.value;

  bool isSearching = true;
  String queryTitle;
  String currentStep = '';
  final List<String> completedSteps = [];
  PartSearchResult? result;
  String? errorText;

  PartSearchSession({required this.queryTitle}) {
    current.value = this;
  }

  void advance(String nextStep, {String? completed}) {
    if (completed != null &&
        completed.trim().isNotEmpty &&
        !completedSteps.contains(completed)) {
      completedSteps.add(completed);
    }
    currentStep = nextStep;
    notifyListeners();
  }

  void finish(PartSearchResult value) {
    if (currentStep.isNotEmpty && !completedSteps.contains(currentStep)) {
      completedSteps.add(currentStep);
    }
    isSearching = false;
    currentStep = '';
    result = value;
    errorText = (!value.ok && !value.needsClarification)
        ? value.clarificationMessage
        : null;
    notifyListeners();
  }

  void fail(String message) {
    isSearching = false;
    currentStep = '';
    errorText = message;
    notifyListeners();
  }
}

@visibleForTesting
class PartCandidateLink {
  final String url;
  final String title;
  final String snippet;
  final String source;

  const PartCandidateLink({
    required this.url,
    this.title = '',
    this.snippet = '',
    required this.source,
  });
}

class _GroundedIdentification {
  final bool needsClarification;
  final String clarifyMessage;
  final String oemPart;
  final String partNameRu;
  final String partNameEn;
  final List<String> replaces;
  final bool? fitsModel;
  final String compatNoteRu;
  final List<PartCandidateLink> groundedLinks;

  const _GroundedIdentification({
    this.needsClarification = false,
    this.clarifyMessage = '',
    this.oemPart = '',
    this.partNameRu = '',
    this.partNameEn = '',
    this.replaces = const [],
    this.fitsModel,
    this.compatNoteRu = '',
    this.groundedLinks = const [],
  });
}

class PartSearchService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const _groundedModels = <({String name, bool thinkingZero})>[
    (name: 'gemini-3.5-flash', thinkingZero: true),
    (name: 'gemini-3.8-flash', thinkingZero: true),
    (name: 'gemini-3.5-flash-lite', thinkingZero: false),
  ];

  static const _canadianShopifyStores = <({String name, String baseUrl})>[
    (name: 'XPart Supply (ON)', baseUrl: 'https://xpartsupply.com'),
    (name: 'Parts of Canada', baseUrl: 'https://partsofcanada.com'),
    (
      name: 'Appliance Parts Canada',
      baseUrl: 'https://www.appliancepartscanada.ca',
    ),
  ];

  static const _blockedHosts = <String>[
    'youtube.com',
    'youtu.be',
    'reddit.com',
    'facebook.com',
    'instagram.com',
    'pinterest.',
    'tiktok.com',
    'justanswer.com',
    'manualslib.com',
    'applianceblog.com',
    'stackexchange.com',
    'quora.com',
    'wikipedia.org',
    'duckduckgo.com',
    'bing.com',
    'google.com',
    'vertexaisearch.cloud.google.com',
  ];

  static const _aftermarketMarkers = <String>[
    'aftermarket',
    'upstart',
    'bluestars',
    'xpart',
    'invertec',
    'supco',
    'exact replacement',
    'compatible with',
    'replacement for',
    'non-oem',
    'generic',
    'slowmoose',
    'foreverpro',
    'ami parts',
    'lunaparts',
    'supplying demand',
    'partsbroz',
    'fetechmate',
    'seentech',
    'edgewater',
    'upgraded',
  ];

  static String _t(String ru, String en) => AppLocale.instance.t(ru, en);

  @visibleForTesting
  static String? extractExplicitPartNumber(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    final tokens = RegExp(r'\b([A-Za-z0-9][A-Za-z0-9\-]{4,22})\b')
        .allMatches(cleaned);
    for (final m in tokens) {
      final raw = m.group(1)!;
      final norm = WarehouseItem.normalizePart(raw);
      if (norm.length < 5 || norm.length > 20) continue;
      final digits = RegExp(r'\d').allMatches(norm).length;
      if (digits < 3) continue;
      if (RegExp(r'^\d{4}$').hasMatch(norm)) continue;
      return raw.toUpperCase();
    }
    return null;
  }

  static bool hasEnoughInput({
    required String partQuery,
    required String partNumber,
    required String model,
    required String problem,
  }) {
    if (partNumber.trim().isNotEmpty) return true;
    if (extractExplicitPartNumber(partQuery) != null) return true;
    if (extractExplicitPartNumber(problem) != null) return true;
    if (partQuery.trim().isNotEmpty) return true;
    if (problem.trim().isNotEmpty &&
        problem.trim().toLowerCase() != 'нет описания') {
      return true;
    }
    return false;
  }

  static Future<PartSearchResult> search({
    String partQuery = '',
    String partNumber = '',
    String applianceType = '',
    String brand = '',
    String model = '',
    String problem = '',
    PartSearchSession? session,
    Future<List<WarehouseItem>> Function()? loadWarehouse,
    String? apiKeyOverride,
  }) async {
    final explicitPart = partNumber.trim().isNotEmpty
        ? partNumber.trim().toUpperCase()
        : (extractExplicitPartNumber(partQuery) ??
              extractExplicitPartNumber(problem) ??
              '');

    final summaryParts = <String>[
      if (explicitPart.isNotEmpty) explicitPart,
      if (partQuery.trim().isNotEmpty &&
          WarehouseItem.normalizePart(partQuery) !=
              WarehouseItem.normalizePart(explicitPart))
        partQuery.trim(),
      if (brand.trim().isNotEmpty || model.trim().isNotEmpty)
        '${brand.trim()} ${model.trim()}'.trim()
      else if (applianceType.trim().isNotEmpty)
        applianceType.trim(),
    ];
    final summary = summaryParts.isEmpty
        ? _t('Поиск запчасти', 'Part search')
        : summaryParts.join(' · ');

    if (!hasEnoughInput(
      partQuery: partQuery,
      partNumber: explicitPart,
      model: model,
      problem: problem,
    )) {
      final msg = model.trim().isEmpty
          ? _t(
              'Уточните, какая именно запчасть нужна, и номер модели техники с шильдика.',
              'Specify which part you need and the model number from the rating plate.',
            )
          : _t(
              'Уточните, какая именно запчасть или симптом поломки для модели ${model.trim()}.',
              'Specify which part or symptom you need for model ${model.trim()}.',
            );
      final res = PartSearchResult(
        ok: false,
        needsClarification: true,
        clarificationMessage: msg,
        querySummary: summary,
        applianceType: applianceType.trim(),
        brand: brand.trim(),
        model: model.trim(),
      );
      session?.finish(res);
      return res;
    }

    final checks = <String>[];
    session?.advance(
      _t(
        'Проверяю точный OEM-артикул и совместимость с моделью...',
        'Verifying exact OEM part number and model compatibility...',
      ),
    );

    final apiKey = apiKeyOverride ?? kGeminiApiKey;
    final identified = await _identifyAndSearchGrounded(
      apiKey: apiKey,
      partQuery: partQuery,
      explicitPartNumber: explicitPart,
      applianceType: applianceType,
      brand: brand,
      model: model,
      problem: problem,
    );

    if (identified.needsClarification && explicitPart.isEmpty) {
      final msg = identified.clarifyMessage.isNotEmpty
          ? identified.clarifyMessage
          : _t(
              'Нужен точный номер модели с шильдика или артикул детали, чтобы не подобрать неподходящую запчасть.',
              'Need the exact appliance model number from the rating plate or part number to verify compatibility.',
            );
      final res = PartSearchResult(
        ok: false,
        needsClarification: true,
        clarificationMessage: msg,
        querySummary: summary,
        applianceType: applianceType.trim(),
        brand: brand.trim(),
        model: model.trim(),
      );
      session?.finish(res);
      return res;
    }

    final canonicalPart = identified.oemPart.trim().isNotEmpty
        ? identified.oemPart.trim().toUpperCase()
        : explicitPart;
    if (canonicalPart.isEmpty) {
      final res = PartSearchResult(
        ok: false,
        needsClarification: true,
        clarificationMessage: _t(
          'Не удалось однозначно подтвердить OEM-артикул детали. Назовите номер модели с шильдика или артикул со старой детали.',
          'Could not unambiguously confirm the OEM part number. Provide the rating-plate model number or old part number.',
        ),
        querySummary: summary,
        applianceType: applianceType.trim(),
        brand: brand.trim(),
        model: model.trim(),
      );
      session?.finish(res);
      return res;
    }

    checks.add(
      model.trim().isNotEmpty
          ? _t(
              'Проверен артикул $canonicalPart и совместимость с моделью ${model.trim()}',
              'Verified part $canonicalPart and compatibility with ${model.trim()}',
            )
          : _t(
              'Подтверждён OEM-артикул $canonicalPart и кросс-номера',
              'Verified OEM part $canonicalPart and cross-references',
            ),
    );

    session?.advance(
      _t(
        'Проверяю свой склад и канадские магазины запчастей...',
        'Checking own warehouse and Canadian parts suppliers...',
      ),
      completed: checks.last,
    );

    final allowedNumbers = buildAllowedPartNumbers(
      canonicalPart,
      identified.replaces,
    );

    final parallelResults = await Future.wait<Object?>([
      _checkOwnWarehouse(
        canonicalPart: canonicalPart,
        allowedNumbers: allowedNumbers,
        loadWarehouse: loadWarehouse,
      ),
      PartSupersessionService.lookup(canonicalPart),
      _queryCanadianShopifyStores(
        canonicalPart: canonicalPart,
        allowedNumbers: allowedNumbers,
        brand: brand,
      ),
      _searchDuckDuckGoCanada(canonicalPart),
      _searchDuckDuckGoBudget(canonicalPart),
    ]);

    final warehouseMatches = parallelResults[0] as List<WarehousePartMatch>;
    final catalogHit = parallelResults[1] as PartCatalogHit?;
    final shopifyResult =
        parallelResults[2]
            as ({List<PartOffer> offers, int checked, int rejected});
    final ddgLinks = parallelResults[3] as List<PartCandidateLink>;
    final budgetDdgLinks = parallelResults[4] as List<PartCandidateLink>;

    final mergedInterchange = <String>{
      ...identified.replaces.map((e) => e.trim().toUpperCase()),
      for (final alt in WarehouseItem.localSupersessions(canonicalPart))
        alt.toUpperCase(),
      if (catalogHit != null && catalogHit.canonical.trim().isNotEmpty)
        catalogHit.canonical.trim().toUpperCase(),
      if (catalogHit != null && catalogHit.replacesFromUrl.trim().isNotEmpty)
        catalogHit.replacesFromUrl.trim().toUpperCase(),
    }..removeWhere(
      (item) =>
          item.isEmpty ||
          WarehouseItem.normalizePart(item) ==
              WarehouseItem.normalizePart(canonicalPart),
    );

    final allAllowed = buildAllowedPartNumbers(
      canonicalPart,
      mergedInterchange,
    );

    checks.add(
      _t(
        'Проверен собственный склад и прямые базы канадских поставщиков',
        'Checked own warehouse and direct Canadian supplier feeds',
      ),
    );

    session?.advance(
      _t(
        'Перепроверяю каждую ссылку, точное наличие и цены...',
        'Cross-checking every link, live stock, and prices...',
      ),
      completed: checks.last,
    );

    final shopifyHosts = shopifyResult.offers
        .map((o) => _cleanHost(Uri.tryParse(o.url)?.host ?? ''))
        .where((h) => h.isNotEmpty)
        .toSet();

    final budgetCandidates = <String, PartCandidateLink>{};
    final oemCandidates = <String, PartCandidateLink>{};
    for (final link in [
      ...budgetDdgLinks,
      ...identified.groundedLinks,
      ...ddgLinks,
    ]) {
      final clean = cleanProductUrl(link.url);
      if (clean == null) continue;
      final uri = Uri.tryParse(clean);
      if (uri == null || !isLikelyProductUrl(uri)) continue;
      final host = _cleanHost(uri.host);
      if (shopifyHosts.contains(host)) continue;
      final cand = PartCandidateLink(
        url: clean,
        title: link.title,
        snippet: link.snippet,
        source: link.source,
      );
      if (_isBudgetMarketplaceHost(host)) {
        budgetCandidates.putIfAbsent(clean, () => cand);
      } else {
        oemCandidates.putIfAbsent(clean, () => cand);
      }
    }

    // Обязательно берём и дешёвые варианты (Amazon.ca / eBay / Walmart), и оригинальные магазины OEM,
    // чтобы дорогие сайты никогда не вытесняли Amazon.ca из очереди проверки!
    final selectedCandidates = <PartCandidateLink>[
      ...budgetCandidates.values.take(6),
      ...oemCandidates.values.take(6),
    ];

    final verifiedWeb = await _verifyCandidateLinks(
      apiKey: apiKey,
      candidates: selectedCandidates,
      canonicalPart: canonicalPart,
      allowedNumbers: allAllowed,
      brand: brand,
    );

    final totalChecked =
        shopifyResult.checked + verifiedWeb.checked;
    final totalRejected =
        shopifyResult.rejected + verifiedWeb.rejected;

    final sortedOffers = sortAndDedupeOffers([
      ...shopifyResult.offers,
      ...verifiedWeb.offers,
    ]);

    checks.add(
      _t(
        'Проверено страниц: $totalChecked · отсеяно без наличия или неверных: $totalRejected · подтверждено в наличии: ${sortedOffers.length}',
        'Pages checked: $totalChecked · filtered out: $totalRejected · confirmed in stock: ${sortedOffers.length}',
      ),
    );

    final partTitle = AppLocale.instance.isEn
        ? (identified.partNameEn.isNotEmpty
              ? identified.partNameEn
              : identified.partNameRu)
        : (identified.partNameRu.isNotEmpty
              ? identified.partNameRu
              : identified.partNameEn);

    final result = PartSearchResult(
      ok: sortedOffers.isNotEmpty || warehouseMatches.isNotEmpty,
      clarificationMessage: sortedOffers.isEmpty && warehouseMatches.isEmpty
          ? _t(
              'Артикул $canonicalPart подтверждён, но ни на одной проверенной странице сейчас нет подтверждённого наличия в Канаде.',
              'Part $canonicalPart is confirmed, but no checked Canadian listing currently has verified in-stock availability.',
            )
          : '',
      querySummary: summary,
      partNumber: canonicalPart,
      partName: partTitle.isEmpty ? canonicalPart : partTitle,
      applianceType: applianceType.trim(),
      brand: brand.trim(),
      model: model.trim(),
      fitsModelVerified: identified.fitsModel,
      compatibilityNote: identified.compatNoteRu,
      interchangeNumbers: mergedInterchange.take(8).toList(),
      warehouseMatches: warehouseMatches,
      offers: sortedOffers,
      checkedSourcesCount: totalChecked,
      rejectedCount: totalRejected,
      checksPerformed: checks,
    );
    session?.finish(result);
    return result;
  }

  @visibleForTesting
  static Set<String> buildAllowedPartNumbers(
    String canonicalPart,
    Iterable<String> interchange,
  ) {
    final out = <String>{};
    void add(String raw) {
      final norm = WarehouseItem.normalizePart(raw);
      if (norm.length >= 4) {
        out.add(norm);
        if (norm.startsWith('00') && norm.length >= 7) {
          out.add(norm.substring(2));
        }
        for (final alt in WarehouseItem.localSupersessions(norm)) {
          final altNorm = WarehouseItem.normalizePart(alt);
          if (altNorm.length >= 4) out.add(altNorm);
        }
      }
    }

    add(canonicalPart);
    for (final item in interchange) {
      add(item);
    }
    return out;
  }

  @visibleForTesting
  static bool textMatchesAllowedPart(
    String text,
    Set<String> allowedNormalized,
  ) {
    if (text.trim().isEmpty || allowedNormalized.isEmpty) return false;
    final normText = WarehouseItem.normalizePart(text);
    if (normText.length < 4) return false;
    for (final part in allowedNormalized) {
      if (part.length < 4) continue;
      if (normText.contains(part)) return true;
    }
    return false;
  }

  @visibleForTesting
  static String? cleanProductUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (uri.host.trim().isEmpty) return null;

    const dropParams = {
      '_pos',
      '_psq',
      '_psid',
      '_ss',
      'utm_source',
      'utm_medium',
      'utm_campaign',
      'utm_term',
      'utm_content',
      'srsltid',
      'gclid',
      'fbclid',
      'sourcecode',
      'searchterm',
      'modelnum',
    };
    final kept = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      if (!dropParams.contains(k.toLowerCase())) {
        kept[k] = v;
      }
    });
    return Uri(
          scheme: 'https',
          userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
          queryParameters: kept.isEmpty ? null : kept,
        )
        .toString()
        .replaceFirst(RegExp(r'\?$'), '');
  }

  @visibleForTesting
  static bool isLikelyProductUrl(Uri uri) {
    final host = _cleanHost(uri.host);
    if (host.isEmpty) return false;
    for (final bad in _blockedHosts) {
      if (host == bad || host.endsWith('.$bad') || host.contains(bad)) {
        return false;
      }
    }
    final path = uri.path.trim();
    if (path.isEmpty || path == '/') return false;
    final lowPath = path.toLowerCase();

    const nonProductFragments = <String>[
      '/search',
      '/collections/',
      '/category/',
      '/categories/',
      '/models/',
      '/model/',
      '/modelproduct/',
      '/symptoms/',
      '/blog/',
      '/pages/',
      '/cart',
      '/account',
      '/login',
      '/en-ca/shop/',
      '/en-ca/category/',
      '/b/',
      '/str/',
      '/usr/',
      '/sch/',
      'best-sellers',
    ];
    for (final frag in nonProductFragments) {
      if (lowPath.contains(frag)) return false;
    }
    if (host.contains('amazon.') &&
        !lowPath.contains('/dp/') &&
        !lowPath.contains('/gp/product/')) {
      return false;
    }
    if (host.contains('ebay.') &&
        !RegExp(r'/itm/(?:[^/]+/)?\d{9,15}').hasMatch(lowPath)) {
      return false;
    }
    if (host.contains('walmart.') && !lowPath.contains('/ip/')) {
      return false;
    }
    if (host.contains('partselect.') &&
        !RegExp(r'/ps\d+', caseSensitive: false).hasMatch(lowPath)) {
      return false;
    }
    return true;
  }

  static bool _isBudgetMarketplaceHost(String host) =>
      host.contains('amazon.') ||
      host.contains('ebay.') ||
      host.contains('walmart.');

  @visibleForTesting
  static bool isAmazonBotChallenge(int statusCode, String html, String host) {
    if (!host.contains('amazon.')) return false;
    if (statusCode == 503 || statusCode == 429) return true;
    final low = html.toLowerCase();
    if (low.contains('validatecaptcha') ||
        low.contains('api-services-support@amazon') ||
        low.contains('automated access to amazon') ||
        low.contains('enter the characters you see below') ||
        low.contains('robot check')) {
      return true;
    }
    if (html.length < 9000 &&
        !low.contains('looking for something?') &&
        !low.contains('we couldn\'t find that page') &&
        !low.contains('currently unavailable') &&
        !low.contains('producttitle') &&
        !low.contains('add-to-cart')) {
      return true;
    }
    return false;
  }

  @visibleForTesting
  static bool isSoft404OrOutOfStockHtml(String html, String host) {
    final low = html.toLowerCase();
    if (host.contains('amazon.')) {
      if (low.contains('looking for something?') ||
          low.contains('we couldn\'t find that page') ||
          low.contains('currently unavailable')) {
        return true;
      }
    }
    const deadMarkers = <String>[
      '<title>404',
      '<title>page not found',
      'page cannot be found',
      'sorry, we couldn\'t find that page',
      'this listing was ended',
      'this item is out of stock',
      'no longer available',
      'part is no longer available',
      'item is discontinued',
    ];
    for (final marker in deadMarkers) {
      if (low.contains(marker)) return true;
    }
    final hasOutSchema =
        low.contains('schema.org/outofstock') ||
        low.contains('schema.org/discontinued') ||
        low.contains('"availability":"outofstock"') ||
        low.contains('"availability": "outofstock"');
    final hasInSchema =
        low.contains('schema.org/instock') ||
        low.contains('"availability":"instock"') ||
        low.contains('"availability": "instock"');
    if (hasOutSchema && !hasInSchema) return true;
    return false;
  }

  @visibleForTesting
  static bool isCloudflareChallenge(int statusCode, String html) {
    if (statusCode != 403 && statusCode != 503) return false;
    final low = html.toLowerCase();
    return low.contains('just a moment...') ||
        low.contains('cf-browser-verification') ||
        low.contains('challenge-platform') ||
        low.contains('_cf_chl') ||
        low.contains('attention required! | cloudflare');
  }

  @visibleForTesting
  static ({double? price, String currency, bool? inStock, String title})
  parseProductHtml(String html, String host) {
    var title = '';
    final titleMatch = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (titleMatch != null) {
      title = _stripTags(titleMatch.group(1)!);
    }

    double? price;
    var currency = _defaultCurrencyForHost(host);
    bool? inStock;

    final ldMatches = RegExp(
      r'<script[^>]*type=["\x27]application/ld\+json["\x27][^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    ).allMatches(html);

    for (final match in ldMatches) {
      final raw = match.group(1)?.trim() ?? '';
      if (raw.isEmpty) continue;
      try {
        final decoded = json.decode(raw);
        final extracted = _extractFromJsonLd(decoded);
        if (extracted.title.isNotEmpty && title.isEmpty) {
          title = extracted.title;
        }
        if (extracted.price != null && extracted.price! > 0) {
          price ??= extracted.price;
          if (extracted.currency.isNotEmpty) currency = extracted.currency;
        }
        if (extracted.inStock != null) {
          inStock = extracted.inStock;
        }
      } catch (_) {}
    }

    if (price == null) {
      final metaPrice = RegExp(
        r'property=["\x27](?:product|og):price:amount["\x27]\s+content=["\x27]([0-9]+(?:\.[0-9]{1,2})?)["\x27]',
        caseSensitive: false,
      ).firstMatch(html);
      if (metaPrice != null) {
        price = double.tryParse(metaPrice.group(1)!);
      }
      final metaCur = RegExp(
        r'property=["\x27](?:product|og):price:currency["\x27]\s+content=["\x27]([A-Za-z]{3})["\x27]',
        caseSensitive: false,
      ).firstMatch(html);
      if (metaCur != null) {
        currency = metaCur.group(1)!.toUpperCase();
      }
    }

    if (html.contains('"active":"USD"') ||
        html.contains('"currency":"USD"')) {
      if (!host.endsWith('.ca') &&
          host != 'partsofcanada.com' &&
          host != 'xpartsupply.com') {
        currency = 'USD';
      }
    }

    if (inStock == null) {
      final low = html.toLowerCase();
      if (low.contains('schema.org/instock') ||
          low.contains('>in stock<') ||
          low.contains('"in_stock":true') ||
          low.contains('"available":true')) {
        inStock = true;
      } else if (low.contains('out of stock') ||
          low.contains('currently unavailable')) {
        inStock = false;
      }
    }

    return (price: price, currency: currency, inStock: inStock, title: title);
  }

  static ({double? price, String currency, bool? inStock, String title})
  _extractFromJsonLd(dynamic node) {
    double? price;
    var currency = '';
    bool? inStock;
    var title = '';

    void walk(dynamic current) {
      if (current is List) {
        for (final item in current) {
          walk(item);
        }
        return;
      }
      if (current is! Map) return;
      final type = '${current['@type'] ?? ''}'.toLowerCase();
      if (type.contains('product')) {
        final name = '${current['name'] ?? ''}'.trim();
        if (name.isNotEmpty && title.isEmpty) title = name;
      }
      if (current.containsKey('offers')) {
        walk(current['offers']);
      }
      if (type.contains('offer') || current.containsKey('price')) {
        final rawPrice = current['price'] ?? current['lowPrice'];
        if (rawPrice != null && price == null) {
          final parsed = double.tryParse(
            rawPrice.toString().replaceAll(RegExp(r'[^0-9.]'), ''),
          );
          if (parsed != null && parsed > 0) price = parsed;
        }
        final cur = '${current['priceCurrency'] ?? ''}'.trim().toUpperCase();
        if (cur.length == 3 && currency.isEmpty) currency = cur;
        final avail = '${current['availability'] ?? ''}'.toLowerCase();
        if (avail.contains('instock')) {
          inStock = true;
        } else if (avail.contains('outofstock') ||
            avail.contains('discontinued') ||
            avail.contains('soldout') ||
            avail.contains('backorder')) {
          inStock ??= false;
        }
      }
      if (current.containsKey('@graph')) {
        walk(current['@graph']);
      }
    }

    walk(node);
    return (price: price, currency: currency, inStock: inStock, title: title);
  }

  @visibleForTesting
  static List<PartOffer> parseShopifySuggestJson({
    required String body,
    required String storeName,
    required String baseUrl,
    required String canonicalPart,
    required Set<String> allowedNumbers,
    String brand = '',
  }) {
    final offers = <PartOffer>[];
    dynamic decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return offers;
    }
    if (decoded is! Map) return offers;
    final products = decoded['resources']?['results']?['products'];
    if (products is! List) return offers;

    for (final raw in products) {
      if (raw is! Map) continue;
      if (raw['available'] != true) continue;
      final title = '${raw['title'] ?? ''}'.trim();
      final handle = '${raw['handle'] ?? ''}'.trim();
      final rawUrl = '${raw['url'] ?? ''}'.trim();
      final vendor = '${raw['vendor'] ?? ''}'.trim();
      final bodyHtml = '${raw['body'] ?? ''}';

      final variantSkus = <String>[];
      if (raw['variants'] is List) {
        for (final v in raw['variants'] as List) {
          if (v is Map && v['sku'] != null) {
            variantSkus.add('${v['sku']}');
          }
        }
      }

      final primaryIdentity = [title, handle, ...variantSkus].join(' ');
      if (!textMatchesAllowedPart(primaryIdentity, allowedNumbers)) {
        continue;
      }

      final parsedPrice = _parsePriceValue(
        raw['price_min'] ?? raw['price'],
      );
      if (parsedPrice == null || parsedPrice <= 0) continue;

      final fullUrl = cleanProductUrl(
        rawUrl.startsWith('http')
            ? rawUrl
            : '$baseUrl${rawUrl.startsWith('/') ? '' : '/'}$rawUrl',
      );
      if (fullUrl == null) continue;

      final isOem = classifyOem(
        storeName: storeName,
        host: _cleanHost(Uri.parse(baseUrl).host),
        title: title,
        vendor: vendor,
        skuText: variantSkus.join(' '),
        bodySnippet: bodyHtml,
        brand: brand,
      );

      offers.add(
        PartOffer(
          store: storeName,
          url: fullUrl,
          title: title.isEmpty ? canonicalPart : title,
          matchedPartNumber: _pickMatchedNumber(
            primaryIdentity,
            canonicalPart,
            allowedNumbers,
          ),
          price: parsedPrice,
          currency: 'CAD',
          inStock: true,
          stockNote: _t(
            'В наличии (проверено по базе магазина)',
            'In stock (verified via live store feed)',
          ),
          isOem: isOem,
          verificationMethod: 'store_api',
        ),
      );
    }
    return offers;
  }

  @visibleForTesting
  static bool? classifyOem({
    required String storeName,
    required String host,
    required String title,
    String vendor = '',
    String skuText = '',
    String bodySnippet = '',
    String brand = '',
  }) {
    final combined = '$storeName $host $title $vendor $skuText $bodySnippet'
        .toLowerCase();
    if (host.contains('xpartsupply.com')) {
      if (combined.contains('genuine oem')) return true;
      return false;
    }
    for (final marker in _aftermarketMarkers) {
      if (combined.contains(marker)) return false;
    }
    if (RegExp(r'\b[a-z0-9\-]+(-er|-xp|xp)\b').hasMatch(skuText.toLowerCase())) {
      return false;
    }
    if (host.contains('partselect.') ||
        host.contains('reliableparts.') ||
        host.contains('homedepot.') ||
        host.contains('amresupply.')) {
      return true;
    }
    if (combined.contains('genuine oem') ||
        combined.contains('authentic oem') ||
        combined.contains('factory original')) {
      return true;
    }
    if (host.contains('amazon.') ||
        host.contains('ebay.') ||
        host.contains('walmart.')) {
      return false;
    }
    if (combined.contains('official')) {
      return true;
    }
    final cleanBrand = brand.trim().toLowerCase();
    if (cleanBrand.isNotEmpty &&
        vendor.trim().toLowerCase() == cleanBrand) {
      return true;
    }
    return null;
  }

  @visibleForTesting
  static List<PartOffer> sortAndDedupeOffers(Iterable<PartOffer> input) {
    final byUrl = <String, PartOffer>{};
    for (final offer in input) {
      if (!offer.inStock) continue;
      final clean = cleanProductUrl(offer.url);
      if (clean == null) continue;
      final existing = byUrl[clean];
      if (existing == null ||
          (existing.price == null && offer.price != null)) {
        byUrl[clean] = offer;
      }
    }

    final list = byUrl.values.toList();
    list.sort((a, b) {
      final pa = a.effectiveCadPrice;
      final pb = b.effectiveCadPrice;
      if (pa != null && pb != null) {
        final cmp = pa.compareTo(pb);
        if (cmp != 0) return cmp;
      } else if (pa != null) {
        return -1;
      } else if (pb != null) {
        return 1;
      }
      final aCad = a.currency.toUpperCase() == 'CAD' ? 0 : 1;
      final bCad = b.currency.toUpperCase() == 'CAD' ? 0 : 1;
      if (aCad != bCad) return aCad.compareTo(bCad);
      return a.store.compareTo(b.store);
    });
    return list;
  }

  static Future<List<WarehousePartMatch>> _checkOwnWarehouse({
    required String canonicalPart,
    required Set<String> allowedNumbers,
    Future<List<WarehouseItem>> Function()? loadWarehouse,
  }) async {
    try {
      final items = loadWarehouse != null
          ? await loadWarehouse()
          : await WarehouseService.ref
                .get()
                .timeout(const Duration(seconds: 4))
                .then(
                  (snap) => snap.docs
                      .map(
                        (d) => WarehouseItem.fromMap(
                          d.data() as Map<String, dynamic>,
                          d.id,
                        ),
                      )
                      .where((item) => !item.isDeleted)
                      .toList(),
                );
      final matches = <WarehousePartMatch>[];
      final targetNorm = WarehouseItem.normalizePart(canonicalPart);
      for (final item in items) {
        if (item.quantity <= 0) continue;
        final itemNumbers = item.searchNumbers;
        var matched = false;
        for (final allowed in allowedNumbers) {
          if (WarehouseItem.numberMatches(allowed, itemNumbers)) {
            matched = true;
            break;
          }
        }
        if (!matched) continue;
        final exact = WarehouseItem.normalizePart(item.partNumber) == targetNorm;
        matches.add(
          WarehousePartMatch(
            id: item.id,
            name: item.name,
            partNumber: item.partNumber,
            quantity: item.quantity,
            price: item.price,
            costPrice: item.costPrice,
            exact: exact,
          ),
        );
      }
      return matches;
    } catch (e) {
      debugPrint('PartSearchService warehouse: $e');
      return const [];
    }
  }

  static Future<({List<PartOffer> offers, int checked, int rejected})>
  _queryCanadianShopifyStores({
    required String canonicalPart,
    required Set<String> allowedNumbers,
    required String brand,
  }) async {
    final results = await Future.wait(
      _canadianShopifyStores.map((store) async {
        final uri = Uri.parse(
          '${store.baseUrl}/search/suggest.json'
          '?q=${Uri.encodeQueryComponent(canonicalPart)}'
          '&resources[type]=product&resources[limit]=5',
        );
        try {
          final resp = await _httpGet(
            uri,
            timeout: const Duration(seconds: 7),
            accept: 'application/json',
          );
          if (resp.statusCode != 200) {
            return (offers: const <PartOffer>[], checked: 1, rejected: 1);
          }
          var rawCount = 0;
          try {
            final d = json.decode(resp.body);
            final list = d['resources']?['results']?['products'];
            if (list is List) rawCount = list.length;
          } catch (_) {}
          final parsed = parseShopifySuggestJson(
            body: resp.body,
            storeName: store.name,
            baseUrl: store.baseUrl,
            canonicalPart: canonicalPart,
            allowedNumbers: allowedNumbers,
            brand: brand,
          );
          final checked = rawCount > 0 ? rawCount : 1;
          final rejected = (checked - parsed.length).clamp(0, checked);
          return (offers: parsed, checked: checked, rejected: rejected);
        } catch (e) {
          debugPrint('PartSearchService shopify ${store.name}: $e');
          return (offers: const <PartOffer>[], checked: 1, rejected: 0);
        }
      }),
    );

    final offers = <PartOffer>[];
    var checked = 0;
    var rejected = 0;
    for (final r in results) {
      offers.addAll(r.offers);
      checked += r.checked;
      rejected += r.rejected;
    }
    return (offers: offers, checked: checked, rejected: rejected);
  }

  static Future<List<PartCandidateLink>> _searchDuckDuckGoCanada(
    String canonicalPart,
  ) async {
    final query =
        '"$canonicalPart" (site:partselect.ca OR site:reliableparts.ca '
        'OR site:amresupply.com OR site:applianceparts.homedepot.ca)';
    final uri = Uri.parse(
      'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}',
    );
    try {
      final resp = await _httpGet(uri, timeout: const Duration(seconds: 7));
      if (resp.statusCode != 200) return const [];
      return parseDuckDuckGoHtml(resp.body);
    } catch (e) {
      debugPrint('PartSearchService ddg: $e');
      return const [];
    }
  }

  static Future<List<PartCandidateLink>> _searchDuckDuckGoBudget(
    String canonicalPart,
  ) async {
    final query =
        '"$canonicalPart" (site:amazon.ca OR site:ebay.ca OR site:walmart.ca)';
    final uri = Uri.parse(
      'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}',
    );
    try {
      final resp = await _httpGet(uri, timeout: const Duration(seconds: 7));
      if (resp.statusCode != 200) return const [];
      return parseDuckDuckGoHtml(resp.body);
    } catch (e) {
      debugPrint('PartSearchService ddg budget: $e');
      return const [];
    }
  }

  @visibleForTesting
  static List<PartCandidateLink> parseDuckDuckGoHtml(String html) {
    final out = <PartCandidateLink>[];
    final re = RegExp(
      r'class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>'
      r'(?:[\s\S]{0,700}?class="result__snippet"[^>]*>([\s\S]*?)</(?:a|div)>)?',
      caseSensitive: false,
    );
    for (final m in re.allMatches(html)) {
      var href = _decodeHtmlEntities(m.group(1) ?? '').trim();
      if (href.contains('duckduckgo.com/y.js') ||
          href.contains('bing.com/aclick')) {
        continue;
      }
      final uddg = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
      if (uddg != null) {
        href = Uri.decodeComponent(uddg.group(1)!);
      }
      if (!href.startsWith('http')) continue;
      final title = _stripTags(m.group(2) ?? '');
      final snippet = _stripTags(m.group(3) ?? '');
      out.add(
        PartCandidateLink(
          url: href,
          title: title,
          snippet: snippet,
          source: 'ddg',
        ),
      );
      if (out.length >= 12) break;
    }
    return out;
  }

  static Future<_GroundedIdentification> _identifyAndSearchGrounded({
    required String apiKey,
    required String partQuery,
    required String explicitPartNumber,
    required String applianceType,
    required String brand,
    required String model,
    required String problem,
  }) async {
    if (apiKey.isEmpty || apiKey == 'YOUR_GEMINI_API_KEY') {
      return _GroundedIdentification(oemPart: explicitPartNumber);
    }

    final prompt = '''
You are a senior Canadian appliance parts verification specialist.
Use Google Search BEFORE answering to verify the exact OEM replacement part number, model compatibility, and active Canadian store listings.

Input:
- Explicit part number (if any): ${explicitPartNumber.isEmpty ? '(none)' : explicitPartNumber}
- Requested part: ${partQuery.trim().isEmpty ? '(infer from symptom/problem if unambiguous)' : partQuery.trim()}
- Appliance type: ${applianceType.trim().isEmpty ? '(unknown)' : applianceType.trim()}
- Brand: ${brand.trim().isEmpty ? '(unknown)' : brand.trim()}
- Model number: ${model.trim().isEmpty ? '(none provided)' : model.trim()}
- Symptom / job description: ${problem.trim().isEmpty ? '(none)' : problem.trim()}

Mandatory verification rules:
1. If NO part number is given AND NO model number is given, and multiple incompatible OEM parts exist for different models of this brand/appliance, DO NOT GUESS. Set NEEDS_CLARIFICATION: YES and explain briefly in Russian in CLARIFY_RU that the model number from the rating plate (or old part number) is required.
2. If a model number IS provided, search official parts diagrams for that exact model to verify the exact OEM part number. If an explicit part number was also given, check whether it actually fits that model; if another OEM part number is the true factory part for that model, report the true factory OEM part in OEM_PART and warn clearly in Russian in COMPAT_NOTE_RU.
3. Search Google for BOTH:
   a) Cheap / aftermarket & Prime options on amazon.ca ("<OEM_PART> site:amazon.ca"), ebay.ca, walmart.ca, and xpartsupply.com; AND
   b) Genuine OEM options at Canadian parts distributors (amresupply.com, partsofcanada.com, appliancepartscanada.ca, reliableparts.ca, partselect.ca).
4. Write your findings (include any direct amazon.ca/dp/... product URLs you found in BUDGET_URLS) and ALWAYS finish with these exact tagged lines at the very end:
NEEDS_CLARIFICATION: <YES or NO>
CLARIFY_RU: <Russian clarification question if NEEDS_CLARIFICATION is YES, otherwise empty>
OEM_PART: <exact primary OEM part number, e.g. W10876537 or 00631200 or DC47-00019A>
PART_NAME_RU: <concise Russian part name>
PART_NAME_EN: <concise English part name>
REPLACES: <comma-separated verified cross-reference / superseded part numbers>
FITS_MODEL: <YES, NO, or UNKNOWN>
COMPAT_NOTE_RU: <1 concise Russian sentence about verified compatibility or assembly notes>
BUDGET_URLS: <comma-separated direct https://www.amazon.ca/.../dp/... or https://www.ebay.ca/itm/... URLs found, or NONE>
''';

    final res = await _callGeminiRest(
      apiKey: apiKey,
      prompt: prompt,
      tools: const [
        {'google_search': {}},
      ],
      timeout: const Duration(seconds: 22),
    );
    if (res == null) {
      return _GroundedIdentification(oemPart: explicitPartNumber);
    }

    final text = res.text;
    final resolvedLinks = await _resolveGroundingChunks(res.chunks);

    String tag(String key) {
      final m = RegExp(
        '^$key:\\s*(.*)\$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(text);
      return (m?.group(1) ?? '').trim();
    }

    final needsClarify = tag('NEEDS_CLARIFICATION').toUpperCase() == 'YES';
    final clarifyRu = tag('CLARIFY_RU');
    final rawOem = tag('OEM_PART')
        .replaceAll('`', '')
        .replaceAll('*', '')
        .trim();
    final oemPart = (rawOem.toLowerCase() == 'none' ||
            rawOem.toLowerCase() == 'unknown' ||
            rawOem.toLowerCase() == 'null')
        ? ''
        : rawOem;
    final replaces = tag('REPLACES')
        .split(RegExp(r'[,;]'))
        .map((s) => s.replaceAll('`', '').replaceAll('*', '').trim())
        .where(
          (s) =>
              s.length >= 4 &&
              s.toLowerCase() != 'none' &&
              s.toLowerCase() != 'n/a',
        )
        .toList();
    final fitsRaw = tag('FITS_MODEL').toUpperCase();
    final bool? fitsModel = switch (fitsRaw) {
      'YES' => true,
      'NO' => false,
      _ => null,
    };
    final explicitBudgetUrls = tag('BUDGET_URLS')
        .split(RegExp(r'[\s,;]+'))
        .map((s) => s.replaceAll('`', '').replaceAll('*', '').trim())
        .where((s) => s.startsWith('http'))
        .map(
          (u) => PartCandidateLink(
            url: u,
            title: oemPart.isNotEmpty ? oemPart : explicitPartNumber,
            source: 'google_budget',
          ),
        )
        .toList();

    return _GroundedIdentification(
      needsClarification: needsClarify,
      clarifyMessage: clarifyRu,
      oemPart: oemPart.isNotEmpty ? oemPart : explicitPartNumber,
      partNameRu: tag('PART_NAME_RU'),
      partNameEn: tag('PART_NAME_EN'),
      replaces: replaces,
      fitsModel: fitsModel,
      compatNoteRu: tag('COMPAT_NOTE_RU'),
      groundedLinks: [...explicitBudgetUrls, ...resolvedLinks],
    );
  }

  static Future<List<PartCandidateLink>> _resolveGroundingChunks(
    List<({String title, String uri})> chunks,
  ) async {
    if (chunks.isEmpty) return const [];
    final resolved = await Future.wait(
      chunks.take(18).map((chunk) async {
        final rawUri = chunk.uri.trim();
        if (rawUri.isEmpty) return null;
        var finalUrl = rawUri;
        if (rawUri.contains('grounding-api-redirect')) {
          final loc = await _resolveRedirectLocation(Uri.parse(rawUri));
          if (loc == null || loc.isEmpty) return null;
          finalUrl = loc;
        }
        return PartCandidateLink(
          url: finalUrl,
          title: chunk.title,
          source: 'google_grounding',
        );
      }),
    );
    return resolved.whereType<PartCandidateLink>().toList();
  }

  static Future<({List<PartOffer> offers, int checked, int rejected})>
  _verifyCandidateLinks({
    required String apiKey,
    required List<PartCandidateLink> candidates,
    required String canonicalPart,
    required Set<String> allowedNumbers,
    required String brand,
  }) async {
    if (candidates.isEmpty) {
      return (offers: const <PartOffer>[], checked: 0, rejected: 0);
    }

    final directOffers = <PartOffer>[];
    final needsUrlContext = <PartCandidateLink>[];
    var rejected = 0;

    final probes = await Future.wait(
      candidates.map((cand) async {
        final uri = Uri.parse(cand.url);
        final host = _cleanHost(uri.host);
        try {
          if (cand.url.contains('/products/')) {
            final shopifyProductJson = await _tryVerifyShopifyProductUrl(
              uri: uri,
              canonicalPart: canonicalPart,
              allowedNumbers: allowedNumbers,
              brand: brand,
            );
            if (shopifyProductJson != null) {
              return (
                offer: shopifyProductJson.offer,
                cfBlocked: false,
                rejected: !shopifyProductJson.accepted,
                cand: cand,
              );
            }
          }

          final resp = await _httpGet(
            uri,
            timeout: const Duration(seconds: 6),
          );
          if (resp.statusCode == 404 ||
              resp.statusCode == 410 ||
              resp.statusCode >= 500) {
            if (isCloudflareChallenge(resp.statusCode, resp.body)) {
              return (
                offer: null,
                cfBlocked: true,
                rejected: false,
                cand: cand,
              );
            }
            return (offer: null, cfBlocked: false, rejected: true, cand: cand);
          }

          if (isCloudflareChallenge(resp.statusCode, resp.body) ||
              isAmazonBotChallenge(resp.statusCode, resp.body, host) ||
              resp.statusCode == 403) {
            if (!host.contains('amazon.') &&
                !textMatchesAllowedPart(
                  '${cand.url} ${cand.title} ${cand.snippet}',
                  allowedNumbers,
                )) {
              return (
                offer: null,
                cfBlocked: false,
                rejected: true,
                cand: cand,
              );
            }
            return (offer: null, cfBlocked: true, rejected: false, cand: cand);
          }

          if (resp.statusCode != 200) {
            return (offer: null, cfBlocked: false, rejected: true, cand: cand);
          }

          final html = resp.body;
          if (isAmazonBotChallenge(resp.statusCode, html, host)) {
            return (offer: null, cfBlocked: true, rejected: false, cand: cand);
          }
          if (isSoft404OrOutOfStockHtml(html, host)) {
            return (offer: null, cfBlocked: false, rejected: true, cand: cand);
          }

          final parsed = parseProductHtml(html, host);
          final identitySample =
              '${cand.url} ${parsed.title} ${cand.title}';
          final bodyMatches = textMatchesAllowedPart(
                identitySample,
                allowedNumbers,
              ) ||
              textMatchesAllowedPart(
                html.length > 60000 ? html.substring(0, 60000) : html,
                allowedNumbers,
              );
          if (!bodyMatches) {
            return (offer: null, cfBlocked: false, rejected: true, cand: cand);
          }

          if (parsed.inStock == false) {
            return (offer: null, cfBlocked: false, rejected: true, cand: cand);
          }

          if (parsed.inStock == true && parsed.price != null) {
            final store = _storeDisplayName(host);
            return (
              offer: PartOffer(
                store: store,
                url: cand.url,
                title: parsed.title.isNotEmpty
                    ? parsed.title
                    : (cand.title.isNotEmpty ? cand.title : canonicalPart),
                matchedPartNumber: _pickMatchedNumber(
                  identitySample,
                  canonicalPart,
                  allowedNumbers,
                ),
                price: parsed.price,
                currency: parsed.currency,
                inStock: true,
                stockNote: _t(
                  'В наличии (проверено на странице товара)',
                  'In stock (verified on live product page)',
                ),
                isOem: classifyOem(
                  storeName: store,
                  host: host,
                  title: parsed.title,
                  brand: brand,
                ),
                verificationMethod: 'live_html',
              ),
              cfBlocked: false,
              rejected: false,
              cand: cand,
            );
          }

          return (offer: null, cfBlocked: true, rejected: false, cand: cand);
        } catch (_) {
          if (textMatchesAllowedPart(
            '${cand.url} ${cand.title} ${cand.snippet}',
            allowedNumbers,
          )) {
            return (offer: null, cfBlocked: true, rejected: false, cand: cand);
          }
          return (offer: null, cfBlocked: false, rejected: true, cand: cand);
        }
      }),
    );

    for (final p in probes) {
      if (p.offer != null) {
        directOffers.add(p.offer!);
      } else if (p.cfBlocked) {
        needsUrlContext.add(p.cand);
      } else if (p.rejected) {
        rejected++;
      }
    }

    if (needsUrlContext.isNotEmpty &&
        apiKey.isNotEmpty &&
        apiKey != 'YOUR_GEMINI_API_KEY') {
      final batch = needsUrlContext.take(10).toList();
      final batchVerified = await _verifyBatchWithUrlContext(
        apiKey: apiKey,
        candidates: batch,
        canonicalPart: canonicalPart,
        allowedNumbers: allowedNumbers,
        brand: brand,
      );
      directOffers.addAll(batchVerified.offers);
      rejected += batchVerified.rejected;
    }

    return (
      offers: directOffers,
      checked: candidates.length,
      rejected: rejected,
    );
  }

  static Future<({PartOffer? offer, bool accepted})?> _tryVerifyShopifyProductUrl({
    required Uri uri,
    required String canonicalPart,
    required Set<String> allowedNumbers,
    required String brand,
  }) async {
    final base = '${uri.scheme}://${uri.host}';
    final cleanPath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (!cleanPath.contains('/products/')) return null;
    try {
      final results = await Future.wait([
        _httpGet(
          Uri.parse('$base$cleanPath.json'),
          timeout: const Duration(seconds: 5),
          accept: 'application/json',
        ),
        _httpGet(
          Uri.parse('$base/meta.json'),
          timeout: const Duration(seconds: 4),
          accept: 'application/json',
        ),
      ]);
      final prodResp = results[0];
      if (prodResp.statusCode != 200) return null;
      final prodJson = json.decode(prodResp.body);
      if (prodJson is! Map || prodJson['product'] is! Map) return null;
      final product = prodJson['product'] as Map;
      final title = '${product['title'] ?? ''}'.trim();
      final handle = '${product['handle'] ?? ''}'.trim();
      final vendor = '${product['vendor'] ?? ''}'.trim();
      final variants = product['variants'] is List
          ? product['variants'] as List
          : const [];

      var currency = _defaultCurrencyForHost(_cleanHost(uri.host));
      if (results[1].statusCode == 200) {
        try {
          final meta = json.decode(results[1].body);
          if (meta is Map && '${meta['currency'] ?? ''}'.length == 3) {
            currency = '${meta['currency']}'.toUpperCase();
          }
        } catch (_) {}
      }

      final skus = <String>[];
      double? bestPrice;
      var anyAvailable = false;
      for (final v in variants) {
        if (v is! Map) continue;
        final sku = '${v['sku'] ?? ''}'.trim();
        if (sku.isNotEmpty) skus.add(sku);
        final avail = v['available'];
        if (avail == false) continue;
        final p = _parsePriceValue(v['price']);
        if (p != null && p > 0) {
          anyAvailable = true;
          if (bestPrice == null || p < bestPrice) bestPrice = p;
        }
      }

      final identity = '$title $handle ${skus.join(' ')}';
      if (!textMatchesAllowedPart(identity, allowedNumbers)) {
        return (offer: null, accepted: false);
      }

      final htmlResp = await _httpGet(uri, timeout: const Duration(seconds: 5));
      if (htmlResp.statusCode == 200 &&
          isSoft404OrOutOfStockHtml(htmlResp.body, _cleanHost(uri.host))) {
        return (offer: null, accepted: false);
      }

      if (!anyAvailable || bestPrice == null) {
        return (offer: null, accepted: false);
      }

      final host = _cleanHost(uri.host);
      final store = _storeDisplayName(host);
      return (
        offer: PartOffer(
          store: store,
          url: '$base$cleanPath',
          title: title.isEmpty ? canonicalPart : title,
          matchedPartNumber: _pickMatchedNumber(
            identity,
            canonicalPart,
            allowedNumbers,
          ),
          price: bestPrice,
          currency: currency,
          inStock: true,
          stockNote: _t(
            'В наличии (проверено по карточке магазина)',
            'In stock (verified via store product feed)',
          ),
          isOem: classifyOem(
            storeName: store,
            host: host,
            title: title,
            vendor: vendor,
            skuText: skus.join(' '),
            brand: brand,
          ),
          verificationMethod: 'store_api',
        ),
        accepted: true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<({List<PartOffer> offers, int rejected})>
  _verifyBatchWithUrlContext({
    required String apiKey,
    required List<PartCandidateLink> candidates,
    required String canonicalPart,
    required Set<String> allowedNumbers,
    required String brand,
  }) async {
    final numbered = StringBuffer();
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      numbered.writeln(
        'ITEM ${i + 1}: URL=${c.url} | TITLE=${c.title} | SNIPPET=${c.snippet}',
      );
    }

    final prompt = '''
Verify each exact appliance part product URL below using URL Context and Google Search.
Target OEM part number: $canonicalPart (allowed cross-references: ${allowedNumbers.join(', ')}).

$numbered

Strict verification rules:
- Check whether each exact URL is an active product page selling $canonicalPart (or one of the allowed cross-references above), NOT a 404/dead listing, NOT a category page, and NOT a different part.
- Check live stock availability: mark IN_STOCK only when confirmed in stock / stocked item / available to ship now. If out of stock, backordered, discontinued, or dead link, mark OUT_OF_STOCK or DEAD.
- Report the exact numeric price on that listing (do NOT invent a price; write NONE if no price is publicly shown). Specify CAD or USD accurately.
- Output one block per item in this exact format:
ITEM <N>
STATUS: <ACTIVE or DEAD or WRONG_PART>
PART_NUMBER: <part number on that page>
STOCK: <IN_STOCK or OUT_OF_STOCK or BACKORDER or UNKNOWN>
PRICE: <number like 105.50 or NONE>
CURRENCY: <CAD or USD>
TYPE: <OEM or AFTERMARKET>
TITLE: <clean product title>
''';

    final res = await _callGeminiRest(
      apiKey: apiKey,
      prompt: prompt,
      tools: const [
        {'url_context': {}},
        {'google_search': {}},
      ],
      timeout: const Duration(seconds: 18),
    );
    if (res == null) {
      return (offers: const <PartOffer>[], rejected: candidates.length);
    }

    return parseBatchVerificationResponse(
      text: res.text,
      candidates: candidates,
      canonicalPart: canonicalPart,
      allowedNumbers: allowedNumbers,
      brand: brand,
    );
  }

  @visibleForTesting
  static ({List<PartOffer> offers, int rejected})
  parseBatchVerificationResponse({
    required String text,
    List<({String url, String title, String snippet})> candidateRecords =
        const [],
    List<PartCandidateLink>? candidates,
    required String canonicalPart,
    required Set<String> allowedNumbers,
    String brand = '',
  }) {
    final items =
        candidates ??
        [
          for (final r in candidateRecords)
            PartCandidateLink(
              url: r.url,
              title: r.title,
              snippet: r.snippet,
              source: 'test',
            ),
        ];

    final offers = <PartOffer>[];
    var rejected = 0;

    for (var i = 0; i < items.length; i++) {
      final idx = i + 1;
      final cand = items[i];
      final blockRe = RegExp(
        'ITEM\\s+$idx\\b([\\s\\S]*?)(?=ITEM\\s+\\d+\\b|\$)',
        caseSensitive: false,
      );
      final match = blockRe.firstMatch(text);
      if (match == null) {
        rejected++;
        continue;
      }
      final block = match.group(1)!;
      String field(String name) {
        final m = RegExp(
          '^\\s*[-*]*\\s*$name:\\s*(.*)\$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(block);
        return (m?.group(1) ?? '')
            .replaceAll('`', '')
            .replaceAll('*', '')
            .trim();
      }

      final status = field('STATUS').toUpperCase();
      final partOnPage = field('PART_NUMBER');
      final stock = field('STOCK').toUpperCase();
      final priceRaw = field('PRICE');
      final curRaw = field('CURRENCY').toUpperCase();
      final typeRaw = field('TYPE').toUpperCase();
      final cleanTitle = field('TITLE');

      if (!status.contains('ACTIVE')) {
        rejected++;
        continue;
      }
      if (stock != 'IN_STOCK') {
        rejected++;
        continue;
      }
      if (!textMatchesAllowedPart(
        '$partOnPage ${cand.url} $cleanTitle ${cand.title}',
        allowedNumbers,
      )) {
        rejected++;
        continue;
      }

      final price = _parsePriceValue(priceRaw);
      final host = _cleanHost(Uri.parse(cand.url).host);
      final currency = (curRaw == 'USD' || curRaw == 'CAD')
          ? curRaw
          : _defaultCurrencyForHost(host);
      final store = _storeDisplayName(host);
      final bool? isOem = switch (typeRaw) {
        'OEM' => true,
        'AFTERMARKET' => false,
        _ => classifyOem(
          storeName: store,
          host: host,
          title: cleanTitle.isNotEmpty ? cleanTitle : cand.title,
          brand: brand,
        ),
      };

      offers.add(
        PartOffer(
          store: store,
          url: cand.url,
          title: cleanTitle.isNotEmpty
              ? cleanTitle
              : (cand.title.isNotEmpty ? cand.title : canonicalPart),
          matchedPartNumber: _pickMatchedNumber(
            '$partOnPage ${cand.url}',
            canonicalPart,
            allowedNumbers,
          ),
          price: price,
          currency: currency,
          inStock: true,
          stockNote: _t(
            'В наличии (проверено в каталоге магазина)',
            'In stock (verified in store catalog)',
          ),
          isOem: isOem,
          verificationMethod: 'url_context',
        ),
      );
    }

    return (offers: offers, rejected: rejected);
  }

  static Future<({String text, List<({String title, String uri})> chunks})?>
  _callGeminiRest({
    required String apiKey,
    required String prompt,
    required List<Map<String, dynamic>> tools,
    required Duration timeout,
  }) async {
    for (final candidate in _groundedModels) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '${candidate.name}:generateContent?key=$apiKey',
      );
      final body = <String, dynamic>{
        if (candidate.thinkingZero)
          'generationConfig': {
            'thinkingConfig': {'thinkingBudget': 0},
          },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'tools': tools,
      };
      try {
        final resp = await _httpPostJson(uri, body, timeout: timeout);
        if (resp.statusCode != 200) {
          debugPrint(
            'PartSearchService ${candidate.name}: ${resp.statusCode}',
          );
          continue;
        }
        final decoded = json.decode(resp.body);
        if (decoded is! Map) continue;
        final cands = decoded['candidates'];
        if (cands is! List || cands.isEmpty || cands.first is! Map) continue;
        final first = cands.first as Map;
        final parts = first['content']?['parts'];
        final buf = StringBuffer();
        if (parts is List) {
          for (final p in parts) {
            if (p is Map && p['text'] is String) {
              buf.writeln(p['text'] as String);
            }
          }
        }
        final text = buf.toString().trim();
        if (text.isEmpty) continue;

        final chunks = <({String title, String uri})>[];
        final rawChunks = first['groundingMetadata']?['groundingChunks'];
        if (rawChunks is List) {
          for (final ch in rawChunks) {
            if (ch is Map && ch['web'] is Map) {
              final web = ch['web'] as Map;
              final u = '${web['uri'] ?? ''}'.trim();
              if (u.isNotEmpty) {
                chunks.add((title: '${web['title'] ?? ''}'.trim(), uri: u));
              }
            }
          }
        }
        return (text: text, chunks: chunks);
      } catch (e) {
        debugPrint('PartSearchService ${candidate.name} err: $e');
      }
    }
    return null;
  }

  static Future<http.Response> _httpGet(
    Uri uri, {
    required Duration timeout,
    String accept = 'text/html,application/xhtml+xml,application/json',
  }) async {
    final client = http.Client();
    try {
      return await client
          .get(
            uri,
            headers: {
              'User-Agent': _ua,
              'Accept': accept,
              'Accept-Language': 'en-CA,en;q=0.9',
            },
          )
          .timeout(timeout);
    } finally {
      client.close();
    }
  }

  static Future<http.Response> _httpPostJson(
    Uri uri,
    Map<String, dynamic> payload, {
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      return await client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(timeout);
    } finally {
      client.close();
    }
  }

  static Future<String?> _resolveRedirectLocation(Uri uri) async {
    final client = http.Client();
    try {
      final req = http.Request('HEAD', uri)
        ..followRedirects = false
        ..headers['User-Agent'] = _ua;
      final resp = await client.send(req).timeout(const Duration(seconds: 4));
      await resp.stream.drain<void>();
      final loc = resp.headers['location']?.trim();
      if (loc != null && loc.startsWith('http')) return loc;
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static double? _parsePriceValue(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw > 0 ? raw.toDouble() : null;
    final s = raw.toString().trim();
    if (s.isEmpty || s.toUpperCase() == 'NONE' || s.toUpperCase() == 'N/A') {
      return null;
    }
    final m = RegExp(r'(\d{1,5}(?:\.\d{1,2})?)').firstMatch(
      s.replaceAll(',', ''),
    );
    if (m == null) return null;
    final val = double.tryParse(m.group(1)!);
    return (val != null && val > 0) ? val : null;
  }

  static String _pickMatchedNumber(
    String text,
    String canonicalPart,
    Set<String> allowed,
  ) {
    final normText = WarehouseItem.normalizePart(text);
    final canonNorm = WarehouseItem.normalizePart(canonicalPart);
    if (canonNorm.isNotEmpty && normText.contains(canonNorm)) {
      return canonicalPart;
    }
    for (final item in allowed) {
      if (normText.contains(item)) return item;
    }
    return canonicalPart;
  }

  static String _cleanHost(String host) =>
      host.trim().toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

  static String _defaultCurrencyForHost(String host) {
    if (host.endsWith('.ca') ||
        host == 'partsofcanada.com' ||
        host == 'xpartsupply.com' ||
        host == 'amresupply.com') {
      return 'CAD';
    }
    return 'USD';
  }

  static String _storeDisplayName(String host) {
    if (host.contains('partselect.ca')) return 'PartSelect Canada';
    if (host.contains('partselect.com')) return 'PartSelect (US)';
    if (host.contains('reliableparts.ca')) return 'Reliable Parts Canada';
    if (host.contains('reliableparts.com')) return 'Reliable Parts';
    if (host.contains('amresupply.com')) return 'AMRE Supply (Canada)';
    if (host.contains('partsofcanada.com')) return 'Parts of Canada';
    if (host.contains('xpartsupply.com')) return 'XPart Supply (ON)';
    if (host.contains('appliancepartscanada.ca')) {
      return 'Appliance Parts Canada';
    }
    if (host.contains('homedepot.ca')) return 'Home Depot Parts Canada';
    if (host.contains('amazon.ca')) return 'Amazon.ca';
    if (host.contains('walmart.ca')) return 'Walmart Canada';
    if (host.contains('ebay.ca')) return 'eBay Canada';
    if (host.contains('ebay.com')) return 'eBay';
    if (host.contains('bestbuy.ca')) return 'Best Buy Canada';
    if (host.contains('repairclinic.com')) return 'RepairClinic';
    if (host.contains('appliancepartspros.com')) return 'AppliancePartsPros';
    return host;
  }

  static String _stripTags(String html) {
    return _decodeHtmlEntities(
      html.replaceAll(RegExp(r'<[^>]+>'), ' '),
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }
}
