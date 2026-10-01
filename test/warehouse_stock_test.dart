import 'package:fix_appliance_crm/models/warehouse_item.dart';
import 'package:fix_appliance_crm/services/warehouse_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Склад двигается только счётом. Если расчёт списания соврёт, владелец
/// поедет на вызов без детали — поэтому он закрыт тестом.
void main() {
  Map<String, dynamic> invoice(List<Map<String, dynamic>> items) => {
    'type': 'Invoice',
    'items': items,
  };

  group('stockDeltas', () {
    test('списывает по количеству в строке', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'warehouseItemId': 'w1', 'qty': 2},
          {'warehouseItemId': 'w2', 'qty': 1},
        ]),
        reverse: false,
      );

      expect(deltas, {'w1': -2, 'w2': -1});
    });

    test('возврат при удалении счёта — та же величина с плюсом', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'warehouseItemId': 'w1', 'qty': 2},
        ]),
        reverse: true,
      );

      expect(deltas, {'w1': 2});
    });

    test('одна деталь в двух строках складывается в одну правку', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'warehouseItemId': 'w1', 'qty': 1},
          {'warehouseItemId': 'w1', 'qty': 3},
        ]),
        reverse: false,
      );

      expect(deltas, {'w1': -4});
    });

    test('работа и позиции без склада не трогают остатки', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'name': 'Диагностика', 'qty': 1, 'price': 99},
          {'warehouseItemId': '', 'qty': 1},
          {'warehouseItemId': '   ', 'qty': 1},
        ]),
        reverse: false,
      );

      expect(deltas, isEmpty);
    });

    test('количество строкой и пропущенное количество', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'warehouseItemId': 'w1', 'qty': '2'},
          {'warehouseItemId': 'w2'},
        ]),
        reverse: false,
      );

      expect(deltas, {'w1': -2, 'w2': -1});
    });

    test('нулевое количество не создаёт пустую правку', () {
      final deltas = WarehouseService.stockDeltas(
        invoice([
          {'warehouseItemId': 'w1', 'qty': 0},
        ]),
        reverse: false,
      );

      expect(deltas, isEmpty);
    });

    test('мусор в позициях не роняет расчёт', () {
      expect(
        WarehouseService.stockDeltas(
          {'type': 'Invoice', 'items': 'не список'},
          reverse: false,
        ),
        isEmpty,
      );
      expect(
        WarehouseService.stockDeltas(
          invoice([]) ..['items'] = ['мусор', 42],
          reverse: false,
        ),
        isEmpty,
      );
    });
  });

  group('shouldApplyStock', () {
    test('смета склад не двигает', () {
      expect(
        WarehouseService.shouldApplyStock(
          {'type': 'Estimate'},
          reverse: false,
        ),
        isFalse,
      );
    });

    test('новый счёт списывает, второй раз — нет', () {
      final doc = invoice([
        {'warehouseItemId': 'w1', 'qty': 1},
      ]);
      expect(WarehouseService.shouldApplyStock(doc, reverse: false), isTrue);
      doc['stockApplied'] = true;
      expect(WarehouseService.shouldApplyStock(doc, reverse: false), isFalse);
    });

    test('вернуть можно только то, что списано', () {
      final doc = invoice([
        {'warehouseItemId': 'w1', 'qty': 1},
      ]);
      expect(WarehouseService.shouldApplyStock(doc, reverse: true), isFalse);
      doc['stockApplied'] = true;
      expect(WarehouseService.shouldApplyStock(doc, reverse: true), isTrue);
    });
  });

  group('фотографии карточки', () {
    test('первым идёт снимок с плитки, повторов нет', () {
      expect(
        WarehouseItem.galleryOf(
          imageUrl: 'a.jpg',
          webImageUrl: 'web.jpg',
          photos: ['b.jpg', 'a.jpg', 'web.jpg'],
        ),
        ['web.jpg', 'a.jpg', 'b.jpg'],
      );
    });

    test('без каталожной картинки первым идёт своё фото', () {
      expect(
        WarehouseItem.galleryOf(imageUrl: 'a.jpg', photos: ['b.jpg']),
        ['a.jpg', 'b.jpg'],
      );
    });

    test('пустые поля не попадают в галерею', () {
      expect(
        WarehouseItem.galleryOf(
          imageUrl: '',
          webImageUrl: '   ',
          photos: ['', 'b.jpg'],
        ),
        ['b.jpg'],
      );
    });

    test('обложка, выбранная долгим нажатием, идёт первой и в списке', () {
      final item = WarehouseItem.fromMap(
        {
          'name': 'Насос',
          'price': 10,
          'imageUrl': 'a.jpg',
          'webImageUrl': 'web.jpg',
          'photos': ['b.jpg'],
          'coverUrl': 'b.jpg',
        },
        'w1',
      );
      expect(item.galleryUrls, ['b.jpg', 'web.jpg', 'a.jpg']);
      expect(item.displayImageUrl, 'b.jpg');
    });

    test('обложка удалённого снимка не показывается', () {
      expect(
        WarehouseItem.galleryOf(
          coverUrl: 'gone.jpg',
          imageUrl: 'a.jpg',
          webImageUrl: 'web.jpg',
        ),
        ['web.jpg', 'a.jpg'],
      );
    });

    test('старый документ без photos читается', () {
      final item = WarehouseItem.fromMap(
        {'name': 'Ремень', 'imageUrl': 'a.jpg', 'price': 10},
        'w1',
      );
      expect(item.photos, isEmpty);
      expect(item.galleryUrls, ['a.jpg']);
    });

    test('список фото из документа: мусор и повторы отсеиваются', () {
      expect(
        WarehouseItem.parsePhotos(['a.jpg', ' a.jpg ', '', 'b.jpg']),
        ['a.jpg', 'b.jpg'],
      );
      expect(WarehouseItem.parsePhotos(null), isEmpty);
      expect(WarehouseItem.parsePhotos('a.jpg'), ['a.jpg']);
    });
  });
}
