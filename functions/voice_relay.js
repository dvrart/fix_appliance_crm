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
const voiceFacts = require('./voice_facts');

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

function outsideAreaRule(profile, thenWhat) {
  const area = String((profile && profile.serviceArea) || '').trim();
  if (!area) {
    return `- Do not refuse a caller based on town names from memory. Coverage comes from the owner's service-area map, and it is not set.`;
  }
  return `- Outside this service area (${area}): we don't travel there, then ${thenWhat}.`;
}

function compactKnown(session) {
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
  if (extracted.slot_ok === false) {
    have.push(
      `wanted ${[extracted.scheduled_date, extracted.scheduled_time].filter(Boolean).join(' ')} but that 2-hour window is TAKEN — offer ${extracted.slot_alts || 'another time the same day'}`
    );
  } else if (extracted.scheduled_date || extracted.scheduled_time) {
    have.push(
      `visit ${[extracted.scheduled_date, extracted.scheduled_time].filter(Boolean).join(' ')}`
    );
  }
  if (extracted.wants_callback) have.push('live callback requested');
  if (extracted.has_job_site) {
    const who = [extracted.contact_on_site_name, extracted.contact_on_site_phone]
      .filter(Boolean)
      .join(' ');
    if (who) have.push(`on-site ${who}`);
  }
  const need = [];
  if (!extracted.problem_description) need.push('what broke');
  if (!extracted.appliance_type || !extracted.brand) need.push('kind and brand');
  if (!extracted.client_name) need.push('first name');
  if (!extracted.wants_callback && !extracted.address) {
    need.push(
      session.knownAddress
        ? 'whether the repair is at the home on file or another address'
        : 'street and town of the repair'
    );
  }
  if (
    !extracted.wants_callback &&
    (!extracted.scheduled_date ||
      !extracted.scheduled_time ||
      extracted.slot_ok === false)
  ) {
    need.push(
      extracted.has_job_site
        ? 'day AND clock time — they gave another repair address, do not hang up, book the visit'
        : 'day and time'
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
  return `You are the virtual receptionist on a live phone for FixApplianceCA, home appliance repair in Ontario.
The technician didn't pick up. You answered. Sound like a polite, educated person in a small shop — never an IVR, never a chatbot. Easy, warm, never freeze or trail off.

Caller phone (do not ask for it): ${session.fromNumber || 'unknown'}
Today (America/Toronto): ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}
Shop hours: ${hours} America/Toronto, Monday–Friday visits only.
Each visit is 2 hours (one job). Never confirm a taken window. If they want a busy time, offer another time the SAME weekday first.
${session.calendarBrief || ''}

Owner rules:
${profile.instructions}

TALK LIKE A PERSON:
- Short spoken turns. Usually one sentence. Never more than two.
- Then listen. Do not fill silence with extra questions.
- If they ask a side question, answer it briefly and well, then return to the next missing repair fact. Never stay on the side topic. Never go silent.
- Contractions: what's, that's, I'll, you're.
- If they already told you something, do not ask it again. Jump to the next gap.
- First react like a human ("oh, the fridge isn't cooling"), then one missing thing if you still need it.
- Never say: got it, I understand, please provide, I have noted, certainly, how may I assist, I am an AI.
- No lists. No "thank you for that information".
- After you greet them, wait for them to talk. Do not keep talking.
- Do not greet until you are told the exact greeting.
- Speak English only. Understand any language, including Russian, but always answer in English.
- Never guess a street. Write names as normal names (Artem).
- Returning caller: use their first name. Ask if the repair is at the address on file. Same → job. Different → job site, who will be there, that phone.
- New caller: ask the repair address. Same place → client card and job. Another place → second site plus who will be there.
- Ask who will be home only if the repair is not at the owner's house.
- HOURS: you take orders 24/7. Visits Monday–Friday ${hours}. Saturday and Sunday: no visit — offer a weekday. Holiday: take the order; technician must agree.
- Bare clock times ("2", "at 2", "two") mean 2 p.m., not 2 a.m., unless they said morning or a.m. Write the visit time. Do not only say it.
- Each visit is 2 hours. If they want 2 p.m., you need 2–4 p.m. free. If that window is taken, do not book it — offer another time that weekday.
- If they want 6 a.m. or a start after 7 p.m. (would end after 9 p.m.), do not book it. Say we don't work then. Offer a time inside ${hours} that ends by 9 p.m.
- If they want a live person: say a technician will call back within 30 minutes. Do not grill for a visit time.
- Price: do not mention money unless they asked. If they asked: a service call is $99. If they approve the repair after diagnosis, they do not pay the service call — only the repair.
- We repair washers, dryers, dishwashers, gas ovens, electric ovens, electric cooktops, fridges, freezers, microwaves. Not gas cooktops, TVs, laptops, phones, or cars.
- When you have a name, what broke, where to go, and a FREE weekday window — or they asked for a callback — confirm once: "I'll pass this to the tech." Ask them to text a model-sticker photo to this number. Ask if anything else. If they say no, say "Have a good day." Do not hang up. The caller hangs up.
- Angry caller: a person from the company will call within 30 minutes. Stay polite. Do not hang up for them.
${outsideAreaRule(profile, 'politely say we do not travel there')}

You cannot hang up. There is no end_call. After "Have a good day," wait. If they go quiet, keep waiting.`;
}

function buildSetup(model, systemText, withTools, resumeHandle) {
  const setup = {
    model: model.startsWith('models/') ? model : `models/${model}`,
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: {
        languageCode: 'en-US',
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
    // Audio is ~25 tokens/s. Old 8k trigger (~5 min) froze her mid-word.
    // Compress only on long calls; keep a large recent window so the chat continues.
    contextWindowCompression: {
      triggerTokens: 32000,
      slidingWindow: { targetTokens: 18000 },
    },
  };
  return { setup };
}

async function streamSpokenReply(ws, session, userText) {
  const { generateVoiceTextStream, spokenText, getAiAnswerSettings } = deps;
  const today =
    (deps.torontoTodayYmd && deps.torontoTodayYmd()) || new Date().toISOString().slice(0, 10);
  const profile = await getAiAnswerSettings();
  const extracted = session.extracted || {};
  const history = (session.history || []).slice(-12);
  const flow = deps.voiceCallFlow || '';
  const prompt = `You are a real receptionist on a live phone for ${profile.companyName}, appliance repair in Ontario.
The technician didn't pick up. You answered. Sound like a warm woman in a small shop — never an IVR, never a chatbot.

Caller phone (do not ask for it): ${session.fromNumber || 'unknown'}
Today (America/Toronto): ${today}
Known client: ${session.clientName || 'new'}
Known address: ${session.knownAddress || 'none'}
Shop hours: ${profile.workHours || '7 a.m. to 9 p.m.'}
${session.calendarBrief || ''}

Owner rules:
${profile.instructions}

${flow}

TALK LIKE A PERSON:
- One short spoken turn. Usually one sentence. Never more than two.
- Then listen. Do not freeze or go silent. If they ask a side question, answer briefly, then return to the repair.
- Contractions: what's, that's, I'll, you're.
- If they already told you something, do not ask it again. Jump to the next gap.
- First react like a human ("oh, the fridge isn't cooling"), then one missing thing.
- If Known client is not "new", use their name. Ask if the repair is at the address on file.
- Never say: got it, I understand, please provide, I have noted, certainly, how may I assist, I am an AI.
- No lists. No "thank you for that information".
- LIVE CALLBACK: if they want a person / the technician to call them, do not ask address or time. If type or brand is missing, ask once. Then say: "Okay, I'll pass your details along and a technician will call you back shortly." Then ask if anything else.
- When you have first name, address, what broke, type/brand, AND a free weekday window: confirm once, ask for a model-sticker photo, then ask if anything else. If they say no, say "Have a good day." Do not hang up.
- Saturday and Sunday: no visit. Offer a weekday. Holiday: take the order; technician must agree.
- Each visit is 2 hours. If the calendar says that window is taken, do not confirm it — offer another time the same weekday.
- Thanks, okay, yes, or confirming the time is NOT goodbye. Stay on the line.
- LAPTOP / COMPUTER / GAS COOKTOP: do not hang up. Say we only repair the listed home appliances, then ask if anything else.
- Angry caller: a person from the company will call within 30 minutes, then ask if you can help with anything else.
${outsideAreaRule(profile, 'stop')}
- Speak English only. Understand Russian if they use it, but never answer in Russian or any other language.

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
scheduled_date must be YYYY-MM-DD. "tomorrow" = the next calendar day after ${today}. Never leave the date empty if they named a day.
scheduled_time must be HH:mm 24-hour. "11:00", "at 11", "eleven o'clock" → 11:00. "2", "at 2", "two", "around two" on a repair call → 14:00 unless they said morning or a.m. Never leave time empty if they named a clock time.
client_name: a normal short name as spoken (Artem). NEVER a phonetic spelling or letter-by-letter mash (not "R Tamiyzhpurush"). If the receptionist already used a first name, copy that spelling.
address: the REPAIR address (where the technician drives). Street number + street name. null if mumbled.
owner_address: the caller's home if it is different from the repair address.
has_job_site=true if the repair is not at the caller's own home (tenant, rental, another house).
If the spoken street is not the known home, has_job_site=true, address=repair place, owner_address=home.
wants_callback=true if they asked to speak to a live person, the technician, the master, or to get a call back from a human. After that, do not treat missing time as incomplete.
service_declined=true if we cannot take the job: outside the service area, not a household appliance (laptop/computer/phone), they cancelled, or we told them we don't do that work. Then createJob=false.
Return STRICT JSON only:
{"client_name":null,"address":null,"city":null,"postal_code":null,"owner_address":null,"appliance_type":null,"brand":null,"model":null,"problem_description":null,"scheduled_date":null,"scheduled_time":null,"wants_callback":false,"has_job_site":false,"contact_on_site_name":null,"contact_on_site_phone":null,"notes":null,"service_declined":false,"decline_reason":null,"done":false,"createJob":false}

done=true ONLY if the caller said goodbye/bye/that's all, or they declined "anything else". Never because they said thanks, okay, yes, or the visit is already booked. Never for a laptop, computer, or something we don't repair.
createJob=true if we should create a repair job (enough info OR live callback OR angry with some details). NEVER if service_declined. Not for a laptop/computer unless they also have a household appliance.
Enough info for a booked visit = first name + address + problem + type/brand + day and time.
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
  const reception = {
    history: session.history,
    extracted: session.extracted,
    language: session.language || 'en',
    turns: session.turns || 0,
    engine: session.engine || 'relay',
    liveFailed: false,
  };
  if (extra && extra.done) reception.done = true;
  const declined =
    voiceFacts.isServiceDeclined(session.extracted) ||
    Boolean(extra && extra.serviceDeclined);
  reception.createJob = Boolean(extra && extra.createJob) && !declined;
  reception.serviceDeclined = declined;
  await callsRef.doc(session.callSid).set(
    {
      answeredBy: 'ai',
      extractedData: session.extracted || {},
      transcription: session.transcription,
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
  if (voiceFacts.isServiceDeclined(extracted)) {
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
  if (session.extractTimer) {
    clearTimeout(session.extractTimer);
    session.extractTimer = null;
  }
  if (session.persistTimer) {
    clearTimeout(session.persistTimer);
    session.persistTimer = null;
  }
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

function armReplyWatchdog(session) {
  clearReplyWatchdog(session);
  session.replyWatch = setTimeout(() => {
    if (session.closed || session.wantHangup || !session.ready) return;
    if (session.assistantPartial) return;
    const lastUser = lastHistoryText(session, 'user');
    if (!lastUser) return;
    session.stallNudge = Number(session.stallNudge || 0) + 1;
    console.warn(`voiceLive stall ${session.callSid} n=${session.stallNudge}`);
    if (session.stallNudge > 1) return;
    nudgeKeepTalking(session, lastUser);
  }, 8000);
}

function clearReplyWatchdog(session) {
  if (session.replyWatch) {
    clearTimeout(session.replyWatch);
    session.replyWatch = null;
  }
}

function nudgeKeepTalking(session, lastUser) {
  if (!session || !session.geminiWs || session.geminiWs.readyState !== 1) return;
  const laptop = voiceFacts.looksOutOfScopeItem(lastUser)
    ? ' They asked about a laptop or computer. Speak now: we only repair household appliances (fridge, washer, dryer, stove, dishwasher, microwave), not laptops. Then ask if you can help with anything else.'
    : '';
  sendJson(session.geminiWs, {
    clientContent: {
      turns: [
        {
          role: 'user',
          parts: [
            {
              text: `The caller is still on the line. Speak now. Do not hang up. Do not stay silent.${laptop}`,
            },
          ],
        },
      ],
      turnComplete: true,
    },
  });
}

function continueLivePrompt(session) {
  const bits = (session.history || []).slice(-8).map((item) => {
    const who = item.role === 'assistant' ? 'You' : 'Caller';
    return `${who}: ${item.text}`;
  });
  return `The phone call is still connected after a brief audio glitch. Same caller, not a new call.
${compactKnown(session)}
Recent turns:
${bits.join('\n') || '(still collecting details)'}
If they say hello / are you there, they are checking the line — say a short "yes, I'm here" and continue the last unanswered question.
Do not greet from scratch. Do not say goodbye. Do not call end_call. Keep collecting.`;
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
    if (session.pendingAudio.length > 200) session.pendingAudio.shift();
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
  if (field === 'userPartial') {
    const lastAsst = lastHistoryText(session, 'assistant');
    if (isSameVoiceLine(lastAsst, value)) return;
  }
  session.language = 'en';
  session[field] = value;
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
  if (!session.ready || !session.geminiWs) return;
  if (session.needsContinue) {
    session.needsContinue = false;
    session.greeted = true;
    const turns = [];
    if (!session.resumeHandle) {
      for (const item of (session.history || []).slice(-8)) {
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
      parts: [{ text: continueLivePrompt(session) }],
    });
    sendJson(session.geminiWs, {
      clientContent: {
        turns,
        turnComplete: true,
      },
    });
    return;
  }
  if (session.greeted) return;
  session.greeted = true;
  const greeting = String(
    session.greeting || (deps && deps.defaultVoiceGreeting) || "Hi, you've reached FixApplianceCA. How can I help?"
  ).trim();
  sendJson(session.geminiWs, {
    clientContent: {
      turns: [
        {
          role: 'user',
          parts: [
            {
              text: `The call just connected. Speak ONLY this greeting, then wait silently for the caller. No other words: ${greeting}`,
            },
          ],
        },
      ],
      turnComplete: true,
    },
  });
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
  if (!session || !session.geminiWs || session.geminiWs.readyState !== 1) return;
  session.prematureBye = Number(session.prematureBye || 0) + 1;
  if (session.prematureBye > 2) return;
  const ask =
    'STOP. The caller is still on the line. Do not hang up. Do not say bye, goodbye, see you then, or have a good day. You already confirmed. Stay quiet and wait.';
  sendJson(session.geminiWs, {
    clientContent: {
      turns: [
        {
          role: 'user',
          parts: [{ text: ask }],
        },
      ],
      turnComplete: true,
    },
  });
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
  if (!missing || !session.geminiWs || session.geminiWs.readyState !== 1) return;
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
  sendJson(session.geminiWs, {
    clientContent: {
      turns: [
        {
          role: 'user',
          parts: [
            {
              text:
                `STOP. Do not hang up. Do not say goodbye. Do not say a technician will call back.${otherAddr} You still need ${missing}. Ask for that now, then wait.`,
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
      console.warn(`voiceLive ignored hangup tool ${session.callSid}`);
      cancelHangup(session);
      session.wantHangup = false;
      responses.push({
        id,
        name,
        response: {
          result: 'stay on the line. You cannot hang up. Wait for the caller.',
        },
      });
      continue;
    }
    responses.push({
      id,
      name,
      response: { result: name === 'end_call' ? 'ok, hang up after goodbye' : 'ok' },
    });
  }
  sendJson(session.geminiWs, { toolResponse: { functionResponses: responses } });
}

async function checkLiveSlot(session) {
  if (!deps || !deps.checkBookingSlot) return;
  const extracted = session.extracted || {};
  if (extracted.wants_callback) return;
  if (!extracted.scheduled_date || !extracted.scheduled_time) return;
  const start = voiceFacts.parseScheduledAtDate(extracted);
  if (!start) return;
  const key = `${extracted.scheduled_date}|${extracted.scheduled_time}`;
  if (session.slotKey === key && extracted.slot_ok != null) return;
  session.slotKey = key;
  try {
    const check = await deps.checkBookingSlot(start, {});
    extracted.slot_ok = check.ok;
    extracted.slot_alts = check.ok ? '' : check.altSpeech;
    extracted.slot_blocked = check.ok ? '' : check.wantedLabel;
  } catch (error) {
    console.warn('voiceLive slot:', error.message);
  }
}

async function handleLiveTurnComplete(session) {
  flushPartials(session);
  applyLocalExtract(session);
  await checkLiveSlot(session);
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
    if (session.needsContinue) {
      flushPendingAudio(session);
    } else {
      session.pendingAudio = [];
    }
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
    clearReplyWatchdog(session);
    setPartial(session, 'assistantPartial', output.text, output.finished === true);
  }
  const turn = pick(content, 'modelTurn', 'model_turn') || {};
  for (const part of turn.parts || []) {
    const inline = pick(part, 'inlineData', 'inline_data');
    if (!inline || !inline.data) continue;
    clearReplyWatchdog(session);
    sendTwilioAudio(session, base64ToInt16(inline.data), parsePcmRate(inline.mimeType || inline.mime_type));
  }
  handleLiveToolCall(session, message);
  if (pick(content, 'turnComplete', 'turn_complete') === true) {
    flushPartials(session);
    const lastAsst = lastHistoryText(session, 'assistant');
    if (voiceFacts.saidGoodbye(lastAsst)) {
      console.warn(`voiceLive premature goodbye ${session.callSid} asst="${String(lastAsst).slice(0, 120)}"`);
      cancelHangup(session);
    }
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
  if (session.resumeAttempts > 40) {
    console.warn(`voiceLive resume gave up ${session.callSid} after ${reason}`);
    closeTwilio(session);
    return;
  }
  const model = session.geminiModel || uniqueModels()[0];
  session.ready = false;
  session.connecting = true;
  session.greeted = true;
  session.needsContinue = true;
  const old = session.geminiWs;
  session.geminiWs = null;
  session.socketGen = (session.socketGen || 0) + 1;
  if (old) {
    try {
      old.close();
    } catch (_) {}
  }
  session.setupPayload = buildSetup(
    model,
    `${session.systemText}\n\nThe live audio session restarted. Continue this same phone call. Do not greet again.`,
    false,
    session.resumeHandle
  );
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
  let tools = false;
  session.retryGemini = () => {
    if (session.closed || session.ready || session.connecting || session.liveStarted) return;
    if (index >= models.length) {
      if (tools) {
        tools = false;
        index = 0;
      } else {
        session.liveGiveUp = Number(session.liveGiveUp || 0) + 1;
        markLiveFailed(session, session.geminiError || 'live model failed');
        if (session.liveGiveUp > 8) return;
        session.liveRetryTimer = setTimeout(() => {
          if (session.closed || session.ready || session.liveStarted) return;
          index = 0;
          tools = false;
          session.retryGemini();
        }, 2500);
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
  if (deps.calendarBrief) {
    try {
      session.calendarBrief = await deps.calendarBrief();
    } catch (error) {
      console.warn('voiceLive calendar:', error.message);
      session.calendarBrief = '';
    }
  }
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
  closeGemini(session);
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
    clearSessionTimers(session);
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
