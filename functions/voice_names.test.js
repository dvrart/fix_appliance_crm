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

// Настоящие звонки 30.09–01.10.2026: в заявку и карточку уехали «Ready», «She»,
// «Shi», «Kate», «Helen», «At» вместо имени клиента или вместо пустоты.

test('«Are you ready?» не имя: Brad Smith остаётся Брэдом', () => {
  const history = [
    { role: 'assistant', text: "FixApplianceCA, this is Sarah, what's going on today?" },
    { role: 'user', text: 'Farah, how are you?' },
    { role: 'assistant', text: 'So, what' },
    { role: 'user', text: "Are you ready? You tell me when you're ready." },
    { role: 'assistant', text: "Yep, I'm ready, what's on your mind?" },
    { role: 'user', text: 'Sí. ¿Es Brad Smith?' },
    { role: 'assistant', text: 'Brad, okay, and what appliance is giving you trouble?' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Ready', history), '');
  assert.equal(voiceFacts.pickClientName('Ready', 'Brad Smith', history), 'Brad Smith');
  const merged = voiceFacts.mergeExtracted({ client_name: 'Ready' }, {}, history);
  assert.equal(merged.client_name, undefined);
});

test('как представилась секретарь в приветствии — не имя клиента (Helen, Kate, she, Shi)', () => {
  const helen = [
    { role: 'assistant', text: 'FixApplianceCA, this is helen, how can I help?' },
    { role: 'user', text: 'Hi, Helen.' },
    { role: 'user', text: "Hi. Okay. I'm just making sure it's a human being." },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Helen', helen), '');
  const she = [
    { role: 'assistant', text: 'FixApplianceCA, this is she speaking — how can I help?' },
    { role: 'assistant', text: 'Hello? Are you still there?' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'She', she), '');
  const kate = voiceFacts.historyFromTranscript(
    "ИИ: Fix Appliance AI, this is Kate. What can I do for you?\nКлиент: Yes, I'd like to book a service for my LG washing machine.\nИИ: Hello, can you help?\nКлиент: Hello."
  );
  assert.equal(voiceFacts.pickClientName(null, 'Kate', kate), '');
  const shi = voiceFacts.historyFromTranscript(
    "ИИ: Fix Appliance CA, this is Shi-\nИИ: speaking. How can I help?\nКлиент: Uh hello. I'm sorry, I didn't catch your name."
  );
  assert.equal(voiceFacts.pickClientName(null, 'Shi', shi), '');
});

test('служебное слово из реплики секретаря не становится именем («look at something new» → не «At»)', () => {
  const history = [
    { role: 'assistant', text: 'FixApplianceCA, can I help you with a repair?' },
    { role: 'assistant', text: 'we already fixed for you, or if you need us to look at something new.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'At', history), '');
  for (const word of ['She', 'At', 'Ready', 'My', 'Fixapplianceca']) {
    assert.equal(voiceFacts.usableClientName(word), '', word);
    assert.equal(voiceFacts.isPlaceholderClientName(word), true, word);
  }
  assert.equal(voiceFacts.pickClientName(null, null, [{ role: 'user', text: "Hi, this is my dryer again, it's not heating." }]), '');
});

test('Sarah — имя секретаря; клиентка Sarah остаётся, если сама так представилась', () => {
  const asked = [
    { role: 'assistant', text: "FixApplianceCA, this is Sarah — what's going on?" },
    { role: 'user', text: 'My fridge is warm.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Sarah', asked), '');
  const namesake = [
    { role: 'assistant', text: "FixApplianceCA, this is Sarah — what's going on?" },
    { role: 'user', text: 'Hi Sarah, this is Sarah too, my fridge is warm.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Sarah', namesake), 'Sarah');
  const fullReply = [
    { role: 'assistant', text: 'Can I get your name?' },
    { role: 'user', text: 'Sarah Johnson.' },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Sarah Johnson', fullReply), 'Sarah Johnson');
});

test('«this is …» дальше в разговоре не считается самопредставлением секретаря', () => {
  const history = [
    { role: 'assistant', text: "FixApplianceCA, this is Sarah — what's going on?" },
    { role: 'user', text: "Hi, it's Brad, my dryer is noisy." },
    { role: 'assistant', text: "Thanks, Brad — and this is Brad's own place, right?" },
  ];
  assert.equal(voiceFacts.pickClientName(null, 'Brad', history), 'Brad');
});

test('прощание и «подождите» распознаются', () => {
  assert.equal(voiceFacts.saidFarewell('Perfect, thanks so much, Brad, have a good day.'), true);
  assert.equal(voiceFacts.saidFarewell('Okay. Our technician will contact you.'), true);
  assert.equal(voiceFacts.saidFarewell('What brand is it?'), false);
  assert.equal(voiceFacts.callerAskedToHold('Hold on, let me grab the model number'), true);
  assert.equal(voiceFacts.callerAskedToHold('One sec'), true);
  assert.equal(voiceFacts.callerAskedToHold("It's a Whirlpool"), false);
});

test('расшифровка без меток остаётся одной репликой клиента', () => {
  assert.deepEqual(voiceFacts.historyFromTranscript('hello\nmy name is Amelia'), [
    { role: 'user', text: 'hello\nmy name is Amelia' },
  ]);
});
