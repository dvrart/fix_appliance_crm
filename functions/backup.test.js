// Еженедельная копия: что в неё попадает. Firestore — заглушка на путях.
const assert = require('node:assert/strict');
const { test } = require('node:test');

const zlib = require('node:zlib');

const { buildBackupPayload, COLLECTIONS, deliverBackup, sendTelegramDocument } = require('./backup');

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

test('копия уходит сжатой на почту и в Telegram, и один упавший канал не мешает другому', async () => {
  const body = Buffer.from(JSON.stringify({ collections: { jobs: [{ id: 'j1' }] } }));
  const got = [];
  const delivered = await deliverBackup({
    body,
    date: '2026-11-08',
    totalDocs: 1,
    partial: false,
    senders: {
      email: async (file) => {
        got.push(file);
        throw new Error('smtp down');
      },
      telegram: async (file) => {
        got.push(file);
        return true;
      },
    },
  });

  assert.deepEqual(delivered, { email: false, telegram: true });
  assert.equal(got.length, 2);
  assert.equal(got[1].fileName, 'fix-backup-2026-11-08.json.gz');
  assert.deepEqual(zlib.gunzipSync(got[1].content), body);
  assert.match(got[1].caption, /2026-11-08: 1 документов/);
});

test('без получателей копия никуда не уходит', async () => {
  assert.deepEqual(await deliverBackup({ body: Buffer.from('{}'), date: 'd', totalDocs: 0 }), {});
});

test('Telegram получает файл в чат владельца, а отказ бота — это ошибка канала', async () => {
  const calls = [];
  const ok = async (url, init) => {
    calls.push({ url, chat: init.body.get('chat_id'), file: init.body.get('document') });
    return { ok: true, status: 200, json: async () => ({ ok: true }) };
  };
  await sendTelegramDocument({
    token: 'T', chatId: 42, fileName: 'b.json.gz', content: Buffer.from('x'), caption: 'c', fetchImpl: ok,
  });
  assert.equal(calls[0].url, 'https://api.telegram.org/botT/sendDocument');
  assert.equal(calls[0].chat, '42');
  assert.equal(calls[0].file.name, 'b.json.gz');

  const refused = async () => ({ ok: false, status: 403, json: async () => ({ ok: false, description: 'bot was blocked by the user' }) });
  await assert.rejects(
    sendTelegramDocument({ token: 'T', chatId: 42, fileName: 'b', content: Buffer.from('x'), caption: 'c', fetchImpl: refused }),
    /403 bot was blocked/
  );
});
