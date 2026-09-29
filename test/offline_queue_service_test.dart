import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fix_appliance_crm/services/offline_queue_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Очередь досылает правки, которые не влезли в Firestore. Здесь закрыто
/// ровно то, на чём она раньше теряла данные мастера.
void main() {
  group('вложения не затираются', () {
    test('ссылка дописывается в уже лежащую запись, остальные фото целы', () {
      final existing = [
        {'url': 'https://a/1.jpg', 'name': '1.jpg'},
        {'url': '', 'name': '2.jpg', 'localPath': '/tmp/2.jpg', 'pendingUpload': true},
        {'url': 'https://a/3.jpg', 'name': '3.jpg'},
      ];

      final next = OfflineQueueService.applyUploadedPhoto(
        existing,
        fileName: '2.jpg',
        url: 'https://a/2.jpg',
      );

      expect(next.length, 3, reason: 'ни одно фото не потеряно и не задвоено');
      expect(next[0]['url'], 'https://a/1.jpg');
      expect(next[2]['url'], 'https://a/3.jpg');
      expect(next[1]['url'], 'https://a/2.jpg');
      expect(next[1].containsKey('localPath'), isFalse);
      expect(next[1].containsKey('pendingUpload'), isFalse);
    });

    test('незнакомое имя добавляется, старые остаются', () {
      final next = OfflineQueueService.applyUploadedPhoto(
        [
          {'url': 'https://a/1.jpg', 'name': '1.jpg'},
        ],
        fileName: '9.jpg',
        url: 'https://a/9.jpg',
      );

      expect(next.length, 2);
      expect(next.first['name'], '1.jpg');
      expect(next.last['url'], 'https://a/9.jpg');
    });

    test('пустой и мусорный массив не роняют дописку', () {
      expect(
        OfflineQueueService.applyUploadedPhoto(
          null,
          fileName: '1.jpg',
          url: 'https://a/1.jpg',
        ).length,
        1,
      );
      expect(
        OfflineQueueService.applyUploadedPhoto(
          ['мусор', 42],
          fileName: '1.jpg',
          url: 'https://a/1.jpg',
        ).length,
        1,
      );
    });

    test('патчится только первое совпадение имени', () {
      final next = OfflineQueueService.applyUploadedPhoto(
        [
          {'url': '', 'name': 'dup.jpg', 'pendingUpload': true},
          {'url': '', 'name': 'dup.jpg', 'pendingUpload': true},
        ],
        fileName: 'dup.jpg',
        url: 'https://a/dup.jpg',
      );

      expect(next.length, 2);
      expect(next[0]['url'], 'https://a/dup.jpg');
      expect(next[1]['url'], '');
    });
  });

  group('типы данных переживают SharedPreferences', () {
    test('дата визита остаётся датой, а не строкой', () {
      final when = DateTime.utc(2026, 9, 21, 14, 30);
      final packed = OfflineQueueService.encodeData({
        'scheduledAt': Timestamp.fromDate(when),
        'status': 'Назначено',
      });

      // Именно этот шаг раньше делал из даты строку.
      final viaJson = jsonDecode(jsonEncode(packed)) as Map<String, dynamic>;
      final restored = OfflineQueueService.decodeData(viaJson);

      expect(restored['scheduledAt'], isA<Timestamp>());
      expect((restored['scheduledAt'] as Timestamp).toDate().toUtc(), when);
      expect(restored['status'], 'Назначено');
    });

    test('DateTime тоже возвращается Timestamp', () {
      final when = DateTime.utc(2026, 1, 2, 3, 4);
      final restored = OfflineQueueService.decodeData(
        jsonDecode(
              jsonEncode(OfflineQueueService.encodeData({'at': when})),
            )
            as Map<String, dynamic>,
      );
      expect((restored['at'] as Timestamp).toDate().toUtc(), when);
    });

    test('даты внутри списков и карт тоже сохраняются', () {
      final when = DateTime.utc(2026, 5, 5, 9);
      final restored = OfflineQueueService.decodeData(
        jsonDecode(
              jsonEncode(
                OfflineQueueService.encodeData({
                  'visits': [
                    {'startAt': Timestamp.fromDate(when), 'done': false},
                  ],
                }),
              ),
            )
            as Map<String, dynamic>,
      );

      final visit = (restored['visits'] as List).first as Map;
      expect(visit['startAt'], isA<Timestamp>());
      expect((visit['startAt'] as Timestamp).toDate().toUtc(), when);
      expect(visit['done'], isFalse);
    });

    test('обычная карта с одним числовым полем не считается датой', () {
      final restored = OfflineQueueService.decodeData({
        'price': {'amount': 120},
      });
      expect(restored['price'], isA<Map>());
      expect((restored['price'] as Map)['amount'], 120);
    });
  });

  group('половина записи не уезжает', () {
    test('FieldValue виден и по имени поля', () {
      final data = {
        'deletedAt': FieldValue.serverTimestamp(),
        'status': 'Отменено',
      };
      expect(OfflineQueueService.hasUnsendableValue(data), isTrue);
      expect(OfflineQueueService.unsendableKeys(data), ['deletedAt']);
    });

    test('FieldValue внутри вложенных структур тоже ловится', () {
      expect(
        OfflineQueueService.unsendableKeys({
          'documents': [
            {'payments': FieldValue.arrayUnion(const [])},
          ],
        }),
        ['documents'],
      );
    });

    test('обычная правка проходит', () {
      expect(
        OfflineQueueService.hasUnsendableValue({
          'status': 'В работе',
          'priority': 'Высокий',
        }),
        isFalse,
      );
    });
  });

  group('операция не висит в очереди вечно', () {
    List<Map<String, dynamic>> ops() => [
      {'id': 'a', 'type': 'jobUpdate', 'attempts': 0},
      {'id': 'b', 'type': 'photo', 'attempts': 2},
    ];

    test('отправленное уходит, упавшее получает попытку', () {
      final remaining = OfflineQueueService.planRemaining(
        ops(),
        done: {'a'},
        attempts: {'b': 3},
      );

      expect(remaining.length, 1);
      expect(remaining.first['id'], 'b');
      expect(remaining.first['attempts'], 3);
    });

    test('операции, добавленные во время отправки, остаются', () {
      final current = [
        ...ops(),
        {'id': 'c', 'type': 'jobUpdate', 'attempts': 0},
      ];

      final remaining = OfflineQueueService.planRemaining(
        current,
        done: {'a', 'b'},
        attempts: const {},
      );

      expect(remaining.map((op) => op['id']), ['c']);
    });

    test('исчерпавшая попытки снимается и очередь пустеет', () {
      final remaining = OfflineQueueService.planRemaining(
        [
          {
            'id': 'a',
            'type': 'jobUpdate',
            'attempts': OfflineQueueService.maxAttempts - 1,
          },
        ],
        done: {'a'},
        attempts: const {},
      );
      expect(remaining, isEmpty);
    });
  });
}
