const { WebSocket, WebSocketServer } = require('ws');
const { STATUS_CODES } = require('node:http');
const {
  mulawToPcm16,
  pcm16ToMulaw,
  upsample8kTo16k,
  downsampleTo8k,
  createLowPass,
  int16ToBase64,
  base64ToInt16,
  parsePcmRate,
  MULAW_SILENCE,
} = require('./audio_codec');
const voiceFacts = require('./voice_facts');

let wss = null;
let deps = null;
const sessions = new Map();

// ── Живой голос: два провайдера ────────────────────────────────────────────
// Основной — OpenAI Realtime (голос естественнее, и звук идёт в родном для
// Twilio g711_ulaw 8 кГц, без единого пересчёта частоты). Запасной — Gemini
// Live. Что выбрано, лежит в settings/ai_voice (см. getAiAnswerSettings в
// index.js); переменные окружения задают только значения по умолчанию.
//
// Gemini-модели, замер боевым промптом, время до первого звука:
//   3.8-live (03.11.2026)        setup ~550 мс, звук ~740 мс — основная у Gemini
//   2.5-native-audio-12-2025    ~1200 мс приветствие, ответ ~2 с (02.10.2026)
// 3.1-flash-live-preview была основной до 03.11.2026: Google выключает её и
// 2.5-native-audio-12-2025 не раньше 17.11.2026, замена — 3.8-live. После
// выключения 2.5 убрать из списка, иначе запасная попытка кончится 404.
// 2.5-…-09-2025 убрана: Google её больше не перечисляет.
const GEMINI_MODELS = [
  process.env.GEMINI_LIVE_MODEL || 'gemini-3.8-live',
  'gemini-2.5-flash-native-audio-preview-12-2025',
];

// Проверено живым сокетом 06.10.2026 нашим боевым setup: поднимаются
// gpt-realtime-mini и gpt-realtime, обе за ~0,4–1,0 с до session.updated.
// gpt-4o-mini-realtime-preview этому ключу уже недоступна, её в API нет —
// ставить её основной значило бы платить отказом за каждый звонок.
// Основная — полная: на mini FIX услышал «мягко, но неестественно», у полной
// заметно живее интонация. Дешёвая остаётся как 'gpt-realtime-mini' в
// настройке openaiModel, если захочется экономить.
const DEFAULT_OPENAI_MODEL = process.env.OPENAI_REALTIME_MODEL || 'gpt-realtime';
// Расшифровка речи звонящего. Живёт отдельно от голосовой модели.
const OPENAI_TRANSCRIBE_MODEL = 'gpt-4o-mini-transcribe';
// marin и cedar — самые живые из GA-голосов, проверены на нашем ключе
// 06.10.2026. coral был по умолчанию до 06.10.2026: в трубке он звучит мягко,
// но ненатурально, поэтому основным стал marin. Все варианты переключаются
// настройкой openaiVoice без выкатки.
const OPENAI_VOICES = ['marin', 'cedar', 'coral', 'sage', 'ash', 'shimmer', 'verse'];
const DEFAULT_OPENAI_VOICE = 'marin';
// Темп речи. 1 — как говорит модель сама; 0,9–0,95 звучит спокойнее, выше 1,1
// начинает частить. Меняется настройкой openaiSpeed, выкатка не нужна.
const OPENAI_SPEED_RANGE = [0.7, 1.3];
const DEFAULT_OPENAI_SPEED = 1;
// Zephyr звучит сухо; Aoede теплее. Остальные — на выбор из настроек.
const GEMINI_VOICES = ['Aoede', 'Kore', 'Leda', 'Zephyr'];
const DEFAULT_GEMINI_VOICE = 'Aoede';
const VOICE_PROVIDERS = ['openai', 'gemini'];
// Основной провайдер — Gemini Live (решение FIX, 06.10.2026: после прослушивания
// в трубке он ему ближе). OpenAI остаётся запасным и включается обратно одним
// полем voiceProvider в settings/ai_voice, без выкатки.
const DEFAULT_VOICE_PROVIDER = 'gemini';
// Как звонок подписан в Firestore. 'relay' — резервный Gather с фиксированным
// приветствием; index.js по этим же именам понимает, что звонок вёл живой голос.
const LIVE_ENGINE_BY_PROVIDER = { openai: 'openai-realtime', gemini: 'gemini-live' };
const LIVE_ENGINES = new Set(Object.values(LIVE_ENGINE_BY_PROVIDER));

/// Значение из настроек, но только из белого списка: опечатка в Firestore не
/// должна оставлять звонок без голоса.
function pickFrom(value, allowed, fallback) {
  const want = String(value || '').trim().toLowerCase();
  return allowed.find((item) => item.toLowerCase() === want) || fallback;
}

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
  return [...new Set(GEMINI_MODELS.map((name) => String(name || '').trim()).filter(Boolean))];
}

/// Цепочка попыток на один звонок: первый шаг — то, что выбрано в настройках,
/// дальше запасные. Откат симметричный: кто не выбран основным, встаёт в конец
/// очереди. Шаги провайдера без ключа в цепочку не попадают, поэтому ошибочная
/// настройка физически не может оставить звонок в тишине.
function buildLiveChain(session) {
  const openaiReady = Boolean(deps && deps.openaiApiKey);
  const geminiReady = Boolean(deps && deps.geminiApiKey);
  const openaiStep = {
    provider: 'openai',
    model: String((session && session.openaiModel) || '').trim() || DEFAULT_OPENAI_MODEL,
  };
  const geminiSteps = uniqueModels().map((model) => ({ provider: 'gemini', model }));
  // Значение по умолчанию разрешаем здесь же: иначе сессия без настройки
  // собирала бы цепочку не тем провайдером, чем заявлено в DEFAULT.
  const provider = pickFrom(
    session && session.voiceProvider,
    VOICE_PROVIDERS,
    DEFAULT_VOICE_PROVIDER
  );
  const wantsGemini = provider === 'gemini';
  const steps = [];
  if (wantsGemini) {
    if (geminiReady) steps.push(...geminiSteps);
    if (openaiReady) steps.push(openaiStep);
    return steps;
  }
  if (openaiReady) steps.push(openaiStep);
  if (geminiReady) steps.push(...geminiSteps);
  return steps;
}

function currentStep(session) {
  const chain = (session && session.liveChain) || [];
  if (!chain.length) return null;
  return chain[Math.min(Number(session.chainAt || 0), chain.length - 1)];
}

function hasNextLiveStep(session) {
  const chain = (session && session.liveChain) || [];
  return Number((session && session.chainAt) || 0) + 1 < chain.length;
}

/// Активный сокет живого голоса, какой бы провайдер его ни держал. На этом
/// держатся все страховки: они не должны знать, кто сейчас говорит.
function liveSocket(session) {
  if (!session) return null;
  return session.provider === 'openai' ? session.openaiWs : session.geminiWs;
}

function liveSocketOpen(session) {
  const ws = liveSocket(session);
  return Boolean(ws && ws.readyState === 1);
}

// Скорость реакции. Меняется переменными окружения, деплой функций без правки кода.
// Сколько тишины ждать, прежде чем решить, что звонящий договорил. Было 160 мс —
// и секретарь влезала на любой паузе («it's making, uh…»), а распознавание
// получало фразу кусками: в бою «it's Brad Smith» стало «Sí. ¿Es Brad Smith?».
// Прямой прогон 02.10.2026, «Hi, my name is … Brad Smith»: при 160 мс она
// перебила и имя пропало из расшифровки, при 500 мс фраза пришла целиком, а
// ответ начался через 1,1–1,3 с после последнего слова. Google советует
// 500–800 мс. Решение FIX — 0,5 с.
const SILENCE_MS = (() => {
  const raw = Number(process.env.VOICE_SILENCE_MS);
  return Number.isFinite(raw) && raw >= 120 && raw <= 1200 ? Math.round(raw) : 500;
})();
const END_SENSITIVITY =
  String(process.env.VOICE_END_SENSITIVITY || '').toUpperCase() === 'LOW'
    ? 'END_SENSITIVITY_LOW'
    : 'END_SENSITIVITY_HIGH';
// Сколько речи нужно, чтобы засчитать её начало: щелчок или кашель на линии не
// должен обрывать секретаря на полуслове.
const PREFIX_MS = 300;

// Страховка на случай, когда модель молчит после реплики клиента: её толкают
// заговорить. Толчок безусловно прерывает генерацию (у Gemini это clientContent
// с turnComplete, у OpenAI — новый элемент беседы и response.create). При
// 1100 мс он срезал её собственный ответ, который просто чуть задержался, и
// заставлял влезать, пока звонящий думает (в бою: «You sound like, um…» →
// «What can we help you with today?»). На 3 с толчок всё ещё прилетал в живую
// паузу: она обрывала фразу и начинала повторяться. С 06.10.2026 — 4,5 с, это
// заметно больше её обычной задержки ответа (~1,2 с). Лестницу тишины
// (10 с → 9 с → 30 с и 60 с на «подождите») это не трогает.
const STALL_MS = (() => {
  const raw = Number(process.env.VOICE_STALL_MS);
  return Number.isFinite(raw) && raw >= 600 && raw <= 8000 ? Math.round(raw) : 4500;
})();

// Тишина на линии. Сама модель на тишину не отвечает — её VAD ждёт голос, —
// поэтому лестницу ведёт релей (решение FIX, 02.10.2026): её реплика кончилась,
// звонящий молчит SILENCE_CHECK_MS → «Hello — are you still there?»; снова
// тишина SILENCE_GIVEUP_MS → «I can't hear you — please call back or text this
// number»; после этого SILENCE_HANGUP_MS тишины → кладём трубку. Любое слово
// звонящего возвращает лестницу в начало. «Hold on, let me check» — ждём дольше.
const SILENCE_CHECK_MS = 10000;
const SILENCE_HOLD_MS = 60000;
const SILENCE_GIVEUP_MS = 9000;
const SILENCE_HANGUP_MS = 30000;

// «Глухой» Live (01.10.2026, три звонка подряд): звонящий говорил, а Gemini не
// слышал ни слова и раз в 10–30 с рвал сокет с 1011. Громкость входящего звука
// релей видит сам: если за время «тишины» звонящий явно говорил (кадры по 20 мс
// с RMS ≥ VOICED_RMS, в сумме ≥ DEAF_VOICED_MS), это не тишина, а сбой модели —
// переходим на запасную. Порог — по записям звонков: шум линии RMS 2–100,
// речь — тысячи.
const VOICED_RMS = 900;
const DEAF_VOICED_MS = 1500;
// 3.1 присылает расшифровку звонящего только в конце его фразы, поэтому во
// время длинного рассказа релей узнаёт о речи лишь по громкости. Пока звонящий
// слышно говорил последние VOICE_QUIET_MS, тишину не объявляем и глухоту не
// решаем: здоровая модель отвечает через ~1,2 с после конца фразы.
const VOICE_QUIET_MS = 2500;

// Сколько обрывов Live терпим за звонок, прежде чем уйти в резервный Gather.
// Модель меняем после второго обрыва подряд на одной и той же.
const LIVE_FAILURE_LIMIT = 5;
const MODEL_FAILURES_TO_SWITCH = 2;

/// 2.5 Live думает по умолчанию (секунды тишины). 3.1 — через thinkingLevel.
function thinkingConfigFor(model) {
  const name = String(model || '').toLowerCase();
  // 3.1 Live already defaults to minimal thinking. Sending thinkingLevel
  // can fail setup on some revisions and leave the caller in silence.
  if (/gemini-3|3\.\d/.test(name)) return null;
  return { thinkingBudget: 0 };
}

/// 3.8 и новее вызывают инструменты асинхронно (NON_BLOCKING) по умолчанию:
/// модель продолжала бы говорить, не дождавшись календаря, а отмену визита
/// можно подтверждать только после ответа сервера. Поэтому им — BLOCKING.
/// Старым моделям поле не передаём: они его не знают.
function toolsNeedBlocking(model) {
  return !/gemini-3\.1|gemini-2\.|native-audio/.test(String(model || '').toLowerCase());
}

/// Эмоциональная подача (модель подстраивает интонацию под голос звонящего)
/// живёт только в native-audio и только на v1alpha. На v1beta тот же setup
/// закрывал сокет с 1007 «Unknown name enableAffectiveDialog», и запасной
/// модели у нас фактически не было. Выключается через GEMINI_AFFECTIVE=0.
function supportsAffectiveDialog(model) {
  if (String(process.env.GEMINI_AFFECTIVE || '').trim() === '0') return false;
  return /native-audio/.test(String(model || '').toLowerCase());
}

/// То же, но с памятью звонка: если попытка с флагом не дошла до готовности,
/// второй раз ту же модель поднимаем на v1beta и без него. Запасная модель
/// важнее интонации — остаться без голоса из-за украшения нельзя.
function affectiveFor(session, model) {
  if (session && session.noAffective) return false;
  return supportsAffectiveDialog(model);
}

function geminiLiveUrl(apiKey, affective) {
  const version = affective ? 'v1alpha' : 'v1beta';
  return (
    `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.${version}` +
    `.GenerativeService.BidiGenerateContent?key=${encodeURIComponent(apiKey)}`
  );
}

/// Сокет к Gemini. Тесты подставляют свой через deps.openGeminiSocket.
function openGeminiSocket(apiKey, model, affective) {
  if (deps && typeof deps.openGeminiSocket === 'function') {
    return deps.openGeminiSocket(apiKey, model, affective);
  }
  return new WebSocket(geminiLiveUrl(apiKey, affective), { perMessageDeflate: false });
}

/// Сокет к OpenAI Realtime. Тесты подставляют свой через deps.openOpenaiSocket.
/// Заголовка «OpenAI-Beta: realtime=v1» здесь нет намеренно: с ним сервер
/// отвечает «The Realtime Beta API is no longer supported» и рвёт сессию.
/// Проверено живым сокетом 06.10.2026.
function openOpenaiSocket(apiKey, model) {
  if (deps && typeof deps.openOpenaiSocket === 'function') {
    return deps.openOpenaiSocket(apiKey, model);
  }
  return new WebSocket(
    `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`,
    {
      headers: { Authorization: `Bearer ${apiKey}` },
      perMessageDeflate: false,
    }
  );
}

function outsideAreaRule(profile, thenWhat) {
  const area = String((profile && profile.serviceArea) || '').trim();
  if (!area) {
    return `- Do not refuse a caller based on town names from memory. Coverage comes from the owner's service-area map, and it is not set.`;
  }
  return `- Service area: ${area} An unfamiliar town is not a refusal — ask for the postal code and take the order. Only a plainly far city is outside: we don't travel there, then ${thenWhat}.`;
}

function compactKnown(session) {
  if (session && appointmentOnly(session)) {
    return `This call concerns an existing appointment, not a new repair. Recheck the current caller schedule; do not collect a new order. ${session.openJobBrief || ''}`;
  }
  const extracted = (session && session.extracted) || {};
  const have = [];
  if (extracted.client_name) have.push(`name ${extracted.client_name}`);
  if (extracted.address) {
    have.push(
      `${extracted.has_job_site ? 'repair at' : 'address'} ${extracted.address}${
        extracted.city ? `, ${extracted.city}` : ''
      }`
    );
  }
  if ((extracted.owner_address || session.knownAddress) && extracted.has_job_site) {
    have.push(`owner home ${extracted.owner_address || session.knownAddress}`);
  } else if (session.knownAddress && !extracted.address) {
    have.push(`home on file ${session.knownAddress}`);
  }
  if (extracted.appliance_type || extracted.brand) {
    have.push(
      `appliance ${[extracted.appliance_type, extracted.brand].filter(Boolean).join(' ')}`
    );
  }
  if (extracted.problem_description) have.push(`problem ${extracted.problem_description}`);
  const wish = [extracted.preferred_time, extracted.scheduled_date, extracted.scheduled_time].filter(Boolean).join(' ');
  if (wish) have.push(`would like ${wish} (a wish only — the technician confirms the time)`);
  if (extracted.wants_callback) have.push('live callback requested');
  if (extracted.has_job_site) {
    const who = [extracted.contact_on_site_name, extracted.contact_on_site_phone]
      .filter(Boolean)
      .join(' ');
    if (who) have.push(`on-site ${who}`);
  }
  const need = [];
  if (!extracted.client_name) need.push('first name');
  if (!extracted.problem_description) need.push('what broke');
  if (!extracted.appliance_type || !extracted.brand) need.push('kind and brand');
  if (!extracted.wants_callback && !wish) {
    need.push('what day and time would suit them (do not book — the technician will contact them)');
  }
  if (!extracted.wants_callback && !extracted.address) {
    need.push(
      session.knownAddress
        ? 'whether the repair is at the home on file or another address'
        : 'street and town of the repair'
    );
  }
  return `Already have: ${have.join('; ') || 'nothing yet'}. Still need: ${
    need.join(', ') || 'nothing — confirm, then ask if anything else'
  }.`;
}

function liveSystemPrompt(profile, session) {
  const today =
    (deps && deps.torontoTodayYmd && deps.torontoTodayYmd()) ||
    new Date().toISOString().slice(0, 10);
  const hours = profile.workHours || '7 a.m. to 9 p.m.';
  const visitDays = profile.workDaysLabel || 'Monday–Friday';
  const closedDays = profile.closedDaysLabel || '';
  const area = String((profile && profile.serviceArea) || '').trim();
  const name = voiceFacts.SECRETARY_NAME;
  const opening = session.greetingSpoken
    ? 'Hello already played. Do not greet again. Wait.'
    : `You pick up the phone. Greet like a real person in a small repair shop: your own words, a little different every time, warm and brisk. If you say a name, it is ${name}. Never a memorized slogan or a call-centre announcement. One short breath, then stop and wait.`;
  return `You are ${name}, answering the shop phone for FixApplianceCA. You sound like a real person in a small shop — not a script, not a form.

${opening} When they speak, first words are ordinary — a real reaction, then one easy follow-up. If they say the dryer is broken: "Oh no — what's it doing?" not their name, not the address.

Caller phone (do not ask): ${session.fromNumber || 'unknown'}
Today (Toronto): ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}
${session.openJobBrief || 'Caller schedule is not loaded. Do not guess whether there is a booking.'}
Visits: ${visitDays}, ${hours} Toronto. ${closedDays}
${profile.priceLine || ''}
${area ? `Service area: ${area}` : 'Service area map is not set — do not refuse from memory.'}
${profile.awayLine || ''}

${profile.instructions}

VOICE DELIVERY & NATURAL CADENCE (CRITICAL):
- You are Sarah, a real-sounding, warm, and empathetic front-desk coordinator at FixApplianceCA on a live phone call in Ontario.
- Speak with a relaxed, natural human cadence. Vary your pitch and intonation so you never sound monotone or like you are reading a checklist.
- Use brief, natural conversational reactions before asking the next question ("Oh, I see", "Got it, let me jot that down", "Oh no, a leaking washer is never fun — we can definitely help with that").
- STRICT ONE-QUESTION RULE: Ask only ONE short question per turn (1 to 2 sentences max), then stop and listen. Never stack multiple questions together.
- Read phone numbers and street numbers in natural conversational groups with slight pauses, never as a rapid robotic string.

LIVE CALENDAR — server facts take priority over any transcript or earlier snapshot:
- Before saying whether THIS caller has a visit, call get_caller_appointments and answer from its latest result. Shop-wide Taken/Open times are NOT this caller's bookings.
- If the caller schedule above shows a repair already on file, do not assume why they rang: ask once, in one short sentence, whether this call is about that repair or a separate new one, and open a new order only after they say it is new.
- Read the full date including the year. Cancelled, completed, deleted and past visits are not upcoming appointments. A provisional visit still needs technician review; do not call it confirmed.
- A lookup or cancellation is not a new repair order. Do not collect repair details or create a new job unless the caller explicitly asks for a separate repair.
- For cancellation, call cancel_appointment, ask its exact confirmation question, wait for the caller's explicit yes, then call it again with confirmed=true. Say it is cancelled ONLY after status=cancelled. On an error say you could not verify the change; never pretend it was saved.
- If there is more than one visit, ask which one. Never cancel another visit or every visit by guessing.
- You do NOT book new visits and cannot see the shop calendar. For a new repair ask what day and time would suit them and say the technician will contact them to set the exact time. Never say a time is free, taken, booked or confirmed. Existing-visit rescheduling must be agreed with the technician or handled by SMS; do not claim it has already been moved.
- Do not read internal job IDs or visit IDs aloud. Keep personal calendar event details private.

SERVICE AREA — the map decides, never your memory:
- The towns listed above are only the well-known ones. The zone also holds villages, hamlets and rural roads that are not named there.
- For any other place — a village, a postal code, a street address, a town you are unsure about — call check_service_area BEFORE you say anything about travelling there.
- inside=true: say yes, we come out there, and carry on with the order. inside=false: politely say we don't travel that far, done=true, createJob=false. inside=null: ask for the postal code, take the order anyway, and say the technician will confirm the trip.
- Never tell a caller we do not serve their place unless check_service_area answered inside=false.

HOW YOU SOUND — you are on a phone, not reading:
- Begin as soon as the caller finishes; never add a silent thinking beat before your first word. Once you are speaking, let the sentence breathe — do not rush to the end of it.
- Vary the delivery the way people actually do: some sentences short, some longer, the pitch rising and falling, a touch more warmth on good news and a touch more care on a problem. An even, evenly-paced voice is what makes a caller hear a machine.
- Keep the short human reaction and the answer in one flowing phrase. Never say "right" or "mm-hm" and then pause to plan the rest.
- Contractions always: what's, that's, you're, I'll, we've. Everyday words over formal ones.
- One thought per turn. If it needs two sentences, make the second one short.
- Never read a list aloud. Never repeat back the whole thing they just told you. The one exception: a name or address you did not catch for sure — ask again, and if needed have them spell it and read the letters back (see the names-and-addresses rule).
- If they pause to look something up, wait quietly. Do not fill the silence with chatter.
- Let them finish. If they trail off ("it's making, uh…"), give them a moment; do not jump in with the next question.

WHO YOU ARE:
- Your name is ${name}. Never use another name, and never introduce yourself as "she".
- Asked your name: "I'm ${name}" — warm, one line — then give the conversation back gently ("so, what's going on?"). Never answer a personal question with a checklist question like the brand or the address.
- Asked whether you are a real person, a human, a robot or an AI: be honest and light — "I'm ${name}, the shop's virtual assistant — I'll get all of this to the technician." Then carry on. Never claim to be human.

LINE TROUBLE:
- If they keep saying hello, say you're breaking up, or cannot hear you: answer in a few words ("Yes, I'm here — can you hear me?"). At most twice in the whole call; never repeat your whole question each time.
- If you still cannot hear each other: say once that you're having trouble hearing them and they can call back or text this number. Then wait quietly.
- If you were cut off mid-sentence, do not restart the same sentence word for word — give the point again in a few words.

You cannot hang up. After "Have a good day," wait. They hang up.`;
}

// Инструменты объявляются один раз и раздаются обоим провайдерам: разойдутся
// описания — разойдётся и поведение секретаря на запасном голосе.
const LIVE_TOOL_SPECS = [
  {
    name: 'get_caller_appointments',
    description: 'Read this caller\'s CURRENT appointments from the CRM. Always use before answering an appointment question; replaces all earlier snapshots. No other caller identity can be supplied.',
    properties: {},
    required: [],
  },
  {
    name: 'cancel_appointment',
    description: 'Cancel one existing appointment. First call stages the exact visit and asks for confirmation. Only call again with confirmed=true AFTER a new, explicit yes from the caller. Never claim cancellation until the tool returns status=cancelled.',
    properties: {
      job_id: { type: 'string', description: 'jobId from get_caller_appointments; do not invent.' },
      visit_id: { type: 'string', description: 'visitId from get_caller_appointments; do not invent.' },
      confirmed: { type: 'boolean', description: 'True only after the caller confirmed the staged cancellation in a separate turn.' },
    },
    required: [],
  },
  {
    name: 'check_service_area',
    description: 'Ask the map whether a place is inside the technician\'s service area. Use it for any town, village, postal code or address you are not sure about, before saying anything about travelling there. Never answer coverage from memory.',
    properties: {
      place: {
        type: 'string',
        description: 'What the caller said: a town, a hamlet, a postal code, or a full street address. Ontario is assumed.',
      },
    },
    required: ['place'],
  },
];

const GEMINI_TOOL_TYPES = { string: 'STRING', boolean: 'BOOLEAN', number: 'NUMBER' };

function geminiToolDeclarations(model) {
  const blocking = toolsNeedBlocking(model) ? { behavior: 'BLOCKING' } : {};
  return LIVE_TOOL_SPECS.map((spec) => {
    const keys = Object.keys(spec.properties);
    const declaration = { name: spec.name, description: spec.description, ...blocking };
    if (!keys.length) return declaration;
    return {
      ...declaration,
      parameters: {
        type: 'OBJECT',
        properties: Object.fromEntries(
          keys.map((key) => [
            key,
            {
              type: GEMINI_TOOL_TYPES[spec.properties[key].type] || 'STRING',
              description: spec.properties[key].description,
            },
          ])
        ),
        ...(spec.required.length ? { required: [...spec.required] } : {}),
      },
    };
  });
}

function openaiToolDeclarations() {
  return LIVE_TOOL_SPECS.map((spec) => ({
    type: 'function',
    name: spec.name,
    description: spec.description,
    parameters: {
      type: 'object',
      properties: structuredClone(spec.properties),
      required: [...spec.required],
    },
  }));
}

function buildSetup(model, systemText, withTools, resumeHandle, options = {}) {
  const thinkingConfig = thinkingConfigFor(model);
  const voiceName = pickFrom(options.voice, GEMINI_VOICES, DEFAULT_GEMINI_VOICE);
  const setup = {
    model: model.startsWith('models/') ? model : `models/${model}`,
    generationConfig: {
      responseModalities: ['AUDIO'],
      ...(thinkingConfig ? { thinkingConfig } : {}),
      speechConfig: {
        languageCode: 'en-US',
        voiceConfig: {
          prebuiltVoiceConfig: { voiceName },
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
        // Сколько ждать после того, как звонящий замолчал (см. SILENCE_MS).
        // Если начнёт перебивать тех, кто ищет шильдик — поднять
        // VOICE_SILENCE_MS до 600–700 или вернуть VOICE_END_SENSITIVITY=LOW.
        endOfSpeechSensitivity: END_SENSITIVITY,
        prefixPaddingMs: PREFIX_MS,
        silenceDurationMs: SILENCE_MS,
      },
    },
    sessionResumption: resumeHandle ? { handle: resumeHandle } : {},
    // Audio is ~25 tokens/s. Old 8k trigger (~5 min) froze her mid-word.
    // Compress only on long calls; keep a large recent window so the chat continues.
    contextWindowCompression: {
      triggerTokens: 64000,
      slidingWindow: { targetTokens: 32000 },
    },
  };
  // Эмоциональная подача — только там, где сервер её знает (native-audio на
  // v1alpha). Если флаг всё-таки не примут, релей снимет его и поднимет ту же
  // модель заново: запасная обязана подниматься всегда.
  const affective = options.affective === undefined
    ? supportsAffectiveDialog(model)
    : Boolean(options.affective);
  if (affective) setup.enableAffectiveDialog = true;
  if (withTools) {
    setup.tools = [{ functionDeclarations: geminiToolDeclarations(model) }];
  }
  return { setup };
}

/// Настройка сессии OpenAI Realtime, схема GA (проверена живым сокетом
/// 06.10.2026). Звук в обе стороны — `audio/pcmu`, то есть родной для Twilio
/// g711 μ-law 8 кГц: ни одного пересчёта частоты, ни одного артефакта от
/// ресемплинга. Пороги VAD те же, что у Gemini (PREFIX_MS / SILENCE_MS), чтобы
/// паузы звонящего слушались одинаково на обоих провайдерах.
///
/// Чего здесь нет и почему: `temperature` в GA-сессии не существует — сервер
/// отвечает «Unknown parameter: 'session.temperature'» и отбивает весь setup.
/// Манеру речи задаёт промпт (блок VOICE DELIVERY), а не температура.
function buildOpenaiSession(session, withTools, instructions) {
  const voice = pickFrom(session && session.openaiVoice, OPENAI_VOICES, DEFAULT_OPENAI_VOICE);
  const asked = Number(session && session.openaiSpeed);
  const speed = Number.isFinite(asked) && asked >= OPENAI_SPEED_RANGE[0] && asked <= OPENAI_SPEED_RANGE[1]
    ? asked
    : DEFAULT_OPENAI_SPEED;
  return {
    type: 'session.update',
    session: {
      type: 'realtime',
      output_modalities: ['audio'],
      instructions: String(instructions || (session && session.systemText) || ''),
      audio: {
        input: {
          format: { type: 'audio/pcmu' },
          transcription: { model: OPENAI_TRANSCRIBE_MODEL, language: 'en' },
          turn_detection: {
            type: 'server_vad',
            threshold: 0.6,
            prefix_padding_ms: PREFIX_MS,
            silence_duration_ms: SILENCE_MS,
            create_response: true,
            // Сервер сам гасит её реплику, когда звонящий заговорил. Наш
            // response.cancel на speech_started остаётся второй подстраховкой.
            interrupt_response: true,
          },
        },
        output: { format: { type: 'audio/pcmu' }, voice, speed },
      },
      tools: withTools ? openaiToolDeclarations() : [],
      tool_choice: 'auto',
    },
  };
}

async function streamSpokenReply(ws, session, userText) {
  const { generateVoiceTextStream, spokenText, getAiAnswerSettings } = deps;
  if (deps.nextAiVoiceTurn && (session.pendingCancellation || /\b(cancel|cancelled|canceled|reschedule|appointment|booking)\b|отмен|встреч|перенос/i.test(userText))) {
    const reply = await deps.nextAiVoiceTurn(session.callSid, {
      fromNumber: session.fromNumber, clientId: session.clientId,
      aiReception: {
        history: session.history, extracted: session.extracted,
        appointmentOnly: session.appointmentOnly, pendingCancellation: session.pendingCancellation,
      },
    }, userText);
    session.extracted = reply.extracted || session.extracted;
    session.appointmentOnly = reply.appointmentOnly === true;
    session.pendingCancellation = reply.pendingCancellation || null;
    const say = spokenText(reply.say, "I can't verify that right now. Please text us so we can check it.");
    sendToken(ws, say, true);
    return say;
  }
  if (deps.voiceOpenJobBrief) session.openJobBrief = await deps.voiceOpenJobBrief({ phone: session.fromNumber, clientId: session.clientId });
  const today =
    (deps.torontoTodayYmd && deps.torontoTodayYmd()) || new Date().toISOString().slice(0, 10);
  const profile = await getAiAnswerSettings();
  const extracted = session.extracted || {};
  const history = (session.history || []).slice(-12);
  const flow = deps.voiceCallFlow || '';
  const prompt = `You are a real woman on the shop phone for ${profile.companyName}. Not a form.

Caller: ${session.fromNumber || 'unknown'}
Today (Toronto): ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}
${session.openJobBrief || 'Caller schedule is not loaded. Do not guess whether there is a booking.'}
Visits: ${profile.workDaysLabel || 'Monday–Friday'}, ${profile.workHours || '7 a.m. to 9 p.m.'}

${profile.instructions}

${flow}

First words are ordinary: react like a person, then one easy follow-up. Do not greet again.

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
  const today =
    (deps.torontoTodayYmd && deps.torontoTodayYmd()) || new Date().toISOString().slice(0, 10);
  const prompt = `From this appliance-repair phone call, extract fields. Use null if unknown.
${voiceFacts.EXTRACT_CARD_RULES}
appliance_type must be Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.
brand: the make they named (Samsung, LG, Whirlpool, GE, Bosch…). Never invent a brand. Not the model number.
Today is ${today} in America/Toronto.
preferred_time: when the caller would like the visit, in their own words, short English ("Wednesday after 2 p.m.", "any weekday morning"). A wish only — nothing is booked on this call.
scheduled_date must be YYYY-MM-DD. "tomorrow" = the next calendar day after ${today}. Never leave the date empty if they named a day. If they did not name a day ("whenever", "any time", "whatever suits the technician"), scheduled_date=null — never default to today.
scheduled_time must be HH:mm 24-hour. "11:00", "at 11", "eleven o'clock" → 11:00. A bare "2", "at 2", "two", "around two" on a repair call → 14:00. But if they said a.m. or morning, keep the hour exactly as spoken: "10 a.m." → 10:00, NEVER 22:00. Only add 12 hours when they said p.m., afternoon, or evening about that same hour. Never leave time empty if they named a clock time.
client_name: the CALLER's own short given name as they said it (Amelia, David). Only from "Caller" turns or the caller's answer to "what's your name?" — never a name you (the assistant, ${voiceFacts.SECRETARY_NAME}) said about yourself, and never the technician the caller asks for. NEVER a phonetic mash. NEVER a mood, filler or ordinary word: good, fine, okay, thanks, well, sure, ready, here, she. "I'm good" / "are you ready?" is not a name. If they already said a real first name, keep that spelling. If the caller spelled it letter by letter or corrected you, use the spelled / corrected version (same for street and city).
address: the REPAIR address (where the technician drives). Street number + street name. null if mumbled.
owner_address: the caller's home if it is different from the repair address.
has_job_site=true if the repair is not at the caller's own home (tenant, rental, another house).
If the spoken street is not the known home, has_job_site=true, address=repair place, owner_address=home.
contact_on_site_name / contact_on_site_phone: ONLY if the caller names a DIFFERENT person who will be at the repair address, with that person's name and/or phone. "I'll be there", "me", "just me", or "my husband" without a name → null. The caller's own name is not an on-site contact.
wants_callback=true if they asked to speak to a live person, the technician, the master, or to get a call back from a human. After that, do not treat missing time as incomplete.
appointment_intent: lookup, cancel, reschedule, new_repair, or none. Use new_repair ONLY if the CALLER explicitly requested a separate new repair, never from the assistant reading existing job facts. An appointment lookup/cancellation/reschedule is not a new order: createJob=false. Dates mentioned in an old booking or a cancellation are NOT a new scheduled_date/time.
service_declined=true if we cannot take a NEW job: outside the service area, not a household appliance (laptop/computer/phone), or we told them we don't do that work. Then createJob=false. Cancellation of an existing visit is handled by the calendar tool, not by this flag. A Freon / refrigerant question is a normal fridge or freezer repair — never declined.
Return STRICT JSON only:
{"appointment_intent":"none","client_name":null,"address":null,"city":null,"postal_code":null,"owner_address":null,"appliance_type":null,"brand":null,"model":null,"problem_description":null,"scheduled_date":null,"scheduled_time":null,"preferred_time":null,"wants_callback":false,"has_job_site":false,"contact_on_site_name":null,"contact_on_site_phone":null,"notes":null,"service_declined":false,"decline_reason":null,"done":false,"createJob":false}

done=true ONLY if the caller said goodbye/bye/that's all, or they declined "anything else". Never because they said thanks, okay, or yes. Never for a laptop, computer, or something we don't repair.
createJob=true if we should create a repair job (enough info OR live callback OR angry with some details). NEVER if service_declined. Not for a laptop/computer unless they also have a household appliance.
Enough info for a job = first name + address + problem + type/brand. The time they would like is nice to have; the technician sets the actual visit.
Live callback = createJob true even without address or time. Do not wait for model, serial, or where the appliance sits.

Known: ${JSON.stringify(session.extracted || {})}
Full conversation: ${JSON.stringify((session.history || []).slice(-24))}
Caller: ${userText}
You said: ${assistantText}`;

  const result = await generateVoiceContent([{ text: prompt }]);
  const parsed = tryParseExtracted(result.response.text());
  const extracted = mergeExtracted(
    session.extracted,
    parsed.extracted || parsed,
    session.history
  );
  if (session.fromNumber) extracted.client_phone = deps.normalizePhone(session.fromNumber);
  const callback = extracted.wants_callback === true;
  const declined = voiceFacts.isServiceDeclined(extracted);
  const goodbye = voiceFacts.saidGoodbye(assistantText);
  const lastUser = userText;
  const allowed = voiceFacts.mayHangUp({
    extracted,
    lastUser,
    lastAsst: assistantText,
    hasEnough: deps.hasEnoughForJob,
    turns: session.turns,
    history: session.history,
  });
  return {
    extracted,
    done: allowed,
    createJob: !declined && (parsed.createJob === true || callback),
    serviceDeclined: declined,
  };
}

async function persistSession(session, extra) {
  const { callsRef } = deps;
  if (!session.callSid) return;
  // У живого голоса (любого провайдера) приветствие импровизируется, и в
  // историю попадает то, что она сказала на самом деле. Шаблон дописываем
  // только резервному Gather с фиксированной фразой в <Say>.
  const greeting = LIVE_ENGINES.has(session.engine) ? '' : String(session.greeting || '').trim();
  if (greeting) {
    const history = session.history || [];
    const already = history.some(
      (item) => item && item.role === 'assistant' && isSameVoiceLine(item.text, greeting)
    );
    if (!already) {
      session.history = [{ role: 'assistant', text: greeting }, ...history];
    }
    const trans = String(session.transcription || '').trim();
    const first = (trans.split('\n')[0] || '').replace(
      /^(ИИ|AI|Assistant|Секретарь|Me|Моё)\s*:\s*/i,
      ''
    );
    if (!trans || !isSameVoiceLine(first, greeting)) {
      session.transcription = [`AI: ${greeting}`, trans].filter(Boolean).join('\n');
    }
  }
  let existingHistory = [];
  let existingTranscription = '';
  try {
    const snap = await callsRef.doc(session.callSid).get();
    const data = snap.exists ? snap.data() || {} : {};
    existingHistory = (data.aiReception && data.aiReception.history) || [];
    existingTranscription = data.transcription || '';
  } catch (_) {}
  const history =
    (session.history || []).length >= existingHistory.length
      ? session.history || []
      : existingHistory;
  session.history = history;
  const transcription = deps.pickLongestTranscript
    ? deps.pickLongestTranscript(session.transcription, existingTranscription)
    : String(session.transcription || '').length >= String(existingTranscription || '').length
      ? session.transcription
      : existingTranscription;
  session.transcription = transcription;
  const onlyAppointment = appointmentOnly(session);
  if (session.appointmentOnly) {
    session.extracted = { ...(session.extracted || {}), appointment_only: onlyAppointment };
  }
  const reception = {
    history,
    extracted: session.extracted,
    language: session.language || 'en',
    turns: session.turns || 0,
    engine: session.engine || 'relay',
    liveFailed: false,
    appointmentOnly: onlyAppointment,
    pendingCancellation: session.pendingCancellation || null,
  };
  if (extra && extra.done) reception.done = true;
  // aiRelayComplete по этой метке не поднимает поток заново, а кладёт трубку.
  if (session.hangupReason) reception.hangup = session.hangupReason;
  const declined =
    voiceFacts.isServiceDeclined(session.extracted) ||
    Boolean(extra && extra.serviceDeclined);
  reception.createJob = Boolean(extra && extra.createJob) && !declined && !onlyAppointment;
  reception.serviceDeclined = declined;
  await callsRef.doc(session.callSid).set(
    {
      answeredBy: 'ai',
      ...(session.clientId ? { clientId: session.clientId } : {}),
      extractedData: session.extracted || {},
      transcription,
      aiReception: reception,
      serviceDeclined: declined,
    },
    { merge: true }
  );
}

function applyLocalExtract(session) {
  if (!deps || !deps.mergeExtracted) return;
  const extracted = deps.mergeExtracted(session.extracted || {}, {}, session.history);
  if (session.fromNumber) extracted.client_phone = deps.normalizePhone(session.fromNumber);
  const lastUser = lastHistoryText(session, 'user');
  const lastAsst = lastHistoryText(session, 'assistant');
  if (session.knownAddress && !extracted.owner_address) {
    extracted.owner_address = session.knownAddress;
  }
  const confirmedHome =
    session.knownAddress &&
    /still right|address on file|home on file|at the address|is the appliance at/i.test(lastAsst) &&
    /^(yes|yeah|yep|correct|that'?s right|still right|right|same|that one)\b/i.test(
      String(lastUser || '').trim()
    );
  if (confirmedHome && !extracted.address) {
    extracted.address = session.knownAddress;
  }
  if (
    extracted.address &&
    session.knownAddress &&
    voiceFacts.addressesLookDifferent(extracted.address, session.knownAddress) &&
    !voiceFacts.detectMoved(`${lastUser} ${lastAsst}`)
  ) {
    extracted.has_job_site = true;
    extracted.owner_address = session.knownAddress;
  }
  session.extracted = extracted;
  if (session.appointmentOnly) extracted.appointment_only = appointmentOnly(session);
  if (voiceFacts.isServiceDeclined(extracted) || appointmentOnly(session)) {
    session.createJob = false;
  } else if (deps.hasEnoughForJob(extracted) || extracted.wants_callback === true) {
    session.createJob = true;
  }
}

function persistSessionSoon(session, extra) {
  session.persistExtra = { ...(session.persistExtra || {}), ...(extra || {}) };
  if (session.persistTimer) return;
  session.persistTimer = setTimeout(() => {
    session.persistTimer = null;
    const pending = session.persistExtra || {};
    session.persistExtra = {};
    persistSession(session, pending).catch((error) => {
      console.warn('voiceLive persist:', error.message);
    });
  }, 2500);
}

function scheduleBackgroundExtract(session) {
  if (session.closed || session.extractTimer) return;
  session.extractTimer = setTimeout(() => {
    session.extractTimer = null;
    runBackgroundExtract(session).catch((error) => {
      console.warn('voiceLive extract:', error.message);
    });
  }, 8000);
}

async function runBackgroundExtract(session) {
  if (session.closed || session.extracting) return;
  session.extracting = true;
  try {
    const lastUser = lastHistoryText(session, 'user');
    const lastAsst = lastHistoryText(session, 'assistant');
    if (!lastUser && !lastAsst) return;
    const facts = await extractFacts(session, lastUser, lastAsst);
    if (session.closed) return;
    session.extracted = facts.extracted;
    session.createJob = session.createJob || facts.createJob || deps.hasEnoughForJob(session.extracted);
    persistSessionSoon(session, {
      done: Boolean(session.wantHangup),
      createJob: session.createJob,
    });
  } finally {
    session.extracting = false;
  }
}

function clearSessionTimers(session) {
  clearReplyWatchdog(session);
  clearSilence(session);
  clearAuthGrace(session);
  if (session.extractTimer) {
    clearTimeout(session.extractTimer);
    session.extractTimer = null;
  }
  if (session.persistTimer) {
    clearTimeout(session.persistTimer);
    session.persistTimer = null;
  }
}

/// Закрыть живой голос насовсем: поднимается socketGen, поэтому обработчик
/// close уже ничего не переподнимет. Для «сетап не приняли, пробуем
/// следующего» есть dropLiveSocketForRetry.
function closeLive(session) {
  if (session.livePing) {
    clearInterval(session.livePing);
    session.livePing = null;
  }
  const open = [session.geminiWs, session.openaiWs].filter(Boolean);
  session.geminiWs = null;
  session.openaiWs = null;
  session.ready = false;
  session.responseActive = false;
  session.socketGen = (session.socketGen || 0) + 1;
  for (const ws of open) {
    try {
      if (ws.readyState === 1) ws.close();
      else ws.terminate();
    } catch (_) {}
  }
}

/// Сессию не приняли. Закрываем именно сокет и не трогаем socketGen: его
/// обработчик close обязан сработать и позвать следующий шаг цепочки. Раньше
/// здесь звали closeGemini, и звонок после отказа в setup оставался без
/// голоса до самой лестницы тишины.
function dropLiveSocketForRetry(session) {
  const ws = liveSocket(session);
  if (!ws) return;
  try {
    ws.close();
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

function cancelHangup(session) {
  if (session.hangupTimer) {
    clearTimeout(session.hangupTimer);
    session.hangupTimer = null;
  }
  session.wantHangup = false;
}

function lastHistoryText(session, role) {
  const history = session.history || [];
  for (let i = history.length - 1; i >= 0; i--) {
    const item = history[i];
    if (item && item.role === role) return String(item.text || '');
  }
  return '';
}

function armReplyWatchdog(session, wait = STALL_MS) {
  clearReplyWatchdog(session);
  session.replyWatch = setTimeout(() => {
    session.replyWatch = null;
    if (session.closed || session.wantHangup || !session.ready || session.toolPending) return;
    if (session.assistantPartial) return;
    const lastUser = String(session.userPartial || '').trim() || lastHistoryText(session, 'user');
    if (!lastUser) return;
    // Звонящий ещё говорит или только что договорил — ждём, а не толкаем её
    // влезать посреди его фразы.
    const quiet = Date.now() - Number(session.lastInputAt || 0);
    if (quiet < STALL_MS) {
      armReplyWatchdog(session, STALL_MS - quiet);
      return;
    }
    // Она уже ответила на эти слова — спасать нечего.
    if (Number(session.lastOutputAt || 0) >= Number(session.lastInputAt || 0)) return;
    session.stallNudge = Number(session.stallNudge || 0) + 1;
    console.warn(`voiceLive stall ${session.callSid} n=${session.stallNudge}`);
    if (session.stallNudge > 1) return;
    nudgeKeepTalking(session, lastUser);
  }, Math.max(50, wait));
}

function clearReplyWatchdog(session) {
  if (session.replyWatch) {
    clearTimeout(session.replyWatch);
    session.replyWatch = null;
  }
}

function nudgeKeepTalking(session, lastUser) {
  if (!liveSocketOpen(session)) return;
  applyLocalExtract(session);
  const enough = deps && deps.hasEnoughForJob && deps.hasEnoughForJob(session.extracted);
  let extra = ' Speak now, like a person. One short sentence.';
  if (voiceFacts.looksOutOfScopeItem(lastUser)) {
    extra = ' We only repair household appliances. Say that kindly, then ask if anything else.';
  } else if (voiceFacts.declinedMoreHelp(lastUser) || voiceFacts.callerAskedToStop(lastUser)) {
    extra = ' They are done. Say only: Have a good day.';
  } else if (enough) {
    extra = ' You have enough. Pass it to the tech if you have not, then ask if anything else.';
  }
  sendPrompt(session, [
    {
      role: 'user',
      parts: [{ text: `The caller is still on the line.${extra} Do not stay silent. Do not hang up.` }],
    },
  ]);
}

function continueLivePrompt(session, callerWaiting) {
  const bits = (session.history || []).slice(-8).map((item) => {
    const who = item.role === 'assistant' ? 'You' : 'Caller';
    return `${who}: ${item.text}`;
  });
  const next = callerWaiting
    ? 'Reply now to what the caller just said, as if nothing happened.'
    : 'Stay quiet and listen until the caller speaks. If they say hello or ask whether you are there, say once, in a few words, that the line cut out for a second, then carry on from your last open question. Do not apologise again on later glitches.';
  return `The phone call is still connected after a brief audio glitch on our side. Same caller, not a new call.
${compactKnown(session)}
Recent turns:
${bits.join('\n') || '(still collecting details)'}
Do not greet from scratch. Do not say goodbye. ${next}`;
}

// ── Тишина на линии ────────────────────────────────────────────────────────

function clearSilence(session) {
  if (session.silenceTimer) {
    clearTimeout(session.silenceTimer);
    session.silenceTimer = null;
  }
}

/// Звонящий что-то сказал (Gemini его расслышал) — лестница сначала.
function noteCallerHeard(session) {
  session.lastCallerAt = Date.now();
  session.silenceStage = 0;
  session.voicedMs = 0;
  clearSilence(session);
}

/// Её реплика закончилась — с этого момента ждём звонящего.
function armSilence(session) {
  clearSilence(session);
  if (session.closed || session.liveFailed) return;
  let stage = Number(session.silenceStage || 0);
  // После «Have a good day» не переспрашиваем: ждём, что звонящий положит
  // трубку, и через SILENCE_HANGUP_MS тишины кладём сами.
  if (stage < 2 && voiceFacts.saidFarewell(lastHistoryText(session, 'assistant'))) {
    stage = 2;
    session.silenceStage = 2;
  }
  let wait = SILENCE_CHECK_MS;
  if (stage >= 2) wait = SILENCE_HANGUP_MS;
  else if (stage === 1) wait = SILENCE_GIVEUP_MS;
  else if (voiceFacts.callerAskedToHold(lastHistoryText(session, 'user'))) wait = SILENCE_HOLD_MS;
  session.silenceTimer = setTimeout(() => onSilence(session), wait);
}

function onSilence(session) {
  session.silenceTimer = null;
  if (session.closed || session.liveFailed) return;
  // Неудобный момент: переподключение, работает инструмент, она говорит или
  // звонящий прямо сейчас слышно говорит (расшифровка придёт в конце фразы).
  const speaking = session.speaking || Boolean(session.assistantPartial);
  const callerTalking = Boolean(session.lastVoicedAt) && Date.now() - session.lastVoicedAt < VOICE_QUIET_MS;
  if (!session.ready || session.toolPending || speaking || callerTalking) {
    session.silenceTimer = setTimeout(() => onSilence(session), 2000);
    return;
  }
  // Звонящий явно говорил и замолчал, а модель не расслышала ни слова и не
  // ответила — она «оглохла». Первый раз — на следующий шаг цепочки (у OpenAI
  // это уже Gemini), второй (или запасных нет) — в Gather: там звонящего
  // слушает сам Twilio. Громкость считается у нас, поэтому детектор одинаков
  // для обоих провайдеров.
  if (Number(session.voicedMs || 0) >= DEAF_VOICED_MS) {
    console.warn(
      `voiceLive deaf ${session.callSid} voiced=${Math.round(session.voicedMs)}ms ` +
        `${session.provider || 'gemini'}:${session.liveModel || '-'}`
    );
    session.voicedMs = 0;
    session.liveFailures = Number(session.liveFailures || 0) + 1;
    if (session.deafSwitched || !hasNextLiveStep(session)) {
      giveUpLive(session, 'deaf');
      return;
    }
    session.deafSwitched = true;
    resumeLive(session, 'deaf', { switchModel: true });
    session.silenceTimer = setTimeout(() => onSilence(session), SILENCE_CHECK_MS);
    return;
  }
  const stage = Number(session.silenceStage || 0);
  if (stage >= 2) {
    hangUpForSilence(session).catch((error) => console.warn('voiceLive silence hangup:', error.message));
    return;
  }
  session.silenceStage = stage + 1;
  console.log(`voiceLive silence ${session.callSid} stage=${session.silenceStage}`);
  nudgeSilence(session, session.silenceStage);
  // Обычно лестницу двигает конец её реплики (armSilence). Если реплики так и
  // не случилось (сокет лёг), идём дальше сами, чтобы звонок не висел вечно.
  const fallback = session.silenceStage >= 2 ? SILENCE_HANGUP_MS : SILENCE_GIVEUP_MS;
  session.silenceTimer = setTimeout(() => onSilence(session), fallback + 6000);
}

function nudgeSilence(session, stage) {
  if (!liveSocketOpen(session)) return;
  const text = stage === 1
    ? 'The caller has not said anything for a while. Check the line once, in a few words — for example: "Hello — are you still there?" Then stop and listen. Do not repeat your last question.'
    : 'Still nothing from the caller: they may not hear you, or you cannot hear them. Say once, kindly, in one or two short sentences, that you are having trouble hearing them and they can call back or send a text to this number. Then stop and wait quietly.';
  sendPrompt(session, [{ role: 'user', parts: [{ text }] }]);
}

/// Подсказка модели от релея (приветствие, толчок, переспрос). Её ответ на
/// такую подсказку — не признак того, что модель расслышала звонящего.
/// Формат один на оба провайдера: turnComplete=false только добавляет контекст,
/// turnComplete=true просит ответить сейчас.
function sendPrompt(session, turns, turnComplete = true) {
  if (turnComplete) session.promptedTurn = true;
  if (session.provider === 'openai') {
    sendOpenaiTurns(session, turns, turnComplete);
    return;
  }
  sendJson(session.geminiWs, { clientContent: { turns, turnComplete } });
}

/// Те же реплики, но в терминах Realtime: элементы беседы и, если ход закрыт,
/// просьба ответить.
function sendOpenaiTurns(session, turns, turnComplete) {
  const ws = session.openaiWs;
  if (!ws || ws.readyState !== 1) return;
  for (const turn of turns || []) {
    const text = (turn.parts || [])
      .map((part) => String((part && part.text) || '').trim())
      .filter(Boolean)
      .join('\n');
    if (!text) continue;
    const assistant = turn.role === 'model' || turn.role === 'assistant';
    // Типы содержимого в GA строгие: реплика секретаря — только output_text
    // («Invalid value: 'text'. Value must be 'output_text'»), реплика
    // звонящего — input_text. Ошибёшься — история при обрыве не перенесётся.
    sendJson(ws, {
      type: 'conversation.item.create',
      item: {
        type: 'message',
        role: assistant ? 'assistant' : 'user',
        content: [{ type: assistant ? 'output_text' : 'input_text', text }],
      },
    });
  }
  if (turnComplete) requestOpenaiResponse(session);
}

/// response.create при уже идущем ответе — ошибка, поэтому держим признак
/// активного ответа и короткий заслон от дублей.
function requestOpenaiResponse(session, { force = false } = {}) {
  const ws = session.openaiWs;
  if (!ws || ws.readyState !== 1) return;
  if (!force && session.responseActive) return;
  const asked = session.responseAskedAt == null ? -Infinity : Number(session.responseAskedAt);
  if (Date.now() - asked < 1000) return;
  session.responseAskedAt = Date.now();
  sendJson(ws, { type: 'response.create' });
}

/// После «can't hear you — call back or text» 30 с тишины: кладём трубку
/// (решение FIX). Сама модель трубку положить не может, это делает релей: метка
/// hangup в звонке говорит aiRelayComplete не поднимать поток заново.
async function hangUpForSilence(session) {
  if (session.closed) return;
  const quiet = Math.round((Date.now() - Number(session.lastCallerAt || session.startedAt || Date.now())) / 1000);
  console.log(`voiceLive silence hangup ${session.callSid} quiet=${quiet}s`);
  session.hangupReason = 'silence';
  try {
    await onLiveStop(session);
  } finally {
    closeTwilio(session);
  }
}

/// Громкость входящего звука: копим «громкие» 20-мс кадры, пока она молчит.
/// Её собственный голос может вернуться эхом, поэтому во время её речи не считаем.
function noteInboundLevel(session, pcm8) {
  if (!pcm8.length) return;
  let sum = 0;
  for (let i = 0; i < pcm8.length; i++) sum += pcm8[i] * pcm8[i];
  if (Math.sqrt(sum / pcm8.length) < VOICED_RMS) return;
  session.lastVoicedAt = Date.now();
  if (!session.speaking) session.voicedMs = Number(session.voicedMs || 0) + pcm8.length / 8;
}

function scheduleHangup(session, ms) {
  if (session.closed) return;
  if (session.hangupTimer) {
    clearTimeout(session.hangupTimer);
    session.hangupTimer = null;
  }
  session.hangupTimer = setTimeout(() => {
    session.hangupTimer = null;
    if (session.closed) return;
    session.closed = true;
    closeLive(session);
    closeTwilio(session);
  }, ms);
}

function sendTwilioClear(session) {
  // И наш хвост нарезчика, и то, что Twilio ещё не проиграл: иначе после
  // перебивания звонящий слышит обрывок её прошлой фразы.
  session.outLeftover = new Int16Array(0);
  session.outMulaw = EMPTY_MULAW;
  if (!session.streamSid) return;
  sendJson(session.twilioWs, { event: 'clear', streamSid: session.streamSid });
}

// Twilio ждёт кадры по 20 мс — это 160 байт mulaw при 8 кГц. Модели присылают
// куски по несколько сотен миллисекунд, и мы отправляли их одним сообщением:
// один кадр «на полсекунды» вместо двадцати пяти. Twilio такие пачки принимает
// плохо и рвёт соединение без закрытия (в журнале это код 1006). Через этот
// нарезчик идут оба провайдера: у OpenAI это готовый g711_ulaw, у Gemini —
// результат фильтрации и даунсемплинга.
const TWILIO_FRAME_BYTES = 160;
const EMPTY_MULAW = Buffer.alloc(0);

function sendTwilioMulaw(session, mulaw) {
  if (!session.streamSid || session.closed || !mulaw || !mulaw.length) return;
  const tail = session.outMulaw && session.outMulaw.length ? session.outMulaw : null;
  const buffer = tail ? Buffer.concat([tail, mulaw]) : Buffer.from(mulaw);
  let at = 0;
  for (; at + TWILIO_FRAME_BYTES <= buffer.length; at += TWILIO_FRAME_BYTES) {
    sendJson(session.twilioWs, {
      event: 'media',
      streamSid: session.streamSid,
      media: {
        payload: buffer.subarray(at, at + TWILIO_FRAME_BYTES).toString('base64'),
      },
    });
  }
  // Неполный кадр не отправляем — он дождётся следующего куска или хвоста.
  session.outMulaw = at < buffer.length ? Buffer.from(buffer.subarray(at)) : EMPTY_MULAW;
}

/// Реплика кончилась, а до целого кадра не хватает нескольких миллисекунд:
/// добиваем тишиной, иначе конец слова повиснет до следующего ответа.
function flushTwilioTail(session) {
  const tail = session.outMulaw;
  session.outMulaw = EMPTY_MULAW;
  if (!tail || !tail.length || !session.streamSid || session.closed) return;
  const frame = Buffer.alloc(TWILIO_FRAME_BYTES, MULAW_SILENCE);
  tail.copy(frame, 0);
  sendJson(session.twilioWs, {
    event: 'media',
    streamSid: session.streamSid,
    media: { payload: frame.toString('base64') },
  });
}

function sendTwilioAudio(session, pcm, sampleRate) {
  if (!session.streamSid || session.closed) return;
  const rate = Number(sampleRate) || 24000;
  // Фильтр держит состояние между чанками, поэтому живёт на сессии.
  if (!session.outFilter || session.outFilter.sampleRate !== rate) {
    session.outFilter = createLowPass(rate, 3400);
  }
  const { pcm8, leftover } = downsampleTo8k(pcm, rate, session.outLeftover, session.outFilter);
  session.outLeftover = leftover;
  if (!pcm8.length) return;
  sendTwilioMulaw(session, pcm16ToMulaw(pcm8));
}

/// Звук звонящего — наверх. Громкость считаем всегда и у себя: на ней держатся
/// детектор «глухой» модели и лестница тишины, и они обязаны работать
/// одинаково на обоих провайдерах.
function forwardCallerAudio(session, payload) {
  const ws = liveSocket(session);
  if (!ws || ws.readyState !== 1) return false;
  const mulaw = Buffer.from(payload, 'base64');
  if (!mulaw.length) return true;
  const pcm8 = mulawToPcm16(mulaw);
  noteInboundLevel(session, pcm8);
  if (session.provider === 'openai') {
    // Родной формат: отдаём ровно то, что пришло от Twilio, без апсемплинга.
    sendJson(ws, { type: 'input_audio_buffer.append', audio: payload });
    return true;
  }
  sendJson(ws, {
    realtimeInput: {
      audio: {
        data: int16ToBase64(upsample8kTo16k(pcm8)),
        mimeType: 'audio/pcm;rate=16000',
      },
    },
  });
  return true;
}

// Один чанк Twilio — 20 мс, значит 200 чанков это всего 4 секунды. Установка
// сессии Gemini занимает до 8 (setupTimer), плюс переподключение по goAway —
// и первые слова звонящего просто выбрасывались. 1500 чанков это 30 секунд
// и меньше мегабайта в памяти.
const PENDING_AUDIO_MAX = 1500;

function sendCallerAudio(session, payload) {
  if (!payload) return;
  if (!session.ready || !forwardCallerAudio(session, payload)) {
    session.pendingAudio = session.pendingAudio || [];
    session.pendingAudio.push(payload);
    if (session.pendingAudio.length > PENDING_AUDIO_MAX) session.pendingAudio.shift();
  }
}

function flushPendingAudio(session) {
  const queued = session.pendingAudio || [];
  session.pendingAudio = [];
  for (const payload of queued) forwardCallerAudio(session, payload);
}

function joinVoiceText(prev, next) {
  const a = String(prev || '').trim();
  const b = String(next || '').trim();
  if (!b) return a;
  if (!a) return b;
  if (b.startsWith(a) || (a.length >= 8 && b.includes(a))) return b;
  if (a.startsWith(b) || (b.length >= 8 && a.includes(b))) return a;
  let overlap = 0;
  const max = Math.min(a.length, b.length, 40);
  for (let i = max; i >= 4; i--) {
    if (a.slice(-i) === b.slice(0, i)) {
      overlap = i;
      break;
    }
  }
  if (overlap) return `${a}${b.slice(overlap)}`;
  return `${a} ${b}`.replace(/\s+/g, ' ');
}

function setPartial(session, field, text, finished) {
  const value = String(text || '').trim();
  if (!value) return;
  if (field === 'userPartial') {
    const lastAsst = lastHistoryText(session, 'assistant');
    if (isSameVoiceLine(lastAsst, value)) return;
    // Звонящий говорит: лестница тишины сначала, сторожевой таймер — от
    // последнего его слова, а не от первого.
    session.lastInputAt = Date.now();
    session.heardChunks = Number(session.heardChunks || 0) + 1;
    noteCallerHeard(session);
    armReplyWatchdog(session);
  }
  session.language = 'en';
  session[field] = joinVoiceText(session[field], value);
  if (finished) flushPartial(session, field);
}

function isSameVoiceLine(a, b) {
  const na = String(a || '')
    .replace(/^(AI|Client|User):\s*/i, '')
    .toLowerCase()
    .replace(/[^a-z0-9а-яё]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const nb = String(b || '')
    .replace(/^(AI|Client|User):\s*/i, '')
    .toLowerCase()
    .replace(/[^a-z0-9а-яё]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!na || !nb) return false;
  if (na === nb) return true;
  const [shorter, longer] = na.length <= nb.length ? [na, nb] : [nb, na];
  return shorter.length >= 12 && longer.includes(shorter) && shorter.length / longer.length >= 0.78;
}

function flushPartial(session, field) {
  const text = String(session[field] || '').trim();
  session[field] = '';
  if (!text) return;
  const role = field === 'userPartial' ? 'user' : 'assistant';
  const history = session.history || [];
  const last = history[history.length - 1];
  if (last && last.role === role && isSameVoiceLine(last.text, text)) return;
  session.history = [...history, { role, text }].slice(-400);
  session.transcription = deps.appendTranscript(
    session.transcription,
    role === 'user' ? `Client: ${text}` : `AI: ${text}`
  );
  if (role === 'user') {
    session.turns = Number(session.turns || 0) + 1;
    armReplyWatchdog(session);
    if (voiceFacts.isCheckInUtterance(text) || session.wantHangup) {
      cancelHangup(session);
    }
  } else {
    clearReplyWatchdog(session);
    session.stallNudge = 0;
  }
}

function flushPartials(session) {
  flushPartial(session, 'userPartial');
  flushPartial(session, 'assistantPartial');
}

function greetLive(session) {
  if (!session.ready || !liveSocket(session)) return;
  if (session.needsContinue) {
    session.needsContinue = false;
    session.greeted = true;
    // Отвечаем сразу, только если последние слова звонящего остались без
    // ответа. Если последней говорила она, после сбоя молча слушаем: раньше
    // каждое переподключение заставляло её сказать «I'm still here…» и
    // повторить вопрос — при сбоях Gemini раз в 10–30 с вышло семь повторов
    // подряд. Контекст при этом передаём (turnComplete=false — без ответа).
    const history = session.history || [];
    const last = history[history.length - 1];
    const callerWaiting = Boolean(last && last.role === 'user' && String(last.text || '').trim());
    const turns = [];
    if (!session.resumeHandle) {
      for (const item of history.slice(-8)) {
        const text = String((item && item.text) || '').trim();
        if (!text) continue;
        turns.push({
          role: item.role === 'assistant' ? 'model' : 'user',
          parts: [{ text }],
        });
      }
    }
    turns.push({
      role: 'user',
      parts: [{ text: continueLivePrompt(session, callerWaiting) }],
    });
    sendPrompt(session, turns, callerWaiting);
    return;
  }
  if (session.greeted) return;
  session.greeted = true;
  if (session.greetingSpoken) return;
  // Фиксированная фраза приветствия больше не передаётся: секретарь
  // здоровается своими словами, каждый раз чуть иначе, как живой человек.
  // session.greeting остался только для ситуативных строк (мастер снял трубку
  // и передал звонок ИИ на ходу) — тогда смысл строки сохраняем.
  const greeting = String(session.greeting || '').trim();
  const body = greeting
    ? `Use an easy conversational rhythm, not a recording or a call-centre announcement. Keep the meaning of this opening, not its exact wording: ${greeting}`
    : 'Do not recite a set line: no memorized slogan, no call-centre announcement, nothing that sounds read from a script. Sound like someone who works here and just picked up the phone. Mention the shop (FixApplianceCA) naturally, and phrase it a little differently on every call.';
  sendPrompt(session, [
    {
      role: 'user',
      parts: [
        {
          text: `The call just connected. For this first greeting only, answer in your own words in English, warmly and matter-of-factly, as if picking up the shop phone for one person.
${body}
Keep it to one short breath. If you give your name, it is ${voiceFacts.SECRETARY_NAME} — no other name, never "this is she". No sales pitch, exaggerated cheerfulness, filler or staged laughter. End with one easy invitation to speak, then stop and listen. Do not start collecting repair details yet.`,
        },
      ],
    },
  ]);
}

function hangupAllowed(session, lastUser, lastAsst) {
  return voiceFacts.mayHangUp({
    lastUser,
    lastAsst,
    history: session.history,
    extracted: session.extracted,
  });
}

function nudgeStayOnLine(session) {
  if (!liveSocketOpen(session)) return;
  session.prematureBye = Number(session.prematureBye || 0) + 1;
  if (session.prematureBye > 2) return;
  const ask =
    'STOP. The caller is still on the line. Do not hang up. Do not say bye, goodbye, see you then, or have a good day. You already confirmed. Stay quiet and wait.';
  sendPrompt(session, [{ role: 'user', parts: [{ text: ask }] }]);
}

function askedForMissing(lastAsst, missing) {
  if (!missing) return true;
  if (/clock time|day AND/i.test(missing)) {
    return voiceFacts.askedForVisitTime(lastAsst);
  }
  if (/street/i.test(missing)) {
    return voiceFacts.askedForAddress(lastAsst);
  }
  return false;
}

function steerCollectAfterTurn(session, lastUser, lastAsst) {
  if (!session || session.closed) return;
  applyLocalExtract(session);
  const missing = voiceFacts.missingVisitDetails(session.extracted);
  if (missing) {
    cancelHangup(session);
  }
  if (!missing || !liveSocketOpen(session)) return;
  const justGaveOtherAddress =
    voiceFacts.looksLikeStreetUtterance(lastUser)
    || voiceFacts.detectJobSite(lastUser)
    || Boolean(session.extracted && session.extracted.has_job_site);
  const hungUpTooSoon =
    voiceFacts.saidGoodbye(lastAsst) || voiceFacts.saidCallbackPromise(lastAsst);
  if (askedForMissing(lastAsst, missing) && !hungUpTooSoon) return;
  session.collectNudge = Number(session.collectNudge || 0) + 1;
  if (session.collectNudge > 3) return;
  const otherAddr =
    justGaveOtherAddress && /clock time|day AND/i.test(missing)
      ? ' They just gave a different repair address. Keep their home. Next ask what day and what time of day to come, then wait for the answer.'
      : '';
  sendPrompt(session, [
    {
      role: 'user',
      parts: [
        {
          text:
            `STOP. Do not hang up. Do not say goodbye. Do not say a technician will call back.${otherAddr} You still need ${missing}. Ask for that now, then wait.`,
        },
      ],
    },
  ]);
}

async function withCalendarDeadline(work) {
  let timer;
  try {
    return await Promise.race([
      work,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Calendar timeout')), 8000); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function refreshCallerSchedule(session) {
  const result = await withCalendarDeadline(deps.loadCallerSchedule({
    phone: session.fromNumber, clientId: session.clientId, callSid: session.callSid,
  }));
  session.openJobBrief = result.brief || 'Caller calendar is unavailable; do not guess.';
  session.callerAppointments = result.ok ? result.appointments || [] : [];
  return result;
}

function appointmentOnly(session) {
  return voiceFacts.isAppointmentOnly(session.extracted, {
    aiReception: { appointmentOnly: session.appointmentOnly, history: session.history },
  });
}

function cancellationConfirmed(session, pending) {
  const userTurns = (session.history || []).filter((item) => item.role === 'user').length;
  if (!pending || userTurns <= pending.userTurns || Date.now() - pending.askedAt > 5 * 60000) return false;
  const history = session.history || [];
  const userIndex = history.findLastIndex((item) => item.role === 'user');
  const question = String(history.slice(0, userIndex).findLast((item) => item.role === 'assistant')?.text || '');
  const answer = lastHistoryText(session, 'user').trim();
  if (!/\b(cancel|cancellation)\b/i.test(question) || !/\?|\b(shall|should|want|confirm)\b/i.test(question)) return false;
  if (/\b(no|not|don't|never|keep|but|instead|rather|other|different|reschedule|move)\b|нет|не отмен|остав|перен/i.test(answer)) return false;
  return /^(yes|yeah|yep|please cancel|cancel it|go ahead)\b/i.test(answer) || /^(да|отмените|отмени)([\s,.!]|$)/i.test(answer);
}

async function runAppointmentTool(session, name, args = {}) {
  if (!['get_caller_appointments', 'cancel_appointment', 'check_service_area'].includes(name)) {
    return { ok: false, error: 'unknown_tool' };
  }
  if (session.closed) return { ok: false, error: 'call_inactive' };
  try {
    // Вопрос про зону — не запись на визит: состояние звонка не трогаем.
    if (name === 'check_service_area') {
      if (!deps.checkServiceArea) return { ok: false, error: 'no_map' };
      return await withCalendarDeadline(deps.checkServiceArea(String(args.place || '')));
    }
    session.appointmentOnly = true;
    session.extracted = { ...(session.extracted || {}), appointment_only: !voiceFacts.hasNewRepairRequest(session.history) };
    if (appointmentOnly(session)) session.createJob = false;
    const current = await refreshCallerSchedule(session);
    if (!current.ok || name === 'get_caller_appointments') return current;
    const pending = session.pendingCancellation;
    if (pending && (session.history || []).filter((item) => item.role === 'user').length > pending.userTurns &&
        /^(no|nope|нет)\b|don't cancel|do not cancel|keep (it|the|my)|не отмен|остав/i.test(lastHistoryText(session, 'user').trim())) {
      session.pendingCancellation = null;
      return { ok: true, status: 'unchanged', say: "Okay, I haven't changed anything." };
    }
    const jobId = args.job_id || (args.confirmed === true && pending && pending.jobId);
    const visitId = args.visit_id || (args.confirmed === true && pending && pending.visitId);
    const appointments = current.appointments || [];
    const selected = jobId || visitId
      ? appointments.find((visit) => visit.jobId === jobId && visit.visitId === visitId)
      : appointments.length === 1 ? appointments[0] : null;
    if (!selected) {
      session.pendingCancellation = null;
      return {
        ok: false, status: appointments.length ? 'selection_required' : 'no_upcoming_visit', appointments,
        say: appointments.length ? 'Which visit would you like to cancel?' : "I don't see an upcoming visit for your number. There is nothing scheduled to cancel.",
      };
    }
    const same = pending && pending.jobId === selected.jobId && pending.visitId === selected.visitId && pending.startAt === selected.startAt;
    if (args.confirmed !== true || !same || !cancellationConfirmed(session, pending)) {
      session.pendingCancellation = {
        ...selected, askedAt: Date.now(), userTurns: (session.history || []).filter((item) => item.role === 'user').length,
      };
      return {
        ok: true, status: 'confirmation_required', appointment: selected,
        say: `Should I cancel your visit on ${selected.when}${selected.address ? ` at ${selected.address}` : ''}?`,
      };
    }
    const result = await withCalendarDeadline(deps.cancelCallerVisit({
      phone: session.fromNumber, clientId: session.clientId, callSid: session.callSid,
    }, { jobId: selected.jobId, visitId: selected.visitId, expectedStartAt: pending.startAt }));
    session.pendingCancellation = null;
    if (!result.ok) {
      return { ...result, say: "That visit has changed. I couldn't confirm a cancellation; please let us check the current booking." };
    }
    await refreshCallerSchedule(session).catch(() => {
      session.openJobBrief = 'The selected cancellation was saved, but the remaining caller schedule is unavailable. Recheck before discussing any other appointment.';
      session.callerAppointments = [];
    });
    return { ...result, say: `Your visit on ${selected.when} is cancelled.` };
  } catch (error) {
    console.warn(`voice calendar ${name}: ${error.message}`);
    session.openJobBrief = 'Caller calendar is unavailable. Do not claim a booking exists or is absent, or that any change succeeded.';
    session.callerAppointments = [];
    return { ok: false, error: 'calendar_unavailable', say: "I can't verify the calendar right now. Please text us so we can check it." };
  }
}

async function handleLiveToolCall(session, message) {
  const toolCall = pick(message, 'toolCall', 'tool_call') || {};
  const calls = pick(toolCall, 'functionCalls', 'function_calls') || [];
  if (!calls.length) return;
  flushPartial(session, 'userPartial');
  clearReplyWatchdog(session);
  session.toolPending = true;
  try {
    const responses = [];
    for (const call of calls) {
      const name = pick(call, 'name') || '';
      const id = pick(call, 'id') || '';
      const args = pick(call, 'args', 'arguments') || {};
      if (name === 'end_call') {
        console.warn(`voiceLive ignored hangup tool ${session.callSid}`);
        cancelHangup(session);
        responses.push({ id, name, response: { ok: false, result: 'You cannot hang up. Wait for the caller.' } });
        continue;
      }
      const response = await runAppointmentTool(session, name, args);
      console.log(`voice calendar ${session.callSid || '?'} ${name} ${response.status || response.error || (response.ok ? 'ok' : 'blocked')}`);
      responses.push({ id, name, response });
    }
    sendJson(session.geminiWs, { toolResponse: { functionResponses: responses } });
    persistSessionSoon(session, { createJob: session.createJob });
  } finally {
    session.toolPending = false;
  }
}

async function handleLiveTurnComplete(session) {
  flushPartials(session);
  applyLocalExtract(session);
  const userText = lastHistoryText(session, 'user');
  const asstText = lastHistoryText(session, 'assistant');
  if (voiceFacts.looksOutOfScopeItem(userText) && !session.scopedNudge) {
    session.scopedNudge = true;
    if (!asstText || asstText.length < 12) {
      nudgeKeepTalking(session, userText);
    }
  }
  persistSessionSoon(session, {
    done: Boolean(session.wantHangup),
    createJob: session.createJob,
  });
  scheduleBackgroundExtract(session);
}

// ── Общее для обоих провайдеров ────────────────────────────────────────────

/// Сессия поднялась. Один и тот же порядок на OpenAI и Gemini: снять флаги
/// переподключения, поздороваться (или подхватить разговор) и завести лестницу
/// тишины.
function onLiveReady(session, { keepPendingAudio = true } = {}) {
  if (session.ready) return;
  session.ready = true;
  session.liveStarted = true;
  session.resumeAttempts = 0;
  // Соединение установлено. Флаг раньше оставался поднятым до первого
  // обрыва, и resumeLive по goAway молча ничего не делал: сессия доживала до
  // дедлайна и обрывалась.
  session.connecting = false;
  session.speaking = false;
  session.promptedTurn = false;
  // Сначала просим поздороваться (или продолжить), и только потом отдаём
  // накопленный звук: иначе VAD успеет ответить раньше приветствия.
  greetLive(session);
  if (keepPendingAudio) flushPendingAudio(session);
  else session.pendingAudio = [];
  // Лестница тишины идёт и тогда, когда от модели так и не пришёл конец
  // реплики (приветствие сорвалось, сокет переподняли). Начатый отсчёт не сбиваем.
  if (!session.silenceTimer) armSilence(session);
}

/// Реплика секретаря закончилась.
function onLiveTurnFinished(session) {
  flushTwilioTail(session);
  flushPartials(session);
  session.speaking = false;
  session.promptedTurn = false;
  const lastAsst = lastHistoryText(session, 'assistant');
  if (voiceFacts.saidGoodbye(lastAsst)) {
    console.warn(`voiceLive premature goodbye ${session.callSid} asst="${String(lastAsst).slice(0, 120)}"`);
    cancelHangup(session);
  }
  armSilence(session);
  handleLiveTurnComplete(session).catch((error) => {
    console.warn('voiceLive turn:', error.message);
  });
}

/// Звонящий заговорил поверх неё. Чистим и очередь Twilio, и хвост нарезчика,
/// гасим текущий ответ и возвращаем лестницу тишины в начало.
function onLiveBargeIn(session) {
  flushPartial(session, 'assistantPartial');
  sendTwilioClear(session);
  session.speaking = false;
  session.promptedTurn = false;
  noteCallerHeard(session);
}

/// Пришёл кусок её голоса — общая бухгалтерия перед отправкой в Twilio.
function noteLiveSpeaking(session) {
  clearReplyWatchdog(session);
  session.lastOutputAt = Date.now();
  // Она заговорила сама, без подсказки релея — значит, отвечает на голос
  // звонящего, и модель его слышит (даже если расшифровка не пришла).
  if (!session.speaking && !session.promptedTurn) noteCallerHeard(session);
  session.speaking = true;
  clearSilence(session);
}

/// Расшифровка её реплики. Ответ модели приходит отдельным потоком и часто
/// завершается раньше, чем расшифровка клиента: без этого в стенограмме
/// реплика секретаря оказывалась ВЫШЕ вопроса, на который она отвечает, и
/// разбор звонка потом винил секретаря в том, чего не было.
/// Порядок важен: flushPartial('userPartial') снова взводит сторожевой таймер,
/// поэтому снимать его надо ПОСЛЕ сброса.
function noteAssistantTranscript(session, text, finished) {
  if (session.userPartial) flushPartial(session, 'userPartial');
  clearReplyWatchdog(session);
  session.lastOutputAt = Date.now();
  setPartial(session, 'assistantPartial', text, finished);
}

// ── OpenAI Realtime ────────────────────────────────────────────────────────

function handleOpenaiMessage(session, raw) {
  let message;
  try {
    message = JSON.parse(String(raw));
  } catch (_) {
    return;
  }
  switch (String(message.type || '')) {
    case 'session.created':
      // Настройку шлём и на open, и сюда: какой бы порядок ни выбрал сервер,
      // сессия должна получить промпт, голос и формат звука.
      sendJson(session.openaiWs, session.setupPayload);
      return;
    case 'session.updated':
      onLiveReady(session);
      return;
    case 'error': {
      const text = String(
        (message.error && (message.error.message || message.error.code)) || 'openai error'
      );
      session.liveError = text;
      console.warn(`voiceLive openai error ${session.callSid}: ${text}`);
      // Отказ до готовности — сессию не приняли: следующий шаг цепочки
      // поднимет обработчик close. Ошибки на живой сессии (например, «нет
      // активного ответа» на response.cancel) просто логируем.
      if (!session.ready) dropLiveSocketForRetry(session);
      return;
    }
    case 'input_audio_buffer.speech_started':
      if (session.responseActive) {
        sendJson(session.openaiWs, { type: 'response.cancel' });
        session.responseActive = false;
      }
      onLiveBargeIn(session);
      return;
    case 'conversation.item.input_audio_transcription.completed':
      if (message.transcript) setPartial(session, 'userPartial', message.transcript, true);
      return;
    case 'conversation.item.input_audio_transcription.failed':
      console.warn(`voiceLive openai transcription failed ${session.callSid}`);
      return;
    case 'response.created':
      session.responseActive = true;
      return;
    case 'response.audio.delta':
    case 'response.output_audio.delta': {
      if (!message.delta) return;
      noteLiveSpeaking(session);
      // Уже g711_ulaw 8 кГц — ни даунсемплинга, ни перекодирования, только
      // нарезка по 160 байт.
      sendTwilioMulaw(session, Buffer.from(message.delta, 'base64'));
      return;
    }
    case 'response.audio_transcript.done':
    case 'response.output_audio_transcript.done':
      if (message.transcript) noteAssistantTranscript(session, message.transcript, true);
      return;
    case 'response.function_call_arguments.done':
      session.toolTail = (session.toolTail || Promise.resolve())
        .then(() => handleOpenaiToolCall(session, message))
        .catch((error) => console.warn('voiceLive tool:', error.message));
      return;
    case 'response.done':
      session.responseActive = false;
      onLiveTurnFinished(session);
      return;
    default:
      return;
  }
}

/// Те же три инструмента и тот же дедлайн 8 секунд, что у Gemini: разбор
/// ответа и двухфазная отмена живут в runAppointmentTool, общем для обоих.
async function handleOpenaiToolCall(session, message) {
  const name = String(message.name || '');
  const callId = String(message.call_id || '');
  flushPartial(session, 'userPartial');
  clearReplyWatchdog(session);
  session.toolPending = true;
  try {
    let args = {};
    try {
      args = message.arguments ? JSON.parse(message.arguments) : {};
    } catch (_) {
      args = {};
    }
    let response;
    if (name === 'end_call') {
      console.warn(`voiceLive ignored hangup tool ${session.callSid}`);
      cancelHangup(session);
      response = { ok: false, result: 'You cannot hang up. Wait for the caller.' };
    } else {
      response = await runAppointmentTool(session, name, args);
      console.log(
        `voice calendar ${session.callSid || '?'} ${name} ` +
          `${response.status || response.error || (response.ok ? 'ok' : 'blocked')}`
      );
    }
    const ws = session.openaiWs;
    if (ws && ws.readyState === 1) {
      sendJson(ws, {
        type: 'conversation.item.create',
        item: {
          type: 'function_call_output',
          call_id: callId,
          output: JSON.stringify(response),
        },
      });
      // Результат нужно озвучить сразу: ответ, в котором был вызов, уже закрыт.
      requestOpenaiResponse(session, { force: true });
    }
    persistSessionSoon(session, { createJob: session.createJob });
  } finally {
    session.toolPending = false;
  }
}

// ── Gemini Live ────────────────────────────────────────────────────────────

function handleGeminiMessage(session, raw) {
  let message;
  try {
    message = JSON.parse(String(raw));
  } catch (_) {
    return;
  }
  if (message.error) {
    const text = String((message.error && message.error.message) || message.error);
    session.liveError = text;
    console.warn(`voiceLive gemini error ${session.callSid}: ${text}`);
    if (!session.ready) {
      const setup = (session.setupPayload && session.setupPayload.setup) || null;
      const gen = setup && setup.generationConfig;
      let stripped = false;
      if (gen && gen.thinkingConfig) {
        delete gen.thinkingConfig;
        stripped = true;
      }
      // Сервер не знает об эмоциональной подаче — снимаем флаг и пробуем ту же
      // модель ещё раз. Молчать в трубку из-за необязательной настройки нельзя.
      if (setup && setup.enableAffectiveDialog) {
        delete setup.enableAffectiveDialog;
        session.noAffective = true;
        stripped = true;
      }
      if (stripped) {
        session.connecting = false;
        const model = session.geminiModel;
        const old = session.geminiWs;
        session.geminiWs = null;
        try {
          if (old) old.close();
        } catch (_) {}
        console.warn(`voiceLive retry ${session.callSid} without extra live flags`);
        attachGeminiSocket(session, openGeminiSocket(deps && deps.geminiApiKey, model, false), model);
        return;
      }
      // Следующий шаг цепочки поднимет обработчик close этого же сокета.
      dropLiveSocketForRetry(session);
    }
    return;
  }
  const resumeUpdate = pick(message, 'sessionResumptionUpdate', 'session_resumption_update');
  if (resumeUpdate) {
    const handle = pick(resumeUpdate, 'newHandle', 'new_handle');
    if (handle) session.resumeHandle = handle;
  }
  if (pick(message, 'setupComplete', 'setup_complete')) {
    // На свежем звонке накопленное до сессии не отдаём: это ещё до приветствия.
    onLiveReady(session, { keepPendingAudio: Boolean(session.needsContinue) });
    return;
  }
  const content = pick(message, 'serverContent', 'server_content') || {};
  // Её перебил голос звонящего — значит, Gemini его слышит и линия жива.
  if (pick(content, 'interrupted') === true) onLiveBargeIn(session);
  const input = pick(content, 'inputTranscription', 'input_transcription');
  if (input && input.text) {
    setPartial(session, 'userPartial', input.text, input.finished === true);
  }
  const output = pick(content, 'outputTranscription', 'output_transcription');
  if (output && output.text) {
    noteAssistantTranscript(session, output.text, output.finished === true);
  }
  const turn = pick(content, 'modelTurn', 'model_turn') || {};
  for (const part of turn.parts || []) {
    const inline = pick(part, 'inlineData', 'inline_data');
    if (!inline || !inline.data) continue;
    noteLiveSpeaking(session);
    // 24 кГц → 8 кГц идёт через фильтр нижних частот (см. sendTwilioAudio).
    sendTwilioAudio(
      session,
      base64ToInt16(inline.data),
      parsePcmRate(inline.mimeType || inline.mime_type)
    );
  }
  if (pick(message, 'toolCall', 'tool_call')) {
    session.toolTail = (session.toolTail || Promise.resolve())
      .then(() => handleLiveToolCall(session, message))
      .catch((error) => console.warn('voiceLive tool:', error.message));
  }
  if (pick(content, 'turnComplete', 'turn_complete') === true) {
    onLiveTurnFinished(session);
  }
  const goAway = pick(message, 'goAway', 'go_away');
  if (goAway) {
    const left = pick(goAway, 'timeLeft', 'time_left');
    console.log(`voiceLive goAway ${session.callSid} timeLeft=${left}`);
    resumeLive(session, 'goAway');
  }
}

/// Один обработчик сокета на оба провайдера: различаются только разбор
/// сообщений и адрес, а учёт обрывов и переключение шагов обязаны быть общими.
function attachLiveSocket(session, ws, step) {
  const { provider, model } = step;
  session.socketGen = (session.socketGen || 0) + 1;
  ws.liveGen = session.socketGen;
  session.provider = provider;
  session.liveModel = model;
  session.liveError = '';
  session.responseActive = false;
  session.engine = LIVE_ENGINE_BY_PROVIDER[provider] || 'gemini-live';
  if (provider === 'openai') {
    session.openaiWs = ws;
    session.openaiModel = model;
    session.geminiWs = null;
  } else {
    session.geminiWs = ws;
    session.geminiModel = model;
    session.openaiWs = null;
  }
  const setupTimer = setTimeout(() => {
    if (session.ready || ws.liveGen !== session.socketGen) return;
    session.liveError = session.liveError || 'setup timeout';
    try {
      ws.close();
    } catch (_) {}
  }, 8000);
  ws.on('open', () => {
    if (session.livePing) clearInterval(session.livePing);
    session.livePing = setInterval(() => {
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
      if (provider === 'openai') handleOpenaiMessage(session, raw);
      else handleGeminiMessage(session, raw);
    } catch (error) {
      console.error(`voiceLive ${provider} message:`, error.message);
    }
  });
  ws.on('error', (error) => {
    if (ws.liveGen !== session.socketGen) return;
    session.liveError = error.message || `${provider} socket error`;
    console.warn(`voiceLive ${provider} socket ${session.callSid}: ${session.liveError}`);
  });
  ws.on('close', (code, reason) => {
    clearTimeout(setupTimer);
    if (session.livePing && ws.liveGen === session.socketGen) {
      clearInterval(session.livePing);
      session.livePing = null;
    }
    if (ws.liveGen !== session.socketGen) return;
    const wasReady = session.ready;
    session.connecting = false;
    session.ready = false;
    session.speaking = false;
    session.promptedTurn = false;
    session.responseActive = false;
    if (session.geminiWs === ws) session.geminiWs = null;
    if (session.openaiWs === ws) session.openaiWs = null;
    // Причина закрытия: раньше в журнале был только код 1011, и понять, что
    // именно сломалось у Gemini 01.10.2026, было уже нельзя.
    const why = String(reason || '').replace(/\s+/g, ' ').slice(0, 160);
    console.log(
      `voiceLive ${provider} close ${session.callSid} code=${code} ` +
        `started=${Boolean(session.liveStarted)} model=${model} reason="${why}"`
    );
    // Попытка с эмоциональной подачей не дожила до готовности: следующий раз
    // эту модель поднимаем на v1beta и без флага.
    if (!wasReady && step.affective) {
      session.noAffective = true;
      console.warn(`voiceLive ${session.callSid} affective dialog refused, retrying plain`);
    }
    if (session.closed || session.wantHangup) return;
    if (!session.liveStarted) {
      if (typeof session.retryLive === 'function') session.retryLive();
      return;
    }
    // Плановые переподключения (goAway) сюда не попадают — их сокет уже
    // заменён. Значит, это сбой: считаем его.
    session.liveFailures = Number(session.liveFailures || 0) + 1;
    session.modelFailures = Number(session.modelFailures || 0) + 1;
    setTimeout(() => resumeLive(session, `close ${code}`), 200);
  });
}

function attachGeminiSocket(session, ws, model) {
  attachLiveSocket(session, ws, { provider: 'gemini', model });
}

const NO_TOOLS_NOTE =
  '\nLive calendar tools are unavailable. Do not claim a fresh lookup or a saved cancellation. Ask the caller to text us for a change.';
const RESTART_NOTE =
  '\n\nThe live audio session restarted. Continue this same phone call. Do not greet again.';

/// Поднять конкретный шаг цепочки. Инструкции у провайдеров одни и те же —
/// расходятся только оболочка настройки и адрес сокета.
function openLiveStep(session, step, { tools, extra = '', resumeHandle = '' }) {
  const text = `${session.systemText || ''}${tools ? '' : NO_TOOLS_NOTE}${extra}`;
  if (step.provider === 'openai') {
    session.setupPayload = buildOpenaiSession(session, tools, text);
    attachLiveSocket(session, openOpenaiSocket(deps.openaiApiKey, step.model), step);
    return;
  }
  const affective = affectiveFor(session, step.model);
  session.setupPayload = buildSetup(step.model, text, tools, resumeHandle, {
    voice: session.geminiVoice,
    affective,
  });
  attachLiveSocket(
    session,
    openGeminiSocket(deps.geminiApiKey, step.model, affective),
    { ...step, affective }
  );
}

/// Live рвётся раз за разом — дальше звонок ведёт резервный Gather (Twilio
/// слушает сам, текстовая модель, синтез). Медленнее, зато звонящего слышно.
function giveUpLive(session, reason) {
  if (session.liveFailed) return;
  console.warn(`voiceLive gave up ${session.callSid} drops=${session.liveFailures} last=${reason}`);
  clearSilence(session);
  markLiveFailed(session, `live dropped ${session.liveFailures} times, last: ${reason}`)
    .then(() => closeTwilio(session));
}

function resumeLive(session, reason, { switchModel = false } = {}) {
  if (session.closed || session.wantHangup) return;
  if (session.connecting) return;
  session.resumeAttempts = Number(session.resumeAttempts || 0) + 1;
  if (session.resumeAttempts > 40) {
    console.warn(`voiceLive resume gave up ${session.callSid} after ${reason}`);
    closeTwilio(session);
    return;
  }
  let step = currentStep(session);
  if (!step) return;
  if (reason !== 'goAway') {
    // 01.10.2026 Gemini 3.1 падал с 1011 раз в 10–30 с весь звонок, а релей
    // каждый раз поднимал ту же модель. Первый обрыв — переподключаемся к ней
    // же (с ручкой сессии), второй подряд — уходим на следующий шаг цепочки
    // (у OpenAI это уже Gemini), после LIVE_FAILURE_LIMIT обрывов — в Gather.
    if (Number(session.liveFailures || 0) >= LIVE_FAILURE_LIMIT) {
      giveUpLive(session, reason);
      return;
    }
    if (switchModel || Number(session.modelFailures || 0) >= MODEL_FAILURES_TO_SWITCH) {
      if (hasNextLiveStep(session)) {
        session.chainAt = Number(session.chainAt || 0) + 1;
        const next = currentStep(session);
        console.warn(
          `voiceLive switch ${session.callSid} ${step.provider}:${step.model} -> ` +
            `${next.provider}:${next.model} (${reason})`
        );
        step = next;
        session.modelSwitches = Number(session.modelSwitches || 0) + 1;
        // Ручка сессии привязана к модели; историю новой передаёт greetLive.
        session.resumeHandle = null;
      } else if (!switchModel) {
        giveUpLive(session, reason);
        return;
      }
      session.modelFailures = 0;
    }
  }
  session.ready = false;
  session.connecting = true;
  session.greeted = true;
  session.needsContinue = true;
  const old = liveSocket(session);
  session.geminiWs = null;
  session.openaiWs = null;
  session.socketGen = (session.socketGen || 0) + 1;
  if (old) {
    try {
      old.close();
    } catch (_) {}
  }
  console.log(
    `voiceLive resume ${session.callSid} ${reason} ${step.provider}:${step.model} ` +
      `attempt=${session.resumeAttempts} drops=${Number(session.liveFailures || 0)} ` +
      `handle=${Boolean(session.resumeHandle)}`
  );
  openLiveStep(session, step, {
    tools: session.liveTools !== false,
    extra: RESTART_NOTE,
    resumeHandle: session.resumeHandle,
  });
}

/// Начало живого звонка: строим цепочку провайдеров и идём по ней сверху вниз.
/// Если не поднялся никто, второй проход идёт без инструментов — звонок без
/// календаря всё ещё лучше, чем звонок без голоса.
function startLiveSession(session) {
  session.liveChain = buildLiveChain(session);
  // Одна строка на звонок, по которой видно, почему говорит именно этот
  // провайдер: ключи (только наличие, не значения), что выбрано в настройках и
  // какая цепочка из этого собралась. Без неё пропавший ключ выглядит ровно
  // как сознательный выбор Gemini, и его ищут часами.
  console.log(
    `voiceLive chain ${session.callSid} key:openai=${deps && deps.openaiApiKey ? 'yes' : 'NO'} ` +
      `key:gemini=${deps && deps.geminiApiKey ? 'yes' : 'NO'} ` +
      `settings=${session.voiceProvider || '-'} ` +
      `steps=[${session.liveChain.map((step) => `${step.provider}:${step.model}`).join(' -> ') || 'пусто'}]`
  );
  if (!session.liveChain.length) {
    markLiveFailed(session, 'no live voice provider configured').then(() => closeTwilio(session));
    return;
  }
  let index = 0;
  let tools = true;
  session.retryLive = () => {
    if (session.closed || session.ready || session.connecting || session.liveStarted) return;
    if (index >= session.liveChain.length) {
      if (tools) {
        tools = false;
        index = 0;
      } else {
        session.liveGiveUp = Number(session.liveGiveUp || 0) + 1;
        markLiveFailed(session, session.liveError || 'live model failed');
        if (session.liveGiveUp > 8) return;
        session.liveRetryTimer = setTimeout(() => {
          if (session.closed || session.ready || session.liveStarted) return;
          index = 0;
          tools = false;
          session.retryLive();
        }, 2500);
        return;
      }
    }
    const step = session.liveChain[index++];
    session.chainAt = index - 1;
    session.connecting = true;
    session.liveTools = tools;
    console.log(
      `voiceLive connect ${session.callSid} ${step.provider}:${step.model} tools=${tools}`
    );
    openLiveStep(session, step, { tools });
  };
  session.retryLive();
}

async function hydrateCall(session, callSid, fromNumber) {
  const { callsRef, findClientByPhone } = deps;
  session.callSid = callSid || session.callSid;
  session.fromNumber = fromNumber || session.fromNumber;
  const snap = session.callSid ? await callsRef.doc(session.callSid).get() : null;
  const data = snap && snap.exists ? snap.data() || {} : {};
  const reception = data.aiReception || {};
  const known = await findClientByPhone(data.fromNumber || session.fromNumber);
  session.clientId = (known && known.id) || data.clientId || '';
  session.appointmentOnly = reception.appointmentOnly === true;
  session.pendingCancellation = reception.pendingCancellation || null;
  // Пункт 17: без этого секретарь не знает, что заказ уже принят.
  session.openJobBrief = deps.voiceOpenJobBrief
    ? await deps.voiceOpenJobBrief({
        phone: data.fromNumber || session.fromNumber,
        clientId: (known && known.id) || data.clientId || '',
      })
    : '';
  session.extracted = reception.extracted || {};
  session.history = Array.isArray(reception.history) ? reception.history : [];
  session.transcription = data.transcription || '';
  session.language = reception.language || 'en';
  session.turns = Number(reception.turns || 0);
  session.clientName = voiceFacts.usableClientName(
    (known && (known.fullName || known.name)) || ''
  );
  session.knownAddress = voiceFacts.clientAddressFrom(known) || '';
  if (voiceFacts.isPlaceholderClientName(session.extracted.client_name)) {
    delete session.extracted.client_name;
  }
  if (session.clientName && !session.extracted.client_name) {
    session.extracted.client_name = session.clientName;
  }
  session.fromNumber = data.fromNumber || session.fromNumber;
  const lastGreeting = [...session.history].find((item) => item && item.role === 'assistant');
  if (lastGreeting && lastGreeting.text) session.greeting = lastGreeting.text;
  if (session.callSid) sessions.set(session.callSid, session);
}

async function onLiveStart(session, message) {
  const start = message.start || {};
  const custom = start.customParameters || {};
  if (!relayKeyOk(custom)) {
    session.closed = true;
    try {
      session.twilioWs.close(1008, 'unauthorized');
    } catch (_) {}
    return;
  }
  session.authorized = true;
  clearAuthGrace(session);
  session.startedAt = Date.now();
  session.streamSid = start.streamSid || message.streamSid;
  // Настоящий движок проставит attachLiveSocket, когда станет известно, кто
  // из провайдеров поднялся.
  session.engine = 'gemini-live';
  // Продолжение после обрыва потока: не здороваться заново, подхватить разговор
  // с того места, где он оборвался (историю поднимает hydrateCall ниже).
  session.resumedStream = String(custom.resume || '') === '1';
  session.greetingSpoken = String(custom.greetingSpoken || '') === '1';
  if (custom.greeting) session.greeting = String(custom.greeting);
  const [profile] = await Promise.all([
    deps.getAiAnswerSettings(),
    hydrateCall(session, custom.callSid || start.callSid, start.from || custom.from),
  ]);
  if (custom.greeting) session.greeting = String(custom.greeting);
  if (session.resumedStream && (session.history || []).length) {
    session.greetingSpoken = true;
    session.needsContinue = true;
    console.log(
      `voiceRelay resumed stream ${session.callSid} turns=${(session.history || []).length}`
    );
  }
  // Провайдер и голоса берём из settings/ai_voice; что не узнали — по
  // умолчанию. Ключи проверяет buildLiveChain.
  session.voiceProvider = pickFrom(profile.voiceProvider, VOICE_PROVIDERS, DEFAULT_VOICE_PROVIDER);
  session.openaiModel = String(profile.openaiModel || '').trim() || DEFAULT_OPENAI_MODEL;
  session.openaiVoice = pickFrom(profile.openaiVoice, OPENAI_VOICES, DEFAULT_OPENAI_VOICE);
  session.openaiSpeed = profile.openaiSpeed;
  session.geminiVoice = pickFrom(profile.geminiVoice, GEMINI_VOICES, DEFAULT_GEMINI_VOICE);
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
  startLiveSession(session);
}

async function onLiveStop(session) {
  if (session.closed && session.finalized) return;
  session.closed = true;
  clearSessionTimers(session);
  if (session.hangupTimer) {
    clearTimeout(session.hangupTimer);
    session.hangupTimer = null;
  }
  if (session.twilioKeepalive) {
    clearInterval(session.twilioKeepalive);
    session.twilioKeepalive = null;
  }
  flushPartials(session);
  applyLocalExtract(session);
  closeLive(session);
  if (session.liveFailed) return;
  try {
    const lastUser = lastHistoryText(session, 'user');
    const lastAsst = lastHistoryText(session, 'assistant');
    if (lastUser || lastAsst) {
      const facts = await extractFacts(session, lastUser, lastAsst);
      session.extracted = facts.extracted;
      session.createJob = voiceFacts.isServiceDeclined(session.extracted)
        ? false
        : session.createJob || facts.createJob || deps.hasEnoughForJob(session.extracted);
      session.wantHangup = session.wantHangup || facts.done;
    }
    await persistSession(session, {
      done: true,
      createJob: session.createJob || deps.hasEnoughForJob(session.extracted),
      serviceDeclined: voiceFacts.isServiceDeclined(session.extracted),
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
    session.clientId = (known && known.id) || data.clientId || '';
    session.appointmentOnly = reception.appointmentOnly === true;
    session.pendingCancellation = reception.pendingCancellation || null;
    session.extracted = reception.extracted || {};
    session.history = Array.isArray(reception.history) ? reception.history : [];
    session.transcription = data.transcription || '';
    session.language = reception.language || 'en';
    session.turns = Number(reception.turns || 0);
    session.clientName = voiceFacts.usableClientName(
      (known && (known.fullName || known.name)) || ''
    );
    session.knownAddress = voiceFacts.clientAddressFrom(known) || '';
    if (voiceFacts.isPlaceholderClientName(session.extracted.client_name)) {
      delete session.extracted.client_name;
    }
    if (session.clientName && !session.extracted.client_name) {
      session.extracted.client_name = session.clientName;
    }
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
    ].slice(-400);
    session.transcription = appendTranscript(
      appendTranscript(session.transcription, `Client: ${userText}`),
      `AI: ${say}`
    );
    const facts = await extractFacts(session, userText, say);
    if (gen !== session.gen) return;
    session.extracted = facts.extracted;
    const createJob = facts.createJob || hasEnoughForJob(session.extracted);
    await persistSession(session, { done: false, createJob });
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
    outMulaw: EMPTY_MULAW,
    userPartial: '',
    assistantPartial: '',
    authorized: false,
  };
  armAuthGrace(ws, session);
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
  ws.on('close', (code, reason) => {
    // Раньше здесь молчали, и обрыв потока не оставлял в журнале ничего —
    // приходилось гадать, кто закрыл соединение.
    const lived = session.startedAt ? Math.round((Date.now() - session.startedAt) / 1000) : null;
    // Итог звонка одной строкой: heard=0 при живом звонящем — Live его не слышал.
    console.log(
      `voiceRelay twilio close ${session.callSid || '?'} code=${code} lived=${lived}s ` +
        `live=${liveSocket(session) ? 'up' : 'down'} ready=${Boolean(session.ready)} ` +
        `voice=${session.provider || '-'}:${session.liveModel || '-'} ` +
        `heard=${Number(session.heardChunks || 0)} ` +
        `turns=${Number(session.turns || 0)} drops=${Number(session.liveFailures || 0)} ` +
        `switches=${Number(session.modelSwitches || 0)} silence=${Number(session.silenceStage || 0)} ` +
        `hangup=${session.hangupReason || '-'} reason="${String(reason || '').slice(0, 80)}"`
    );
    session.closed = true;
    clearSessionTimers(session);
    if (session.twilioKeepalive) {
      clearInterval(session.twilioKeepalive);
      session.twilioKeepalive = null;
    }
    closeLive(session);
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

// Проверка секрета. Ключ приходит НЕ в адресе: Twilio выбрасывает query-строку
// из <Stream url>, и проверка на upgrade отбивала настоящие звонки — разговор
// уходил в медленный резервный Gather. Ключ лежит в <Parameter name="k">, то
// есть виден только в событии start. Поэтому апгрейд пускаем, а сокет без
// подтверждённого ключа закрываем: сам по себе он ничего не стоит, сессию
// Gemini поднимает только onLiveStart.
const RELAY_AUTH_GRACE_MS = 15000;

function relayKeyOk(custom) {
  const expected = process.env.VOICE_RELAY_KEY;
  if (!expected) {
    console.warn('voiceRelay: VOICE_RELAY_KEY not set, stream left open');
    return true;
  }
  const got = String((custom && (custom.k || custom.key)) || '');
  if (got === expected) return true;
  console.warn('voiceRelay: bad or missing k in stream parameters');
  return false;
}

function armAuthGrace(ws, session) {
  session.authGrace = setTimeout(() => {
    session.authGrace = null;
    if (session.authorized || session.closed) return;
    console.warn('voiceRelay: closing socket, no valid k within grace');
    try {
      ws.close(1008, 'unauthorized');
    } catch (_) {}
  }, RELAY_AUTH_GRACE_MS);
}

function clearAuthGrace(session) {
  if (session.authGrace) {
    clearTimeout(session.authGrace);
    session.authGrace = null;
  }
}

const relayHttpServers = new WeakSet();
const upgradedSockets = new WeakMap();

function preserveUpgradedSockets(httpServer) {
  if (!httpServer || relayHttpServers.has(httpServer)) return;
  const previous = httpServer.rawListeners('clientError');
  for (const listener of previous) httpServer.removeListener('clientError', listener);
  httpServer.on('clientError', (error, socket) => {
    const upgraded = upgradedSockets.has(socket);
    if (upgraded && error.code === 'ERR_HTTP_REQUEST_TIMEOUT') {
      if (!upgradedSockets.get(socket)) {
        console.log('voiceRelay: preserved WebSocket after HTTP request timeout');
        upgradedSockets.set(socket, true);
      }
      return;
    }
    if (previous.length) {
      for (const listener of previous.slice()) {
        const onceIndex = listener.listener ? previous.indexOf(listener) : -1;
        if (onceIndex >= 0) previous.splice(onceIndex, 1);
        listener.call(httpServer, error, socket);
      }
      return;
    }
    if (
      !upgraded && socket.writable &&
      (!socket._httpMessage || !socket._httpMessage._headerSent)
    ) {
      const status = {
        ERR_HTTP_REQUEST_TIMEOUT: 408,
        HPE_HEADER_OVERFLOW: 431,
        HPE_CHUNK_EXTENSIONS_OVERFLOW: 413,
      }[error.code] || 400;
      socket.write(`HTTP/1.1 ${status} ${STATUS_CODES[status]}\r\nConnection: close\r\n\r\n`);
    }
    socket.destroy(error);
  });
  relayHttpServers.add(httpServer);
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
    preserveUpgradedSockets(incoming.socket && incoming.socket.server);
    const server = getWss();
    server.handleUpgrade(incoming, incoming.socket, Buffer.alloc(0), (ws) => {
      upgradedSockets.set(incoming.socket, false);
      server.emit('connection', ws, incoming);
    });
    return;
  }
  res.status(200).send('aiVoiceRelay');
}

module.exports = {
  init,
  handleRequest,
  greetLive,
  persistSession,
  liveSystemPrompt,
  buildSetup,
  buildOpenaiSession,
  runAppointmentTool,
  // Внутренние шаги живого звонка — только для тестов.
  _internals: {
    handleGeminiMessage,
    handleOpenaiMessage,
    startLiveSession,
    startGeminiLive: startLiveSession,
    buildLiveChain,
    sendCallerAudio,
    sendTwilioMulaw,
    liveModels: uniqueModels,
    voices: { OPENAI_VOICES, GEMINI_VOICES, DEFAULT_OPENAI_VOICE, DEFAULT_GEMINI_VOICE },
    timing: {
      SILENCE_MS, PREFIX_MS, STALL_MS, SILENCE_CHECK_MS, SILENCE_HOLD_MS, SILENCE_GIVEUP_MS,
      SILENCE_HANGUP_MS, DEAF_VOICED_MS, LIVE_FAILURE_LIMIT, TWILIO_FRAME_BYTES,
    },
  },
};
