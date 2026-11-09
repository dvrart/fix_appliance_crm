const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const JOB = `${COMPANY}/jobs/audit-job`;
const SLOT = '2099-01-05T09:00';
const START = new Date('2099-01-05T14:00:00Z');
let store;
let writes;
let pushes;
let transactionTail;
let clock;
let transactionCount;
let transactionFailures;
let providerCalls;
let providerFailure;
let documentCount;
let beforeTransaction;

function snapshot(path) {
  const data = store.get(path);
  return {
    id: path.split('/').pop(),
    ref: ref(path),
    exists: data !== undefined,
    data: () => structuredClone(data),
  };
}

function apply(path, data, merge = true) {
  const previous = structuredClone(store.get(path));
  const next = { ...(merge ? previous : {}), ...structuredClone(data) };
  store.set(path, next);
  writes.push({ path, before: previous, after: structuredClone(next) });
}

function ref(path) {
  return {
    path,
    id: path.split('/').pop(),
    collection: (name) => ref(`${path}/${name}`),
    doc: (name) => ref(`${path}/${name}`),
    where() { return this; },
    limit() { return this; },
    get: async () => {
      if (store.has(path)) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot);
      return { ...snapshot(path), docs, empty: !docs.length, size: docs.length };
    },
    update: async (data) => apply(path, data),
    set: async (data, options) => apply(path, data, options?.merge === true),
    add: async (data) => {
      const document = ref(`${path}/generated-${++documentCount}`);
      apply(document.path, data, false);
      return document;
    },
  };
}

const firestore = Object.assign(() => ({
  collection: (name) => ref(name),
  runTransaction: (work) => {
    const invocation = ++transactionCount;
    const result = transactionTail.then(async () => {
      if (transactionFailures.has(invocation)) throw new Error('Simulated Firestore write failure');
      if (beforeTransaction) {
        const hook = beforeTransaction;
        beforeTransaction = null;
        hook();
      }
      const pending = [];
      const value = await work({
        get: async (document) => snapshot(document.path),
        update: (document, data) => pending.push(() => apply(document.path, data)),
        set: (document, data, options) => pending.push(() => apply(document.path, data, options?.merge === true)),
        create: (document, data) => pending.push(() => {
          assert.equal(store.has(document.path), false);
          apply(document.path, data, false);
        }),
      });
      pending.forEach((commit) => commit());
      return value;
    });
    transactionTail = result.catch(() => {});
    return result;
  },
}), {
  Timestamp: { now: () => new Date(clock++), fromDate: (value) => value },
  FieldValue: { serverTimestamp: () => new Date(clock++), delete: () => null },
});

const load = Module._load;
Module._load = function (name, parent, isMain) {
  if (name === 'firebase-admin/firestore') return {
    getFirestore: firestore, FieldValue: firestore.FieldValue, Timestamp: firestore.Timestamp,
  };
  if (name === 'twilio') return () => ({
    messages: {
      create: async () => {
        providerCalls++;
        if (providerFailure) throw new Error('Simulated Twilio send failure');
        return { sid: `SM-fake-${providerCalls}`, status: 'queued' };
      },
    },
  });
  if (name === 'firebase-functions/v2/firestore') return { onDocumentWritten: (_, handler) => handler };
  if (name === 'firebase-functions/v2/scheduler') return { onSchedule: (_, handler) => handler };
  if (name === './notify') return { notifyMaster: async (...args) => pushes.push(args) };
  return load.apply(this, arguments);
};
const visitSms = require('./visit_sms');
Module._load = load;

function job(visitPatch = {}) {
  return {
    status: 'Вызов',
    needsReview: false,
    clientName: 'Audit Example',
    clientPhone: '+14165550101',
    visits: [{
      id: 'audit-visit',
      startAt: START,
      durationMinutes: 120,
      outcome: 'scheduled',
      ...visitPatch,
    }],
  };
}

function event(before, after) {
  return {
    params: { jobId: 'audit-job' },
    data: {
      before: { exists: !!before, data: () => structuredClone(before) },
      after: { exists: !!after, data: () => structuredClone(after) },
    },
  };
}

async function trigger(before, after) {
  store.set(JOB, structuredClone(after));
  await visitSms.onJobWritten(event(before, after));
  return structuredClone(store.get(JOB));
}

beforeEach(() => {
  store = new Map([
    [`${COMPANY}/settings/config`, { bookingSmsEnabled: true }],
    [`${COMPANY}/settings/sms_templates`, {}],
  ]);
  writes = [];
  pushes = [];
  transactionTail = Promise.resolve();
  transactionCount = 0;
  transactionFailures = new Set();
  providerCalls = 0;
  providerFailure = false;
  documentCount = 0;
  beforeTransaction = null;
  process.env.TWILIO_ACCOUNT_SID = 'test-account';
  process.env.TWILIO_API_KEY_SID = 'test-key';
  process.env.TWILIO_API_KEY_SECRET = 'test-only';
  process.env.TWILIO_AUTH_TOKEN = 'test-only';
  process.env.TWILIO_PHONE_NUMBER = '+14165550102';
  clock = Date.parse('2098-12-30T14:00:00Z');
});

test('a new visit no longer queues a confirmation by itself', async () => {
  const initial = job();
  const queued = await trigger(null, initial);
  const again = await trigger(initial, queued);
  await trigger(queued, again);
  assert.equal(writes.filter((write) => write.path === JOB).length, 0);
  assert.equal(pushes.length, 0);
  assert.equal(store.get(JOB).visits[0].smsBooking, undefined);
});

test('replayed and concurrent stale trigger events do not queue a confirmation', async () => {
  const initial = job();
  store.set(JOB, structuredClone(initial));
  await Promise.all([
    visitSms.onJobWritten(event(null, initial)),
    visitSms.onJobWritten(event(null, initial)),
  ]);
  await visitSms.onJobWritten(event(null, initial));
  assert.equal(pushes.length, 0);
  assert.equal(writes.filter((write) => write.path === JOB).length, 0);
});

test('owner rejection survives unrelated changes and trigger retries', async () => {
  const rejected = job({
    smsBookingPending: false,
    smsBookingSlotKey: SLOT,
    smsBooking: { state: 'rejected', slotKey: SLOT },
  });
  const after = await trigger(rejected, { ...rejected, description: 'Updated notes' });
  await trigger(rejected, after);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'rejected');
  assert.equal(store.get(JOB).visits[0].smsBookingPending, false);
  assert.equal(pushes.length, 0);
});

test('a same-day move no longer queues a confirmation by itself', async () => {
  const before = job({ smsBooking: { state: 'rejected', slotKey: SLOT }, smsBookingSlotKey: SLOT });
  const moved = structuredClone(before);
  moved.visits[0].startAt = new Date('2099-01-05T15:00:00Z');
  const after = await trigger(before, moved);
  await trigger(moved, after);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'rejected');
  assert.equal(pushes.length, 0);
});

test('legacy space slot key does not reset an unchanged confirmed visit', async () => {
  const sent = job({
    smsConfirmStatus: 'confirmed',
    smsBookingSlotKey: '2099-01-05 09:00',
    smsBookingDayKey: '2099-01-05',
    smsBookingSentAt: new Date('2098-12-30T14:00:00Z'),
    smsBookingSentSms: true,
    smsBookingVia: 'sms',
  });
  const after = await trigger(sent, sent);
  assert.equal(after.visits[0].smsConfirmStatus, 'confirmed');
  assert.notEqual(after.visits[0].smsBookingPending, true);
  assert.equal(pushes.length, 0);
});

test('a legacy pending flag is left alone and does not notify again', async () => {
  const pendingAt = new Date('2098-12-30T13:00:00Z');
  const pending = job({
    smsBookingPending: true,
    smsBookingPendingAt: pendingAt,
    smsBookingSlotKey: '2099-01-05 09:00',
    smsBookingDayKey: '2099-01-05',
  });
  const after = await trigger(pending, pending);
  await trigger(pending, after);
  assert.equal(pushes.length, 0);
  assert.equal(store.get(JOB).visits[0].smsBooking, undefined);
  assert.deepEqual(store.get(JOB).visits[0].smsBookingPendingAt, pendingAt);
});

test('an old sent timestamp cannot complete SMS for the new slot', async () => {
  const before = job({
    smsBookingSlotKey: SLOT,
    smsBookingDayKey: '2099-01-05',
    smsBookingSentAt: new Date('2098-12-30T13:00:00Z'),
    smsBookingSentSms: true,
    smsBookingVia: 'sms',
    smsConfirmStatus: 'confirmed',
  });
  const moved = structuredClone(before);
  moved.visits[0].startAt = new Date('2099-01-06T14:00:00Z');
  const after = await trigger(before, moved);
  const again = await trigger(moved, after);
  // Старая отметка об отправке больше не подменяется новой очередью:
  // подтверждение визита само не создаётся.
  assert.equal(again.visits[0].smsBooking, undefined);
  assert.notEqual(again.visits[0].smsBookingPending, true);
  assert.equal(pushes.length, 0);
});

for (const state of ['approved', 'sending', 'sent', 'error']) {
  test(`${state} booking SMS is not requeued by job changes`, async () => {
    const existing = job({
      smsBooking: { state, slotKey: SLOT, requestId: 'existing-request-1234' },
      smsBookingSlotKey: SLOT,
      smsBookingPending: false,
    });
    const after = await trigger(existing, existing);
    assert.equal(after.visits[0].smsBooking.state, state);
    assert.equal(after.visits[0].smsBookingPending, false);
    assert.equal(pushes.length, 0);
  });
}

test('review-required and closed jobs never queue booking SMS', async () => {
  for (const patch of [{ needsReview: true }, { status: 'Завершено' }, { deletedAt: START }]) {
    const existing = { ...job(), ...patch };
    await trigger(existing, existing);
  }
  assert.equal(pushes.length, 0);
  assert.equal(writes.filter((write) => write.path === JOB).length, 0);
});

function sendInput(patch = {}) {
  return {
    jobId: 'audit-job', visitId: 'audit-visit', slotKey: SLOT,
    requestId: 'audit-request-0001', to: '+14165550101',
    messageData: { from: '+14165550102', body: 'Please confirm your visit' },
    send: async () => ({ sid: 'SM-audit-1', status: 'queued' }),
    ...patch,
  };
}

test('approval, sending and sent are persisted without changing client confirmation', async () => {
  store.set(JOB, job({ smsConfirmStatus: 'confirmed' }));
  const result = await visitSms.sendApprovedBookingSms(sendInput());
  assert.equal(result.success, true);
  assert.equal(result.sid, 'SM-audit-1');
  assert.deepEqual(writes.filter((write) => write.path === JOB).map((write) => write.after.visits[0].smsBooking.state), ['approved', 'sending', 'sent']);
  assert.equal(store.get(JOB).visits[0].smsConfirmStatus, 'confirmed');
  assert.equal(store.get(JOB).visits[0].smsBookingSlotKey, SLOT);
});

test('concurrent and replayed requests send a single SMS', async () => {
  store.set(JOB, job());
  let sent = 0;
  const input = sendInput({ send: async () => { sent++; return { sid: 'SM-audit-1', status: 'queued' }; } });
  await Promise.all([
    visitSms.sendApprovedBookingSms(input),
    visitSms.sendApprovedBookingSms(input),
  ]);
  const result = await visitSms.sendApprovedBookingSms(input);
  assert.equal(sent, 1);
  assert.equal(result.success, true);
  assert.equal([...store.keys()].filter((key) => key.includes('/messages/')).length, 1);
});

test('a second request cannot send while the first one is in flight', async () => {
  store.set(JOB, job());
  let started;
  let finish;
  const start = new Promise((resolve) => { started = resolve; });
  const waiting = new Promise((resolve) => { finish = resolve; });
  const first = visitSms.sendApprovedBookingSms(sendInput({ send: () => { started(); return waiting; } }));
  await start;
  await assert.rejects(visitSms.sendApprovedBookingSms(sendInput({ requestId: 'audit-request-0002' })), /Предыдущая отправка/);
  finish({ sid: 'SM-audit-1', status: 'queued' });
  assert.equal((await first).success, true);
});

test('ambiguous provider errors cannot be automatically retried', async () => {
  store.set(JOB, job());
  let sent = 0;
  const input = sendInput({ send: async () => { sent++; throw new Error('connection reset'); } });
  const result = await visitSms.sendApprovedBookingSms(input);
  assert.equal(result.state, 'error');
  assert.equal(store.get(JOB).visits[0].smsBooking.retryAllowed, false);
  await visitSms.sendApprovedBookingSms(input);
  await assert.rejects(visitSms.sendApprovedBookingSms(sendInput({ requestId: 'audit-request-0002' })), /Предыдущая отправка/);
  assert.equal(sent, 1);
  await visitSms.recordBookingDelivery(input.requestId, { sid: 'SM-audit-1', status: 'delivered' });
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'sent');
});

test('definite provider rejection allows a new explicitly approved attempt only', async () => {
  store.set(JOB, job());
  let sent = 0;
  const input = sendInput({ send: async () => { sent++; throw Object.assign(new Error('rejected'), { status: 400, code: 21211 }); } });
  const result = await visitSms.sendApprovedBookingSms(input);
  assert.equal(result.state, 'error');
  assert.equal(store.get(JOB).visits[0].smsBooking.retryAllowed, true);
  const current = structuredClone(store.get(JOB));
  await trigger(current, current);
  await visitSms.sendApprovedBookingSms(input);
  assert.equal(sent, 1);
  assert.equal(pushes.length, 0);
  assert.equal((await visitSms.sendApprovedBookingSms(sendInput({ requestId: 'audit-request-0002' }))).success, true);
});

test('delivery failure updates the visit but does not remove client confirmation', async () => {
  store.set(JOB, job({ smsConfirmStatus: 'confirmed' }));
  await visitSms.sendApprovedBookingSms(sendInput());
  await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status: 'undelivered', errorCode: '30003' });
  const current = structuredClone(store.get(JOB));
  await trigger(current, current);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'error');
  assert.equal(store.get(JOB).visits[0].smsConfirmStatus, 'confirmed');
  assert.equal(pushes.length, 0);
});

test('out-of-order delivery callbacks cannot downgrade a delivered SMS', async () => {
  store.set(JOB, job());
  await visitSms.sendApprovedBookingSms(sendInput());
  await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status: 'delivered' });
  for (const status of ['queued', 'sending', 'sent', 'failed', 'undelivered', 'canceled']) {
    await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status });
  }
  assert.equal(store.get(`${COMPANY}/messages/booking_audit-request-0001`).status, 'delivered');
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'sent');
  assert.equal(store.get(JOB).visits[0].smsBooking.retryAllowed, false);
});

test('duplicate delivery callbacks perform no extra writes', async () => {
  store.set(JOB, job());
  await visitSms.sendApprovedBookingSms(sendInput());
  await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status: 'delivered' });
  const count = writes.length;
  await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status: 'delivered' });
  assert.equal(writes.length, count);
});

test('a visit confirmation already awaiting a decision is left alone', async () => {
  const pending = job({ smsBooking: { state: 'pending', slotKey: SLOT }, smsBookingPending: true });
  await trigger(pending, pending);
  assert.equal(providerCalls, 0);
  assert.equal(writes.length, 0);
});

test('a reschedule does not text the client or queue a confirmation by itself', async () => {
  const before = job({
    smsBookingSlotKey: SLOT, smsBookingSentAt: new Date('2026-01-01T00:00:00Z'),
    smsBookingSentSms: true, smsBookingVia: 'sms', smsConfirmStatus: 'pending',
  });
  const moved = structuredClone(before);
  moved.visits[0].startAt = new Date('2099-01-06T14:00:00Z');
  const result = await trigger(before, moved);
  assert.equal(providerCalls, 0);
  assert.equal(result.visits[0].smsBooking, undefined);
  assert.notEqual(result.visits[0].smsBookingPending, true);
  assert.equal(pushes.length, 0);
  await trigger(moved, result);
  assert.equal(providerCalls, 0);
  assert.equal(pushes.length, 0);
});

test('manual visit confirmation on the job card does not queue a duplicate SMS', async () => {
  const before = job({ smsConfirmStatus: 'pending' });
  const after = structuredClone(before);
  after.visits[0].smsConfirmStatus = 'confirmed';
  await trigger(before, after);
  assert.equal(providerCalls, 0);
  const queued = [...store.entries()]
    .filter(([path]) => path.startsWith(`${COMPANY}/messages/`))
    .map(([, data]) => data);
  assert.equal(queued.length, 0);
  assert.equal(pushes.length, 0);
});

test('a transaction failure after provider acceptance does not resend', async () => {
  store.set(JOB, job());
  transactionFailures = new Set([3, 4]);
  let sent = 0;
  const input = sendInput({ send: async () => { sent++; return { sid: 'SM-audit-1', status: 'queued' }; } });
  const result = await visitSms.sendApprovedBookingSms(input);
  assert.equal(result.success, true);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'sent');
  assert.equal(store.get(`${COMPANY}/messages/booking_audit-request-0001`).bookingState, 'sent');
  await visitSms.sendApprovedBookingSms(input);
  assert.equal(sent, 1);
});

test('reconciliation does not queue other visits or send notifications', async () => {
  const existing = job();
  existing.visits.push({ id: 'other-visit', startAt: new Date('2099-01-06T14:00:00Z'), outcome: 'scheduled' });
  store.set(JOB, existing);
  transactionFailures = new Set([3, 4]);
  await visitSms.sendApprovedBookingSms(sendInput());
  assert.equal(store.get(JOB).visits[1].smsBooking, undefined);
  assert.equal(pushes.length, 0);
});

test('a late callback for the old slot cannot overwrite a new slot decision', async () => {
  store.set(JOB, job());
  await visitSms.sendApprovedBookingSms(sendInput());
  const moved = job({
    startAt: new Date('2099-01-06T14:00:00Z'),
    smsBooking: { state: 'rejected', slotKey: '2099-01-06T09:00' },
  });
  store.set(JOB, moved);
  await visitSms.recordBookingDelivery('audit-request-0001', { sid: 'SM-audit-1', status: 'delivered' });
  assert.deepEqual(store.get(JOB), moved);
});

test('changed slots and recipients are rejected before sending', async () => {
  store.set(JOB, job());
  let sent = 0;
  const send = async () => { sent++; };
  await assert.rejects(visitSms.sendApprovedBookingSms(sendInput({ send, slotKey: '2099-01-05T10:00' })), /Время визита изменилось/);
  await assert.rejects(visitSms.sendApprovedBookingSms(sendInput({ send, to: '+14165550199' })), /Телефон клиента изменился/);
  assert.equal(sent, 0);
  assert.equal(writes.length, 0);
});

test('a replayed request cannot be reused for different message text', async () => {
  store.set(JOB, job());
  await visitSms.sendApprovedBookingSms(sendInput());
  await assert.rejects(visitSms.sendApprovedBookingSms(sendInput({ messageData: { body: 'Different text' } })), /другому сообщению/);
});

test('client confirmation arriving during sending is preserved', async () => {
  store.set(JOB, job({ smsConfirmStatus: 'pending' }));
  await visitSms.sendApprovedBookingSms(sendInput({ send: async () => {
    const current = store.get(JOB);
    current.visits[0].smsConfirmStatus = 'confirmed';
    current.description = 'New client information';
    return { sid: 'SM-audit-1', status: 'queued' };
  } }));
  assert.equal(store.get(JOB).visits[0].smsConfirmStatus, 'confirmed');
  assert.equal(store.get(JOB).description, 'New client information');
});

test('a moved visit is not requeued or texted by itself', async () => {
  const before = job({ smsBooking: { state: 'rejected', slotKey: SLOT } });
  const after = structuredClone(before);
  Object.assign(after.visits[0], {
    startAt: new Date('2099-01-06T14:00:00Z'), smsConfirmStatus: 'confirmed',
    smsBookingSlotKey: '2099-01-06T09:00', smsBookingDayKey: '2099-01-06',
    smsBookingSentAt: new Date(),
  });
  const result = await trigger(before, after);
  assert.equal(result.visits[0].smsBooking.state, 'rejected');
  assert.equal(result.visits[0].smsConfirmStatus, 'confirmed');
  assert.equal(pushes.length, 0);
  assert.equal(providerCalls, 0);
});

test('a bare "1" no longer confirms the visit or texts the client back', async () => {
  store.set(JOB, job());
  const handled = await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '1' });
  assert.equal(handled, false);
  assert.equal(store.get(JOB).visits[0].smsConfirmStatus, undefined);
  assert.equal(providerCalls, 0);
  assert.equal(pushes.length, 0);
  const messages = [...store.entries()]
    .filter(([path]) => path.startsWith(`${COMPANY}/messages/`))
    .map(([, data]) => data);
  assert.equal(messages.length, 0);

  const again = await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: 'yes' });
  assert.equal(again, false);
  assert.equal(providerCalls, 0);
});

test('a cancellation still wakes the owner', async () => {
  store.set(JOB, { ...job({ smsDialog: 'save_offer' }), scheduledAt: START });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '0' });
  assert.equal(store.get(JOB).visits[0].outcome, 'cancelled');
  assert.ok(pushes.length > 0, 'об отмене мастер узнаёт сразу');
});

test('SMS cancellation clears both schedule fields and uses the same visit state as phone cancellation', async () => {
  store.set(JOB, { ...job({ smsDialog: 'save_offer' }), scheduledAt: START, scheduledDate: START });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '0' });
  const saved = store.get(JOB);
  assert.equal(saved.visits[0].outcome, 'cancelled');
  assert.equal(saved.status, 'Отменено');
  assert.equal(saved.scheduledAt, null);
  assert.equal(saved.scheduledDate, null);
});

test('SMS cancellation preserves another scheduled visit on the same job', async () => {
  const initial = job({ smsDialog: 'save_offer' });
  const later = new Date('2099-01-07T14:00:00Z');
  initial.visits.push({ id: 'second-visit', startAt: later, outcome: 'scheduled' });
  store.set(JOB, initial);
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '0' });
  const saved = store.get(JOB);
  assert.equal(saved.status, 'Вызов');
  assert.equal(saved.visits[1].outcome, 'scheduled');
  assert.deepEqual(saved.scheduledAt, later);
  assert.deepEqual(saved.scheduledDate, later);
});

test('SMS cancellation does not overwrite a concurrent app move', async () => {
  store.set(JOB, job({ smsDialog: 'save_offer' }));
  const moved = new Date('2099-01-08T14:00:00Z');
  beforeTransaction = () => { store.get(JOB).visits[0].startAt = moved; };
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '0' });
  assert.equal(store.get(JOB).visits[0].outcome, 'scheduled');
  assert.deepEqual(store.get(JOB).visits[0].startAt, moved);
  // Ответ «визит изменился» клиенту сам не уходит — ждёт мастера.
  assert.equal(providerCalls, 0);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0][2].type, 'outbox');
});

test('the cancel digit the template advertises cancels instead of moving the visit', async () => {
  // Боевой шаблон просит «❌ CANCEL - 2️⃣», а разбор знал только «0». Ответ «2»
  // уходил в поиск времени (inferTimeFromText('2') = 14:00) и переносил визит
  // на два часа дня вместо отмены (найдено проверкой 12.10.2026).
  store.set(`${COMPANY}/settings/sms_templates`, {
    booking_confirm: 'Your visit {date} {time}\n✅ CONFIRM - 1️⃣\n❌ CANCEL - 2️⃣\n🔁 ANOTHER DAY - 5️⃣',
  });
  store.set(JOB, { ...job(), scheduledAt: START, scheduledDate: START });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '2' });
  const saved = store.get(JOB);
  // Визит не уехал на другое время, а встал в разговор об отмене.
  assert.deepEqual(saved.visits[0].startAt, START);
  assert.equal(saved.visits[0].smsDialog, 'save_offer');
  assert.equal(pushes.some(([title]) => title === 'Клиент просит отмену'), true);
});

test('without a cancel digit in the template a bare 2 is still not a cancel', async () => {
  store.set(`${COMPANY}/settings/sms_templates`, {
    booking_confirm: 'Your visit {date} {time}\nReply 1 to confirm, 0 to cancel, 5 for another day',
  });
  store.set(JOB, { ...job(), scheduledAt: START, scheduledDate: START });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '2' });
  assert.equal(store.get(JOB).visits[0].smsDialog, undefined);
});

test('a visit reminder never asks the client to confirm', async () => {
  // Подтверждение визита убрано совсем. Шаблон напоминания правит сам FIX,
  // поэтому просьбу снимаем на отправке.
  store.set(`${COMPANY}/settings/config`, { reminderSmsEnabled: true });
  store.set(`${COMPANY}/settings/sms_templates`, {
    day_before:
      'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}\n\nReply:\n✅ CONFIRM - 1️⃣\n❌ CANCEL - 2️⃣\n🔁 ANOTHER DAY - 5️⃣',
  });
  store.set(JOB, {
    status: 'Вызов',
    needsReview: false,
    clientName: 'Reminder Client',
    clientPhone: '+14165550101',
    clientAddress: '7 Trinity Lane, Waterford',
    visits: [{
      id: 'reminder-visit',
      startAt: new Date(Date.now() + 24 * 3600 * 1000),
      durationMinutes: 120,
      outcome: 'scheduled',
    }],
  });
  await visitSms.sendDayBeforeReminders();
  const queued = [...store.values()].filter((item) => item && item.kind === 'day_before');
  assert.equal(queued.length, 1);
  const body = queued[0].body;
  assert.match(body, /Trinity Lane/);
  assert.doesNotMatch(body, /reply/i);
  assert.doesNotMatch(body, /confirm/i);
  assert.doesNotMatch(body, /cancel/i);
  assert.doesNotMatch(body, /another day/i);
});

test('stripConfirmAsk keeps the visit facts and drops only the reply menu', () => {
  const cleaned = visitSms.stripConfirmAsk(
    'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}\n\nReply 1 ✅ to confirm, 0 ❌ to cancel, 5 🔁 another day.'
  );
  assert.equal(cleaned, 'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}');
});

test('stripConfirmAsk drops the lead-in of the reply menu too', () => {
  // Боевой шаблон FIX (проверка 18.10.2026): меню снималось, а строка «Please
  // let us know:» оставалась висеть в конце — клиент читал её как просьбу.
  const cleaned = visitSms.stripConfirmAsk(
    '🔔 Reminder for tomorrow!\n📅 Date - {date}\n🕘 Time - {time}\n📍 Address - {address}\n\nPlease let us know:\n✅ CONFIRM - 1️⃣\n❌ CANCEL - 2️⃣\n🔁 ANOTHER DAY - 5️⃣'
  );
  assert.equal(
    cleaned,
    '🔔 Reminder for tomorrow!\n📅 Date - {date}\n🕘 Time - {time}\n📍 Address - {address}'
  );
  assert.equal(
    visitSms.stripConfirmAsk('Визит {date} в {time}\nДайте знать, пожалуйста:\n1 — подтверждаю\n0 — отмена'),
    'Визит {date} в {time}'
  );
});

test('a same-day reminder says today, not tomorrow', () => {
  // Утреннее напоминание и «за 2 часа» идут тем же шаблоном, что и за сутки,
  // а в нём «Reminder for tomorrow!» — утром в день визита это вводит в
  // заблуждение (в бою 16.10.2026 так и ушло).
  const text = '🔔 Reminder for tomorrow!\n📅 Date - {date}';
  assert.equal(visitSms.sameDayWording(text), '🔔 Reminder for today!\n📅 Date - {date}');
  assert.equal(visitSms.sameDayWording('Напоминаем: завтра визит'), 'Напоминаем: сегодня визит');
  assert.equal(visitSms.sameDayWording('Reminder: your visit'), 'Reminder: your visit');
});

test('a stale SMS dialog cannot reopen a cancelled job', async () => {
  store.set(JOB, { ...job({ smsDialog: 'save_offer' }), status: 'Canceled' });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '2' });
  assert.equal(store.get(JOB).status, 'Canceled');
  assert.equal(writes.filter((write) => write.path === JOB).length, 0);
});

test('SMS reschedule updates scheduledAt and scheduledDate together', async () => {
  store.set(JOB, { ...job({ smsDialog: 'ask_slot' }), scheduledAt: START, scheduledDate: START });
  await visitSms.tryHandleConfirmReply({ from: '+14165550101', body: '2099-01-06 at 10:00' });
  const saved = store.get(JOB);
  assert.notDeepEqual(saved.scheduledAt, START);
  assert.deepEqual(saved.scheduledAt, saved.visits[0].startAt);
  assert.deepEqual(saved.scheduledDate, saved.scheduledAt);
});

test('a documents overwrite from the app cannot erase a Stripe payment, and the repair does not loop', async () => {
  const stripePaid = { amount: 226, method: 'Stripe', date: '2098-12-30T13:00:00.000Z', stripePaymentIntentId: 'pi_kept' };
  const before = { ...job(), status: 'Готово', documents: [
    { type: 'Invoice', number: 'INV-1', items: [{ name: 'Repair', qty: 1, price: 200 }], taxRate: 0.13, payments: [stripePaid], stripe: { status: 'paid' } },
  ] };
  const overwrite = { ...before, documents: [
    { ...before.documents[0], items: [{ name: 'Repair', qty: 1, price: 210 }], payments: [{ amount: 20, method: 'Наличные', date: '2098-12-30T13:30:00.000Z' }], stripe: {} },
  ] };
  const repaired = await trigger(before, overwrite);
  assert.deepEqual(repaired.documents[0].payments, [overwrite.documents[0].payments[0], stripePaid]);
  assert.equal(repaired.documents[0].items[0].price, 210);
  assert.equal(repaired.documents[0].stripe.status, 'paid');
  const jobWrites = writes.filter((write) => write.path === JOB).length;
  const again = await trigger(overwrite, repaired);
  assert.deepEqual(again.documents, repaired.documents);
  assert.equal(writes.filter((write) => write.path === JOB).length, jobWrites);
});

test('removing a whole trashed invoice or a cash payment is left alone', async () => {
  const before = { ...job(), documents: [
    { type: 'Invoice', number: 'INV-1', items: [], payments: [{ amount: 50, method: 'Наличные', date: '2098-12-30T13:00:00.000Z' }] },
    { type: 'Invoice', number: 'INV-2', items: [], deletedAt: '2098-12-01', payments: [{ amount: 10, method: 'Stripe', stripeSessionId: 'cs_gone' }] },
  ] };
  const after = { ...before, documents: [{ ...before.documents[0], payments: [] }] };
  const result = await trigger(before, after);
  assert.deepEqual(result.documents, after.documents);
});

function visitSoonJob(minutesAhead, extra = {}) {
  return {
    status: 'Вызов',
    needsReview: false,
    clientName: 'Soon Client',
    clientPhone: '+14165550101',
    applianceType: 'Washer',
    visits: [{
      id: 'soon-visit',
      startAt: new Date(Date.now() + minutesAhead * 60000),
      durationMinutes: 120,
      outcome: 'scheduled',
      ...extra,
    }],
  };
}

test('the owner is pushed about a visit within 1.5 hours, exactly once', async () => {
  store.set(JOB, visitSoonJob(60));
  await visitSms.sendOwnerVisitSoon({ morningBriefingEnabled: true });
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0][0], 'Через 1.5 часа заявка');
  assert.equal(pushes[0][2].type, 'visit_soon');
  assert.equal(pushes[0][2].jobId, 'audit-job');
  assert.equal(pushes[0][2].visitId, 'soon-visit');
  assert.ok(store.get(JOB).visits[0].ownerSoonAt);
  // Второй прогон крона не шлёт повторно — метка ownerSoonAt держит идемпотентность.
  await visitSms.sendOwnerVisitSoon({ morningBriefingEnabled: true });
  assert.equal(pushes.length, 1);
});

test('a visit further than 1.5 hours away is not pushed yet', async () => {
  store.set(JOB, visitSoonJob(180));
  await visitSms.sendOwnerVisitSoon({ morningBriefingEnabled: true });
  assert.equal(pushes.length, 0);
  assert.equal(store.get(JOB).visits[0].ownerSoonAt, undefined);
});

test('a visit already in the past is not pushed', async () => {
  store.set(JOB, visitSoonJob(-30));
  await visitSms.sendOwnerVisitSoon({ morningBriefingEnabled: true });
  assert.equal(pushes.length, 0);
});

test('owner visit-soon pushes respect the briefing toggle', async () => {
  store.set(JOB, visitSoonJob(60));
  await visitSms.sendOwnerVisitSoon({ morningBriefingEnabled: false });
  assert.equal(pushes.length, 0);
});
