const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const NOW = new Date('2026-09-20T15:00:00Z');
let store;
let writes;

function snapshot(path) {
  return {
    id: path.split('/').pop(),
    ref: ref(path),
    exists: store.has(path),
    data: () => structuredClone(store.get(path)),
  };
}

function ref(path, filters = []) {
  return {
    path,
    id: path.split('/').pop(),
    collection: (name) => ref(`${path}/${name}`),
    doc: (name) => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, { field, op, value }]),
    set: async (data) => apply(ref(path), data),
    update: async (data) => apply(ref(path), data),
    get: async () => {
      if (store.has(path)) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot)
        .filter((doc) => filters.every(({ field, value }) => doc.data()[field] === value));
      return { ...snapshot(path), docs, empty: !docs.length };
    },
  };
}

function apply(document, data) {
  const previous = structuredClone(store.get(document.path));
  store.set(document.path, { ...previous, ...structuredClone(data) });
  writes.push({ path: document.path, data: structuredClone(data) });
}

const firestore = Object.assign(() => ({ collection: (name) => ref(name) }), {
  Timestamp: { now: () => NOW, fromDate: (value) => value },
  FieldValue: { serverTimestamp: () => NOW, delete: () => null },
});

const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return { firestore };
  return load.apply(this, arguments);
};
const dedupe = require('./job_dedupe');
Module._load = load;

function job(id, patch = {}) {
  return {
    id,
    status: 'Вызов',
    clientId: 'client-1',
    clientName: 'Amelia',
    clientPhone: '+14165550101',
    clientAddress: '12 King Street, Toronto',
    applianceType: 'Стиральная машина',
    description: '',
    source: 'phone',
    sourceCallId: `call-${id}`,
    needsReview: true,
    visits: [],
    createdAt: NOW,
    ...patch,
  };
}

function put(data) {
  store.set(`${COMPANY}/jobs/${data.id}`, data);
  return data;
}

function read(id) {
  return store.get(`${COMPANY}/jobs/${id}`) || {};
}

beforeEach(() => {
  store = new Map();
  writes = [];
});

test('two drafts from one number inside 48 hours become one job', async () => {
  const first = put(job('first', { description: 'Washer leaking' }));
  const second = put(
    job('second', {
      clientAddress: '',
      applianceType: 'Техника',
      description: 'Water on the floor',
      model: 'WF45T6000',
      createdAt: new Date('2026-09-21T09:00:00Z'),
      sourceCallId: 'call-second',
    })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.equal(result.mergedInto, 'first');
  assert.deepEqual(result.merged, ['second']);
  const keep = read('first');
  assert.equal(keep.model, 'WF45T6000');
  assert.match(keep.description, /Washer leaking/);
  assert.match(keep.description, /Water on the floor/);
  assert.deepEqual(keep.mergedFromJobIds, ['second']);
  const drop = read('second');
  assert.equal(drop.status, 'Отменено');
  assert.equal(drop.mergedIntoJobId, 'first');
  assert.equal(drop.needsReview, false);
});

test('the merge note lives in history, not in the description', async () => {
  put(job('first', { description: 'Washer leaking' }));
  const second = put(
    job('second', { description: '', createdAt: new Date('2026-09-20T18:00:00Z') })
  );

  await dedupe.checkJobForDuplicates(second.id, second);

  assert.equal(read('first').description, 'Washer leaking');
  assert.equal(
    store.get(`${COMPANY}/jobs/first/changes/merged_second`).event,
    'merged_duplicate'
  );
  assert.equal(
    store.get(`${COMPANY}/jobs/second/changes/merged_into_first`).event,
    'merged_into'
  );
});

test('the job with a booked visit stays and swallows the later draft', async () => {
  put(
    job('booked', {
      needsReview: false,
      visits: [{ id: 'v1', startAt: new Date('2026-09-22T18:00:00Z'), outcome: 'scheduled' }],
    })
  );
  const draft = put(
    job('draft', {
      clientName: 'Клиент +14165550101',
      description: 'Dryer is noisy too',
      applianceType: 'Сушильная машина',
      createdAt: new Date('2026-09-20T20:00:00Z'),
    })
  );

  await dedupe.checkJobForDuplicates(draft.id, draft);

  const keep = read('booked');
  assert.equal(read('draft').mergedIntoJobId, 'booked');
  assert.match(keep.description, /Dryer is noisy too/);
  assert.equal(keep.needsReview, true);
});

test('a second appliance from the same caller rides along on the kept job', async () => {
  put(job('first', { appliances: [{ type: 'Стиральная машина', brand: 'LG' }] }));
  const second = put(
    job('second', {
      appliances: [{ type: 'Сушильная машина', brand: 'LG' }],
      applianceType: 'Сушильная машина',
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  await dedupe.checkJobForDuplicates(second.id, second);

  const types = read('first').appliances.map((item) => item.type);
  assert.deepEqual(types, ['Стиральная машина', 'Сушильная машина']);
});

test('one number at two different addresses is two jobs, not a duplicate', async () => {
  put(job('first', { clientAddress: '12 King Street, Toronto' }));
  const second = put(
    job('second', {
      clientAddress: '480 Queen Street West, Toronto',
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.deepEqual(result, { merged: [], flagged: [], mergedInto: '' });
  assert.equal(read('second').status, 'Вызов');
  assert.equal(read('second').possibleDuplicateOfJobId, undefined);
});

test('the same address written longer is still the same address', () => {
  const short = { clientAddress: '12 King Street' };
  const long = { clientAddress: '12 King Street, Toronto, ON' };
  assert.equal(dedupe.differentAddress(short, long), false);
  assert.equal(dedupe.differentAddress(short, { clientAddress: '14 King Street' }), true);
});

test('a call three days later is a new job', async () => {
  put(job('first'));
  const second = put(
    job('second', { createdAt: new Date('2026-09-23T16:00:00Z') })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.deepEqual(result.merged, []);
  assert.equal(read('second').status, 'Вызов');
});

test('an incoming draft still merges into a job the owner typed by hand', async () => {
  put(job('typed', { source: '', sourceCallId: '', needsReview: false }));
  const draft = put(
    job('draft', {
      clientAddress: '',
      description: 'Called again',
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  const result = await dedupe.checkJobForDuplicates(draft.id, draft);

  assert.deepEqual(result.merged, ['draft']);
  assert.equal(read('draft').mergedIntoJobId, 'typed');
  assert.match(read('typed').description, /Called again/);
});

test('two hand-made jobs are only flagged, never closed by the server', async () => {
  const typed = { source: '', sourceCallId: '', needsReview: false };
  put(job('typed-a', typed));
  const second = put(
    job('typed-b', { ...typed, createdAt: new Date('2026-09-20T19:00:00Z') })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.deepEqual(result.merged, []);
  assert.deepEqual(result.flagged, ['typed-b']);
  assert.equal(read('typed-b').possibleDuplicateOfJobId, 'typed-a');
  assert.equal(read('typed-a').status, 'Вызов');
  assert.equal(read('typed-b').status, 'Вызов');
});

test('a flagged pair the owner dismissed is not flagged again', async () => {
  const typed = { source: '', sourceCallId: '', needsReview: false };
  put(job('typed-a', typed));
  const second = put(
    job('typed-b', {
      ...typed,
      duplicateDismissed: true,
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.deepEqual(result.flagged, []);
  assert.equal(read('typed-b').possibleDuplicateOfJobId, undefined);
});

test('calls and messages of the closed duplicate point at the kept job', async () => {
  put(job('first'));
  const second = put(job('second', { createdAt: new Date('2026-09-20T19:00:00Z') }));
  store.set(`${COMPANY}/calls/call-second`, { createdJobId: 'second', jobId: 'second' });
  store.set(`${COMPANY}/messages/sms-1`, { jobId: 'second' });

  await dedupe.checkJobForDuplicates(second.id, second);

  assert.equal(store.get(`${COMPANY}/calls/call-second`).jobId, 'first');
  assert.equal(store.get(`${COMPANY}/calls/call-second`).createdJobId, 'first');
  assert.equal(store.get(`${COMPANY}/messages/sms-1`).jobId, 'first');
});

test('a repeated trigger does not merge the same pair twice', async () => {
  put(job('first'));
  const second = put(job('second', { createdAt: new Date('2026-09-20T19:00:00Z') }));

  await dedupe.checkJobForDuplicates(second.id, second);
  const after = writes.length;
  const again = await dedupe.checkJobForDuplicates('second', read('second'));

  assert.deepEqual(again, { merged: [], flagged: [], mergedInto: '' });
  assert.equal(writes.length, after);
});

test('a closed or trashed job is never touched', async () => {
  put(job('done', { status: 'Завершено' }));
  put(job('trashed', { deletedAt: NOW }));
  const draft = put(job('draft', { createdAt: new Date('2026-09-20T19:00:00Z') }));

  const result = await dedupe.checkJobForDuplicates(draft.id, draft);

  assert.deepEqual(result, { merged: [], flagged: [], mergedInto: '' });
});

test('jobs without a phone are never paired', async () => {
  put(job('first', { clientPhone: '', jobSitePhone: '' }));
  const second = put(
    job('second', {
      clientPhone: '',
      jobSitePhone: '',
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  const result = await dedupe.checkJobForDuplicates(second.id, second);

  assert.deepEqual(result.merged, []);
  assert.equal(read('second').status, 'Вызов');
});

test('the owner can merge a booked duplicate by hand', async () => {
  put(job('keep'));
  put(
    job('other', {
      needsReview: false,
      visits: [{ id: 'v9', startAt: new Date('2026-09-23T18:00:00Z'), outcome: 'scheduled' }],
      createdAt: new Date('2026-09-20T19:00:00Z'),
    })
  );

  const merged = await dedupe.mergeJobs('keep', 'other', { by: 'owner', force: true });

  assert.equal(merged, true);
  assert.equal(read('keep').visits.length, 1);
  assert.equal(read('other').status, 'Отменено');
  assert.equal(read('other').visits[0].outcome, 'cancelled');
});

test('the phone check only reruns when the number changes', () => {
  const before = { clientPhone: '+14165550101' };
  assert.equal(dedupe.phoneChanged(null, before), true);
  assert.equal(dedupe.phoneChanged(before, { clientPhone: '416 555 0101' }), false);
  assert.equal(dedupe.phoneChanged(before, { clientPhone: '+14165550102' }), true);
});
