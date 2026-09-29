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
}
