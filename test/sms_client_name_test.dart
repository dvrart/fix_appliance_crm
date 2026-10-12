import 'package:fix_appliance_crm/core/sms_text.dart';
import 'package:fix_appliance_crm/models/client.dart';
import 'package:fix_appliance_crm/models/document_settings.dart';
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
}
