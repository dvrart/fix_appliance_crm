import 'dart:convert';

import 'package:fix_appliance_crm/features/ai/assistant/part_search_screen.dart';
import 'package:fix_appliance_crm/models/warehouse_item.dart';
import 'package:fix_appliance_crm/services/part_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('фильтр и очистка ссылок на запчасти', () {
    test('принимает только реальные карточки товара и отсекает главные/поиск/фейки', () {
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse(
            'https://www.partselect.ca/PS11704799-Bosch-00631200-PUMP-DRAIN.htm',
          ),
        ),
        isTrue,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://www.ebay.ca/itm/204723674900'),
        ),
        isTrue,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://www.amazon.ca/Drain-Pump/dp/B0HLCMY8JW'),
        ),
        isTrue,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://www.walmart.ca/en/ip/Drain-Pump/27UHVXM6BKR9'),
        ),
        isTrue,
      );

      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://www.walmart.ca/'),
        ),
        isFalse,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse(
            'https://www.ebay.ca/itm/Whirlpool-W10876537-Dishwasher-Drain-Pump',
          ),
        ),
        isFalse,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse(
            'https://www.partselect.ca/Models/WDT730PAHZ0/Symptoms/Leaking/',
          ),
        ),
        isFalse,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://www.youtube.com/watch?v=0mqWvrARtlM'),
        ),
        isFalse,
      );
      expect(
        PartSearchService.isLikelyProductUrl(
          Uri.parse('https://partsofcanada.com/collections/dishwasher-parts'),
        ),
        isFalse,
      );
    });

    test('срезает поисковые хвосты, но сохраняет нужный variant', () {
      final cleaned = PartSearchService.cleanProductUrl(
        'https://xpartsupply.com/products/00631200-drain-pump?_pos=1&_psq=00631200&_ss=e&variant=50653698',
      );
      expect(
        cleaned,
        'https://xpartsupply.com/products/00631200-drain-pump?variant=50653698',
      );
    });
  });

  group('проверка прямых баз канадских магазинов', () {
    test('берёт только позиции в наличии и отсекает чужие сборки из описания', () {
      final body = json.encode({
        'resources': {
          'results': {
            'products': [
              {
                'title': 'Samsung Dryer heating element DC47-00019A',
                'handle': 'dc47-00019a-electric-dryer-heating-element-1',
                'url': '/products/dc47-00019a-electric-dryer-heating-element-1?_pos=1',
                'price': '79.99',
                'price_min': '79.99',
                'available': true,
                'vendor': 'Samsung',
                'variants': [
                  {'sku': 'XP10003195'},
                ],
              },
              {
                'title': 'Samsung Heater Duct Assembly DC97-14486A',
                'handle': 'dc97-14486a-dryer-heating-element-assembly',
                'url': '/products/dc97-14486a-dryer-heating-element-assembly',
                'price': '97.99',
                'available': true,
                'body': '<p>Includes coil DC47-00019A inside housing</p>',
                'variants': [
                  {'sku': 'DC97-14486AXP'},
                ],
              },
              {
                'title': 'DC47-00019A Out of Stock Listing',
                'handle': 'dc47-00019a-oos',
                'url': '/products/dc47-00019a-oos',
                'price': '29.99',
                'available': false,
              },
            ],
          },
        },
      });

      final allowed = PartSearchService.buildAllowedPartNumbers(
        'DC47-00019A',
        const ['PS4205218', 'AP4201899'],
      );
      final offers = PartSearchService.parseShopifySuggestJson(
        body: body,
        storeName: 'XPart Supply (ON)',
        baseUrl: 'https://xpartsupply.com',
        canonicalPart: 'DC47-00019A',
        allowedNumbers: allowed,
        brand: 'Samsung',
      );

      expect(offers, hasLength(1));
      expect(offers.single.price, 79.99);
      expect(offers.single.currency, 'CAD');
      expect(offers.single.inStock, isTrue);
      expect(offers.single.isOem, isFalse);
      expect(
        offers.single.url,
        'https://xpartsupply.com/products/dc47-00019a-electric-dryer-heating-element-1',
      );
    });
  });

  group('проверка HTML и отсев пустых/недоступных карточек', () {
    test('ловит мёртвый ASIN Amazon и товары OutOfStock', () {
      expect(
        PartSearchService.isSoft404OrOutOfStockHtml(
          '<html><body>Looking for something? We are sorry.</body></html>',
          'amazon.ca',
        ),
        isTrue,
      );
      expect(
        PartSearchService.isSoft404OrOutOfStockHtml(
          '<script type="application/ld+json">'
          '{"@type":"Product","offers":{"availability":"https://schema.org/OutOfStock"}}'
          '</script>',
          'partsofcanada.com',
        ),
        isTrue,
      );
    });

    test('читает цену, валюту и наличие из JSON-LD карточки товара', () {
      const html = '''
<html>
<head>
  <title>Bosch 00631200 Drain Pump</title>
  <script type="application/ld+json">
  {
    "@type": "Product",
    "name": "Bosch 00631200 Dishwasher Drain Pump",
    "sku": "00631200",
    "offers": {
      "@type": "Offer",
      "price": "66.80",
      "priceCurrency": "CAD",
      "availability": "https://schema.org/InStock"
    }
  }
  </script>
</head>
<body>In Stock</body>
</html>
''';
      final parsed = PartSearchService.parseProductHtml(
        html,
        'appliancepartscanada.ca',
      );
      expect(parsed.price, 66.80);
      expect(parsed.currency, 'CAD');
      expect(parsed.inStock, isTrue);
      expect(parsed.title, contains('00631200'));
    });

    test('пакетная перепроверка отбрасывает чужие номера и отсутствие на складе', () {
      const responseText = '''
ITEM 1
STATUS: ACTIVE
PART_NUMBER: W10876537
STOCK: IN_STOCK
PRICE: 105.50
CURRENCY: CAD
TYPE: OEM
TITLE: Whirlpool W10876537 Dishwasher Drain Pump

ITEM 2
STATUS: ACTIVE
PART_NUMBER: W11612327
STOCK: IN_STOCK
PRICE: 89.00
CURRENCY: CAD
TYPE: OEM
TITLE: Whirlpool W11612327 Circulation Pump

ITEM 3
STATUS: ACTIVE
PART_NUMBER: W10876537
STOCK: OUT_OF_STOCK
PRICE: 45.00
CURRENCY: CAD
TYPE: AFTERMARKET
TITLE: W10876537 Drain Pump
''';
      final allowed = PartSearchService.buildAllowedPartNumbers(
        'W10876537',
        const ['PS11738151', 'W10724439'],
      );
      final verified = PartSearchService.parseBatchVerificationResponse(
        text: responseText,
        candidateRecords: const [
          (
            url:
                'https://www.partselect.ca/PS11738151-Whirlpool-W10876537-Pump.htm',
            title: 'W10876537',
            snippet: '',
          ),
          (
            url:
                'https://www.partselect.ca/PS16744935-Whirlpool-W11612327-Pump.htm',
            title: 'W11612327',
            snippet: '',
          ),
          (
            url: 'https://www.walmart.ca/en/ip/W10876537/12345',
            title: 'W10876537',
            snippet: '',
          ),
        ],
        canonicalPart: 'W10876537',
        allowedNumbers: allowed,
        brand: 'Whirlpool',
      );

      expect(verified.offers, hasLength(1));
      expect(verified.rejected, 2);
      expect(verified.offers.single.store, 'PartSelect Canada');
      expect(verified.offers.single.price, 105.50);
    });
  });

  group('сортировка цен и сквозная проверка поиска', () {
    test('сортирует в наличии от самой дешёвой цены с учётом курса USD→CAD', () {
      final sorted = PartSearchService.sortAndDedupeOffers(const [
        PartOffer(
          store: 'PartSelect Canada',
          url: 'https://www.partselect.ca/PS11704799-Bosch-00631200.htm',
          title: 'Bosch Drain Pump',
          matchedPartNumber: '00631200',
          price: 98.00,
          currency: 'CAD',
          inStock: true,
          isOem: true,
          verificationMethod: 'url_context',
        ),
        PartOffer(
          store: 'US Store',
          url: 'https://www.repairclinic.com/ProductDetail/2160266',
          title: 'Drain Pump USD',
          matchedPartNumber: '00631200',
          price: 55.00,
          currency: 'USD',
          inStock: true,
          isOem: true,
          verificationMethod: 'live_html',
        ),
        PartOffer(
          store: 'XPart Supply (ON)',
          url: 'https://xpartsupply.com/products/00631200-drain-pump',
          title: 'Bosch 00631200 Replacement',
          matchedPartNumber: '00631200',
          price: 39.99,
          currency: 'CAD',
          inStock: true,
          isOem: false,
          verificationMethod: 'store_api',
        ),
        PartOffer(
          store: 'Appliance Parts Canada',
          url: 'https://www.appliancepartscanada.ca/products/00631200-pump',
          title: '00631200 Bosch OEM',
          matchedPartNumber: '00631200',
          price: 66.80,
          currency: 'CAD',
          inStock: true,
          isOem: true,
          verificationMethod: 'store_api',
        ),
      ]);

      expect(
        sorted.map((o) => o.store).toList(),
        [
          'XPart Supply (ON)',
          'Appliance Parts Canada',
          'US Store',
          'PartSelect Canada',
        ],
      );
    });

    test('просит уточнение, если не указана ни деталь, ни симптом', () async {
      final result = await PartSearchService.search(
        applianceType: 'Посудомойка',
        brand: 'Bosch',
      );
      expect(result.ok, isFalse);
      expect(result.needsClarification, isTrue);
      expect(result.clarificationMessage, isNotEmpty);
    });

    test('полный цикл: проверяет модель, склад, живые магазины и отсеивает битые ссылки', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        final url = request.url.toString();

        if (url.contains('generativelanguage.googleapis.com')) {
          final payload = json.encode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': '''
Verified Bosch SHXM63W55N/01 parts diagram.
NEEDS_CLARIFICATION: NO
OEM_PART: 00631200
PART_NAME_RU: Сливной насос посудомойки
PART_NAME_EN: Dishwasher Drain Pump
REPLACES: 631200, PS11704799
FITS_MODEL: YES
COMPAT_NOTE_RU: Артикул 00631200 проверен по схеме модели SHXM63W55N/01.
''',
                    },
                  ],
                },
                'groundingMetadata': {
                  'groundingChunks': [
                    {
                      'web': {
                        'title': 'amazon.ca',
                        'uri':
                            'https://vertexaisearch.cloud.google.com/grounding-api-redirect/dead_asin',
                      },
                    },
                  ],
                },
              },
            ],
          });
          return http.StreamedResponse(
            Stream.value(utf8.encode(payload)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }

        if (url.contains('grounding-api-redirect/dead_asin')) {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {
              'location': 'https://www.amazon.ca/Dead-Pump/dp/B0DEAD0001',
            },
          );
        }

        if (url.contains('amazon.ca/Dead-Pump/dp/B0DEAD0001')) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode('<html><body>Looking for something?</body></html>'),
            ),
            200,
          );
        }

        if (url.contains('xpartsupply.com/search/suggest.json')) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                json.encode({
                  'resources': {
                    'results': {
                      'products': [
                        {
                          'title': 'Bosch Dishwasher Drain Pump 00631200',
                          'handle': '00631200-drain-pump',
                          'url': '/products/00631200-drain-pump',
                          'price': '39.99',
                          'available': true,
                          'vendor': 'XPart',
                        },
                      ],
                    },
                  },
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        if (url.contains('appliancepartscanada.ca/search/suggest.json')) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                json.encode({
                  'resources': {
                    'results': {
                      'products': [
                        {
                          'title': '00631200 Bosch Genuine OEM Drain Pump',
                          'handle': '00631200-bosch-oem',
                          'url': '/products/00631200-bosch-oem',
                          'price': '66.80',
                          'available': true,
                          'vendor': 'Bosch',
                        },
                      ],
                    },
                  },
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
      });

      final session = PartSearchSession(
        queryTitle: 'Bosch SHXM63W55N/01',
      );

      final result = await http.runWithClient(
        () => PartSearchService.search(
          applianceType: 'Посудомойка',
          brand: 'Bosch',
          model: 'SHXM63W55N/01',
          problem: 'ошибка E24, не сливает воду',
          session: session,
          apiKeyOverride: 'test-key',
          loadWarehouse: () async => [
            WarehouseItem(
              id: 'w1',
              name: 'Насос Bosch с полки',
              partNumber: '631200',
              price: 95,
              costPrice: 42,
              quantity: 1,
            ),
          ],
        ),
        () => client,
      );

      expect(result.ok, isTrue);
      expect(result.partNumber, '00631200');
      expect(result.fitsModelVerified, isTrue);
      expect(result.warehouseMatches, hasLength(1));
      expect(result.offers, hasLength(2));
      expect(result.cheapestOverall!.store, 'XPart Supply (ON)');
      expect(result.cheapestOverall!.price, 39.99);
      expect(result.cheapestOem!.store, 'Appliance Parts Canada');
      expect(result.cheapestOem!.price, 66.80);
      expect(
        result.offers.any((o) => o.url.contains('B0DEAD0001')),
        isFalse,
      );
      expect(result.rejectedCount, greaterThanOrEqualTo(1));
    });
  });

  testWidgets('экран поиска запчастей показывает шаги проверки и карточки покупки', (
    tester,
  ) async {
    final session = PartSearchSession(
      queryTitle: 'Сливной насос · Bosch SHXM63W55N/01',
    );
    session.advance('Проверяю артикул...');

    await tester.pumpWidget(
      MaterialApp(
        home: PartSearchScreen(initialSession: session),
      ),
    );
    expect(find.text('Проверяю артикул...'), findsOneWidget);

    session.finish(
      const PartSearchResult(
        ok: true,
        partNumber: '00631200',
        partName: 'Сливной насос посудомойки',
        applianceType: 'Посудомойка',
        brand: 'Bosch',
        model: 'SHXM63W55N/01',
        fitsModelVerified: true,
        compatibilityNote: 'Совместим с SHXM63W55N/01',
        warehouseMatches: [
          WarehousePartMatch(
            id: 'w1',
            name: 'Bosch Pump',
            partNumber: '00631200',
            quantity: 2,
            price: 90,
            exact: true,
          ),
        ],
        offers: [
          PartOffer(
            store: 'XPart Supply (ON)',
            url: 'https://xpartsupply.com/products/00631200-drain-pump',
            title: 'Bosch Drain Pump Replacement',
            matchedPartNumber: '00631200',
            price: 39.99,
            currency: 'CAD',
            inStock: true,
            isOem: false,
            verificationMethod: 'store_api',
          ),
          PartOffer(
            store: 'Appliance Parts Canada',
            url: 'https://www.appliancepartscanada.ca/products/00631200-oem',
            title: 'Bosch 00631200 Genuine OEM',
            matchedPartNumber: '00631200',
            price: 66.80,
            currency: 'CAD',
            inStock: true,
            isOem: true,
            verificationMethod: 'store_api',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('00631200'), findsWidgets);
    expect(find.text('XPart Supply (ON)'), findsOneWidget);
    expect(find.text('\$39.99 CAD'), findsOneWidget);
    expect(find.text('Appliance Parts Canada'), findsOneWidget);
    expect(find.text('\$66.80 CAD'), findsOneWidget);
    expect(find.textContaining('Bosch Pump'), findsOneWidget);
  });
}
