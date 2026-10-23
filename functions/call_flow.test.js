// Сквозная цепочка звонка на заглушках Twilio/Gemini/Firestore:
// входящий → мастер не взял → секретарь → конец стрима → запись → разбор →
// клиент и заявка → уведомление. Реальных звонков и запросов к Gemini нет.
const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');
const realTwilio = require('twilio');
const realGemini = require('@google/generative-ai');
const realRecordingStore = require('./recording_store');

const COMPANY = 'companies/fix_appliance_ca';
const CALLER = '+14165550101';
let store;
let notifications;
let transactionTail;
let geminiScript;
let geminiCalls;
let downloads;

class FakeTimestamp extends Date {
  toDate() { return new Date(this); }
  toMillis() { return this.getTime(); }
}
function revive(value) {
  if (value instanceof Date) return new FakeTimestamp(value);
  if (Array.isArray(value)) return value.map(revive);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, revive(item)]));
  }
  return value;
}
function snapshot(path) {
  const stored = store.get(path);
  return {
    exists: stored !== undefined, id: path.split('/').pop(), ref: ref(path),
    data: () => (stored === undefined ? undefined : revive(structuredClone(stored))),
  };
}
function apply(path, data, merge = true) {
  const value = { ...(merge ? store.get(path) : {}), ...structuredClone(data) };
  for (const [key, item] of Object.entries(value)) if (item?.__delete) delete value[key];
  store.set(path, value);
}
let generated = 0;
function ref(path, filters = [], queryLimit = Infinity) {
  return {
    path, id: path.split('/').pop(),
    collection: (name) => ref(`${path}/${name}`),
    doc: (name = `generated-${++generated}`) => ref(`${path}/${name}`),
    where: (field, op, value) => ref(path, [...filters, [field, op, value]], queryLimit),
    orderBy() { return this; },
    limit: (count) => ref(path, filters, count),
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .sort().map(snapshot)
        .filter((doc) => filters.every(([field, op, expected]) => op !== '==' || doc.data()?.[field] === expected))
        .slice(0, queryLimit);
      return { docs, empty: !docs.length, size: docs.length };
    },
    set: async (data, options) => apply(path, data, options?.merge === true),
    update: async (data) => apply(path, data),
    delete: async () => store.delete(path),
    add: async (data) => { const doc = ref(`${path}/generated-${++generated}`); apply(doc.path, data, false); return doc; },
  };
}
const db = {
  collection: (name) => ref(name),
  runTransaction: (work) => {
    const result = transactionTail.then(async () => {
      const writes = [];
      const value = await work({
        get: (document) => document.get(),
        set: (document, data, options) => writes.push(() => apply(document.path, data, options?.merge === true)),
        update: (document, data) => writes.push(() => apply(document.path, data)),
      });
      writes.forEach((write) => write());
      return value;
    });
    transactionTail = result.catch(() => {});
    return result;
  },
};
const firestore = Object.assign(() => db, {
  FieldValue: { serverTimestamp: () => new Date(), delete: () => ({ __delete: true }), increment: (value) => value, arrayUnion: (...items) => items },
  Timestamp: { now: () => new FakeTimestamp(), fromDate: (date) => new FakeTimestamp(date), fromMillis: (value) => new FakeTimestamp(value) },
});

function geminiReply(parts) {
  geminiCalls.push(parts);
  const text = parts.map((part) => part.text || '').join('\n');
  if (parts.some((part) => part.inlineData)) return geminiScript.transcript;
  if (/second-pass checker/.test(text)) return JSON.stringify({ extracted: geminiScript.extracted, confidence: 0.9, address_uncertain: false, review_notes: '' });
  if (/"summary":"2-4 Russian sentences"/.test(text)) return JSON.stringify({ summary: geminiScript.summary, extracted: geminiScript.extracted });
  if (/Переведи/.test(text)) return geminiScript.transcriptRu || '';
  return 'OK';
}
class FakeGemini {
  getGenerativeModel() {
    return { generateContent: async (parts) => ({ response: { text: () => geminiReply(parts) } }) };
  }
}

const handler = (...args) => args.at(-1);
const fakeTwilio = Object.assign(() => ({
  calls: Object.assign(() => ({ fetch: async () => ({ status: 'completed' }) }), { list: async () => [] }),
  recordings: { list: async () => [] },
  messages: { create: async () => ({ sid: 'SM-synthetic', status: 'queued' }) },
}), realTwilio);
const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return { initializeApp: () => ({}), firestore, storage: () => ({ bucket: () => ({}) }) };
  if (name === 'firebase-functions') return { https: { onRequest: handler }, scheduler: { onSchedule: handler } };
  if (name === 'firebase-functions/v2/https') return { onRequest: handler };
  if (name === 'firebase-functions/v2/firestore') return { onDocumentWritten: handler };
  if (name === 'firebase-functions/v2/scheduler') return { onSchedule: handler };
  if (name === './auth_guard') return { requireTwilioSignature: () => true, requireAppUser: async () => ({ uid: 'owner' }), verifyAppUser: async () => ({ uid: 'owner' }) };
  if (name === './notify') return { notifyMaster: async (title, body, data) => notifications.push({ title, body, data }), registerDeviceToken: async () => {} };
  if (name === '@google/generative-ai') return { ...realGemini, GoogleGenerativeAI: FakeGemini };
  if (name === './recording_store') return {
    ...realRecordingStore,
    createRecordingStore: () => ({
      downloadRecordingBuffer: async (url) => { downloads.push(url); return Buffer.from('synthetic-mp3'); },
      cacheRecordingToStorage: async (callId) => `https://storage.test/${callId}.mp3`,
    }),
  };
  if (name === 'twilio') return fakeTwilio;
  return load.apply(this, arguments);
};
const savedEnv = { ...process.env };
Object.assign(process.env, {
  TWILIO_ACCOUNT_SID: `AC${'0'.repeat(32)}`, TWILIO_AUTH_TOKEN: 'synthetic-test-token', TWILIO_PHONE_NUMBER: '+14165550100',
  GEMINI_API_KEY: 'synthetic-gemini-key',
});
let api;
try {
  api = require('./index');
} finally {
  Module._load = load;
  for (const key of ['TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN', 'TWILIO_PHONE_NUMBER', 'GEMINI_API_KEY']) {
    if (savedEnv[key] === undefined) delete process.env[key]; else process.env[key] = savedEnv[key];
  }
}

function response() {
  return {
    statusCode: 200, body: null,
    status(code) { this.statusCode = code; return this; }, type() { return this; }, set() { return this; },
    send(body) { this.body = body; return this; }, json(body) { return this.send(body); },
  };
}
function request(body) {
  return { method: 'POST', body, headers: { host: 'functions.test' }, query: {}, protocol: 'https', get: () => 'functions.test' };
}
async function webhook(fn, body) {
  const res = response();
  await fn(request(body), res);
  assert.equal(res.statusCode, 200);
  return res.body;
}
const jobs = () => [...store.entries()].filter(([path]) => /\/jobs\/[^/]+$/.test(path)).map(([id, data]) => ({ id: id.split('/').pop(), ...data }));
const clients = () => [...store.entries()].filter(([path]) => /\/clients\/[^/]+$/.test(path)).map(([, data]) => data);
const call = (sid) => store.get(`${COMPANY}/calls/${sid}`);
const changeEvent = (sid, before) => ({ data: { before: { exists: true, data: () => revive(structuredClone(before)) }, after: snapshot(`${COMPANY}/calls/${sid}`) } });

async function recordingArrives(sid, digit) {
  const before = structuredClone(call(sid));
  const recordingSid = `RE${digit.repeat(32)}`;
  await webhook(api.recordingComplete, {
    CallSid: sid, RecordingSid: recordingSid, RecordingStatus: 'completed', RecordingDuration: '95', RecordingChannels: '2',
    RecordingUrl: `https://api.twilio.com/2010-04-01/Accounts/AC0/Recordings/${recordingSid}`,
  });
  assert.equal(call(sid).aiStatus, 'processing');
  return changeEvent(sid, before);
}

const washer = () => ({
  transcript: 'AI: Hi, FixApplianceCA, how can I help?\nClient: My washer does not drain, I am Amelia at 12 King Street in Brantford.\nAI: Our technician will contact you.\nClient: Wednesday afternoon works. Thank you, bye.',
  transcriptRu: 'ИИ: Здравствуйте, FixApplianceCA, чем помочь?\nКлиент: Стиральная машина не сливает, я Амелия, 12 King Street, Brantford.\nИИ: Мастер свяжется с вами.\nКлиент: Среда после обеда подходит. Спасибо, до свидания.',
  summary: 'Амелия из Брантфорда: стиральная машина не сливает воду, удобно в среду после обеда.',
  extracted: {
    client_name: 'Amelia', client_phone: '4165550101', address: '12 King Street', city: 'Brantford', postal_code: null,
    appliance_type: 'Стиральная машина', brand: null, model: null, problem_description: 'Не сливает воду',
    scheduled_date: null, scheduled_time: null, preferred_time: 'Wednesday afternoon', wants_callback: false,
    contact_on_site_name: null, contact_on_site_phone: null, has_job_site: false, notes: null, service_declined: false, decline_reason: null,
  },
});

beforeEach(() => {
  store = new Map([
    [`${COMPANY}/settings/config`, { aiAnswerEnabled: true, aiAnswerTimeoutSeconds: 15 }],
    [`${COMPANY}/settings/voice_infra`, { wss: 'wss://relay.test/stream' }],
  ]);
  notifications = [];
  transactionTail = Promise.resolve();
  geminiScript = washer();
  geminiCalls = [];
  downloads = [];
  generated = 0;
});

async function secretaryTakesCall(sid) {
  const ring = await webhook(api.incomingCall, { CallSid: sid, From: CALLER, To: '+14165550100' });
  assert.match(ring, /<Dial/);
  assert.equal(call(sid).status, 'ringing');
  const live = await webhook(api.dialAction, { CallSid: sid, DialCallStatus: 'no-answer' });
  assert.match(live, /<Stream[^>]*url="wss:\/\/relay\.test\/stream"/);
  assert.equal(call(sid).answeredBy, 'ai');
  assert.equal(call(sid).aiReception.engine, 'gemini-live');
  // Live-релей закончил разговор и положил разбор в запись звонка.
  apply(`${COMPANY}/calls/${sid}`, { aiReception: {
    ...call(sid).aiReception, done: true, extracted: geminiScript.extracted,
    history: [{ role: 'assistant', text: 'Hi, FixApplianceCA, how can I help?' }, { role: 'user', text: 'My washer does not drain, I am Amelia at 12 King Street in Brantford.' }],
  } });
  await webhook(api.aiRelayComplete, { CallSid: sid, CallStatus: 'completed' });
}

// Заявку со звонка сервер не заводит (решение FIX, 21.10.2026). Разбор
// записи при этом обязан доехать до конца: мастер открывает карточку
// звонка, читает расшифровку и жмёт «Создать заявку на ремонт» сам.
test('secretary call: the recording is analysed, but neither job nor client appears by itself', async () => {
  const sid = `CA${'1'.repeat(32)}`;
  await secretaryTakesCall(sid);
  assert.equal(call(sid).status, 'completed');
  assert.equal(call(sid).aiStatus, 'done');
  assert.equal(jobs().length, 0);
  assert.deepEqual(notifications.map((n) => n.data.kind), ['call_offer']);
  // Уведомление о звонке больше ничего не предлагает создать.
  assert.equal(notifications[0].title, 'Входящий звонок');

  const event = await recordingArrives(sid, '3');
  await api.processQueuedCallRecording(event);

  assert.equal(jobs().length, 0);
  assert.equal(clients().length, 0);
  const done = call(sid);
  assert.equal(done.aiStatus, 'done');
  assert.equal(done.createdJobId, undefined);
  assert.equal(done.aiProcessedRecordingSid, `RE${'3'.repeat(32)}`);
  assert.equal(done.recordingProcessingLease, null);
  assert.match(done.transcription, /Амелия/);
  assert.match(done.summary, /стиральная машина/i);
  // Форму ручного создания заполняет этот разбор — без него кнопка пустая.
  assert.equal(done.extractedData.client_name, 'Amelia');
  assert.equal(done.extractedData.appliance_type, 'Стиральная машина');
  assert.equal(done.extractedData.city, 'Brantford');
  assert.deepEqual(notifications.map((n) => n.data.kind), ['call_offer']);
  assert.equal(downloads.length, 1);
});

test('a replayed recording trigger and a concurrent second trigger still create nothing and download once', async () => {
  const sid = `CA${'2'.repeat(32)}`;
  await secretaryTakesCall(sid);
  const event = await recordingArrives(sid, '4');
  await Promise.all([api.processQueuedCallRecording(event), api.processQueuedCallRecording(event).catch(() => {})]);
  await api.processQueuedCallRecording(event);
  assert.equal(jobs().length, 0);
  assert.equal(clients().length, 0);
  assert.equal(notifications.filter((n) => n.data.kind === 'job').length, 0);
  assert.equal(downloads.length, 1);
});

test('a client with an open job calling again lands on that job, not on a clone', async () => {
  // Заявку завёл мастер руками — её и должен найти следующий звонок.
  apply(`${COMPANY}/clients/client-amelia`, {
    fullName: 'Amelia', phone: '4165550101', address: '12 King Street, Brantford',
  }, false);
  apply(`${COMPANY}/jobs/job-amelia`, {
    clientId: 'client-amelia', clientName: 'Amelia', clientPhone: '4165550101',
    applianceType: 'Стиральная машина', status: 'Вызов', needsReview: false,
    description: 'Не сливает воду', attachments: [], documents: [],
    createdAt: new Date(),
  }, false);

  const second = `CA${'6'.repeat(32)}`;
  await webhook(api.incomingCall, { CallSid: second, From: CALLER, To: '+14165550100' });
  await webhook(api.dialAction, { CallSid: second, DialCallStatus: 'completed', DialCallDuration: '70' });
  assert.equal(call(second).status, 'completed');
  geminiScript.transcript = 'Me: FixApplianceCA.\nClient: Hi, it is Amelia again about the washer, the model is WF45.\nMe: Noted, see you Wednesday.';
  geminiScript.extracted = { ...geminiScript.extracted, model: 'WF45' };
  await api.processQueuedCallRecording(await recordingArrives(second, '6'));

  assert.equal(jobs().length, 1);
  assert.equal(clients().length, 1);
  assert.equal(call(second).createdJobId, 'job-amelia');
  const updated = jobs()[0];
  assert.equal(updated.attachments.length, 1);
  assert.equal(updated.attachments[0].callId, second);
  assert.equal(updated.attachments[0].answeredBy, 'master');
});

test('a time spoken on the call reaches the call card, but books nothing by itself', async () => {
  const sid = `CA${'7'.repeat(32)}`;
  await webhook(api.incomingCall, { CallSid: sid, From: CALLER, To: '+14165550100' });
  await webhook(api.dialAction, { CallSid: sid, DialCallStatus: 'completed', DialCallDuration: '120' });
  geminiScript.transcript = 'Me: FixApplianceCA.\nClient: My washer does not drain, I am Amelia, 12 King Street, Brantford.\nMe: Tomorrow at two works, see you then.';
  geminiScript.extracted = { ...geminiScript.extracted, scheduled_date: '2099-01-07', scheduled_time: '14:00' };
  await api.processQueuedCallRecording(await recordingArrives(sid, '7'));
  assert.equal(jobs().length, 0);
  const done = call(sid);
  assert.equal(done.extractedData.scheduled_date, '2099-01-07');
  assert.equal(done.extractedData.scheduled_time, '14:00');
});

test('after the relay hangs up on a silent line the call ends instead of re-opening the stream', async () => {
  const sid = `CA${'a'.repeat(32)}`;
  await webhook(api.incomingCall, { CallSid: sid, From: CALLER, To: '+14165550100' });
  await webhook(api.dialAction, { CallSid: sid, DialCallStatus: 'no-answer' });
  apply(`${COMPANY}/calls/${sid}`, { aiReception: {
    ...call(sid).aiReception, done: true,
    history: [{ role: 'assistant', text: "Sorry, I'm having trouble hearing you — please call back or text this number." }],
  } });
  // Без метки оборванный поток на живом звонке поднимается заново.
  assert.match(await webhook(api.aiRelayComplete, { CallSid: sid, CallStatus: 'in-progress' }), /<Stream/);
  // Релей сказал «can't hear you» и через 30 с тишины закрыл поток сам.
  apply(`${COMPANY}/calls/${sid}`, { aiReception: { ...call(sid).aiReception, hangup: 'silence' } });
  const ended = await webhook(api.aiRelayComplete, { CallSid: sid, CallStatus: 'in-progress' });
  assert.doesNotMatch(ended, /<Stream|<Gather|<Say|<Dial/);
  assert.equal(call(sid).status, 'completed');
});

test('a declined or deleted call never becomes a job', async () => {
  const declined = `CA${'8'.repeat(32)}`;
  geminiScript.transcript = 'AI: Hi, FixApplianceCA.\nClient: Do you fix gas cooktops?\nAI: Sorry, we do not service gas cooktops.\nClient: Ok, bye.';
  geminiScript.extracted = { ...washer().extracted, client_name: null, address: null, city: null, appliance_type: 'Газовая варочная панель', problem_description: null, service_declined: true, decline_reason: 'gas cooktop' };
  await secretaryTakesCall(declined);
  assert.equal(call(declined).serviceDeclined, true);
  await api.processQueuedCallRecording(await recordingArrives(declined, '8'));
  assert.equal(jobs().length, 0);
  assert.deepEqual(notifications.map((n) => n.data.kind), ['missed']);

  const deleted = `CA${'9'.repeat(32)}`;
  geminiScript = washer();
  await secretaryTakesCall(deleted);
  const event = await recordingArrives(deleted, '9');
  apply(`${COMPANY}/calls/${deleted}`, { deletedAt: new Date() });
  await api.processQueuedCallRecording(event);
  assert.equal(jobs().length, 0);
  assert.equal(clients().length, 0);
  assert.equal(downloads.length, 1);
});

test('a shorter Russian translation is kept over a longer English live transcript with Russian speaker labels', async () => {
  const sid = `CA${'b'.repeat(32)}`;
  await webhook(api.incomingCall, { CallSid: sid, From: CALLER, To: '+14165550100' });
  await webhook(api.dialAction, { CallSid: sid, DialCallStatus: 'no-answer' });
  apply(`${COMPANY}/calls/${sid}`, {
    aiReception: {
      ...call(sid).aiReception,
      done: true,
      extracted: geminiScript.extracted,
      history: [
        { role: 'assistant', text: 'FixApplianceCA, this is Sarah. How can I help you today with your appliance?' },
        { role: 'user', text: 'My washing machine does not drain water at all, I am Amelia at 12 King Street in Brantford.' },
        { role: 'assistant', text: 'Got it, our technician will contact you within thirty minutes to confirm.' },
        { role: 'user', text: 'Wednesday afternoon works great for me. Thank you very much, goodbye.' },
      ],
    },
  });
  // Русский перевод короче английской live-истории с метками «ИИ:» / «Клиент:».
  geminiScript.transcriptRu =
    'ИИ: FixApplianceCA, Сара. Чем помочь?\n' +
    'Клиент: Стиралка не сливает, я Амелия, 12 King Street, Brantford.\n' +
    'ИИ: Мастер позвонит через 30 минут.\n' +
    'Клиент: Среда после обеда подходит. Пока.';
  await webhook(api.aiRelayComplete, { CallSid: sid, CallStatus: 'completed' });
  await api.processQueuedCallRecording(await recordingArrives(sid, 'b'));
  const done = call(sid);
  assert.match(done.transcriptionRu, /Стиралка не сливает/);
  assert.doesNotMatch(done.transcriptionRu, /How can I help you today/);
  assert.match(done.transcription, /Стиралка не сливает/);
});

