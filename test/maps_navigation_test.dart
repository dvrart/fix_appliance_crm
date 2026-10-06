import 'package:fix_appliance_crm/services/maps_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Кнопка «Проложить маршрут» открывала пустую форму поиска: без параметра
/// `destination` Google Maps так и делает (документация Maps URLs). Адрес
/// терялся на пустом поле заявки, а в маршруте дня — на неэкранированной
/// вертикальной черте между точками.
void main() {
  group('адрес для Google', () {
    test('пусто и заглушки — ехать некуда', () {
      for (final bad in [
        '',
        '   ',
        'Не указан',
        'не указано',
        'адрес не указан',
        'Not specified',
        'N/A',
        '—',
      ]) {
        expect(
          MapsService.hasRoutableAddress(bad),
          isFalse,
          reason: 'адрес «$bad» не должен открывать карту',
        );
      }
    });

    test('квартира выкинута, провинция и страна дописаны', () {
      expect(
        MapsService.navigationQuery(
          '21 Bloor St W, Unit 5, Toronto, M4W 1A9',
          region: 'Ontario',
        ),
        '21 Bloor St W, Toronto, M4W 1A9, Ontario, Canada',
      );
      expect(
        MapsService.navigationQuery('14 Elm Ave, #3B, Brantford'),
        '14 Elm Ave, Brantford, Canada',
      );
    });

    test('провинция и страна не дублируются', () {
      expect(
        MapsService.navigationQuery(
          '21 Bloor St W, Toronto, ON, Canada',
          region: 'Ontario',
        ),
        '21 Bloor St W, Toronto, ON, Canada',
      );
      expect(
        MapsService.navigationQuery(
          '21 Bloor St W, Toronto, Ontario',
          region: 'Ontario',
        ),
        '21 Bloor St W, Toronto, Ontario, Canada',
      );
    });

    test('улица без города остаётся адресом', () {
      expect(MapsService.hasRoutableAddress('14 Elm Ave'), isTrue);
    });
  });

  group('ссылка на маршрут', () {
    test('без точек ссылки нет — иначе откроется пустой поиск', () {
      expect(MapsService.routeUri(const []), isNull);
      expect(
        MapsService.routeUri(const [MapPlace(address: '  ')]),
        isNull,
      );
    });

    test('одна точка: адрес плюс place_id', () {
      final uri = MapsService.routeUri(const [
        MapPlace(address: '21 Bloor St W, Toronto, ON', placeId: 'ChIJ_bloor'),
      ])!;
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['destination'], '21 Bloor St W, Toronto, ON');
      expect(uri.queryParameters['destination_place_id'], 'ChIJ_bloor');
      expect(uri.queryParameters['travelmode'], 'driving');
      expect(uri.queryParameters.containsKey('waypoints'), isFalse);
    });

    test('промежуточные точки разделены %7C, а не голой чертой', () {
      final uri = MapsService.routeUri(const [
        MapPlace(address: 'A, Toronto', placeId: 'idA'),
        MapPlace(address: 'B, Toronto', placeId: 'idB'),
        MapPlace(address: 'C, Toronto', placeId: 'idC'),
      ])!;
      expect(uri.queryParameters['destination'], 'C, Toronto');
      expect(uri.queryParameters['waypoints'], 'A, Toronto|B, Toronto');
      expect(uri.queryParameters['waypoint_place_ids'], 'idA|idB');
      expect(uri.toString(), isNot(contains('|')));
      expect(uri.toString(), contains('%7C'));
    });

    test('без place_id у части точек список id не отправляем', () {
      final uri = MapsService.routeUri(const [
        MapPlace(address: 'A, Toronto'),
        MapPlace(address: 'B, Toronto', placeId: 'idB'),
      ])!;
      expect(uri.queryParameters['waypoints'], 'A, Toronto');
      expect(uri.queryParameters.containsKey('waypoint_place_ids'), isFalse);
    });

    test('больше девяти промежуточных точек Google не берёт', () {
      final stops = [
        for (var i = 0; i < 14; i++) MapPlace(address: 'Stop $i, Toronto'),
      ];
      final uri = MapsService.routeUri(stops)!;
      final waypoints = uri.queryParameters['waypoints']!.split('|');
      expect(waypoints.length, MapsService.maxMapsWaypoints);
      expect(waypoints.first, 'Stop 0, Toronto');
      expect(uri.queryParameters['destination'], 'Stop 13, Toronto');
    });
  });
}
