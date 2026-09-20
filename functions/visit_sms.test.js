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
  if (name === 'firebase-admin') return { firestore };
  if (name === 'twilio') return () => ({
    messages: { create: async () => ({ sid: `SM-fake-${++providerCalls}`, status: 'queued' }) },
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
    [`${COMPANY}/settings/config`, { manualSmsApproval: true, bookingSmsEnabled: true }],
    [`${COMPANY}/settings/sms_templates`, {}],
  ]);
  writes = [];
  pushes = [];
  transactionTail = Promise.resolve();
  transactionCount = 0;
  transactionFailures = new Set();
  providerCalls = 0;
  documentCount = 0;
  beforeTransaction = null;
  process.env.TWILIO_ACCOUNT_SID = 'test-account';
  process.env.TWILIO_API_KEY_SID = 'test-key';
  process.env.TWILIO_API_KEY_SECRET = 'test-only';
  process.env.TWILIO_AUTH_TOKEN = 'test-only';
  process.env.TWILIO_PHONE_NUMBER = '+14165550102';
  clock = Date.parse('2098-12-30T14:00:00Z');
});

test('pending SMS settles after one write and one notification', async () => {
  const initial = job();
  const queued = await trigger(null, initial);
  const again = await trigger(initial, queued);
  await trigger(queued, again);
  assert.equal(writes.filter((write) => write.path === JOB).length, 1);
  assert.equal(pushes.length, 1);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'pending');
  assert.deepEqual(again.visits[0].smsBookingPendingAt, queued.visits[0].smsBookingPendingAt);
});

test('replayed and concurrent stale trigger events do not queue twice', async () => {
  const initial = job();
  store.set(JOB, structuredClone(initial));
  await Promise.all([
    visitSms.onJobWritten(event(null, initial)),
    visitSms.onJobWritten(event(null, initial)),
  ]);
  await visitSms.onJobWritten(event(null, initial));
  assert.equal(pushes.length, 1);
  assert.equal(writes.filter((write) => write.path === JOB).length, 1);
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

test('a real same-day move creates a new decision after rejection', async () => {
  const before = job({ smsBooking: { state: 'rejected', slotKey: SLOT }, smsBookingSlotKey: SLOT });
  const moved = structuredClone(before);
  moved.visits[0].startAt = new Date('2099-01-05T15:00:00Z');
  const after = await trigger(before, moved);
  await trigger(moved, after);
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'pending');
  assert.equal(store.get(JOB).visits[0].smsBooking.slotKey, '2099-01-05T10:00');
  assert.equal(pushes.length, 1);
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

test('legacy pending flag is migrated without notifying again', async () => {
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
  assert.equal(store.get(JOB).visits[0].smsBooking.state, 'pending');
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
  assert.equal(again.visits[0].smsBooking.state, 'pending');
  assert.equal(again.visits[0].smsBookingPending, true);
  assert.equal(again.visits[0].smsConfirmStatus, 'pending');
  assert.equal(pushes.length, 1);
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

test('changing to automatic mode does not approve an existing manual decision', async () => {
  store.set(`${COMPANY}/settings/config`, { manualSmsApproval: false });
  const pending = job({ smsBooking: { state: 'pending', slotKey: SLOT }, smsBookingPending: true });
  await trigger(pending, pending);
  assert.equal(providerCalls, 0);
  assert.equal(writes.length, 0);
});

test('automatic reschedule records the new send time and settles', async () => {
  store.set(`${COMPANY}/settings/config`, { manualSmsApproval: false });
  const before = job({
    smsBookingSlotKey: SLOT, smsBookingSentAt: new Date('2026-01-01T00:00:00Z'),
    smsBookingSentSms: true, smsBookingVia: 'sms', smsConfirmStatus: 'pending',
  });
  const moved = structuredClone(before);
  moved.visits[0].startAt = new Date('2099-01-06T14:00:00Z');
  const result = await trigger(before, moved);
  assert.equal(providerCalls, 1);
  assert.ok(result.visits[0].smsBookingSentAt.getTime() > before.visits[0].smsBookingSentAt.getTime());
  await trigger(moved, result);
  assert.equal(providerCalls, 1);
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

test('legacy SMS rescheduling acknowledgement is not replaced with pending', async () => {
  const before = job({ smsBooking: { state: 'rejected', slotKey: SLOT } });
  const after = structuredClone(before);
  Object.assign(after.visits[0], {
    startAt: new Date('2099-01-06T14:00:00Z'), smsConfirmStatus: 'confirmed',
    smsBookingSlotKey: '2099-01-06T09:00', smsBookingDayKey: '2099-01-06',
    smsBookingSentAt: new Date(),
  });
  const result = await trigger(before, after);
  assert.equal(result.visits[0].smsBooking.state, 'sent');
  assert.equal(result.visits[0].smsConfirmStatus, 'confirmed');
  assert.equal(pushes.length, 0);
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
  assert.equal(pushes.length, 0);
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
