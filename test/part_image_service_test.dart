import 'package:fix_appliance_crm/services/part_image_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('каталог запчастей', () {
    test('одна деталь — ссылка на большое фото с её номером', () {
      const html = '<title>Samsung Dryer Thermostat DC47-00018A</title>'
          '<div style="background: #fff url(https://applianceparts.homedepot.ca'
          '/thumbnail/product/2705759/300/200)"></div><span>DC47-00018A</span>';
      final rows = PartImageService.parseCatalog(
        html,
        'https://applianceparts.homedepot.ca/product/21429747',
        'DC47-00018A',
      );
      expect(rows, hasLength(1));
      expect(
        rows.first.image,
        'https://applianceparts.homedepot.ca/thumbnail/product/2705759/1600/1200/DC47-00018A.jpg',
      );
    });

    test('карточка чужой детали не выдаётся за нашу', () {
      const html = '<title>Other part</title>'
          '<div style="url(https://applianceparts.homedepot.ca'
          '/thumbnail/product/111/300/200)"></div>';
      final rows = PartImageService.parseCatalog(
        html,
        'https://applianceparts.homedepot.ca/product/999',
        'DC47-00018A',
      );
      expect(rows, isEmpty);
    });

    test('в списке берём только плитку с нашим номером', () {
      const html =
          '<script>var product0 = new Array();product0.partNumber = "SMG DC47-00018A";'
          'product0.url = "/product/21429747";</script>'
          '<script>var product1 = new Array();product1.partNumber = "SMG DC47-00019B";'
          'product1.url = "/product/21459961";</script>'
          '<a href="https://applianceparts.homedepot.ca/product/21429747" class="product-image" '
          'style="background: #fff url(https://applianceparts.homedepot.ca/thumbnail/product/2705759/300/200)"></a>'
          '<a href="https://applianceparts.homedepot.ca/product/21459961" class="product-image" '
          'style="background: #fff url(https://applianceparts.homedepot.ca/thumbnail/product/3297951/300/200)"></a>';
      final rows = PartImageService.parseCatalog(
        html,
        'https://applianceparts.homedepot.ca/search?q=DC47-00018A',
        'DC47-00018A',
      );
      expect(rows, hasLength(1));
      expect(rows.first.image, contains('/2705759/1600/1200/'));
      expect(
        rows.first.page,
        'https://applianceparts.homedepot.ca/product/21429747',
      );
    });
  });

  group('выдача картинок', () {
    test('достаём ссылку на файл и на страницу', () {
      const html = '<a class="iusc" m="{&quot;cid&quot;:&quot;1&quot;,'
          '&quot;murl&quot;:&quot;https://photos.partsdr.com/large/WPW10730972_4.jpg&quot;,'
          '&quot;purl&quot;:&quot;https://www.partsdr.com/part/WPW10730972&quot;,'
          '&quot;t&quot;:&quot;Whirlpool Drain Pump&quot;}">x</a>';
      final rows = PartImageService.parseBing(html);
      expect(rows, hasLength(1));
      expect(rows.first.image, 'https://photos.partsdr.com/large/WPW10730972_4.jpg');
      expect(rows.first.page, 'https://www.partsdr.com/part/WPW10730972');
    });

    test('битый json не роняет разбор', () {
      expect(PartImageService.parseBing('<a m="{&quot;murl&quot;:}">x</a>'), isEmpty);
    });
  });
}
