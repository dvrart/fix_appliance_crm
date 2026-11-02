// Безнал за месяц > $800: подсчёт и одно уведомление на месяц. Firestore и
// пуши — заглушки.
const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const NOW = new Date('2026-10-24T16:00:00Z');
let store;
let pushes;

function snapshot(path) {
  const stored = store.get(path);
  return { id: path.split('/').pop(), exists: stored !== undefined, data: () => structuredClone(stored) };
}

function ref(path, filters = []) {
  return {
    path,
    collection: (name) => ref(`${path}/${name}`),
    doc: (name) => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, { field, op, value }]),
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot)
        .filter((doc) => filters.every(({ field, op, value }) => op === '>=' && doc.data()[field] >= value));
      return { docs, empty: !docs.length };
    },
  };
}

const db = {
  collection: (name) => ref(name),
  runTransaction: async (work) => {
    const writes = [];
    const result = await work({
      get: (document) => document.get(),
      set: (document, data, options) => writes.push(() => store.set(document.path, {
        ...(options?.merge ? store.get(document.path) : {}), ...structuredClone(data),
      })),
    });
    writes.forEach((write) => write());
    return result;
  },
};
const firestore = Object.assign(() => db, { FieldValue: { serverTimestamp: () => NOW } });

const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return { firestore };
  if (name === 'firebase-functions/v2/firestore') return { onDocumentWritten: (_, handler) => handler };
  if (name === './notify') return { notifyMaster: async (...args) => pushes.push(args) };
  return load.apply(this, arguments);
};
const { _internals: alert } = require('./noncash_alert');
Module._load = load;

const invoice = (payments, patch = {}) => ({ type: 'Invoice', number: 'INV-1', items: [], payments, ...patch });
const pay = (amount, method, date = '2026-10-20T12:00:00.000', extra = {}) => ({ amount, method, date, ...extra });
const job = (documents, patch = {}) => ({ status: 'Вызов', updatedAt: NOW, documents, ...patch });

beforeEach(() => {
  store = new Map();
  pushes = [];
});

test('cash and tips on cash are not counted; card, Stripe, e-Transfer, card tips count; refunds subtract', () => {
  const jobs = [
    job([invoice([pay(300, 'Наличные'), pay(20, 'Tip')])]),
    job([invoice([pay(226, 'Stripe', '2026-10-05T15:00:00.000Z', { stripePaymentIntentId: 'pi_1' }), pay(10, 'Чаевые', '2026-10-05T15:00:00.000Z', { stripePaymentIntentId: 'pi_1' })])]),
    job([invoice([pay(150, 'E-Transfer'), pay(40, 'Tip')])]),
    job([invoice([pay(100, 'Card'), pay(-50, 'Stripe (refund)', '2026-10-21T12:00:00.000Z', { stripeRefundId: 're_1' })])]),
    job([invoice([pay(80, 'Cheque')])]),
    job([invoice([pay(-30, 'Возврат (наличные)')])]),
  ];
  assert.equal(alert.nonCashTotalForMonth(jobs, '2026-10'), 226 + 10 + 150 + 40 + 100 - 50 + 80);
});

test('other months, estimates, trashed invoices and deleted jobs are skipped', () => {
  const jobs = [
    job([invoice([pay(500, 'Card', '2026-09-30T12:00:00.000')])]),
    job([invoice([pay(500, 'Card')], { type: 'Estimate' })]),
    job([invoice([pay(500, 'Card')], { deletedAt: '2026-10-21T00:00:00.000' })]),
    job([invoice([pay(500, 'Card')])], { deletedAt: '2026-10-22T00:00:00.000' }),
    job([invoice([pay(500, 'Card')], { status: 'cancelled' })]),
  ];
  assert.equal(alert.nonCashTotalForMonth(jobs, '2026-10'), 0);
});

test('payment month follows Toronto: app local time as is, server UTC converted', () => {
  assert.equal(alert.paymentMonthKey('2026-10-31T22:30:00.000'), '2026-10');
  assert.equal(alert.paymentMonthKey('2026-11-01T02:30:00.000Z'), '2026-10');
  assert.equal(alert.paymentMonthKey('2026-11-01T05:30:00.000Z'), '2026-11');
  assert.equal(alert.paymentMonthKey(new Date('2026-10-15T12:00:00Z')), '2026-10');
});

test('crossing $800 sends one notification per month, cash never triggers it', async () => {
  store.set(`${COMPANY}/jobs/a`, job([invoice([pay(500, 'Stripe', '2026-10-02T15:00:00.000Z')])]));
  store.set(`${COMPANY}/jobs/old`, job([invoice([pay(900, 'Card', '2026-09-10T12:00:00.000')])], { updatedAt: new Date('2026-09-10T16:00:00Z') }));

  const before = job([invoice([])]);
  const cash = job([invoice([pay(1000, 'Наличные')])]);
  store.set(`${COMPANY}/jobs/b`, cash);
  assert.deepEqual(await alert.handleJobWrite(before, cash, 'b', NOW), { checked: false });

  const under = job([invoice([pay(1000, 'Наличные'), pay(300, 'E-Transfer')])]);
  store.set(`${COMPANY}/jobs/b`, under);
  const first = await alert.handleJobWrite(cash, under, 'b', NOW);
  assert.equal(first.total, 800);
  assert.equal(first.notified, false);
  assert.equal(pushes.length, 0);

  const over = job([invoice([pay(1000, 'Наличные'), pay(300, 'E-Transfer'), pay(0.5, 'Card')])]);
  store.set(`${COMPANY}/jobs/b`, over);
  const crossed = await alert.handleJobWrite(under, over, 'b', NOW);
  assert.equal(crossed.notified, true);
  assert.equal(crossed.total, 800.5);
  assert.equal(pushes.length, 1);
  assert.match(pushes[0][0], /\$800/);
  assert.match(pushes[0][1], /С 1 октября пришло \$800\.50/);
  assert.equal(pushes[0][2].type, 'noncash_month');
  assert.equal(store.get(`${COMPANY}/settings/noncash_alert`).notifiedMonth, '2026-10');

  const more = job([invoice([pay(1000, 'Наличные'), pay(300, 'E-Transfer'), pay(0.5, 'Card'), pay(200, 'Card')])]);
  store.set(`${COMPANY}/jobs/b`, more);
  assert.deepEqual(await alert.handleJobWrite(over, more, 'b', NOW), { checked: false });
  assert.equal(pushes.length, 1);

  const nextMonth = new Date('2026-11-03T16:00:00Z');
  const november = job([invoice([pay(900, 'Card', '2026-11-03T11:00:00.000')])], { updatedAt: nextMonth });
  store.set(`${COMPANY}/jobs/c`, november);
  const again = await alert.handleJobWrite(null, november, 'c', nextMonth);
  assert.equal(again.notified, true);
  assert.equal(pushes.length, 2);
  assert.match(pushes[1][1], /С 1 ноября/);
});
