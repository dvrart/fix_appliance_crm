// Care Plan на сервере: поиск члена плана по номеру, строка для секретаря и
// ежедневные напоминания о ТО (по одному разу). Firestore и пуши — заглушки.
const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
let store;
let pushes;
let queries;

function snapshot(path) {
  const stored = store.get(path);
  return { id: path.split('/').pop(), ref: ref(path), exists: stored !== undefined, data: () => structuredClone(stored) };
}

function matches(data, { field, op, value }) {
  if (op === '==') return data[field] === value;
  if (op === 'array-contains') return Array.isArray(data[field]) && data[field].includes(value);
  return true;
}

function ref(path, filters = []) {
  return {
    path,
    collection: (name) => ref(`${path}/${name}`),
    doc: (name) => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, { field, op, value }]),
    set: async (data, options) => store.set(path, { ...(options?.merge ? store.get(path) : {}), ...structuredClone(data) }),
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      queries++;
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot)
        .filter((doc) => filters.every((f) => matches(doc.data(), f)));
      return { docs, empty: !docs.length };
    },
  };
}

const firestore = Object.assign(() => ({ collection: (name) => ref(name) }), {
  FieldValue: { serverTimestamp: () => 'now' },
});
const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin/firestore') return { getFirestore: firestore, FieldValue: firestore.FieldValue };
  if (name === 'firebase-functions/v2/scheduler') return { onSchedule: (_, handler) => handler };
  if (name === './notify') return { notifyMaster: async (...args) => pushes.push(args) };
  return load.apply(this, arguments);
};
const lookup = require('./care_plan_lookup');
const { _internals: reminders } = require('./care_plan');
Module._load = load;

beforeEach(() => {
  store = new Map();
  pushes = [];
  queries = 0;
  lookup.clearCache();
});

test('a caller is a member only while the plan is active or past due; the answer is cached', async () => {
  store.set(`${COMPANY}/care_plans/p1`, { clientId: 'c1', phones: ['4165550101'], status: 'active', discountPercent: 30 });
  store.set(`${COMPANY}/care_plans/p2`, { clientId: 'c2', phones: ['4165550102'], status: 'pending' });
  const member = await lookup.findMemberPlan({ phone: '+1 (416) 555-0101' });
  assert.equal(member.id, 'p1');
  assert.equal(await lookup.findMemberPlan({ phone: '+14165550102' }), null);
  assert.equal(await lookup.findMemberPlan({ phone: '' }), null);
  const before = queries;
  await lookup.findMemberPlan({ phone: '4165550101' });
  assert.equal(queries, before, 'second lookup within 5 minutes comes from the cache');
  assert.equal((await lookup.findMemberPlan({ clientId: 'c1' })).id, 'p1');
});

test('the secretary hears plan terms but no promises of time or extra prices', () => {
  const line = lookup.secretaryBriefLine({ status: 'past_due', discountPercent: 100 });
  assert.match(line, /Care Plan member/);
  assert.match(line, /pays for parts only/);
  assert.match(line, /sticker/);
  assert.match(lookup.secretaryBriefLine({ status: 'active', discountPercent: 30 }), /30% off repair labour/);
  assert.match(line, /Do not promise a time/);
  assert.doesNotMatch(line, /warranty/i);
  assert.equal(lookup.secretaryBriefLine({ status: 'cancelled' }), '');
  assert.equal(lookup.secretaryBriefLine(null), '');
});

test('maintenance reminders: two weeks ahead, on the due date, unpaid contracts; each only once', async () => {
  const now = new Date('2026-10-25T13:00:00Z');
  store.set(`${COMPANY}/settings/config`, { carePlanRemindDays: 14 });
  store.set(`${COMPANY}/care_plans/soon`, {
    clientId: 'c1', clientName: 'Amelia', status: 'active', nextMaintenanceDue: new Date('2026-11-03T12:00:00Z'),
  });
  store.set(`${COMPANY}/care_plans/due`, {
    clientId: 'c2', clientName: 'Brad', status: 'past_due', nextMaintenanceDue: new Date('2026-10-20T12:00:00Z'),
  });
  store.set(`${COMPANY}/care_plans/later`, {
    clientId: 'c3', status: 'active', nextMaintenanceDue: new Date('2027-01-20T12:00:00Z'),
  });
  store.set(`${COMPANY}/care_plans/unpaid`, {
    clientId: 'c4', clientName: 'Chris', status: 'pending', signedAt: new Date('2026-10-20T15:00:00Z'),
  });
  store.set(`${COMPANY}/care_plans/fresh`, {
    clientId: 'c5', status: 'pending', signedAt: new Date('2026-10-24T15:00:00Z'),
  });
  store.set(`${COMPANY}/care_plans/gone`, {
    clientId: 'c6', status: 'cancelled', nextMaintenanceDue: new Date('2026-10-20T12:00:00Z'),
  });
  store.set(`${COMPANY}/appliances/a1`, { planId: 'soon' });
  store.set(`${COMPANY}/appliances/a2`, { planId: 'soon' });
  store.set(`${COMPANY}/appliances/a3`, { planId: 'soon', status: 'retired' });

  assert.equal(await reminders.runReminders(now), 3);
  const byPlan = Object.fromEntries(pushes.map(([title, body, data]) => [data.planId, { title, body, data }]));
  assert.equal(byPlan.soon.title, 'Care Plan: скоро ТО');
  assert.match(byPlan.soon.body, /Amelia — ТО через 9 дн\. \(03\.11\) · 2 ед\. техники/);
  assert.equal(byPlan.due.title, 'Care Plan: пора ТО');
  assert.equal(byPlan.unpaid.title, 'Care Plan не оплачен');
  assert.equal(byPlan.soon.data.type, 'care_plan');
  assert.equal(byPlan.soon.data.clientId, 'c1');
  assert.equal(store.get(`${COMPANY}/care_plans/soon`).lastReminderKey, '2026-11-03:soon');

  assert.equal(await reminders.runReminders(now), 0, 'the same reminder is not sent twice');
  // 3 ноября: у «soon» наступил срок ТО, а «fresh» уже 10 дней без оплаты.
  pushes = [];
  assert.equal(await reminders.runReminders(new Date('2026-11-03T14:00:00Z')), 2);
  const later = Object.fromEntries(pushes.map(([title, , data]) => [data.planId, title]));
  assert.deepEqual(later, { soon: 'Care Plan: пора ТО', fresh: 'Care Plan не оплачен' });
});

test('next maintenance falls back to the plan rules when no date is stored', () => {
  assert.equal(
    reminders.nextMaintenanceDue({ signedAt: new Date('2026-10-01T12:00:00Z'), firstMaintenanceDays: 30 }).toISOString(),
    '2026-10-31T12:00:00.000Z',
  );
  assert.equal(
    reminders.nextMaintenanceDue({ lastMaintenanceAt: new Date('2026-01-31T12:00:00Z'), maintenanceMonths: 1 }).toISOString(),
    '2026-02-28T12:00:00.000Z',
  );
});
