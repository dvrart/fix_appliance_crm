const { WebSocket, WebSocketServer } = require('ws');
const {
  mulawToPcm16,
  pcm16ToMulaw,
  upsample8kTo16k,
  downsampleTo8k,
  int16ToBase64,
  base64ToInt16,
  parsePcmRate,
} = require('./audio_codec');

let wss = null;
let deps = null;
const sessions = new Map();

const LIVE_MODELS = [
  process.env.GEMINI_LIVE_MODEL || 'gemini-3.1-flash-live-preview',
  'gemini-2.5-flash-native-audio-preview-12-2025',
  'gemini-2.5-flash-native-audio-preview-09-2025',
  'gemini-2.5-flash-live-preview',
];

function init(nextDeps) {
  deps = nextDeps;
}

function pick(obj, ...names) {
  if (!obj || typeof obj !== 'object') return undefined;
  for (const name of names) {
    if (obj[name] != null) return obj[name];
  }
  return undefined;
}

function sendJson(ws, payload) {
  if (!ws || ws.readyState !== 1) return;
  ws.send(JSON.stringify(payload));
}

function sendToken(ws, token, last) {
  sendJson(ws, {
    type: 'text',
    token: token || ' ',
    last: Boolean(last),
    interruptible: true,
    preemptible: true,
  });
}

function sendEnd(ws) {
  sendJson(ws, { type: 'end' });
}

function uniqueModels() {
  return [...new Set(LIVE_MODELS.map((name) => String(name || '').trim()).filter(Boolean))];
}

function geminiLiveUrl(apiKey) {
  return (
    'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta' +
    `.GenerativeService.BidiGenerateContent?key=${encodeURIComponent(apiKey)}`
  );
}

function liveSystemPrompt(profile, session) {
  const today = new Date().toISOString().slice(0, 10);
  return `You are a real receptionist on a live phone for ${profile.companyName}, appliance repair in Ontario.
The technician didn't pick up. You answered. Sound like a warm woman in a small shop — never an IVR, never a chatbot.

Caller phone (do not ask for it): ${session.fromNumber || 'unknown'}
Today: ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}

Owner rules:
${profile.instructions}

TALK LIKE A PERSON:
- Short spoken turns. Usually one sentence. Never more than two.
- Then STOP and listen. Do not fill silence with extra questions.
- Contractions: what's, that's, I'll, you're.
- If they already told you something, do not ask it again.
- First react like a human ("oh, the fridge isn't cooling"), then one missing thing.
- Never say: got it, I understand, please provide, I have noted, certainly, how may I assist, I am an AI.
- No lists. No "thank you for that information".
- When you have full name, address, what broke, AND a day or time: wrap up — "I'll pass this to the tech and he'll call you back to confirm." Then call end_call with createJob true.
- Angry caller: a person from the company will call within 30 minutes, then call end_call with createJob true.
- Outside Brant/Norfolk service area: we don't travel there, then call end_call with createJob false.
- Speak English unless they speak Russian.
- After you greet them, wait for them to talk. Do not keep talking.
- Do not greet until you are told the exact greeting.

When the conversation is finished, call the end_call tool.`;
}

function buildSetup(model, systemText, withTools, resumeHandle) {
  const setup = {
    model: model.startsWith('models/') ? model : `models/${model}`,
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: {
        voiceConfig: {
          prebuiltVoiceConfig: { voiceName: 'Aoede' },
        },
      },
    },
    systemInstruction: {
      parts: [{ text: systemText }],
    },
    inputAudioTranscription: {},
    outputAudioTranscription: {},
    realtimeInputConfig: {
      activityHandling: 'START_OF_ACTIVITY_INTERRUPTS',
      automaticActivityDetection: {
        disabled: false,
        startOfSpeechSensitivity: 'START_SENSITIVITY_HIGH',
        endOfSpeechSensitivity: 'END_SENSITIVITY_LOW',
        prefixPaddingMs: 200,
        silenceDurationMs: 900,
      },
    },
    sessionResumption: resumeHandle ? { handle: resumeHandle } : {},
    contextWindowCompression: {
      triggerTokens: 25000,
      slidingWindow: { targetTokens: 12000 },
    },
  };
  if (withTools) {
    setup.tools = [
      {
        functionDeclarations: [
          {
            name: 'end_call',
            description:
              'Hang up after you have said goodbye. Use when you collected enough repair details, the caller is outside the service area, they want to stop, or you promised a callback.',
            parameters: {
              type: 'OBJECT',
              properties: {
                createJob: {
                  type: 'BOOLEAN',
                  description: 'True if a repair visit should be created from this call',
                },
                reason: { type: 'STRING' },
              },
              required: ['createJob'],
            },
          },
        ],
      },
    ];
  }
  return { setup };
}

async function streamSpokenReply(ws, session, userText) {
  const { generateVoiceTextStream, spokenText, getAiAnswerSettings } = deps;
  const today = new Date().toISOString().slice(0, 10);
  const profile = await getAiAnswerSettings();
  const extracted = session.extracted || {};
  const history = (session.history || []).slice(-12);
  const prompt = `You are a real receptionist on a live phone for ${profile.companyName}, appliance repair in Ontario.
The technician didn't pick up. You answered. Sound like a warm woman in a small shop — never an IVR, never a chatbot.

Caller phone (do not ask for it): ${session.fromNumber || 'unknown'}
Today: ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}

Owner rules:
${profile.instructions}

TALK LIKE A PERSON:
- One short spoken turn. Usually one sentence. Never more than two.
- Then STOP and listen. Do not fill silence with extra questions.
- Contractions: what's, that's, I'll, you're.
- If they already told you something, do not ask it again.
- First react like a human ("oh, the fridge isn't cooling"), then one missing thing.
- Never say: got it, I understand, please provide, I have noted, certainly, how may I assist, I am an AI.
- No lists. No "thank you for that information".
- When you have full name, address, what broke, AND a day or time: wrap up — "I'll pass this to the tech and he'll call you back to confirm." No price, no exact ETA.
- Angry caller: a person from the company will call within 30 minutes, then stop.
- Outside Brant/Norfolk service area: we don't travel there, then stop.
- Speak English unless they speak Russian.

Facts so far: ${JSON.stringify(extracted)}
Conversation: ${JSON.stringify(history)}
Caller just said: ${userText}

Reply with ONLY the spoken words. No quotes, no JSON, no labels.`;

  let raw = '';
  let pending = '';
  await generateVoiceTextStream([{ text: prompt }], (chunk) => {
    raw += chunk;
    if (pending) sendToken(ws, pending, false);
    pending = chunk;
  });
  let text = spokenText(raw.replace(/^["']|["']$/g, ''), 'Go ahead.');
  if (pending) {
    sendToken(ws, pending, true);
  } else {
    sendToken(ws, text || 'Go ahead.', true);
  }
  return text;
}

function tryParseExtracted(rawText) {
  const { extractJsonObject } = deps;
  let raw = String(rawText || '').trim();
  if (raw.startsWith('```json')) raw = raw.slice(7);
  else if (raw.startsWith('```')) raw = raw.slice(3);
  if (raw.endsWith('```')) raw = raw.slice(0, -3);
  try {
    return extractJsonObject(raw.trim()) || {};
  } catch (_) {
    return {};
  }
}

async function extractFacts(session, userText, assistantText) {
  const { generateVoiceContent, mergeExtracted } = deps;
  const prompt = `From this appliance-repair phone call, extract fields. Use null if unknown.
appliance_type must be Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.
Return STRICT JSON only:
{"client_name":null,"address":null,"city":null,"postal_code":null,"appliance_type":null,"brand":null,"model":null,"problem_description":null,"scheduled_date":null,"scheduled_time":null,"notes":null,"done":false,"createJob":false}

done=true if we should hang up (enough info, outside area, angry callback, wrong number).
createJob=true if we should create a job (enough info OR angry with some details). Enough info = name + address + problem + day or time.

Known: ${JSON.stringify(session.extracted || {})}
Full conversation: ${JSON.stringify((session.history || []).slice(-16))}
Caller: ${userText}
You said: ${assistantText}`;

  const result = await generateVoiceContent([{ text: prompt }]);
  const parsed = tryParseExtracted(result.response.text());
  const extracted = mergeExtracted(session.extracted, parsed.extracted || parsed);
  if (session.fromNumber) extracted.client_phone = deps.normalizePhone(session.fromNumber);
  return {
    extracted,
    done: parsed.done === true,
    createJob: parsed.createJob === true,
  };
}

async function persistSession(session, extra) {
  const { callsRef } = deps;
  if (!session.callSid) return;
  await callsRef.doc(session.callSid).set(
    {
      answeredBy: 'ai',
      extractedData: session.extracted || {},
      transcription: session.transcription,
      aiReception: {
        history: session.history,
        extracted: session.extracted,
        language: session.language || 'en',
        turns: session.turns || 0,
        engine: session.engine || 'relay',
        done: Boolean(extra && extra.done),
        createJob: Boolean(extra && extra.createJob),
        liveFailed: false,
      },
    },
    { merge: true }
  );
}

function closeGemini(session) {
  if (session.geminiPing) {
    clearInterval(session.geminiPing);
    session.geminiPing = null;
  }
  const ws = session.geminiWs;
  session.geminiWs = null;
  session.ready = false;
  session.socketGen = (session.socketGen || 0) + 1;
  if (!ws) return;
  try {
    if (ws.readyState === 1) ws.close();
    else ws.terminate();
  } catch (_) {}
}

function closeTwilio(session) {
  const ws = session.twilioWs;
  if (!ws) return;
  try {
    if (ws.readyState === 1) ws.close();
  } catch (_) {}
}

function markLiveFailed(session, reason) {
  session.liveFailed = true;
  const { callsRef } = deps;
  if (!session.callSid || !callsRef) return Promise.resolve();
  console.warn(`voiceLive failed ${session.callSid}: ${reason}`);
  return callsRef
    .doc(session.callSid)
    .set({ aiReception: { liveFailed: true, liveError: String(reason || '').slice(0, 240) } }, { merge: true })
    .catch(() => {});
}

function scheduleHangup(session, ms) {
  if (session.closed || session.hangupTimer) return;
  session.hangupTimer = setTimeout(() => {
    session.hangupTimer = null;
    if (session.closed) return;
    session.closed = true;
    closeGemini(session);
    closeTwilio(session);
  }, ms);
}

function sendTwilioClear(session) {
  if (!session.streamSid) return;
  sendJson(session.twilioWs, { event: 'clear', streamSid: session.streamSid });
  session.outLeftover = new Int16Array(0);
}

function sendTwilioAudio(session, pcm, sampleRate) {
  if (!session.streamSid || session.closed) return;
  const { pcm8, leftover } = downsampleTo8k(pcm, sampleRate, session.outLeftover);
  session.outLeftover = leftover;
  if (!pcm8.length) return;
  sendJson(session.twilioWs, {
    event: 'media',
    streamSid: session.streamSid,
    media: { payload: pcm16ToMulaw(pcm8).toString('base64') },
  });
}

function forwardMulawToGemini(session, payload) {
  if (!session.geminiWs || session.geminiWs.readyState !== 1) return false;
  const mulaw = Buffer.from(payload, 'base64');
  if (!mulaw.length) return true;
  const pcm16 = upsample8kTo16k(mulawToPcm16(mulaw));
  sendJson(session.geminiWs, {
    realtimeInput: {
      audio: {
        data: int16ToBase64(pcm16),
        mimeType: 'audio/pcm;rate=16000',
      },
    },
  });
  return true;
}

function sendCallerAudio(session, payload) {
  if (!payload) return;
  if (!session.ready || !forwardMulawToGemini(session, payload)) {
    session.pendingAudio = session.pendingAudio || [];
    session.pendingAudio.push(payload);
    if (session.pendingAudio.length > 100) session.pendingAudio.shift();
  }
}

function flushPendingAudio(session) {
  const queued = session.pendingAudio || [];
  session.pendingAudio = [];
  for (const payload of queued) forwardMulawToGemini(session, payload);
}

function setPartial(session, field, text, finished) {
  const value = String(text || '').trim();
  if (!value) return;
  if (/[А-Яа-яЁё]/.test(value)) session.language = 'ru';
  session[field] = value;
  if (finished) flushPartial(session, field);
}

function flushPartial(session, field) {
  const text = String(session[field] || '').trim();
  session[field] = '';
  if (!text) return;
  const role = field === 'userPartial' ? 'user' : 'assistant';
  const history = session.history || [];
  const last = history[history.length - 1];
  if (last && last.role === role && last.text === text) return;
  session.history = [...history, { role, text }].slice(-24);
  session.transcription = deps.appendTranscript(
    session.transcription,
    role === 'user' ? `Client: ${text}` : `AI: ${text}`
  );
  if (role === 'user') session.turns = Number(session.turns || 0) + 1;
}

function flushPartials(session) {
  flushPartial(session, 'userPartial');
  flushPartial(session, 'assistantPartial');
}

function greetLive(session) {
  if (session.greeted || !session.ready || !session.geminiWs) return;
  session.greeted = true;
  const greeting = String(session.greeting || "Hi, you've reached us. How can I help?").trim();
  sendJson(session.geminiWs, {
    clientContent: {
      turns: [
        {
          role: 'user',
          parts: [
            {
              text: `The call just connected. Greet the caller now with exactly this, then wait silently: ${greeting}`,
            },
          ],
        },
      ],
      turnComplete: true,
    },
  });
}

function handleLiveToolCall(session, message) {
  const toolCall = pick(message, 'toolCall', 'tool_call') || {};
  const calls = pick(toolCall, 'functionCalls', 'function_calls') || [];
  if (!calls.length) return;
  const responses = [];
  for (const call of calls) {
    const name = pick(call, 'name') || '';
    const id = pick(call, 'id') || '';
    const args = pick(call, 'args', 'arguments') || {};
    if (name === 'end_call') {
      session.wantHangup = true;
      if (args.createJob === true) session.createJob = true;
      if (args.createJob === false) session.createJob = false;
    }
    responses.push({
      id,
      name,
      response: { result: name === 'end_call' ? 'ok, hang up after goodbye' : 'ok' },
    });
  }
  sendJson(session.geminiWs, { toolResponse: { functionResponses: responses } });
  if (session.wantHangup) scheduleHangup(session, 1600);
}

async function handleLiveTurnComplete(session) {
  flushPartials(session);
  if (session.extracting) return;
  session.extracting = true;
  try {
    const lastUser = [...(session.history || [])].reverse().find((item) => item && item.role === 'user');
    const lastAsst = [...(session.history || [])].reverse().find((item) => item && item.role === 'assistant');
    if (!lastUser && !lastAsst) return;
    const facts = await extractFacts(
      session,
      (lastUser && lastUser.text) || '',
      (lastAsst && lastAsst.text) || ''
    );
    session.extracted = facts.extracted;
    session.createJob =
      session.createJob || facts.createJob || deps.hasEnoughForJob(session.extracted);
    await persistSession(session, {
      done: Boolean(session.wantHangup),
      createJob: session.createJob,
    });
  } catch (error) {
    console.warn('voiceLive extract:', error.message);
  } finally {
    session.extracting = false;
  }
}

function handleGeminiMessage(session, raw) {
  let message;
  try {
    message = JSON.parse(String(raw));
  } catch (_) {
    return;
  }
  if (message.error) {
    const text = String((message.error && message.error.message) || message.error);
    session.geminiError = text;
    console.warn(`voiceLive gemini error ${session.callSid}: ${text}`);
    if (!session.ready) closeGemini(session);
    return;
  }
  const resumeUpdate = pick(message, 'sessionResumptionUpdate', 'session_resumption_update');
  if (resumeUpdate) {
    const handle = pick(resumeUpdate, 'newHandle', 'new_handle');
    if (handle) session.resumeHandle = handle;
  }
  if (pick(message, 'setupComplete', 'setup_complete')) {
    session.ready = true;
    session.liveStarted = true;
    session.resumeAttempts = 0;
    flushPendingAudio(session);
    greetLive(session);
    return;
  }
  const content = pick(message, 'serverContent', 'server_content') || {};
  if (pick(content, 'interrupted') === true) {
    sendTwilioClear(session);
  }
  const input = pick(content, 'inputTranscription', 'input_transcription');
  if (input && input.text) {
    setPartial(session, 'userPartial', input.text, input.finished === true);
  }
  const output = pick(content, 'outputTranscription', 'output_transcription');
  if (output && output.text) {
    setPartial(session, 'assistantPartial', output.text, output.finished === true);
  }
  const turn = pick(content, 'modelTurn', 'model_turn') || {};
  for (const part of turn.parts || []) {
    const inline = pick(part, 'inlineData', 'inline_data');
    if (!inline || !inline.data) continue;
    sendTwilioAudio(session, base64ToInt16(inline.data), parsePcmRate(inline.mimeType || inline.mime_type));
  }
  handleLiveToolCall(session, message);
  if (pick(content, 'turnComplete', 'turn_complete') === true) {
    handleLiveTurnComplete(session).catch((error) => {
      console.warn('voiceLive turn:', error.message);
    });
  }
  const goAway = pick(message, 'goAway', 'go_away');
  if (goAway) {
    const left = pick(goAway, 'timeLeft', 'time_left');
    console.log(`voiceLive goAway ${session.callSid} timeLeft=${left}`);
    resumeLive(session, 'goAway');
  }
}

function attachGeminiSocket(session, ws, model) {
  session.socketGen = (session.socketGen || 0) + 1;
  const socketGen = session.socketGen;
  ws.liveGen = socketGen;
  session.geminiWs = ws;
  session.geminiModel = model;
  session.geminiError = '';
  const setupTimer = setTimeout(() => {
    if (session.ready || ws.liveGen !== session.socketGen) return;
    session.geminiError = session.geminiError || 'setup timeout';
    try {
      ws.close();
    } catch (_) {}
  }, 8000);
  ws.on('open', () => {
    if (session.geminiPing) clearInterval(session.geminiPing);
    session.geminiPing = setInterval(() => {
      if (ws.readyState === 1) {
        try {
          ws.ping();
        } catch (_) {}
      }
    }, 20000);
    sendJson(ws, session.setupPayload);
  });
  ws.on('message', (raw) => {
    if (ws.liveGen !== session.socketGen) return;
    try {
      handleGeminiMessage(session, raw);
    } catch (error) {
      console.error('voiceLive gemini message:', error.message);
    }
  });
  ws.on('error', (error) => {
    if (ws.liveGen !== session.socketGen) return;
    session.geminiError = error.message || 'gemini socket error';
    console.warn(`voiceLive gemini socket ${session.callSid}: ${session.geminiError}`);
  });
  ws.on('close', (code) => {
    clearTimeout(setupTimer);
    if (session.geminiPing && ws.liveGen === session.socketGen) {
      clearInterval(session.geminiPing);
      session.geminiPing = null;
    }
    if (ws.liveGen !== session.socketGen) return;
    session.connecting = false;
    session.ready = false;
    if (session.geminiWs === ws) session.geminiWs = null;
    console.log(
      `voiceLive gemini close ${session.callSid} code=${code} started=${Boolean(session.liveStarted)}`
    );
    if (session.closed || session.wantHangup) return;
    if (!session.liveStarted) {
      if (typeof session.retryGemini === 'function') session.retryGemini();
      return;
    }
    setTimeout(() => resumeLive(session, `close ${code}`), 200);
  });
}

function resumeLive(session, reason) {
  if (session.closed || session.wantHangup) return;
  if (session.connecting) return;
  const apiKey = deps && deps.geminiApiKey;
  if (!apiKey) return;
  session.resumeAttempts = Number(session.resumeAttempts || 0) + 1;
  if (session.resumeAttempts > 12) {
    console.warn(`voiceLive resume gave up ${session.callSid} after ${reason}`);
    return;
  }
  const model = session.geminiModel || uniqueModels()[0];
  session.ready = false;
  session.connecting = true;
  session.greeted = true;
  const old = session.geminiWs;
  session.geminiWs = null;
  session.socketGen = (session.socketGen || 0) + 1;
  if (old) {
    try {
      old.close();
    } catch (_) {}
  }
  session.setupPayload = buildSetup(model, session.systemText, true, session.resumeHandle);
  console.log(
    `voiceLive resume ${session.callSid} ${reason} attempt=${session.resumeAttempts} handle=${Boolean(session.resumeHandle)}`
  );
  attachGeminiSocket(
    session,
    new WebSocket(geminiLiveUrl(apiKey), { perMessageDeflate: false }),
    model
  );
}

function startGeminiLive(session) {
  const apiKey = deps && deps.geminiApiKey;
  if (!apiKey) {
    markLiveFailed(session, 'GEMINI_API_KEY missing').then(() => closeTwilio(session));
    return;
  }
  const models = uniqueModels();
  let index = 0;
  let tools = true;
  session.retryGemini = () => {
    if (session.closed || session.ready || session.connecting || session.liveStarted) return;
    if (index >= models.length) {
      if (tools) {
        tools = false;
        index = 0;
      } else {
        markLiveFailed(session, session.geminiError || 'live model failed').then(() =>
          closeTwilio(session)
        );
        return;
      }
    }
    const model = models[index++];
    session.connecting = true;
    session.setupPayload = buildSetup(model, session.systemText, tools);
    console.log(`voiceLive connect ${session.callSid} ${model} tools=${tools}`);
    attachGeminiSocket(
      session,
      new WebSocket(geminiLiveUrl(apiKey), { perMessageDeflate: false }),
      model
    );
  };
  session.retryGemini();
}

async function hydrateCall(session, callSid, fromNumber) {
  const { callsRef, findClientByPhone } = deps;
  session.callSid = callSid || session.callSid;
  session.fromNumber = fromNumber || session.fromNumber;
  const snap = session.callSid ? await callsRef.doc(session.callSid).get() : null;
  const data = snap && snap.exists ? snap.data() || {} : {};
  const reception = data.aiReception || {};
  const known = await findClientByPhone(data.fromNumber || session.fromNumber);
  session.extracted = reception.extracted || {};
  session.history = Array.isArray(reception.history) ? reception.history : [];
  session.transcription = data.transcription || '';
  session.language = reception.language || 'en';
  session.turns = Number(reception.turns || 0);
  session.clientName = (known && (known.fullName || known.name)) || '';
  session.knownAddress = (known && (known.address || '')) || '';
  session.fromNumber = data.fromNumber || session.fromNumber;
  const lastGreeting = [...session.history].find((item) => item && item.role === 'assistant');
  if (lastGreeting && lastGreeting.text) session.greeting = lastGreeting.text;
  if (session.callSid) sessions.set(session.callSid, session);
}

async function onLiveStart(session, message) {
  const start = message.start || {};
  const custom = start.customParameters || {};
  session.streamSid = start.streamSid || message.streamSid;
  session.engine = 'gemini-live';
  await hydrateCall(session, custom.callSid || start.callSid, start.from || custom.from);
  if (custom.greeting) session.greeting = String(custom.greeting);
  const profile = await deps.getAiAnswerSettings();
  session.systemText = liveSystemPrompt(profile, session);
  if (session.twilioKeepalive) clearInterval(session.twilioKeepalive);
  session.twilioKeepalive = setInterval(() => {
    if (session.closed || !session.streamSid) return;
    sendJson(session.twilioWs, {
      event: 'mark',
      streamSid: session.streamSid,
      mark: { name: 'keep' },
    });
  }, 10000);
  startGeminiLive(session);
}

async function onLiveStop(session) {
  if (session.closed && session.finalized) return;
  session.closed = true;
  if (session.hangupTimer) {
    clearTimeout(session.hangupTimer);
    session.hangupTimer = null;
  }
  if (session.twilioKeepalive) {
    clearInterval(session.twilioKeepalive);
    session.twilioKeepalive = null;
  }
  flushPartials(session);
  closeGemini(session);
  if (session.liveFailed) return;
  try {
    const lastUser = [...(session.history || [])].reverse().find((item) => item && item.role === 'user');
    const lastAsst = [...(session.history || [])].reverse().find((item) => item && item.role === 'assistant');
    if (lastUser || lastAsst) {
      const facts = await extractFacts(
        session,
        (lastUser && lastUser.text) || '',
        (lastAsst && lastAsst.text) || ''
      );
      session.extracted = facts.extracted;
      session.createJob =
        session.createJob || facts.createJob || deps.hasEnoughForJob(session.extracted);
      session.wantHangup = session.wantHangup || facts.done;
    }
    await persistSession(session, {
      done: true,
      createJob: session.createJob || deps.hasEnoughForJob(session.extracted),
    });
    session.finalized = true;
  } catch (error) {
    console.warn('voiceLive stop:', error.message);
  }
}

async function onRelayMessage(ws, session, message) {
  const { callsRef, appendTranscript, hasEnoughForJob, findClientByPhone } = deps;
  if (message.type === 'setup') {
    session.callSid = message.callSid;
    session.fromNumber = message.from || session.fromNumber;
    const custom = message.customParameters || {};
    if (custom.callSid) session.callSid = custom.callSid;
    const snap = session.callSid ? await callsRef.doc(session.callSid).get() : null;
    const data = snap && snap.exists ? snap.data() || {} : {};
    const reception = data.aiReception || {};
    const known = await findClientByPhone(data.fromNumber || session.fromNumber);
    session.extracted = reception.extracted || {};
    session.history = Array.isArray(reception.history) ? reception.history : [];
    session.transcription = data.transcription || '';
    session.language = reception.language || 'en';
    session.turns = Number(reception.turns || 0);
    session.clientName = (known && (known.fullName || known.name)) || '';
    session.knownAddress = (known && (known.address || '')) || '';
    session.fromNumber = data.fromNumber || session.fromNumber;
    session.engine = 'relay';
    sessions.set(session.callSid, session);
    console.log(`voiceRelay setup ${session.callSid}`);
    return;
  }

  if (message.type === 'interrupt') {
    session.gen += 1;
    return;
  }

  if (message.type === 'error') {
    console.error('voiceRelay twilio error:', message.description || message.message || message);
    return;
  }

  if (message.type !== 'prompt') return;
  const userText = String(message.voicePrompt || '').trim();
  if (!userText) return;
  if (message.last === false) return;

  const gen = (session.gen += 1);
  session.turns = Number(session.turns || 0) + 1;
  try {
    const say = await streamSpokenReply(ws, session, userText);
    if (gen !== session.gen) return;
    session.history = [
      ...(session.history || []),
      { role: 'user', text: userText },
      { role: 'assistant', text: say },
    ].slice(-20);
    session.transcription = appendTranscript(
      appendTranscript(session.transcription, `Client: ${userText}`),
      `AI: ${say}`
    );
    const facts = await extractFacts(session, userText, say);
    if (gen !== session.gen) return;
    session.extracted = facts.extracted;
    const done =
      facts.done ||
      session.turns >= 12 ||
      (facts.createJob && hasEnoughForJob(session.extracted));
    const createJob = facts.createJob || hasEnoughForJob(session.extracted);
    await persistSession(session, { done, createJob });
    if (done) {
      setTimeout(() => sendEnd(ws), 600);
    }
  } catch (error) {
    console.error('voiceRelay prompt:', error.message);
    if (gen === session.gen) {
      sendToken(ws, 'Sorry, I missed that — go ahead.', true);
    }
  }
}

async function onSocketMessage(ws, session, message) {
  if (message.event) {
    if (message.event === 'connected') return;
    if (message.event === 'start') {
      await onLiveStart(session, message);
      return;
    }
    if (message.event === 'media') {
      const track = message.media && message.media.track;
      if (track && track !== 'inbound') return;
      sendCallerAudio(session, (message.media && message.media.payload) || '');
      return;
    }
    if (message.event === 'stop') {
      await onLiveStop(session);
    }
    return;
  }
  await onRelayMessage(ws, session, message);
}

function handleSocket(ws) {
  const session = {
    gen: 0,
    history: [],
    extracted: {},
    turns: 0,
    twilioWs: ws,
    outLeftover: new Int16Array(0),
    userPartial: '',
    assistantPartial: '',
  };
  ws.on('message', async (raw) => {
    let message;
    try {
      message = JSON.parse(String(raw));
    } catch (_) {
      return;
    }
    try {
      await onSocketMessage(ws, session, message);
    } catch (error) {
      console.error('voiceRelay message:', error.message);
    }
  });
  ws.on('close', () => {
    session.closed = true;
    if (session.twilioKeepalive) {
      clearInterval(session.twilioKeepalive);
      session.twilioKeepalive = null;
    }
    closeGemini(session);
    if (session.callSid) sessions.delete(session.callSid);
  });
  ws.on('error', (error) => {
    console.error('voiceRelay socket:', error.message);
  });
}

function getWss() {
  if (wss) return wss;
  wss = new WebSocketServer({ noServer: true });
  wss.on('connection', (ws) => handleSocket(ws));
  return wss;
}

function handleRequest(req, res) {
  const incoming = req.rawRequest || req;
  const headers = incoming.headers || req.headers || {};
  const upgrade = String(headers.upgrade || '').toLowerCase();
  const host = String((req.get && req.get('host')) || headers.host || '');
  if (host.includes('run.app') && deps && deps.saveRelayHost) {
    deps.saveRelayHost(`wss://${host.split(',')[0].trim()}`).catch(() => {});
  }
  if (upgrade === 'websocket') {
    const server = getWss();
    server.handleUpgrade(incoming, incoming.socket, Buffer.alloc(0), (ws) => {
      server.emit('connection', ws, incoming);
    });
    return;
  }
  res.status(200).send('aiVoiceRelay');
}

module.exports = {
  init,
  handleRequest,
};
