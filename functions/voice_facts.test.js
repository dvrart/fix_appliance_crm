const test = require('node:test');
const assert = require('node:assert');

const voiceFacts = require('./voice_facts.js');

// Реальная форма зоны: прямоугольник вокруг Брантфорда и Тилсонбурга.
const ZONE = [
  { lat: 43.3, lng: -81.0 },
  { lat: 43.3, lng: -79.9 },
  { lat: 42.7, lng: -79.9 },
  { lat: 42.7, lng: -81.0 },
];

test('SMS только с номером квартиры — это квартира к адресу, а не новый адрес', () => {
  assert.equal(voiceFacts.unitOnlyAddress('Unit 23'), 'Unit 23');
  assert.equal(voiceFacts.unitOnlyAddress('unit #23'), 'Unit 23');
  assert.equal(voiceFacts.unitOnlyAddress('Apt. 5b'), 'Apt 5B');
  assert.equal(voiceFacts.unitOnlyAddress('apartment 12'), 'Apt 12');
  assert.equal(voiceFacts.unitOnlyAddress('Suite 200'), 'Suite 200');
  assert.equal(voiceFacts.unitOnlyAddress('#7'), '#7');
  assert.equal(voiceFacts.unitOnlyAddress('кв. 23'), 'Unit 23');
  assert.equal(voiceFacts.unitOnlyAddress('190 Argyle Street'), '');
  assert.equal(voiceFacts.unitOnlyAddress('Unit 23, 190 Argyle Street'), '');
  assert.equal(voiceFacts.unitOnlyAddress(''), '');

  assert.equal(
    voiceFacts.addressWithUnit('190 Argyle Street, Simcoe', 'Unit 23'),
    '190 Argyle Street, Unit 23, Simcoe'
  );
  assert.equal(
    voiceFacts.addressWithUnit('190 Argyle Street, Unit 4, Simcoe, N3Y 1V7', 'Unit 23'),
    '190 Argyle Street, Unit 23, Simcoe, N3Y 1V7'
  );
  assert.equal(voiceFacts.addressWithUnit('190 Argyle Street', 'Apt 5'), '190 Argyle Street, Apt 5');
  assert.equal(voiceFacts.addressWithUnit('190 Argyle Street, #9, Simcoe', ''), '190 Argyle Street, Simcoe');
});

test('секретарь не назначает визит: промпт и прощание обещают звонок мастера', () => {
  for (const flow of [voiceFacts.VOICE_CALL_FLOW, voiceFacts.VOICE_LIVE_FLOW]) {
    assert.match(flow, /You do NOT book visits/);
    assert.match(flow, /technician will contact them/);
    assert.doesNotMatch(flow, /do not book a taken window/);
  }
  const wish = { scheduled_date: '2099-01-05', scheduled_time: '14:00' };
  assert.equal(voiceFacts.farewellFor(wish), voiceFacts.VOICE_FAREWELL_EN_CALLBACK);
  assert.equal(voiceFacts.farewellFor({ preferred_time: 'any weekday morning' }), voiceFacts.VOICE_FAREWELL_EN_CALLBACK);
  assert.doesNotMatch(voiceFacts.farewellFor(wish), /see you then/);
});

test('номер дома после «at» — адрес, а не время визита', () => {
  assert.equal(voiceFacts.inferTimeFromText('My washer does not drain, I am Amelia at 12 King Street in Brantford.'), '');
  assert.equal(voiceFacts.inferTimeFromText("We're at 56 Elm Dr, Paris."), '');
  assert.equal(voiceFacts.inferTimeFromText('Can he come at 2 tomorrow?'), '14:00');
  assert.equal(voiceFacts.inferTimeFromText('around 10 a.m. works'), '10:00');
});

test('секретарь переспрашивает неразборчивые имя и адрес, при нужде — по буквам', () => {
  for (const flow of [voiceFacts.VOICE_CALL_FLOW, voiceFacts.VOICE_LIVE_FLOW]) {
    assert.ok(flow.includes(voiceFacts.VOICE_CLARIFY_RULES));
  }
  assert.match(voiceFacts.VOICE_CLARIFY_RULES, /spell/);
  assert.match(voiceFacts.VOICE_CLARIFY_RULES, /letter by letter/);
  assert.match(voiceFacts.VOICE_CLARIFY_RULES, /does NOT cover a name, street/);
});

test('pointInPolygon: город внутри и снаружи зоны', () => {
  assert.equal(voiceFacts.pointInPolygon(42.8623, -80.728, ZONE), true); // Tillsonburg
  assert.equal(voiceFacts.pointInPolygon(43.1394, -80.2644, ZONE), true); // Brantford
  assert.equal(voiceFacts.pointInPolygon(43.6532, -79.3832, ZONE), false); // Toronto
  assert.equal(voiceFacts.pointInPolygon(42.9849, -81.2453, ZONE), false); // London
});

test('pointInPolygon: без полигона и с мусором — не внутри', () => {
  assert.equal(voiceFacts.pointInPolygon(42.86, -80.72, []), false);
  assert.equal(voiceFacts.pointInPolygon(42.86, -80.72, [{ lat: 1, lng: 2 }]), false);
  assert.equal(voiceFacts.pointInPolygon(NaN, -80.72, ZONE), false);
});

test('townsInsideArea оставляет только города внутри', () => {
  const towns = [
    { name: 'Tillsonburg', lat: 42.8623, lng: -80.728 },
    { name: 'Brantford', lat: 43.1394, lng: -80.2644 },
    { name: 'Toronto', lat: 43.6532, lng: -79.3832 },
  ];
  assert.deepEqual(voiceFacts.townsInsideArea(towns, ZONE), ['Tillsonburg', 'Brantford']);
  assert.deepEqual(voiceFacts.townsInsideArea(towns, []), []);
});

// Подпись с карты — это углы полигона, а не перечень городов. Секретарь читала
// её как закрытый список и отказывала Тилсонбургу, который в зоне.
test('serviceAreaSpeech добавляет города к подписи зоны', () => {
  const text = voiceFacts.serviceAreaSpeech('Ontario: Brant, Norfolk, Zorra', [
    'Brantford',
    'Tillsonburg',
  ]);
  assert.match(text, /Ontario: Brant, Norfolk, Zorra\./);
  assert.match(text, /Towns inside the zone: Brantford, Tillsonburg\./);
  assert.match(text, /not the whole zone/);
});

test('serviceAreaSpeech без городов отдаёт подпись как есть', () => {
  assert.equal(voiceFacts.serviceAreaSpeech('Ontario: Brant', []), 'Ontario: Brant');
  assert.equal(voiceFacts.serviceAreaSpeech('', []), '');
});

// Контакт на адресе ремонта: если другой человек не назван — это сам клиент.
test('onSiteContactFrom: назван другой человек — остаются его имя и телефон', () => {
  const contact = voiceFacts.onSiteContactFrom(
    { contact_on_site_name: 'john', contact_on_site_phone: '+1 519 555 0101' },
    'Maria',
    '+14165550102'
  );
  assert.deepEqual(contact, {
    name: 'John',
    phone: '5195550101',
    explicit: true,
  });
});

test('onSiteContactFrom: «я буду» и мусор — контакт = клиент', () => {
  for (const name of [null, '', 'me', 'myself', "I'll be there", 'the tenant']) {
    const contact = voiceFacts.onSiteContactFrom(
      { contact_on_site_name: name },
      'Maria',
      '+14165550102'
    );
    assert.equal(contact.name, 'Maria');
    assert.equal(contact.phone, '4165550102');
    assert.equal(contact.explicit, false);
  }
});

test('onSiteContactFrom: своё же имя клиента — это не другой человек', () => {
  const contact = voiceFacts.onSiteContactFrom(
    { contact_on_site_name: 'maria', contact_on_site_phone: '+14165550102' },
    'Maria',
    '+14165550102'
  );
  assert.equal(contact.name, 'Maria');
  assert.equal(contact.phone, '4165550102');
  assert.equal(contact.explicit, false);
});

test('onSiteContactFrom: имя другого человека без его телефона — телефон клиента', () => {
  const contact = voiceFacts.onSiteContactFrom(
    { contact_on_site_name: 'John' },
    'Maria',
    '+14165550102'
  );
  assert.equal(contact.name, 'John');
  assert.equal(contact.phone, '4165550102');
  assert.equal(contact.explicit, true);
});

test('onSiteContactFrom: другой номер без имени — имя клиента, номер другой', () => {
  const contact = voiceFacts.onSiteContactFrom(
    { contact_on_site_phone: '+1 519 555 0101' },
    'Maria',
    '+14165550102'
  );
  assert.equal(contact.name, 'Maria');
  assert.equal(contact.phone, '5195550101');
  assert.equal(contact.explicit, true);
});

test('onSiteContactFrom: ничего нет ни у звонящего, ни у клиента — пусто', () => {
  const contact = voiceFacts.onSiteContactFrom({}, '', '');
  assert.deepEqual(contact, { name: '', phone: '', explicit: false });
});
