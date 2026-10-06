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

  // Позицию счёта можно поправить уже после сохранения. Если не досчитать
  // разницу, остаток на складе разойдётся с тем, что стоит в счёте.
  group('stockChangeDeltas', () {
    Map<String, dynamic> applied(List<Map<String, dynamic>> items) =>
        invoice(items)..['stockApplied'] = true;

    test('количество выросло — списываем разницу', () {
      expect(
        WarehouseService.stockChangeDeltas(
          applied([
            {'warehouseItemId': 'w1', 'qty': 1},
          ]),
          applied([
            {'warehouseItemId': 'w1', 'qty': 3},
          ]),
        ),
        {'w1': -2},
      );
    });

    test('количество уменьшили — лишнее возвращается', () {
      expect(
        WarehouseService.stockChangeDeltas(
          applied([
            {'warehouseItemId': 'w1', 'qty': 3},
          ]),
          applied([
            {'warehouseItemId': 'w1', 'qty': 1},
          ]),
        ),
        {'w1': 2},
      );
    });

    test('имя и цена склад не двигают', () {
      expect(
        WarehouseService.stockChangeDeltas(
          applied([
            {'warehouseItemId': 'w1', 'qty': 2, 'name': 'Насос', 'price': 120},
          ]),
          applied([
            {'warehouseItemId': 'w1', 'qty': 2, 'name': 'Pump', 'price': 150},
          ]),
        ),
        isEmpty,
      );
    });

    test('деталь заменили другой — одну вернули, другую списали', () {
      expect(
        WarehouseService.stockChangeDeltas(
          applied([
            {'warehouseItemId': 'w1', 'qty': 1},
          ]),
          applied([
            {'warehouseItemId': 'w2', 'qty': 1},
          ]),
        ),
        {'w1': 1, 'w2': -1},
      );
    });

    test('несписанный документ (смета) не трогаем', () {
      expect(
        WarehouseService.stockChangeDeltas(
          invoice([
            {'warehouseItemId': 'w1', 'qty': 1},
          ]),
          invoice([
            {'warehouseItemId': 'w1', 'qty': 5},
          ]),
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

  // Деталь, которую не находят по номеру, для склада всё равно что нет:
  // владелец закажет вторую. Поэтому поиск закрыт тестом.
  group('поиск по складу', () {
    final roller = <String, dynamic>{
      'name': 'LG Dryer Roller Assembly',
      'partNumber': '4581EL2002C',
      'modelNumber': 'DLE2515S',
      'category': 'Сушилка',
      'price': 0,
      'interchange': '4561EL3002A, 4400EL2001A',
    };
    final kit = <String, dynamic>{
      'name': 'Dryer Repair Kit',
      'partNumber': '4392067',
      'price': 0,
      'interchange': ['4392067VP', 'PS373088', 'AP3109602'],
    };

    test('свой номер — как напечатан и через дефис', () {
      expect(WarehouseItem.matchesSearch(roller, '4581EL2002C'), isTrue);
      expect(WarehouseItem.matchesSearch(roller, '4581el2002c'), isTrue);
      expect(WarehouseItem.matchesSearch(roller, '4581-EL 2002C'), isTrue);
    });

    test('номер, который деталь заменяет', () {
      expect(WarehouseItem.matchesSearch(roller, '4400EL2001A'), isTrue);
      expect(WarehouseItem.matchesSearch(roller, '4561-EL3002A'), isTrue);
    });

    test('номер с суффиксом магазина и без него', () {
      // В каталоге 4392067VP, на коробке 4392067 — карточка одна.
      expect(WarehouseItem.matchesSearch(kit, '4392067VP'), isTrue);
      expect(WarehouseItem.matchesSearch(kit, '4392067'), isTrue);
      expect(WarehouseItem.matchesSearch(kit, 'PS373088'), isTrue);
    });

    test('пара Whirlpool WP… ↔ … находится в обе стороны', () {
      final pump = <String, dynamic>{
        'name': 'Drain pump',
        'partNumber': 'W10311524',
        'price': 0,
      };
      expect(WarehouseItem.matchesSearch(pump, 'WPW10311524'), isTrue);
      expect(WarehouseItem.matchesSearch(pump, 'W10311524'), isTrue);
    });

    test('модель, штрихкод и название', () {
      expect(WarehouseItem.matchesSearch(roller, 'DLE2515S'), isTrue);
      expect(WarehouseItem.matchesSearch(roller, 'roller'.toUpperCase()), isTrue);
      expect(
        WarehouseItem.matchesSearch(
          {'name': 'Ремень', 'barcode': '8809012345', 'price': 0},
          '8809012345',
        ),
        isTrue,
      );
    });

    test('чужая деталь не всплывает', () {
      expect(WarehouseItem.matchesSearch(roller, 'W10314173'), isFalse);
      expect(WarehouseItem.matchesSearch(kit, '4581EL2002C'), isFalse);
    });

    test('пустой запрос показывает всё, короткий номер не ищем', () {
      expect(WarehouseItem.matchesSearch(roller, ''), isTrue);
      expect(WarehouseItem.matchesSearch(roller, '   '), isTrue);
      // «45» совпало бы с половиной склада — такой короткий кусок номером
      // не считаем.
      expect(WarehouseItem.matchesSearch(roller, '45'), isFalse);
    });

    test('номера карточки собираются вместе с заменами', () {
      final numbers = WarehouseItem.fromMap(roller, 'w1').searchNumbers;
      expect(numbers, contains('4581EL2002C'));
      expect(numbers, contains('4400EL2001A'));
      expect(numbers, contains('DLE2515S'));
    });
  });
}
