const test = require('node:test');
const assert = require('node:assert');

const serviceArea = require('./service_area.js');

// Упрощённая форма реальной зоны: от озера Эри до линии Гуэлфа.
const POLYGON = [
  { lat: 42.509, lng: -80.469 },
  { lat: 42.766, lng: -81.049 },
  { lat: 43.118, lng: -80.919 },
  { lat: 43.416, lng: -80.904 },
  { lat: 43.53, lng: -80.622 },
  { lat: 43.536, lng: -80.482 },
  { lat: 43.395, lng: -80.211 },
  { lat: 43.162, lng: -80.086 },
  { lat: 43.035, lng: -79.881 },
  { lat: 42.63, lng: -79.939 },
];
const LABEL = 'Ontario: Brant, Norfolk, Zorra, Wellesley, North Dumfries, Haldimand';

function place(lat, lng, label, types = ['locality', 'political']) {
  return { status: 'OK', results: [{ formatted_address: label, geometry: { location: { lat, lng } }, types }] };
}

const NOTHING = { status: 'ZERO_RESULTS', results: [] };

function setup(t, { answer, key = 'test-key', polygon = POLYGON, label = LABEL } = {}) {
  const calls = [];
  serviceArea.init({
    loadConfig: async () => ({ servicePolygon: polygon, serviceAreaLabel: label }),
    apiKey: () => key,
    fetchJson: async (url) => {
      const address = decodeURIComponent((url.match(/address=([^&]+)/) || [])[1] || '');
      calls.push(address);
      return answer ? answer(address) : NOTHING;
    },
  });
  t.after(() => serviceArea.init({}));
  return calls;
}

test('известный город отвечает по списку, без обращения к геокодеру', async (t) => {
  const calls = setup(t);
  const result = await serviceArea.checkServiceArea('Tillsonburg');
  assert.deepEqual(
    { ok: result.ok, inside: result.inside, place: result.place, source: result.source },
    { ok: true, inside: true, place: 'Tillsonburg', source: 'list' }
  );
  assert.equal(calls.length, 0);
});

// Ради этого всё и затевалось: деревни между Тилсонбургом и Брантфордом в
// списке городов нет и не будет, а выезжать туда мастер выезжает.
test('деревня из зоны определяется геокодером как внутри', async (t) => {
  const calls = setup(t, {
    answer: () => place(42.995863, -80.317944, 'Wilsonville, Norfolk, ON N0E 1Z0, Canada'),
  });
  const result = await serviceArea.checkServiceArea('Wilsonville');
  assert.equal(result.inside, true);
  assert.match(result.place, /Wilsonville/);
  assert.equal(result.source, 'geocode');
  assert.deepEqual(calls, ['Wilsonville']);
});

test('далёкий город определяется как снаружи', async (t) => {
  setup(t, { answer: () => place(43.6532, -79.3832, 'Toronto, ON, Canada') });
  assert.equal((await serviceArea.checkServiceArea('Toronto')).inside, false);
});

test('почтовый индекс проверяется так же, как название', async (t) => {
  setup(t, { answer: () => place(42.8623, -80.728, 'Tillsonburg, ON N4G, Canada', ['postal_code']) });
  assert.equal((await serviceArea.checkServiceArea('N4G 1A1')).inside, true);
});

// «Mount Pleasant» без подсказки уезжает под Белвилл. Округ из подписи зоны —
// единственное, что геокодер здесь слушает.
test('одноимённая деревня переспрашивается с округом из подписи зоны', async (t) => {
  const calls = setup(t, {
    answer: (address) => {
      if (address === 'Mount Pleasant') {
        return place(44.242774, -77.030734, 'Mount Pleasant, Tyendinaga, ON', ['sublocality']);
      }
      if (address === 'Mount Pleasant, Brant, Ontario') {
        return place(43.0806, -80.3181, 'Mount Pleasant, Brant, ON, Canada', ['neighborhood']);
      }
      return NOTHING;
    },
  });
  const result = await serviceArea.checkServiceArea('Mount Pleasant');
  assert.equal(result.inside, true);
  assert.match(result.place, /Brant/);
  assert.equal(calls[0], 'Mount Pleasant');
  assert.equal(calls.length, 7, 'один обычный запрос и шесть подсказок разом');
});

// «Mount Pleasant, Norfolk» отдаёт центр округа — это не деревня, а «Google сдался».
test('центр округа не считается найденным местом', async (t) => {
  setup(t, {
    answer: (address) =>
      address === 'Mount Pleasant'
        ? place(44.242774, -77.030734, 'Mount Pleasant, Tyendinaga, ON', ['sublocality'])
        : place(42.85, -80.35, 'Norfolk County, ON, Canada', ['administrative_area_level_2', 'political']),
  });
  const result = await serviceArea.checkServiceArea('Mount Pleasant');
  assert.equal(result.inside, false);
  assert.match(result.place, /Tyendinaga/);
});

test('далёкий город не подтягивается подсказками', async (t) => {
  setup(t, { answer: () => place(43.6532, -79.3832, 'Toronto, ON, Canada') });
  assert.equal((await serviceArea.checkServiceArea('Toronto')).inside, false);
});

test('второй вопрос про то же место не ходит в сеть', async (t) => {
  const calls = setup(t, { answer: () => place(42.995863, -80.317944, 'Wilsonville, ON') });
  await serviceArea.checkServiceArea('Wilsonville');
  await serviceArea.checkServiceArea('wilsonville');
  assert.equal(calls.length, 1);
});

// Неизвестный ответ — не отказ. Отказ только когда карта сказала «снаружи».
test('нераспознанное место возвращает inside=null, а не отказ', async (t) => {
  setup(t);
  const result = await serviceArea.checkServiceArea('Ыыы');
  assert.equal(result.ok, true);
  assert.equal(result.inside, null);
  assert.match(result.say, /postal code/);
});

test('без ключа и без карты секретарь тоже не отказывает', async (t) => {
  setup(t, { key: '' });
  assert.equal((await serviceArea.checkServiceArea('Wilsonville')).inside, null);
  setup(t, { polygon: [] });
  const noMap = await serviceArea.checkServiceArea('Tillsonburg');
  assert.equal(noMap.inside, null);
  assert.equal(noMap.source, 'no_map');
});

test('сбой геокодера не роняет звонок', async (t) => {
  setup(t, {
    answer: () => {
      throw new Error('network down');
    },
  });
  const result = await serviceArea.checkServiceArea('Wilsonville');
  assert.equal(result.ok, true);
  assert.equal(result.inside, null);
});

test('пустое место — ошибка, без запроса к карте', async (t) => {
  const calls = setup(t);
  assert.deepEqual(await serviceArea.checkServiceArea(' '), { ok: false, error: 'no_place' });
  assert.equal(calls.length, 0);
});

test('hintsFromLabel берёт округа из подписи и отбрасывает провинцию', () => {
  assert.deepEqual(serviceArea.hintsFromLabel(LABEL), [
    'Brant',
    'Norfolk',
    'Zorra',
    'Wellesley',
    'North Dumfries',
    'Haldimand',
  ]);
  assert.deepEqual(serviceArea.hintsFromLabel(''), []);
});
