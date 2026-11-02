const assert = require('node:assert/strict');
const { test } = require('node:test');
const route = require('./call_route');

test('phone numbers become E.164 and junk becomes empty', () => {
  assert.equal(route.normalizePhone('(519) 555-0123'), '+15195550123');
  assert.equal(route.normalizePhone('1 519 555 0123'), '+15195550123');
  assert.equal(route.normalizePhone('+44 20 7946 0958'), '+442079460958');
  assert.equal(route.normalizePhone('555-0123'), '');
  assert.equal(route.normalizePhone(''), '');
});

test('without a SIM number every mode behaves like the app', () => {
  assert.deepEqual(route.readCallRouting({}), { mode: 'app', cell: '' });
  assert.deepEqual(route.readCallRouting({ callRoute: 'cell' }), { mode: 'app', cell: '' });
  assert.deepEqual(route.readCallRouting({ callRoute: 'auto', masterCellNumber: '519 555 0123' }), {
    mode: 'auto',
    cell: '+15195550123',
  });
  assert.deepEqual(route.readCallRouting({ callRoute: 'nonsense', masterCellNumber: '5195550123' }), {
    mode: 'app',
    cell: '+15195550123',
  });
});

test('only the cell mode sends an inbound call to the SIM, and never the master to himself', () => {
  const cell = route.readCallRouting({ callRoute: 'cell', masterCellNumber: '5195550123' });
  const auto = route.readCallRouting({ callRoute: 'auto', masterCellNumber: '5195550123' });
  assert.equal(route.inboundGoesToCell(cell, '+14165550101'), true);
  assert.equal(route.inboundGoesToCell(cell, '+15195550123'), false);
  assert.equal(route.inboundGoesToCell(auto, '+14165550101'), false);
});

test('the SIM rings at least 15 seconds and at most a minute', () => {
  assert.equal(route.cellRingSeconds(8), 15);
  assert.equal(route.cellRingSeconds(25), 25);
  assert.equal(route.cellRingSeconds(90), 60);
  assert.equal(route.cellRingSeconds(undefined), 15);
});

test('a pending "call via SIM" request is taken only while fresh and unused', () => {
  const now = Date.parse('2026-10-27T15:00:00Z');
  const fresh = { phone: '4165550101', at: new Date(now - 30 * 1000) };
  assert.equal(route.pendingCellDestination(fresh, now), '+14165550101');
  assert.equal(route.pendingCellDestination({ ...fresh, at: new Date(now - 3 * 60 * 1000) }, now), '');
  assert.equal(route.pendingCellDestination({ ...fresh, consumedAt: new Date(now) }, now), '');
  assert.equal(route.pendingCellDestination({ phone: '123', at: new Date(now) }, now), '');
  assert.equal(route.pendingCellDestination(null, now), '');
});

test('query parameters are appended without empty values', () => {
  assert.equal(route.withQuery('https://x.test/dialAction', { stage: 'screen', parent: 'CA1' }),
    'https://x.test/dialAction?stage=screen&parent=CA1');
  assert.equal(route.withQuery('https://x.test/a?b=1', { leg: 'cell', parent: '' }), 'https://x.test/a?b=1&leg=cell');
});

test('the SIM leg keeps the client on ringing, records both sides and screens the master', () => {
  const xml = route.twimlDialCell({
    callerId: '+14165550101',
    cell: '+15195550123',
    timeoutSeconds: 8,
    actionUrl: 'https://x.test/dialAction?leg=cell',
    screenUrl: 'https://x.test/dialAction?stage=screen&parent=CA1',
    recordingUrl: 'https://x.test/recordingComplete',
  }).toString();
  assert.match(xml, /<Dial[^>]*answerOnBridge="true"/);
  assert.match(xml, /<Dial[^>]*record="record-from-answer-dual"/);
  assert.match(xml, /<Dial[^>]*timeout="15"/);
  assert.match(xml, /<Dial[^>]*callerId="\+14165550101"/);
  assert.match(xml, /<Number url="https:\/\/x\.test\/dialAction\?stage=screen&amp;parent=CA1">\+15195550123<\/Number>/);
});

test('the master must press 1; silence or another digit hangs up his leg', () => {
  const screen = route.twimlCellScreen({ acceptUrl: 'https://x.test/a' }).toString();
  assert.match(screen, /<Gather[^>]*numDigits="1"/);
  assert.match(screen, /<Say language="ru-RU">Звонок в мастерскую\. Нажмите 1/);
  assert.match(screen, /<\/Gather><Hangup\/>/);
  assert.match(route.twimlCellAccepted(true).toString(), /<Play digits="9"\/>/);
  assert.match(route.twimlCellAccepted(false).toString(), /<Hangup\/>/);
});
