import 'package:fix_appliance_crm/core/sms_text.dart';
import 'package:fix_appliance_crm/models/client.dart';
import 'package:fix_appliance_crm/models/document_settings.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/message_translate_service.dart';
import 'package:fix_appliance_crm/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Живой случай 07.10.2026: клиенту ушло SMS с обращением «Клиент +14165550101»
/// — подписью карточки, которую секретарь ставит, пока имя не названо.
void main() {
  test('заглушка карточки обращением не становится', () {
    for (final raw in [
      'Клиент +14165550101',
      'Клиент',
      'client +1 416 555 0101',
      '+1 416 555 0101',
      'Неизвестно',
      'без имени',
      '',
      null,
    ]) {
      expect(SmsText.clientName(raw), '', reason: '$raw');
      expect(Client.isPlaceholderName(raw), isTrue, reason: '$raw');
    }
  });

  test('настоящее имя — латиницей и только первое', () {
    expect(SmsText.clientName('Amelia'), 'Amelia');
    expect(SmsText.clientName('brad johnson'), 'Brad');
    expect(SmsText.clientName('Артём'), 'Artem');
    expect(Client.isPlaceholderName('Amelia'), isFalse);
  });

  test('без имени обращение убирается целиком, а не остаётся «Hi !»', () {
    expect(
      SmsText.fillName(SettingsService.defaultBookingConfirmSms, 'Клиент +14165550101'),
      startsWith('Hi! ✅'),
    );
    expect(
      SmsText.fillName(SettingsService.defaultOnWaySms, null),
      'Hi! 🚗\nYour technician is on the way — about 30 minutes.',
    );
    expect(
      SmsText.fillName('No problem, {name}. 🔁', 'Неизвестно'),
      'No problem. 🔁',
    );
    expect(
      SmsText.fillName('Hi {name}, this is your technician.', ''),
      'Hi, this is your technician.',
    );
  });

  test('имя есть — подставляется как обычно', () {
    expect(
      SmsText.fillName(SettingsService.defaultOnWaySms, 'amelia smith'),
      startsWith('Hi Amelia! 🚗'),
    );
  });

  test('в счёте и смете заглушка тоже не подставляется', () {
    final sms = DocumentSettings.defaults.renderSms(
      kind: 'invoice',
      clientName: 'Клиент +14165550101',
      total: 100,
      due: 100,
      paid: 0,
      items: const [],
      url: 'https://example.com/i',
    );
    expect(sms.contains('Клиент'), isFalse);
    expect(sms, startsWith('Hi, your invoice'));
  });

  test('перевод во вкладке «Информация»: смешанный текст идёт на русский', () {
    for (final mixed in [
      "Не запускается (Won't start)\n\nМодель: GTD40EBMK0WW\nIt worked yesterday for 30 minutes. I turned the timer button and hit start and nothing.",
      'Модель: GFW550SMN4WW\nnot draining, gives error 10, error 2',
      'will not spin\n\nУдобное время: пн 19.10\n\nМодель: MVWB955FC1',
      'leaking from bottom of door\n\nМодель: MDBH949PAW4',
      "burner that's out\n\nУдобное время: вт 20.10 (Tomorrow afternoon)",
      'Стиральная машина издает громкий стук\n\nwashing and dryer check\n\nfix the dryer',
      '11 year old Samsung stove. The oven fan has stopped working.\n\nвентилятор не работает\n\nNE59J7651WS\n\nМодель: UNTIL',
    ]) {
      expect(
        MessageTranslateService.prefersRussian(mixed),
        isTrue,
        reason: mixed,
      );
    }

    for (final alreadyRu in [
      'Не запускается.\n\nМодель: GTD40EBMK0WW\nВчера работала 30 минут. Повернул ручку таймера и нажал старт, и ничего.',
      'Ошибка E15, внизу нет воды, проблема с поплавковым выключателем',
      'Посудомойка Bosch не набирает воду и шумит; модель SHPM65Z55N',
      'Сушилка Samsung в Brantford не греет',
      'духовка',
    ]) {
      expect(
        MessageTranslateService.prefersRussian(alreadyRu),
        isFalse,
        reason: alreadyRu,
      );
    }
  });

  test('failedRussian отвергает ответ, оставшийся на английском', () {
    const src =
        "Не запускается (Won't start)\n\nМодель: GTD40EBMK0WW\nIt worked yesterday for 30 minutes.";
    expect(
      MessageTranslateService.failedRussian(
        src,
        "Won't start\n\nModel: GTD40EBMK0WW\nIt worked yesterday for 30 minutes.",
      ),
      isTrue,
    );
    expect(
      MessageTranslateService.failedRussian(
        src,
        'Не запускается.\n\nМодель: GTD40EBMK0WW\nВчера работала 30 минут.',
      ),
      isFalse,
    );
  });

  test('если не знаем имени — убираем слово «клиент» и оставляем только телефон', () {
    expect(SmsText.stripClientWord('Клиент +14165550101'), '+14165550101');
    expect(SmsText.stripClientWord('Клиент 5197323488'), '5197323488');
    expect(SmsText.stripClientWord('Клиент', '+14165550101'), '+14165550101');
    expect(SmsText.stripClientWord('', '+14165550101'), '+14165550101');
    expect(SmsText.stripClientWord('Amelia', '+14165550101'), 'Amelia');

    final client = Client.fromMap({
      'fullName': 'Клиент +14165550101',
      'phone': '+14165550101',
    }, 'c1');
    expect(client.fullName, '+14165550101');

    final job = Job.fromMap({
      'clientName': 'Клиент',
      'clientPhone': '+14165550101',
    }, 'j1');
    expect(job.clientName, '+14165550101');
    expect(job.contactName, '+14165550101');
  });
}
