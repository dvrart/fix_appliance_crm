// Еженедельная копия: что в неё попадает. Firestore — заглушка на путях.
const assert = require('node:assert/strict');
const { test } = require('node:test');

const { buildBackupPayload, COLLECTIONS } = require('./backup');

const COMPANY = 'fix_appliance_ca';

function docRef(path) {
  const parts = path.split('/');
  return {
    id: parts[parts.length - 1],
    path,
    get parent() {
      return collectionRef(parts.slice(0, -1).join('/'));
    },
  };
}

function collectionRef(path) {
  const parts = path.split('/');
  return {
    id: parts[parts.length - 1],
    path,
    get parent() {
      return parts.length > 1 ? docRef(parts.slice(0, -1).join('/')) : null;
    },
  };
}

function snapshotOf(store, keep) {
  const docs = [...store.entries()]
    .filter(([path]) => keep(path))
    .map(([path, data]) => ({ id: path.split('/').pop(), ref: docRef(path), data: () => structuredClone(data) }));
  return { docs, size: docs.length };
}

function fakeDb(store) {
  const collection = (path) => ({
    doc: (id) => ({ collection: (name) => collection(`${path}/${id}/${name}`) }),
    get: async () =>
      snapshotOf(store, (p) => p.startsWith(`${path}/`) && p.split('/').length === path.split('/').length + 1),
  });
  return {
    collection,
    collectionGroup: (name) => ({
      get: async () => snapshotOf(store, (p) => p.split('/').slice(-2, -1)[0] === name),
    }),
  };
}

test('копия берёт Care Plan, технику клиентов и прочие живые коллекции', () => {
  for (const name of [
    'care_plans',
    'appliances',
    'passport_notes',
    'scheduled_messages',
    'secretary_lessons',
    'shipment_events',
    'short_links',
  ]) {
    assert.ok(COLLECTIONS.includes(name), name);
  }
});

test('чат и история правок внутри заявок попадают в копию, SMS мастерской — нет', async () => {
  const root = `companies/${COMPANY}`;
  const store = new Map([
    [`${root}/jobs/j1`, { clientName: 'Will' }],
    [`${root}/care_plans/p1`, { name: 'Gold' }],
    [`${root}/messages/sms1`, { body: 'top-level sms' }],
    [`${root}/jobs/j1/messages/m1`, { text: 'деталь заказана' }],
    [`${root}/jobs/j1/changes/c1`, { field: 'status' }],
    ['companies/other/jobs/x/messages/m9', { text: 'чужая компания' }],
  ]);

  const payload = await buildBackupPayload(fakeDb(store), COMPANY);

  assert.deepEqual(payload.collections.care_plans, [{ id: 'p1', name: 'Gold' }]);
  assert.deepEqual(payload.collections.messages, [{ id: 'sms1', body: 'top-level sms' }]);
  assert.deepEqual(payload.jobSubcollections.messages, [{ jobId: 'j1', id: 'm1', text: 'деталь заказана' }]);
  assert.deepEqual(payload.jobSubcollections.changes, [{ jobId: 'j1', id: 'c1', field: 'status' }]);
  assert.equal(payload.counts['jobs/*/messages'], 1);
  assert.equal(payload.partial, false);
});
