const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');
const realTwilio = require('twilio');

const COMPANY = 'companies/fix_appliance_ca';
const CALL = `CA${'1'.repeat(32)}`;
const MESSAGE = `SM${'2'.repeat(32)}`;
let store;
let notifications;
let failWrites;
let transactionTail;
let mediaReads;
let sentSms;
let beforeTransaction;
let retryTransaction;

function snapshot(path) {
  const stored = structuredClone(store.get(path));
  return {
    exists: stored !== undefined, id: path.split('/').pop(), ref: ref(path),
    data: () => {
      const data = structuredClone(stored);
      if (data?.sendAt instanceof Date) data.sendAt = { toDate: () => new Date(stored.sendAt) };
      return data;
    },
  };
}

function apply(path, data, merge = true) {
  if (failWrites) throw new Error('Synthetic storage failure');
  const value = { ...(merge ? store.get(path) : {}), ...structuredClone(data) };
  for (const [key, item] of Object.entries(value)) if (item?.__delete) delete value[key];
  store.set(path, value);
}

function ref(path, filters = [], queryLimit = Infinity, after = '') {
  return {
    path, id: path.split('/').pop(),
    collection: (name) => ref(`${path}/${name}`),
    doc: (name = 'generated-document') => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, [field, op, value]], queryLimit, after),
    orderBy() { return this; },
    limit: (count) => ref(path, filters, count, after),
    startAfter: (document) => ref(path, filters, queryLimit, document.id),
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .sort()
        .map(snapshot)
        .filter((doc) => doc.id > after && filters.every(([field, op, expected]) => op !== '==' || doc.data()?.[field] === expected))
        .slice(0, queryLimit);
      return { docs, empty: !docs.length, size: docs.length };
    },
    set: async (data, options) => apply(path, data, options?.merge === true),
    update: async (data) => apply(path, data),
    create: async (data) => {
      if (store.has(path)) throw Object.assign(new Error('Already exists'), { code: 6 });
      apply(path, data, false);
    },
    delete: async () => store.delete(path),
    add: async (data) => { const doc = ref(`${path}/generated-document`); await doc.create(data); return doc; },
  };
}

const db = {
  collection: (name) => ref(name),
  runTransaction: (work) => {
    const result = transactionTail.then(async () => {
      if (beforeTransaction) {
        const before = beforeTransaction;
        beforeTransaction = null;
        before();
      }
      const attempt = async (commit) => {
        const writes = [];
        const result = await work({
          get: (document) => document.get(),
          set: (document, data, options) => writes.push(() => apply(document.path, data, options?.merge === true)),
          update: (document, data) => writes.push(() => apply(document.path, data)),
        });
        if (commit) writes.forEach((write) => write());
        return result;
      };
      if (retryTransaction) {
        const conflict = retryTransaction;
        retryTransaction = null;
        await attempt(false);
        conflict();
      }
      return attempt(true);
    });
    transactionTail = result.catch(() => {});
    return result;
  },
};
class FakeTimestamp extends Date {
  toDate() { return new Date(this); }
}
const firestore = Object.assign(() => db, {
  FieldValue: { serverTimestamp: () => new Date(), delete: () => ({ __delete: true }), increment: (value) => value },
  Timestamp: { now: () => new FakeTimestamp(), fromDate: (date) => date, fromMillis: (value) => new Date(value) },
});
const handler = (...args) => args.at(-1);
const fakeTwilio = Object.assign(() => ({
  calls: Object.assign(() => ({ fetch: async () => ({ status: 'completed' }) }), { list: async () => [] }),
  recordings: { list: async () => [] },
  messages: { create: async (payload) => {
    sentSms.push(payload);
    return { sid: `SM-synthetic-${sentSms.length}`, status: 'queued' };
  } },
}), realTwilio);
const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return {
    initializeApp: () => ({}), firestore,
    storage: () => ({ bucket: () => ({ name: 'test-bucket', file: () => ({ download: async () => { mediaReads++; throw new Error('Unexpected media work'); } }) }) }),
  };
  if (name === 'firebase-functions') return { https: { onRequest: handler }, scheduler: { onSchedule: handler } };
  if (name === 'firebase-functions/v2/https') return { onRequest: handler };
  if (name === 'firebase-functions/v2/firestore') return { onDocumentWritten: handler };
  if (name === 'firebase-functions/v2/scheduler') return { onSchedule: handler };
  if (name === './auth_guard') return { requireTwilioSignature: () => true, requireAppUser: async () => ({ uid: 'test-user' }), verifyAppUser: async () => ({ uid: 'test-user' }) };
  if (name === './notify') return { notifyMaster: async (...args) => notifications.push(args), registerDeviceToken: async () => {} };
  if (name === 'twilio') return fakeTwilio;
  return load.apply(this, arguments);
};
const originalSid = process.env.TWILIO_ACCOUNT_SID;
const originalToken = process.env.TWILIO_AUTH_TOKEN;
process.env.TWILIO_ACCOUNT_SID = `AC${'0'.repeat(32)}`;
process.env.TWILIO_AUTH_TOKEN = 'synthetic-test-token';
let api;
try {
  api = require('./index');
} finally {
  Module._load = load;
  if (originalSid === undefined) delete process.env.TWILIO_ACCOUNT_SID;
  else process.env.TWILIO_ACCOUNT_SID = originalSid;
  if (originalToken === undefined) delete process.env.TWILIO_AUTH_TOKEN;
  else process.env.TWILIO_AUTH_TOKEN = originalToken;
}

function response() {
  return {
    statusCode: 200, headersSent: false, body: null,
    status(code) { this.statusCode = code; return this; },
    type() { return this; }, set() { return this; },
    send(body) { assert.equal(this.headersSent, false); this.headersSent = true; this.body = body; return this; },
    json(body) { return this.send(body); },
  };
}

function request(body) {
  return { method: 'POST', body, headers: { host: 'example.test' }, query: {}, protocol: 'https', get: () => 'example.test' };
}

beforeEach(() => {
  store = new Map([
    [`${COMPANY}/settings/config`, { aiAnswerEnabled: false, aiAnswerTimeoutSeconds: 15 }],
    [`${COMPANY}/calls/${CALL}`, { callSid: CALL, status: 'in-progress', direction: 'inbound', fromNumber: '+14165550101' }],
  ]);
  notifications = [];
  failWrites = false;
  transactionTail = Promise.resolve();
  mediaReads = 0;
  sentSms = [];
  beforeTransaction = null;
  retryTransaction = null;
});

test('concurrent SMS webhook retries persist one message and queue work before acknowledging', async () => {
  const first = response();
  const second = response();
  const body = { MessageSid: MESSAGE, From: '+14165550101', To: '+14165550102', Body: 'Synthetic repair message', NumMedia: '0' };
  await Promise.all([api.incomingSms(request(body), first), api.incomingSms(request(body), second)]);
  const messages = [...store.entries()].filter(([path]) => path.startsWith(`${COMPANY}/messages/`));
  assert.equal(messages.length, 1);
  assert.equal(messages[0][1].processingVersion, 2);
  assert.equal(messages[0][1].smsProcessingRequestId, MESSAGE);
  assert.equal(first.statusCode, 200);
  assert.equal(second.statusCode, 200);
  assert.equal(notifications.length, 0);
});

test('a failed SMS save is not acknowledged as delivered', async () => {
  failWrites = true;
  const res = response();
  await api.incomingSms(request({ MessageSid: MESSAGE, From: '+14165550101', Body: 'Synthetic message', NumMedia: '0' }), res);
  assert.equal(res.statusCode, 503);
  assert.equal(notifications.length, 0);
});

test('recording callbacks keep the longest take and do not complete a still-active parent call', async () => {
  const callback = async (duration, digit) => {
    const res = response();
    await api.recordingComplete(request({ CallSid: CALL, RecordingSid: `RE${digit.repeat(32)}`, RecordingUrl: `https://api.twilio.com/Recordings/RE${digit.repeat(32)}`, RecordingDuration: String(duration), RecordingChannels: '2', RecordingStatus: 'completed' }), res);
    assert.equal(res.statusCode, 200);
  };
  await Promise.all([callback(90, '3'), callback(20, '4')]);
  const call = store.get(`${COMPANY}/calls/${CALL}`);
  assert.equal(call.recordingDurationSeconds, 90);
  assert.equal(call.recordingRequestId, `RE${'3'.repeat(32)}`);
  assert.equal(call.recordingProcessingVersion, 2);
  assert.equal(call.status, 'in-progress');
  assert.equal(mediaReads, 0);
});

test('a late status callback cannot reopen a completed call', async () => {
  await api.callStatusCallback(request({ CallSid: CALL, CallStatus: 'completed', CallDuration: '90' }), response());
  await api.callStatusCallback(request({ CallSid: CALL, CallStatus: 'ringing' }), response());
  const call = store.get(`${COMPANY}/calls/${CALL}`);
  assert.equal(call.status, 'completed');
  assert.equal(call.twilioStatus, 'completed');
  assert.equal(call.durationSeconds, 90);
  assert.equal(call.recordingRecoveryRequestId, CALL);
});

test('replayed incoming webhooks preserve review state and do not send a second ringing alert', async () => {
  store.set(`${COMPANY}/calls/${CALL}`, { callSid: CALL, status: 'completed', reviewed: true, aiStatus: 'done', startTime: new Date('2026-09-01') });
  const res = response();
  await api.incomingCall(request({ CallSid: CALL, From: '+14165550101', To: '+14165550102' }), res);
  const call = store.get(`${COMPANY}/calls/${CALL}`);
  assert.equal(call.status, 'completed');
  assert.equal(call.reviewed, true);
  assert.equal(call.aiStatus, 'done');
  assert.equal(notifications.length, 0);
  assert.match(res.body, /<Dial/);
});

function scheduledMessage(overrides = {}) {
  const path = `${COMPANY}/scheduled_messages/synthetic-message`;
  store.set(path, {
    channel: 'sms', to: '+14165550101', body: 'Original text',
    status: 'pending', sendAt: new Date(Date.now() - 60000), ...overrides,
  });
  return path;
}

test('concurrent scheduled-message workers send one SMS', async () => {
  const path = scheduledMessage();
  await Promise.all([api.processScheduledMessages(), api.processScheduledMessages()]);
  assert.equal(sentSms.length, 1);
  assert.equal(store.get(path).status, 'sent');
});

for (const status of ['cancelled', 'sending']) {
  test(`a retried transaction cannot send a scheduled message now ${status}`, async () => {
    const path = scheduledMessage();
    retryTransaction = () => apply(path, { status });
    await api.processScheduledMessages();
    assert.equal(sentSms.length, 0);
    assert.equal(store.get(path).status, status);
  });
}

test('a failed claim commit never sends the scheduled message', async () => {
  const path = scheduledMessage();
  retryTransaction = () => { throw new Error('Synthetic commit failure'); };
  await api.processScheduledMessages();
  assert.equal(sentSms.length, 0);
  assert.equal(store.get(path).status, 'pending');
});

test('scheduled sending uses the payload from the successful transaction', async () => {
  const path = scheduledMessage();
  beforeTransaction = () => apply(path, { body: 'Updated text', to: '+14165550109' });
  await api.processScheduledMessages();
  assert.equal(sentSms.length, 1);
  assert.equal(sentSms[0].to, '+14165550109');
  assert.match(sentSms[0].body, /Updated text/);
  assert.doesNotMatch(sentSms[0].body, /Original text/);
});

test('a scheduled message moved to a future time is not sent from an old snapshot', async () => {
  const path = scheduledMessage();
  beforeTransaction = () => apply(path, { sendAt: new Date(Date.now() + 3600000) });
  await api.processScheduledMessages();
  assert.equal(sentSms.length, 0);
  assert.equal(store.get(path).status, 'pending');
});

test('due messages are not starved behind a page of future scheduled messages', async () => {
  const path = scheduledMessage();
  for (let index = 0; index < 55; index++) {
    store.set(`${COMPANY}/scheduled_messages/00-future-${String(index).padStart(3, '0')}`, {
      channel: 'sms', to: '+14165550101', body: 'Future message',
      status: 'pending', sendAt: new Date(Date.now() + 3600000),
    });
  }
  await api.processScheduledMessages();
  assert.equal(sentSms.length, 1);
  assert.match(sentSms[0].body, /Original text/);
  assert.equal(store.get(path).status, 'sent');
});

test('an unsupported scheduled channel is failed instead of reported as sent', async () => {
  const path = scheduledMessage({ channel: 'unsupported' });
  await api.processScheduledMessages();
  assert.equal(sentSms.length, 0);
  assert.equal(store.get(path).status, 'failed');
});
