// Публичная страница паспорта техники: путь, разбор кода, история и то, что
// на странице нет данных клиента. Firestore — заглушка.
const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
let store;

function snapshot(path) {
  const stored = store.get(path);
  return { id: path.split('/').pop(), exists: stored !== undefined, data: () => structuredClone(stored) };
}

function matches(data, filters) {
  return filters.every(({ field, op, value }) => {
    if (op === 'array-contains') return Array.isArray(data[field]) && data[field].includes(value);
    if (op === '==') return data[field] === value;
    return false;
  });
}

function ref(path, filters = []) {
  return {
    path,
    collection: (name) => ref(`${path}/${name}`),
    doc: (name) => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, { field, op, value }]),
    limit: () => ref(path, filters),
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot)
        .filter((doc) => matches(doc.data(), filters));
      return { docs, empty: !docs.length, size: docs.length };
    },
    set: async (data) => {
      const current = store.get(path) || {};
      const next = { ...current };
      for (const [key, value] of Object.entries(data)) {
        const added = value && value.__union;
        next[key] = added ? [...(Array.isArray(current[key]) ? current[key] : []), ...added] : value;
      }
      store.set(path, next);
    },
    add: async (data) => {
      store.set(`${path}/note-${store.size}`, data);
    },
  };
}

const firestore = Object.assign(() => ({ collection: (name) => ref(name) }), {
  FieldValue: {
    arrayUnion: (...items) => ({ __union: items }),
    serverTimestamp: () => 'server-time',
  },
});
const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin/firestore') return { getFirestore: firestore, FieldValue: firestore.FieldValue };
  return load.apply(this, arguments);
};
const passport = require('./passport');
Module._load = load;

function response() {
  return {
    statusCode: 0, headers: {}, body: '',
    set(key, value) { this.headers[key] = value; return this; },
    status(code) { this.statusCode = code; return this; },
    send(body) { this.body = body; return this; },
    json(body) { this.body = JSON.stringify(body); return this; },
  };
}

beforeEach(() => {
  store = new Map();
});

test('passport paths: /a/<code>, /passport/<code> and the direct function URL; short links are not passports', () => {
  assert.equal(passport.isPassportPath('/a/k7m2x9qa3f'), true);
  assert.equal(passport.isPassportPath('/p/a/k7m2x9qa3f'), true);
  assert.equal(passport.isPassportPath('/passport/k7m2x9qa3f?x=1'), true);
  assert.equal(passport.isPassportPath('/p/abc23def'), false);
  assert.equal(passport.isPassportPath('/pay/abc23def'), false);
  assert.equal(passport.passportCodeFromPath('/a/K7M2X9QA3F'), 'k7m2x9qa3f');
  assert.equal(passport.passportCodeFromPath('/a/../../etc'), '');
  assert.equal(passport.passportCodeFromPath('/a/ab'), '');
  assert.equal(passport.passportCodeFromPath('/a/abc0lio123'), '', 'ambiguous letters are not in the alphabet');
});

test('the page shows the appliance, plan and English history but never the client', async () => {
  store.set(`${COMPANY}/appliances/k7m2x9qa3f`, {
    clientId: 'client-1', planId: 'plan-1', type: 'Стиральная машина', brand: 'LG',
    model: 'WM3400CW', serialNumber: '905KWAB12345', manufactureDate: '2019-05',
    notes: 'Клиент просил звонить вечером', status: 'active',
    serviceLog: [{ date: '2026-11-20T15:00:00.000Z', kind: 'maintenance', items: ['Drain pump filter cleaned', 'Фильтр почищен'] }],
  });
  store.set(`${COMPANY}/care_plans/plan-1`, {
    clientName: 'Amelia Secret', status: 'active', nextMaintenanceDue: new Date('2027-11-20T12:00:00Z'),
  });
  store.set(`${COMPANY}/settings/documents`, {
    companyName: 'FIX Appliance', companyPhone: '(519) 555-0100', technicianName: 'Artem',
  });
  store.set(`${COMPANY}/jobs/job-1`, {
    applianceIds: ['k7m2x9qa3f'], status: 'Завершено', completedAt: new Date('2026-10-25T18:00:00Z'),
    solution: 'Заменил сливной насос',
    solutionEn: 'Replaced the drain pump. It was seized.',
    technicianName: 'Artem', servicedByShop: 'FIX Appliance', servicedByPhone: '5195550100',
    clientName: 'Amelia Secret', clientPhone: '+14165550101', clientAddress: '1 Hidden St',
    documents: [
      { type: 'Invoice', items: [{ name: 'Drain pump', price: 189 }, { name: 'Service call', price: 99 }, { name: 'Насос', price: 1 }] },
      { type: 'Estimate', items: [{ name: 'Not done yet', price: 500 }] },
    ],
  });
  store.set(`${COMPANY}/jobs/job-2`, { applianceIds: ['k7m2x9qa3f'], status: 'Отменено', completedAt: new Date('2026-09-01T12:00:00Z') });
  store.set(`${COMPANY}/jobs/job-3`, { applianceIds: ['k7m2x9qa3f'], status: 'Вызов' });

  const res = response();
  await passport.handlePassportRequest({ path: '/a/k7m2x9qa3f' }, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.headers['X-Robots-Tag'], /noindex/);
  assert.match(res.body, /LG Washer/);
  assert.match(res.body, /WM3400CW/);
  assert.match(res.body, /Protected by FIX Appliance Care Plan/);
  assert.match(res.body, /Next maintenance: November 2027/);
  assert.match(res.body, /Replaced the drain pump\. It was seized\./);
  assert.match(res.body, /"parts":\["Drain pump"\]/);
  assert.doesNotMatch(res.body, /"parts":\[.*"Service call"/);
  assert.doesNotMatch(res.body, /Заменил/);
  assert.match(res.body, /Drain pump filter cleaned/);
  assert.match(res.body, /tel:\+15195550100/);
  assert.match(res.body, /Artem/);
  assert.doesNotMatch(res.body, /Amelia|Secret|Hidden|4165550101|\$189|189|Not done yet|Насос|Фильтр|вечером/);
  assert.equal((res.body.match(/<li>/g) || []).length, 2, 'cancelled and unfinished jobs stay out of the history');
});

test('an unfinished job with a completed visit shows as an inspection, not a repair', () => {
  const history = passport._internals.buildHistory({}, [
    {
      applianceIds: ['k7m2x9qa3f'], status: 'Ожидание запчасти',
      solution: 'Вентилятор испарителя трещит', solutionEn: 'Evaporator fan rattling - motor ordered',
      visits: [{ outcome: 'done', startAt: new Date('2026-10-28T15:00:00Z') }],
    },
    { status: 'Вызов', solutionEn: 'Not yet' },
  ]);
  assert.equal(history.length, 1, 'a job nobody visited yet stays off the page');
  assert.equal(history[0].label, 'Inspected');
  assert.equal(history[0].report, 'Evaporator fan rattling - motor ordered');
});

test('a recall visit adds its own Warranty follow-up row without overwriting the first repair', () => {
  const history = passport._internals.buildHistory({}, [
    {
      applianceIds: ['k7m2x9qa3f'],
      status: 'Завершено',
      completedAt: new Date('2026-11-10T16:00:00Z'),
      solution: 'Заменил замок люка',
      solutionEn: 'Replaced the door lock assembly.',
      visits: [
        { outcome: 'done', startAt: new Date('2026-11-01T14:00:00Z') },
        { outcome: 'done', startAt: new Date('2026-11-10T15:00:00Z') },
      ],
      recalls: [
        {
          id: 'rec_1',
          date: '2026-11-10T15:00:00Z',
          description: 'Снова мигает замок',
          report: 'Подогнул ответный крючок люка и проверил замок',
          reportEn: 'Adjusted the door strike alignment and verified lock operation.',
        },
      ],
    },
  ]);
  assert.equal(history.length, 2);
  assert.equal(history[0].label, 'Warranty follow-up');
  assert.equal(history[0].report, 'Adjusted the door strike alignment and verified lock operation.');
  assert.equal(history[1].label, '');
  assert.equal(history[1].report, 'Replaced the door lock assembly.');
});

test('a visiting technician can add a record; Russian and scripts never reach the page', async () => {
  store.set(`${COMPANY}/appliances/k7m2x9qa3f`, { type: 'Washer', brand: 'LG', status: 'active', serviceLog: [] });
  const bad = await passport._internals.addOutsideNote('k7m2x9qa3f', { shop: '  ', work: 'Fixed it' });
  assert.equal(bad.status, 400);
  const saved = await passport._internals.addOutsideNote('k7m2x9qa3f', {
    shop: 'Other Co <script>', by: 'Иван', phone: '519-555-0199', work: 'Replaced belt. Починил.',
  }, '1.2.3.4');
  assert.equal(saved.status, 200);
  const res = response();
  await passport.handlePassportRequest({ path: '/a/k7m2x9qa3f', method: 'GET' }, res);
  const history = res.body.match(/const HISTORY = (\[.*?\]);/);
  assert.ok(history, 'the visit list is on the page');
  assert.match(history[1], /Other Co/);
  assert.match(history[1], /Replaced belt/);
  assert.doesNotMatch(history[1], /<script>|Иван|Починил/);
});

test('unknown codes and retired appliances are handled without leaking anything', async () => {
  const missing = response();
  await passport.handlePassportRequest({ path: '/a/zzzzzzzzzz' }, missing);
  assert.equal(missing.statusCode, 404);
  assert.match(missing.body, /Passport not found/);

  store.set(`${COMPANY}/appliances/retxred22a`, { type: 'Сушилка', brand: '<script>x</script>', status: 'retired' });
  const res = response();
  await passport.handlePassportRequest({ path: '/a/retxred22a' }, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /This appliance has been replaced/);
  assert.match(res.body, /No service records yet/);
  assert.doesNotMatch(res.body, /<script>x/);
});
