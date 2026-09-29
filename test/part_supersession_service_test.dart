import 'package:fix_appliance_crm/services/part_supersession_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('разбор ответа каталога', () {
    test('страница товара: берём актуальный Part #', () {
      final hit = PartSupersessionService.parseLookup(
        '<h2 class="partNumber">Part #: 279834</h2>'
        '{"sku": "279834"}',
        'https://applianceparts.homedepot.ca/product/'
            'amana_whirlpool_dryer_valve_coil_kit_2_pieces_279834',
        '279834',
      );
      expect(hit, isNotNull);
      expect(hit!.canonical, '279834');
      expect(hit.replacesFromUrl, isEmpty);
    });

    test('старый номер приводит на новый с ?replaces= в адресе', () {
      final hit = PartSupersessionService.parseLookup(
        '<h2 class="partNumber">Part #: WP3392519</h2>'
        '<div>WP3392519 Whirlpool Dryer Thermal fuse</div>',
        'https://applianceparts.homedepot.ca/product/'
            'amana_whirlpool_dryer_thermal_fuse_wp3392519?replaces=3392519',
        '3392519',
      );
      expect(hit, isNotNull);
      expect(hit!.canonical, 'WP3392519');
      expect(hit.canonicalNorm, 'WP3392519');
      expect(hit.replacesFromUrl, '3392519');
    });

    test('страница товара без Part #: — из JSON-LD sku', () {
      final hit = PartSupersessionService.parseLookup(
        '{"sku": "WP3392519", "mpn": "WP3392519"}',
        'https://applianceparts.homedepot.ca/product/wp3392519',
        'WP3392519',
      );
      expect(hit, isNotNull);
      expect(hit!.canonical, 'WP3392519');
    });

    test('выдача: берём только точный номер', () {
      const html =
          '<script>var product0 = new Array();product0.partNumber = "SMG DC47-00018A";'
          'product0.url = "/product/21429747";</script>'
          '<script>var product1 = new Array();product1.partNumber = "SMG DC47-00018A EXTRA";'
          'product1.url = "/product/21459961";</script>';
      final hit = PartSupersessionService.parseLookup(
        html,
        'https://applianceparts.homedepot.ca/search?q=DC47-00018A',
        'DC47-00018A',
      );
      expect(hit, isNotNull);
      expect(hit!.canonical, 'SMG DC47-00018A');
    });

    test('выдача без нашего номера — каталог деталь не знает', () {
      const html =
          '<script>var product0 = new Array();product0.partNumber = "WP3392519";'
          'product0.url = "/product/1";</script>';
      final hit = PartSupersessionService.parseLookup(
        html,
        'https://applianceparts.homedepot.ca/search?q=W10295370',
        'W10295370',
      );
      expect(hit, isNull);
    });
  });

  group('вердикт по замене', () {
    const wpOld = PartCatalogHit(canonical: 'WP3392519', replacesFromUrl: '3392519');
    const wpNew = PartCatalogHit(canonical: 'WP3392519');
    const coil = PartCatalogHit(canonical: '279834');

    test('та же деталь: поиск старого номера дал карточку кандидата', () {
      final verdict = PartSupersessionService.decide(
        '3392519',
        'WP3392519',
        wantedHit: wpOld,
        candidateHit: wpNew,
      );
      expect(verdict, SupersessionVerdict.replaces);
    });

    test('та же деталь наоборот: карточка кандидата зовётся нашим номером', () {
      final verdict = PartSupersessionService.decide(
        'WP3392519',
        '3392519',
        wantedHit: wpNew,
        candidateHit: wpOld,
      );
      expect(verdict, SupersessionVerdict.replaces);
    });

    test('разные детали: каталог знает оба номера и это разные карточки', () {
      final verdict = PartSupersessionService.decide(
        'WP3392519',
        '279834',
        wantedHit: wpNew,
        candidateHit: coil,
      );
      expect(verdict, SupersessionVerdict.different);
    });

    test('каталог знает только один номер — не опровергаем', () {
      final verdict = PartSupersessionService.decide(
        'DC9716350C',
        'W10295370',
        wantedHit: null,
        candidateHit: wpNew,
      );
      expect(verdict, SupersessionVerdict.unknown);
    });

    test('без сети и каталога срабатывает родной WP-префикс', () {
      final verdict = PartSupersessionService.decide(
        'W10311524',
        'WPW10311524',
      );
      expect(verdict, SupersessionVerdict.replaces);
    });

    test('полный произвол ИИ без каких-либо подтверждений — unknown', () {
      final verdict = PartSupersessionService.decide(
        'WPW10515039',
        '279834',
      );
      expect(verdict, SupersessionVerdict.unknown);
    });

    test('каталог знает оба, одна карточка на двоих — замена', () {
      final verdict = PartSupersessionService.decide(
        'W10311524',
        'WPW10311524',
        wantedHit: const PartCatalogHit(canonical: 'W10311524'),
        candidateHit: const PartCatalogHit(canonical: 'W10311524'),
      );
      expect(verdict, SupersessionVerdict.replaces);
    });
  });
}
