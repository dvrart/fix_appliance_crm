import 'package:fix_appliance_crm/features/reports/classify_items_page.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Работа или запчасть. Метку ставит мастер в счёте; у старых счетов её нет,
/// и тогда это догадка — её и разбирают на экране «Разобрать позиции».
void main() {
  group('Job.itemKind', () {
    test('метка человека сильнее всего остального', () {
      expect(Job.itemKind({'type': 'Part'}), 'part');
      expect(Job.itemKind({'type': 'Service'}), 'service');
      expect(Job.itemKind({'type': 'Запчасть'}), 'part');
      expect(Job.itemKind({'type': 'Работа'}), 'service');
      expect(Job.itemKind({'type': 'Labour'}), 'service');
    });

    test('метки нет — пусто, а не догадка', () {
      expect(Job.itemKind({'name': 'control board'}), '');
      expect(Job.itemKind({'type': ''}), '');
      expect(Job.itemKind({'type': 'что-то своё'}), '');
    });

    test('«Service» с себестоимостью остаётся работой', () {
      final item = {'type': 'Service', 'costPrice': 90.0};
      expect(Job.isPartItem(item), isFalse);
      expect(Job.isItemClassified(item), isTrue);
    });

    test('без метки запчасть узнаём по складу и себестоимости', () {
      expect(Job.isPartItem({'warehouseItemId': 'w1'}), isTrue);
      expect(Job.isPartItem({'costPrice': 20.0}), isTrue);
      expect(Job.isPartItem({'name': 'control board'}), isFalse);
      expect(Job.isItemClassified({'warehouseItemId': 'w1'}), isFalse);
    });
  });

  group('подсказка для старых счетов', () {
    test('название детали — запчасть', () {
      expect(guessIsPart({'name': 'control board for a washing machine'}), isTrue);
      expect(guessIsPart({'name': 'Drain pump'}), isTrue);
      expect(guessIsPart({'name': 'Плата управления'}), isTrue);
    });

    test('название работы — работа', () {
      expect(guessIsPart({'name': 'washing machine repair'}), isFalse);
      expect(guessIsPart({'name': 'Service call'}), isFalse);
      expect(guessIsPart({'name': 'Диагностика'}), isFalse);
    });

    test('непонятное название — остаётся прежняя догадка', () {
      expect(guessIsPart({'name': 'Misc'}), isFalse);
      expect(guessIsPart({'name': 'Misc', 'warehouseItemId': 'w1'}), isTrue);
    });
  });
}
