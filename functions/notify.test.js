const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const TOKENS = `${COMPANY}/fcm_tokens`;
let store;
let sent;
let removed;
let failedTokens;
let onSend;

function document(path) {
  return {
    id: path.split('/').pop(),
    path,
    collection: (name) => document(`${path}/${name}`),
    doc: (name) => document(`${path}/${name}`),
    get: async () => {
      const data = store.get(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot);
      return { ...snapshot(path), docs, empty: !docs.length, data: () => data };
    },
    set: async (data, options) => store.set(path, { ...(options?.merge ? store.get(path) : {}), ...data }),
    delete: async () => { removed.push(path); store.delete(path); },
  };
}

function snapshot(path) {
  return { id: path.split('/').pop(), ref: document(path), exists: store.has(path), data: () => store.get(path) };
}

const firestore = Object.assign(() => ({
  collection: (name) => document(name),
  runTransaction: async (work) => work({
    get: (ref) => ref.get(),
    set: (ref, data, options) => ref.set(data, options),
    delete: (ref) => ref.delete(),
  }),
}), { FieldValue: { serverTimestamp: () => new Date() } });

const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return {
    firestore,
    messaging: () => ({
      sendEachForMulticast: async (message) => {
        assert.ok(message.tokens.length <= 500, 'FCM accepts at most 500 tokens per multicast');
        sent.push(structuredClone(message));
        if (onSend) await onSend(message);
        return { responses: message.tokens.map((token) => failedTokens.has(token)
          ? { success: false, error: { code: 'messaging/registration-token-not-registered' } }
          : { success: true }) };
      },
    }),
  };
  return load.apply(this, arguments);
};
const { notifyMaster, sanitizeFcmData, registerDeviceToken } = require('./notify');
Module._load = load;

beforeEach(() => {
  store = new Map([[`${TOKENS}/phone`, { token: 'test-phone-token', platform: 'android' }]]);
  sent = [];
  removed = [];
  failedTokens = new Set();
  onSend = null;
});

test('Android CRM pushes are data-only so only the native renderer owns the shade', async () => {
  await notifyMaster('Test call', 'Synthetic call', { type: 'call', callSid: 'CA-test-1', from: '+14165550101' });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].notification, undefined);
  assert.equal(sent[0].android.notification, undefined);
  assert.equal(sent[0].data.peer, '+14165550101');
  assert.equal(sent[0].data.from, undefined);
  assert.equal(sent[0].data.title, 'Test call');
});

test('legacy from and FCM peer use one contact tag', async () => {
  await notifyMaster('Test', '', { type: 'call', callSid: 'CA-test-1', from: '+1 (416) 555-0101' });
  await notifyMaster('Test', '', { type: 'visit_confirm', jobId: 'job-1', peer: '4165550101' });
  assert.equal(sent[0].data.tag, 'crm_inbox_4165550101');
  assert.equal(sent[1].data.tag, sent[0].data.tag);
});

test('call outcome retries retain one event identity but a new call has its own identity', async () => {
  await notifyMaster('Missed call', '', { type: 'call', callSid: 'CA-test-1', from: '+14165550101' });
  await notifyMaster('Call ready', '', { type: 'call', callSid: 'CA-test-1', from: '+14165550101', kind: 'call_offer' });
  await notifyMaster('Missed call', '', { type: 'call', callSid: 'CA-test-2', from: '+14165550101' });
  assert.equal(sent[0].data.eventId, 'call:CA-test-1');
  assert.equal(sent[1].data.eventId, sent[0].data.eventId);
  assert.notEqual(sent[2].data.eventId, sent[0].data.eventId);
});

test('an SMS and its AI job update share the message identity', async () => {
  await notifyMaster('SMS', '', { type: 'sms', messageId: 'SM-test-1', from: '+14165550101' });
  await notifyMaster('Job updated', '', { type: 'job', source: 'sms', jobId: 'job-1', messageId: 'SM-test-1', from: '+14165550101' });
  assert.equal(sent[0].data.eventId, 'sms:SM-test-1');
  assert.equal(sent[1].data.eventId, sent[0].data.eventId);
  assert.equal(sent[1].data.channelId, 'sms_messages');
});

test('email digits are not interpreted as a phone number', async () => {
  await notifyMaster('Email', '', { type: 'email', from: '4165550101@example.test', messageId: 'email-1' });
  assert.equal(sent[0].data.tag, 'crm_inbox_4165550101@example.test');
});

test('long email addresses with a common prefix do not overwrite one another', async () => {
  const prefix = 'long.customer.address.with.a.shared.prefix';
  await notifyMaster('Email', '', { type: 'email', from: `${prefix}@first.example.test` });
  await notifyMaster('Email', '', { type: 'email', from: `${prefix}@second.example.test` });
  assert.notEqual(sent[0].data.tag, sent[1].data.tag);
  assert.ok(sent[0].data.tag.length <= 50);
});

test('duplicate and disabled token documents never deliver a second push to one device', async () => {
  store.set(`${TOKENS}/duplicate`, { token: 'test-phone-token', platform: 'android' });
  store.set(`${TOKENS}/disabled`, { token: 'test-disabled-token', disabled: true });
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.deepEqual(sent.flatMap((message) => message.tokens), ['test-phone-token']);
});

test('only the latest token for an installation receives notifications', async () => {
  store.clear();
  store.set(`${TOKENS}/old`, { token: 'old-token', deviceId: 'test-install', updatedAt: new Date('2026-01-01') });
  store.set(`${TOKENS}/new`, { token: 'new-token', deviceId: 'test-install', updatedAt: new Date('2026-02-01') });
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.deepEqual(sent.flatMap((message) => message.tokens), ['new-token']);
});

test('invalid registrations before valid ones cannot shift failed-token cleanup', async () => {
  store.clear();
  store.set(`${TOKENS}/empty`, { platform: 'android' });
  store.set(`${TOKENS}/stale`, { token: 'stale-token' });
  failedTokens.add('stale-token');
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.deepEqual(removed, [`${TOKENS}/stale`]);
  assert.ok(store.has(`${TOKENS}/empty`));
});

test('a token rotated during delivery is not deleted by the old-token failure', async () => {
  failedTokens.add('test-phone-token');
  onSend = async () => store.set(`${TOKENS}/phone`, { token: 'replacement-token' });
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.equal(store.get(`${TOKENS}/phone`)?.token, 'replacement-token');
});

test('large registration lists are sent in bounded batches', async () => {
  store.clear();
  for (let i = 0; i < 501; i++) store.set(`${TOKENS}/${i}`, { token: `test-token-${i}` });
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.deepEqual(sent.map((message) => message.tokens.length), [500, 1]);
});

test('token rotation updates one installation and retires its legacy registrations', async () => {
  store.clear();
  store.set(`${TOKENS}/old-token`, { token: 'old-token' });
  await registerDeviceToken({ token: 'new-token', previousToken: 'old-token', platform: 'android', deviceId: 'test-installation-1', userId: 'test-user' });
  await registerDeviceToken({ token: 'latest-token', platform: 'android', deviceId: 'test-installation-1', userId: 'test-user' });
  assert.equal(store.get(`${TOKENS}/old-token`).disabled, true);
  assert.equal([...store.keys()].filter((key) => key.includes('/device_')).length, 1);
  await notifyMaster('Test', '', { type: 'sms', messageId: 'SM-test-1' });
  assert.deepEqual(sent.flatMap((message) => message.tokens), ['latest-token']);
});

test('legacy app versions can still register without an installation id', async () => {
  store.clear();
  await registerDeviceToken({ token: 'legacy-token', platform: 'android', userId: 'test-user' });
  assert.equal(store.get(`${TOKENS}/legacy-token`).token, 'legacy-token');
});

test('FCM reserved data keys remain filtered', () => {
  assert.deepEqual(sanitizeFcmData({ from: '+14165550101', googleKey: 'x', gcmKey: 'x', notification: 'x', type: 'sms' }), {
    type: 'sms', peer: '+14165550101',
  });
});
