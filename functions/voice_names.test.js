const test = require('node:test');
const assert = require('node:assert');

const voiceFacts = require('./voice_facts.js');

test('имя мастера из его же реплики не становится именем клиента', () => {
  const history = voiceFacts.historyFromTranscript(
    'Моё: Здравствуйте, Fix Appliance, меня зовут Артём.\nКлиент: Здравствуйте, у меня стиралка не сливает.\nМоё: Какой адрес?\nКлиент: 12 King Street, Brantford.'
  );
  assert.deepEqual(history.map((h) => h.role), ['assistant', 'user', 'assistant', 'user']);
  const out = voiceFacts.enrichExtracted({ client_name: 'Artem' }, history, '');
  assert.equal(out.client_name, undefined);
});

test('имя клиента берётся из его реплики, а не из представления мастера', () => {
  const history = voiceFacts.historyFromTranscript(
    'Me: Hello, Artem speaking.\nClient: Hi Artem, my name is Amelia, my dryer is not heating.'
  );
  assert.equal(voiceFacts.pickClientName(null, 'Artem', history), 'Amelia');
  assert.equal(voiceFacts.enrichExtracted({ client_name: 'Artem' }, history, '').client_name, 'Amelia');
});

test('секретарь представилась по имени — это не имя звонящего', () => {
  const history = [
    { role: 'assistant', text: 'Hi, FixApplianceCA, this is Sophie from the office. How can I help?' },
    { role: 'user', text: 'Yeah my fridge stopped cooling.' },
    { role: 'assistant', text: "Oh no. I'm Sophie, by the way — what brand is it?" },
    { role: 'user', text: 'Samsung.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Sophie', history), '');
  const merged = voiceFacts.mergeExtracted({ client_name: 'Sophie' }, { client_name: 'Sophie' }, history);
  assert.equal(merged.client_name, undefined);
});

test('звонящий спрашивает Артёма — имя не уходит в заявку', () => {
  const history = [
    { role: 'assistant', text: 'Hi, FixApplianceCA, how can I help?' },
    { role: 'user', text: 'Hi, can I talk to Artem? My washer is leaking.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Artem', history), '');
  assert.equal(voiceFacts.isShopPersonName('Aetem', history), true);
});

test('тёзка мастера: клиент сам представился Артёмом — имя остаётся', () => {
  const answer = [
    { role: 'assistant', text: "Hi, FixApplianceCA. What's your name?" },
    { role: 'user', text: 'Artem.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Artem', answer), 'Artem');
  const intro = [{ role: 'user', text: "Hi, it's Artem, my oven won't heat." }];
  assert.equal(voiceFacts.pickClientName(null, 'Artem', intro), 'Artem');
});

test('обычное имя клиента, названное в ответ на вопрос, сохраняется', () => {
  const history = [
    { role: 'assistant', text: 'Can I get your name?' },
    { role: 'user', text: 'Sure, David.' },
    { role: 'assistant', text: 'Thanks David, what is the address?' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'David', history), 'David');
});

test('расшифровка без меток остаётся одной репликой клиента', () => {
  assert.deepEqual(voiceFacts.historyFromTranscript('hello\nmy name is Amelia'), [
    { role: 'user', text: 'hello\nmy name is Amelia' },
  ]);
});
