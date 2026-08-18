/**
 * Firebase Functions: Twilio Voice + SMS + Stripe + автоматическая ИИ-обработка звонков.
 *
 * Настройка (см. README в конце файла и /functions/.env.example):
 * 1. cd functions && npm install
 * 2. cp .env.example .env   (и заполнить реальными значениями)
 * 3. firebase deploy --only functions
 */

const functions = require('firebase-functions');
const { onRequest: onRequestV2 } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const twilio = require('twilio');
const crypto = require('crypto');
const { GoogleGenerativeAI } = require('@google/generative-ai');
const voiceRelay = require('./voice_relay');
const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');
const visitSms = require('./visit_sms');

admin.initializeApp();

const TWILIO_ACCOUNT_SID = process.env.TWILIO_ACCOUNT_SID;
const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;
const TWILIO_API_KEY_SID = process.env.TWILIO_API_KEY_SID;
const TWILIO_API_KEY_SECRET = process.env.TWILIO_API_KEY_SECRET;
const TWILIO_TWIML_APP_SID = process.env.TWILIO_TWIML_APP_SID;
const TWILIO_PUSH_CREDENTIAL_SID = process.env.TWILIO_PUSH_CREDENTIAL_SID;
const TWILIO_PHONE_NUMBER = process.env.TWILIO_PHONE_NUMBER;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;

// Идентификатор клиента Twilio Voice, на который приходят входящие звонки
// (регистрируется в приложении через TwilioVoicePlatform.instance).
const MASTER_IDENTITY = process.env.TWILIO_MASTER_IDENTITY || 'master';

const COMPANY_ID = 'fix_appliance_ca';

// Для REST-запросов (отправка SMS, скачивание записи разговора) Twilio
// принимает либо Account SID + Auth Token, либо API Key SID + Secret —
// используем то, что заполнено в .env (API Key приоритетнее).
const REST_AUTH_USER = TWILIO_API_KEY_SID || TWILIO_ACCOUNT_SID;
const REST_AUTH_SECRET = TWILIO_API_KEY_SECRET || TWILIO_AUTH_TOKEN;

const client =
  TWILIO_ACCOUNT_SID && REST_AUTH_USER && REST_AUTH_SECRET
    ? twilio(REST_AUTH_USER, REST_AUTH_SECRET, { accountSid: TWILIO_ACCOUNT_SID })
    : null;

const db = admin.firestore();
const callsRef = db.collection('companies').doc(COMPANY_ID).collection('calls');
const messagesRef = db.collection('companies').doc(COMPANY_ID).collection('messages');
const clientsRef = db.collection('companies').doc(COMPANY_ID).collection('clients');
const jobsRef = db.collection('companies').doc(COMPANY_ID).collection('jobs');
const tokensRef = db.collection('companies').doc(COMPANY_ID).collection('fcm_tokens');

async function getSmsHeader() {
  try {
    const snap = await db
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('documents')
      .get();
    const data = snap.exists ? snap.data() || {} : {};
    return sanitizeSmsHeader(data.smsHeader, data.companyName);
  } catch (_) {
    return '';
  }
}

const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

function setCors(res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
}

function handleOptions(req, res) {
  if (req.method === 'OPTIONS') {
    setCors(res);
    res.status(204).send('');
    return true;
  }
  return false;
}

/** Оставляет только цифры и берёт последние 10 (североамериканский номер без кода страны). */
function normalizePhone(value) {
  if (!value) return '';
  const digits = String(value).replace(/\D/g, '');
  return digits.length > 10 ? digits.slice(-10) : digits;
}

/** Пытается найти существующего клиента по номеру телефона. */
async function findClientByPhone(phone) {
  const normalized = normalizePhone(phone);
  if (!normalized) return null;
  try {
    const snapshot = await clientsRef.get();
    for (const doc of snapshot.docs) {
      const data = doc.data();
      if (normalizePhone(data.phone) === normalized) {
        return { id: doc.id, ...data };
      }
    }
  } catch (error) {
    console.error('findClientByPhone error:', error);
  }
  return null;
}

async function findClientByEmail(email) {
  const normalized = String(email || '').trim().toLowerCase();
  if (!normalized || !normalized.includes('@')) return null;
  try {
    const snapshot = await clientsRef.get();
    for (const doc of snapshot.docs) {
      const data = doc.data();
      if (String(data.email || '').trim().toLowerCase() === normalized) {
        return { id: doc.id, ...data };
      }
    }
  } catch (error) {
    console.error('findClientByEmail error:', error);
  }
  return null;
}

function buildFullAddress(extracted, existingClient) {
  const parts = [
    extracted.address,
    extracted.city,
    extracted.postal_code,
  ].filter((part) => part && String(part).trim());
  if (parts.length) return parts.join(', ');
  return (existingClient && (existingClient.address || '')) || '';
}

function parseScheduledAt(extracted) {
  const dateStr = extracted.scheduled_date;
  if (!dateStr) return null;
  const dateParts = String(dateStr).split('-').map((v) => Number(v));
  if (dateParts.length < 3 || dateParts.some((n) => !n && n !== 0)) return null;
  let hours = 9;
  let mins = 0;
  if (extracted.scheduled_time) {
    const timeParts = String(extracted.scheduled_time).split(':');
    hours = Number(timeParts[0]) || 9;
    mins = Number(timeParts[1]) || 0;
  }
  return admin.firestore.Timestamp.fromDate(
    new Date(dateParts[0], dateParts[1] - 1, dateParts[2], hours, mins)
  );
}

/**
 * После разбора звонка создаёт (или находит) клиента и черновик заявки.
 * Заявка помечается needsReview, чтобы мастер проверил её в приложении.
 */
async function createDraftJobFromCall(callId, extracted, existingClient) {
  const callSnap = await callsRef.doc(callId).get();
  const callData = callSnap.exists ? callSnap.data() || {} : {};
  if (callData.createdJobId) {
    return { jobId: callData.createdJobId, clientId: callData.clientId || null };
  }

  const phone =
    normalizePhone(extracted.client_phone) ||
    normalizePhone(callData.direction === 'inbound' ? callData.fromNumber : callData.toNumber);

  let clientId = existingClient && existingClient.id;
  let clientName =
    (extracted.client_name && String(extracted.client_name).trim()) ||
    (existingClient && existingClient.fullName) ||
    (phone ? `Клиент ${phone}` : 'Клиент');
  const address = buildFullAddress(extracted, existingClient);
  const city = (extracted.city && String(extracted.city).trim()) || '';
  const street = (extracted.address && String(extracted.address).trim()) || '';
  const postal = (extracted.postal_code && String(extracted.postal_code).trim()) || '';

  if (!clientId) {
    const clientDoc = await clientsRef.add({
      fullName: clientName,
      phone: phone || '',
      address,
      locations: [
        {
          id: 'primary',
          street,
          city,
          postalCode: postal,
          contacts: [
            {
              id: 'owner',
              name: clientName,
              phone: phone || '',
              role: 'owner',
              isPrimary: true,
            },
          ],
        },
      ],
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      lastActiveAt: admin.firestore.FieldValue.serverTimestamp(),
      createdByAi: true,
    });
    clientId = clientDoc.id;
  } else {
    const updates = {
      lastActiveAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (extracted.client_name && !existingClient.fullName) {
      updates.fullName = clientName;
    }
    if (address && !existingClient.address) {
      updates.address = address;
    }
    await clientsRef.doc(clientId).set(updates, { merge: true });
  }

  const applianceType = (extracted.appliance_type && String(extracted.appliance_type).trim()) || 'Техника';
  const brand = (extracted.brand && String(extracted.brand).trim()) || '';
  const model = (extracted.model && String(extracted.model).trim()) || '';
  const issue = (extracted.problem_description && String(extracted.problem_description).trim()) || '';
  const scheduledAt = parseScheduledAt(extracted);

  const jobRef = await jobsRef.add({
    clientId,
    clientName,
    clientPhone: phone || '',
    clientAddress: address,
    hasJobSite: extracted.has_job_site === true,
    jobSiteName: extracted.contact_on_site_name || null,
    jobSitePhone: extracted.contact_on_site_phone || null,
    jobSiteAddress: extracted.has_job_site === true ? address : null,
    appliances: [
      {
        type: applianceType,
        brand,
        model,
        serialNumber: extracted.serial_number || '',
        issue,
      },
    ],
    applianceType,
    brand,
    model,
    serialNumber: extracted.serial_number || '',
    description: issue,
    status: 'Вызов',
    priority: '🟢 Обычный',
    scheduledAt,
    scheduledDate: scheduledAt,
    needsReview: true,
    sourceCallId: callId,
    createdByAi: true,
    city,
    documents: [],
    attachments: [],
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { jobId: jobRef.id, clientId };
}

// ============================================================================
// VOICE: Access Token для Twilio Voice SDK (twilio_voice в приложении)
// ============================================================================

exports.twilioAccessToken = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);

  try {
    if (!TWILIO_API_KEY_SID || !TWILIO_API_KEY_SECRET || !TWILIO_TWIML_APP_SID) {
      res.status(500).json({
        error:
          'Twilio Voice не настроен: заполните TWILIO_API_KEY_SID, TWILIO_API_KEY_SECRET, TWILIO_TWIML_APP_SID в functions/.env',
      });
      return;
    }

    const identity = (req.query.identity || req.body?.identity || MASTER_IDENTITY).toString();

    const AccessToken = twilio.jwt.AccessToken;
    const VoiceGrant = AccessToken.VoiceGrant;

    const token = new AccessToken(
      TWILIO_ACCOUNT_SID,
      TWILIO_API_KEY_SID,
      TWILIO_API_KEY_SECRET,
      { identity, ttl: 3600 }
    );

    const voiceGrant = new VoiceGrant({
      outgoingApplicationSid: TWILIO_TWIML_APP_SID,
      incomingAllow: true,
      ...(TWILIO_PUSH_CREDENTIAL_SID ? { pushCredentialSid: TWILIO_PUSH_CREDENTIAL_SID } : {}),
    });
    token.addGrant(voiceGrant);

    res.json({ token: token.toJwt(), identity });
  } catch (error) {
    console.error('Error generating token:', error);
    res.status(500).json({ error: error.message });
  }
});

function digitsOf(value) {
  return String(value || '').replace(/\D/g, '');
}

function firstScalar(value) {
  if (Array.isArray(value)) return value.find(Boolean);
  return value;
}

function isOurTwilioNumber(value) {
  const ours = digitsOf(TWILIO_PHONE_NUMBER);
  const theirs = digitsOf(value);
  return ours.length >= 10 && theirs.length >= 10 && ours.slice(-10) === theirs.slice(-10);
}

function isFromClient(body) {
  const from = String(body.From || '');
  return /^client:/i.test(from) || from === MASTER_IDENTITY;
}

function formatPstn(value) {
  const raw = String(value || '').trim();
  if (!raw || /^client:/i.test(raw) || raw === MASTER_IDENTITY) return null;
  if (isOurTwilioNumber(raw)) return null;
  const digits = digitsOf(raw);
  if (digits.length < 10) return null;
  if (raw.startsWith('+')) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return `+${digits}`;
}

function outboundDestination(body) {
  for (const key of ['phone', 'callee', 'ToNumber', 'to', 'To']) {
    const formatted = formatPstn(firstScalar(body[key]));
    if (formatted) return formatted;
  }
  return null;
}

async function resolveLoggedCallId(callSid) {
  if (!callSid) return callSid;
  const direct = await callsRef.doc(callSid).get();
  if (direct.exists) return callSid;
  if (!client) return callSid;
  try {
    const twilioCall = await client.calls(callSid).fetch();
    if (twilioCall.parentCallSid) {
      console.log(`resolveLoggedCallId: ${callSid} -> parent ${twilioCall.parentCallSid}`);
      return twilioCall.parentCallSid;
    }
  } catch (error) {
    console.warn('resolveLoggedCallId:', error.message);
  }
  return callSid;
}

async function findTwilioRecordingMp3(callSid) {
  if (!client || !callSid || !TWILIO_ACCOUNT_SID) return null;

  async function firstRecording(sid) {
    const recs = await client.recordings.list({ callSid: sid, limit: 5 });
    if (!recs.length) return null;
    return `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Recordings/${recs[0].sid}.mp3`;
  }

  const own = await firstRecording(callSid);
  if (own) return own;
  const children = await client.calls.list({ parentCallSid: callSid, limit: 10 });
  for (const child of children) {
    const url = await firstRecording(child.sid);
    if (url) return url;
  }
  return null;
}

async function downloadRecordingBuffer(recordingUrl) {
  const authHeader =
    'Basic ' + Buffer.from(`${REST_AUTH_USER}:${REST_AUTH_SECRET}`).toString('base64');
  let lastError;
  for (let attempt = 1; attempt <= 5; attempt++) {
    const response = await fetch(recordingUrl, {
      headers: { Authorization: authHeader },
    });
    if (response.ok) {
      return Buffer.from(await response.arrayBuffer());
    }
    lastError = new Error(`Не удалось скачать запись (HTTP ${response.status})`);
    await new Promise((resolve) => setTimeout(resolve, 1500 * attempt));
  }
  throw lastError;
}

function extractJsonObject(text) {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1) {
    throw new Error('Нет JSON в ответе ИИ');
  }
  return JSON.parse(text.slice(start, end + 1));
}

const recordingRuntime = { timeoutSeconds: 300, memory: '1GiB', invoker: 'public' };

function sendTwiml(res, twiml) {
  res.type('text/xml');
  res.send(twiml.toString());
}

function functionUrl(_req, name) {
  const project =
    process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
  return `https://us-central1-${project}.cloudfunctions.net/${name}`;
}

function recordingUrl(req) {
  return functionUrl(req, 'recordingComplete');
}

function dialActionUrl(req) {
  return functionUrl(req, 'dialAction');
}

const DEFAULT_VOICE_GREETING = "Hi, you've reached {company}. How can I help?";

const STALE_VOICE_GREETINGS = [
  "Hi, you've reached {company}. How can I help you today?",
  "Hi, you've reached {company}. I can take your repair details. How can I help you today?",
  "Hi, you've reached {company}. The technician's with a customer, but I can take your details. What's going on?",
];

const DEFAULT_VOICE_INSTRUCTIONS = `Tone: friendly and professional.

You MUST collect:
- full name
- address (street and town)
- a convenient day AND time window for the technician
- what is broken
- how the problem shows up (leaks, won't drain, no heat, error code, noise, etc.)
- where the appliance is in the home, if that matters
- ask if they can text a photo of the model sticker to this same number

Do NOT promise a price or an exact arrival time. A technician will call back to confirm.

Service area only: Brant area (Brantford, Paris, Scotland), Norfolk area (Tillsonburg, Delhi, Port Dover, Norwich), and the First Nations reserve near Tillsonburg. If they are clearly outside this area, politely say we do not travel there, set done=true and createJob=false.

If the caller is angry or yelling: stay calm. Say that a company employee will contact them within 30 minutes. Then set done=true and createJob=true with whatever you already have. Do not keep asking questions.`;

const VOICE_MODEL_CANDIDATES = [
  'gemini-2.0-flash',
  'gemini-flash-lite-latest',
  'gemini-flash-latest',
  'gemini-2.5-flash',
];

async function getAiAnswerSettings() {
  try {
    const [configSnap, voiceSnap, docsSnap] = await Promise.all([
      db.collection('companies').doc(COMPANY_ID).collection('settings').doc('config').get(),
      db.collection('companies').doc(COMPANY_ID).collection('settings').doc('ai_voice').get(),
      db.collection('companies').doc(COMPANY_ID).collection('settings').doc('documents').get(),
    ]);
    const config = configSnap.exists ? configSnap.data() || {} : {};
    const voice = voiceSnap.exists ? voiceSnap.data() || {} : {};
    const docs = docsSnap.exists ? docsSnap.data() || {} : {};
    const timeout = Number(config.aiAnswerTimeoutSeconds);
    const greeting = String(voice.greeting || '').trim();
    const instructions = String(voice.instructions || '').trim();
    const companyName = String(docs.companyName || '').trim() || 'Fix Appliance';
    const staleGreeting = STALE_VOICE_GREETINGS.includes(greeting);
    return {
      enabled: config.aiAnswerEnabled !== false,
      timeoutSeconds: Number.isFinite(timeout)
        ? Math.min(60, Math.max(8, Math.round(timeout)))
        : 20,
      companyName,
      greeting: !greeting || staleGreeting ? DEFAULT_VOICE_GREETING : greeting,
      instructions: instructions || DEFAULT_VOICE_INSTRUCTIONS,
    };
  } catch (_) {
    return {
      enabled: true,
      timeoutSeconds: 20,
      companyName: 'Fix Appliance',
      greeting: DEFAULT_VOICE_GREETING,
      instructions: DEFAULT_VOICE_INSTRUCTIONS,
    };
  }
}

function fillVoiceTemplate(template, vars) {
  let text = String(template || '');
  for (const [key, value] of Object.entries(vars)) {
    text = text.replace(new RegExp(`\\{${key}\\}`, 'gi'), value || '');
  }
  return text.replace(/\s{2,}/g, ' ').trim();
}

function firstNameOf(fullName) {
  const name = String(fullName || '').trim();
  if (!name) return '';
  return name.split(/\s+/)[0];
}

async function generateVoiceContent(parts) {
  if (!genAI) throw new Error('GEMINI_API_KEY не настроен');
  let lastError;
  for (const name of VOICE_MODEL_CANDIDATES) {
    try {
      const model = genAI.getGenerativeModel({
        model: name,
        generationConfig: {
          temperature: 0.8,
          maxOutputTokens: 400,
        },
      });
      const result = await generateContentWithRetry(model, parts, 2);
      console.log(`Voice Gemini ответил моделью ${name}`);
      return result;
    } catch (error) {
      lastError = error;
      console.warn(`Voice Gemini ${name}: ${error.message}`);
    }
  }
  throw lastError;
}

async function generateVoiceTextStream(parts, onChunk) {
  if (!genAI) throw new Error('GEMINI_API_KEY не настроен');
  let lastError;
  for (const name of VOICE_MODEL_CANDIDATES) {
    try {
      const model = genAI.getGenerativeModel({
        model: name,
        generationConfig: {
          temperature: 0.9,
          maxOutputTokens: 100,
        },
      });
      const result = await model.generateContentStream(parts);
      let full = '';
      for await (const chunk of result.stream) {
        const piece = typeof chunk.text === 'function' ? chunk.text() : '';
        if (!piece) continue;
        full += piece;
        onChunk(piece);
      }
      console.log(`Voice Gemini stream ${name}`);
      return full;
    } catch (error) {
      lastError = error;
      console.warn(`Voice Gemini stream ${name}: ${error.message}`);
    }
  }
  throw lastError;
}

async function getCompanyDisplayName() {
  try {
    const snap = await db
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('documents')
      .get();
    const name = String((snap.exists && snap.data() && snap.data().companyName) || '').trim();
    return name || 'Fix Appliance';
  } catch (_) {
    return 'Fix Appliance';
  }
}

function twimlDialPstn(req, toNumber) {
  const twiml = new twilio.twiml.VoiceResponse();
  const dial = twiml.dial({
    callerId: TWILIO_PHONE_NUMBER,
    timeout: 25,
    answerOnBridge: true,
    record: 'record-from-answer',
    recordingStatusCallback: recordingUrl(req),
    recordingStatusCallbackEvent: 'completed',
    action: dialActionUrl(req),
  });
  dial.number(toNumber);
  return twiml;
}

function twimlDialMaster(req, fromNumber, timeoutSeconds) {
  const twiml = new twilio.twiml.VoiceResponse();
  const dial = twiml.dial({
    callerId: fromNumber,
    timeout: timeoutSeconds || 20,
    answerOnBridge: true,
    record: 'record-from-answer',
    recordingStatusCallback: recordingUrl(req),
    recordingStatusCallbackEvent: 'completed',
    action: dialActionUrl(req),
  });
  const clientNode = dial.client();
  clientNode.identity(MASTER_IDENTITY);
  if (fromNumber && fromNumber !== 'Unknown' && !/^client:/i.test(fromNumber)) {
    clientNode.parameter({ name: '__TWI_CALLER_ID', value: fromNumber });
    clientNode.parameter({ name: '__TWI_CALLER_NAME', value: fromNumber });
  }
  const parentSid = String(req.body.CallSid || '').trim();
  if (parentSid) {
    clientNode.parameter({ name: 'parentCallSid', value: parentSid });
  }
  return twiml;
}

async function logCall(callSid, data) {
  if (!callSid) return;
  try {
    const { twilioTime, ...fields } = data;
    const ref = callsRef.doc(callSid);
    const existing = await ref.get();
    const payload = {
      callSid,
      ...fields,
      aiStatus: fields.aiStatus || 'none',
      reviewed: false,
    };
    const already = existing.exists && existing.data() && existing.data().startTime;
    if (!already) {
      const parsed = twilioTime ? new Date(twilioTime) : null;
      payload.startTime =
        parsed && !Number.isNaN(parsed.getTime())
          ? parsed
          : admin.firestore.FieldValue.serverTimestamp();
    }
    await ref.set(payload, { merge: true });
  } catch (error) {
    console.error('voice: failed to log call', error);
  }
}

async function handleOutboundFromApp(req, res, source) {
  const dest = outboundDestination(req.body);
  const callSid = req.body.CallSid;
  console.log(
    `${source}: outbound from=${req.body.From || ''} toParam=${req.body.To || ''} phone=${req.body.phone || ''} dest=${dest || '-'}`
  );
  await logCall(callSid, {
    fromNumber: TWILIO_PHONE_NUMBER || '',
    toNumber: dest || '',
    direction: 'outbound',
    status: 'in-progress',
    twilioTime: req.body.Timestamp || req.body.StartTime,
  });
  if (!dest) {
    const twiml = new twilio.twiml.VoiceResponse();
    twiml.say({ language: 'ru-RU' }, 'Номер получателя не указан.');
    sendTwiml(res, twiml);
    return;
  }
  sendTwiml(res, twimlDialPstn(req, dest));
}

async function handleInboundToMaster(req, res, source) {
  const fromNumber = req.body.From || 'Unknown';
  const toNumber = req.body.To || TWILIO_PHONE_NUMBER || '';
  const callSid = req.body.CallSid;
  const aiSettings = await getAiAnswerSettings();
  console.log(
    `${source}: inbound from=${fromNumber} to=${toNumber} aiTimeout=${aiSettings.timeoutSeconds} ai=${aiSettings.enabled}`
  );
  await logCall(callSid, {
    fromNumber,
    toNumber,
    direction: 'inbound',
    status: 'ringing',
    twilioTime: req.body.Timestamp || req.body.StartTime,
  });
  sendTwiml(res, twimlDialMaster(req, fromNumber, aiSettings.timeoutSeconds));
}

// ============================================================================
// VOICE: Webhook входящего звонка на Twilio-номер (Voice URL номера в консоли)
// ============================================================================

exports.incomingCall = functions.https.onRequest(async (req, res) => {
  // Если TwiML App тоже смотрит сюда, исходящий из приложения приходит
  // как From=client:master. Его нельзя снова звонить на master — иначе
  // мастер видит «входящий» сам себе (короткий номер вроде 627837).
  if (isFromClient(req.body)) {
    await handleOutboundFromApp(req, res, 'incomingCall');
    return;
  }
  await handleInboundToMaster(req, res, 'incomingCall');
});

// ============================================================================
// VOICE: Webhook исходящего звонка — Voice Request URL в TwiML App
// (вызывается автоматически плагином twilio_voice через call.place())
// ============================================================================

exports.outgoingCall = functions.https.onRequest(async (req, res) => {
  if (!isFromClient(req.body) && !outboundDestination(req.body)) {
    await handleInboundToMaster(req, res, 'outgoingCall');
    return;
  }
  await handleOutboundFromApp(req, res, 'outgoingCall');
});

// ============================================================================
// VOICE: Статус звонка (продолжительность, завершение)
// ============================================================================

exports.callStatusCallback = functions.https.onRequest(async (req, res) => {
  const callSid = req.body.CallSid;
  const callStatus = req.body.CallStatus || req.body.DialCallStatus;
  const duration = parseInt(req.body.CallDuration || req.body.DialCallDuration, 10) || null;

  console.log(`Call ${callSid} status: ${callStatus}`);

  try {
    if (callSid) {
      const updates = { twilioStatus: callStatus };
      if (duration != null) updates.durationSeconds = duration;

      if (['completed', 'failed', 'busy', 'no-answer', 'canceled'].includes(callStatus)) {
        updates.endTime = admin.firestore.FieldValue.serverTimestamp();
        updates.status = callStatus === 'completed' ? 'completed' : callStatus;
      }

      await callsRef.doc(callSid).set(updates, { merge: true });
    }
  } catch (error) {
    console.error('Error updating call status:', error);
  }

  res.type('text/xml');
  res.send('<Response></Response>');
});

const AI_VOICE_MAX_TURNS = 10;
const voiceAiRuntime = { timeoutSeconds: 60, memory: '512MiB', invoker: 'public' };

function sayLang(language) {
  return language === 'ru' ? 'ru-RU' : 'en-US';
}

function gatherLang(language) {
  return language === 'ru' ? 'ru-RU' : 'en-US';
}

function spokenText(value, fallback) {
  let text = String(value || '')
    .replace(/[`*_#]/g, '')
    .replace(/https?:\/\/\S+/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
  text = text.replace(
    /^(certainly|absolutely|of course|thank you for (?:that|sharing|the information|calling)|i(?:'ve| have) noted(?: that)?|please (?:provide|state|be advised)|how may i assist you(?: today)?)\b[^.?!]*[.?!]?\s*/i,
    ''
  );
  if (!text) text = String(fallback || '').trim();
  const sentences = text.split(/(?<=[.!?])\s+/).filter(Boolean);
  if (sentences.length > 2) text = `${sentences[0]} ${sentences[1]}`;
  return text.slice(0, 280);
}

function mergeExtracted(prev, next) {
  const out = { ...(prev || {}) };
  if (!next || typeof next !== 'object') return out;
  for (const [key, value] of Object.entries(next)) {
    if (value === null || value === undefined || value === '') continue;
    out[key] = value;
  }
  return out;
}

function hasEnoughForJob(extracted) {
  if (!extracted) return false;
  const problem = Boolean(extracted.appliance_type || extracted.problem_description);
  const name = Boolean(extracted.client_name);
  const address = Boolean(extracted.address);
  const when = Boolean(extracted.scheduled_date || extracted.scheduled_time);
  return problem && name && address && when;
}

function appendTranscript(current, line) {
  const next = [String(current || '').trim(), line].filter(Boolean).join('\n');
  return next.slice(-8000);
}

function sayAttrs(language) {
  if (language === 'ru') {
    return { voice: 'Google.ru-RU-Chirp3-HD-Aoede', language: 'ru-RU' };
  }
  return { voice: 'Google.en-US-Chirp3-HD-Aoede', language: 'en-US' };
}

const VOICE_HINTS =
  'fridge, refrigerator, freezer, washer, washing machine, dryer, dishwasher, stove, oven, range, microwave, repair, leak, leaking, not cooling, Brantford, Paris, Scotland, Tillsonburg, Delhi, Port Dover, Norwich';

let cachedRelayWss = '';

async function saveRelayHost(wss) {
  cachedRelayWss = String(wss || '').replace(/^https:/i, 'wss:');
  if (!cachedRelayWss) return;
  try {
    await db
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('voice_infra')
      .set(
        { wss: cachedRelayWss, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true }
      );
  } catch (error) {
    console.warn('saveRelayHost:', error.message);
  }
}

async function resolveConversationRelayWss() {
  if (process.env.USE_GATHER_VOICE === '1') return '';
  if (process.env.CONVERSATION_RELAY_WSS) {
    return String(process.env.CONVERSATION_RELAY_WSS).replace(/^https:/i, 'wss:');
  }
  if (cachedRelayWss) return cachedRelayWss;
  try {
    const infra = await db
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('voice_infra')
      .get();
    const stored = String((infra.exists && infra.data() && infra.data().wss) || '').trim();
    if (stored) {
      cachedRelayWss = stored.replace(/^https:/i, 'wss:');
      return cachedRelayWss;
    }
  } catch (_) {}
  try {
    const { GoogleAuth } = require('google-auth-library');
    const auth = new GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/cloud-platform'],
    });
    const client = await auth.getClient();
    const project =
      process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
    const url = `https://cloudfunctions.googleapis.com/v2/projects/${project}/locations/us-central1/functions/aiVoiceRelay`;
    const res = await client.request({ url });
    const uri = String(
      (res.data && res.data.serviceConfig && res.data.serviceConfig.uri) || ''
    );
    if (uri) {
      await saveRelayHost(uri);
      return cachedRelayWss;
    }
  } catch (error) {
    console.warn('resolveConversationRelayWss:', error.message);
  }
  return 'wss://aivoicerelay-wmdrqa3n7q-uc.a.run.app';
}

function twimlGatherSpeech(req, { say, language }) {
  const twiml = new twilio.twiml.VoiceResponse();
  const gather = twiml.gather({
    input: ['speech'],
    language: gatherLang(language),
    speechTimeout: 'auto',
    timeout: 10,
    bargeIn: true,
    enhanced: true,
    speechModel: 'phone_call',
    profanityFilter: false,
    hints: VOICE_HINTS,
    action: functionUrl(req, 'aiVoiceTurn'),
    method: 'POST',
    actionOnEmptyResult: true,
  });
  if (say) gather.say(sayAttrs(language), say);
  twiml.redirect({ method: 'POST' }, functionUrl(req, 'aiVoiceTurn'));
  return twiml;
}

function twimlConversationRelay(req, { url, greeting, callSid }) {
  const twiml = new twilio.twiml.VoiceResponse();
  const connect = twiml.connect({
    action: functionUrl(req, 'aiRelayComplete'),
  });
  const relay = connect.conversationRelay({
    url,
    welcomeGreeting: greeting,
    welcomeGreetingInterruptible: 'speech',
    language: 'en-US',
    ttsProvider: 'Google',
    voice: 'en-US-Chirp3-HD-Aoede',
    transcriptionProvider: 'Deepgram',
    speechModel: 'nova-3-general',
    interruptible: 'speech',
    interruptSensitivity: 'high',
    ignoreBackchannel: true,
    reportInputDuringAgentSpeech: 'none',
    speechTimeout: 700,
    hints: VOICE_HINTS,
  });
  if (callSid && typeof relay.parameter === 'function') {
    relay.parameter({ name: 'callSid', value: callSid });
  }
  relay.language({
    code: 'en-US',
    ttsProvider: 'Google',
    voice: 'en-US-Chirp3-HD-Aoede',
    transcriptionProvider: 'Deepgram',
    speechModel: 'nova-3-general',
  });
  relay.language({
    code: 'ru-RU',
    ttsProvider: 'Google',
    voice: 'ru-RU-Chirp3-HD-Aoede',
    transcriptionProvider: 'Deepgram',
    speechModel: 'nova-2-general',
  });
  return twiml;
}

function twimlGeminiLiveStream(req, { url, callSid }) {
  const twiml = new twilio.twiml.VoiceResponse();
  const connect = twiml.connect({
    action: functionUrl(req, 'aiRelayComplete'),
  });
  const stream = connect.stream({
    url,
    name: 'gemini-live',
  });
  if (callSid && typeof stream.parameter === 'function') {
    stream.parameter({ name: 'callSid', value: callSid });
  }
  return twiml;
}

function twimlHangup(say, language) {
  const twiml = new twilio.twiml.VoiceResponse();
  if (say) twiml.say(sayAttrs(language), say);
  twiml.hangup();
  return twiml;
}

async function startAiReception(req, res, callSid, options = {}) {
  const forceGather = options.forceGather === true;
  const callRef = callsRef.doc(callSid);
  const snap = await callRef.get();
  const data = snap.exists ? snap.data() || {} : {};
  const alreadyAi = data.answeredBy === 'ai' && data.aiReception;

  if (alreadyAi && forceGather) {
    const language = data.aiReception.language === 'ru' ? 'ru' : 'en';
    sendTwiml(
      res,
      twimlGatherSpeech(req, {
        say: language === 'ru' ? 'Да, слушаю вас.' : 'Go ahead.',
        language,
      })
    );
    return;
  }

  if (alreadyAi && data.aiReception && Array.isArray(data.aiReception.history) && data.aiReception.history.length) {
    const language = data.aiReception.language === 'ru' ? 'ru' : 'en';
    const last = [...data.aiReception.history].reverse().find((item) => item && item.role === 'assistant');
    const say = spokenText(
      last && last.text,
      language === 'ru' ? 'Да, слушаю вас.' : 'Go ahead.'
    );
    sendTwiml(res, twimlGatherSpeech(req, { say, language }));
    return;
  }

  const profile = await getAiAnswerSettings();
  const existingClient = await findClientByPhone(data.fromNumber);
  const clientName = existingClient
    ? existingClient.fullName || existingClient.name || ''
    : '';
  const dialSeconds = parseInt(req.body.DialCallDuration || req.body.CallDuration, 10) || 0;
  const greeting = data.handoffToAi && dialSeconds > 1
    ? 'The technician had to step away. How can I help?'
    : fillVoiceTemplate(profile.greeting, {
        company: profile.companyName,
        name: firstNameOf(clientName),
      });

  await callRef.set(
    {
      status: 'in-progress',
      answeredBy: 'ai',
      clientId: existingClient ? existingClient.id : data.clientId || null,
      aiReception: {
        history: [{ role: 'assistant', text: greeting }],
        extracted: clientName ? { client_name: clientName } : {},
        language: 'en',
        turns: 0,
        knownClient: Boolean(existingClient),
      },
      transcription: appendTranscript(data.transcription, `AI: ${greeting}`),
    },
    { merge: true }
  );

  if (client) {
    try {
      await client.calls(callSid).recordings.create({
        recordingStatusCallback: recordingUrl(req),
        recordingStatusCallbackEvent: ['completed'],
      });
    } catch (error) {
      console.warn('startAiReception recording:', error.message);
    }
  }

  try {
    await notifyMaster('ИИ взял звонок', data.fromNumber || callSid, {
      type: 'call',
      callSid,
      answeredBy: 'ai',
    });
  } catch (error) {
    console.warn('startAiReception notify:', error.message);
  }

  const wss = forceGather ? '' : await resolveConversationRelayWss();
  if (wss) {
    if (process.env.USE_CONVERSATION_RELAY === '1') {
      console.log(`startAiReception relay ${callSid} ${wss}`);
      sendTwiml(res, twimlConversationRelay(req, { url: wss, greeting, callSid }));
      return;
    }
    console.log(`startAiReception live ${callSid} ${wss}`);
    sendTwiml(res, twimlGeminiLiveStream(req, { url: wss, callSid }));
    return;
  }

  sendTwiml(res, twimlGatherSpeech(req, { say: greeting, language: 'en' }));
}

async function finishAiReception(req, res, callSid, callData, say, language, extracted, createJob, options = {}) {
  const silent = options.silent === true;
  const updates = {
    status: 'completed',
    endTime: admin.firestore.FieldValue.serverTimestamp(),
    answeredBy: 'ai',
    aiReception: {
      ...(callData.aiReception || {}),
      done: true,
    },
  };
  if (say && !silent) {
    updates.transcription = appendTranscript(callData.transcription, `AI: ${say}`);
  }

  if (createJob && extracted) {
    try {
      const matchedClient = await findClientByPhone(
        extracted.client_phone || callData.fromNumber
      );
      if (!extracted.client_phone && callData.fromNumber) {
        extracted.client_phone = normalizePhone(callData.fromNumber);
      }
      if (!extracted.scheduled_date) {
        extracted.scheduled_date = new Date().toISOString().slice(0, 10);
      }
      const created = await createDraftJobFromCall(callSid, extracted, matchedClient);
      updates.createdJobId = created.jobId || null;
      updates.clientId = created.clientId || (matchedClient ? matchedClient.id : null);
      updates.extractedData = extracted;
      updates.aiStatus = created.jobId ? 'done' : 'none';
      if (created.jobId) {
        try {
          await notifyMaster(
            'ИИ создал заявку',
            extracted.client_name || extracted.appliance_type || callData.fromNumber || '',
            { type: 'job', jobId: created.jobId, callSid }
          );
        } catch (error) {
          console.warn('finishAiReception notify:', error.message);
        }
      }
    } catch (error) {
      console.error('finishAiReception job:', error);
      updates.aiStatus = 'error';
      updates.aiError = error.message;
    }
  }

  await callsRef.doc(callSid).set(updates, { merge: true });
  sendTwiml(res, twimlHangup(silent ? '' : say, language));
}

async function nextAiVoiceTurn(callSid, callData, userText) {
  const reception = callData.aiReception || {};
  const history = Array.isArray(reception.history) ? [...reception.history] : [];
  const extracted = mergeExtracted(reception.extracted, {});
  const today = new Date().toISOString().slice(0, 10);
  const profile = await getAiAnswerSettings();
  const companyName = profile.companyName;
  const instructions = profile.instructions;
  const caller = callData.fromNumber || '';
  const known = await findClientByPhone(caller);
  const existingName = (known && (known.fullName || known.name)) || '';
  const existingAddress = (known && (known.address || '')) || '';

  if (userText) {
    history.push({ role: 'user', text: userText });
  }

  const prompt = `You are on a live phone call for ${companyName}, a small appliance-repair shop in Ontario, Canada.
The technician didn't pick up. YOU answered. You are a real person in the office — a warm woman, maybe mid-thirties, a little busy, never an IVR, never a chatbot, never a survey.

Caller phone (already known, do not ask for it): ${caller || 'unknown'}
Today: ${today}
Known CRM client: ${existingName || 'new caller'}
Known address if any: ${existingAddress || 'none'}

Company rules from the owner (facts and policy — follow these):
${instructions}

HOW TO TALK — this is the most important part:
- Speak like a real Ontario phone call. Contractions: "what's", "that's", "you're", "I'll".
- "say" is 1 short sentence, maybe 2. Usually under 16 words. One question only.
- First, briefly react like a human ("oh, the fridge isn't cooling", "okay, Brantford").
- Then ask the next missing thing in everyday words: "what's your name?", "and where's that at?", "what day's better for you?"
- If they already told you something, NEVER ask it again.
- Repeat the address back once, casually: "so that's 12 King in Paris, yeah?"
- Never answer with only "got it", "okay", or "I understand" — always continue with a real sentence, or stay quiet by asking one thing.
- Never say: "please provide", "I have noted", "thank you for that information", "how may I assist you", "I understand your concern", "certainly", "absolutely", "please be advised", "I am an AI".
- Never list questions. Never sound like a website form.
- If they are angry: stop collecting. Say a person from the company will call within 30 minutes. done=true, createJob=true.
- If you have full name, address, what broke, AND a day or time: wrap up like a person. "Perfect, I'll pass this to the tech and he'll call you back to confirm." No price, no exact ETA. done=true, createJob=true.
- Outside the service area: politely say you don't travel there. done=true, createJob=false.
- Wrong number / spam: done=true, createJob=false.
- Answer in the caller's language. Ontario is usually English. Russian only if they speak Russian.
- appliance_type in extracted must be Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.

Good "say" examples:
- "Oh, the fridge isn't cooling. What's your name?"
- "Okay John — what's the address there?"
- "Paris, perfect. What day works for a tech to come by?"
- "Alright, I'll have him call you back to confirm. Thanks."

Bad examples (never):
- "Thank you for providing that information. May I please have your full name?"
- "I have noted your appliance type as refrigerator."

Current extracted JSON: ${JSON.stringify(extracted)}
Conversation: ${JSON.stringify(history.slice(-12))}
Latest caller words: ${userText || '(silence)'}

Return STRICT JSON, no markdown:
{
  "say": "spoken reply",
  "language": "en",
  "done": false,
  "createJob": false,
  "extracted": {
    "client_name": null,
    "client_phone": null,
    "address": null,
    "city": null,
    "postal_code": null,
    "appliance_type": null,
    "brand": null,
    "model": null,
    "problem_description": null,
    "scheduled_date": null,
    "scheduled_time": null,
    "notes": null
  }
}`;

  const result = await generateVoiceContent([{ text: prompt }]);
  let text = (result.response.text() || '').trim();
  if (text.startsWith('```json')) text = text.slice(7);
  else if (text.startsWith('```')) text = text.slice(3);
  if (text.endsWith('```')) text = text.slice(0, -3);
  try {
    return extractJsonObject(text.trim());
  } catch (error) {
    console.warn('nextAiVoiceTurn JSON:', error.message);
    return {
      say: spokenText(text, 'Go ahead.'),
      language: 'en',
      done: false,
      createJob: false,
      extracted: {},
    };
  }
}

// Dial finished: master answered, or timeout → AI receptionist.
exports.dialAction = functions.https.onRequest(voiceAiRuntime, async (req, res) => {
  const callSid = req.body.CallSid;
  const dialStatus = req.body.DialCallStatus || req.body.CallStatus || '';
  const duration = parseInt(req.body.DialCallDuration || req.body.CallDuration, 10) || null;
  console.log(`dialAction ${callSid} DialCallStatus=${dialStatus}`);

  try {
    if (callSid) {
      await callsRef.doc(callSid).set({ twilioStatus: dialStatus }, { merge: true });
    }

    const snap = callSid ? await callsRef.doc(callSid).get() : null;
    const data = snap && snap.exists ? snap.data() || {} : {};
    const inbound = data.direction === 'inbound';
    const declined = data.declineNoAi === true;
    const handoff = data.handoffToAi === true;
    const missed =
      dialStatus === 'no-answer' || dialStatus === 'busy' || dialStatus === 'failed';
    const callerGone = dialStatus === 'canceled';
    const aiSettings = inbound && !declined && !callerGone ? await getAiAnswerSettings() : { enabled: false };
    const takeAi =
      inbound &&
      !declined &&
      !callerGone &&
      callSid &&
      (handoff || (aiSettings.enabled && missed));

    if (takeAi) {
      await startAiReception(req, res, callSid);
      return;
    }

    if (callSid) {
      const updates = {};
      if (duration != null) updates.durationSeconds = duration;
      if (['completed', 'failed', 'busy', 'no-answer', 'canceled'].includes(dialStatus)) {
        updates.endTime = admin.firestore.FieldValue.serverTimestamp();
        updates.status = dialStatus === 'completed' ? 'completed' : dialStatus;
      }
      if (Object.keys(updates).length) {
        await callsRef.doc(callSid).set(updates, { merge: true });
      }
    }
  } catch (error) {
    console.error('dialAction error:', error);
  }

  res.type('text/xml');
  res.send('<Response></Response>');
});

exports.aiVoiceTurn = functions.https.onRequest(voiceAiRuntime, async (req, res) => {
  const callSid = req.body.CallSid;
  const incomingSpeech = String(req.body.SpeechResult || '').trim();
  console.log(`aiVoiceTurn ${callSid} speech="${incomingSpeech.slice(0, 80)}"`);

  if (!callSid) {
    sendTwiml(res, twimlHangup('Goodbye.', 'en'));
    return;
  }

  try {
    const snap = await callsRef.doc(callSid).get();
    const data = snap.exists ? snap.data() || {} : {};
    const reception = data.aiReception || {};
    const language = reception.language === 'ru' ? 'ru' : 'en';
    const speech = incomingSpeech || String(reception.pendingSpeech || '').trim();
    const emptyTurns = Number(reception.emptyTurns || 0);
    const turns = Number(reception.turns || 0) + (speech ? 1 : 0);
    const receptionNow = { ...reception, pendingSpeech: '' };

    if (!speech) {
      const nextEmpty = emptyTurns + 1;
      await callsRef.doc(callSid).set(
        {
          aiReception: { ...receptionNow, emptyTurns: nextEmpty },
          transcription: appendTranscript(data.transcription, 'Client: (silence)'),
        },
        { merge: true }
      );
      if (nextEmpty >= 4 || turns >= AI_VOICE_MAX_TURNS) {
        await finishAiReception(
          req,
          res,
          callSid,
          data,
          language === 'ru'
            ? 'Спасибо. Мастер перезвонит.'
            : 'Thanks — a technician will call you back.',
          language,
          reception.extracted,
          hasEnoughForJob(reception.extracted)
        );
        return;
      }
      sendTwiml(
        res,
        twimlGatherSpeech(req, {
          say: nextEmpty >= 2
            ? (language === 'ru' ? 'Я вас слушаю.' : "I'm here — go ahead.")
            : '',
          language,
        })
      );
      return;
    }

    const parsed = (await nextAiVoiceTurn(callSid, { ...data, aiReception: receptionNow }, speech)) || {};
    const nextLanguage = parsed.language === 'ru' ? 'ru' : 'en';
    const extracted = mergeExtracted(reception.extracted, parsed.extracted);
    if (!extracted.client_phone && data.fromNumber) {
      extracted.client_phone = normalizePhone(data.fromNumber);
    }
    const say = spokenText(
      parsed.say,
      nextLanguage === 'ru' ? 'Да, слушаю вас.' : 'Yeah, go ahead.'
    );
    const history = Array.isArray(reception.history) ? [...reception.history] : [];
    history.push({ role: 'user', text: speech });
    history.push({ role: 'assistant', text: say });

    const forceDone = turns >= AI_VOICE_MAX_TURNS;
    const done = parsed.done === true || forceDone;
    const createJob =
      parsed.createJob === true || (forceDone && hasEnoughForJob(extracted));

    const nextData = {
      ...data,
      transcription: appendTranscript(data.transcription, `Client: ${speech}`),
      aiReception: {
        history,
        extracted,
        language: nextLanguage,
        turns,
        done,
        pendingSpeech: '',
        emptyTurns: 0,
      },
    };

    await callsRef.doc(callSid).set(
      {
        answeredBy: 'ai',
        extractedData: extracted,
        transcription: appendTranscript(nextData.transcription, `AI: ${say}`),
        aiReception: nextData.aiReception,
      },
      { merge: true }
    );

    if (done) {
      const confirm =
        say ||
        (nextLanguage === 'ru'
          ? 'Спасибо, заявка принята. Мастер перезвонит.'
          : "Perfect — I'll have the tech call you back to confirm.");
      await finishAiReception(
        req,
        res,
        callSid,
        nextData,
        confirm,
        nextLanguage,
        extracted,
        createJob || hasEnoughForJob(extracted)
      );
      return;
    }

    sendTwiml(res, twimlGatherSpeech(req, { say, language: nextLanguage }));
  } catch (error) {
    console.error('aiVoiceTurn error:', error);
    sendTwiml(
      res,
      twimlHangup(
        "Sorry, something went wrong. Call back or send a text, we'll take care of it.",
        'en'
      )
    );
  }
});

exports.aiRelayComplete = functions.https.onRequest(voiceAiRuntime, async (req, res) => {
  const callSid = req.body.CallSid;
  const sessionStatus = String(req.body.SessionStatus || req.body.CallStatus || '').toLowerCase();
  const errorCode = String(req.body.ErrorCode || '').trim();
  const errorMessage = String(req.body.ErrorMessage || '').trim();
  console.log(
    `aiRelayComplete ${callSid} status=${sessionStatus} error=${errorCode} ${errorMessage}`
  );

  if (!callSid) {
    sendTwiml(res, new twilio.twiml.VoiceResponse());
    return;
  }

  try {
    const snap = await callsRef.doc(callSid).get();
    let data = snap.exists ? snap.data() || {} : {};
    const liveFailed = Boolean(data.aiReception && data.aiReception.liveFailed);
    if (errorCode || sessionStatus === 'failed' || liveFailed) {
      if (liveFailed) {
        await callsRef.doc(callSid).set({ aiReception: { liveFailed: false } }, { merge: true });
      }
      await startAiReception(req, res, callSid, { forceGather: true });
      return;
    }

    if (data.aiReception && data.aiReception.engine === 'gemini-live' && !data.aiReception.done) {
      await new Promise((resolve) => setTimeout(resolve, 800));
      const again = await callsRef.doc(callSid).get();
      if (again.exists) data = again.data() || data;
    }

    const extracted = (data.aiReception && data.aiReception.extracted) || data.extractedData;
    const createJob =
      (data.aiReception && data.aiReception.createJob === true) || hasEnoughForJob(extracted);
    if (data.status === 'completed' && (data.createdJobId || !createJob)) {
      sendTwiml(res, twimlHangup('', 'en'));
      return;
    }
    await finishAiReception(
      req,
      res,
      callSid,
      data,
      '',
      'en',
      extracted,
      createJob,
      { silent: true }
    );
  } catch (error) {
    console.error('aiRelayComplete error:', error);
    sendTwiml(res, twimlHangup('', 'en'));
  }
});

voiceRelay.init({
  geminiApiKey: GEMINI_API_KEY,
  generateVoiceContent,
  generateVoiceTextStream,
  spokenText,
  getAiAnswerSettings,
  hasEnoughForJob,
  extractJsonObject,
  mergeExtracted,
  normalizePhone,
  findClientByPhone,
  callsRef,
  appendTranscript,
  saveRelayHost,
});

exports.aiVoiceRelay = onRequestV2(
  {
    region: 'us-central1',
    timeoutSeconds: 3600,
    memory: '1GiB',
    cpu: 1,
    concurrency: 8,
    minInstances: 1,
    invoker: 'public',
    cors: false,
  },
  (req, res) => voiceRelay.handleRequest(req, res)
);

// ============================================================================
// VOICE: Запись разговора готова — запускаем ИИ-обработку
// ============================================================================

exports.recordingComplete = functions.https.onRequest(recordingRuntime, async (req, res) => {
  const rawSid = req.body.CallSid;
  const recordingUrl = req.body.RecordingUrl;
  const recordingSid = req.body.RecordingSid;
  const duration = parseInt(req.body.RecordingDuration, 10) || 0;

  console.log(`Recording complete for call ${rawSid}: ${recordingUrl}`);

  try {
    if (!rawSid || !recordingUrl) {
      res.status(200).send('OK');
      return;
    }

    const callId = await resolveLoggedCallId(rawSid);
    const mp3Url = `${recordingUrl}.mp3`;
    await callsRef.doc(callId).set(
      {
        recordingUrl: mp3Url,
        recordingSid,
        recordingCallSid: rawSid,
        recordingDurationSeconds: duration,
        endTime: admin.firestore.FieldValue.serverTimestamp(),
        status: 'completed',
        aiStatus: 'processing',
        aiStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    res.status(200).send('OK');
    await processRecordingWithAi(callId, mp3Url);
    return;
  } catch (error) {
    console.error('Error processing recording:', error);
    res.status(500).send('Error');
  }
});

/**
 * Gemini иногда временно недоступен (503 "high demand") или случается
 * сетевой сбой при обращении к API — в обоих случаях повторный запрос почти
 * всегда проходит успешно, поэтому не заставляем пользователя нажимать
 * "Повторить ИИ" вручную при таких временных сбоях.
 */
async function generateContentWithRetry(model, parts, maxAttempts = 3) {
  let lastError;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await model.generateContent(parts);
    } catch (error) {
      lastError = error;
      const status = error?.status;
      const isRetryable =
        status === 429 ||
        status === 500 ||
        status === 503 ||
        /fetch failed|unavailable|overloaded/i.test(error?.message || '');
      if (!isRetryable || attempt === maxAttempts) throw error;
      const delayMs = 1000 * 2 ** (attempt - 1);
      console.warn(
        `generateContent попытка ${attempt}/${maxAttempts} не удалась (${error.message}), повтор через ${delayMs}мс`
      );
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  throw lastError;
}

const GEMINI_MODEL_CANDIDATES = [
  'gemini-flash-lite-latest',
  'gemini-flash-latest',
  'gemini-2.5-flash',
  'gemini-2.0-flash',
];

async function generateContentWithModelFallback(parts) {
  if (!genAI) throw new Error('GEMINI_API_KEY не настроен');
  let lastError;
  for (const name of GEMINI_MODEL_CANDIDATES) {
    try {
      const model = genAI.getGenerativeModel({ model: name });
      const result = await generateContentWithRetry(model, parts, 2);
      console.log(`Gemini ответил моделью ${name}`);
      return result;
    } catch (error) {
      lastError = error;
      console.warn(`Gemini ${name}: ${error.message}`);
    }
  }
  throw lastError;
}

function fallbackExtractFromSms(body) {
  const text = String(body || '').trim();
  if (!text) return null;
  if (/^(ok|okay|thanks|thank you|yes|no|hi|hello|спасибо|ок)\.?$/i.test(text)) {
    return { relevant: false };
  }
  const modelMatch = text.match(/\b[A-Z0-9][A-Z0-9-]{4,}\b/i);
  return {
    relevant: true,
    appliance_type: null,
    brand: null,
    model: (modelMatch ? modelMatch[0] : text).toUpperCase(),
    serial_number: null,
    problem_description: null,
    notes: text,
  };
}

/**
 * Скачивает запись разговора и одним запросом к Gemini получает и
 * транскрипцию, и структурированные данные для заявки — без отдельного
 * шага распознавания речи.
 */
async function processRecordingWithAi(callId, recordingUrl) {
  if (!genAI) {
    await callsRef.doc(callId).set(
      { aiStatus: 'error', aiError: 'GEMINI_API_KEY не настроен в functions/.env' },
      { merge: true }
    );
    return;
  }

  await callsRef.doc(callId).set(
    {
      aiStatus: 'processing',
      aiStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      aiRetryCount: admin.firestore.FieldValue.increment(1),
    },
    { merge: true }
  );

  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await processRecordingWithAiOnce(callId, recordingUrl);
      return;
    } catch (error) {
      lastError = error;
      console.error(`AI processing attempt ${attempt}/3 for ${callId}:`, error.message);
      if (attempt < 3) {
        await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
      }
    }
  }

  await callsRef.doc(callId).set(
    { aiStatus: 'error', aiError: lastError ? lastError.message : 'AI failed' },
    { merge: true }
  );
}

async function processRecordingWithAiOnce(callId, recordingUrl) {
    const audioBuffer = await downloadRecordingBuffer(recordingUrl);
    const audioBase64 = audioBuffer.toString('base64');

    let callerNumber = '';
    let direction = 'inbound';
    try {
      const callDoc = await callsRef.doc(callId).get();
      const data = callDoc.data() || {};
      direction = data.direction || 'inbound';
      callerNumber =
        direction === 'outbound' ? data.toNumber || '' : data.fromNumber || '';
    } catch (_) {}

    const today = new Date().toISOString().slice(0, 10);

    const prompt = `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Прослушай запись телефонного разговора и сделай два действия:
1) Дай точную текстовую транскрипцию разговора на языке, на котором говорят.
2) Извлеки структурированные данные для заявки на ремонт.

Известные данные звонка (уже определены системой, не выдумывай другие):
- Сегодняшняя дата: ${today}
- Номер клиента: ${callerNumber || 'неизвестен'}
- Направление: ${direction === 'outbound' ? 'мастер звонил клиенту' : 'клиент звонил мастеру'}

Правила извлечения:
- client_phone: если клиент не назвал другой номер — обязательно поставь номер клиента (${callerNumber || 'null'}), 10 цифр без пробелов и плюса
- scheduled_date: если дата визита не названа — поставь сегодняшнюю дату ${today} в формате YYYY-MM-DD. «Завтра»/«послезавтра» считай от ${today}
- address, city, postal_code: извлеки улицу, дом, город и индекс, если они хоть как-то упомянуты (даже частично)
- Телефон форматируй как 10 цифр без пробелов
- Время форматируй как HH:MM (24-часовой формат)
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Если клиент — владелец, а техника находится у арендатора, установи has_job_site: true
- Если что-то не упомянуто или разговор не про ремонт техники — поставь null

Верни СТРОГО один JSON-объект без markdown и пояснений, в формате:
{
  "transcription": "полный текст разговора",
  "extracted": {
    "client_name": "Имя клиента (владельца)",
    "client_phone": "Телефон клиента",
    "address": "Улица и номер дома",
    "city": "Город",
    "postal_code": "Почтовый индекс",
    "appliance_type": "Тип техники",
    "brand": "Бренд",
    "model": "Модель",
    "problem_description": "Описание проблемы",
    "scheduled_date": "Дата визита",
    "scheduled_time": "Время визита",
    "contact_on_site_name": "Имя контакта на месте (арендатор)",
    "contact_on_site_phone": "Телефон контакта на месте",
    "has_job_site": false,
    "notes": "Дополнительные заметки"
  }
}`;

    const result = await generateContentWithModelFallback([
      { text: prompt },
      { inlineData: { mimeType: 'audio/mp3', data: audioBase64 } },
    ]);

    let text = (result.response.text() || '').trim();
    if (text.startsWith('```json')) text = text.slice(7);
    else if (text.startsWith('```')) text = text.slice(3);
    if (text.endsWith('```')) text = text.slice(0, -3);
    text = text.trim();

    const parsed = extractJsonObject(text);
    const transcription = parsed.transcription || '';
    const extracted = parsed.extracted || {};

    if (!extracted.client_phone && callerNumber) {
      extracted.client_phone = callerNumber.replace(/\D/g, '').slice(-10);
    }
    if (!extracted.scheduled_date) {
      extracted.scheduled_date = today;
    }

    const matchedClient = await findClientByPhone(
      extracted.client_phone || (await getCallFromNumber(callId))
    );

    const hasSubstance = Boolean(
      extracted.appliance_type ||
        extracted.problem_description ||
        extracted.address ||
        extracted.client_name ||
        transcription.length > 40
    );

    let created = { jobId: null, clientId: matchedClient ? matchedClient.id : null };
    if (hasSubstance) {
      try {
        created = await createDraftJobFromCall(callId, extracted, matchedClient);
      } catch (jobError) {
        console.error(`createDraftJobFromCall(${callId}) failed:`, jobError);
      }
    }

    await callsRef.doc(callId).set(
      {
        transcription,
        extractedData: extracted,
        aiStatus: 'done',
        clientId: created.clientId || (matchedClient ? matchedClient.id : null),
        createdJobId: created.jobId || null,
        reviewed: Boolean(created.jobId),
      },
      { merge: true }
    );

    console.log(`AI processing done for call ${callId}, job=${created.jobId || 'none'}`);
}

async function getCallFromNumber(callId) {
  try {
    const doc = await callsRef.doc(callId).get();
    const data = doc.data();
    if (!data) return null;
    return data.direction === 'inbound' ? data.fromNumber : data.toNumber;
  } catch (_) {
    return null;
  }
}

/**
 * Ручной перезапуск ИИ-обработки записи (например, если она упала с ошибкой).
 */
exports.processCallRecording = functions.https.onRequest(
  recordingRuntime,
  async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);

  const rawBody = req.body;
  const payload = typeof rawBody === 'string'
    ? (() => { try { return JSON.parse(rawBody); } catch (_) { return {}; } })()
    : (rawBody || {});
  const callId = payload.callId || payload.callSid;
  if (!callId) {
    res.status(400).json({ error: 'callId required' });
    return;
  }

  try {
    const resolvedId = await resolveLoggedCallId(callId);
    const doc = await callsRef.doc(resolvedId).get();
    if (!doc.exists) {
      res.status(404).json({ error: 'Call not found' });
      return;
    }

    const data = doc.data() || {};
    let recordingUrl = data.recordingUrl;
    if (!recordingUrl) {
      recordingUrl = await findTwilioRecordingMp3(resolvedId);
      if (recordingUrl) {
        await callsRef.doc(resolvedId).set({ recordingUrl }, { merge: true });
      }
    }
    if (!recordingUrl) {
      res.status(400).json({ error: 'Запись ещё не готова' });
      return;
    }

    await callsRef.doc(resolvedId).set(
      {
        aiStatus: 'processing',
        aiStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    res.json({ success: true });
    await processRecordingWithAi(resolvedId, recordingUrl);
  } catch (error) {
    console.error('Error processing call:', error);
    if (!res.headersSent) {
      res.status(500).json({ error: error.message });
    }
  }
});

function isAiProcessingStale(data, maxAgeMs = 8 * 60 * 1000) {
  const started = data && data.aiStartedAt && typeof data.aiStartedAt.toMillis === 'function'
    ? data.aiStartedAt.toMillis()
    : 0;
  if (!started) return true;
  return Date.now() - started > maxAgeMs;
}

function shouldAutoRetryCallAi(data) {
  if (!data || data.aiStatus === 'done' || data.reviewed) return false;
  const retries = Number(data.aiRetryCount || 0);
  if (retries >= 5) return false;
  const hasRecording = Boolean(data.recordingUrl);
  const duration = Number(data.durationSeconds || data.recordingDurationSeconds || 0);
  if (!hasRecording && duration <= 0) return false;
  if (data.aiStatus === 'error') return true;
  if (data.aiStatus === 'processing') return isAiProcessingStale(data);
  return false;
}

/**
 * Сам подбирает звонки с ошибкой ИИ или зависшей обработкой и запускает повтор.
 */
async function retryStuckCallAiJobs(limit = 3) {
  const errorSnap = await callsRef.where('aiStatus', '==', 'error').limit(20).get();
  const processingSnap = await callsRef.where('aiStatus', '==', 'processing').limit(20).get();
  const picked = [];
  const seen = new Set();

  for (const doc of [...errorSnap.docs, ...processingSnap.docs]) {
    if (seen.has(doc.id)) continue;
    seen.add(doc.id);
    const data = doc.data() || {};
    if (!shouldAutoRetryCallAi(data)) continue;
    picked.push({
      id: doc.id,
      recordingUrl: data.recordingUrl || null,
    });
    if (picked.length >= limit) break;
  }

  for (const item of picked) {
    let recordingUrl = item.recordingUrl;
    if (!recordingUrl) {
      recordingUrl = await findTwilioRecordingMp3(item.id);
      if (recordingUrl) {
        await callsRef.doc(item.id).set({ recordingUrl }, { merge: true });
      }
    }
    if (!recordingUrl) {
      console.log(`retryStuckCallAi: нет записи для ${item.id}`);
      continue;
    }
    console.log(`retryStuckCallAi: повтор ИИ для ${item.id}`);
    await processRecordingWithAi(item.id, recordingUrl);
  }
}

exports.retryStuckCallAi = functions.scheduler.onSchedule(
  {
    schedule: 'every 5 minutes',
    timeZone: 'America/Toronto',
    timeoutSeconds: 300,
    memory: '1GiB',
    retryCount: 0,
  },
  async () => {
    await retryStuckCallAiJobs(3);
  }
);

exports.registerFcmToken = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);

  const { token, platform } = req.body || {};
  if (!token) {
    res.status(400).json({ error: 'token required' });
    return;
  }

  try {
    const id = String(token).replace(/\//g, '_').slice(0, 700);
    await tokensRef.doc(id).set({
      token,
      platform: platform || 'unknown',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log('registerFcmToken: токен сохранён', platform || 'unknown');
    res.json({ success: true });
  } catch (error) {
    console.error('registerFcmToken error:', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// SMS: отправка сообщения из приложения
// ============================================================================

exports.sendSms = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);

  if (!client) {
    res.status(500).json({ error: 'Twilio не настроен (TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN)' });
    return;
  }

  const { to, body, clientId } = req.body || {};
  const mediaUrls = Array.isArray((req.body || {}).mediaUrls)
    ? (req.body.mediaUrls)
        .map((url) => String(url || '').trim())
        .filter((url) => /^https?:\/\//i.test(url))
        .slice(0, 10)
    : [];
  if (!to || (!body && !mediaUrls.length)) {
    res.status(400).json({ error: 'Требуются поля to и body' });
    return;
  }

  const e164 = (() => {
    const digits = String(to).replace(/\D/g, '');
    if (!digits) return null;
    if (digits.length === 10) return `+1${digits}`;
    if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
    if (String(to).trim().startsWith('+')) return `+${digits}`;
    return `+${digits}`;
  })();
  if (!e164) {
    res.status(400).json({ error: 'Некорректный номер телефона' });
    return;
  }

  try {
    const header = await getSmsHeader();
    const text = withSmsHeader(body || '', header);
    const payload = {
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      statusCallback: TWILIO_ACCOUNT_SID
        ? `https://${req.get('host')}/smsStatusCallback`
        : undefined,
    };
    if (text) payload.body = text;
    if (mediaUrls.length) payload.mediaUrl = mediaUrls;
    const message = await client.messages.create(payload);

    const docRef = await messagesRef.add({
      sid: message.sid,
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text || '',
      direction: 'outbound',
      status: message.status,
      clientId: clientId || null,
      channel: 'sms',
      mediaUrls,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      read: true,
    });

    res.json({ success: true, sid: message.sid, id: docRef.id });
  } catch (error) {
    console.error('sendSms error:', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// SMS: webhook входящего сообщения — Messaging URL номера в консоли Twilio
// ============================================================================

exports.incomingSms = functions.https.onRequest(
  { timeoutSeconds: 120, memory: '512MiB', invoker: 'public' },
  async (req, res) => {
  const from = req.body.From || req.body.from;
  const to = req.body.To || req.body.to;
  const body = req.body.Body || req.body.body || '';
  const sid = req.body.MessageSid || req.body.sid;
  const numMedia = parseInt(req.body.NumMedia || req.body.numMedia, 10) || 0;

  let twilioMedia = [];
  for (let i = 0; i < Math.max(numMedia, 10); i++) {
    const url = req.body[`MediaUrl${i}`] || req.body[`mediaUrl${i}`];
    const contentType = req.body[`MediaContentType${i}`] || req.body[`mediaContentType${i}`] || '';
    if (url) twilioMedia.push({ url, contentType });
    if (i >= numMedia && !url) break;
  }

  let docRef = null;
  let matchedClient = null;
  let alreadyProcessed = false;

  try {
    if (sid) {
      const existing = await messagesRef.where('sid', '==', sid).limit(1).get();
      if (!existing.empty) {
        docRef = existing.docs[0].ref;
        const prev = existing.docs[0].data() || {};
        alreadyProcessed = prev.aiStatus === 'done';
        const missingPhoto =
          Array.isArray(prev.twilioMedia) &&
          prev.twilioMedia.length &&
          !(prev.mediaUrls && prev.mediaUrls.length);
        if (missingPhoto) alreadyProcessed = false;
        matchedClient = prev.clientId ? { id: prev.clientId, fullName: '' } : await findClientByPhone(from);
        if (!twilioMedia.length && Array.isArray(prev.twilioMedia)) {
          twilioMedia = prev.twilioMedia.filter((item) => item && item.url);
        }
      }
    }

    if (!twilioMedia.length && sid) {
      try {
        twilioMedia = await listTwilioMedia(sid);
      } catch (error) {
        console.warn('listTwilioMedia failed:', error.message);
      }
    }

    console.log(
      `incomingSms sid=${sid || '-'} media=${twilioMedia.length} bodyLen=${String(body).length}`
    );

    if (!docRef) {
      matchedClient = await findClientByPhone(from);
      docRef = await messagesRef.add({
        sid,
        from,
        to,
        body,
        direction: 'inbound',
        status: 'received',
        clientId: matchedClient ? matchedClient.id : null,
        mediaUrls: [],
        twilioMedia,
        channel: 'sms',
        aiStatus: twilioMedia.length || body.trim() ? 'processing' : 'none',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: false,
      });
    }
  } catch (error) {
    console.error('incomingSms error:', error);
  }

  const preview = body.trim()
    ? body.trim().slice(0, 80)
    : twilioMedia.length
      ? 'Фото'
      : 'Новое сообщение';
  const title = matchedClient
    ? `SMS от ${matchedClient.fullName || matchedClient.name || from}`
    : `SMS от ${from || 'клиента'}`;

  // Отвечаем Twilio сразу, чтобы webhook не истекал, пока работает ИИ.
  res.type('text/xml');
  res.send('<Response></Response>');

  let confirmHandled = false;
  if (docRef && !alreadyProcessed) {
    try {
      confirmHandled = await visitSms.tryHandleConfirmReply({
        from,
        body,
        clientId: matchedClient ? matchedClient.id : null,
      });
      if (confirmHandled) {
        await docRef.set({ aiStatus: 'skipped_confirm', read: true }, { merge: true });
      }
    } catch (error) {
      console.error('incomingSms confirm error:', error);
    }
  }

  if (!alreadyProcessed && !confirmHandled) {
    try {
      await notifyMaster(title, preview, { type: 'sms', from: from || '' });
    } catch (error) {
      console.error('incomingSms notify error:', error);
    }
  }

  if (docRef && !alreadyProcessed && !confirmHandled) {
    try {
      await processSmsWithAi({
        messageId: docRef.id,
        from,
        body,
        twilioMedia,
        clientId: matchedClient ? matchedClient.id : null,
        clientName: matchedClient
          ? matchedClient.fullName || matchedClient.name || ''
          : '',
      });
    } catch (error) {
      console.error('incomingSms AI error:', error);
      await docRef.set({ aiStatus: 'error', aiError: error.message }, { merge: true });
    }
  }
});

exports.onJobWritten = visitSms.onJobWritten;
exports.sendVisitReminders = visitSms.sendVisitReminders;


// ============================================================================
// SMS: статус доставки исходящего сообщения
// ============================================================================

exports.smsStatusCallback = functions.https.onRequest(async (req, res) => {
  const sid = req.body.MessageSid;
  const status = req.body.MessageStatus;

  try {
    if (sid) {
      const snapshot = await messagesRef.where('sid', '==', sid).limit(1).get();
      if (!snapshot.empty) {
        await snapshot.docs[0].ref.update({ status });
      }
    }
  } catch (error) {
    console.error('smsStatusCallback error:', error);
  }

  res.status(200).send('OK');
});

async function notifyMaster(title, body, data = {}) {
  const snapshot = await tokensRef.get();
  const tokens = snapshot.docs.map((d) => d.data().token).filter(Boolean);
  if (!tokens.length) {
    console.warn('notifyMaster: нет сохранённых FCM-токенов');
    return;
  }

  const stringData = {};
  for (const [key, value] of Object.entries(data)) {
    stringData[key] = String(value ?? '');
  }

  const type = String(data.type || 'sms');
  const channelId = type === 'email' ? 'email_messages' : 'sms_messages';
  const tag = `crm_${type}_${String(data.from || data.to || 'inbox')}`.slice(0, 50);
  stringData.type = type;
  stringData.tag = tag;

  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: stringData,
    android: {
      priority: 'high',
      notification: {
        channelId,
        sound: 'default',
        defaultSound: true,
        tag,
        priority: 'high',
      },
    },
    apns: {
      payload: {
        aps: { sound: 'default' },
      },
    },
  });

  const stale = [];
  response.responses.forEach((r, i) => {
    if (!r.success) {
      const code = r.error && r.error.code;
      if (
        code === 'messaging/registration-token-not-registered' ||
        code === 'messaging/invalid-registration-token'
      ) {
        stale.push(snapshot.docs[i].id);
      } else {
        console.warn('notifyMaster: ошибка отправки', code, r.error && r.error.message);
      }
    }
  });
  await Promise.all(stale.map((id) => tokensRef.doc(id).delete()));
}

async function downloadTwilioMedia(url) {
  const authHeader =
    'Basic ' + Buffer.from(`${REST_AUTH_USER}:${REST_AUTH_SECRET}`).toString('base64');
  const first = await fetch(url, {
    headers: { Authorization: authHeader },
    redirect: 'manual',
    signal: AbortSignal.timeout(20000),
  });

  let response = first;
  if ([301, 302, 303, 307, 308].includes(first.status)) {
    const location = first.headers.get('location');
    if (!location) {
      throw new Error(`Twilio media redirect HTTP ${first.status} без Location`);
    }
    response = await fetch(location, { signal: AbortSignal.timeout(20000) });
  }

  if (!response.ok) {
    throw new Error(`Не удалось скачать вложение SMS (HTTP ${response.status})`);
  }
  const mime = response.headers.get('content-type') || 'image/jpeg';
  const buffer = Buffer.from(await response.arrayBuffer());
  if (!buffer.length) {
    throw new Error('Вложение SMS пустое');
  }
  return { mime, buffer, base64: buffer.toString('base64') };
}

async function listTwilioMedia(messageSid) {
  if (!client || !messageSid) return [];
  const list = await client.messages(messageSid).media.list();
  return (list || []).map((item) => ({
    url: `https://api.twilio.com${String(item.uri || '').replace(/\.json$/, '')}`,
    contentType: item.contentType || '',
  }));
}

async function uploadSmsMedia(sid, index, buffer, mime) {
  try {
    const bucketName =
      process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT
        ? `${process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT}.firebasestorage.app`
        : 'fix-appliance-crm.firebasestorage.app';
    const bucket = admin.storage().bucket(bucketName);
    const ext = (mime.split('/')[1] || 'jpg').split(';')[0].replace('+xml', '');
    const path = `companies/${COMPANY_ID}/sms/${sid || 'unknown'}/${index}.${ext}`;
    const file = bucket.file(path);
    const token = crypto.randomUUID();
    await file.save(buffer, {
      resumable: false,
      metadata: {
        contentType: mime.split(';')[0],
        metadata: { firebaseStorageDownloadTokens: token },
      },
    });
    const encoded = encodeURIComponent(path);
    const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encoded}?alt=media&token=${token}`;
    console.log(`uploadSmsMedia ok ${path}`);
    return url;
  } catch (error) {
    console.warn('uploadSmsMedia failed:', error.message);
    return null;
  }
}

async function findJobByPhone(phone) {
  const normalized = normalizePhone(phone);
  if (!normalized) return null;
  const snapshot = await jobsRef.get();
  const open = [];
  const all = [];
  for (const doc of snapshot.docs) {
    const data = doc.data();
    const phones = [data.clientPhone, data.jobSitePhone].map(normalizePhone);
    if (!phones.includes(normalized)) continue;
    const item = { id: doc.id, ...data };
    all.push(item);
    if (data.status !== 'Завершено' && data.status !== 'Отменено') open.push(item);
  }
  const byDate = (a, b) => {
    const millis = (v) => (v && typeof v.toMillis === 'function' ? v.toMillis() : 0);
    return millis(b.createdAt) - millis(a.createdAt);
  };
  open.sort(byDate);
  if (open.length) return open[0];
  all.sort(byDate);
  return all[0] || null;
}

function hasRepairData(extracted) {
  if (!extracted) return false;
  return Boolean(
    extracted.model ||
      extracted.brand ||
      extracted.appliance_type ||
      extracted.serial_number ||
      extracted.problem_description
  );
}

function mergeAppliance(existing, extracted) {
  const current = existing || {};
  return {
    type: extracted.appliance_type || current.type || '',
    brand: extracted.brand || current.brand || '',
    model: extracted.model || current.model || '',
    serialNumber: extracted.serial_number || current.serialNumber || '',
    issue: current.issue || extracted.problem_description || '',
  };
}

function stripSmsDump(text) {
  return String(text || '')
    .replace(/\[SMS[^\]]*\][^\n]*/g, '')
    .replace(/^Текст:.*$/gm, '')
    .replace(/^Создано из SMS\s*$/gm, '')
    .replace(/^Серийный номер:.*$/gm, '')
    .replace(/^Проблема:.*$/gm, '')
    .replace(/^Бренд:.*$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function mergeJobDescription(existing, note) {
  let base = stripSmsDump(existing);
  if (note) {
    base = base.replace(/^Модель:\s*.*$/gm, '').replace(/\n{3,}/g, '\n\n').trim();
  }
  if (!note) return base;
  if (base.toLowerCase().includes(note.toLowerCase())) return base;
  return [base, note].filter(Boolean).join('\n\n');
}

async function processSmsWithAi({ messageId, from, body, twilioMedia, clientId, clientName }) {
  const messageRef = messagesRef.doc(messageId);
  const existing = await messageRef.get();
  const messageSid = existing.exists ? existing.data().sid : '';

  let mediaItems = Array.isArray(twilioMedia) ? [...twilioMedia] : [];
  if (!mediaItems.length && messageSid) {
    try {
      mediaItems = await listTwilioMedia(messageSid);
    } catch (error) {
      console.warn('listTwilioMedia failed:', error.message);
    }
  }

  const images = [];
  const storedUrls = [];
  for (let i = 0; i < mediaItems.length; i++) {
    const item = mediaItems[i];
    if (!item.url) continue;
    if (item.contentType &&
        !String(item.contentType).startsWith('image/') &&
        item.contentType !== 'application/octet-stream') {
      continue;
    }
    try {
      const downloaded = await downloadTwilioMedia(item.url);
      images.push(downloaded);
      const url = await uploadSmsMedia(messageId, i, downloaded.buffer, downloaded.mime);
      if (url) storedUrls.push(url);
    } catch (error) {
      console.warn('SMS media download failed:', error.message);
    }
  }

  if (storedUrls.length) {
    await messageRef.set({ mediaUrls: storedUrls }, { merge: true });
  }

  if (!genAI) {
    await messageRef.set(
      { aiStatus: 'error', aiError: 'GEMINI_API_KEY не настроен' },
      { merge: true }
    );
    return;
  }

  if (!body.trim() && !images.length) {
    await messageRef.set({ aiStatus: 'none' }, { merge: true });
    return;
  }

  const prompt = `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Клиент прислал SMS${images.length ? ' и фото (шильдик, модель, техника)' : ''}.
Извлеки данные для заявки на ремонт.

Правила:
- Если на фото шильдик/бирка — обязательно прочитай model, brand, serial_number
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Если это обычное сообщение без данных о технике (ок, спасибо, когда приедете) — все поля null, relevant: false
- Телефон форматируй как 10 цифр

Верни СТРОГО один JSON без markdown:
{
  "relevant": true,
  "appliance_type": null,
  "brand": null,
  "model": null,
  "serial_number": null,
  "problem_description": null,
  "notes": null
}

Текст SMS: ${body || '(нет текста)'}
Номер отправителя: ${from || ''}`;

  const parts = [{ text: prompt }];
  for (const img of images) {
    parts.push({ inlineData: { mimeType: img.mime.split(';')[0], data: img.base64 } });
  }

  let extracted;
  try {
    const result = await generateContentWithModelFallback(parts);
    let text = (result.response.text() || '').trim();
    if (text.startsWith('```json')) text = text.slice(7);
    else if (text.startsWith('```')) text = text.slice(3);
    if (text.endsWith('```')) text = text.slice(0, -3);
    extracted = JSON.parse(text.trim());
  } catch (error) {
    console.warn('SMS Gemini failed, fallback extract:', error.message);
    extracted = fallbackExtractFromSms(body);
    if (!extracted) {
      await messageRef.set(
        { aiStatus: 'error', aiError: error.message },
        { merge: true }
      );
      return;
    }
  }
  const relevant = extracted.relevant !== false && hasRepairData(extracted);

  const updates = {
    extractedData: extracted,
    aiStatus: relevant ? 'done' : 'none',
  };

  if (!relevant) {
    await messageRef.set(updates, { merge: true });
    return;
  }

  let job = await findJobByPhone(from);
  const appliance = mergeAppliance(job && (job.appliances || [])[0], extracted);
  const smsNote = extracted.model ? `Модель: ${extracted.model}` : '';

  if (job) {
    const appliances = Array.isArray(job.appliances) && job.appliances.length
      ? [appliance, ...job.appliances.slice(1)]
      : [appliance];
    const jobUpdates = {
      appliances,
      applianceType: appliance.type,
      brand: appliance.brand,
      model: appliance.model,
      serialNumber: appliance.serialNumber,
      description: mergeJobDescription(job.description, smsNote),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (storedUrls.length) {
      const attachments = storedUrls.map((url) => ({
        url,
        type: 'image',
        source: 'sms',
        createdAt: new Date().toISOString(),
      }));
      jobUpdates.attachments = admin.firestore.FieldValue.arrayUnion(...attachments);
    }
    await jobsRef.doc(job.id).update(jobUpdates);
    updates.jobId = job.id;
  } else {
    const created = await jobsRef.add({
      clientId: clientId || '',
      clientName: clientName || from || '',
      clientPhone: from || '',
      clientAddress: '',
      hasJobSite: false,
      appliances: [appliance],
      applianceType: appliance.type,
      brand: appliance.brand,
      model: appliance.model,
      serialNumber: appliance.serialNumber,
      description: smsNote,
      status: 'Вызов',
      priority: '🟢 Обычный',
      attachments: storedUrls.map((url) => ({
        url,
        type: 'image',
        source: 'sms',
        createdAt: new Date().toISOString(),
      })),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    updates.jobId = created.id;
  }

  await messageRef.set(updates, { merge: true });
  console.log(`SMS AI done for ${messageId}, job ${updates.jobId}`);
}

// ============================================================================
// STRIPE: инвойсы, депозиты, Checkout и webhook оплаты
// ============================================================================

const stripeHandlers = require('./stripe');
exports.createStripePayment = stripeHandlers.createStripePayment;
exports.createTerminalConnectionToken = stripeHandlers.createTerminalConnectionToken;
exports.createTerminalPaymentIntent = stripeHandlers.createTerminalPaymentIntent;
exports.completeTerminalPayment = stripeHandlers.completeTerminalPayment;
exports.stripeWebhook = stripeHandlers.stripeWebhook;
exports.stripePaymentComplete = stripeHandlers.stripePaymentComplete;

const createEmailModule = require('./email');
const emailHandlers = createEmailModule({
  notifyMaster,
  setCors,
  handleOptions,
});
exports.sendEmail = functions.https.onRequest(
  { timeoutSeconds: 120, memory: '512MiB', invoker: 'public' },
  emailHandlers.sendEmail
);
exports.syncGmailInbox = functions.scheduler.onSchedule(
  {
    schedule: 'every 3 minutes',
    timeZone: 'America/Toronto',
    timeoutSeconds: 120,
    memory: '512MiB',
    retryCount: 0,
  },
  async () => {
    await emailHandlers.syncGmailInbox();
  }
);
