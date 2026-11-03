const assert = require('node:assert/strict');
const { EventEmitter, once } = require('node:events');
const http = require('node:http');
const net = require('node:net');
const { test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');
const { WebSocket } = require('ws');
const voiceRelay = require('./voice_relay');
const voiceFacts = require('./voice_facts');

async function relayServer(t, configure) {
  const sockets = new Set();
  const server = http.createServer({
    headersTimeout: 120,
    requestTimeout: 360,
    connectionsCheckingInterval: 20,
  }, (req, res) => {
    res.status = (status) => {
      res.statusCode = status;
      return res;
    };
    res.send = (body) => res.end(body);
    setImmediate(() => voiceRelay.handleRequest(req, res));
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  if (configure) configure(server);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await new Promise(setImmediate);
  });
  return { server, sockets, port: server.address().port };
}

async function connect(t, port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`, { perMessageDeflate: false });
  const errors = [];
  ws.on('error', (error) => errors.push(error));
  t.after(() => ws.terminate());
  await once(ws, 'open');
  return { ws, errors };
}

function sendTraffic(t, ws) {
  let pongs = 0;
  ws.on('pong', () => pongs++);
  const payload = Buffer.alloc(160, 255).toString('base64');
  const timer = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ event: 'media', media: { track: 'inbound', payload } }));
    ws.ping();
  }, 20);
  t.after(() => clearInterval(timer));
  return () => pongs;
}

async function rawRequest(t, port, request) {
  const socket = net.connect(port, '127.0.0.1');
  let response = '';
  socket.on('data', (data) => { response += data.toString(); });
  socket.on('error', () => {});
  t.after(() => socket.destroy());
  const closed = new Promise((resolve) => socket.once('close', resolve));
  await once(socket, 'connect');
  socket.write(request);
  await Promise.race([
    closed,
    delay(1500, null, { ref: false }).then(() => assert.fail('HTTP connection was not closed')),
  ]);
  return response;
}

test('active relay sockets survive HTTP header and request timeouts', { timeout: 5000 }, async (t) => {
  const { server, port } = await relayServer(t);
  const first = await connect(t, port);
  const second = await connect(t, port);
  const firstPongs = sendTraffic(t, first.ws);
  const secondPongs = sendTraffic(t, second.ws);
  await delay(650);
  assert.equal(first.ws.readyState, WebSocket.OPEN, 'first call was restarted by an HTTP timeout');
  assert.equal(second.ws.readyState, WebSocket.OPEN, 'second call was restarted by an HTTP timeout');
  assert.deepEqual(first.errors, []);
  assert.deepEqual(second.errors, []);
  assert.ok(firstPongs() >= 5);
  assert.ok(secondPongs() >= 5);
  assert.equal(server.listenerCount('clientError'), 1);
  assert.equal(server.headersTimeout, 120);
  assert.equal(server.requestTimeout, 360);
});

test('normal HTTP connections still expire and malformed requests are rejected', { timeout: 5000 }, async (t) => {
  const { port } = await relayServer(t);
  const { ws } = await connect(t, port);
  sendTraffic(t, ws);
  const timeout = await rawRequest(t, port, 'GET / HTTP/1.1\r\nHost: localhost\r\n');
  assert.match(timeout, /^HTTP\/1\.1 408 Request Timeout\r\n/);
  const malformed = await rawRequest(t, port, 'invalid request\r\n\r\n');
  assert.match(malformed, /^HTTP\/1\.1 400 Bad Request\r\n/);
  const oversized = await rawRequest(t, port, `GET / HTTP/1.1\r\nHost: localhost\r\nX-Test: ${'x'.repeat(20000)}\r\n\r\n`);
  assert.match(oversized, /^HTTP\/1\.1 431 Request Header Fields Too Large\r\n/);
  assert.equal(ws.readyState, WebSocket.OPEN);
});

test('non-timeout errors still close upgraded sockets', { timeout: 5000 }, async (t) => {
  const { server, sockets, port } = await relayServer(t);
  const { ws } = await connect(t, port);
  const closed = once(ws, 'close');
  const error = Object.assign(new Error('Simulated connection error'), { code: 'ECONNRESET' });
  server.emit('clientError', error, [...sockets][0]);
  await closed;
  assert.equal(ws.readyState, WebSocket.CLOSED);
});

test('existing one-shot HTTP error handlers retain their behavior', { timeout: 5000 }, async (t) => {
  const seen = [];
  const { port } = await relayServer(t, (server) => {
    server.once('clientError', function (error, socket) {
      assert.equal(this, server);
      seen.push(error.code);
      socket.destroy();
    });
  });
  const { ws } = await connect(t, port);
  sendTraffic(t, ws);
  await delay(250);
  assert.equal(ws.readyState, WebSocket.OPEN);
  assert.deepEqual(seen, []);
  await rawRequest(t, port, 'invalid request\r\n\r\n');
  assert.deepEqual(seen, ['HPE_INVALID_METHOD']);
  const next = await rawRequest(t, port, 'invalid request\r\n\r\n');
  assert.match(next, /^HTTP\/1\.1 400 Bad Request\r\n/);
  assert.equal(seen.length, 1);
});

test('unauthenticated sockets still close after the authentication grace period', { timeout: 25000 }, async (t) => {
  const { port } = await relayServer(t);
  const { ws } = await connect(t, port);
  sendTraffic(t, ws);
  const [code, reason] = await once(ws, 'close');
  assert.equal(code, 1008);
  assert.equal(reason.toString(), 'unauthorized');
});

function greetingSession(overrides = {}) {
  const messages = [];
  const session = {
    ready: true,
    greeting: 'Hi, FIX Appliance CA. How can I help?',
    history: [],
    extracted: {},
    geminiWs: {
      readyState: WebSocket.OPEN,
      send: (raw) => messages.push(JSON.parse(raw)),
    },
    ...overrides,
  };
  return { session, messages };
}

test('the delivery rules ask for a natural cadence instead of a clipped, rushed one', () => {
  const prompt = voiceRelay.liveSystemPrompt({ instructions: 'Shop rules.' }, {});
  // Старые строки писались против медлительности Gemini и спорили с блоком
  // VOICE DELIVERY: модель просили быть расслабленной и торопиться разом.
  // В трубке это звучало мягко, но механически.
  assert.doesNotMatch(prompt, /brisk, efficient pace/);
  assert.doesNotMatch(prompt, /slightly quicker than ordinary conversation/);
  assert.doesNotMatch(prompt, /Clip the gaps between sentences/);
  assert.match(prompt, /let the sentence breathe/);
  assert.match(prompt, /An even, evenly-paced voice is what makes a caller hear a machine/);
  // Антизадержка остаётся: молчать перед первым словом по-прежнему нельзя.
  assert.match(prompt, /never add a silent thinking beat/);
  assert.match(prompt, /relaxed, natural human cadence/);
});

test('reply delivery stays connected while shop rules and caller pauses remain unchanged', () => {
  const profile = {
    instructions: 'Keep the existing repair intake and booking rules.',
    workHours: '8 a.m. to 6 p.m.',
    workDaysLabel: 'Tuesday–Friday',
    serviceArea: 'Test service area',
    priceLine: 'Use the configured price list.',
  };
  const session = {
    greetingSpoken: true,
    clientName: 'Test Client',
    knownAddress: 'Address on file',
    openJobBrief: 'An existing repair is already booked.',
    calendarBrief: 'The current visit window is occupied.',
  };
  const prompt = voiceRelay.liveSystemPrompt(profile, session);
  // Главное здесь — не рвать реплику надвое: «ага…» и пауза на обдумывание.
  // Требование торопиться убрано отдельно (см. тест про естественный темп).
  assert.match(prompt, /one flowing phrase/);
  assert.match(prompt, /never add a silent thinking beat/);
  assert.doesNotMatch(prompt, /while you think/);
  assert.ok(prompt.includes(profile.instructions));
  assert.ok(prompt.includes(profile.workHours));
  assert.ok(prompt.includes(profile.workDaysLabel));
  assert.ok(prompt.includes(profile.serviceArea));
  assert.ok(prompt.includes(profile.priceLine));
  assert.ok(prompt.includes(session.openJobBrief));
  assert.match(prompt, /whether this call is about that repair or a separate new one/);
  // Секретарь не назначает визиты: занятость календаря ей не показываем.
  assert.ok(!prompt.includes(session.calendarBrief));
  assert.match(prompt, /You do NOT book new visits/);
  assert.match(prompt, /technician will contact them/);
  assert.match(prompt, /Do not greet again/);
  assert.match(prompt, /If they pause to look something up, wait quietly/);
  assert.match(prompt, /You cannot hang up/);
});

test('pause tuning preserves the voice, listening sensitivity and long-session configuration', () => {
  const { setup } = voiceRelay.buildSetup('gemini-3.1-flash-live-preview', 'Shop instructions', false, 'test-resume');
  assert.equal(setup.model, 'models/gemini-3.1-flash-live-preview');
  // Zephyr звучал сухо — по умолчанию Aoede, остальное выбирается в настройках.
  assert.deepEqual(setup.generationConfig.speechConfig, {
    languageCode: 'en-US',
    voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Aoede' } },
  });
  assert.equal(setup.generationConfig.thinkingConfig, undefined);
  // 0,5 с тишины, а не 0,16: иначе она влезает на каждой паузе звонящего и
  // распознавание получает фразу кусками (решение FIX, 02.10.2026).
  assert.deepEqual(setup.realtimeInputConfig, {
    activityHandling: 'START_OF_ACTIVITY_INTERRUPTS',
    automaticActivityDetection: {
      disabled: false,
      startOfSpeechSensitivity: 'START_SENSITIVITY_HIGH',
      endOfSpeechSensitivity: 'END_SENSITIVITY_HIGH',
      prefixPaddingMs: 300,
      silenceDurationMs: 500,
    },
  });
  assert.deepEqual(setup.sessionResumption, { handle: 'test-resume' });
  assert.deepEqual(setup.contextWindowCompression, {
    triggerTokens: 64000, slidingWindow: { targetTokens: 32000 },
  });
});

test('the fallback list holds only models that exist, and the voice is configurable', () => {
  // 3.1-flash-live-preview Google выключает 17.11.2026 — основной стала 3.8-live.
  assert.deepEqual(voiceRelay._internals.liveModels(), [
    'gemini-3.8-live',
    'gemini-2.5-flash-native-audio-preview-12-2025',
  ]);
  const voiceOf = (voice) => voiceRelay.buildSetup('gemini-3.1-flash-live-preview', 'Shop rules', false, '', { voice })
    .setup.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName;
  assert.equal(voiceOf('Kore'), 'Kore');
  assert.equal(voiceOf('Leda'), 'Leda');
  assert.equal(voiceOf('Zephyr'), 'Zephyr');
  // Опечатка в настройках не должна оставить звонок без голоса.
  assert.equal(voiceOf('Nonexistent'), 'Aoede');
  assert.equal(voiceOf(''), 'Aoede');
});

test('affective dialog is sent only where the server knows it, and is dropped if refused', (t) => {
  const live = voiceRelay.buildSetup('gemini-3.1-flash-live-preview', 'Shop rules', true).setup;
  assert.equal(live.enableAffectiveDialog, undefined);
  const model = 'gemini-2.5-flash-native-audio-preview-12-2025';
  const native = voiceRelay.buildSetup(model, 'Shop rules', true).setup;
  assert.equal(native.enableAffectiveDialog, true);
  assert.deepEqual(native.generationConfig.thinkingConfig, { thinkingBudget: 0 });
  // Сервер не принял флаг — релей снимает его и поднимает ту же модель заново,
  // а не оставляет звонящего без голоса (так было с 1007 на v1beta).
  const retried = [];
  voiceRelay.init({
    geminiApiKey: 'test-gemini-key',
    openGeminiSocket: (_key, name) => {
      retried.push(name);
      return new FakeGeminiSocket();
    },
  });
  t.after(() => voiceRelay.init(null));
  const session = {
    callSid: 'CA-affective',
    setupPayload: { setup: structuredClone(native) },
    geminiModel: model,
    geminiWs: null,
  };
  voiceRelay._internals.handleGeminiMessage(
    session,
    JSON.stringify({ error: { message: 'Unknown name "enableAffectiveDialog"' } })
  );
  assert.equal(session.setupPayload.setup.enableAffectiveDialog, undefined);
  assert.equal(session.setupPayload.setup.generationConfig.thinkingConfig, undefined);
  assert.deepEqual(retried, [model]);
  assert.equal(session.noAffective, true);
});

test('a native-audio session that never opens is retried without the affective flag', (t) => {
  const call = liveCall(t, { voiceProvider: 'gemini' });
  // Доводим звонок до запасной native-audio модели: две неудачи подряд.
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.current().drop(1011);
  call.tick(200);
  call.ready();
  call.current().drop(1011);
  call.tick(200);
  const native = call.sockets[2];
  native.readyState = WebSocket.OPEN;
  native.emit('open');
  assert.equal(native.setup.model, 'models/gemini-2.5-flash-native-audio-preview-12-2025');
  assert.equal(native.setup.enableAffectiveDialog, true);
  assert.equal(call.affective.at(-1), true, 'v1alpha only while the flag is on');

  // Сокет закрылся, так и не дойдя до setupComplete: интонация не стоит
  // потерянной запасной модели — поднимаем ту же модель без флага.
  native.drop(1011, 'Unknown name "enableAffectiveDialog"');
  call.tick(200);
  assert.equal(call.session.noAffective, true);
  const plain = call.sockets[3];
  plain.readyState = WebSocket.OPEN;
  plain.emit('open');
  assert.equal(plain.setup.model, 'models/gemini-2.5-flash-native-audio-preview-12-2025');
  assert.equal(plain.setup.enableAffectiveDialog, undefined);
  assert.equal(call.affective.at(-1), false, 'and back to v1beta');
});

test('blocking tool calls are asked for only where the model needs them', () => {
  const behaviours = (model) => voiceRelay.buildSetup(model, 'Shop rules', true).setup.tools[0]
    .functionDeclarations.map((fn) => fn.behavior);
  assert.deepEqual(behaviours('gemini-3.1-flash-live-preview'), [undefined, undefined, undefined]);
  assert.deepEqual(behaviours('gemini-2.5-flash-native-audio-preview-12-2025'), [undefined, undefined, undefined]);
  // Модели новее зовут инструменты асинхронно; отмена визита обязана дождаться
  // сервера, иначе она подтвердит клиенту то, чего не сохранилось.
  assert.deepEqual(behaviours('gemini-4-live'), ['BLOCKING', 'BLOCKING', 'BLOCKING']);
});

test('she is Sarah: one fixed name, honest about being a virtual assistant, calm on a bad line', () => {
  const prompt = voiceRelay.liveSystemPrompt({ instructions: 'Shop rules.' }, {});
  assert.match(prompt, /You are Sarah, answering the shop phone/);
  assert.match(prompt, /Never use another name, and never introduce yourself as "she"/);
  assert.match(prompt, /Asked your name: "I'm Sarah"/);
  assert.match(prompt, /Never answer a personal question with a checklist question/);
  assert.match(prompt, /the shop's virtual assistant/);
  assert.match(prompt, /Never claim to be human/);
  assert.match(prompt, /At most twice in the whole call/);
  assert.match(prompt, /call back or text this number/);
  assert.doesNotMatch(prompt, /You are a real woman/);
  const { session, messages } = greetingSession({ greeting: '' });
  voiceRelay.greetLive(session);
  const greeting = messages[0].clientContent.turns[0].parts[0].text;
  assert.match(greeting, /If you give your name, it is Sarah/);
  assert.match(greeting, /never "this is she"/);
  assert.doesNotMatch(greeting, /made-up personal name/);
});

test('first greeting is improvised like a live person, without a canned line', () => {
  const { session, messages } = greetingSession({ greeting: '' });
  voiceRelay.greetLive(session);
  assert.equal(messages.length, 1);
  const content = messages[0].clientContent;
  const prompt = content.turns[0].parts[0].text;
  assert.match(prompt, /in your own words/i);
  assert.match(prompt, /first greeting only/);
  assert.match(prompt, /no memorized slogan/i);
  assert.doesNotMatch(prompt, /Keep the meaning of this opening/);
  assert.doesNotMatch(prompt, /Hi, FIX Appliance CA/);
  assert.match(prompt, /stop and listen/);
  assert.doesNotMatch(prompt, /Speak ONLY this greeting|No other words:/);
  assert.equal(content.turnComplete, true);
  assert.equal(content.turns.length, 1);
});

test('natural greeting retains the technician handoff meaning', () => {
  const greeting = 'The technician had to step away. How can I help?';
  const { session, messages } = greetingSession({ greeting });
  voiceRelay.greetLive(session);
  assert.ok(messages[0].clientContent.turns[0].parts[0].text.includes(greeting));
});

test('initial greeting is sent once and never repeats an already spoken greeting', () => {
  const first = greetingSession();
  voiceRelay.greetLive(first.session);
  voiceRelay.greetLive(first.session);
  assert.equal(first.messages.length, 1);
  const spoken = greetingSession({ greetingSpoken: true });
  voiceRelay.greetLive(spoken.session);
  assert.deepEqual(spoken.messages, []);
});

test('greeting waits for the Live session to be ready', () => {
  const { session, messages } = greetingSession({ ready: false });
  voiceRelay.greetLive(session);
  assert.equal(session.greeted, undefined);
  assert.deepEqual(messages, []);
  session.ready = true;
  voiceRelay.greetLive(session);
  assert.equal(messages.length, 1);
});

test('resumed calls continue with their history instead of a new greeting', () => {
  const history = [
    { role: 'user', text: 'My dryer is not heating.' },
    { role: 'assistant', text: 'What brand is it?' },
  ];
  for (const resumeHandle of ['', 'test-resume-handle']) {
    const { session, messages } = greetingSession({ needsContinue: true, history, resumeHandle });
    voiceRelay.greetLive(session);
    assert.equal(messages.length, 1);
    const turns = messages[0].clientContent.turns;
    const prompt = turns.at(-1).parts[0].text;
    assert.match(prompt, /Same caller, not a new call/);
    assert.match(prompt, /My dryer is not heating/);
    assert.match(prompt, /Do not greet from scratch/);
    assert.doesNotMatch(prompt, /The call just connected|first greeting only/);
    assert.equal(turns.length, resumeHandle ? 1 : history.length + 1);
    assert.equal(session.needsContinue, false);
    assert.equal(session.greeted, true);
    // Последней говорила она: после сбоя молчит и слушает, без «I'm still here».
    assert.equal(messages[0].clientContent.turnComplete, false);
    assert.match(prompt, /Stay quiet and listen until the caller speaks/);
  }
});

test('after a glitch she answers at once only if the caller was left without a reply', () => {
  const history = [
    { role: 'assistant', text: 'What brand is it?' },
    { role: 'user', text: "It's a Whirlpool, about five years old." },
  ];
  const { session, messages } = greetingSession({ needsContinue: true, history, resumeHandle: 'test-resume-handle' });
  voiceRelay.greetLive(session);
  assert.equal(messages[0].clientContent.turnComplete, true);
  assert.match(messages[0].clientContent.turns.at(-1).parts[0].text, /Reply now to what the caller just said/);
});

test('Live history records the actual greeting while fixed TTS greetings still persist', async (t) => {
  let written;
  voiceRelay.init({
    callsRef: {
      doc: () => ({
        get: async () => ({ exists: false }),
        set: async (data) => { written = structuredClone(data); },
      }),
    },
  });
  t.after(() => voiceRelay.init(null));
  const actual = 'Fix Appliance CA. What can I help you with?';
  const history = [{ role: 'assistant', text: actual }];
  const live = greetingSession({
    callSid: 'CA-greeting-test', engine: 'gemini-live', history, transcription: `AI: ${actual}`,
  });
  await voiceRelay.persistSession(live.session);
  assert.deepEqual(written.aiReception.history, history);
  assert.equal(written.transcription, `AI: ${actual}`);
  const interrupted = greetingSession({
    callSid: 'CA-greeting-test', engine: 'gemini-live', transcription: '',
  });
  await voiceRelay.persistSession(interrupted.session);
  assert.deepEqual(written.aiReception.history, []);
  assert.equal(written.transcription, '');
  const fixed = greetingSession({ callSid: 'CA-greeting-test', engine: 'relay', transcription: '' });
  await voiceRelay.persistSession(fixed.session);
  assert.deepEqual(written.aiReception.history, [{ role: 'assistant', text: fixed.session.greeting }]);
  assert.equal(written.transcription, `AI: ${fixed.session.greeting}`);
});

const TEST_APPOINTMENT = {
  jobId: 'test-job', visitId: 'test-visit', startAt: '2099-01-05T14:00:00.000Z',
  when: 'Monday, January 5, 2099 at 9 a.m. Toronto', address: '1 Example Street',
};

function appointmentSession(t, overrides = {}) {
  const state = { appointments: [TEST_APPOINTMENT], cancellations: [], reads: 0 };
  voiceRelay.init({
    loadCallerSchedule: async (caller) => {
      state.reads++;
      assert.equal(caller.phone, '+14165550101');
      return { ok: true, appointments: [...state.appointments], brief: state.appointments.length ? 'Current booking' : 'No upcoming visits' };
    },
    cancelCallerVisit: async (caller, target) => {
      state.cancellations.push({ caller, target });
      state.appointments = [];
      return { ok: true, changed: true, status: 'cancelled', appointment: TEST_APPOINTMENT };
    },
    ...overrides,
  });
  t.after(() => voiceRelay.init(null));
  const session = {
    callSid: 'CA-appointment-test', fromNumber: '+14165550101', clientId: 'test-client',
    history: [{ role: 'user', text: 'Please cancel my appointment.' }], extracted: {},
  };
  return { session, state };
}

function confirmCancellation(session, text = 'Yes, please cancel it.') {
  session.history.push(
    { role: 'assistant', text: 'Should I cancel the visit on Monday, January 5, 2099 at 9 a.m.?' },
    { role: 'user', text },
  );
}

test('Live declares real calendar tools and never declares a hangup tool', () => {
  const { setup } = voiceRelay.buildSetup('gemini-3.1-flash-live-preview', 'Shop rules', true);
  const names = setup.tools.flatMap((tool) => tool.functionDeclarations.map((fn) => fn.name));
  assert.deepEqual(names.sort(), [
    'cancel_appointment',
    'check_service_area',
    'get_caller_appointments',
  ]);
  assert.equal(voiceRelay.buildSetup('gemini-3.1-flash-live-preview', 'Shop rules', false).setup.tools, undefined);
});

// Вопрос «вы ездите в Вильсонвилль?» не должен превращать звонок в разговор про
// существующий визит: раньше любой инструмент включал appointmentOnly и заявка
// переставала создаваться.
test('service area lookup answers from the map without touching the appointment state', async (t) => {
  const asked = [];
  const { session, state } = appointmentSession(t, {
    checkServiceArea: async (place) => {
      asked.push(place);
      return { ok: true, inside: true, place: 'Wilsonville, Norfolk, ON', source: 'geocode' };
    },
  });
  const result = await voiceRelay.runAppointmentTool(session, 'check_service_area', {
    place: 'Wilsonville',
  });
  assert.deepEqual(asked, ['Wilsonville']);
  assert.equal(result.inside, true);
  assert.equal(state.reads, 0);
  assert.equal(session.appointmentOnly, undefined);
  assert.equal(session.createJob, undefined);
});

test('without a map service the relay reports it instead of refusing the caller', async (t) => {
  const { session } = appointmentSession(t);
  const result = await voiceRelay.runAppointmentTool(session, 'check_service_area', { place: 'Ayr' });
  assert.equal(result.ok, false);
  assert.equal(result.error, 'no_map');
});

test('appointment lookup reloads the server instead of repeating the session snapshot', async (t) => {
  const { session, state } = appointmentSession(t);
  session.openJobBrief = 'Stale October 11 booking';
  assert.equal((await voiceRelay.runAppointmentTool(session, 'get_caller_appointments')).appointments.length, 1);
  state.appointments = [];
  assert.equal((await voiceRelay.runAppointmentTool(session, 'get_caller_appointments')).appointments.length, 0);
  assert.equal(state.reads, 2);
  assert.equal(session.openJobBrief, 'No upcoming visits');
});

test('cancel requires a separate caller confirmation even if the model claims confirmed', async (t) => {
  const { session, state } = appointmentSession(t);
  const args = { job_id: 'test-job', visit_id: 'test-visit', confirmed: true };
  assert.equal((await voiceRelay.runAppointmentTool(session, 'cancel_appointment', args)).status, 'confirmation_required');
  assert.equal((await voiceRelay.runAppointmentTool(session, 'cancel_appointment', args)).status, 'confirmation_required');
  assert.equal(state.cancellations.length, 0);
  confirmCancellation(session);
  const result = await voiceRelay.runAppointmentTool(session, 'cancel_appointment', args);
  assert.equal(result.ok, true);
  assert.equal(result.status, 'cancelled');
  assert.equal(state.cancellations.length, 1);
  assert.equal(state.cancellations[0].target.expectedStartAt, TEST_APPOINTMENT.startAt);
  assert.equal(session.pendingCancellation, null);
  assert.equal(session.openJobBrief, 'No upcoming visits');
});

test('unrelated or negated yes never cancels a visit', async (t) => {
  const { session, state } = appointmentSession(t);
  for (const text of ["Yes, but don't cancel it", 'No, keep it', 'Yes, reschedule instead', 'Do not cancel', 'Нет, не отменяйте']) {
    await voiceRelay.runAppointmentTool(session, 'cancel_appointment');
    confirmCancellation(session, text);
    const result = await voiceRelay.runAppointmentTool(session, 'cancel_appointment', { confirmed: true });
    assert.notEqual(result.status, 'cancelled');
  }
  session.history.push({ role: 'assistant', text: 'Is your address still the same?' }, { role: 'user', text: 'Yes' });
  await voiceRelay.runAppointmentTool(session, 'cancel_appointment', { confirmed: true });
  assert.equal(state.cancellations.length, 0);
});

test('cancellation success is not returned until the server write is acknowledged', async (t) => {
  let finish;
  const pendingWrite = new Promise((resolve) => { finish = resolve; });
  const { session } = appointmentSession(t, { cancelCallerVisit: () => pendingWrite });
  await voiceRelay.runAppointmentTool(session, 'cancel_appointment');
  confirmCancellation(session);
  let replied = false;
  const cancelling = voiceRelay.runAppointmentTool(session, 'cancel_appointment', { confirmed: true }).then((result) => {
    replied = true;
    return result;
  });
  await new Promise(setImmediate);
  assert.equal(replied, false);
  finish({ ok: true, status: 'cancelled', appointment: TEST_APPOINTMENT });
  assert.equal((await cancelling).status, 'cancelled');
});

test('changed visits and unavailable storage never produce a false cancellation success', async (t) => {
  const { session } = appointmentSession(t, { cancelCallerVisit: async () => ({ ok: false, error: 'visit_changed' }) });
  await voiceRelay.runAppointmentTool(session, 'cancel_appointment');
  confirmCancellation(session);
  const changed = await voiceRelay.runAppointmentTool(session, 'cancel_appointment', { confirmed: true });
  assert.equal(changed.ok, false);
  assert.doesNotMatch(changed.say, /is cancelled|I've cancelled/);
  voiceRelay.init({ loadCallerSchedule: async () => { throw new Error('Test storage unavailable'); } });
  const failed = await voiceRelay.runAppointmentTool(session, 'get_caller_appointments');
  assert.equal(failed.ok, false);
  assert.doesNotMatch(session.openJobBrief, /Current booking|No upcoming visits/);
});

test('multiple appointments require selection and unknown tools fail closed', async (t) => {
  const { session, state } = appointmentSession(t);
  state.appointments.push({ ...TEST_APPOINTMENT, jobId: 'another-job' });
  assert.equal((await voiceRelay.runAppointmentTool(session, 'cancel_appointment')).status, 'selection_required');
  assert.equal((await voiceRelay.runAppointmentTool(session, 'invented_tool')).ok, false);
  assert.equal(state.cancellations.length, 0);
});

test('appointment-only calls cannot become repair jobs from repeated historical facts', () => {
  const extracted = { client_name: 'Test', appliance_type: 'Холодильник', address: '1 Example Street', scheduled_date: '2099-01-05', scheduled_time: '09:00' };
  const data = { aiReception: { appointmentOnly: true, history: [
    { role: 'assistant', text: 'Your fridge repair visit is on January 5.' },
    { role: 'user', text: 'Was that appointment cancelled?' },
  ] } };
  assert.equal(voiceFacts.isAppointmentOnly(extracted, data), true);
  data.aiReception.history.push({ role: 'user', text: 'I need to create a new appointment to repair my microwave.' });
  assert.equal(voiceFacts.isAppointmentOnly(extracted, data), false);
});

// ── Живой звонок на поддельном сокете Gemini и поддельных часах ─────────────

class FakeGeminiSocket extends EventEmitter {
  constructor() {
    super();
    this.readyState = 0;
    this.sent = [];
  }
  send(raw) { this.sent.push(JSON.parse(raw)); }
  ping() {}
  close() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit('close', 1000, Buffer.from(''));
  }
  terminate() { this.close(); }
  server(message) { this.emit('message', Buffer.from(JSON.stringify(message))); }
  drop(code = 1011, reason = 'Internal error encountered.') {
    this.readyState = 3;
    this.emit('close', code, Buffer.from(reason));
  }
  get setup() { return this.sent.find((m) => m.setup)?.setup; }
  get prompts() { return this.sent.filter((m) => m.clientContent).map((m) => m.clientContent); }
}

const MODEL_AUDIO = Buffer.alloc(960).toString('base64');
const LOUD_FRAME = Buffer.from(Array.from({ length: 160 }, (_, i) => (i % 2 ? 0x00 : 0x80))).toString('base64');

function liveCall(t, sessionOverrides = {}) {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  const sockets = [];
  const affective = [];
  const writes = [];
  const twilio = {
    readyState: WebSocket.OPEN, closed: false, sent: [],
    send(raw) { this.sent.push(JSON.parse(raw)); },
    close() { this.closed = true; this.readyState = WebSocket.CLOSED; },
  };
  voiceRelay.init({
    geminiApiKey: 'test-gemini-key',
    openGeminiSocket: (_key, _model, wantsAffective) => {
      const ws = new FakeGeminiSocket();
      sockets.push(ws);
      affective.push(Boolean(wantsAffective));
      return ws;
    },
    callsRef: {
      doc: () => ({
        get: async () => ({ exists: false }),
        set: async (data) => { writes.push(structuredClone(data)); },
      }),
    },
    mergeExtracted: (prev) => ({ ...(prev || {}) }),
    normalizePhone: (phone) => String(phone || '').replace(/\D/g, '').slice(-10),
    hasEnoughForJob: () => false,
    appendTranscript: (current, line) => [current, line].filter(Boolean).join('\n'),
    generateVoiceContent: async () => ({ response: { text: () => '{}' } }),
    extractJsonObject: (raw) => JSON.parse(raw),
  });
  t.after(() => voiceRelay.init(null));
  const session = {
    callSid: 'CA-live-test', fromNumber: '+15195550100', streamSid: 'MZ-live-test',
    history: [], extracted: {}, turns: 0, twilioWs: twilio, outLeftover: new Int16Array(0),
    userPartial: '', assistantPartial: '', systemText: 'Shop rules.', startedAt: Date.now(),
    ...sessionOverrides,
  };
  voiceRelay._internals.startGeminiLive(session);
  const current = () => sockets.at(-1);
  const ready = () => {
    current().readyState = WebSocket.OPEN;
    current().emit('open');
    current().server({ setupComplete: {} });
  };
  const modelSays = (text) => {
    current().server({ serverContent: { outputTranscription: { text } } });
    current().server({ serverContent: { modelTurn: { parts: [{ inlineData: { mimeType: 'audio/pcm;rate=24000', data: MODEL_AUDIO } }] } } });
    current().server({ serverContent: { turnComplete: true } });
  };
  const callerSays = (text) => current().server({ serverContent: { inputTranscription: { text } } });
  const tick = (ms) => t.mock.timers.tick(ms);
  const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
  const allPrompts = () => sockets.flatMap((ws) => ws.prompts);
  return {
    session, sockets, affective, twilio, writes, current, ready,
    modelSays, callerSays, tick, flush, allPrompts,
  };
}

test('a model that keeps dropping is swapped for the next one, never looping "I\'m still here", then Gather', async (t) => {
  const call = liveCall(t);
  assert.equal(voiceRelay._internals.timing.LIVE_FAILURE_LIMIT, 5);
  call.ready();
  call.current().server({ sessionResumptionUpdate: { newHandle: 'handle-1' } });
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  const models = () => call.sockets.map((ws) => ws.setup.model.replace('models/', ''));

  call.current().drop(1011);
  call.tick(200);
  assert.equal(call.sockets.length, 2);
  call.ready();
  assert.deepEqual(call.sockets[1].setup.sessionResumption, { handle: 'handle-1' });

  call.current().drop(1011);
  call.tick(200);
  call.ready();
  call.current().drop(1011);
  call.tick(200);
  call.ready();
  // Первый обрыв — та же модель с ручкой сессии, второй подряд — следующая.
  assert.deepEqual(models(), [
    'gemini-3.8-live',
    'gemini-3.8-live',
    'gemini-2.5-flash-native-audio-preview-12-2025',
    'gemini-2.5-flash-native-audio-preview-12-2025',
  ]);
  // Ручка сессии не переносится на другую модель, а история передаётся текстом.
  assert.deepEqual(call.sockets[2].setup.sessionResumption, {});
  assert.match(JSON.stringify(call.sockets[2].prompts), /this is Sarah/);
  // Ни одно переподключение не заставило её заговорить без звонящего.
  const forced = call.sockets.slice(1).flatMap((ws) => ws.prompts).filter((p) => p.turnComplete);
  assert.deepEqual(forced, []);

  // Запасных в цепочке не осталось — дальше резервный Gather, новых сокетов нет.
  call.current().drop(1011);
  call.tick(200);
  await call.flush();
  assert.equal(call.sockets.length, 4);
  assert.ok(call.writes.some((w) => w.aiReception && w.aiReception.liveFailed === true));
  assert.equal(call.twilio.closed, true);
});

test('a planned goAway reconnect keeps the model and is not counted as a failure', (t) => {
  const call = liveCall(t);
  call.ready();
  call.current().server({ sessionResumptionUpdate: { newHandle: 'handle-9' } });
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.current().server({ goAway: { timeLeft: '50s' } });
  assert.equal(call.sockets.length, 2, 'goAway opens the next session straight away');
  call.ready();
  assert.deepEqual(call.sockets[1].setup.sessionResumption, { handle: 'handle-9' });
  assert.equal(call.sockets[1].setup.model, 'models/gemini-3.8-live');
  assert.equal(call.session.liveFailures || 0, 0);
});

test('the stall nudge waits for the caller to finish and never fires after she answered', (t) => {
  const call = liveCall(t);
  const { STALL_MS } = voiceRelay._internals.timing;
  // 3 с срезали живую паузу: она обрывала фразу и начинала повторяться.
  assert.equal(STALL_MS, 4500);
  const nudges = () => call.allPrompts().filter((p) => /still on the line/.test(JSON.stringify(p)));
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.callerSays('My dryer is making');
  call.tick(2000);
  call.callerSays(' kind of a grinding noise, uh');
  call.tick(STALL_MS - 100);
  assert.equal(nudges().length, 0, 'the caller has only just stopped — too early to push her');
  call.tick(100);
  assert.equal(nudges().length, 1);

  call.modelSays('Oh no — when does it grind?');
  call.callerSays('When it spins.');
  call.tick(1200);
  call.modelSays('Got it. What brand is it?');
  call.tick(6000);
  assert.equal(nudges().length, 1, 'she answered, nothing to rescue');
});

test('silence on the line: one check, then "can\'t hear you", then the relay hangs up 30 s later', async (t) => {
  const call = liveCall(t);
  const { SILENCE_CHECK_MS, SILENCE_GIVEUP_MS, SILENCE_HANGUP_MS } = voiceRelay._internals.timing;
  const ladder = () => call.allPrompts().map((p) => p.turns[0].parts[0].text).filter((text) => /said anything|Still nothing/.test(text));
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.tick(SILENCE_CHECK_MS - 1000);
  call.callerSays('Hi, my fridge is warm.');
  call.modelSays('Oh no — is the freezer still cold?');
  call.tick(SILENCE_CHECK_MS - 1);
  assert.deepEqual(ladder(), [], 'a word from the caller restarts the count');
  call.tick(1);
  assert.equal(ladder().length, 1);
  assert.match(ladder()[0], /are you still there/);

  call.modelSays('Hello — are you still there?');
  call.tick(SILENCE_GIVEUP_MS);
  assert.equal(ladder().length, 2);
  assert.match(ladder()[1], /trouble hearing them/);
  assert.match(ladder()[1], /call back or send a text/);

  call.modelSays("Sorry, I'm having trouble hearing you — please call back or text this number.");
  call.tick(SILENCE_HANGUP_MS - 1);
  assert.equal(call.twilio.closed, false);
  call.tick(1);
  await call.flush();
  assert.equal(call.twilio.closed, true);
  const last = call.writes.at(-1).aiReception;
  assert.equal(last.hangup, 'silence');
  assert.equal(last.done, true);
});

test('after "have a good day" she does not ask whether they are there; the line closes after 30 s', async (t) => {
  const call = liveCall(t);
  const { SILENCE_HANGUP_MS } = voiceRelay._internals.timing;
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.callerSays("No, that's all, thanks.");
  call.modelSays('Perfect — have a good day!');
  call.tick(SILENCE_HANGUP_MS);
  await call.flush();
  assert.equal(call.allPrompts().filter((p) => /said anything/.test(JSON.stringify(p))).length, 0);
  assert.equal(call.twilio.closed, true);
});

test('"hold on, let me check" buys a full minute before she checks the line', (t) => {
  const call = liveCall(t);
  const { SILENCE_CHECK_MS, SILENCE_HOLD_MS } = voiceRelay._internals.timing;
  const checks = () => call.allPrompts().filter((p) => /said anything/.test(JSON.stringify(p))).length;
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.callerSays('Hold on, let me grab the model number.');
  call.modelSays('Sure, take your time.');
  call.tick(SILENCE_CHECK_MS * 3);
  assert.equal(checks(), 0);
  call.tick(SILENCE_HOLD_MS - SILENCE_CHECK_MS * 3);
  assert.equal(checks(), 1);
});

test('a deaf model (caller audibly talks, Gemini hears nothing) is replaced, and the second time Gather takes over', async (t) => {
  const call = liveCall(t);
  const { SILENCE_CHECK_MS } = voiceRelay._internals.timing;
  const talk = (ms) => {
    for (let at = 0; at < ms; at += 20) {
      voiceRelay._internals.sendCallerAudio(call.session, LOUD_FRAME);
      call.tick(20);
    }
  };
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.tick(1000);
  talk(2000);
  call.tick(SILENCE_CHECK_MS - 3000);
  assert.equal(call.sockets.length, 2, 'switched to the next model');
  call.ready();
  assert.equal(call.sockets[1].setup.model, 'models/gemini-2.5-flash-native-audio-preview-12-2025');
  assert.equal(call.current().prompts.at(-1).turnComplete, false);

  talk(2000);
  call.tick(SILENCE_CHECK_MS);
  await call.flush();
  assert.ok(call.writes.some((w) => w.aiReception && w.aiReception.liveFailed === true));
  assert.equal(call.twilio.closed, true);
});

test('a long story from the caller is not mistaken for silence or deafness', (t) => {
  const call = liveCall(t);
  const { SILENCE_CHECK_MS } = voiceRelay._internals.timing;
  call.ready();
  call.modelSays('FixApplianceCA, this is Sarah — what can I do for you?');
  // 3.1 присылает расшифровку только в конце фразы: 14 секунд рассказа без неё.
  for (let at = 0; at < 14000; at += 20) {
    voiceRelay._internals.sendCallerAudio(call.session, LOUD_FRAME);
    call.tick(20);
  }
  call.callerSays('So the dryer started making this noise last week and now it will not heat at all.');
  call.tick(SILENCE_CHECK_MS - 1);
  assert.equal(call.sockets.length, 1);
  assert.equal(call.allPrompts().filter((p) => /said anything/.test(JSON.stringify(p))).length, 0);
});

// ── Живой звонок на OpenAI Realtime ────────────────────────────────────────

test('the provider chain falls back to Gemini and never offers a provider without a key', () => {
  const chain = (session, keys) => {
    voiceRelay.init(keys);
    const steps = voiceRelay._internals.buildLiveChain(session);
    voiceRelay.init(null);
    return steps.map((step) => `${step.provider}:${step.model}`);
  };
  const both = { geminiApiKey: 'g', openaiApiKey: 'o' };
  assert.deepEqual(chain({ voiceProvider: 'openai', openaiModel: 'gpt-realtime' }, both), [
    'openai:gpt-realtime',
    'gemini:gemini-3.8-live',
    'gemini:gemini-2.5-flash-native-audio-preview-12-2025',
  ]);
  // Выбран Gemini — он ведёт, OpenAI ждёт в конце очереди. Откат симметричный.
  assert.deepEqual(chain({ voiceProvider: 'gemini', openaiModel: 'gpt-realtime' }, both), [
    'gemini:gemini-3.8-live',
    'gemini:gemini-2.5-flash-native-audio-preview-12-2025',
    'openai:gpt-realtime',
  ]);
  // По умолчанию (поле не задано) звонки ведёт Gemini.
  assert.deepEqual(chain({}, both), [
    'gemini:gemini-3.8-live',
    'gemini:gemini-2.5-flash-native-audio-preview-12-2025',
    'openai:gpt-realtime',
  ]);
  // Ключа OpenAI нет — звонки ведёт Gemini, как и раньше.
  assert.deepEqual(chain({ voiceProvider: 'openai' }, { geminiApiKey: 'g' }), [
    'gemini:gemini-3.8-live',
    'gemini:gemini-2.5-flash-native-audio-preview-12-2025',
  ]);
  // Нет ключа Gemini — лучше OpenAI, чем тишина в трубке.
  assert.deepEqual(chain({ voiceProvider: 'gemini' }, { openaiApiKey: 'o' }), [
    'openai:gpt-realtime',
  ]);
  assert.deepEqual(chain({ voiceProvider: 'openai' }, {}), []);
});

test('every call logs which keys were seen, so a missing key is never mistaken for a choice', (t) => {
  const lines = [];
  const log = console.log;
  console.log = (text) => lines.push(String(text));
  t.after(() => { console.log = log; });
  const call = openaiCall(t);
  console.log = log;
  const chain = lines.find((line) => line.includes('voiceLive chain'));
  assert.match(chain, /key:openai=yes/);
  assert.match(chain, /key:gemini=yes/);
  assert.match(chain, /settings=openai/);
  assert.match(chain, /steps=\[openai:gpt-realtime -> gemini:/);
  assert.equal(call.sockets.length, 1);
});

test('the OpenAI session speaks Twilio\'s own audio format and declares the same three tools', () => {
  const { session } = voiceRelay.buildOpenaiSession({ openaiVoice: 'marin' }, true, 'Shop rules.');
  // Схема GA, снятая с живого сокета. Бета-форма (modalities, voice и
  // input_audio_format в корне, temperature) сервером больше не принимается.
  assert.equal(session.type, 'realtime');
  assert.equal(session.instructions, 'Shop rules.');
  assert.deepEqual(session.output_modalities, ['audio']);
  assert.equal(session.audio.output.voice, 'marin');
  assert.equal(session.audio.output.speed, 1);
  // Родной формат Twilio в обе стороны: ни одного пересчёта частоты.
  assert.deepEqual(session.audio.input.format, { type: 'audio/pcmu' });
  assert.deepEqual(session.audio.output.format, { type: 'audio/pcmu' });
  assert.deepEqual(session.audio.input.transcription, { model: 'gpt-4o-mini-transcribe', language: 'en' });
  assert.deepEqual(session.audio.input.turn_detection, {
    type: 'server_vad', threshold: 0.6, prefix_padding_ms: 300,
    silence_duration_ms: 500, create_response: true, interrupt_response: true,
  });
  // session.temperature в GA не существует и отбивает весь setup.
  assert.equal(session.temperature, undefined);
  assert.deepEqual(session.tools.map((tool) => tool.name).sort(), [
    'cancel_appointment', 'check_service_area', 'get_caller_appointments',
  ]);
  assert.ok(session.tools.every((tool) => tool.type === 'function'));
  assert.deepEqual(session.tools.find((tool) => tool.name === 'check_service_area').parameters, {
    type: 'object',
    properties: {
      place: {
        type: 'string',
        description: 'What the caller said: a town, a hamlet, a postal code, or a full street address. Ontario is assumed.',
      },
    },
    required: ['place'],
  });
  // Инструмента «положить трубку» нет ни у одного провайдера.
  assert.ok(!session.tools.some((tool) => /end_call|hangup/i.test(tool.name)));
  const voiceOf = (voice) =>
    voiceRelay.buildOpenaiSession({ openaiVoice: voice }, false, 'x').session.audio.output.voice;
  assert.equal(voiceOf('sage'), 'sage');
  assert.equal(voiceOf('cedar'), 'cedar');
  assert.equal(voiceOf('coral'), 'coral');
  // Опечатка в настройках не должна оставить звонок без голоса.
  assert.equal(voiceOf('nonexistent'), 'marin');
  assert.deepEqual(voiceRelay.buildOpenaiSession({}, false, 'x').session.tools, []);
});

test('speech speed is owner-tunable but never outside a sane range', () => {
  const speedOf = (openaiSpeed) =>
    voiceRelay.buildOpenaiSession({ openaiSpeed }, false, 'x').session.audio.output.speed;
  assert.equal(speedOf(0.9), 0.9);
  assert.equal(speedOf(1.15), 1.15);
  // Мусор и крайности не должны превращать секретаря в скороговорку.
  assert.equal(speedOf(undefined), 1);
  assert.equal(speedOf('быстро'), 1);
  assert.equal(speedOf(0), 1);
  assert.equal(speedOf(3), 1);
});

test('conversation items use the strict GA content types in both directions', (t) => {
  const call = openaiCall(t);
  call.ready();
  // Реплика секретаря обязана быть output_text: на 'text' GA отвечает
  // «Invalid value», и история при обрыве потока не переносится.
  call.session.history = [
    { role: 'user', text: 'My dryer is dead.' },
    { role: 'assistant', text: 'What brand is it?' },
  ];
  call.session.needsContinue = true;
  call.session.greeted = false;
  voiceRelay.greetLive(call.session);
  const items = call.current().sent
    .filter((m) => m.type === 'conversation.item.create')
    .map((m) => [m.item.role, m.item.content[0].type]);
  assert.ok(items.some(([role, type]) => role === 'assistant' && type === 'output_text'));
  assert.ok(items.every(([role, type]) => (role === 'user' ? type === 'input_text' : type === 'output_text')));
});

function openaiCall(t, overrides = {}) {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  const sockets = [];
  const geminiSockets = [];
  const writes = [];
  const twilio = {
    readyState: WebSocket.OPEN, closed: false, sent: [],
    send(raw) { this.sent.push(JSON.parse(raw)); },
    close() { this.closed = true; this.readyState = WebSocket.CLOSED; },
  };
  voiceRelay.init({
    geminiApiKey: 'test-gemini-key',
    openaiApiKey: 'test-openai-key',
    openOpenaiSocket: () => {
      const ws = new FakeGeminiSocket();
      sockets.push(ws);
      return ws;
    },
    openGeminiSocket: () => {
      const ws = new FakeGeminiSocket();
      geminiSockets.push(ws);
      return ws;
    },
    callsRef: {
      doc: () => ({
        get: async () => ({ exists: false }),
        set: async (data) => { writes.push(structuredClone(data)); },
      }),
    },
    mergeExtracted: (prev) => ({ ...(prev || {}) }),
    normalizePhone: (phone) => String(phone || '').replace(/\D/g, '').slice(-10),
    hasEnoughForJob: () => false,
    appendTranscript: (current, line) => [current, line].filter(Boolean).join('\n'),
    generateVoiceContent: async () => ({ response: { text: () => '{}' } }),
    extractJsonObject: (raw) => JSON.parse(raw),
    ...overrides,
  });
  t.after(() => voiceRelay.init(null));
  const session = {
    callSid: 'CA-openai-test', fromNumber: '+15195550100', streamSid: 'MZ-openai-test',
    history: [], extracted: {}, turns: 0, twilioWs: twilio, outLeftover: new Int16Array(0),
    userPartial: '', assistantPartial: '', systemText: 'Shop rules.', startedAt: Date.now(),
    voiceProvider: 'openai', openaiVoice: 'coral',
  };
  voiceRelay._internals.startLiveSession(session);
  const current = () => sockets.at(-1);
  const ready = () => {
    current().readyState = WebSocket.OPEN;
    current().emit('open');
    current().server({ type: 'session.created' });
    current().server({ type: 'session.updated' });
  };
  const sarahSays = (text, audio) => {
    current().server({ type: 'response.created' });
    if (audio) current().server({ type: 'response.audio.delta', delta: audio });
    current().server({ type: 'response.audio_transcript.done', transcript: text });
    current().server({ type: 'response.done' });
  };
  const callerSays = (text) => current().server({
    type: 'conversation.item.input_audio_transcription.completed', transcript: text,
  });
  const media = () => twilio.sent.filter((m) => m.event === 'media');
  const types = () => current().sent.map((m) => m.type);
  const tick = (ms) => t.mock.timers.tick(ms);
  const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
  return {
    session, sockets, geminiSockets, twilio, writes, current, ready,
    sarahSays, callerSays, media, types, tick, flush,
  };
}

test('OpenAI: the session is configured, Sarah greets first, and her audio is cut into 20 ms frames', (t) => {
  const call = openaiCall(t);
  assert.equal(call.sockets.length, 1);
  call.ready();
  assert.equal(call.session.provider, 'openai');
  assert.equal(call.session.engine, 'openai-realtime');
  const update = call.current().sent.find((m) => m.type === 'session.update');
  assert.equal(update.session.instructions, 'Shop rules.');
  assert.deepEqual(update.session.audio.output.format, { type: 'audio/pcmu' });
  // Поздоровалась сама: элемент беседы с инструкцией плюс просьба ответить.
  const greeting = call.current().sent.find((m) => m.type === 'conversation.item.create');
  assert.match(greeting.item.content[0].text, /first greeting only/);
  assert.equal(greeting.item.role, 'user');
  assert.ok(call.types().includes('response.create'));

  // 170 байт — это один целый кадр и хвост в 10 байт. Хвост ждёт продолжения,
  // а не уезжает в Twilio коротким кадром (из-за них Twilio рвал поток 1006).
  call.current().server({ type: 'response.created' });
  call.current().server({ type: 'response.audio.delta', delta: Buffer.alloc(170, 0x7f).toString('base64') });
  assert.equal(call.media().length, 1);
  call.current().server({ type: 'response.audio.delta', delta: Buffer.alloc(140, 0x7f).toString('base64') });
  assert.equal(call.media().length, 1, '150 байт — всё ещё не кадр, ждём продолжения');
  call.current().server({ type: 'response.done' });
  // Конец реплики: остаток добивается тишиной, чтобы последние слова не повисли.
  assert.equal(call.media().length, 2);
  for (const frame of call.media()) {
    assert.equal(Buffer.from(frame.media.payload, 'base64').length, 160);
  }
});

test('OpenAI: transcripts land in the same history and transcript the JSON extractor reads', (t) => {
  const call = openaiCall(t);
  call.ready();
  call.sarahSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.callerSays('My washer is leaking.');
  call.sarahSays('Oh no — where is it leaking from?');
  assert.deepEqual(call.session.history, [
    { role: 'assistant', text: 'FixApplianceCA, this is Sarah — what can I do for you?' },
    { role: 'user', text: 'My washer is leaking.' },
    { role: 'assistant', text: 'Oh no — where is it leaking from?' },
  ]);
  assert.equal(
    call.session.transcription,
    'AI: FixApplianceCA, this is Sarah — what can I do for you?\n' +
      'Client: My washer is leaking.\n' +
      'AI: Oh no — where is it leaking from?'
  );
  assert.equal(call.session.turns, 1);
});

test('OpenAI: the caller\'s audio goes up untouched and barge-in clears both queues', (t) => {
  const call = openaiCall(t);
  call.ready();
  call.sarahSays('FixApplianceCA, this is Sarah — what can I do for you?');
  voiceRelay._internals.sendCallerAudio(call.session, LOUD_FRAME);
  const appended = call.current().sent.filter((m) => m.type === 'input_audio_buffer.append');
  // Родной mulaw от Twilio, без апсемплинга в 16 кГц.
  assert.deepEqual(appended.map((m) => m.audio), [LOUD_FRAME]);

  call.current().server({ type: 'response.created' });
  call.current().server({ type: 'response.audio.delta', delta: Buffer.alloc(400, 0x7f).toString('base64') });
  call.current().server({ type: 'input_audio_buffer.speech_started' });
  assert.ok(call.twilio.sent.some((m) => m.event === 'clear'));
  assert.ok(call.types().includes('response.cancel'));
  assert.equal(call.session.speaking, false);
  assert.equal(call.session.silenceStage, 0);
  // Хвост нарезчика тоже сброшен: обрывок прошлой фразы не доиграет.
  assert.equal(call.session.outMulaw.length, 0);
});

test('OpenAI: the same three tools run with the same two-step cancellation and are spoken back', async (t) => {
  const asked = [];
  const call = openaiCall(t, {
    checkServiceArea: async (place) => {
      asked.push(place);
      return { ok: true, inside: true, place: 'Ayr, ON' };
    },
  });
  call.ready();
  call.current().server({
    type: 'response.function_call_arguments.done',
    name: 'check_service_area', call_id: 'call-1', arguments: '{"place":"Ayr"}',
  });
  await call.flush();
  assert.deepEqual(asked, ['Ayr']);
  const output = call.current().sent.find((m) => m.item && m.item.type === 'function_call_output');
  assert.equal(output.item.call_id, 'call-1');
  assert.deepEqual(JSON.parse(output.item.output), { ok: true, inside: true, place: 'Ayr, ON' });
  // Результат надо озвучить сразу, иначе звонящий слышит паузу.
  assert.ok(call.types().lastIndexOf('response.create') > call.types().indexOf('conversation.item.create'));

  // Трубку она не кладёт ни на одном провайдере.
  call.current().server({
    type: 'response.function_call_arguments.done',
    name: 'end_call', call_id: 'call-2', arguments: '{}',
  });
  await call.flush();
  const refused = call.current().sent.filter((m) => m.item && m.item.call_id === 'call-2');
  assert.match(refused[0].item.output, /You cannot hang up/);
});

test('OpenAI: silence ladder and the deaf detector behave exactly as on Gemini', async (t) => {
  const call = openaiCall(t);
  const { SILENCE_CHECK_MS, SILENCE_GIVEUP_MS } = voiceRelay._internals.timing;
  call.ready();
  call.sarahSays('FixApplianceCA, this is Sarah — what can I do for you?');
  const ladder = () => call.current().sent
    .filter((m) => m.type === 'conversation.item.create')
    .map((m) => m.item.content[0].text)
    .filter((text) => /said anything|Still nothing/.test(text));
  call.tick(SILENCE_CHECK_MS);
  assert.equal(ladder().length, 1);
  assert.match(ladder()[0], /are you still there/);
  call.sarahSays('Hello — are you still there?');
  call.tick(SILENCE_GIVEUP_MS);
  assert.equal(ladder().length, 2);
  assert.match(ladder()[1], /trouble hearing them/);
});

test('OpenAI: a deaf session (caller audibly talks, nothing heard) is handed to Gemini', (t) => {
  const deaf = openaiCall(t);
  const { SILENCE_CHECK_MS } = voiceRelay._internals.timing;
  deaf.ready();
  deaf.sarahSays('FixApplianceCA, this is Sarah — what can I do for you?');
  deaf.tick(1000);
  for (let at = 0; at < 2000; at += 20) {
    voiceRelay._internals.sendCallerAudio(deaf.session, LOUD_FRAME);
    deaf.tick(20);
  }
  deaf.tick(SILENCE_CHECK_MS - 3000);
  assert.equal(deaf.geminiSockets.length, 1, 'switched from OpenAI to Gemini');
  assert.equal(deaf.sockets.length, 1, 'and did not try OpenAI again');
  assert.equal(deaf.session.provider, 'gemini');
  deaf.geminiSockets[0].readyState = WebSocket.OPEN;
  deaf.geminiSockets[0].emit('open');
  assert.equal(
    deaf.geminiSockets[0].sent.find((m) => m.setup).setup.model,
    'models/gemini-3.8-live'
  );
});

test('OpenAI: a dropped session switches to Gemini after the second failure in a row', (t) => {
  const call = openaiCall(t);
  call.ready();
  call.sarahSays('FixApplianceCA, this is Sarah — what can I do for you?');
  call.current().drop(1011);
  call.tick(200);
  // Первый обрыв — пробуем того же провайдера ещё раз.
  assert.equal(call.sockets.length, 2);
  assert.equal(call.geminiSockets.length, 0);
  call.ready();
  call.current().drop(1011);
  call.tick(200);
  assert.equal(call.geminiSockets.length, 1);
  assert.equal(call.session.provider, 'gemini');
  assert.equal(call.session.engine, 'gemini-live');
  const gemini = call.geminiSockets[0];
  gemini.readyState = WebSocket.OPEN;
  gemini.emit('open');
  gemini.server({ setupComplete: {} });
  // Разговор переносится текстом, а не начинается заново.
  const carried = JSON.stringify(gemini.sent.filter((m) => m.clientContent));
  assert.match(carried, /this is Sarah/);
  assert.match(carried, /Same caller, not a new call/);
});

test('OpenAI: a session the server refuses falls through to the next provider', (t) => {
  const call = openaiCall(t);
  call.current().readyState = WebSocket.OPEN;
  call.current().emit('open');
  call.current().server({ type: 'error', error: { message: 'Unsupported model' } });
  // Сокет закрыт, но цепочка обязана продолжиться, а не оставить звонок немым.
  assert.equal(call.sockets.length + call.geminiSockets.length, 2);
  assert.equal(call.geminiSockets.length, 1);
});

test('bad stream keys are still rejected before starting Gemini', { timeout: 5000 }, async (t) => {
  const oldKey = process.env.VOICE_RELAY_KEY;
  process.env.VOICE_RELAY_KEY = 'relay-test-key';
  t.after(() => {
    if (oldKey === undefined) delete process.env.VOICE_RELAY_KEY;
    else process.env.VOICE_RELAY_KEY = oldKey;
  });
  const { port } = await relayServer(t);
  const { ws } = await connect(t, port);
  const closed = once(ws, 'close');
  ws.send(JSON.stringify({
    event: 'start',
    start: { streamSid: 'MZ-test', customParameters: { k: 'invalid-test-key' } },
  }));
  const [code, reason] = await closed;
  assert.equal(code, 1008);
  assert.equal(reason.toString(), 'unauthorized');
});
