import 'package:fix_appliance_crm/services/client_service.dart';
import 'package:fix_appliance_crm/models/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientService.normalizePhone', () {
    test('убирает скобки, пробелы, дефисы', () {
      expect(ClientService.normalizePhone('+1 (250) 514-0123'), '2505140123');
    });

    test('возвращает последние 10 цифр для длинных номеров', () {
      expect(ClientService.normalizePhone('112345678901234'), '5678901234');
    });
  });

  group('ClientService.addressFields', () {
    test('формирует полный адрес из улицы, города, почтового кода', () {
      final data = ClientService.addressFields(
        street: '123 Main St',
        city: 'Toronto',
        postal: 'M5H 2N2',
      );
      expect(data['address'], contains('123 Main St'));
      expect(data['address'], contains('Toronto'));
      expect(data['address'], contains('M5H 2N2'));
    });

    test('добавляет Unit, если указан', () {
      final data = ClientService.addressFields(
        street: '456 Oak Ave',
        city: 'Vancouver',
        postal: 'V6B 1A1',
        unit: '12B',
      );
      expect(data['address'], contains('Unit 12B'));
    });
  });

  group('Client.isPlaceholderName', () {
    test('«Клиент» — placeholder', () {
      expect(Client.isPlaceholderName('Клиент'), true);
      expect(Client.isPlaceholderName('Client'), true);
    });

    test('реальное имя — не placeholder', () {
      expect(Client.isPlaceholderName('Amelia'), false);
    });

    test('номер телефона — placeholder', () {
      expect(Client.isPlaceholderName('+12505140123'), true);
    });
  });

  group('Client.extractName', () {
    test('находит fullName, даже если поле name отсутствует или содержит телефон', () {
      expect(
        Client.extractName({
          'fullName': 'John Smith',
          'phone': '+14165550101',
        }),
        'John Smith',
      );
      expect(
        Client.extractName({
          'name': 'Клиент +14165550101',
          'fullName': 'John Smith',
          'phone': '+14165550101',
        }),
        'John Smith',
      );
    });

    test('берёт настоящее имя из контактов локации, если в шапке только телефон', () {
      expect(
        Client.extractName({
          'fullName': '+14165550101',
          'phone': '+14165550101',
          'locations': [
            {
              'id': 'primary',
              'contacts': [
                {'name': 'Maria Petrova', 'phone': '+14165550101'},
              ],
            },
          ],
        }),
        'Maria Petrova',
      );
    });
  });

  group('Постоянный клиент (isRegular)', () {
    test('сохраняется в Client.fromMap / toMap / toUiMap и Job.fromMap', () {
      final client = Client.fromMap({
        'fullName': 'Sarah Connor',
        'phone': '+1 519-555-0199',
        'email': 'sarah@example.com',
        'isRegular': true,
      }, 'c-1');
      expect(client.isRegular, true);
      expect(client.toUiMap()['isRegular'], true);
      expect(client.toMap()['isRegular'], true);
      expect(client.copyWith(isRegular: false).isRegular, false);
    });

    test('распознаётся по id, телефону и email в ClientService и ищется по слову «постоянный»', () {
      final regular = Client(
        id: 'reg-1',
        fullName: 'James Miller',
        phone: '+1 (519) 555-0144',
        email: 'james@example.com',
        isRegular: true,
      );
      final ordinary = Client(
        id: 'ord-1',
        fullName: 'Bob Smith',
        phone: '+1 (519) 555-0188',
        isRegular: false,
      );
      ClientService.syncRegularFromClients([regular, ordinary]);

      expect(ClientService.isRegularClient(clientId: 'reg-1'), true);
      expect(ClientService.isRegularClient(phone: '519-555-0144'), true);
      expect(ClientService.isRegularClient(email: 'JAMES@example.com'), true);
      expect(ClientService.isRegularClient(clientId: 'ord-1'), false);
      expect(ClientService.isRegularClient(phone: '519-555-0188'), false);

      expect(ClientService.matchesClient(regular, 'постоянный'), true);
      expect(ClientService.matchesClient(ordinary, 'постоянный'), false);

      ClientService.noteClientRegular(regular.copyWith(isRegular: false));
      expect(ClientService.isRegularClient(clientId: 'reg-1'), false);
      expect(ClientService.isRegularClient(phone: '519-555-0144'), false);
    });
  });
}
