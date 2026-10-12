const test = require('node:test');
const assert = require('node:assert');

const smsText = require('./sms_text.js');

// Живой случай 07.10.2026: клиент получил «Hi Клиент +14165550101!» — в карточке
// ещё стояла заглушка секретаря, и она уехала в обращение как имя.
test('заглушка карточки обращением не становится', () => {
  for (const raw of [
    'Клиент +14165550101',
    'Клиент',
    'client +1 416 555 0101',
    '+14165550101',
    'без имени',
    '',
    null,
  ]) {
    assert.equal(smsText.smsName(raw), '', String(raw));
  }
});

test('настоящее имя — латиницей и только первое', () => {
  assert.equal(smsText.smsName('Amelia'), 'Amelia');
  assert.equal(smsText.smsName('brad johnson'), 'Brad');
  assert.equal(smsText.smsName('Артём'), 'Artem');
});

test('без имени обращение убирается целиком, а не остаётся «Hi !»', () => {
  assert.equal(smsText.fillName('Hi {name}! ✅\n📅 Visit', ''), 'Hi! ✅\n📅 Visit');
  assert.equal(
    smsText.fillName('Sorry to hear that, {name}. Would you like to reschedule?', 'Клиент +1416'),
    'Sorry to hear that. Would you like to reschedule?'
  );
  assert.equal(smsText.fillName('No problem, {name}. 🔁', null), 'No problem. 🔁');
  assert.equal(
    smsText.fillName('Hi {name}, this is your technician.', ''),
    'Hi, this is your technician.'
  );
  assert.equal(smsText.fillName('{name}, your repair is done.', ''), 'your repair is done.');
});

test('имя есть — подставляется как обычно', () => {
  assert.equal(smsText.fillName('Hi {name}! 👋', 'amelia'), 'Hi Amelia! 👋');
});

// Перевод на английский бережёт имена, поэтому «Клиент» он оставлял как есть:
// латиница в тексте была, и старая проверка такое пропускала к клиенту.
test('кириллица в тексте клиенту транслитерируется', () => {
  assert.equal(smsText.latinizeSms('Hi Клиент! See you Friday.'), 'Hi Klient! See you Friday.');
  assert.equal(smsText.latinizeSms('Hi Amelia!'), 'Hi Amelia!');
  assert.equal(smsText.latinizeSms(''), '');
  assert.equal(smsText.hasCyrillic('Hi Amelia!'), false);
});
