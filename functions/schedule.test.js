const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const NOW = new Date('2026-09-08T13:00:00Z');
const START = new Date('2099-01-05T14:00:00Z');
let store;
let writes;
let transactionTail;

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
    get: async () => {
      if (store.has(path)) return snapshot(path);
      const docs = [...store.keys()]
        .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
        .map(snapshot)
        .filter((doc) => filters.every(({ field, op, value }) =>
          op === 'in' ? value.includes(doc.data()[field]) : doc.data()[field] === value));
      return { ...snapshot(path), docs, empty: !docs.length };
    },
  };
}

function apply(document, data) {
  const previous = structuredClone(store.get(document.path));
  store.set(document.path, { ...previous, ...structuredClone(data) });
  writes.push({ path: document.path, data: structuredClone(data) });
}

const firestore = Object.assign(() => ({
  collection: (name) => ref(name),
  runTransaction: (work) => {
    const result = transactionTail.then(async () => {
      const pending = [];
      const value = await work({
        get: (document) => document.get(),
        update: (document, data) => pending.push(() => apply(document, data)),
        set: (document, data) => pending.push(() => apply(document, data)),
      });
      pending.forEach((commit) => commit());
      return value;
    });
    transactionTail = result.catch(() => {});
    return result;
  },
}), {
  Timestamp: { now: () => new Date(), fromDate: (value) => value },
  FieldValue: { serverTimestamp: () => new Date(), delete: () => null },
});

const load = Module._load;
Module._load = function (name, parent, isMain) {
  if (name === 'firebase-admin') return { firestore };
  return load.apply(this, arguments);
};
const schedule = require('./schedule');
Module._load = load;

function job(patch = {}) {
  return {
    id: 'calendar-job',
    status: 'Вызов',
    clientId: 'calendar-client',
    clientPhone: '+14165550101',
    clientAddress: '1 Example Street',
    applianceType: 'Холодильник',
    visits: [{ id: 'visit-1', startAt: START, durationMinutes: 120, outcome: 'scheduled' }],
    ...patch,
  };
}

beforeEach(() => {
  store = new Map([[`${COMPANY}/settings/config`, {
    workDays: [1, 2, 3, 4, 5, 6, 7], workStartMinutes: 0, workEndMinutes: 1440,
  }]]);
  writes = [];
  transactionTail = Promise.resolve();
});

test('the imported Canceled October 11 2025 job is not an upcoming appointment', () => {
  const imported = job({
    status: 'Canceled',
    scheduledAt: new Date('2025-10-11T04:00:00Z'),
    visits: [{ id: 'imported', startAt: new Date('2025-10-11T04:00:00Z'), durationMinutes: 60, outcome: 'scheduled' }],
  });
  const brief = schedule.describeCallerJobs([imported], NOW);
  assert.doesNotMatch(brief, /October|already booked/);
  assert.match(brief, /No upcoming visits/);
});

test('all app closed-status aliases stay out of the caller schedule', () => {
  for (const status of ['Canceled', 'CANCELLED', ' cancel ', 'Отмена', 'Отменено', 'Завершено', 'Completed', 'Ready', 'Готов', 'Готово', 'Готова']) {
    const brief = schedule.describeCallerJobs([job({ status })], NOW);
    assert.match(brief, /No upcoming visits/, status);
    assert.doesNotMatch(brief, /2099|already booked/, status);
  }
});

test('a past scheduled visit is history, not a future booking', () => {
  const brief = schedule.describeCallerJobs([job({ visits: [{ id: 'old', startAt: new Date('2025-10-11T04:00:00Z') }] })], NOW);
  assert.doesNotMatch(brief, /October|already booked/);
  assert.match(brief, /No upcoming visits/);
});

test('a cancellation in the confirmation field also removes the active visit', () => {
  const initial = job();
  initial.visits[0].smsConfirmStatus = 'cancelled';
  assert.match(schedule.describeCallerJobs([initial], NOW), /No upcoming visits/);
});

test('caller brief includes every upcoming visit, earliest first, with explicit years', () => {
  const initial = job();
  initial.visits.unshift({ id: 'later', startAt: new Date('2100-03-10T14:00:00Z') });
  const brief = schedule.describeCallerJobs([initial], NOW);
  assert.match(brief, /2099/);
  assert.match(brief, /2100/);
  assert.ok(brief.indexOf('2099') < brief.indexOf('2100'));
});

test('legacy schedule fields still describe a real future visit', () => {
  const brief = schedule.describeCallerJobs([job({ visits: [], scheduledDate: START })], NOW);
  assert.match(brief, /2099/);
  assert.doesNotMatch(brief, /No upcoming visits/);
});

test('a cancellation is visible to a second calendar read without a process cache', async (t) => {
  t.mock.method(Date, 'now', () => NOW.getTime());
  const initial = job({ visits: [{ id: 'v', startAt: new Date('2026-09-09T14:00:00Z'), durationMinutes: 120 }] });
  store.set(`${COMPANY}/jobs/calendar-job`, initial);
  const before = await schedule.checkSlot(initial.visits[0].startAt);
  assert.equal(before.ok, false);
  store.set(`${COMPANY}/jobs/calendar-job`, { ...initial, status: 'Canceled' });
  const after = await schedule.checkSlot(initial.visits[0].startAt);
  assert.equal(after.ok, true);
});

test('personal calendar events block the same window as in the app without exposing titles', async (t) => {
  t.mock.method(Date, 'now', () => NOW.getTime() + 20000);
  const startAt = new Date('2026-09-09T14:00:00Z');
  store.set(`${COMPANY}/calendar_events/personal-event`, {
    title: 'Private appointment', startAt, durationMinutes: 60,
  });
  const check = await schedule.checkSlot(startAt);
  assert.equal(check.ok, false);
  assert.equal(check.reason, 'busy');
  const brief = await schedule.calendarBrief();
  assert.doesNotMatch(brief, /Private appointment/);
});

test('a custom open job status still occupies its active visit', async (t) => {
  t.mock.method(Date, 'now', () => NOW.getTime() + 40000);
  const startAt = new Date('2026-09-09T14:00:00Z');
  store.set(`${COMPANY}/jobs/custom-status`, job({ status: 'Custom active', visits: [{ id: 'v', startAt, durationMinutes: 120 }] }));
  assert.equal((await schedule.checkSlot(startAt)).ok, false);
});

const CALLER = { phone: '+14165550101', clientId: 'calendar-client', callSid: 'CA-calendar-test' };
const TARGET = { jobId: 'calendar-job', visitId: 'visit-1', expectedStartAt: START.toISOString() };

function seedCall(initial = job()) {
  store.set(`${COMPANY}/jobs/calendar-job`, initial);
  store.set(`${COMPANY}/calls/${CALLER.callSid}`, {
    fromNumber: CALLER.phone, clientId: CALLER.clientId, status: 'in-progress', answeredBy: 'ai',
  });
}

test('caller schedule combines matching contacts, excludes strangers and reloads after edits', async () => {
  seedCall();
  store.set(`${COMPANY}/jobs/duplicate-contact`, job({ clientId: 'older-contact', visits: [{ id: 'v2', startAt: new Date('2099-01-06T14:00:00Z') }] }));
  store.set(`${COMPANY}/jobs/other-caller`, job({ clientId: 'other', clientPhone: '+14165550199' }));
  const first = await schedule.loadCallerSchedule(CALLER);
  assert.equal(first.appointments.length, 2);
  assert.equal(first.appointments[0].jobId, 'calendar-job');
  store.set(`${COMPANY}/jobs/calendar-job`, job({ status: 'Canceled' }));
  assert.equal((await schedule.loadCallerSchedule(CALLER)).appointments.length, 1);
  assert.equal((await schedule.loadCallerSchedule({})).ok, false);
});

test('confirmed cancellation updates the canonical visit and both legacy dates atomically', async () => {
  seedCall();
  const result = await schedule.cancelCallerVisit(CALLER, TARGET);
  assert.equal(result.ok, true);
  assert.equal(result.changed, true);
  const saved = store.get(`${COMPANY}/jobs/calendar-job`);
  assert.equal(saved.visits[0].outcome, 'cancelled');
  assert.equal(saved.visits[0].smsConfirmStatus, 'cancelled');
  assert.equal(saved.status, 'Отменено');
  assert.equal(saved.scheduledAt, null);
  assert.equal(saved.scheduledDate, null);
  assert.equal(saved.visits[0].cancelledByCallId, CALLER.callSid);
  assert.equal(store.get(`${COMPANY}/calls/${CALLER.callSid}`).calendarActions.length, 1);
  assert.equal((await schedule.loadCallerSchedule(CALLER)).appointments.length, 0);
});

test('replayed and concurrent cancellation cannot cancel a second visit or duplicate audit rows', async () => {
  const initial = job();
  initial.visits.push({ id: 'second', startAt: new Date('2099-01-07T14:00:00Z'), durationMinutes: 90 });
  seedCall(initial);
  const results = await Promise.all([
    schedule.cancelCallerVisit(CALLER, TARGET), schedule.cancelCallerVisit(CALLER, TARGET),
  ]);
  assert.equal(results.filter((result) => result.changed).length, 1);
  const saved = store.get(`${COMPANY}/jobs/calendar-job`);
  assert.equal(saved.status, 'Вызов');
  assert.equal(saved.visits[1].outcome, undefined);
  assert.deepEqual(saved.scheduledAt, initial.visits[1].startAt);
  assert.deepEqual(saved.scheduledDate, initial.visits[1].startAt);
  assert.equal(store.get(`${COMPANY}/calls/${CALLER.callSid}`).calendarActions.length, 1);
});

test('a visit moved in the app while the caller confirms is not cancelled at the stale time', async () => {
  const initial = job();
  initial.visits[0].startAt = new Date('2099-01-06T14:00:00Z');
  seedCall(initial);
  const result = await schedule.cancelCallerVisit(CALLER, TARGET);
  assert.equal(result.ok, false);
  assert.equal(result.error, 'visit_changed');
  assert.deepEqual(writes, []);
});

test('cancellation rejects other callers, missing calls, closed jobs and invalid references', async () => {
  seedCall(job({ clientId: 'stranger', clientPhone: '+14165550199' }));
  assert.equal((await schedule.cancelCallerVisit(CALLER, TARGET)).ok, false);
  seedCall();
  assert.equal((await schedule.cancelCallerVisit({ ...CALLER, phone: '+14165550199' }, TARGET)).ok, false);
  store.delete(`${COMPANY}/calls/${CALLER.callSid}`);
  assert.equal((await schedule.cancelCallerVisit(CALLER, TARGET)).ok, false);
  seedCall(job({ status: 'Canceled' }));
  assert.equal((await schedule.cancelCallerVisit(CALLER, TARGET)).ok, false);
  assert.equal((await schedule.cancelCallerVisit(CALLER, { ...TARGET, jobId: '../other' })).ok, false);
  assert.deepEqual(writes, []);
});

test('ended calls cannot start a new cancellation', async () => {
  seedCall();
  store.get(`${COMPANY}/calls/${CALLER.callSid}`).status = 'completed';
  assert.equal((await schedule.cancelCallerVisit(CALLER, TARGET)).ok, false);
  assert.deepEqual(writes, []);
});
