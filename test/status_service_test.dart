import 'package:fix_appliance_crm/core/constants.dart';
import 'package:fix_appliance_crm/services/status_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StatusService.colorOf', () {
    test('встроенный статус берёт цвет каталога', () {
      expect(
        StatusService.colorOf(JobStatuses.call).toARGB32(),
        0xFF1E88E5,
      );
    });

    test('пробелы и регистр не ломают совпадение', () {
      expect(
        StatusService.colorOf('  вызов '),
        StatusService.colorOf(JobStatuses.call),
      );
    });

    test('"В работе" не вырезана: жёлтый, а не случайный цвет', () {
      expect(
        StatusService.colorOf(JobStatuses.inProgress).toARGB32(),
        0xFFFCC520,
      );
    });

    test('алиасы готовности красятся как "Завершено"', () {
      for (final alias in ['Готов', 'Готово', 'готова', 'completed']) {
        expect(
          StatusService.colorOf(alias),
          StatusService.colorOf(JobStatuses.completed),
          reason: alias,
        );
      }
    });

    test('английская "Canceled" красится как отмена', () {
      for (final alias in ['Canceled', 'Cancelled', 'cancel']) {
        expect(
          StatusService.colorOf(alias),
          StatusService.colorOf(JobStatuses.cancelled),
          reason: alias,
        );
      }
    });

    test('«Депозит» — янтарный из каталога, не случайный цвет', () {
      expect(
        StatusService.colorOf(JobStatuses.deposit).toARGB32(),
        0xFFFFB300,
      );
    });

    test('«Взят депозит» красится как «Депозит»', () {
      for (final alias in ['Взят депозит', 'deposit', 'Deposit taken']) {
        expect(
          StatusService.colorOf(alias),
          StatusService.colorOf(JobStatuses.deposit),
          reason: alias,
        );
      }
    });

    test('чужой статус получает стабильный цвет между вызовами', () {
      final a = JobStatuses.fallbackColor('ремонт');
      final b = JobStatuses.fallbackColor('ремонт');
      expect(a, b);
    });
  });

  group('StatusService.labelOf', () {
    test('алиас "Готов" подписан как в каталоге', () {
      expect(
        StatusService.labelOf('Готов'),
        StatusService.labelOf(JobStatuses.completed),
      );
    });

    test('неизвестный статус возвращается как есть', () {
      expect(StatusService.labelOf('ремонт'), 'ремонт');
    });
  });
}
