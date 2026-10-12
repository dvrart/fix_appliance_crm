import 'package:fix_appliance_crm/core/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Подпись под сообщением должна говорить не только «во сколько», но и «когда».
/// Без дня в переписке не отличить сегодняшнее SMS от мартовского.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
    await initializeDateFormatting('en');
  });

  // Полдень, чтобы перевод в пояс магазина не утащил дату на соседние сутки.
  DateTime noon(DateTime day) =>
      DateTime(day.year, day.month, day.day, 12, 34);

  test('сегодняшнее сообщение подписано днём и временем', () {
    final stamp = Formatters.messageStamp(noon(DateTime.now()));
    expect(stamp, startsWith('Сегодня · '));
    expect(RegExp(r'\d{2}:\d{2}$').hasMatch(stamp), isTrue);
  });

  test('вчерашнее и завтрашнее названы словами', () {
    final now = DateTime.now();
    expect(
      Formatters.messageDay(noon(now.subtract(const Duration(days: 1)))),
      'Вчера',
    );
    expect(
      Formatters.messageDay(noon(now.add(const Duration(days: 1)))),
      'Завтра',
    );
  });

  test('позавчерашнее показывает дату без года', () {
    final day = noon(DateTime.now().subtract(const Duration(days: 2)));
    final label = Formatters.messageDay(day);
    expect(label, isNot(contains('Сегодня')));
    expect(label, isNot(contains('Вчера')));
    expect(label, contains('${day.day}'));
    expect(label, isNot(contains('${day.year}')));
  });

  test('у прошлых лет дописан год', () {
    expect(Formatters.messageDay(DateTime(2020, 3, 5, 12)), contains('2020'));
    expect(
      Formatters.messageStamp(DateTime(2020, 3, 5, 12)),
      contains('2020'),
    );
  });

  test('без даты подпись пустая, а не «null»', () {
    expect(Formatters.messageStamp(null), '');
    expect(Formatters.messageDay(null), '');
  });
}
