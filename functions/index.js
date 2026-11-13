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
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const twilio = require('twilio');
const crypto = require('crypto');
const { GoogleGenerativeAI } = require('@google/generative-ai');
const voiceRelay = require('./voice_relay');
const voiceFacts = require('./voice_facts');
const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');
const smsLinks = require('./sms_links');
const smsText = require('./sms_text');
const visitSms = require('./visit_sms');
const schedule = require('./schedule');
const serviceArea = require('./service_area');
const jobDedupe = require('./job_dedupe');
const notifyApi = require('./notify');
const { notifyMaster, pingMaster, registerDeviceToken } = notifyApi;
const callRoute = require('./call_route');
const { requireAppUser, requireTwilioSignature } = require('./auth_guard');
const technicians = require('./technicians');
const { createRecordingStore, isTwilioMediaUrl, appendCallRecording } = require('./recording_store');
const { createCallTranscriber } = require('./call_transcribe');
const { createCallDubber } = require('./call_dub');
const { withProcessingLease } = require('./processing_lease');

initializeApp();

const TWILIO_ACCOUNT_SID = process.env.TWILIO_ACCOUNT_SID;
const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;
const TWILIO_API_KEY_SID = process.env.TWILIO_API_KEY_SID;
const TWILIO_API_KEY_SECRET = process.env.TWILIO_API_KEY_SECRET;
const TWILIO_TWIML_APP_SID = process.env.TWILIO_TWIML_APP_SID;
const TWILIO_PUSH_CREDENTIAL_SID = process.env.TWILIO_PUSH_CREDENTIAL_SID;
const TWILIO_PHONE_NUMBER = process.env.TWILIO_PHONE_NUMBER;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
// Живой голос секретаря. Без этого ключа OpenAI Realtime в цепочку провайдеров
// даже не попадает, и звонки ведёт Gemini Live, как раньше.
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

// Идентификатор клиента Twilio Voice, на который приходят входящие звонки
// (регистрируется в приложении через TwilioVoicePlatform.instance).
const MASTER_IDENTITY = process.env.TWILIO_MASTER_IDENTITY || 'master';

const COMPANY_ID = 'fix_appliance_ca';
const SMS_STATUS_CB =
  'https://us-central1-fix-appliance-crm.cloudfunctions.net/smsStatusCallback';

// Для REST-запросов (отправка SMS, скачивание записи разговора) Twilio
// принимает либо Account SID + Auth Token, либо API Key SID + Secret —
// используем то, что заполнено в .env (API Key приоритетнее).
const REST_AUTH_USER = TWILIO_API_KEY_SID || TWILIO_ACCOUNT_SID;
const REST_AUTH_SECRET = TWILIO_API_KEY_SECRET || TWILIO_AUTH_TOKEN;

const client =
  TWILIO_ACCOUNT_SID && REST_AUTH_USER && REST_AUTH_SECRET
    ? twilio(REST_AUTH_USER, REST_AUTH_SECRET, { accountSid: TWILIO_ACCOUNT_SID })
    : null;

const db = getFirestore();
const callsRef = db.collection('companies').doc(COMPANY_ID).collection('calls');
const secretaryLearnApi = {
  proposeFromCall: async () => {},
};
const messagesRef = db.collection('companies').doc(COMPANY_ID).collection('messages');
const clientsRef = db.collection('companies').doc(COMPANY_ID).collection('clients');
const scheduledMessagesRef = db.collection('companies').doc(COMPANY_ID).collection('scheduled_messages');
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

/**
 * SMS с просьбой об отзыве: ссылку меняем на наш редирект с google-хоста
 * (ссылки на свой домен и g.page операторы режут, 30007) и кладём запасной
 * текст без ссылки на случай, если зарежут всё равно.
 */
async function prepareReviewSms(body) {
  try {
    const settings = db.collection('companies').doc(COMPANY_ID).collection('settings');
    const [configSnap, docsSnap] = await Promise.all([
      settings.doc('config').get(),
      settings.doc('documents').get(),
    ]);
    const config = configSnap.exists ? configSnap.data() || {} : {};
    const docs = docsSnap.exists ? docsSnap.data() || {} : {};
    return smsLinks.prepareReviewSms(body, {
      reviewUrl: config.googleReviewUrl,
      company: docs.companyName,
    });
  } catch (error) {
    console.warn('prepareReviewSms:', error.message);
    return { body: String(body || ''), fallbackBody: '' };
  }
}

const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

function setCors(res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
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
      const data = doc.data() || {};
      if (data.deletedAt) continue;
      if (voiceFacts.phonesOfClient(data).has(normalized)) {
        return { id: doc.id, ...data };
      }
    }
  } catch (error) {
    console.error('findClientByPhone error:', error);
  }
  return null;
}

function emailsOfClient(client) {
  const out = new Set();
  const add = (value) => {
    const email = String(value || '').trim().toLowerCase();
    if (email.includes('@')) out.add(email);
  };
  if (!client || typeof client !== 'object') return out;
  add(client.email);
  for (const loc of Array.isArray(client.locations) ? client.locations : []) {
    add(loc && loc.email);
    for (const contact of Array.isArray(loc && loc.contacts) ? loc.contacts : []) {
      add(contact && contact.email);
    }
  }
  return out;
}

async function findClientByEmail(email) {
  const normalized = String(email || '').trim().toLowerCase();
  if (!normalized || !normalized.includes('@')) return null;
  try {
    const snapshot = await clientsRef.get();
    for (const doc of snapshot.docs) {
      const data = doc.data() || {};
      if (data.deletedAt) continue;
      if (emailsOfClient(data).has(normalized)) {
        return { id: doc.id, ...data };
      }
    }
  } catch (error) {
    console.error('findClientByEmail error:', error);
  }
  return null;
}

async function findExistingClient({ phone, email } = {}) {
  const byPhone = await findClientByPhone(phone);
  if (byPhone) return byPhone;
  return findClientByEmail(email);
}

async function findClientForInboundPhone(phone) {
  const existing = await findExistingClient({ phone });
  if (existing) return existing;
  const job = await findOpenJobForContact({ phone });
  if (!job || !job.clientId) return null;
  try {
    const snap = await clientsRef.doc(job.clientId).get();
    if (snap.exists) return { id: snap.id, ...snap.data() };
  } catch (_) {}
  return {
    id: job.clientId,
    fullName: job.clientName || '',
    name: job.clientName || '',
  };
}

function buildFullAddress(extracted, existingClient) {
  const parts = [
    extracted.address,
    extracted.city,
    extracted.postal_code,
  ].filter((part) => part && String(part).trim());
  if (parts.length) return parts.join(', ');
  return voiceFacts.clientAddressFrom(existingClient);
}

function locationAddressKey(street, city, postal) {
  return [street, city, postal]
    .map((part) => String(part || '').trim().toLowerCase().replace(/\s+/g, ' '))
    .join('|');
}

function isJobSiteExtract(extracted) {
  if (!extracted) return false;
  if (extracted.has_job_site === true || extracted.has_job_site === 'true') return true;
  if (
    String(extracted.contact_on_site_name || '').trim() ||
    String(extracted.contact_on_site_phone || '').trim()
  ) {
    return true;
  }
  if (
    extracted.owner_address &&
    extracted.address &&
    voiceFacts.addressesLookDifferent(extracted.owner_address, extracted.address)
  ) {
    return true;
  }
  return false;
}

function tenantContactFromExtracted(extracted, ownerName, ownerPhone) {
  // Другого человека не назвали — на месте будет сам клиент (его имя и телефон).
  const site = voiceFacts.onSiteContactFrom(extracted, ownerName, ownerPhone);
  return {
    id: 'tenant',
    name: site.name || 'Tenant',
    phone: site.phone || '',
    role: 'tenant',
    isPrimary: true,
  };
}

function jobSiteLocationFromExtracted(extracted, ownerName, ownerPhone) {
  const street = String((extracted && extracted.address) || '').trim();
  const city = String((extracted && extracted.city) || '').trim();
  const postal = String((extracted && extracted.postal_code) || '').trim();
  const contacts = [tenantContactFromExtracted(extracted, ownerName, ownerPhone)];
  // Отдельный контакт «владелец» нужен только когда на месте назван другой
  // человек — иначе контакт на месте и так несёт данные клиента.
  if (voiceFacts.onSiteContactFrom(extracted, ownerName, ownerPhone).explicit && (ownerName || ownerPhone)) {
    contacts.push({
      id: 'owner',
      name: ownerName || '',
      phone: ownerPhone || '',
      role: 'owner',
      isPrimary: false,
    });
  }
  return {
    id: `site_${Date.now()}`,
    street,
    city,
    postalCode: postal,
    notes: 'Job site',
    contacts,
  };
}

async function upsertClientJobSite(clientId, existingClient, extracted, ownerName, ownerPhone) {
  if (!clientId || !isJobSiteExtract(extracted)) return;
  const street = String((extracted && extracted.address) || '').trim();
  const city = String((extracted && extracted.city) || '').trim();
  const postal = String((extracted && extracted.postal_code) || '').trim();
  if (!street && !city) return;

  const locations = Array.isArray(existingClient && existingClient.locations)
    ? existingClient.locations.map((loc) => ({ ...(loc || {}) }))
    : [];
  const key = locationAddressKey(street, city, postal);
  const matchIdx = locations.findIndex(
    (loc) => locationAddressKey(loc.street, loc.city, loc.postalCode || loc.postal) === key
  );
  const tenant = tenantContactFromExtracted(extracted, ownerName, ownerPhone);
  const site = voiceFacts.onSiteContactFrom(extracted, ownerName, ownerPhone);

  if (matchIdx >= 0) {
    const loc = locations[matchIdx];
    const contacts = Array.isArray(loc.contacts) ? [...loc.contacts] : [];
    const tenantIdx = contacts.findIndex((c) => String(c.role || '') === 'tenant');
    if (site.explicit) {
      // Назван другой человек — записываем/обновляем его данные, но не
      // затираем ранее записанный отдельный номер арендатора фолбэком хозяина.
      if (tenantIdx >= 0) {
        const existingPhone = normalizePhone(contacts[tenantIdx].phone);
        const ownerNorm = normalizePhone(ownerPhone);
        const explicitSitePhone = normalizePhone(
          extracted && extracted.contact_on_site_phone
        );
        contacts[tenantIdx] = {
          ...contacts[tenantIdx],
          ...tenant,
          phone:
            explicitSitePhone ||
            (existingPhone && existingPhone !== ownerNorm
              ? contacts[tenantIdx].phone
              : tenant.phone),
          id: contacts[tenantIdx].id || 'tenant',
        };
      } else {
        contacts.push(tenant);
      }
    } else if (tenantIdx < 0) {
      // Другого человека не назвали: контакт на месте — сам клиент.
      // Существующего tenant не трогаем, чтобы не затереть реального человека.
      contacts.push(tenant);
    }
    loc.contacts = contacts;
    if (!loc.notes) loc.notes = 'Job site (tenant)';
    locations[matchIdx] = loc;
  } else {
    locations.push(jobSiteLocationFromExtracted(extracted, ownerName, ownerPhone));
  }

  await clientsRef.doc(clientId).set(
    {
      locations,
      lastActiveAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

function parseScheduledAt(extracted) {
  const date = voiceFacts.parseScheduledAtDate(extracted);
  return date ? Timestamp.fromDate(date) : null;
}

const jobFillScore = jobDedupe.jobFillScore;

async function findJobsBySourceCall(callId) {
  if (!callId) return [];
  const snap = await jobsRef.where('sourceCallId', '==', callId).limit(10).get();
  return snap.docs;
}

async function mergeDuplicateSourceCallJobs(callId, keepId) {
  const docs = await findJobsBySourceCall(callId);
  for (const doc of docs) {
    if (doc.id === keepId) continue;
    const data = doc.data() || {};
    if (isClosedJobData(data) || data.deletedAt) continue;
    await closeCloneJob({ id: doc.id, ...data }, keepId, { force: true });
  }
}

function callAiBlocked(data) {
  return Boolean(data && (data.deletedAt || data.jobCreateBlocked || data.aiSkip));
}

function messageAiBlocked(data) {
  return Boolean(data && (data.deletedAt || data.aiSkip));
}

async function blockCallJobCreate(callId) {
  const id = String(callId || '').trim();
  if (!id) return;
  await callsRef.doc(id).set(
    { jobCreateBlocked: true, reviewed: true },
    { merge: true }
  );
}

async function claimOrReuseCallJob(callId) {
  const callSnap = await callsRef.doc(callId).get();
  const callData = callSnap.exists ? callSnap.data() || {} : {};
  if (callAiBlocked(callData)) {
    return { jobId: null, clientId: callData.clientId || null, existed: true };
  }

  const existing = await findJobsBySourceCall(callId);
  if (existing.length) {
    existing.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
    const live = existing.find((doc) => !isClosedJobData(doc.data() || {}));
    const keep = live || existing[0];
    const data = keep.data() || {};
    if (!live || isClosedJobData(data)) {
      await blockCallJobCreate(callId);
      return { jobId: keep.id, clientId: data.clientId || null, existed: true };
    }
    await callsRef.doc(callId).set(
      {
        createdJobId: keep.id,
        jobId: keep.id,
        clientId: data.clientId || null,
      },
      { merge: true }
    );
    if (existing.length > 1) {
      await mergeDuplicateSourceCallJobs(callId, keep.id);
    }
    return { jobId: keep.id, clientId: data.clientId || null, existed: true };
  }

  return db.runTransaction(async (tx) => {
    const ref = callsRef.doc(callId);
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() || {} : {};
    if (callAiBlocked(data)) {
      return { jobId: null, clientId: data.clientId || null, existed: true };
    }
    if (data.createdJobId) {
      return {
        jobId: data.createdJobId,
        clientId: data.clientId || null,
        existed: true,
      };
    }
    if (callAgeHours(data) > 48) {
      return { jobId: null, clientId: data.clientId || null, existed: false };
    }
    const jobId = jobsRef.doc().id;
    tx.set(
      ref,
      {
        createdJobId: jobId,
        jobId,
      },
      { merge: true }
    );
    return { jobId, clientId: data.clientId || null, existed: false };
  });
}

/**
 * Транскрипт слышит имя с ошибкой: «Artem» превращается в «Aetem», и такое имя
 * проходит все проверки, потому что выглядит как настоящее. Если у клиента в
 * карточке уже есть живое имя и услышанное отличается от него на одну-две
 * буквы — это опечатка распознавания, а не другой человек. Берём имя карточки.
 */
async function preferKnownClientName(clientId, spoken) {
  const heard = voiceFacts.usableClientName(spoken);
  if (!clientId || !heard) return heard;
  try {
    const snap = await clientsRef.doc(clientId).get();
    if (!snap.exists) return heard;
    const data = snap.data() || {};
    const known = voiceFacts.usableClientName(data.fullName || data.name || '');
    if (!known || known === heard) return heard;
    const limit = known.length >= 7 ? 2 : 1;
    if (voiceFacts.editDistance(known.toLowerCase(), heard.toLowerCase()) <= limit) {
      console.log(`preferKnownClientName: "${heard}" -> "${known}"`);
      return known;
    }
  } catch (error) {
    console.warn('preferKnownClientName:', error.message);
  }
  return heard;
}

async function applyPersonNameToClient(clientId, name) {
  const spoken = voiceFacts.usableClientName(name);
  if (!clientId || !spoken) return;
  const snap = await clientsRef.doc(clientId).get();
  if (!snap.exists) return;
  const data = snap.data() || {};
  const current = String(data.fullName || data.name || '').trim();
  const updates = {};
  if (voiceFacts.isPlaceholderClientName(current) || !current) {
    updates.fullName = spoken;
    updates.name = spoken;
  }
  const locations = Array.isArray(data.locations) ? data.locations : [];
  let locChanged = false;
  const nextLocations = locations.map((loc) => {
    const contacts = Array.isArray(loc.contacts) ? loc.contacts : [];
    const nextContacts = contacts.map((contact) => {
      if (
        contact &&
        (contact.role === 'owner' || contact.isPrimary) &&
        voiceFacts.isPlaceholderClientName(contact.name)
      ) {
        locChanged = true;
        return { ...contact, name: spoken };
      }
      return contact;
    });
    return locChanged ? { ...loc, contacts: nextContacts } : loc;
  });
  if (locChanged) updates.locations = nextLocations;
  if (!Object.keys(updates).length) return;
  updates.lastActiveAt = FieldValue.serverTimestamp();
  await clientsRef.doc(clientId).set(updates, { merge: true });
}

/**
 * После разбора звонка создаёт (или находит) клиента и черновик заявки.
 * Заявка помечается needsReview, чтобы мастер проверил её в приложении.
 */
function callAgeHours(data) {
  const start = data && data.startTime && data.startTime.toDate
    ? data.startTime.toDate()
    : null;
  if (!start) return 999;
  return (Date.now() - start.getTime()) / 36e5;
}

function isClosedJobData(job) {
  return schedule.isClosedJob(job);
}

const applianceKey = jobDedupe.applianceKey;
const jobApplianceKey = jobDedupe.jobApplianceKey;

function jobsAreSameRepair(a, b) {
  const ka = jobApplianceKey(a);
  const kb = jobApplianceKey(b);
  if (ka && kb) return ka === kb;
  return true;
}

function isDraftCloneJob(job) {
  if (!job || isClosedJobData(job) || job.deletedAt) return false;
  if (job.needsReview === true) return true;
  const status = String(job.status || '').trim();
  if (status && status !== 'Вызов') return false;
  const visits = Array.isArray(job.visits) ? job.visits : [];
  return visits.length === 0 && !job.scheduledAt && !job.scheduledDate;
}

async function closeCloneJob(job, keepId, { force = false } = {}) {
  if (!job || !job.id || job.id === keepId) return false;
  if (isClosedJobData(job) || job.deletedAt) return false;
  if (!force && !isDraftCloneJob(job)) return false;
  // Дубль не просто закрываем: сначала переливаем его данные в главную заявку.
  if (keepId) {
    return jobDedupe.mergeJobs(keepId, job.id, {
      by: jobDedupe.historyActor(job),
      force: true,
    });
  }
  const visits = Array.isArray(job.visits)
    ? job.visits.map((visit) => {
        if (!visit || visit.outcome === 'done' || visit.outcome === 'cancelled') {
          return visit;
        }
        return { ...visit, outcome: 'cancelled', smsConfirmStatus: 'cancelled' };
      })
    : [];
  await jobsRef.doc(job.id).set(
    {
      status: 'Отменено',
      needsReview: false,
      cloneOfJobId: keepId || null,
      visits,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  console.log(`closeCloneJob: ${job.id} → ${keepId || 'none'}`);
  return true;
}

async function listOpenJobsForContact({ phone, clientId } = {}) {
  const items = [];
  const seen = new Set();
  const pushDoc = (id, data) => {
    if (!id || seen.has(id)) return;
    if (isClosedJobData(data) || data.deletedAt) return;
    seen.add(id);
    items.push({ id, ...data });
  };

  if (clientId) {
    const snap = await jobsRef.where('clientId', '==', clientId).get();
    for (const doc of snap.docs) {
      pushDoc(doc.id, doc.data() || {});
    }
  }

  const normalized = normalizePhone(phone);
  if (normalized) {
    const snapshot = await jobsRef.get();
    for (const doc of snapshot.docs) {
      const data = doc.data() || {};
      const phones = [data.clientPhone, data.jobSitePhone].map(normalizePhone);
      if (!phones.includes(normalized)) continue;
      pushDoc(doc.id, data);
    }
  }
  return items;
}

async function findReusableOpenJob({ phone, clientId, applianceType } = {}) {
  const open = await listOpenJobsForContact({ phone, clientId });
  const want = applianceKey(applianceType);
  let best = null;
  let bestScore = -1;
  for (const job of open) {
    const got = jobApplianceKey(job);
    if (want && got && want !== got) continue;
    const score = jobFillScore(job);
    if (score > bestScore) {
      best = job;
      bestScore = score;
    }
  }
  return best;
}

async function collapseAllCloneJobs() {
  const snapshot = await jobsRef.get();
  const byPhone = new Map();
  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    if (isClosedJobData(data) || data.deletedAt) continue;
    const phones = [data.clientPhone, data.jobSitePhone]
      .map(normalizePhone)
      .filter(Boolean);
    for (const phone of phones) {
      if (!byPhone.has(phone)) byPhone.set(phone, []);
      byPhone.get(phone).push({ id: doc.id, ...data });
    }
  }
  let closed = 0;
  for (const jobs of byPhone.values()) {
    if (jobs.length < 2) continue;
    jobs.sort((a, b) => jobFillScore(b) - jobFillScore(a));
    const kept = [];
    for (const job of jobs) {
      const twin = kept.find((item) => jobsAreSameRepair(item, job));
      if (twin) {
        if (await closeCloneJob(job, twin.id)) closed += 1;
        continue;
      }
      kept.push(job);
    }
  }
  if (closed) console.log(`collapseAllCloneJobs: закрыл ${closed}`);
  return closed;
}

/**
 * ОТКЛЮЧЕНО (решение FIX, 21.10.2026): заявку со звонка никто не создаёт
 * автоматически — мастер слушает запись и жмёт «Создать заявку на ремонт»
 * в карточке звонка. Функция оставлена как справка по разбору звонка в
 * заявку; вызовов у неё нет и быть не должно. Если понадобится вернуть
 * автоматику — сначала спросите владельца.
 */
async function createDraftJobFromCall(callId, extracted, knownClient) {
  const callSnap = await callsRef.doc(callId).get();
  const callData = callSnap.exists ? callSnap.data() || {} : {};
  if (callAiBlocked(callData)) {
    return { jobId: null, clientId: null, created: false };
  }

  extracted = voiceFacts.enrichExtracted(
    extracted,
    (callData.aiReception || {}).history,
    callData.transcription
  );

  if (voiceFacts.isAppointmentOnly(extracted, callData)) {
    return { jobId: null, clientId: callData.clientId || null, created: false };
  }
  const noBooking = callData.answeredBy === 'ai';
  const claimed = await claimOrReuseCallJob(callId);
  if (claimed.existed && claimed.jobId) {
    const existingJob = await jobsRef.doc(claimed.jobId).get();
    if (existingJob.exists) {
      const existingData = existingJob.data() || {};
      if (isClosedJobData(existingData)) {
        await blockCallJobCreate(callId);
        return { jobId: null, clientId: existingData.clientId || null, created: false };
      }
      await patchDraftJobFromCall(claimed.jobId, extracted, { noBooking });
      return {
        jobId: claimed.jobId,
        clientId: claimed.clientId || existingData.clientId || null,
        created: false,
      };
    }
    await blockCallJobCreate(callId);
    return { jobId: null, clientId: null, created: false };
  }
  if (!claimed.jobId && callAgeHours(callData) > 48) {
    return { jobId: null, clientId: null, created: false };
  }

  const phone =
    normalizePhone(extracted.client_phone) ||
    normalizePhone(callData.direction === 'inbound' ? callData.fromNumber : callData.toNumber);

  let existingClient = knownClient && knownClient.id ? knownClient : null;
  if (!existingClient) {
    existingClient = await findExistingClient({
      phone,
      email: extracted && extracted.client_email,
    });
  }
  let clientId = existingClient && existingClient.id;
  // Распознавание речи теряет буквы в названиях городов: с живого звонка
  // приехал «Branford» вместо «Brantford», и маршрут по такому адресу не
  // строится. Сверяем с городами из карточки клиента и с теми, по которым
  // мастер работает.
  if (extracted && extracted.city) {
    const known = [...voiceFacts.citiesFromClient(existingClient), ...SERVICE_TOWN_NAMES];
    const snapped = voiceFacts.snapCity(extracted.city, known);
    if (snapped && snapped !== extracted.city) {
      console.log(`city snapped "${extracted.city}" -> "${snapped}"`);
      extracted.city = snapped;
    }
  }
  let extractedName = voiceFacts.usableClientName(
    (extracted && extracted.client_name) || ''
  );
  const existingRealName = voiceFacts.usableClientName(
    (existingClient && (existingClient.fullName || existingClient.name)) || ''
  );
  let clientName =
    extractedName ||
    existingRealName ||
    phone ||
    '';
  const address = buildFullAddress(extracted, existingClient);
  const city = extracted.address_uncertain
    ? ''
    : ((extracted.city && String(extracted.city).trim()) || '');
  const street = extracted.address_uncertain
    ? ''
    : ((extracted.address && String(extracted.address).trim()) || '');
  const postal = extracted.address_uncertain
    ? ''
    : ((extracted.postal_code && String(extracted.postal_code).trim()) || '');

  if (!clientId) {
    const initialLocation = isJobSiteExtract(extracted)
      ? jobSiteLocationFromExtracted(extracted, clientName, phone)
      : {
          id: 'primary',
          street,
          city,
          postalCode: postal,
          notes: '',
          contacts: [
            {
              id: 'owner',
              name: clientName,
              phone: phone || '',
              role: 'owner',
              isPrimary: true,
            },
          ],
        };
    const clientDoc = await clientsRef.add({
      fullName: clientName,
      phone: phone || '',
      address: isJobSiteExtract(extracted)
        ? String(extracted.owner_address || '').trim() || ''
        : address,
      locations: [initialLocation],
      createdAt: FieldValue.serverTimestamp(),
      lastActiveAt: FieldValue.serverTimestamp(),
      createdByAi: true,
    });
    clientId = clientDoc.id;
  } else {
    const updates = {
      lastActiveAt: FieldValue.serverTimestamp(),
    };
    if (extractedName) {
      await applyPersonNameToClient(clientId, extractedName);
    }
    await clientsRef.doc(clientId).set(updates, { merge: true });
    await upsertClientJobSite(clientId, existingClient, extracted, clientName, phone);
    if (!isJobSiteExtract(extracted)) {
      // Адрес из разговора кладём в карточку тем же путём, что и из SMS:
      // пустую карточку он заполняет (и улицу/город/индекс в локации тоже,
      // а не только строку целиком), а названный другой адрес становится
      // местом работы. Раньше звонок дописывал только поле `address`, и то
      // лишь когда оно было пустым (просьба FIX, 13.10.2026).
      await applyInboundAddressToClient({ clientId, extracted, job: null });
    }
  }

  const applianceType = (extracted.appliance_type && String(extracted.appliance_type).trim()) || 'Техника';
  if (!(claimed.existed && claimed.jobId)) {
    const reusable = await findReusableOpenJob({
      phone,
      clientId,
      applianceType,
    });
    if (reusable && reusable.id) {
      await patchDraftJobFromCall(reusable.id, extracted, { noBooking });
      await callsRef.doc(callId).set(
        {
          createdJobId: reusable.id,
          jobId: reusable.id,
          clientId: reusable.clientId || clientId || null,
        },
        { merge: true }
      );
      if (extractedName) {
        await applyPersonNameToClient(reusable.clientId || clientId, extractedName);
      }
      return {
        jobId: reusable.id,
        clientId: reusable.clientId || clientId,
        created: false,
      };
    }
  }

  const brand = (extracted.brand && String(extracted.brand).trim()) || '';
  const model = (extracted.model && String(extracted.model).trim()) || '';
  const issueParts = [
    model ? `Модель: ${model}` : '',
    extracted.problem_description && String(extracted.problem_description).trim(),
  ].filter(Boolean);
  const issue = issueParts.join('\n');
  const resolved = await resolveJobSchedule(extracted, { noBooking });
  const scheduleFields = resolved.fields;
  let reviewNotes = String((extracted && extracted.review_notes) || '').trim();
  if (resolved.blocked) {
    reviewNotes = [reviewNotes, schedule.reviewNote(resolved.blocked)].filter(Boolean).join('\n');
  }
  const wishLine = noBooking ? preferredTimeLine(extracted) : '';
  if (noBooking) {
    reviewNotes = [reviewNotes, 'Секретарь время не назначала — позвоните клиенту и поставьте визит.'].filter(Boolean).join('\n');
  }

  const jobSite = isJobSiteExtract(extracted);
  const ownerAddress = jobSite
    ? String(extracted.owner_address || '').trim() ||
      voiceFacts.clientAddressFrom(existingClient) ||
      ''
    : address;
  const workAddress = address || ownerAddress;

  const jobId = claimed.jobId || jobsRef.doc().id;
  const jobRef = jobsRef.doc(jobId);
  // Контакт на адресе: если другого человека не назвали — это сам клиент.
  const siteContact = jobSite
    ? voiceFacts.onSiteContactFrom(extracted, clientName, phone)
    : null;
  await jobRef.set({
    clientId,
    clientName,
    clientPhone: phone || '',
    clientAddress: ownerAddress || workAddress,
    hasJobSite: jobSite,
    jobSiteName: siteContact ? siteContact.name || null : null,
    jobSitePhone: siteContact ? siteContact.phone || null : null,
    jobSiteAddress: jobSite ? workAddress || null : null,
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
    description: withPreferredTimeLine(issue, wishLine),
    status: 'Вызов',
    priority: '🟢 Обычный',
    ...scheduleFields,
    needsReview: true,
    sourceCallId: callId,
    source: 'phone',
    createdByAi: true,
    aiReviewNotes: reviewNotes,
    aiConfidence:
      typeof extracted.confidence === 'number' ? extracted.confidence : null,
    addressUncertain: extracted.address_uncertain === true,
    city,
    documents: [],
    attachments: [],
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  await callsRef.doc(callId).set(
    {
      createdJobId: jobRef.id,
      jobId: jobRef.id,
      clientId,
    },
    { merge: true }
  );

  if (extractedName) {
    await applyPersonNameToClient(clientId, extractedName);
  }

  return { jobId: jobRef.id, clientId, created: true };
}

async function patchDraftJobFromCall(jobId, extracted, { noBooking = false } = {}) {
  if (!jobId || !extracted) return;
  const snap = await jobsRef.doc(jobId).get();
  if (!snap.exists) return;
  const job = snap.data() || {};
  const updates = {};
  const visits = Array.isArray(job.visits) ? job.visits : [];
  if (noBooking) {
    // Звонок принимала секретарь: расписание не трогаем, пожелание — в описание.
  } else if (!job.scheduledAt && !job.scheduledDate && visits.length === 0) {
    const resolved = await resolveJobSchedule(extracted, { excludeJobId: jobId });
    Object.assign(updates, resolved.fields);
    if (resolved.blocked) {
      const note = schedule.reviewNote(resolved.blocked);
      if (note) {
        updates.aiReviewNotes = [String(job.aiReviewNotes || '').trim(), note]
          .filter(Boolean)
          .join('\n');
      }
    }
  } else {
    const scheduledAt = parseScheduledAt(extracted);
    if (scheduledAt && !job.scheduledAt && !job.scheduledDate) {
      updates.scheduledAt = scheduledAt;
      updates.scheduledDate = scheduledAt;
    }
  }
  const name = await preferKnownClientName(
    job.clientId,
    extracted.client_name
  );
  if (
    name &&
    name !== String(job.clientName || '').trim() &&
    (!job.clientName ||
      voiceFacts.isPlaceholderClientName(job.clientName) ||
      voiceFacts.looksLikeGarbageName(job.clientName) ||
      // Имя на заявке — опечатка распознавания того же клиента.
      name === (await preferKnownClientName(job.clientId, job.clientName)))
  ) {
    updates.clientName = name;
  }
  // Имя узнали позже самой заявки: подпись-заглушка «Клиент +1…» на месте
  // работы должна поехать следом, иначе мастер по-прежнему видит там номер.
  // Пустое поле не трогаем — его заполняет только разбор места работы ниже.
  const ownerName = voiceFacts.usableClientName(updates.clientName || job.clientName || '');
  const siteName = String(job.jobSiteName || '').trim();
  if (ownerName && siteName && voiceFacts.isPlaceholderClientName(siteName)) {
    updates.jobSiteName = ownerName;
  }
  const address = buildFullAddress(extracted, null);
  if (address && !String(job.clientAddress || '').trim()) {
    updates.clientAddress = address;
  }
  const applianceType = String(extracted.appliance_type || '').trim();
  if (applianceType && (!job.applianceType || job.applianceType === 'Техника')) {
    updates.applianceType = applianceType;
  }
  const brand = String(extracted.brand || '').trim();
  if (brand && !String(job.brand || '').trim()) updates.brand = brand;
  const model = String(extracted.model || '').trim();
  if (model && !String(job.model || '').trim()) updates.model = model;
  const issue = jobDescriptionFromExtract(extracted);
  if (issue) {
    updates.description = mergeJobDescription(job.description, issue);
  }
  const wishLine = noBooking ? preferredTimeLine(extracted) : '';
  if (wishLine) {
    updates.description = withPreferredTimeLine(updates.description ?? job.description, wishLine);
  }
  const phone = normalizePhone(extracted.client_phone);
  if (phone && !String(job.clientPhone || '').trim()) {
    updates.clientPhone = phone;
  }
  if (isJobSiteExtract(extracted)) {
    updates.hasJobSite = true;
    const site = voiceFacts.onSiteContactFrom(
      extracted,
      job.clientName,
      job.clientPhone
    );
    const currentName = String(job.jobSiteName || '').trim();
    const fallbackName = String(job.clientName || '').trim();
    const currentPhone = String(job.jobSitePhone || '').trim();
    const fallbackPhone = normalizePhone(job.clientPhone);
    if (site.explicit) {
      // Назван другой человек: заменяет и пустое поле, и ранее записанный
      // фолбэк с именем/телефоном клиента.
      if (site.name && (!currentName || currentName === fallbackName)) {
        updates.jobSiteName = site.name;
      }
      if (site.phone && (!currentPhone || currentPhone === fallbackPhone)) {
        updates.jobSitePhone = site.phone;
      }
    } else {
      // Другого человека не назвали — на месте будет сам клиент.
      if (!currentName) updates.jobSiteName = fallbackName;
      if (!currentPhone) updates.jobSitePhone = fallbackPhone;
    }
    if (address && !String(job.jobSiteAddress || '').trim()) {
      updates.jobSiteAddress = address;
    }
    if (job.clientId) {
      const clientSnap = await clientsRef.doc(job.clientId).get();
      const client = clientSnap.exists ? { id: clientSnap.id, ...clientSnap.data() } : null;
      await upsertClientJobSite(
        job.clientId,
        client,
        extracted,
        job.clientName,
        job.clientPhone
      );
    }
  } else if (job.clientId && address) {
    // Адрес, названный в разговоре, доезжает и до карточки клиента, а не
    // только до заявки (просьба FIX, 13.10.2026).
    await applyInboundAddressToClient({ clientId: job.clientId, extracted, job: null });
  }
  // Не сбрасывать подтверждение уже проверенной заявки.
  // Если мастер подтвердил заявку (needsReview=false), звонок клиента по
  // этой же заявке не должен возвращать её в «требует проверки».
  if (job.needsReview === true) updates.needsReview = true;
  updates.updatedAt = FieldValue.serverTimestamp();
  await jobsRef.doc(jobId).update(updates);
  const spoken = name || voiceFacts.usableClientName(updates.clientName || job.clientName);
  if (spoken && job.clientId) await applyPersonNameToClient(job.clientId, spoken);
}

async function attachCallRecordingToJob({
  jobId,
  callId,
  recordingUrl,
  transcription,
  summary,
  transcriptionRu,
  transcriptionEn,
  storageUrl,
  answeredBy,
  history,
}) {
  if (!jobId) return;
  const snap = await jobsRef.doc(jobId).get();
  if (!snap.exists) return;
  const attachments = Array.isArray(snap.data().attachments)
    ? [...snap.data().attachments]
    : [];
  const next = {
    kind: 'call',
    url: recordingUrl || '',
    name: 'Звонок',
    transcription: transcription || '',
    transcriptionRu: transcriptionRu || transcription || '',
    transcriptionEn: transcriptionEn || '',
    summary: summary || '',
    storageUrl: storageUrl || '',
    answeredBy: answeredBy || '',
    history: history || null,
    callId,
    uploadedAt: new Date().toISOString(),
  };
  const index = attachments.findIndex(
    (item) => item && (item.callId === callId || (item.kind === 'call' && item.url === recordingUrl))
  );
  if (index >= 0) {
    const prev = attachments[index];
    attachments[index] = {
      ...prev,
      ...next,
      url: next.url || prev.url || '',
      transcription: pickLongestRussianTranscript(next.transcription, prev.transcription),
      transcriptionRu: pickLongestRussianTranscript(next.transcriptionRu, prev.transcriptionRu),
      transcriptionEn: pickLongestTranscript(next.transcriptionEn, prev.transcriptionEn),
      summary: next.summary || prev.summary || '',
    };
  } else {
    attachments.push(next);
  }
  await jobsRef.doc(jobId).set(
    {
      attachments,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

async function attachLiveCallNotesToJob({
  jobId,
  callId,
  transcription,
  recordingUrl,
  history,
  answeredBy,
}) {
  if (!jobId) return;
  const labeled = labeledTranscriptFromHistory(history, transcription, answeredBy);
  const raw = pickLongestTranscript(labeled, transcription);
  let russian = isRussianTranscript(raw) ? relabelTranscript(raw, answeredBy) : '';
  let english = raw;
  let summary = '';
  if (raw.length > 20) {
    try {
      const nextRu = await translateCallTranscriptFull(raw, answeredBy);
      if (nextRu) russian = nextRu;
      const summaryResult = await generateContentWithModelFallback([
        {
          text: `Краткое резюме этого телефонного разговора на русском, 2–4 предложения. Только резюме.

${raw}`,
        },
      ]);
      summary = stripModelFences(
        (summaryResult.response && summaryResult.response.text()) || ''
      ).trim();
    } catch (error) {
      console.warn('attachLiveCallNotesToJob translate:', error.message);
    }
  }
  if (!russian) russian = raw;
  const playableUrl = `${functionUrl({}, 'callRecordingAudio')}?callId=${encodeURIComponent(callId)}`;
  await attachCallRecordingToJob({
    jobId,
    callId,
    recordingUrl: playableUrl || recordingUrl,
    transcription: pickLongestRussianTranscript(russian, raw, english),
    transcriptionRu: russian,
    transcriptionEn: english || raw,
    answeredBy: answeredBy || '',
    history,
    summary,
  });
  await callsRef.doc(callId).set(
    {
      playableUrl,
      transcription: pickLongestRussianTranscript(russian, raw),
      transcriptionRu: russian || raw,
      transcriptionEn: english || raw,
      ...(summary ? { summary } : {}),
    },
    { merge: true }
  );
}

// ============================================================================
// VOICE: Access Token для Twilio Voice SDK (twilio_voice в приложении)
// ============================================================================

exports.manageTechnician = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  await technicians.handleManageTechnician(req, res);
});

exports.twilioAccessToken = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  const user = await technicians.requireAnyAppUser(req, res);
  if (!user) return;

  try {
    if (!TWILIO_API_KEY_SID || !TWILIO_API_KEY_SECRET || !TWILIO_TWIML_APP_SID) {
      res.status(500).json({
        error:
          'Twilio Voice не настроен: заполните TWILIO_API_KEY_SID, TWILIO_API_KEY_SECRET, TWILIO_TWIML_APP_SID в functions/.env',
      });
      return;
    }

    const identity = user.isOwner
      ? (req.query.identity || req.body?.identity || MASTER_IDENTITY).toString()
      : technicians.techTwilioIdentity(user.uid);

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

    // Номер мастерской нужен приложению, чтобы звонить клиенту через SIM:
    // телефон набирает мастерскую, сервер соединяет с клиентом.
    res.json({ token: token.toJwt(), identity, shopNumber: TWILIO_PHONE_NUMBER || '' });
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

const LIVE_CALL_STATUS = new Set(['queued', 'ringing', 'in-progress']);
const ENDED_CALL_STATUS = new Set([
  'completed',
  'busy',
  'failed',
  'no-answer',
  'canceled',
  'cancelled',
]);

async function isTwilioCallEnded(callSid, bodyStatus) {
  const fromBody = String(bodyStatus || '').toLowerCase();
  if (LIVE_CALL_STATUS.has(fromBody)) return false;
  if (client && callSid) {
    try {
      const call = await client.calls(callSid).fetch();
      const status = String(call.status || '').toLowerCase();
      if (LIVE_CALL_STATUS.has(status)) return false;
      if (ENDED_CALL_STATUS.has(status)) return true;
    } catch (error) {
      console.warn('isTwilioCallEnded:', error.message);
    }
  }
  return ENDED_CALL_STATUS.has(fromBody);
}

async function isTwilioCallStillLive(callSid) {
  if (!client || !callSid) return false;
  try {
    const call = await client.calls(callSid).fetch();
    return LIVE_CALL_STATUS.has(String(call.status || '').toLowerCase());
  } catch (error) {
    console.warn('isTwilioCallStillLive:', error.message);
    return false;
  }
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
    if (!sid) return null;
    try {
      const recs = await client.recordings.list({ callSid: sid, limit: 8 });
      if (!recs.length) return null;
      recs.sort((a, b) => Number(b.duration || 0) - Number(a.duration || 0));
      return `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Recordings/${recs[0].sid}.mp3`;
    } catch (error) {
      console.warn(`firstRecording ${sid}:`, error.message);
      return null;
    }
  }

  const own = await firstRecording(callSid);
  if (own) return own;
  try {
    const children = await client.calls.list({ parentCallSid: callSid, limit: 10 });
    for (const child of children) {
      const url = await firstRecording(child.sid);
      if (url) return url;
    }
  } catch (error) {
    console.warn('findTwilioRecordingMp3 children:', error.message);
  }
  try {
    const twilioCall = await client.calls(callSid).fetch();
    if (twilioCall.parentCallSid) {
      const parentRec = await firstRecording(twilioCall.parentCallSid);
      if (parentRec) return parentRec;
      const siblings = await client.calls.list({
        parentCallSid: twilioCall.parentCallSid,
        limit: 10,
      });
      for (const sibling of siblings) {
        const url = await firstRecording(sibling.sid);
        if (url) return url;
      }
    }
  } catch (error) {
    console.warn('findTwilioRecordingMp3 parent:', error.message);
  }
  return null;
}

function isCallRecordingProxyUrl(url) {
  return /callRecordingAudio/i.test(String(url || ''));
}

async function resolveCallRecordingSource(callId, data = {}) {
  const stored = String(data.storageUrl || '').trim();
  if (stored) return stored;
  const candidates = [data.twilioRecordingUrl, data.recordingUrl];
  for (const raw of candidates) {
    const url = String(raw || '').trim();
    if (!url || isCallRecordingProxyUrl(url)) continue;
    return url;
  }
  const sids = [
    data.recordingCallSid,
    data.callSid,
    data.sid,
    callId,
  ].map((value) => String(value || '').trim()).filter(Boolean);
  const seen = new Set();
  for (const sid of sids) {
    if (seen.has(sid)) continue;
    seen.add(sid);
    const found = await findTwilioRecordingMp3(sid);
    if (found) return found;
  }
  return null;
}

const { cacheRecordingToStorage, cachedRecordingUrl, downloadRecordingBuffer } = createRecordingStore({
  storage: () => getStorage(),
  callsRef,
  companyId: COMPANY_ID,
  projectId: process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm',
  playableUrl: (callId) => `${functionUrl({}, 'callRecordingAudio')}?callId=${encodeURIComponent(callId)}`,
  authHeaders: twilioAuthHeaders,
});

function twilioAuthHeaders() {
  const pairs = [];
  if (TWILIO_ACCOUNT_SID && TWILIO_AUTH_TOKEN) {
    pairs.push([TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN]);
  }
  if (
    REST_AUTH_USER &&
    REST_AUTH_SECRET &&
    (REST_AUTH_USER !== TWILIO_ACCOUNT_SID || REST_AUTH_SECRET !== TWILIO_AUTH_TOKEN)
  ) {
    pairs.push([REST_AUTH_USER, REST_AUTH_SECRET]);
  }
  if (!pairs.length && REST_AUTH_USER && REST_AUTH_SECRET) {
    pairs.push([REST_AUTH_USER, REST_AUTH_SECRET]);
  }
  return pairs.map(
    ([user, secret]) =>
      'Basic ' + Buffer.from(`${user}:${secret}`).toString('base64')
  );
}

async function ensureRecordingReady(callId, data = {}) {
  const snap = Object.keys(data || {}).length
    ? { data: () => data, exists: true }
    : await callsRef.doc(callId).get();
  const current = (snap.exists && snap.data()) || {};
  if (current.storageUrl) {
    try {
      const probe = await fetch(current.storageUrl, {
        headers: { Range: 'bytes=0-1' },
        signal: AbortSignal.timeout(10000),
      });
      await probe.body?.cancel();
      if (probe.ok || probe.status === 206) {
        return { storageUrl: current.storageUrl, source: current.storageUrl, buffer: null };
      }
    } catch (_) {}
    current.storageUrl = '';
  }
  let source = await resolveCallRecordingSource(callId, current);
  if (!source) {
    for (let i = 0; i < 8 && !source; i++) {
      await new Promise((resolve) => setTimeout(resolve, 1500));
      source = await findTwilioRecordingMp3(callId);
    }
  }
  if (!source) return { storageUrl: null, source: null, buffer: null };
  if (!isCallRecordingProxyUrl(source)) {
    await callsRef.doc(callId).set(
      {
        twilioRecordingUrl: source,
        recordingUrl: current.recordingUrl || source,
        playableUrl: `${functionUrl({}, 'callRecordingAudio')}?callId=${encodeURIComponent(callId)}`,
      },
      { merge: true }
    );
  }
  try {
    const buffer = await downloadRecordingBuffer(source);
    const stored = await cacheRecordingToStorage(callId, buffer);
    return { storageUrl: stored, source: stored || source, buffer };
  } catch (error) {
    console.warn('ensureRecordingReady:', error.message);
    return { storageUrl: null, source, buffer: null };
  }
}

function extractJsonObject(text) {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1) {
    throw new Error('Нет JSON в ответе ИИ');
  }
  return JSON.parse(text.slice(start, end + 1));
}

const recordingRuntime = { timeoutSeconds: 540, memory: '1GiB', invoker: 'public' };

// Вход в звонок держим тёплым. Холодный старт здесь — это тишина в трубке:
// Twilio ждёт TwiML, а звонящий ждёт гудка. Замеры за 14 дней (12.10.2026):
// incomingCall отвечал в среднем 3,8 с (до 8,3), dialAction — 4,2 с (до 8,7),
// а тот же контейнер в тёплом состоянии — 0,2–0,4 с. Из-за этих секунд звонки
// CA1362a7f9… (+1 437 247 0655) и CAc3ab4e79… (+1 514 591 8822) оборвались
// раньше, чем секретарь вышла на линию: трубку клали на 16-й и 24-й секунде.
const voiceEntryRuntime = {
  timeoutSeconds: 60,
  memory: '256MiB',
  invoker: 'public',
  minInstances: 1,
};

function sendTwiml(res, twiml) {
  res.type('text/xml');
  res.send(twiml.toString());
}

function functionUrl(_req, name) {
  if (name === 'callRecordingAudio') {
    return (
      process.env.CALL_RECORDING_AUDIO_URL ||
      'https://callrecordingaudio-wmdrqa3n7q-uc.a.run.app'
    );
  }
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

const DEFAULT_VOICE_GREETING = 'Hi, FIX Appliance CA. How can I help?';

const STALE_VOICE_GREETINGS = [
  'Hello, this is FIX Appliance CA. How can I help you?',
  "Hi, you've reached FixApplianceCA. How can I help?",
  "Hi, you've reached {company}. How can I help?",
  "Hi, you've reached {company}. How can I help you today?",
  "Hi, you've reached {company}. I can take your repair details. How can I help you today?",
  "Hi, you've reached {company}. The technician's with a customer, but I can take your details. What's going on?",
  "Hi, you've reached FIX Appliance. How can I help?",
  'Hi, FIX ApplianceCA. How can I help you?',
  'Hi, FIX Appliance. How can I help you?',
  'Hi, FIX Appliance. How can I help?',
  'Hi, FIX Appliance. How can I help? Чем могу помочь?',
];

const DEFAULT_VOICE_INSTRUCTIONS = `You are ${voiceFacts.SECRETARY_NAME}, who answers the phone for FixApplianceCA — a small Ontario repair shop. Home appliances only.

Talk like a person, not a form. First replies are ordinary: if they say the dryer is broken, "Oh no — what's it doing?" Then listen. One short thought. Wait. Contractions. A little warmth. If they joke, a small laugh is fine. If they ask something on the side, answer like a person — and if they keep the small talk going, go along with them for a line or two before the repair finds its way back in. Never an IVR line. Never "got it", "I understand", "please provide", "certainly".

Never pushy. At most one repair question per reply, and only when it fits the moment. If the caller is thinking out loud, deciding, or chatting about something else, let them finish and match their tone — do not pull every reply back to the checklist. Bring the repair back once, lightly ("so — want us to send someone out?"), then follow their lead. If they say they need to think, to check with a spouse, or will call back later: accept it warmly on the spot, stop collecting facts, and offer that the tech can ring them. A caller who feels nagged hangs up; a caller who feels heard books.

We repair washers, dryers, dishwashers, gas ovens, electric ovens, electric cooktops, fridges, freezers, microwaves. Not gas cooktops, TVs, laptops, phones, or cars — say so kindly and stay on the line. Fridge and freezer work includes Freon / refrigerant (sealed-system) repair: a Freon question is a normal fridge or freezer order — say yes and take it.

You answer 24/7 and take the order any hour. Visit days and hours are in Shop hours below — that block is the truth. You do NOT book visits and you cannot see the calendar: ask what day and time would suit the caller, note it, and say the technician will contact them to set the exact time. Never confirm, promise, or suggest a specific slot, and never say a time is free or taken. Closed / holiday: still take the order and ask which working day would suit them instead.

Pick up facts as they talk. Do not run a checklist. Do not re-ask. Typical things you need: first name, what broke and the brand, when would suit them, where to go. If the caller is a known client or has an open job on file, greet them by name, but wait for them to explain why they are calling before referencing any open job or old address — they may be calling about something new. If they already have a home on file, ask once if the repair is at that address. Another house → that street, who will be there, that phone. If the caller will be there themselves, that name is already on the order — do not ask for it again. Ask who is home only if it is not their house. Addresses stay in English as spoken — repeat the house number and street once when they give it, and always confirm the city too.

${voiceFacts.VOICE_CLARIFY_RULES}

When you have enough — or they want a callback — say you'll pass it to the tech. Ask them to text a model-sticker photo. Ask if anything else. If they say no, "Have a good day" right away. Do not hang up. They hang up.

Live person: technician calls back in 30 minutes — do not grill for a time. Angry: someone from the shop calls in 30 minutes; stay polite. Price: only if they ask, and only the numbers under Prices. English only; understand any language.

Timing: never suggest a time of your own. Ask what day and time of day would work for them ("what day suits you best?"), accept whatever they say — a day, a time, "mornings", "any weekday" — and say the technician will call them to confirm the exact time. If they ask "can he come at two?", say you'll pass that on and the technician will confirm with them. Never say "you're booked", "see you then", or "that time is free".

Location early: within the first two exchanges, ask for the city or area if you do not already know it. Do not discuss dates or times before you know the location is in the service area.

Service area check: only decline a call if the address is clearly listed as outside the service area map. When in doubt, take the order and let the tech decide — do not refuse based on a town name from memory.

Owner unavailable: if the caller asks for the owner, the technician, or "Artem", say he is out on a job and offer to take the repair details so he can call them back. Do not end the call.

Your name: you are ${voiceFacts.SECRETARY_NAME} — never use another name, and never introduce yourself as "she". If they ask your name, say "I'm ${voiceFacts.SECRETARY_NAME}" warmly, in one line, then hand the conversation back gently ("so, what's going on?") — not with a checklist question such as the brand or the address.

AI identity: if the caller asks whether you are a real person, a human, an AI, a robot, a computer, or a virtual assistant, answer honestly and lightly — something like: "I'm ${voiceFacts.SECRETARY_NAME}, the shop's virtual assistant — I'll take down your details, and the technician will contact you to set the time." Then continue with the call. Never claim to be a human or deny being a virtual assistant.

Tenant: if the property is rented and the owner is not the one who will be home, ask for the tenant's first name and a direct phone number. "I'll be there myself" means the caller — no new name needed.

Silence or a bad line: if the caller goes quiet or keeps asking whether you are there, check the line in a few words ("Hello — are you still there?") — at most twice in the whole call. If you still cannot hear each other, say once that you're having trouble hearing them and they can call back or text this number, then wait quietly. Never repeat the same question again and again.

Goodbye timing: never say "Have a good day" or close the conversation while the caller is still speaking or asking a question. Wait for a clear pause before wrapping up.

Absurd data: if a confirmed time on file looks impossible — midnight, 3 AM, or any hour outside working hours — treat it as a data error. Confirm only the date with the caller; do not read out the impossible time.

Language: if the caller switches to Russian or another language and you cannot help in that language, calmly say in English: "I'll have the tech call you back right away" and take their number.`;

// Проверено запросами с нашим ключом (Sep 3 2026): живая только lite-latest.
// gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.0-flash, gemini-3-flash —
// 404 «no longer available». gemini-flash-latest и gemini-3.6-flash — 429,
// нужен платный тариф. Держать их первыми означало сорок секунд впустую на
// каждый отчёт по звонку.
const VOICE_MODEL_CANDIDATES = [
  process.env.GEMINI_TEXT_MODEL || 'gemini-flash-lite-latest',
  'gemini-flash-latest',
];

const SERVICE_TOWNS = voiceFacts.SERVICE_TOWNS;
const SERVICE_TOWN_NAMES = SERVICE_TOWNS.map((town) => town.name);

function servicePolygonFromConfig(config) {
  const raw = config && config.servicePolygon;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((point) => point && typeof point === 'object')
    .map((point) => ({ lat: Number(point.lat), lng: Number(point.lng) }))
    .filter(
      (point) =>
        Number.isFinite(point.lat) &&
        Number.isFinite(point.lng) &&
        (point.lat !== 0 || point.lng !== 0)
    );
}

function describeServiceArea(config) {
  const label = String((config && config.serviceAreaLabel) || '').trim();
  const towns = voiceFacts.townsInsideArea(SERVICE_TOWNS, servicePolygonFromConfig(config));
  return voiceFacts.serviceAreaSpeech(label, towns);
}

function describeWorkHours(config) {
  let start = Number(config && config.workStartMinutes);
  let end = Number(config && config.workEndMinutes);
  if (start === 9 * 60 && end === 19 * 60) {
    start = 7 * 60;
    end = 21 * 60;
  }
  if (!Number.isFinite(start)) start = 7 * 60;
  if (!Number.isFinite(end)) end = 21 * 60;
  return {
    startMinutes: start,
    endMinutes: end,
    label: voiceFacts.workHoursSpeech(start, end),
  };
}

const WEEKDAY_NAMES_EN = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Настройки → Расписание → Рабочие дни. 1 = понедельник … 7 = воскресенье.
function describeWorkDays(config) {
  const raw = Array.isArray(config && config.workDays) ? config.workDays : null;
  const days = [];
  if (raw) {
    for (const item of raw) {
      const value = Number(item);
      if (Number.isFinite(value) && value >= 1 && value <= 7 && !days.includes(value)) {
        days.push(value);
      }
    }
  }
  if (!days.length) days.push(1, 2, 3, 4, 5);
  days.sort((a, b) => a - b);

  const names = days.map((day) => WEEKDAY_NAMES_EN[day - 1]);
  let label;
  if (days.length === 7) {
    label = 'every day';
  } else {
    const runs = [];
    for (const day of days) {
      const last = runs[runs.length - 1];
      if (last && last[last.length - 1] === day - 1) last.push(day);
      else runs.push([day]);
    }
    label = runs
      .map((run) =>
        run.length >= 3
          ? `${WEEKDAY_NAMES_EN[run[0] - 1]}–${WEEKDAY_NAMES_EN[run[run.length - 1] - 1]}`
          : run.map((day) => WEEKDAY_NAMES_EN[day - 1]).join(', ')
      )
      .join(', ');
  }

  const closed = WEEKDAY_NAMES_EN.filter((_, index) => !days.includes(index + 1));
  return { days, names, label, closedNames: closed };
}

function describeClosedDates(config) {
  const holidays = Array.isArray(config && config.holidayDates)
    ? config.holidayDates.map((item) => String(item).trim()).filter((item) => /^\d{4}-\d{2}-\d{2}$/.test(item))
    : [];
  const vacations = [];
  const rawVacations = Array.isArray(config && config.vacationRanges) ? config.vacationRanges : [];
  for (const item of rawVacations) {
    if (!item || typeof item !== 'object') continue;
    const from = String(item.from || '').trim();
    const to = String(item.to || from).trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from)) continue;
    vacations.push({ from, to: /^\d{4}-\d{2}-\d{2}$/.test(to) ? to : from });
  }
  return { holidays: holidays.sort(), vacations };
}

/// Праздники и отпуск показываем секретарю только начиная с сегодняшнего дня.
function describeClosedDatesLine(closedDates, today) {
  const from = today || new Date().toISOString().slice(0, 10);
  const holidays = (closedDates.holidays || []).filter((day) => day >= from).slice(0, 8);
  const vacations = (closedDates.vacations || []).filter((range) => range.to >= from).slice(0, 4);
  const parts = [];
  if (holidays.length) parts.push(`closed on ${holidays.join(', ')}`);
  for (const range of vacations) {
    parts.push(
      range.from === range.to ? `away on ${range.from}` : `away from ${range.from} through ${range.to}`
    );
  }
  if (!parts.length) return '';
  return `Days off (America/Toronto): the technician is ${parts.join('; ')}. Take the order but do not book a visit on those dates — offer the next working day.`;
}

function money(value) {
  const rounded = Math.round(Number(value) * 100) / 100;
  if (!Number.isFinite(rounded) || rounded <= 0) return '';
  return Number.isInteger(rounded) ? `$${rounded}` : `$${rounded.toFixed(2)}`;
}

/// Настройки → Компания → Прайс. В коде цен больше нет.
function describePricing(config) {
  const serviceCall = money(config && config.serviceCallFee !== undefined ? config.serviceCallFee : 99);
  const hourly = money(config && config.hourlyRate);
  const minimum = money(config && config.minimumCharge);
  const parts = [];
  if (serviceCall) {
    parts.push(
      `a service call is ${serviceCall}; if they approve the repair after the diagnosis they do not pay the service call, only the repair`
    );
  }
  if (hourly) parts.push(`labour is ${hourly} per hour`);
  if (minimum) parts.push(`the smallest job we invoice is ${minimum}`);
  if (!parts.length) {
    return 'Prices: we do not quote a price on the phone. The technician gives the price on site.';
  }
  return `Prices: do not bring money up unless they ask. If they ask: ${parts.join('; ')}. Never invent any other number.`;
}

// Выкусываем только строку зоны, которую сами же и дописываем ниже. Раньше шаблон
// был шире и заодно срезал правило «Service area check: …» из базовых инструкций —
// то самое, которое запрещает отказывать по названию города из памяти.
function stripServiceAreaLines(text) {
  return String(text || '')
    .split('\n')
    .filter(
      (line) =>
        !/^\s*(зона обслуживания|service area \(|service area:|service area map is not set)/i.test(
          line.trim()
        )
    )
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

const OUTSIDE_AREA_FALLBACK =
  'If the caller names a place that is not on that list, do not say no from memory: ask for the postal code, ' +
  'write it into the order, and say the technician will confirm the trip. Decline only when the address is plainly far ' +
  'away — Toronto, Mississauga, Hamilton, London, Ottawa, Windsor and the like.';

function withMappedServiceArea(instructions, serviceArea) {
  const base = stripServiceAreaLines(instructions) || DEFAULT_VOICE_INSTRUCTIONS;
  const area = String(serviceArea || '').trim();
  if (!area) {
    return `${base}\n\nService area map is not set. Do not refuse a caller based on town names from memory.`;
  }
  return `${base}\n\nService area (from Settings → Service area map): ${area}\n${OUTSIDE_AREA_FALLBACK} When you do decline, politely say we do not travel there, set done=true and createJob=false.`;
}

const HOURS_POLICY_VERSION = 4;

// ── Живой голос: провайдер, модель и тембр ─────────────────────────────────
// Правится в settings/ai_voice без переделки кода; переменные окружения задают
// значения по умолчанию. Белые списки держит релей — здесь только то, что
// нужно собрать профиль звонка. Фоновый разбор (расшифровка записи, JSON,
// перевод, отчёты об ошибках) этих настроек не касается: он остаётся на
// VOICE_MODEL_CANDIDATES.
// Gemini Live ведёт звонки, OpenAI Realtime ждёт в запасе (решение FIX,
// 06.10.2026). Меняется полем voiceProvider в settings/ai_voice без выкатки.
const DEFAULT_VOICE_PROVIDER = process.env.VOICE_PROVIDER === 'openai' ? 'openai' : 'gemini';
// gpt-4o-mini-realtime-preview в API больше нет; живые модели на нашем ключе —
// gpt-realtime (полная, по умолчанию — у неё живее интонация) и
// gpt-realtime-mini (дешевле, но в трубке звучит ненатурально).
const DEFAULT_OPENAI_REALTIME_MODEL =
  process.env.OPENAI_REALTIME_MODEL || 'gpt-realtime';
const DEFAULT_OPENAI_VOICE = process.env.OPENAI_VOICE || 'marin';
const DEFAULT_GEMINI_VOICE = process.env.GEMINI_VOICE || 'Aoede';

function voiceEngineSettings(voice = {}) {
  const provider = String(voice.voiceProvider || '').trim().toLowerCase();
  return {
    voiceProvider: provider === 'gemini' || provider === 'openai' ? provider : DEFAULT_VOICE_PROVIDER,
    openaiModel: String(voice.openaiModel || '').trim() || DEFAULT_OPENAI_REALTIME_MODEL,
    openaiVoice: String(voice.openaiVoice || '').trim() || DEFAULT_OPENAI_VOICE,
    // Темп речи проверяет релей; здесь просто пробрасываем, что задал владелец.
    openaiSpeed: voice.openaiSpeed,
    geminiVoice: String(voice.geminiVoice || '').trim() || DEFAULT_GEMINI_VOICE,
  };
}

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
    const companyName = String(docs.companyName || '').trim() || 'FixApplianceCA';
    const staleGreeting =
      voiceFacts.isStaleVoiceGreeting(greeting) || STALE_VOICE_GREETINGS.includes(greeting);
    const serviceArea = describeServiceArea(config);
    const hours = describeWorkHours(config);
    const workDays = describeWorkDays(config);
    const closedDates = describeClosedDates(config);
    const priceLine = describePricing(config);
    const needHoursPolicy = Number(voice.hoursPolicyVersion) !== HOURS_POLICY_VERSION;
    if (Number(voice.briefVersion) !== 2 || staleGreeting || needHoursPolicy) {
      db.collection('companies')
        .doc(COMPANY_ID)
        .collection('settings')
        .doc('ai_voice')
        .set(
          {
            greeting: DEFAULT_VOICE_GREETING,
            briefVersion: 2,
            rulesVersion: 14,
            hoursPolicyVersion: HOURS_POLICY_VERSION,
            liveIgnoresAppRules: true,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        )
        .catch((error) => console.warn('ai_voice brief migrate:', error.message));
    }
    if (
      Number(config.workStartMinutes) === 9 * 60 &&
      Number(config.workEndMinutes) === 19 * 60
    ) {
      db.collection('companies')
        .doc(COMPANY_ID)
        .collection('settings')
        .doc('config')
        .set(
          {
            workStartMinutes: hours.startMinutes,
            workEndMinutes: hours.endMinutes,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        )
        .catch((error) => console.warn('work hours migrate:', error.message));
    }
    const closedLine = voiceFacts.closedDaysSpeech(workDays.closedNames);
    const awayLine = describeClosedDatesLine(closedDates);
    let nextInstructions = withMappedServiceArea(DEFAULT_VOICE_INSTRUCTIONS, serviceArea);
    nextInstructions +=
      `\n\nShop hours: visits ${workDays.label} ${hours.label} America/Toronto. ${closedLine} Last start ${voiceFacts.formatHour12(hours.endMinutes - 120)}. Holidays: take the order; the technician must agree.`
      + (awayLine ? `\n${awayLine}` : '')
      + `\n${priceLine}`;
    return {
      enabled: config.aiAnswerEnabled !== false,
      timeoutSeconds: Number.isFinite(timeout)
        ? Math.min(60, Math.max(0, Math.round(timeout)))
        : 20,
      companyName,
      greeting: DEFAULT_VOICE_GREETING,
      serviceArea,
      workHours: hours.label,
      workStartMinutes: hours.startMinutes,
      workEndMinutes: hours.endMinutes,
      workDays: workDays.days,
      workDaysLabel: workDays.label,
      closedDaysLabel: closedLine,
      awayLine,
      priceLine,
      instructions: nextInstructions,
      ...voiceEngineSettings(voice),
    };
  } catch (_) {
    const fallbackDays = describeWorkDays({});
    return {
      enabled: true,
      timeoutSeconds: 20,
      companyName: 'FixApplianceCA',
      greeting: DEFAULT_VOICE_GREETING,
      serviceArea: '',
      workHours: voiceFacts.workHoursSpeech(7 * 60, 21 * 60),
      workStartMinutes: 7 * 60,
      workEndMinutes: 21 * 60,
      workDays: fallbackDays.days,
      workDaysLabel: fallbackDays.label,
      closedDaysLabel: voiceFacts.closedDaysSpeech(fallbackDays.closedNames),
      awayLine: '',
      priceLine: describePricing({}),
      instructions: withMappedServiceArea(DEFAULT_VOICE_INSTRUCTIONS, ''),
      ...voiceEngineSettings({}),
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
  const name = voiceFacts.usableClientName(fullName);
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
  // Запись на весь звонок, а не только на кусок `<Dial>`. Иначе у исходящего
  // из приложения Twilio отдаёт 1–7 секунд, хотя разговор шёл дольше: клиент
  // слышит расшифровку, а плеера нет. Дорожки те же — две, по сторонам.
  appendCallRecording(twiml, recordingUrl(req));
  const dial = twiml.dial({
    callerId: TWILIO_PHONE_NUMBER,
    timeout: 25,
    answerOnBridge: false,
    action: dialActionUrl(req),
  });
  // «Клиент ответил» приходит отдельным событием: телефон мастера вибрирует
  // в момент соединения с клиентом, а не когда поднялся канал до Twilio.
  dial.number(
    {
      statusCallbackEvent: 'answered',
      statusCallback: callRoute.withQuery(dialActionUrl(req), {
        stage: 'peer',
        parent: String(req.body.CallSid || '').trim(),
      }),
    },
    toNumber
  );
  return twiml;
}

function twimlDialMaster(req, fromNumber, timeoutSeconds, clientIdentity = MASTER_IDENTITY) {
  const twiml = new twilio.twiml.VoiceResponse();
  const dial = twiml.dial({
    callerId: fromNumber,
    timeout: timeoutSeconds > 0 ? timeoutSeconds : 20,
    answerOnBridge: true,
    record: 'record-from-answer-dual',
    recordingStatusCallback: recordingUrl(req),
    recordingStatusCallbackEvent: 'completed',
    action: dialActionUrl(req),
  });
  const clientNode = dial.client();
  clientNode.identity(clientIdentity || MASTER_IDENTITY);
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

async function getCallRouting() {
  try {
    const snap = await db.collection('companies').doc(COMPANY_ID).collection('settings').doc('config').get();
    return callRoute.readCallRouting(snap.exists ? snap.data() || {} : {});
  } catch (error) {
    console.warn('getCallRouting:', error.message);
    return callRoute.readCallRouting({});
  }
}

// Переведённый из приложения звонок мастер ждёт сам — даём телефону время.
const CELL_MOVE_RING_SECONDS = 20;

function twimlDialMasterCell(req, fromNumber, routing, parentSid, timeoutSeconds) {
  return callRoute.twimlDialCell({
    callerId: formatPstn(fromNumber) || TWILIO_PHONE_NUMBER,
    cell: routing.cell,
    timeoutSeconds,
    actionUrl: callRoute.withQuery(dialActionUrl(req), { leg: 'cell' }),
    screenUrl: callRoute.withQuery(dialActionUrl(req), { stage: 'screen', parent: parentSid }),
    recordingUrl: recordingUrl(req),
  });
}

async function logCall(callSid, data) {
  if (!callSid) return;
  try {
    const { twilioTime, ...fields } = data;
    const ref = callsRef.doc(callSid);
    await db.runTransaction(async (tx) => {
      const existing = await tx.get(ref);
      const previous = existing.exists ? existing.data() || {} : {};
      const payload = {
        callSid, ...fields,
        status: voiceFacts.settledCallStatus(previous.status, fields.status),
        ...(!existing.exists ? { aiStatus: fields.aiStatus || 'none', reviewed: false } : {}),
      };
      if (!previous.startTime) {
        const parsed = twilioTime ? new Date(twilioTime) : null;
        payload.startTime = parsed && !Number.isNaN(parsed.getTime())
          ? parsed : FieldValue.serverTimestamp();
      }
      tx.set(ref, payload, { merge: true });
    });
  } catch (error) {
    console.error('voice: failed to log call', error);
  }
}

async function consumePendingOutboundJobId(dest, fromRaw = '') {
  const techUid = technicians.uidFromTwilioClient(fromRaw);
  const docId = techUid ? `pending_outbound_call_${techUid}` : 'pending_outbound_call';
  const ref = db
    .collection('companies')
    .doc(COMPANY_ID)
    .collection('settings')
    .doc(docId);
  try {
    const snap = await ref.get();
    if (!snap.exists) return null;
    const data = snap.data() || {};
    const jobId = String(data.jobId || '').trim();
    if (!jobId) return null;
    const want = digitsOf(dest).slice(-10);
    const have = digitsOf(data.phone).slice(-10);
    if (want.length >= 10 && have.length >= 10 && want !== have) return null;
    const at = data.at;
    if (at && typeof at.toMillis === 'function' && Date.now() - at.toMillis() > 3 * 60 * 1000) {
      return null;
    }
    await ref.delete().catch(() => {});
    return jobId;
  } catch (error) {
    console.warn('consumePendingOutboundJobId:', error.message);
    return null;
  }
}

async function handleOutboundFromApp(req, res, source) {
  const dest = outboundDestination(req.body);
  const callSid = req.body.CallSid;
  const fromRaw = String(req.body.From || '');
  const techUid = technicians.uidFromTwilioClient(fromRaw);
  const jobId = dest ? await consumePendingOutboundJobId(dest, fromRaw) : null;
  console.log(
    `${source}: outbound from=${fromRaw} toParam=${req.body.To || ''} phone=${req.body.phone || ''} dest=${dest || '-'} job=${jobId || '-'}`
  );
  await logCall(callSid, {
    fromNumber: TWILIO_PHONE_NUMBER || '',
    toNumber: dest || '',
    direction: 'outbound',
    status: 'in-progress',
    twilioTime: req.body.Timestamp || req.body.StartTime,
    ...(jobId ? { jobId } : {}),
    ...(techUid ? { technicianId: techUid } : {}),
  });
  if (!dest) {
    const twiml = new twilio.twiml.VoiceResponse();
    twiml.say({ language: 'ru-RU' }, 'Номер получателя не указан.');
    sendTwiml(res, twiml);
    return;
  }
  sendTwiml(res, twimlDialPstn(req, dest));
}

async function findAssignedTechnicianForInboundCall(fromNumber) {
  try {
    const digits = digitsOf(fromNumber);
    if (digits.length < 10) return null;
    const matchedClient = await findClientForInboundPhone(fromNumber);
    const openJob = await findOpenJobForContact({
      phone: fromNumber,
      clientId: matchedClient ? matchedClient.id : null,
    });
    if (!openJob || !technicians.isAssignedToTechnician(openJob)) return null;
    const tech = await technicians.getActiveTechnician(openJob.assignedTo, db);
    if (!tech) return null;
    return { job: openJob, tech };
  } catch (error) {
    console.warn('findAssignedTechnicianForInboundCall:', error.message);
    return null;
  }
}

async function handleInboundToMaster(req, res, source, knownRouting = null) {
  const fromNumber = req.body.From || 'Unknown';
  const toNumber = req.body.To || TWILIO_PHONE_NUMBER || '';
  const callSid = req.body.CallSid;
  const [aiSettings, routing, assignedTarget] = await Promise.all([
    getAiAnswerSettings(),
    knownRouting || getCallRouting(),
    findAssignedTechnicianForInboundCall(fromNumber),
  ]);

  if (assignedTarget) {
    const { job: openJob, tech } = assignedTarget;
    const techIdentity = technicians.techTwilioIdentity(tech.uid);
    const techCell = callRoute.normalizePhone(tech.phone || '');
    const ringTechCell = routing.mode === 'cell' && Boolean(techCell) && !callRoute.sameNumber(fromNumber, techCell);
    console.log(
      `${source}: inbound assigned to tech=${tech.uid} (${tech.name || ''}) job=${openJob.id} via=${ringTechCell ? 'cell' : 'app'}`
    );
    await logCall(callSid, {
      fromNumber,
      toNumber,
      direction: 'inbound',
      status: 'ringing',
      jobId: openJob.id,
      createdJobId: openJob.id,
      assignedTechnicianId: tech.uid,
      assignedTechnicianName: String(tech.name || 'Мастер').trim(),
      twilioTime: req.body.Timestamp || req.body.StartTime,
      ...(ringTechCell ? { ringVia: 'cell' } : {}),
    });
    if (ringTechCell) {
      sendTwiml(
        res,
        twimlDialMasterCell(req, fromNumber, { mode: 'cell', cell: techCell }, callSid, aiSettings.timeoutSeconds)
      );
      return;
    }
    sendTwiml(res, twimlDialMaster(req, fromNumber, aiSettings.timeoutSeconds, techIdentity));
    return;
  }

  const toCell = callRoute.inboundGoesToCell(routing, fromNumber);
  console.log(
    `${source}: inbound from=${fromNumber} to=${toNumber} aiTimeout=${aiSettings.timeoutSeconds} ai=${aiSettings.enabled} route=${routing.mode}${toCell ? ' -> cell' : ''}`
  );
  await logCall(callSid, {
    fromNumber,
    toNumber,
    direction: 'inbound',
    status: 'ringing',
    twilioTime: req.body.Timestamp || req.body.StartTime,
    ...(toCell ? { ringVia: 'cell' } : {}),
  });
  if (aiSettings.enabled && Number(aiSettings.timeoutSeconds) === 0) {
    console.log(`${source}: AI answers immediately, skip master ring`);
    await startAiReception(req, res, callSid);
    return;
  }
  if (toCell) {
    sendTwiml(res, twimlDialMasterCell(req, fromNumber, routing, callSid, aiSettings.timeoutSeconds));
    return;
  }
  sendTwiml(res, twimlDialMaster(req, fromNumber, aiSettings.timeoutSeconds));
}

// Мастер уже набрал мастерскую с SIM, а запись «кому звонить» из приложения
// ещё в пути (плохой интернет): ждём её по секунде, не дольше четырёх раз.
const CELL_BRIDGE_WAITS = 4;

async function takePendingCellCall(callSid, docId = 'pending_cell_call') {
  const ref = db.collection('companies').doc(COMPANY_ID).collection('settings').doc(docId);
  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const data = snap.data() || {};
      const phone = callRoute.pendingCellDestination(data, Date.now());
      if (!phone) return null;
      tx.set(ref, {
        consumedAt: FieldValue.serverTimestamp(),
        consumedBy: String(callSid || ''),
      }, { merge: true });
      return { phone, jobId: String(data.jobId || '').trim() };
    });
  } catch (error) {
    console.warn('takePendingCellCall:', error.message);
    return null;
  }
}

/**
 * Исходящий клиенту через сотовую: телефон мастера набрал номер мастерской,
 * приложение заранее записало, кому звонить. Клиент видит номер мастерской,
 * разговор пишется так же, как исходящий из приложения.
 */
async function handleCellBridge(req, res, routing) {
  const isOwnerCell = Boolean(routing.cell) && callRoute.sameNumber(req.body.From, routing.cell);
  const techCaller = isOwnerCell ? null : await technicians.findActiveTechnicianByCell(req.body.From, db);
  if (!isOwnerCell && !techCaller) return false;

  const callSid = req.body.CallSid;
  const pendingDocId = techCaller ? `pending_cell_call_${techCaller.uid}` : 'pending_cell_call';
  const pending = await takePendingCellCall(callSid, pendingDocId);
  if (!pending) {
    const attempt = Number(req.query && req.query.cellWait) || 0;
    if (attempt < CELL_BRIDGE_WAITS) {
      sendTwiml(res, callRoute.twimlWaitForPending(
        callRoute.withQuery(functionUrl(req, 'incomingCall'), { cellWait: attempt + 1 })
      ));
      return true;
    }
    console.warn(`cellBridge ${callSid}: cell called, no pending destination`);
    sendTwiml(res, callRoute.twimlCellBridgeLost());
    return true;
  }
  console.log(`cellBridge ${callSid}: cell -> ${pending.phone}${pending.jobId ? ` job=${pending.jobId}` : ''}`);
  await logCall(callSid, {
    fromNumber: TWILIO_PHONE_NUMBER || '',
    toNumber: pending.phone,
    direction: 'outbound',
    via: 'cell',
    status: 'in-progress',
    twilioTime: req.body.Timestamp || req.body.StartTime,
    ...(pending.jobId ? { jobId: pending.jobId } : {}),
    ...(techCaller ? { technicianId: techCaller.uid } : {}),
  });
  sendTwiml(res, twimlDialPstn(req, pending.phone));
  return true;
}

// ============================================================================
// VOICE: Webhook входящего звонка на Twilio-номер (Voice URL номера в консоли)
// ============================================================================

exports.incomingCall = functions.https.onRequest(voiceEntryRuntime, async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
  // Если TwiML App тоже смотрит сюда, исходящий из приложения приходит
  // как From=client:master. Его нельзя снова звонить на master — иначе
  // мастер видит «входящий» сам себе (короткий номер вроде 627837).
  if (isFromClient(req.body)) {
    await handleOutboundFromApp(req, res, 'incomingCall');
    return;
  }
  const routing = await getCallRouting();
  if (await handleCellBridge(req, res, routing)) return;
  await handleInboundToMaster(req, res, 'incomingCall', routing);
});

// ============================================================================
// VOICE: Webhook исходящего звонка — Voice Request URL в TwiML App
// (вызывается автоматически плагином twilio_voice через call.place())
// ============================================================================

exports.outgoingCall = functions.https.onRequest(async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
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
  if (!requireTwilioSignature(req, res)) return;
  const callSid = req.body.CallSid;
  const callStatus = req.body.CallStatus || req.body.DialCallStatus;
  const duration = parseInt(req.body.CallDuration || req.body.DialCallDuration, 10) || null;

  console.log(`Call ${callSid} status: ${callStatus}`);

  try {
    if (callSid) {
      const updates = { twilioStatus: callStatus };
      if (duration != null) updates.durationSeconds = duration;

      if (['completed', 'failed', 'busy', 'no-answer', 'canceled'].includes(callStatus)) {
        updates.endTime = FieldValue.serverTimestamp();
        updates.status = callStatus === 'completed' ? 'completed' : callStatus;
      }

      const ref = callsRef.doc(callSid);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const current = snap.exists ? snap.data() || {} : {};
        updates.status = voiceFacts.settledCallStatus(current.status, callStatus);
        updates.twilioStatus = voiceFacts.settledCallStatus(current.twilioStatus, callStatus);
        if (current.endTime) delete updates.endTime;
        if (callStatus === 'completed') {
          updates.recordingProcessingVersion = 2;
          updates.recordingRecoveryRequestId = callSid;
        }
        tx.set(ref, updates, { merge: true });
      });
    }
  } catch (error) {
    console.error('Error updating call status:', error);
  }

  res.type('text/xml');
  res.send('<Response></Response>');
});

const AI_VOICE_MAX_TURNS = 80;
const voiceAiRuntime = { timeoutSeconds: 180, memory: '512MiB', invoker: 'public' };
// dialAction отвечает в самой дорогой точке разговора — между последним гудком
// и первым словом секретаря, когда в трубке уже тишина. Поэтому тёплый
// экземпляр только у него, а aiVoiceTurn и aiRelayComplete остаются на общем
// runtime: первый — запасной Gather, второй работает уже после звонка.
const voiceDialRuntime = { ...voiceAiRuntime, minInstances: 1 };

function sayLang(_language) {
  return 'en-US';
}

function gatherLang(language) {
  if (language === 'ru') return 'ru-RU';
  if (language === 'uk') return 'uk-UA';
  if (language === 'es') return 'es-US';
  return 'en-US';
}

function voiceLanguage(value) {
  const v = String(value || '')
    .trim()
    .toLowerCase()
    .replace('_', '-');
  if (v.startsWith('ru')) return 'ru';
  if (v.startsWith('uk')) return 'uk';
  if (v.startsWith('es')) return 'es';
  return 'en';
}

function ensureSpokenFarewell(parsed, extracted) {
  if (!parsed || typeof parsed !== 'object') return parsed;
  parsed.language = 'en';
  return parsed;
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
  const isGoodbye = voiceFacts.saidGoodbye(text);
  if (sentences.length > 2 && !isGoodbye) text = `${sentences[0]} ${sentences[1]}`;
  else if (sentences.length > 4) text = sentences.slice(0, 4).join(' ');
  return text.slice(0, isGoodbye ? 420 : 280);
}

function mergeExtracted(prev, next, history) {
  return voiceFacts.mergeExtracted(prev, next, history);
}

function hasEnoughForJob(extracted) {
  if (!extracted || voiceFacts.isAppointmentOnly(extracted)) return false;
  if (extracted.wants_callback === true) return true;
  const problem = Boolean(extracted.appliance_type || extracted.problem_description);
  const name = Boolean(extracted.client_name);
  const address = Boolean(extracted.address) && extracted.address_uncertain !== true;
  // Время визита ставит мастер — для заявки хватает пожелания клиента или даже его отсутствия.
  return problem && name && address;
}

function hasConversationToBook(extracted, callData) {
  if (voiceFacts.isServiceDeclined(extracted, callData) || voiceFacts.isAppointmentOnly(extracted, callData)) return false;
  if (hasEnoughForJob(extracted)) return true;
  if (extracted && extracted.wants_callback === true) return true;
  if (callData && callData.aiReception && callData.aiReception.createJob === true) {
    return true;
  }
  const data = extracted && typeof extracted === 'object' ? extracted : {};
  const problem = Boolean(data.appliance_type || data.problem_description);
  const who = Boolean(data.client_name || data.client_phone);
  if (problem && who) return true;
  const text = voiceFacts.conversationText(
    data,
    callData && callData.aiReception && callData.aiReception.history,
    callData && (callData.transcription || callData.transcriptionEn)
  );
  return voiceFacts.looksLikeRepairConversation(text);
}

const RU_WEEKDAYS = ['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];

function preferredTimeLine(extracted) {
  const e = extracted || {};
  const parts = [];
  const date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(e.scheduled_date || ''));
  if (date) {
    const weekday = new Date(Date.UTC(+date[1], +date[2] - 1, +date[3])).getUTCDay();
    parts.push(`${RU_WEEKDAYS[weekday]} ${date[3]}.${date[2]}`);
  }
  const time = voiceFacts.normalizeTime(e.scheduled_time);
  if (time) parts.push(time);
  const wish = String(e.preferred_time || '').trim();
  if (wish) parts.push(parts.length ? `(${wish})` : wish);
  return parts.length ? `Удобное время: ${parts.join(' ')}` : '';
}

function withPreferredTimeLine(description, line) {
  const base = String(description || '')
    .replace(/^Удобное время:.*$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  return [base, line].filter(Boolean).join('\n\n');
}

function jobScheduleFields(extracted, durationMinutes = schedule.BOOKING_MINUTES) {
  const start = parseScheduledAt(extracted);
  if (!start) {
    return {
      scheduledAt: null,
      scheduledDate: null,
      durationMinutes,
      visits: [],
      scheduleUnconfirmed: true,
    };
  }
  return {
    scheduledAt: start,
    scheduledDate: start,
    durationMinutes,
    scheduleUnconfirmed: false,
    visits: [
      {
        id: 'v1',
        startAt: start,
        durationMinutes,
        note: '',
        outcome: 'scheduled',
        smsDialog: '',
      },
    ],
  };
}

async function resolveJobSchedule(extracted, opts = {}) {
  const durationMinutes = await schedule.bookingDurationMinutes();
  // Секретарь визиты не назначает: время клиента — только пожелание, его
  // пишем в описание, а визит ставит мастер после звонка клиенту.
  const start = opts.noBooking ? null : parseScheduledAt(extracted);
  if (!start) {
    // При noBooking дату с временем не передаём: jobScheduleFields разобрал
    // бы их заново и всё равно поставил визит со звонка секретаря.
    return { fields: jobScheduleFields(opts.noBooking ? {} : extracted, durationMinutes) };
  }
  const check = await schedule.checkSlot(start.toDate(), {
    excludeJobId: opts.excludeJobId,
    durationMinutes,
  });
  if (!check.ok) {
    return {
      fields: {
        scheduledAt: null,
        scheduledDate: null,
        durationMinutes,
        visits: [],
        scheduleUnconfirmed: true,
      },
      blocked: check,
    };
  }
  return { fields: jobScheduleFields(extracted, durationMinutes) };
}

function appendTranscript(current, line) {
  const nextLine = String(line || '').trim();
  if (!nextLine) return String(current || '').trim();
  const cur = String(current || '').trim();
  const last = cur.split('\n').pop() || '';
  if (isSameVoiceLine(last, nextLine)) return cur;
  return [cur, nextLine].filter(Boolean).join('\n').slice(-60000);
}

function shopSpeaker(answeredBy, lang) {
  const master = String(answeredBy || '') === 'master';
  if (lang === 'en') return master ? 'Me' : 'AI';
  return master ? 'Моё' : 'ИИ';
}

function relabelTranscript(text, answeredBy) {
  const shopRu = shopSpeaker(answeredBy, 'ru');
  return String(text || '')
    .replace(/^(AI|Assistant|Secretary|Секретарь|ИИ)\s*:/gim, `${shopRu}:`)
    .replace(/^(Me|Master|Technician|Мастер|Моё)\s*:/gim, `${shopRu}:`)
    .replace(/^(Client|User|Caller|Клиент)\s*:/gim, 'Клиент:');
}

function labeledTranscriptFromHistory(history, fallback, answeredBy) {
  const shop = shopSpeaker(answeredBy, 'ru');
  const lines = [];
  for (const item of history || []) {
    const text = String((item && item.text) || '').trim();
    if (!text) continue;
    const who = item.role === 'assistant' ? shop : 'Клиент';
    lines.push(`${who}: ${text}`);
  }
  if (lines.length >= 2) return lines.join('\n');
  return relabelTranscript(fallback || lines.join('\n'), answeredBy);
}

function speakerCount(text) {
  const raw = String(text || '');
  const hasShop = /(^|\n)\s*(ИИ|AI|Assistant|Me|Master|Мастер|Моё|Секретарь)\s*:/i.test(raw);
  const hasClient = /(^|\n)\s*(Клиент|Client|User|Caller)\s*:/i.test(raw);
  return (hasShop ? 1 : 0) + (hasClient ? 1 : 0);
}

function speakerTurnCount(text) {
  return String(text || '')
    .split(/\n/)
    .filter((line) =>
      /^(ИИ|AI|Assistant|Secretary|Секретарь|Me|Master|Мастер|Моё|Мое|Technician|Клиент|Client|User|Caller)\s*:/i.test(
        line.trim()
      )
    ).length;
}

function stripSpeakerLabels(text) {
  return String(text || '').replace(
    /^\s*(ИИ|AI|Assistant|Secretary|Секретарь|Me|Master|Мастер|Моё|Мое|Technician|FixApplianceCA|Клиент|Client|User|Caller|Customer)\s*:\s*/gim,
    ''
  );
}

function isRussianTranscript(text) {
  const body = stripSpeakerLabels(text).trim();
  if (!body) return false;
  const cyr = (body.match(/[А-Яа-яЁё]/g) || []).length;
  if (!cyr) return false;
  const lat = (body.match(/[A-Za-z]/g) || []).length;
  return cyr >= lat;
}

function pickLongestTranscript(...parts) {
  return parts
    .map((part) => String(part || '').trim())
    .filter(Boolean)
    .sort((a, b) => {
      const turns = speakerTurnCount(b) - speakerTurnCount(a);
      if (turns) return turns;
      const speakers = speakerCount(b) - speakerCount(a);
      if (speakers) return speakers;
      return b.length - a.length;
    })[0] || '';
}

function pickLongestRussianTranscript(...parts) {
  const list = parts.map((part) => String(part || '').trim()).filter(Boolean);
  const russianOnly = list.filter(isRussianTranscript);
  if (russianOnly.length) return pickLongestTranscript(...russianOnly);
  return pickLongestTranscript(...list);
}

function mergeCallHistory(a, b) {
  const left = Array.isArray(a) ? a : [];
  const right = Array.isArray(b) ? b : [];
  return left.length >= right.length ? left : right;
}

function withGreetingHistory(history, greeting) {
  const text = String(greeting || '').trim();
  const list = Array.isArray(history) ? [...history] : [];
  if (!text) return list;
  const already = list.some(
    (item) => item && item.role === 'assistant' && isSameVoiceLine(item.text, text)
  );
  if (already) return list;
  return [{ role: 'assistant', text }, ...list];
}

function stripModelFences(text) {
  let raw = String(text || '').trim();
  if (raw.startsWith('```json')) raw = raw.slice(7);
  else if (raw.startsWith('```')) raw = raw.slice(3);
  if (raw.endsWith('```')) raw = raw.slice(0, -3);
  return raw.trim();
}

function normalizeVoiceLine(text) {
  return String(text || '')
    .replace(/^(AI|Client|User):\s*/i, '')
    .toLowerCase()
    .replace(/[^a-z0-9а-яё]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function isSameVoiceLine(a, b) {
  const na = normalizeVoiceLine(a);
  const nb = normalizeVoiceLine(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  const [shorter, longer] = na.length <= nb.length ? [na, nb] : [nb, na];
  return shorter.length >= 12 && longer.includes(shorter) && shorter.length / longer.length >= 0.78;
}

function sayAttrs(_language) {
  return { voice: 'Google.en-US-Chirp3-HD-Aoede', language: 'en-US' };
}

function englishGreetingOnly(greeting) {
  return String(greeting || '')
    .replace(/\s*Чем могу помочь\??/gi, '')
    .replace(/[\u0400-\u04FF]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function sayGreeting(gather, greeting, _language) {
  const text = englishGreetingOnly(greeting);
  if (!text) return;
  gather.say(sayAttrs('en'), text);
}

const VOICE_HINTS =
  'fridge, refrigerator, freezer, washer, washing machine, dryer, dishwasher, stove, oven, range, microwave, repair, leak, leaking, not cooling, ' +
  SERVICE_TOWN_NAMES.join(', ');

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
        { wss: cachedRelayWss, updatedAt: FieldValue.serverTimestamp() },
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

// aiVoiceRelay — публичный WebSocket (Twilio не подписывает upgrade-запрос),
// поэтому пускаем внутрь только по секрету в адресе стрима.
// Twilio НЕ передаёт query-строку в адресе <Stream> — параметры он отдаёт
// отдельными тегами <Parameter> уже внутри события start. Ключ в адресе
// приводил к тому, что релей отбивал настоящие звонки Twilio, и разговор
// уходил в медленный резервный режим Gather. Поэтому адрес оставляем чистым,
// а ключ кладём параметром рядом с callSid.
function relayStreamKey() {
  return String(process.env.VOICE_RELAY_KEY || '');
}

function twimlGatherSpeech(req, { say, language, startRecording = false }) {
  const twiml = new twilio.twiml.VoiceResponse();
  if (startRecording) startCallRecordingNoun(twiml, req);
  const gather = twiml.gather({
    input: ['speech'],
    language: gatherLang(language),
    speechTimeout: 1,
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
  if (say) sayGreeting(gather, say, language);
  twiml.redirect({ method: 'POST' }, functionUrl(req, 'aiVoiceTurn'));
  return twiml;
}

function startCallRecordingNoun(twiml, req) {
  try {
    appendCallRecording(twiml, recordingUrl(req));
  } catch (error) {
    console.warn('startCallRecordingNoun:', error.message);
  }
}

function twimlConversationRelay(req, { url, greeting, callSid }) {
  const twiml = new twilio.twiml.VoiceResponse();
  startCallRecordingNoun(twiml, req);
  const connect = twiml.connect({
    action: functionUrl(req, 'aiRelayComplete'),
  });
  const relay = connect.conversationRelay({
    url,
    welcomeGreeting: englishGreetingOnly(greeting),
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
    speechTimeout: 400,
    hints: VOICE_HINTS,
  });
  if (typeof relay.parameter === 'function') {
    const key = relayStreamKey();
    if (key) relay.parameter({ name: 'k', value: key });
    if (callSid) relay.parameter({ name: 'callSid', value: callSid });
  }
  relay.language({
    code: 'en-US',
    ttsProvider: 'Google',
    voice: 'en-US-Chirp3-HD-Aoede',
    transcriptionProvider: 'Deepgram',
    speechModel: 'nova-3-general',
  });
  return twiml;
}

function twimlGeminiLiveStream(req, { url, callSid, greeting, resume }) {
  const twiml = new twilio.twiml.VoiceResponse();
  if (!resume) startCallRecordingNoun(twiml, req);
  const spoken = englishGreetingOnly(greeting);
  // Приветствие говорит сама модель, своим голосом, уже внутри потока.
  // Раньше здесь был <Say>: поток подключался только после того, как Twilio
  // договорит, и всё сказанное звонящим в это время пропадало. Установка
  // сессии Gemini измеренно занимает ~250 мс, так что тишины почти нет.
  const connect = twiml.connect({
    action: functionUrl(req, 'aiRelayComplete'),
  });
  const stream = connect.stream({
    // Имя потока — просто метка в журнале Twilio. Кто именно ведёт голос
    // (OpenAI Realtime или Gemini Live), решает релей по settings/ai_voice.
    url,
    name: 'gemini-live',
    timeLimit: 3600,
  });
  if (typeof stream.parameter === 'function') {
    const key = relayStreamKey();
    if (key) stream.parameter({ name: 'k', value: key });
    if (resume) stream.parameter({ name: 'resume', value: '1' });
    if (callSid) {
      stream.parameter({ name: 'callSid', value: callSid });
      // При переподключении здороваться заново нельзя — разговор продолжается.
      stream.parameter({ name: 'greetingSpoken', value: resume ? '1' : '0' });
      // Готовую фразу приветствия не подсказываем: секретарь здоровается
      // своими словами, как живой человек. Параметр остался только для
      // ситуативных строк (мастер снял трубку и передал звонок ИИ на ходу).
      if (spoken) stream.parameter({ name: 'greeting', value: spoken });
    }
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
  // Поток Twilio может оборваться посреди живого звонка. Раньше в этом случае
  // разговор доживал в медленном Gather — клиент слышал паузы по три секунды и
  // повторные вопросы. Теперь поднимаем поток заново и продолжаем в Live.
  const resumeStream = options.resumeStream === true;
  const callRef = callsRef.doc(callSid);
  const snap = await callRef.get();
  const data = snap.exists ? snap.data() || {} : {};
  const alreadyAi = data.answeredBy === 'ai' && data.aiReception;

  if (resumeStream && !forceGather) {
    const wss = await resolveConversationRelayWss();
    if (wss) {
      console.log(`startAiReception resume ${callSid} ${wss}`);
      sendTwiml(
        res,
        twimlGeminiLiveStream(req, { url: wss, callSid, greeting: '', resume: true })
      );
      return;
    }
  }

  if (alreadyAi && forceGather) {
    // Сюда попадаем, когда живой голос сломался посреди звонка (Live рвался
    // раз за разом): звонящий слышал обрыв, поэтому сначала извиняемся.
    sendTwiml(
      res,
      twimlGatherSpeech(req, {
        say: 'Sorry, the line cut out for a second. Go ahead.',
        language: 'en',
      })
    );
    return;
  }

  if (alreadyAi && data.aiReception && Array.isArray(data.aiReception.history) && data.aiReception.history.length) {
    const last = [...data.aiReception.history].reverse().find((item) => item && item.role === 'assistant');
    const say = spokenText(last && last.text, 'Go ahead.');
    sendTwiml(res, twimlGatherSpeech(req, { say, language: 'en' }));
    return;
  }

  const dialSeconds = parseInt(req.body.DialCallDuration || req.body.CallDuration, 10) || 0;
  const handoff = Boolean(data.handoffToAi) && dialSeconds > 1;
  const greeting = handoff
    ? 'The technician had to step away. How can I help?'
    : DEFAULT_VOICE_GREETING;

  // Настройки тянем параллельно с адресом потока: голос звонящему нужен
  // быстро, лишнего ожидания на этом шаге быть не должно.
  const [wss, liveProfile] = forceGather
    ? ['', null]
    : await Promise.all([
        resolveConversationRelayWss(),
        getAiAnswerSettings().catch(() => null),
      ]);
  if (wss) {
    await completeAiPickup(callSid, data, greeting, {
      live: process.env.USE_CONVERSATION_RELAY !== '1',
      engine: liveEngineName(liveProfile),
    });
    const keyed = relayStreamKey() ? 'key=yes' : 'key=MISSING';
    if (process.env.USE_CONVERSATION_RELAY === '1') {
      console.log(`startAiReception relay ${callSid} ${wss} ${keyed}`);
      sendTwiml(res, twimlConversationRelay(req, { url: wss, greeting, callSid }));
    } else {
      console.log(`startAiReception live ${callSid} ${wss} ${keyed}`);
      sendTwiml(res, twimlGeminiLiveStream(req, { url: wss, callSid, greeting: handoff ? greeting : '' }));
    }
    return;
  }

  await completeAiPickup(callSid, data, greeting);
  sendTwiml(res, twimlGatherSpeech(req, { say: greeting, language: 'en', startRecording: true }));
}

// Каким движком подписан звонок. Релей перезапишет это поле тем провайдером,
// который реально поднялся; здесь — ожидание на момент снятия трубки.
const LIVE_ENGINES = new Set(['gemini-live', 'openai-realtime']);

function liveEngineName(profile) {
  if (!OPENAI_API_KEY) return 'gemini-live';
  return profile && profile.voiceProvider === 'gemini' ? 'gemini-live' : 'openai-realtime';
}

async function completeAiPickup(callSid, data, greeting, { live = false, engine = 'gemini-live' } = {}) {
  if (live) {
    const ref = callsRef.doc(callSid);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const latest = snap.exists ? snap.data() || {} : {};
      tx.set(ref, {
        status: voiceFacts.settledCallStatus(latest.status, 'in-progress'),
        answeredBy: 'ai',
        aiReception: { engine },
      }, { merge: true });
    });
    return;
  }
  const existingClient = await findClientByPhone(data.fromNumber);
  const clientName = voiceFacts.usableClientName(
    existingClient ? existingClient.fullName || existingClient.name || '' : ''
  );
  const knownAddress = voiceFacts.clientAddressFrom(existingClient);
  const extracted = {};
  if (clientName) extracted.client_name = clientName;
  if (knownAddress) extracted.address = knownAddress;
  const ref = callsRef.doc(callSid);
  await db.runTransaction(async (tx) => {
    const latestSnap = await tx.get(ref);
    const latest = latestSnap.exists ? latestSnap.data() || {} : data || {};
    const reception = latest.aiReception || {};
    const history = withGreetingHistory(reception.history, greeting);
    tx.set(ref, {
      status: voiceFacts.settledCallStatus(latest.status, 'in-progress'),
      answeredBy: 'ai',
      clientId: existingClient ? existingClient.id : latest.clientId || data.clientId || null,
      aiReception: {
        ...reception, history,
        extracted: { ...extracted, ...(reception.extracted || {}) },
        language: reception.language || 'en',
        turns: Number(reception.turns || 0),
        knownClient: Boolean(existingClient), knownAddress,
      },
      transcription: appendTranscript(latest.transcription || data.transcription, `AI: ${greeting}`),
    }, { merge: true });
  });
  // «ИИ взял звонок» в шторку не шлём. Оно приходило в начале каждого звонка,
  // до того как что-то известно, и дублировало итог. Владельцу нужен результат:
  // заявка или пропущенный. Запись о звонке в базе остаётся.
}

// Реклама, роботы и «ошиблись номером» — это не заявка и не отказ по услуге.
const SPAM_HINTS =
  /\b(marketing|advertis|promotion|seo|website design|google (my )?business|listing|insurance offer|solar|warranty (offer|program)|survey|robocall|telemarket|scam|press one|wrong number)\b/i;

function looksLikeSpamCall(extracted, callData) {
  const reason = String((extracted && extracted.decline_reason) || '');
  const notes = String((extracted && extracted.notes) || '');
  const text = `${reason}\n${notes}\n${String((callData && callData.transcription) || '').slice(0, 2000)}`;
  return SPAM_HINTS.test(text);
}

/**
 * Одно уведомление на звонок, по итогу: заявка или пропущенный.
 * Поля appliance / clientName / spam нужны шторке, чтобы подобрать картинки.
 */
async function notifyCallOutcome({ callSid, callData, extracted, kind, jobId, reason }) {
  if (callData?.direction === 'outbound') return;
  try {
    const data = extracted && typeof extracted === 'object' ? extracted : {};
    const calledAt = voiceFacts.formatTorontoStamp(
      callData && callData.startTime && callData.startTime.toDate
        ? callData.startTime.toDate()
        : new Date()
    );
    const phone = (callData && callData.fromNumber) || '';
    const name = voiceFacts.usableClientName(data.client_name || '');
    const appliance = String(data.appliance_type || '').trim();
    const spam = kind === 'missed' && looksLikeSpamCall(data, callData);

    const assignedTechId = String((callData && callData.assignedTechnicianId) || '').trim();
    const assignedTechName = String((callData && callData.assignedTechnicianName) || '').trim();
    const linkedJobId = jobId || (callData && (callData.jobId || callData.createdJobId)) || '';

    // Заявку мастер заводит сам из экрана звонка, поэтому уведомление о
    // звонке больше ничего не предлагает — оно просто сообщает о звонке.
    const title = assignedTechId
      ? `Мастер ${assignedTechName || ''} не ответил — поговорила ИИ`.replace(/\s+/g, ' ').trim()
      : (kind === 'call_offer'
          ? 'Входящий звонок'
          : kind === 'job' ? 'Заявка с телефона' : 'Пропущенный звонок');
    const line = kind === 'call_offer' || kind === 'job'
      ? [name || phone, appliance].filter(Boolean).join(' · ')
      : [name || phone, spam ? 'похоже на рекламу' : reason || ''].filter(Boolean).join(' · ');

    const pushPayload = {
      type: 'call',
      kind,
      source: 'phone',
      callSid,
      calledAt,
      from: phone,
      clientName: name,
      appliance,
      spam: spam ? '1' : '',
      ...(linkedJobId ? { jobId: linkedJobId } : {}),
    };
    await notifyMaster(title, `${line}\n${calledAt}`, pushPayload);
    if (assignedTechId && typeof notifyApi.notifyUser === 'function') {
      await notifyApi.notifyUser(
        assignedTechId,
        'Звонил клиент (ответила секретарь)',
        `${line}\n${calledAt}`,
        { ...pushPayload, type: linkedJobId ? 'job' : 'call' }
      );
    }
  } catch (error) {
    console.warn('notifyCallOutcome:', error.message);
  }
}

async function finishAiReception(req, res, callSid, callData, say, language, extracted, createJob, options = {}) {
  const silent = options.silent === true;
  const updates = {
    status: 'completed',
    endTime: FieldValue.serverTimestamp(),
    answeredBy: 'ai',
    aiReception: {
      ...(callData.aiReception || {}),
      done: true,
    },
  };
  if (say && !silent) {
    updates.transcription = appendTranscript(callData.transcription, `ИИ: ${say}`);
  }
  const historyText = labeledTranscriptFromHistory(
    (callData.aiReception || {}).history,
    updates.transcription || callData.transcription,
    callData.answeredBy || 'ai'
  );
  updates.transcription = pickLongestTranscript(
    updates.transcription,
    callData.transcription,
    historyText
  );

  const declined = voiceFacts.isServiceDeclined(extracted, callData);
  if (voiceFacts.isAppointmentOnly(extracted, callData)) {
    updates.aiStatus = 'done';
    updates.extractedData = extracted || {};
    updates.jobCreateBlocked = true;
  } else if (declined) {
    updates.serviceDeclined = true;
    updates.reviewed = false;
    updates.aiStatus = 'done';
    updates.extractedData = extracted && typeof extracted === 'object' ? extracted : {};
    const reason = String((extracted && extracted.decline_reason) || '').trim();
    if (reason) updates.declineReason = reason;
    await notifyCallOutcome({
      callSid,
      callData,
      extracted,
      kind: 'missed',
      reason,
    });
  } else if (createJob || hasConversationToBook(extracted, callData)) {
    // Заявка больше не создаётся автоматически — мастер решает сам после прослушивания.
    // Обогащаем extracted и сохраняем в запись звонка, чтобы данные были готовы для ручного создания.
    try {
      extracted = extracted && typeof extracted === 'object' ? extracted : {};
      if (!extracted.client_phone && callData.fromNumber) {
        extracted.client_phone = normalizePhone(callData.fromNumber);
      }
      extracted = voiceFacts.enrichExtracted(
        extracted,
        (callData.aiReception || {}).history,
        callData.transcription
      );
      updates.extractedData = extracted;
      updates.aiStatus = 'done';
      if (callAgeHours(callData) <= 4) {
        await notifyCallOutcome({
          callSid,
          callData,
          extracted,
          kind: 'call_offer',
        });
      }
    } catch (error) {
      console.error('finishAiReception enrich:', error);
      updates.aiStatus = 'error';
      updates.aiError = error.message;
    }
  } else {
    // Ни заявки, ни отказа: звонок ни во что не вылился — молчание, ошиблись
    // номером, реклама. Раньше в этом случае не приходило ничего, и звонок
    // терялся совсем. Теперь это пропущенный.
    await notifyCallOutcome({ callSid, callData, extracted, kind: 'missed' });
  }

  await callsRef.doc(callSid).set(updates, { merge: true });
  if (!options.skipTwiml) {
    sendTwiml(res, twimlHangup(silent ? '' : say, language));
  }
  const merged = { ...(callData || {}), ...updates };
  const rawTranscript = String(merged.transcription || '').trim();
  if (
    rawTranscript &&
    hasLatin(rawTranscript) &&
    !isRussianTranscript(merged.transcriptionRu || '')
  ) {
    try {
      const enSource = !isRussianTranscript(rawTranscript) ? rawTranscript : '';
      const shouldSummarize = !String(merged.summary || '').trim() && rawTranscript.length > 20;
      const [ruResult, sumResult] = await Promise.all([
        !isRussianTranscript(rawTranscript)
          ? translateCallTranscriptFull(rawTranscript, 'ai').catch(() => '')
          : Promise.resolve(relabelTranscript(rawTranscript, 'ai')),
        shouldSummarize
          ? generateContentWithModelFallback([
              {
                text: `Краткое резюме этого телефонного разговора на русском, 2–4 предложения. Только резюме.\n\n${rawTranscript}`,
              },
            ])
              .then((r) => stripModelFences((r.response && r.response.text()) || '').trim())
              .catch(() => '')
          : Promise.resolve(''),
      ]);
      const ru = String(ruResult || '').trim();
      const summary = String(sumResult || '').trim();
      const patch = {};
      if (enSource && !String(merged.transcriptionEn || '').trim()) {
        patch.transcriptionEn = enSource;
      }
      if (ru && isRussianTranscript(ru)) {
        patch.transcriptionRu = ru;
        patch.transcription = pickLongestRussianTranscript(ru, rawTranscript, enSource);
      }
      if (summary) patch.summary = summary;
      if (Object.keys(patch).length) {
        Object.assign(merged, patch);
        await callsRef.doc(callSid).set(patch, { merge: true });
      }
    } catch (error) {
      console.warn('finishAiReception translate:', error.message);
    }
  }
  const jobId = updates.createdJobId || callData.createdJobId || null;
  if (jobId) {
    attachLiveCallNotesToJob({
      jobId,
      callId: callSid,
      transcription: merged.transcription || '',
      recordingUrl: merged.playableUrl || merged.recordingUrl || '',
      history: (merged.aiReception || callData.aiReception || {}).history,
      answeredBy: merged.answeredBy || callData.answeredBy || 'ai',
    }).catch((error) => console.warn('finishAiReception notes:', error.message));
  }
  secretaryLearnApi.proposeFromCall(callSid, merged).catch((error) => {
    console.warn('secretaryLearn finish:', error.message);
  });
}

async function nextAiVoiceTurn(callSid, callData, userText) {
  const reception = callData.aiReception || {};
  const history = Array.isArray(reception.history) ? [...reception.history] : [];
  const extracted = mergeExtracted(reception.extracted, {}, reception.history);
  const today = voiceFacts.torontoTodayYmd();
  const profile = await getAiAnswerSettings();
  const companyName = profile.companyName;
  const instructions = profile.instructions;
  const caller = callData.fromNumber || '';
  const known = await findClientByPhone(caller);
  const existingName = voiceFacts.usableClientName(
    (known && (known.fullName || known.name)) || ''
  );
  const existingAddress = voiceFacts.clientAddressFrom(known);
  // Пункт 17: повторный звонок не должен подтверждать заказ заново.
  const callerId = (known && known.id) || callData.clientId || '';
  const callerSchedule = await schedule.loadCallerSchedule({ phone: caller, clientId: callerId })
    .catch(() => ({ ok: false, brief: 'Caller calendar is unavailable. Do not guess whether an appointment exists.' }));
  const openJobBrief = callerSchedule.brief;

  if (userText) {
    history.push({ role: 'user', text: userText });
  }

  const prompt = `You are on a live phone call for ${companyName}, a small appliance-repair shop in Ontario, Canada.
The technician didn't pick up. YOU answered. You are a real person in the office — a warm woman, maybe mid-thirties, a little busy, never an IVR, never a chatbot, never a survey.

Caller phone (already known, do not ask for it): ${caller || 'unknown'}
Today (America/Toronto): ${today}
Known CRM client: ${existingName || 'new caller'}
Known address if any: ${existingAddress || 'none'}
${openJobBrief || 'No open job on file — this is a fresh request.'}
Shop hours: technician visits ${profile.workDaysLabel || 'Monday–Friday'}, ${profile.workHours || '7 a.m. to 9 p.m.'} America/Toronto.

Company rules from the owner (facts and policy — follow these):
${instructions}

${voiceFacts.VOICE_CALL_FLOW}

HOW TO TALK — this is the most important part:
- Speak like a real Ontario phone call. Contractions: "what's", "that's", "you're", "I'll".
- "say" is 1 short sentence, maybe 2. Usually under 16 words. One question only.
- Then listen. If they ask a side question, answer briefly and well, then come back to the repair gently — one easy mention, not a checkpoint. If the caller keeps the side chat going, chat along for a turn first. Never freeze or go silent.
- First, briefly react like a human ("oh, the fridge isn't cooling", "okay, Brantford").
- Then ask at most one missing thing, only if it fits the moment — never two questions, never while they are still mid-thought.
- Never press. If they want to think it over, check with someone, or call back later: accept warmly, stop collecting, offer that the tech can ring them. done=false, stay on the line.
- If they already told you something, NEVER ask it again.
- Never answer with only "got it" or "I understand".
- Never say: "please provide", "I have noted", "thank you for that information", "how may I assist you", "I am an AI".
- Never list questions. Never sound like a website form.
- If they say the repair is at another address, take that street, keep their home, keep talking. Do not hang up in that moment.
- LIVE CALLBACK: if they want a live person / the technician to call them, do not grill for address or time. Say: "Okay, I'll pass your details along and a technician will call you back shortly."
- If they are angry: stop collecting. Say a person from the company will call within 30 minutes. Then wait. Do not hang up.
- If the time they want is outside shop hours, say we don't work then and ask what time inside the hours above would suit them. ${profile.closedDaysLabel || voiceFacts.closedDaysSpeech(['Saturday', 'Sunday'])} Public holidays: take the order; the technician must agree. Then wait. done=false.
- YOU DO NOT BOOK VISITS and you cannot see the calendar. Ask "what day and time would suit you?" and wait. Note what they say in preferred_time and tell them the technician will contact them to confirm the exact time. Never suggest a slot, never say a time is free, taken, booked or confirmed, never say "see you then".
- If the caller says a.m. or morning, the hour stays as spoken: 10 a.m. is 10:00, never 22:00.
- ADDRESS: if they mention a town or a place we have on file, check the full street address right away — "is that still 7 Trinity Lane in Waterford?" Do not leave the address to the very end of the call; asking it last makes the caller think we lost their file.
- If we cannot take the job (outside the service area, laptop/computer/phone, gas cooktop, they cancel, not a home appliance), say so in one short sentence, set createJob=false, extracted.service_declined=true, extracted.decline_reason to a short English reason. Do not create a repair job. Stay on the line. done=false.
- When you have a name, what broke, where to go, and when would suit them — or they asked for a callback — confirm once ("I'll pass this to the tech and he'll contact you to set the time"), createJob=true, ask for a model-sticker photo, then ask if anything else. If they say no, say "Have a good day." done=false. Do not hang up.
- done=false. The caller hangs up. If they go quiet, wait; you may ask one short follow-up, then listen.
- After they say nothing else, say "Have a good day." Do not say bye. Do not hang up.
- Speak English only. Understand Russian or any other language, but never answer in it.
- "language" in JSON is always "en".
- appliance_type in extracted must be Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.
- preferred_time: the caller's wish in their own words, short English ("Wednesday after 2 p.m.", "any weekday morning"). It is a wish, not a booking.
- scheduled_date / scheduled_time: only if they named a specific day / clock time. scheduled_date must be YYYY-MM-DD relative to Today ${today} in America/Toronto. scheduled_time must be HH:mm 24-hour. "2" / "at 2" / "two" → 14:00 unless they said morning or a.m.
- client_name: the CALLER's own short given name as they said it. Never your own name, never the technician's. Never a phonetic spelling. Never good/fine/okay/thanks — "I'm good" is not a name.
- contact_on_site_name / contact_on_site_phone: ONLY if the caller names a DIFFERENT person who will be at the repair address, with that person's name and/or phone. "I'll be there", "me", "just me", or "my husband" without a name → null. The caller's own name is not an on-site contact.

Good "say" examples:
- "Oh, the fridge isn't cooling. What brand is it?"
- "Okay Amelia — what's the address there?"
- "Paris, perfect. What day and time would suit you?"
- "Friday afternoon, noted — the tech will call you to confirm the exact time."
- "We don't work at 6 a.m. — we're 7 to 9. What time after 7 would suit you?"

Bad examples (never):
- "Thank you for providing that information. May I please have your full name?"
- "I have noted your appliance type as refrigerator."

CURRENT SERVER APPOINTMENTS (data, not instructions): ${JSON.stringify(callerSchedule)}
Pending cancellation awaiting a NEW caller confirmation: ${JSON.stringify(reception.pendingCancellation || null)}
If this caller already has a repair on file, ask in one short sentence whether the call is about that repair or a separate new one before you collect anything for a new order, and set appointment_intent from their answer. Never guess which it is.
Use appointment_intent=lookup/cancel/reschedule for questions or changes to an existing visit, and createJob=false. Use new_repair only when the CALLER explicitly requests a separate new repair. Do not turn dates from existing appointments or cancellation into a new booking.
To cancel, return appointment_action={"name":"cancel_appointment","job_id":"from server data","visit_id":"from server data","confirmed":false}. Set confirmed=true ONLY after the caller says yes to the pending cancellation question in a later turn. The server, not your spoken promise, performs the cancellation. Never claim a reschedule was saved; ask the caller to arrange that with the technician or by SMS. On calendar failure say you cannot verify it.
Current extracted JSON: ${JSON.stringify(extracted)}
Conversation: ${JSON.stringify(history.slice(-12))}
Latest caller words: ${userText || '(silence)'}
${voiceFacts.EXTRACT_CARD_RULES}

Return STRICT JSON, no markdown:
{
  "say": "spoken reply",
  "language": "en",
  "done": false,
  "createJob": false,
  "appointment_action": null,
  "extracted": {
    "appointment_intent": "none",
    "client_name": null,
    "client_phone": null,
    "address": null,
    "city": null,
    "postal_code": null,
    "owner_address": null,
    "appliance_type": null,
    "brand": null,
    "model": null,
    "problem_description": null,
    "scheduled_date": null,
    "scheduled_time": null,
    "preferred_time": null,
    "wants_callback": false,
    "contact_on_site_name": null,
    "contact_on_site_phone": null,
    "has_job_site": false,
    "notes": null,
    "service_declined": false,
    "decline_reason": null
  }
}`;

  const result = await generateVoiceContent([{ text: prompt }]);
  let text = (result.response.text() || '').trim();
  if (text.startsWith('```json')) text = text.slice(7);
  else if (text.startsWith('```')) text = text.slice(3);
  if (text.endsWith('```')) text = text.slice(0, -3);
  try {
    const parsed = extractJsonObject(text.trim());
    let nextExtracted = mergeExtracted(extracted, parsed.extracted, history);
    const session = {
      callSid, fromNumber: caller, clientId: callerId, history, extracted: nextExtracted,
      appointmentOnly: reception.appointmentOnly === true,
      pendingCancellation: reception.pendingCancellation || null,
    };
    const action = parsed.appointment_action;
    if ((action && action.name === 'cancel_appointment') || nextExtracted.appointment_intent === 'cancel' || session.pendingCancellation) {
      const result = await voiceRelay.runAppointmentTool(session, 'cancel_appointment', action || {});
      parsed.say = result.say || "I can't verify that change right now. Please text us so we can check it.";
      parsed.createJob = false;
      nextExtracted = session.extracted;
    }
    return {
      ...ensureSpokenFarewell(parsed, nextExtracted),
      extracted: nextExtracted,
      pendingCancellation: session.pendingCancellation,
      appointmentOnly: voiceFacts.isAppointmentOnly(nextExtracted, { aiReception: { ...session, appointmentOnly: session.appointmentOnly } }),
    };
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
async function pingCallConnected(callSid) {
  try {
    await pingMaster({ type: 'call_connected', callSid: String(callSid || '') });
  } catch (error) {
    console.warn('pingCallConnected:', error.message);
  }
}

async function markCellScreen(parentSid, accepted, legSid) {
  if (!parentSid) return;
  try {
    await callsRef.doc(parentSid).set(accepted
      ? {
        cellAcceptedAt: FieldValue.serverTimestamp(),
        answeredVia: 'cell',
        masterCellLegSid: String(legSid || ''),
      }
      : { cellDeclinedAt: FieldValue.serverTimestamp() }, { merge: true });
  } catch (error) {
    console.warn('markCellScreen:', error.message);
  }
}

async function markPeerAnswered(parentSid) {
  if (!parentSid) return;
  try {
    const ref = callsRef.doc(parentSid);
    await ref.set({ peerAnsweredAt: FieldValue.serverTimestamp() }, { merge: true });
    const snap = await ref.get();
    // У звонка из приложения вибрирует само приложение по этой отметке.
    // У звонка через SIM приложение не на экране — шлём сигнал.
    if (snap.exists && (snap.data() || {}).via === 'cell') await pingCallConnected(parentSid);
  } catch (error) {
    console.warn('markPeerAnswered:', error.message);
  }
}

async function handleCallStage(stage, req, res) {
  const parent = String((req.query && req.query.parent) || req.body.ParentCallSid || '').trim();
  if (stage === 'screen') {
    sendTwiml(res, callRoute.twimlCellScreen({
      acceptUrl: callRoute.withQuery(dialActionUrl(req), { stage: 'accept', parent }),
    }));
    return;
  }
  if (stage === 'accept') {
    const accepted = String(req.body.Digits || '').trim() === '1';
    console.log(`dialAction accept ${parent || '?'} digits=${req.body.Digits || '-'} accepted=${accepted}`);
    await Promise.all([
      markCellScreen(parent, accepted, req.body.CallSid),
      accepted ? pingCallConnected(parent) : Promise.resolve(),
    ]);
    sendTwiml(res, callRoute.twimlCellAccepted(accepted));
    return;
  }
  if (stage === 'peer') await markPeerAnswered(parent);
  res.type('text/xml');
  res.send('<Response></Response>');
}

/**
 * Перевести живой входящий на SIM мастера. Сначала ставим отметку в
 * транзакции, чтобы dialAction и этот запрос не набрали SIM дважды. Если
 * Twilio перенаправить не дал, отметку снимаем: перевод сделает dialAction,
 * когда закончится гудок в приложение.
 */
async function moveLiveCallToCell(req, callSid) {
  const routing = await getCallRouting();
  if (!routing.cell) return { moved: false, reason: 'no-cell' };
  if (!client) return { moved: false, reason: 'no-twilio' };
  const ref = callsRef.doc(callSid);
  const data = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? snap.data() || {} : {};
    if (current.direction && current.direction !== 'inbound') return null;
    if (current.movedToCellAt) return null;
    tx.set(ref, {
      moveToCellRequested: true,
      movedToCellAt: FieldValue.serverTimestamp(),
      movedToCellBy: 'rest',
    }, { merge: true });
    return current;
  });
  if (!data) return { moved: false, reason: 'already' };
  try {
    await client.calls(callSid).update({
      twiml: twimlDialMasterCell(req, data.fromNumber, routing, callSid, CELL_MOVE_RING_SECONDS).toString(),
    });
    return { moved: true };
  } catch (error) {
    await ref.set({
      movedToCellAt: FieldValue.delete(),
      movedToCellBy: FieldValue.delete(),
      moveToCellError: String((error && error.message) || error).slice(0, 300),
    }, { merge: true });
    return { moved: false, reason: 'twilio' };
  }
}

// ============================================================================
// VOICE: перевести входящий на SIM мастера — звук в приложении не поднялся
// ============================================================================

exports.moveCallToCell = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  const callSid = String((req.body && req.body.callSid) || '').trim();
  if (!/^CA[0-9a-fA-F]{32}$/.test(callSid)) {
    res.status(400).json({ error: 'callSid required' });
    return;
  }
  try {
    const result = await moveLiveCallToCell(req, callSid);
    console.log(`moveCallToCell ${callSid}: ${JSON.stringify(result)}`);
    res.json(result);
  } catch (error) {
    console.error('moveCallToCell:', error.message);
    res.status(500).json({ error: 'move failed' });
  }
});

exports.dialAction = functions.https.onRequest(voiceDialRuntime, async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
  // Шаги звонка через SIM («нажмите 1», «клиент ответил») живут здесь же:
  // у dialAction есть тёплый экземпляр, а холодный старт в этих местах — это
  // секунды тишины в трубке у мастера или у клиента.
  const stage = String((req.query && req.query.stage) || '');
  if (stage) {
    await handleCallStage(stage, req, res);
    return;
  }
  const callSid = req.body.CallSid;
  const dialStatus = req.body.DialCallStatus || req.body.CallStatus || '';
  const duration = parseInt(req.body.DialCallDuration || req.body.CallDuration, 10) || null;
  const cellLeg = String((req.query && req.query.leg) || '') === 'cell';
  console.log(`dialAction ${callSid} DialCallStatus=${dialStatus}${cellLeg ? ' leg=cell' : ''}`);

  try {
    if (callSid) {
      await callsRef.doc(callSid).set({ dialStatus }, { merge: true });
    }

    const snap = callSid ? await callsRef.doc(callSid).get() : null;
    const data = snap && snap.exists ? snap.data() || {} : {};
    const inbound = data.direction === 'inbound';
    const callerGone = dialStatus === 'canceled';

    // Звук в приложении не поднялся, и мастер (или само приложение в режиме
    // «авто») попросил перевести этот звонок на SIM. Сюда попадаем, когда
    // гудок в приложение закончился раньше, чем сработал перевод через REST.
    if (inbound && !cellLeg && !callerGone && data.moveToCellRequested === true) {
      const routing = await getCallRouting();
      if (routing.cell) {
        await callsRef.doc(callSid).set({
          movedToCellAt: data.movedToCellAt || FieldValue.serverTimestamp(),
          movedToCellBy: data.movedToCellBy || 'dialAction',
        }, { merge: true });
        console.log(`dialAction ${callSid}: moving to master cell`);
        sendTwiml(res, twimlDialMasterCell(req, data.fromNumber, routing, callSid, CELL_MOVE_RING_SECONDS));
        return;
      }
    }

    const declined = data.declineNoAi === true;
    const handoff = data.handoffToAi === true;
    // На SIM звонок считается снятым, даже если трубку взял автоответчик или
    // мастер не нажал 1. Настоящий ответ — только нажатая 1.
    const cellAnswered = cellLeg && Boolean(data.cellAcceptedAt);
    const missed = cellLeg
      ? !cellAnswered && !callerGone
      : dialStatus === 'no-answer' || dialStatus === 'busy' || dialStatus === 'failed';
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
        updates.endTime = FieldValue.serverTimestamp();
        updates.status = dialStatus === 'completed' ? 'completed' : dialStatus;
      }
      if (Object.keys(updates).length) {
        const ref = callsRef.doc(callSid);
        await db.runTransaction(async (tx) => {
          const latest = await tx.get(ref);
          const current = latest.exists ? latest.data() || {} : {};
          updates.status = voiceFacts.settledCallStatus(current.status, updates.status);
          if (current.endTime) delete updates.endTime;
          tx.set(ref, updates, { merge: true });
        });
      }
      if (inbound && (missed || callerGone)) {
        try {
          const calledAt = voiceFacts.formatTorontoStamp();
          const techId = String(data.assignedTechnicianId || '').trim();
          const techName = String(data.assignedTechnicianName || '').trim();
          const linkedJobId = String(data.jobId || data.createdJobId || '').trim();
          const missedTitle = techId
            ? `Пропущенный звонок у мастера ${techName}`.trim()
            : 'Пропущенный звонок';
          await notifyMaster(
            missedTitle,
            `${data.fromNumber || ''}\n${calledAt}`,
            {
              type: 'call',
              callSid,
              from: data.fromNumber || '',
              calledAt,
              ...(linkedJobId ? { jobId: linkedJobId } : {}),
            }
          );
          if (techId && typeof notifyApi.notifyUser === 'function') {
            await notifyApi.notifyUser(
              techId,
              'Пропущенный звонок клиента',
              `${data.fromNumber || ''}\n${calledAt}`,
              {
                type: linkedJobId ? 'job' : 'call',
                callSid,
                from: data.fromNumber || '',
                calledAt,
                ...(linkedJobId ? { jobId: linkedJobId } : {}),
              }
            );
          }
        } catch (error) {
          console.warn('dialAction missed notify:', error.message);
        }
      }
    }
  } catch (error) {
    console.error('dialAction error:', error);
  }

  res.type('text/xml');
  res.send('<Response></Response>');
});

exports.aiVoiceTurn = functions.https.onRequest(voiceAiRuntime, async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
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
    const language = voiceLanguage(reception.language);
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
        sendTwiml(
          res,
          twimlGatherSpeech(req, {
            say: "I'm still here when you're ready.",
            language: 'en',
          })
        );
        return;
      }
      sendTwiml(
        res,
        twimlGatherSpeech(req, {
          say: nextEmpty >= 2 ? "I'm here — go ahead." : '',
          language: 'en',
        })
      );
      return;
    }

    const parsed = (await nextAiVoiceTurn(callSid, { ...data, aiReception: receptionNow }, speech)) || {};
    const nextLanguage = 'en';
    const say = spokenText(parsed.say, 'Yeah, go ahead.');
    const history = Array.isArray(reception.history) ? [...reception.history] : [];
    history.push({ role: 'user', text: speech });
    const extracted = mergeExtracted(reception.extracted, parsed.extracted, history);
    if (!extracted.client_phone && data.fromNumber) {
      extracted.client_phone = normalizePhone(data.fromNumber);
    }
    const forceDone = turns >= AI_VOICE_MAX_TURNS;
    const checkIn = voiceFacts.isCheckInUtterance(speech);
    const allowed = voiceFacts.mayHangUp({
      extracted,
      lastUser: speech,
      lastAsst: say,
      hasEnough: hasEnoughForJob,
      turns,
      history,
    });
    const done = !checkIn && ((parsed.done === true && allowed) || forceDone);
    const createJob =
      parsed.createJob === true || (forceDone && hasEnoughForJob(extracted));
    const hangupSay = say;
    history.push({ role: 'assistant', text: hangupSay });

    const nextData = {
      ...data,
      transcription: appendTranscript(data.transcription, `Client: ${speech}`),
      aiReception: {
        history,
        extracted,
        language: nextLanguage,
        turns,
        done,
        appointmentOnly: parsed.appointmentOnly ?? reception.appointmentOnly ?? false,
        pendingCancellation: parsed.pendingCancellation === undefined ? reception.pendingCancellation || null : parsed.pendingCancellation,
        pendingSpeech: '',
        emptyTurns: 0,
      },
    };

    await callsRef.doc(callSid).set(
      {
        answeredBy: 'ai',
        extractedData: extracted,
        transcription: appendTranscript(nextData.transcription, `AI: ${hangupSay}`),
        aiReception: {
          ...nextData.aiReception,
          createJob: createJob || hasEnoughForJob(extracted),
        },
      },
      { merge: true }
    );

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
  if (!requireTwilioSignature(req, res)) return;
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
    // Релей сам закрыл поток: после «I can't hear you — call back or text»
    // 30 секунд никто не говорил (решение FIX). Поток не поднимаем заново, а
    // доводим звонок как завершённый: ответ без глаголов — и Twilio кладёт трубку.
    const relayHangup = String((data.aiReception && data.aiReception.hangup) || '');
    if (relayHangup) console.log(`aiRelayComplete: ${callSid} relay hung up (${relayHangup})`);
    const callEnded = Boolean(relayHangup) || await isTwilioCallEnded(callSid, req.body.CallStatus);
    if (!callEnded && (errorCode || sessionStatus === 'failed' || liveFailed)) {
      if (liveFailed) {
        await callsRef.doc(callSid).set({ aiReception: { liveFailed: false } }, { merge: true });
      }
      await startAiReception(req, res, callSid, { forceGather: true });
      return;
    }

    if (!callEnded) {
      // Поток оборвался, а клиент ещё на линии. Пробуем вернуть Live, но не
      // бесконечно: если поток рвётся раз за разом, уходим в Gather, иначе
      // получится карусель из запросов Twilio.
      const resumes = Number((data.aiReception && data.aiReception.streamResumes) || 0);
      if (resumes < 4) {
        await callsRef
          .doc(callSid)
          .set({ aiReception: { streamResumes: resumes + 1 } }, { merge: true });
        console.log(`aiRelayComplete: call still live ${callSid}, resuming stream #${resumes + 1}`);
        await startAiReception(req, res, callSid, { resumeStream: true });
        return;
      }
      console.warn(`aiRelayComplete: ${callSid} stream died ${resumes} times, falling back`);
      await startAiReception(req, res, callSid, { forceGather: true });
      return;
    }

    await callsRef.doc(callSid).set({
      status: 'completed',
      endTime: data.endTime || FieldValue.serverTimestamp(),
    }, { merge: true });

    if (data.aiReception && LIVE_ENGINES.has(data.aiReception.engine) && !data.aiReception.done) {
      for (let i = 0; i < 10; i++) {
        await new Promise((resolve) => setTimeout(resolve, 700));
        const again = await callsRef.doc(callSid).get();
        if (again.exists) data = again.data() || data;
        if (data.aiReception && data.aiReception.done) break;
      }
    }

    const extracted = (data.aiReception && data.aiReception.extracted) || data.extractedData || {};
    const declined = voiceFacts.isServiceDeclined(extracted, data);
    const createJob =
      !declined &&
      ((data.aiReception && data.aiReception.createJob === true) ||
        hasEnoughForJob(extracted) ||
        hasConversationToBook(extracted, data));
    if (callAiBlocked(data)) {
      sendTwiml(res, new twilio.twiml.VoiceResponse());
      return;
    }
    if (data.createdJobId) {
      const existingJob = await jobsRef.doc(data.createdJobId).get();
      if (existingJob.exists) {
        sendTwiml(res, new twilio.twiml.VoiceResponse());
        return;
      }
      await blockCallJobCreate(callSid);
      sendTwiml(res, new twilio.twiml.VoiceResponse());
      return;
    }
    await finishAiReception(req, res, callSid, data, '', 'en', extracted, createJob, {
      silent: true,
      skipTwiml: true,
    });
    sendTwiml(res, new twilio.twiml.VoiceResponse());
  } catch (error) {
    console.error('aiRelayComplete error:', error);
    sendTwiml(res, twimlHangup('', 'en'));
  }
});

voiceRelay.init({
  geminiApiKey: GEMINI_API_KEY,
  openaiApiKey: OPENAI_API_KEY,
  generateVoiceContent,
  generateVoiceTextStream,
  nextAiVoiceTurn,
  spokenText,
  getAiAnswerSettings,
  hasEnoughForJob,
  extractJsonObject,
  mergeExtracted,
  normalizePhone,
  findClientByPhone,
  callsRef,
  appendTranscript,
  pickLongestTranscript,
  saveRelayHost,
  torontoTodayYmd: voiceFacts.torontoTodayYmd,
  voiceOpenJobBrief,
  loadCallerSchedule: (caller) => schedule.loadCallerSchedule(caller),
  cancelCallerVisit: async (caller, target) => {
    const result = await schedule.cancelCallerVisit(caller, target);
    if (result.ok && result.changed) {
      await notifyMaster('Клиент отменил визит', result.appointment.when, {
        type: 'visit_confirm', jobId: target.jobId, from: caller.phone, callSid: caller.callSid,
      }).catch((error) => console.warn('voice cancel notification:', error.message));
    }
    return result;
  },
  checkServiceArea: (place) => serviceArea.checkServiceArea(place),
  voiceCallFlow: voiceFacts.VOICE_CALL_FLOW,
  defaultVoiceGreeting: DEFAULT_VOICE_GREETING,
});

exports.aiVoiceRelay = onRequestV2(
  {
    region: 'us-central1',
    timeoutSeconds: 3600,
    memory: '2GiB',
    cpu: 2,
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
  if (!requireTwilioSignature(req, res)) return;
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
    const recordingStatus = String(req.body.RecordingStatus || 'completed').toLowerCase();
    if (recordingStatus && recordingStatus !== 'completed') {
      console.log(`Recording ${recordingStatus} for ${callId}, wait until completed`);
      if (recordingSid) {
        await callsRef.doc(callId).set(
          { recordingSid, recordingCallSid: rawSid },
          { merge: true }
        );
      }
      res.status(200).send('OK');
      return;
    }
    if (duration === 0) {
      console.log(`Recording complete ${callId}: duration 0, wait for a longer take`);
      res.status(200).send('OK');
      return;
    }
    const mp3Url = `${String(recordingUrl).replace(/\.mp3$/i, '')}.mp3`;
    const ref = callsRef.doc(callId);
    await db.runTransaction(async (tx) => {
      const existing = await tx.get(ref);
      const previous = existing.exists ? existing.data() || {} : {};
      const previousDuration = Number(previous.recordingDurationSeconds || 0);
      const channels = Number(req.body.RecordingChannels || 0);
      if (previousDuration > duration ||
          (previousDuration === duration && previous.recordingRequestId && Number(previous.recordingChannels || 0) >= channels)) return;
      tx.set(ref, {
        recordingUrl: mp3Url, twilioRecordingUrl: mp3Url,
        recordingSid: recordingSid || '', recordingCallSid: rawSid,
        recordingDurationSeconds: duration, recordingChannels: channels,
        recordingProcessingVersion: 2,
        recordingRequestId: String(recordingSid || `${rawSid}:${duration}`),
        ...(!callAiBlocked(previous) ? {
          aiStatus: 'processing', aiStartedAt: FieldValue.serverTimestamp(),
        } : {}),
      }, { merge: true });
    });
    res.status(200).send('OK');
  } catch (error) {
    console.error('Error processing recording:', error);
    res.status(500).send('Error');
  }
});

exports.processQueuedCallRecording = onDocumentWritten({
  document: `companies/${COMPANY_ID}/calls/{callId}`,
  timeoutSeconds: 540, memory: '1GiB', retry: true,
}, async (event) => {
  const after = event.data?.after;
  if (!after?.exists) return;
  const data = after.data() || {};
  const before = event.data.before.exists ? event.data.before.data() || {} : {};
  const manual = data.recordingManualRequestId !== before.recordingManualRequestId;
  const requested = manual || data.recordingRequestId !== before.recordingRequestId ||
    data.recordingRecoveryRequestId !== before.recordingRecoveryRequestId;
  if (data.recordingProcessingVersion !== 2 || !requested || callAiBlocked(data)) return;
  if (!ENDED_CALL_STATUS.has(data.status) && !await isTwilioCallEnded(after.id)) {
    throw new Error('Waiting for the call to finish before processing its recording');
  }
  const latest = await after.ref.get();
  const current = latest.exists ? latest.data() || {} : {};
  if (!latest.exists || callAiBlocked(current)) return;
  await after.ref.set({
    status: 'completed', endTime: current.endTime || FieldValue.serverTimestamp(),
  }, { merge: true });
  let source = current.twilioRecordingUrl || current.recordingUrl || '';
  if (isCallRecordingProxyUrl(source)) source = '';
  for (let attempt = 0; attempt < 6 && !source; attempt++) {
    if (attempt) await new Promise((resolve) => setTimeout(resolve, 1500));
    source = await findTwilioRecordingMp3(after.id);
  }
  if (source) {
    await processRecordingWithAi(after.id, source, { force: manual });
  } else {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(after.ref);
      if (snap.exists && snap.data()?.aiStatus === 'processing') {
        tx.set(after.ref, { aiStatus: 'error', aiError: 'Запись разговора пока недоступна. Можно повторить обработку позже.' }, { merge: true });
      }
    });
  }
});

// Русская озвучка записи. Собирается при первом прослушивании и ложится в
// хранилище рядом с оригиналом, поэтому второй раз отдаётся сразу. Карта
// незавершённых сборок нужна, чтобы два нажатия подряд не озвучивали один и
// тот же разговор дважды.
const callDubber = createCallDubber({ apiKey: OPENAI_API_KEY });
const dubsInFlight = new Map();

async function russianTranscriptFor(callId, data) {
  for (const field of ['transcriptionRu', 'transcription']) {
    const stored = String(data[field] || '').trim();
    if (isRussianTranscript(stored)) return stored;
  }
  const english = String(data.transcriptionEn || data.transcription || '').trim();
  if (!english) return '';
  const russian = await translateCallTranscriptFull(english, String(data.answeredBy || ''));
  if (russian) {
    await callsRef.doc(callId).set({ transcriptionRu: russian }, { merge: true });
  }
  return russian;
}

async function serveRussianDub(callId, data, res) {
  const cached = await cachedRecordingUrl(callId, { variant: 'ru', extension: 'wav' });
  if (cached) {
    res.set('Cache-Control', 'private, max-age=86400');
    res.redirect(302, cached);
    return;
  }
  if (!OPENAI_API_KEY) {
    res.status(503).send('voice translation unavailable');
    return;
  }
  let task = dubsInFlight.get(callId);
  if (!task) {
    task = (async () => {
      const russian = await russianTranscriptFor(callId, data);
      if (!russian) throw Object.assign(new Error('no russian transcript'), { status: 409 });
      const dub = await callDubber.buildRussianDub(russian);
      console.log(`callRecordingAudio ru ${callId}: ${dub.turns} реплик, ${Math.round(dub.seconds)} с`);
      await cacheRecordingToStorage(callId, dub.wav, {
        variant: 'ru',
        extension: 'wav',
        contentType: 'audio/wav',
        field: 'storageUrlRu',
      });
      return dub.wav;
    })();
    dubsInFlight.set(callId, task);
    task.catch(() => {}).finally(() => dubsInFlight.delete(callId));
  }
  try {
    const wav = await task;
    res.set('Content-Type', 'audio/wav');
    res.set('Content-Length', String(wav.length));
    res.set('Accept-Ranges', 'bytes');
    res.set('Content-Disposition', 'inline; filename="call-ru.wav"');
    res.set('Cache-Control', 'private, max-age=86400');
    res.status(200).send(wav);
  } catch (error) {
    if (Number(error.status) === 409) {
      res.status(409).send('no russian transcript');
      return;
    }
    throw error;
  }
}

// Аудиозапись без Twilio-логина: приложение открывает эту ссылку.
exports.callRecordingAudio = onRequestV2(
  {
    region: 'us-central1',
    timeoutSeconds: 300,
    memory: '1GiB',
    invoker: 'public',
    cors: true,
  },
  async (req, res) => {
    setCors(res);
    if (handleOptions(req, res)) return;
    const user = await technicians.requireAnyAppUser(req, res);
    if (!user) return;
    const requested = String(req.query.callId || req.body.callId || '').trim();
    if (!requested) {
      res.status(400).send('callId required');
      return;
    }
    try {
      const callId = await resolveLoggedCallId(requested);
      const snap = await callsRef.doc(callId).get();
      const data = snap.exists ? snap.data() || {} : {};
      if (!user.isOwner) {
        const linkedJobId = String(data.jobId || data.createdJobId || '').trim();
        if (!linkedJobId) {
          res.status(403).send('Forbidden');
          return;
        }
        const jobSnap = await jobsRef.doc(linkedJobId).get();
        const jobData = jobSnap.exists ? jobSnap.data() || {} : {};
        if (String(jobData.assignedTo || '').trim() !== user.uid) {
          res.status(403).send('Forbidden');
          return;
        }
      }
      if (String(req.query.lang || '').toLowerCase() === 'ru') {
        await serveRussianDub(callId, data, res);
        return;
      }
      const ready = await ensureRecordingReady(callId, data);
      if (ready.storageUrl) {
        res.set('Cache-Control', 'private, max-age=86400');
        res.redirect(302, ready.storageUrl);
        return;
      }
      const buffer = ready.buffer;
      if (!buffer || !buffer.length) {
        if (!ready.source) {
          res.status(404).send('no recording');
          return;
        }
        const fetched = await downloadRecordingBuffer(ready.source);
        res.set('Content-Type', 'audio/mpeg');
        res.set('Content-Length', String(fetched.length));
        res.set('Accept-Ranges', 'bytes');
        res.set('Content-Disposition', 'inline; filename="call.mp3"');
        res.set('Cache-Control', 'private, max-age=300');
        res.status(200).send(fetched);
        cacheRecordingToStorage(callId, fetched).catch((error) => {
          console.warn('callRecordingAudio cache:', error.message);
        });
        return;
      }
      res.set('Content-Type', 'audio/mpeg');
      res.set('Content-Length', String(buffer.length));
      res.set('Accept-Ranges', 'bytes');
      res.set('Content-Disposition', 'inline; filename="call.mp3"');
      res.set('Cache-Control', 'private, max-age=86400');
      res.status(200).send(buffer);
    } catch (error) {
      console.error('callRecordingAudio:', error);
      res.status(500).send('Error');
    }
  }
);

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
  process.env.GEMINI_TEXT_MODEL || 'gemini-flash-lite-latest',
  'gemini-flash-latest',
];

async function generateContentWithModelFallback(parts, options = {}) {
  if (!genAI) throw new Error('GEMINI_API_KEY не настроен');
  // «Качественная» модель у нас упирается в квоту, поэтому первой всё равно
  // идёт рабочая. Появится платный тариф — поставьте GEMINI_QUALITY_MODEL.
  const names = options.quality
    ? [
        process.env.GEMINI_QUALITY_MODEL || 'gemini-flash-lite-latest',
        'gemini-flash-latest',
      ]
    : GEMINI_MODEL_CANDIDATES;
  const generationConfig = {};
  if (options.maxOutputTokens) {
    generationConfig.maxOutputTokens = Number(options.maxOutputTokens);
  }
  let lastError;
  for (const name of names) {
    try {
      const model = genAI.getGenerativeModel({
        model: name,
        ...(Object.keys(generationConfig).length ? { generationConfig } : {}),
      });
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

function hasCyrillic(text) {
  return /[А-Яа-яЁё]/.test(String(text || ''));
}

function hasLatin(text) {
  return /[A-Za-z]/.test(String(text || ''));
}

function skipTranslate(text, to = '') {
  const t = String(text || '').trim();
  if (!t) return true;
  if (t.length < 2 && !hasCyrillic(t)) return true;
  if (/^[\d\s.,:+\-/#]+$/.test(t)) return true;
  if (to !== 'ru' && /^(1|2|0|5|yes|no|ok|ок|да|нет)$/i.test(t.replace(/[.!,]/g, ''))) return true;
  return false;
}

async function polishChat(text, options = {}) {
  const t = String(text || '').trim();
  if (!t) return t;
  const variant = Math.max(1, Number(options.variant || 1) || 1);
  const emoji = String(options.emoji || 'normal').toLowerCase();
  const previous = String(options.previous || '').trim();
  const layouts = [
    'greeting on its own line, then one fact per line, then a short closing',
    'short punchy lines with a blank line between greeting, body, and thanks',
    'compact: greeting plus 2–3 fact lines, close with a short question',
    'friendly checklist: hello line, then hyphen facts, then a warm sign-off',
  ];
  const layout = layouts[(variant - 1) % layouts.length];
  const emojiRule =
    emoji === 'more'
      ? 'Use 6–8 emojis. Put them in the greeting, on several fact lines, and in the closing.'
      : emoji === 'less'
        ? 'Use exactly 2 emojis total — one in the greeting and one in the closing. No more.'
        : 'Use 3–5 emojis. Never fewer than 2.';
  const avoid = previous
    ? `\nDo NOT copy this previous version. Change line order, emoji placement, and wording while keeping the same facts:\n${previous}\n`
    : '';
  const instruction =
    'Edit this technician draft into a client SMS. Keep the original language '
    + '(Russian stays Russian, English stays English). '
    + `${emojiRule} Variation #${variant}. Use this structure: ${layout}. `
    + 'Break the text into short structured lines. Use blank lines between blocks. '
    + 'Do not write one long paragraph. '
    + 'Do not change facts, names, addresses, times, model numbers, phone numbers, or URLs. '
    + avoid
    + 'Return ONLY the edited message.';
  const result = await generateContentWithModelFallback([{ text: `${instruction}\n\n${t}` }]);
  const out = String((result.response && result.response.text()) || '').trim();
  return out || t;
}

const JOB_TRANSLATE_RULES = `Ты переводишь и приводишь в порядок описание поломки в карточке заявки для мастера по ремонту бытовой техники в Онтарио.
Переводи грамотным, естественным русским языком мастера, без машинного подстрочника. Английских слов в описании поломки остаться не должно.
Латиницей оставляй ТОЛЬКО имена людей, названия городов и улиц, марки техники, номера моделей/серийников и коды ошибок (E15, F21).
Правильные термины: timer knob / timer button — ручка таймера, door seal / gasket — уплотнитель дверцы, smooth top / glass cooktop / clear top — стеклокерамическая варочная панель, burner — конфорка, heating element / bake element — ТЭН (нагревательный элемент), igniter — свеча розжига, drain pump — сливной насос, float switch — поплавковый датчик, control board — плата управления, spray arm — коромысло (разбрызгиватель), drum — барабан, service call — выезд мастера.
Учитывай род техники по-русски (сушилка, стиральная машина, посудомойка, плита, духовка — женский род; холодильник — мужской род).
Если в тексте есть английские дубли в скобках вроде «Не запускается (Won't start)» — оставь только русский текст без скобок.
Если одна и та же поломка повторена несколько раз разными словами в отдельных строках — объедини эти повторы в одну чёткую фразу, сохранив все детали, номер модели и строку «Удобное время: ...» (переведя английские пометки времени внутри неё на русский).`;

async function translateJobDescription(text, to, { appliance = '' } = {}) {
  const t = String(text || '').trim();
  if (!t || skipTranslate(t)) return t;
  if (to === 'en') return translateChat(t, 'en');
  if (!hasLatin(t)) return t;
  const app = String(appliance || '').trim();
  const applianceLine = app ? `\nТехника в заявке: ${app}.` : '';
  if (OPENAI_API_KEY) {
    try {
      const parsed = await openaiJsonResponse(
        `${JOB_TRANSLATE_RULES}${applianceLine}
Верни строго JSON {"text":"перевод"}.

${t}`,
        { maxOutputTokens: 6000 }
      );
      const out = String((parsed && parsed.text) || '').trim();
      if (out && hasCyrillic(out)) return out;
    } catch (error) {
      console.warn('translateJobDescription OpenAI:', error.message);
    }
  }
  const result = await generateContentWithModelFallback([
    {
      text: `${JOB_TRANSLATE_RULES}${applianceLine}
Верни ТОЛЬКО готовый текст без кавычек и пояснений.

${t}`,
    },
  ]);
  const out = stripModelFences(String((result.response && result.response.text()) || '')).trim();
  return out && hasCyrillic(out) ? out : t;
}

const QUICK_RU_REPLIES = {
  yes: 'Да',
  yep: 'Да',
  yeah: 'Да',
  no: 'Нет',
  nope: 'Нет',
  ok: 'Ок',
  okay: 'Ок',
  sure: 'Конечно',
  thanks: 'Спасибо',
  'thank you': 'Спасибо',
};

async function translateChat(text, to) {
  const t = String(text || '').trim();
  if (!t || skipTranslate(t, to)) return t;
  if (to === 'en' && !hasCyrillic(t)) return t;
  if (to === 'ru' && hasCyrillic(t) && !hasLatin(t)) return t;
  if (to === 'ru' && !hasLatin(t)) return t;
  if (to === 'ru') {
    const quick = QUICK_RU_REPLIES[t.toLowerCase().replace(/[.!,\s]+$/g, '')];
    if (quick) return quick;
  }
  const isDialogue = /(^|\n)\s*(ИИ|AI|Клиент|Client|User|Assistant)\s*:/i.test(t);
  const instruction =
    to === 'en'
      ? 'Translate the technician message to the client into natural Canadian English. Keep names, addresses, model numbers, and URLs unchanged. Return ONLY the English translation, no quotes or notes.'
      : isDialogue
        ? 'Переведи этот диалог на естественный русский. Сохрани метки говорящих ИИ: и Клиент: на каждой строке. Нельзя выкидывать реплики ИИ. Верни ТОЛЬКО диалог, без кавычек и пояснений.'
        : 'Переведи сообщение клиента мастеру на естественный русский. Имена, адреса, модели и ссылки не меняй. Верни ТОЛЬКО перевод, без кавычек и пояснений.';
  const rules = to === 'en' ? 'You translate for an appliance repair shop in Ontario.' : TRANSLATE_RULES;
  // Короткие одиночные SMS быстрее переводить через Gemini Flash Lite,
  // чтобы отправка и онлайн-перевод не ждали reasoning-модель OpenAI.
  if (!isDialogue && t.length <= 600 && genAI) {
    try {
      const result = await generateContentWithModelFallback([
        { text: `${rules}\n\n${instruction}\n\n${t}` },
      ]);
      const out = stripModelFences(String((result.response && result.response.text()) || '')).trim();
      if (out) {
        if (to === 'ru' && hasCyrillic(out)) return out;
        if (to === 'en' && hasLatin(out) && !hasCyrillic(out)) return out;
      }
    } catch (error) {
      console.warn('translateChat Gemini fast:', error.message);
    }
  }
  if (OPENAI_API_KEY) {
    try {
      const parsed = await openaiJsonResponse(
        `${rules}

${instruction}
Верни строго JSON {"text":"перевод"}.

${t}`,
        { maxOutputTokens: 6000 }
      );
      const out = String((parsed && parsed.text) || '').trim();
      if (out) return out;
    } catch (error) {
      console.warn('translateChat OpenAI:', error.message);
    }
  }
  const result = await generateContentWithModelFallback([
    { text: `${rules}\n\n${instruction}\n\n${t}` },
  ]);
  const out = String((result.response && result.response.text()) || '').trim();
  return out || t;
}

function fallbackExtractFromSms(body) {
  const text = String(body || '').trim();
  if (!text) return null;
  if (/^(ok|okay|thanks|thank you|yes|no|hi|hello|спасибо|ок)\.?$/i.test(text)) {
    return { relevant: false };
  }
  const guessed = guessAddressFromText(text);
  const modelMatch = text.match(/\b[A-Z0-9][A-Z0-9-]{4,}\b/i);
  const looksOnlyAddress = Boolean(guessed && guessed.address) && text.length < 80;
  return {
    relevant: !looksOnlyAddress,
    appliance_type: null,
    brand: null,
    model: looksOnlyAddress ? null : (modelMatch ? modelMatch[0] : text).toUpperCase(),
    serial_number: null,
    problem_description: null,
    notes: text,
    address: guessed && guessed.address ? guessed.address : null,
    postal_code: guessed && guessed.postal_code ? guessed.postal_code : null,
  };
}

/**
 * Скачивает запись разговора и одним запросом к Gemini получает и
 * транскрипцию, и структурированные данные для заявки — без отдельного
 * шага распознавания речи.
 */
async function processRecordingWithAi(callId, recordingUrl, { force = false } = {}) {
  const ref = callsRef.doc(callId);
  const sourceSid = String(recordingUrl || '').match(/\/Recordings\/(RE[a-f0-9]{32})/i)?.[1] || '';
  return withProcessingLease({
    db, ref, field: 'recordingProcessingLease',
    shouldRun: (current) => !callAiBlocked(current) &&
      (force || Number(current.recordingProcessingLeaseAttempts || 0) < 6) &&
      (force || !sourceSid || current.aiStatus !== 'done' || current.aiProcessedRecordingSid !== sourceSid),
  }, async () => {
    const completed = await processRecordingWithAiLeased(callId, recordingUrl);
    const latest = await ref.get();
    if (!completed && latest.exists && latest.data()?.aiStatus === 'error') {
      throw new Error('Recording analysis needs retry');
    }
    if (completed && latest.exists && latest.data()?.aiStatus === 'done') {
      await ref.set({
        aiError: FieldValue.delete(),
        aiProcessedRecordingSid: sourceSid,
      }, { merge: true });
    }
  });
}

async function processRecordingWithAiLeased(callId, recordingUrl) {
  try {
    const existing = await callsRef.doc(callId).get();
    if (callAiBlocked(existing.exists ? existing.data() : null)) {
      await callsRef.doc(callId).set({ aiStatus: 'skipped' }, { merge: true });
      return;
    }
  } catch (_) {}
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
      aiStartedAt: FieldValue.serverTimestamp(),
      aiRetryCount: FieldValue.increment(1),
    },
    { merge: true }
  );

  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await processRecordingWithAiOnce(callId, recordingUrl);
      return true;
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

async function selfCheckCallExtract(transcription, extracted, summary) {
  const transcript = String(transcription || '').trim();
  if (transcript.length < 20) return null;
  const prompt = `You are a second-pass checker for an appliance-repair CRM in Ontario.
Compare the transcript with the first-pass JSON. Fix fields that are clearly in the transcript but missing or wrong.
${voiceFacts.EXTRACT_CARD_RULES}
NEVER invent an address, city, postal code, brand, or model.
If the address was mumbled, incomplete, or you would be guessing: address=null, city=null, postal_code=null, address_uncertain=true.
If the name is phonetic garbage or a filler (good, fine, okay, thanks), set client_name=null.
If client_name is a name the SHOP side said (technician Artem, the receptionist introducing herself, lines labelled Me/Моё/AI/ИИ) and the customer never gave it as their own, set client_name=null.
Keep client_phone as 10 digits if present.
appliance_type must stay Russian if known: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.
confidence is 0..1.
review_notes: short Russian notes for the technician (what to double-check). Empty string if solid.

TRANSCRIPT:
${transcript}

SUMMARY:
${String(summary || '').trim()}

FIRST PASS JSON:
${JSON.stringify(extracted || {})}

Return STRICT JSON only:
{"extracted":{"client_name":null,"client_phone":null,"address":null,"city":null,"postal_code":null,"owner_address":null,"appliance_type":null,"brand":null,"model":null,"problem_description":null,"scheduled_date":null,"scheduled_time":null,"wants_callback":false,"contact_on_site_name":null,"contact_on_site_phone":null,"has_job_site":false,"notes":null},"confidence":0.8,"address_uncertain":false,"review_notes":""}`;

  const result = await generateContentWithModelFallback([{ text: prompt }]);
  let raw = String((result.response && result.response.text()) || '').trim();
  if (raw.startsWith('```json')) raw = raw.slice(7);
  else if (raw.startsWith('```')) raw = raw.slice(3);
  if (raw.endsWith('```')) raw = raw.slice(0, -3);
  return extractJsonObject(raw.trim());
}

// Подсказка распознаванию: марки техники и наши города модель иначе слышит
// как попало («Fix Appliance CA» превращалось в «6 Supply and CA»).
const TRANSCRIBE_VOCABULARY = [
  'Appliance repair phone call for FixApplianceCA in Ontario, Canada.',
  'Brands: Bosch, Whirlpool, Samsung, LG, GE, Frigidaire, Maytag, KitchenAid, Electrolux, Kenmore, Amana, Inglis, Miele, Danby.',
  `Towns: ${voiceFacts.SERVICE_TOWNS.slice(0, 22).map((town) => town.name).join(', ')}.`,
  'Keep phone numbers, postal codes, street addresses and model numbers exact.',
].join(' ');

const callTranscriber = createCallTranscriber({ apiKey: OPENAI_API_KEY });

/**
 * Точная расшифровка по дорожкам. Twilio пишет каждую сторону отдельно,
 * поэтому говорящего не надо угадывать, а распознавание слышит чистый голос
 * без наложения. Сюда попадает только запись, которую ещё можно забрать у
 * Twilio в wav; на всё остальное (моно, старые записи, нет ключа OpenAI)
 * остаётся прежний разбор всей записи одной моделью.
 */
async function transcribeDualChannelRecording({ callId, twilioUrl, direction, shopEn }) {
  // Молчаливый отказ здесь стоил живой заявки (07.10.2026): разбор уходил на
  // сведённую дорожку, та пишется одним голосом, и реплики клиента — имя,
  // адрес, описание поломки — пропадали целиком, а в журнале не было ничего.
  if (!OPENAI_API_KEY) {
    console.warn(`dual-channel(${callId}): пропуск — нет OPENAI_API_KEY`);
    return '';
  }
  if (!twilioUrl || !isTwilioMediaUrl(twilioUrl)) {
    console.warn(`dual-channel(${callId}): пропуск — запись не у Twilio: ${twilioUrl || 'ссылки нет'}`);
    return '';
  }
  const wav = await downloadRecordingBuffer(twilioUrl, { format: 'wav' });
  const result = await callTranscriber.transcribeDualWav(wav, {
    direction,
    prompt: TRANSCRIBE_VOCABULARY,
    labels: { shop: shopEn, client: 'Client' },
  });
  console.log(
    `dual-channel(${callId}): реплик=${result.turns.length} симв=${result.text.length} ` +
      `дорожка мастерской=${result.shopChannel} запись=${Math.round(result.duration)}с`
  );
  return result.text;
}

async function transcribeCallRecordingAudio({ audioBase64, shopEn, shopWho }) {
  const transcriptPrompt = `Listen to the WHOLE phone recording from the first sound to the last. Take your time.
Who spoke for the shop: ${shopWho}.
Write EVERY spoken turn from BOTH people. One line per turn. Do not merge turns. Do not summarize. Do not skip the start or the end. If a word is unclear write [unclear].
Return ONLY the dialog, no JSON, no title, like:
${shopEn}: ...
Client: ...`;
  const transcriptResult = await generateContentWithModelFallback(
    [
      { text: transcriptPrompt },
      { inlineData: { mimeType: 'audio/mp3', data: audioBase64 } },
    ],
    { quality: true, maxOutputTokens: 16384 }
  );
  const raw = stripModelFences(
    (transcriptResult.response && transcriptResult.response.text()) || ''
  );
  return relabelTranscript(raw, shopEn === 'Me' ? 'master' : 'ai');
}

// Перевод разговора. На gemini-flash-lite он терял метки говорящих, по своему
// вкусу переписывал адреса кириллицей («Стратфорд») и иногда молча возвращал
// половину разговора — а проверка на полноту отбрасывала такой перевод
// целиком, и мастер видел английский. Теперь переводим построчно и сверяем
// количество строк, поэтому потерять реплику нельзя.
const OPENAI_TEXT_MODELS = [
  process.env.OPENAI_TEXT_MODEL || 'gpt-5.4-mini',
  'gpt-5-mini',
];
const TRANSLATE_BATCH_LINES = 40;

async function openaiJsonResponse(prompt, { maxOutputTokens = 12000 } = {}) {
  if (!OPENAI_API_KEY) throw new Error('OPENAI_API_KEY не настроен');
  let lastError;
  for (const model of OPENAI_TEXT_MODELS) {
    try {
      const response = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model,
          input: prompt,
          reasoning: { effort: 'low' },
          text: { format: { type: 'json_object' }, verbosity: 'low' },
          max_output_tokens: maxOutputTokens,
        }),
        signal: AbortSignal.timeout(90000),
      });
      const raw = await response.text();
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${raw.slice(0, 200)}`);
      const body = JSON.parse(raw);
      const text = (body.output || [])
        .flatMap((item) => (item.content || []).map((part) => part.text || ''))
        .join('')
        .trim();
      if (!text) throw new Error('пустой ответ');
      return extractJsonObject(stripModelFences(text));
    } catch (error) {
      lastError = error;
      console.warn(`OpenAI ${model}: ${error.message}`);
    }
  }
  throw lastError || new Error('OpenAI не ответил');
}

const TRANSLATE_RULES = `Ты переводишь запись телефонного разговора ремонтной мастерской бытовой техники в Онтарио для мастера.
Переводи живым разговорным русским, а не подстрочником. Английских слов в переводе остаться не должно.
Латиницей оставляй ТОЛЬКО имена людей, названия городов и улиц, марки техники и номера моделей — мастер по ним ищет адрес и деталь. Всё остальное переводи: technician — мастер, model sticker — наклейка с моделью, warranty — гарантия, part — деталь.
Номера телефонов и цифры переноси точно. Время пиши по-русски: before 5 p.m. — до 17:00, at 2 — в 14:00.
Техника по-русски: dishwasher — посудомойка, washer — стиральная машина, dryer — сушилка, fridge/freezer — холодильник/морозильник, stove/range — плита, oven — духовка, spray arm — разбрызгиватель, drum — барабан, compressor — компрессор, igniter — свеча розжига, service call — выезд мастера.
Ничего не добавляй, не сокращай и не объединяй реплики.`;

function transcriptLines(text) {
  return String(text || '')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^([^:]{1,24}):\s*(.*)$/);
      return match ? { label: match[1].trim(), text: match[2].trim() } : { label: '', text: line };
    });
}

async function translateLineBatch(batch) {
  const prompt = `${TRANSLATE_RULES}

Переведи каждую реплику из массива. Верни строго JSON {"lines":[...]} — ровно ${batch.length} строк, в том же порядке, без меток говорящих.

${JSON.stringify(batch.map((line) => line.text))}`;
  for (let attempt = 1; attempt <= 2; attempt++) {
    const parsed = await openaiJsonResponse(prompt);
    const lines = Array.isArray(parsed && parsed.lines) ? parsed.lines.map((line) => String(line || '').trim()) : [];
    if (lines.length === batch.length && lines.every(Boolean)) return lines;
    console.warn(`translateLineBatch: получено ${lines.length} строк вместо ${batch.length}, попытка ${attempt}`);
  }
  throw new Error('перевод вернул не все реплики');
}

async function translateCallTranscriptLines(english, answeredBy) {
  const shopRu = shopSpeaker(answeredBy, 'ru');
  const lines = transcriptLines(english);
  if (!lines.length) return '';
  const translated = [];
  for (let i = 0; i < lines.length; i += TRANSLATE_BATCH_LINES) {
    const batch = lines.slice(i, i + TRANSLATE_BATCH_LINES);
    translated.push(...(await translateLineBatch(batch)));
  }
  return lines
    .map((line, index) => {
      const label = /^(client|caller|user|клиент)$/i.test(line.label) ? 'Клиент' : line.label ? shopRu : '';
      return label ? `${label}: ${translated[index]}` : translated[index];
    })
    .join('\n')
    .trim();
}

async function translateCallTranscriptFull(english, answeredBy) {
  const source = String(english || '').trim();
  if (!source) return '';
  if (OPENAI_API_KEY) {
    try {
      const russian = await translateCallTranscriptLines(source, answeredBy);
      if (russian) return russian;
    } catch (error) {
      console.warn('translateCallTranscriptLines:', error.message);
    }
  }
  return translateCallTranscriptWithGemini(source, answeredBy);
}

async function translateCallTranscriptWithGemini(english, answeredBy) {
  const source = String(english || '').trim();
  if (!source) return '';
  const shopRu = shopSpeaker(answeredBy, 'ru');
  const chunks = [];
  const lines = source.split('\n').filter((line) => String(line || '').trim());
  if (source.length <= 9000) {
    chunks.push(source);
  } else {
    const mid = Math.ceil(lines.length / 2);
    chunks.push(lines.slice(0, mid).join('\n'), lines.slice(mid).join('\n'));
  }
  const translated = [];
  for (const chunk of chunks) {
    const result = await generateContentWithModelFallback(
      [
        {
          text: `Переведи этот ПОЛНЫЙ кусок телефонного разговора на русский. Сохрани каждую реплику, тот же порядок, те же говорящие (${shopRu}: / Клиент:). Ничего не сокращай и не выкидывай конец. Имена и адреса не меняй. Верни только текст разговора.

${chunk}`,
        },
      ],
      { quality: true, maxOutputTokens: 16384 }
    );
    translated.push(
      relabelTranscript(
        stripModelFences((result.response && result.response.text()) || ''),
        answeredBy
      )
    );
  }
  const russian = translated.filter(Boolean).join('\n').trim();
  if (speakerTurnCount(russian) < Math.max(2, Math.floor(speakerTurnCount(source) * 0.9))) {
    return '';
  }
  return russian;
}

async function processRecordingWithAiOnce(callId, recordingUrl) {
    let callerNumber = '';
    let direction = 'inbound';
    let liveHistory = [];
    let liveTranscription = '';
    let answeredBy = '';
    let twilioUrl = '';
    try {
      const callDoc = await callsRef.doc(callId).get();
      const data = callDoc.data() || {};
      direction = data.direction || 'inbound';
      callerNumber =
        direction === 'outbound' ? data.toNumber || '' : data.fromNumber || '';
      liveHistory = (data.aiReception && data.aiReception.history) || [];
      liveTranscription = data.transcription || '';
      answeredBy = String(data.answeredBy || '').trim();
      twilioUrl = String(data.twilioRecordingUrl || '').trim();
      if (!answeredBy && direction === 'outbound') answeredBy = 'master';
      if (!answeredBy) answeredBy = liveHistory.length ? 'ai' : 'master';
      if (callAiBlocked(data)) {
        await callsRef.doc(callId).set({ aiStatus: 'skipped' }, { merge: true });
        return;
      }
    } catch (_) {}
    if (!twilioUrl && isTwilioMediaUrl(recordingUrl)) twilioUrl = recordingUrl;

    const audioBuffer = await downloadRecordingBuffer(recordingUrl);
    const storedUrl = await cacheRecordingToStorage(callId, audioBuffer);

    const today = voiceFacts.torontoTodayYmd();
    const shopEn = shopSpeaker(answeredBy, 'en');
    const shopRu = shopSpeaker(answeredBy, 'ru');
    const shopWho =
      answeredBy === 'master'
        ? 'the technician (label Me / Моё), not the AI'
        : 'the AI receptionist (label AI / ИИ)';

    const liveLabeled = labeledTranscriptFromHistory(
      liveHistory,
      liveTranscription,
      answeredBy
    );
    const liveEn = liveHistory.length
      ? liveHistory
          .map((item) => {
            const who = item.role === 'assistant' ? shopEn : 'Client';
            return `${who}: ${item.text}`;
          })
          .join('\n')
      : '';
    let fromAudioEn = '';
    try {
      fromAudioEn = await transcribeDualChannelRecording({ callId, twilioUrl, direction, shopEn });
    } catch (error) {
      console.warn(`dual-channel transcription(${callId}):`, error.message);
    }
    if (!fromAudioEn) {
      console.warn(`transcript(${callId}): по дорожкам текста нет, разбираем сведённую запись`);
      fromAudioEn = await transcribeCallRecordingAudio({
        audioBase64: audioBuffer.toString('base64'),
        shopEn,
        shopWho,
      });
    }
    const transcriptionEn =
      pickLongestTranscript(
        fromAudioEn,
        liveEn,
        !isRussianTranscript(liveTranscription) ? liveTranscription : '',
        !isRussianTranscript(liveLabeled) ? liveLabeled : ''
      ) || pickLongestTranscript(liveTranscription, liveLabeled);
    // Один голос на всю расшифровку — это не молчаливый клиент, а слипшиеся
    // дорожки: вместе с его репликами пропадают имя, адрес и описание поломки.
    if (speakerCount(transcriptionEn) < 2) {
      console.warn(`transcript(${callId}): в расшифровке один голос — реплики клиента потеряны`);
    }
    // Перевод и разбор заявки смотрят в одну и ту же английскую расшифровку и
    // друг от друга не зависят, поэтому идут вместе: раньше мастер ждал их по
    // очереди.
    const extractSource = transcriptionEn || liveLabeled || liveTranscription;
    const extractPrompt = `From this complete appliance-repair phone transcript, write a short Russian summary and extract job fields.
Do not change or shorten the transcript. Use only what is written.
${voiceFacts.EXTRACT_CARD_RULES}
Today (America/Toronto): ${today}
Caller phone: ${callerNumber || 'unknown'}
Direction: ${direction === 'outbound' ? 'master called the client' : 'client called the shop'}
Speakers: lines "${shopEn}:" / "${shopRu}:" are the shop (${answeredBy === 'master' ? 'the technician Artem' : 'the AI receptionist'}); "Client:" / "Клиент:" is the customer.
- client_name: ONLY from what the customer said about themselves. A name in a shop line ("меня зовут Артём", "Artem speaking", the receptionist's name) is NOT the client. Unknown → null.
- client_phone: 10 digits, default ${callerNumber || 'null'} if they did not give another
- scheduled_date YYYY-MM-DD, only if the customer named a day or date (tomorrow = next day after ${today}). "Whenever", "any time", "whatever suits the technician" → null. Never default to today.
- scheduled_time HH:mm. "2" / "at 2" / "two" = 14:00 unless morning / a.m.
- service_declined: a Freon / refrigerant question is a normal fridge or freezer repair — not declined.
- appliance_type in Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Never invent address, brand, or model
Return STRICT JSON only:
{"summary":"2-4 Russian sentences","extracted":{"client_name":null,"client_phone":null,"address":null,"city":null,"postal_code":null,"owner_address":null,"appliance_type":null,"brand":null,"model":null,"problem_description":null,"scheduled_date":null,"scheduled_time":null,"wants_callback":false,"contact_on_site_name":null,"contact_on_site_phone":null,"has_job_site":false,"notes":null,"service_declined":false,"decline_reason":null}}

TRANSCRIPT:
${extractSource}`;

    const [fromAudioRu, card] = await Promise.all([
      transcriptionEn
        ? translateCallTranscriptFull(transcriptionEn, answeredBy).catch((error) => {
            console.warn(`translate transcript(${callId}):`, error.message);
            return '';
          })
        : Promise.resolve(''),
      generateContentWithModelFallback([{ text: extractPrompt }])
        .then((result) =>
          extractJsonObject(stripModelFences((result.response && result.response.text()) || '')) || {}
        )
        .catch((error) => {
          console.warn(`extract from transcript(${callId}):`, error.message);
          return {};
        }),
    ]);
    const summary = String(card.summary || '').trim();
    let extracted = card.extracted || {};

    const transcriptionRu = pickLongestTranscript(
      fromAudioRu,
      isRussianTranscript(liveLabeled) ? liveLabeled : '',
      isRussianTranscript(liveTranscription) ? liveTranscription : ''
    );
    const transcription = pickLongestRussianTranscript(
      transcriptionRu,
      transcriptionEn,
      liveLabeled,
      liveTranscription,
      liveEn,
      fromAudioEn
    );
    // Реплики мастерской и клиента раздельно: иначе «меня зовут Артём»
    // мастера читалось как имя звонящего. История — по английской расшифровке:
    // имя приходит латиницей («Brad»), а в русском переводе оно «Брэд», и
    // проверка «имя звучало в разговоре» выбросила бы настоящее имя.
    const transcriptHistory = voiceFacts.historyFromTranscript(transcriptionEn || transcription);
    extracted = voiceFacts.enrichExtracted(extracted, transcriptHistory, transcription);

    try {
      const reviewed = await selfCheckCallExtract(transcription, extracted, summary);
      if (reviewed && reviewed.extracted) {
        extracted = voiceFacts.mergeExtracted(extracted, reviewed.extracted, transcriptHistory);
        if (reviewed.address_uncertain === true) {
          extracted.address_uncertain = true;
          extracted.address = null;
          extracted.city = null;
          extracted.postal_code = null;
        }
        if (typeof reviewed.confidence === 'number') {
          extracted.confidence = reviewed.confidence;
        }
        if (reviewed.review_notes) {
          extracted.review_notes = reviewed.review_notes;
        }
      }
    } catch (error) {
      console.warn(`selfCheckCallExtract(${callId}):`, error.message);
    }

    if (extracted.address_uncertain === true && !String(extracted.address || '').trim()) {
      extracted.address = null;
    }

    if (!extracted.client_phone && callerNumber) {
      extracted.client_phone = callerNumber.replace(/\D/g, '').slice(-10);
    }

    const matchedClient = await findExistingClient({
      phone: extracted.client_phone || (await getCallFromNumber(callId)),
      email: extracted.client_email,
    });

    const callSnap = await callsRef.doc(callId).get();
    const callData = callSnap.exists ? callSnap.data() || {} : {};
    if (callAiBlocked(callData)) {
      await callsRef.doc(callId).set({ aiStatus: 'skipped' }, { merge: true });
      return;
    }
    const declined = voiceFacts.isServiceDeclined(extracted, callData);
    const hasSubstance =
      !declined &&
      Boolean(
        extracted.appliance_type ||
          extracted.problem_description ||
          extracted.wants_callback ||
          hasConversationToBook(extracted, callData) ||
          voiceFacts.looksLikeRepairConversation(transcription)
      );

    let jobId = callData.jobId || callData.createdJobId || null;
    if (!jobId) {
      const bySource = await findJobsBySourceCall(callId);
      if (bySource.length) {
        bySource.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
        jobId = bySource[0].id;
      }
    }
    // Пока Live-релей ещё дописывает разговор, ждём его итог. Когда он уже
    // закрыл сессию (`done`), ждать нечего — иначе заявка после каждого
    // звонка секретаря опаздывала на девять секунд впустую.
    if (!jobId && callData.answeredBy === 'ai' && !(callData.aiReception && callData.aiReception.done)) {
      for (let i = 0; i < 6 && !jobId; i++) {
        await new Promise((resolve) => setTimeout(resolve, 1500));
        const again = await callsRef.doc(callId).get();
        const latest = again.exists ? again.data() || {} : {};
        jobId = latest.jobId || latest.createdJobId || null;
        if (!jobId) {
          const bySource = await findJobsBySourceCall(callId);
          if (bySource.length) jobId = bySource[0].id;
        }
      }
    }
    if (!jobId) {
      const existingJob = await findReusableOpenJob({
        phone: extracted.client_phone || callerNumber,
        clientId: matchedClient && matchedClient.id,
        applianceType: extracted.appliance_type,
      });
      if (existingJob && existingJob.id) jobId = existingJob.id;
    }

    if (declined) {
      jobId = null;
    }

    if (jobId) {
      const linked = await jobsRef.doc(jobId).get();
      if (!linked.exists) {
        await blockCallJobCreate(callId);
        callData.jobCreateBlocked = true;
        jobId = null;
      } else if (isClosedJobData(linked.data() || {})) {
        await blockCallJobCreate(callId);
        callData.jobCreateBlocked = true;
      }
    }

    if (!jobId && (await isTwilioCallStillLive(callId))) {
      console.log(`processRecordingWithAiOnce: still on the line ${callId}, job after hangup`);
      await callsRef.doc(callId).set(
        {
          extractedData: extracted,
          aiStatus: 'none',
        },
        { merge: true }
      );
      return;
    }

    // Заявка со звонка автоматически больше не создаётся (решение FIX,
    // 21.10.2026): мастер слушает запись и жмёт «Создать заявку на ремонт»
    // в карточке звонка. Разбор, расшифровка и `extractedData` остаются —
    // из них заполняется форма при ручном создании.
    if (jobId && hasSubstance && !callData.jobCreateBlocked) {
      try {
        await patchDraftJobFromCall(jobId, extracted, { noBooking: callData.answeredBy === 'ai' });
      } catch (_) {}
    }

    if (jobId) {
      await mergeDuplicateSourceCallJobs(callId, jobId);
      try {
        const playableUrl = `${functionUrl({}, 'callRecordingAudio')}?callId=${encodeURIComponent(callId)}`;
        await attachCallRecordingToJob({
          jobId,
          callId,
          recordingUrl: playableUrl,
          transcription,
          transcriptionRu: transcriptionRu || transcription,
          transcriptionEn: transcriptionEn || transcription,
          storageUrl: storedUrl || '',
          answeredBy,
          history: liveHistory,
          summary,
        });
        await callsRef.doc(callId).set({ playableUrl }, { merge: true });
      } catch (attachError) {
        console.error(`attachCallRecordingToJob(${callId}) failed:`, attachError);
      }
    }

    const callUpdates = {
      transcription,
      transcriptionRu: transcriptionRu || transcription,
      transcriptionEn: transcriptionEn || transcription,
      summary,
      extractedData: extracted,
      aiStatus: 'done',
      clientId: matchedClient ? matchedClient.id : null,
      serviceDeclined: declined,
      declineReason: String(extracted.decline_reason || '').trim() || null,
    };
    if (jobId) {
      callUpdates.createdJobId = jobId;
      callUpdates.jobId = jobId;
    }
    await callsRef.doc(callId).set(callUpdates, { merge: true });

    if (declined && !jobId && callData.serviceDeclined !== true) {
      await notifyCallOutcome({
        callSid: callId,
        callData,
        extracted,
        kind: 'missed',
        reason: String(extracted.decline_reason || ''),
      });
    }

    console.log(`AI processing done for call ${callId}, job=${jobId || 'none'}`);
    const latest = await callsRef.doc(callId).get();
    secretaryLearnApi
      .proposeFromCall(callId, latest.exists ? latest.data() || {} : { transcription, answeredBy: 'ai' })
      .catch((error) => console.warn('secretaryLearn recording:', error.message));
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
  if (!(await requireAppUser(req, res))) return;

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
    if (callAiBlocked(data)) {
      res.json({ success: true, skipped: true });
      return;
    }
    await callsRef.doc(resolvedId).set({
      aiStatus: 'processing',
      aiStartedAt: FieldValue.serverTimestamp(),
      recordingProcessingVersion: 2,
      recordingManualRequestId: crypto.randomUUID(),
    }, { merge: true });
    res.json({ success: true, queued: true });
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
  if (!data || callAiBlocked(data) || data.aiStatus === 'done' || data.reviewed) return false;
  const retries = Number(data.aiRetryCount || 0);
  if (retries >= 5) return false;
  const hasRecording = Boolean(data.recordingUrl);
  const duration = Number(data.durationSeconds || data.recordingDurationSeconds || 0);
  if (!hasRecording && duration <= 0) return false;
  if (data.aiStatus === 'error') return true;
  if (data.aiStatus === 'processing') return isAiProcessingStale(data);
  return false;
}

async function recoverJobsMissingVisits(limit = 15) {
  const snap = await jobsRef.orderBy('createdAt', 'desc').limit(80).get();
  const fixed = [];
  for (const doc of snap.docs) {
    if (fixed.length >= limit) break;
    const job = doc.data() || {};
    if (!job.createdByAi && !job.sourceCallId) continue;
    const visits = Array.isArray(job.visits) ? job.visits : [];
    if (visits.length || job.scheduledAt || job.scheduledDate) continue;

    // Раньше здесь писался jobScheduleFields({}), то есть ровно то состояние,
    // которое проверяет условие выше: visits: [], scheduledAt: null. Заявка
    // никогда не выходила из выборки, одни и те же 12 штук перезаписывались
    // каждые 5 минут и дёргали onJobWritten. Плюс durationMinutes каждый раз
    // сбрасывался на значение по умолчанию, затирая выбор владельца.
    const updates = {};
    if (!Array.isArray(job.visits)) updates.visits = [];
    if (job.scheduleUnconfirmed !== true) updates.scheduleUnconfirmed = true;
    if (!Number(job.durationMinutes)) {
      updates.durationMinutes = schedule.BOOKING_MINUTES;
    }
    if (!Object.keys(updates).length) continue;

    updates.updatedAt = FieldValue.serverTimestamp();
    await doc.ref.set(updates, { merge: true });
    fixed.push(doc.id);
    console.log(
      `recoverJobsMissingVisits: ${doc.id} ${job.clientName || job.clientPhone || ''} ${Object.keys(updates).join(',')}`
    );
  }
  return fixed;
}

/**
 * Лечит имена, которые транскрипт услышал с опечаткой: на заявке «Aetem», а в
 * карточке клиента «Artem». Правим только когда расхождение — одна-две буквы,
 * то есть это тот же человек. Осознанно другое имя владельца не трогаем, для
 * чужого контакта на объекте есть отдельное поле jobSiteName.
 */
async function healJobClientNames(limit = 10) {
  const snap = await jobsRef.orderBy('createdAt', 'desc').limit(80).get();
  const healed = [];
  const cache = new Map();
  for (const doc of snap.docs) {
    if (healed.length >= limit) break;
    const job = doc.data() || {};
    if (job.deletedAt) continue;
    const current = String(job.clientName || '').trim();
    const clientId = String(job.clientId || '').trim();
    if (!current || !clientId) continue;

    if (!cache.has(clientId)) {
      const client = await clientsRef.doc(clientId).get();
      cache.set(
        clientId,
        client.exists
          ? voiceFacts.usableClientName(
              (client.data() || {}).fullName || (client.data() || {}).name || ''
            )
          : ''
      );
    }
    const known = cache.get(clientId);
    if (!known) continue;
    // Сравнивать сырое имя с нормализованным нельзя: лишний пробел давал
    // «Eric Stigter» -> «Eric Stigter», то есть запись без изменений.
    const currentNorm = voiceFacts.usableClientName(current) || current;
    if (known === currentNorm) continue;

    const limitDist = known.length >= 7 ? 2 : 1;
    const dist = voiceFacts.editDistance(
      known.toLowerCase(),
      currentNorm.toLowerCase()
    );
    if (dist === 0 || dist > limitDist) continue;

    await doc.ref.set(
      {
        clientName: known,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    healed.push(doc.id);
    console.log(`healJobClientNames: ${doc.id} "${current}" -> "${known}"`);
  }
  return healed;
}

async function cancelResurrectedDraft(jobDoc) {
  const job = jobDoc.data() || {};
  if (isClosedJobData(job) || job.needsReview !== true) return false;
  const status = String(job.status || '').trim();
  if (status && status !== 'Вызов') return false;
  const visits = Array.isArray(job.visits)
    ? job.visits.map((visit) => {
        if (!visit || visit.outcome === 'done' || visit.outcome === 'cancelled') {
          return visit;
        }
        return { ...visit, outcome: 'cancelled', smsConfirmStatus: 'cancelled' };
      })
    : [];
  await jobDoc.ref.set(
    {
      status: 'Отменено',
      needsReview: false,
      visits,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  console.log(`recoverAiCallsMissingJobs: отменил воскресшую ${jobDoc.id}`);
  return true;
}

function jobCreatedLagHours(job, callData) {
  const created = job && job.createdAt && job.createdAt.toDate ? job.createdAt.toDate() : null;
  const start = callData && callData.startTime && callData.startTime.toDate
    ? callData.startTime.toDate()
    : null;
  if (!created || !start) return 0;
  return (created.getTime() - start.getTime()) / 36e5;
}

async function recoverAiCallsMissingJobs(limit = 12) {
  await collapseAllCloneJobs();
  const snap = await callsRef.orderBy('startTime', 'desc').limit(80).get();
  const recovered = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const age = callAgeHours(data);
    const linkedId = data.createdJobId || data.jobId || '';
    const bySource = await findJobsBySourceCall(doc.id);
    const closedSource = bySource.filter((jobDoc) => isClosedJobData(jobDoc.data() || {}));
    const draftSource = bySource.filter((jobDoc) => {
      const job = jobDoc.data() || {};
      return !isClosedJobData(job) && job.needsReview === true;
    });

    if (closedSource.length && draftSource.length) {
      for (const jobDoc of draftSource) {
        await cancelResurrectedDraft(jobDoc);
      }
      await blockCallJobCreate(doc.id);
      continue;
    }

    if (callAiBlocked(data)) continue;

    if (age > 48 && draftSource.length) {
      for (const jobDoc of draftSource) {
        const job = jobDoc.data() || {};
        if (jobCreatedLagHours(job, data) >= 12) {
          await cancelResurrectedDraft(jobDoc);
        }
      }
    }

    if (linkedId) {
      const linkedJob = await jobsRef.doc(linkedId).get();
      if (!linkedJob.exists) {
        await blockCallJobCreate(doc.id);
        continue;
      }
      const linkedData = linkedJob.data() || {};
      if (isClosedJobData(linkedData)) {
        await blockCallJobCreate(doc.id);
        continue;
      }
      if (age > 48 && jobCreatedLagHours(linkedData, data) >= 12 && linkedData.needsReview) {
        await cancelResurrectedDraft(linkedJob);
        await blockCallJobCreate(doc.id);
        continue;
      }
    }

    const liveSource = bySource.filter((jobDoc) => !isClosedJobData(jobDoc.data() || {}));
    if (bySource.length && !liveSource.length) {
      await blockCallJobCreate(doc.id);
      continue;
    }
    if (liveSource.length) {
      liveSource.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
      const keep = liveSource[0];
      await callsRef.doc(doc.id).set(
        {
          createdJobId: keep.id,
          jobId: keep.id,
          clientId: (keep.data() || {}).clientId || data.clientId || null,
          aiStatus: data.aiStatus === 'processing' ? data.aiStatus : 'done',
        },
        { merge: true }
      );
      continue;
    }

    if (callAiBlocked(data) || age > 48) {
      if (age > 48) await blockCallJobCreate(doc.id);
      continue;
    }
    if (recovered.length >= limit) continue;

    const inbound = data.direction !== 'outbound';
    const answeredAi = data.answeredBy === 'ai';
    const extracted = (data.aiReception && data.aiReception.extracted) || data.extractedData || {};
    if (voiceFacts.isServiceDeclined(extracted, data)) continue;
    const canBook = hasConversationToBook(extracted, data) || Boolean(data.recordingUrl);
    if (!inbound || !answeredAi || !canBook) continue;
    if (Number(data.jobRecoverCount || 0) >= 3) continue;

    await callsRef.doc(doc.id).set(
      { jobRecoverCount: FieldValue.increment(1) },
      { merge: true }
    );

    // Заявку из звонка этот крон больше не создаёт: мастер заводит её сам
    // в карточке звонка. Остаётся только добор неразобранной записи, чтобы
    // в карточке звонка были текст, краткое содержание и данные для формы.
    if (!data.createdJobId && !data.jobId && data.recordingUrl && data.aiStatus !== 'done') {
      console.log(`recoverAiCallsMissingJobs: запись ${doc.id}`);
      await processRecordingWithAi(doc.id, data.recordingUrl);
      recovered.push(doc.id);
    }
  }
  await collapseAllCloneJobs();
  return recovered;
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
    let recordingUrl = await resolveCallRecordingSource(item.id, item);
    if (recordingUrl && recordingUrl !== item.recordingUrl) {
      await callsRef.doc(item.id).set(
        { recordingUrl, twilioRecordingUrl: recordingUrl },
        { merge: true }
      );
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
    await recoverJobsMissingVisits(12);
    await healJobClientNames(10);
    await recoverAiCallsMissingJobs(8);
  }
);

exports.recoverStuckCallJobs = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  try {
    const jobs = await recoverJobsMissingVisits(20);
    const names = await healJobClientNames(20);
    const calls = await recoverAiCallsMissingJobs(15);
    res.json({ ok: true, jobs, names, calls });
  } catch (error) {
    console.error('recoverStuckCallJobs:', error);
    res.status(500).json({ error: error.message });
  }
});

// Ручное соединение двух заявок из карточки: мастер нажал «Соединить» на
// метке «похоже на дубляж». Сервер делает то же слияние, что и автоматика,
// но force — можно слить и заявку с уже назначенным визитом.
exports.mergeDuplicateJobs = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST required' });
    return;
  }
  const keepId = String((req.body && req.body.keepId) || '').trim();
  const dropId = String((req.body && req.body.dropId) || '').trim();
  if (!keepId || !dropId || keepId === dropId) {
    res.status(400).json({ error: 'keepId and dropId required' });
    return;
  }
  try {
    const merged = await jobDedupe.mergeJobs(keepId, dropId, {
      by: 'owner',
      force: true,
    });
    res.json({ ok: merged, keepId, dropId });
  } catch (error) {
    console.error('mergeDuplicateJobs:', error);
    res.status(500).json({ error: error.message });
  }
});

exports.registerFcmToken = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  const user = await technicians.requireAnyAppUser(req, res);
  if (!user) return;
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST required' });
    return;
  }

  const { token, platform, deviceId, previousToken } = req.body || {};
  if (typeof token !== 'string' || !token.trim() || token.length > 4096 ||
      (deviceId != null && (typeof deviceId !== 'string' || !/^[a-zA-Z0-9_-]{16,128}$/.test(deviceId))) ||
      (previousToken != null && (typeof previousToken !== 'string' || previousToken.length > 4096))) {
    res.status(400).json({ error: 'valid token and deviceId required' });
    return;
  }

  try {
    await registerDeviceToken({
      token: token.trim(),
      platform,
      deviceId,
      previousToken,
      userId: user.uid,
      role: user.isOwner ? 'owner' : 'technician',
    });
    console.log('registerFcmToken: устройство зарегистрировано');
    res.json({ success: true });
  } catch (error) {
    console.error('registerFcmToken error:', error.message);
    res.status(500).json({ error: 'Device registration failed' });
  }
});

// ============================================================================
// SMS: отправка сообщения из приложения
// ============================================================================

async function loadSmsSendSettings() {
  try {
    const settings = db.collection('companies').doc(COMPANY_ID).collection('settings');
    const [configSnap, docsSnap] = await Promise.all([
      settings.doc('config').get(),
      settings.doc('documents').get(),
    ]);
    const config = configSnap.exists ? configSnap.data() || {} : {};
    const docs = docsSnap.exists ? docsSnap.data() || {} : {};
    return {
      header: sanitizeSmsHeader(docs.smsHeader, docs.companyName),
      reviewUrl: config.googleReviewUrl,
      company: docs.companyName,
    };
  } catch (error) {
    console.warn('loadSmsSendSettings:', error.message);
    return { header: '', reviewUrl: '', company: '' };
  }
}

exports.sendSms = functions.https.onRequest(
  { timeoutSeconds: 60, memory: '512MiB', invoker: 'public' },
  async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  const user = await technicians.requireAnyAppUser(req, res);
  if (!user) return;

  if (!client) {
    res.status(500).json({ error: 'Twilio не настроен (TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN)' });
    return;
  }

  const { to, body, clientId, jobId, bodyRu, fallbackBody, visitBooking, isReactionEcho } = req.body || {};
  const trimmedJobId = String(jobId || (visitBooking && visitBooking.jobId) || '').trim();
  if (!user.isOwner) {
    if (!trimmedJobId) {
      res.status(403).json({ error: 'Мастер может отправлять SMS только из карточки своего заказа' });
      return;
    }
    const jobSnap = await jobsRef.doc(trimmedJobId).get();
    const jobData = jobSnap.exists ? jobSnap.data() || {} : {};
    if (String(jobData.assignedTo || '').trim() !== user.uid) {
      res.status(403).json({ error: 'Доступ к заказу закрыт' });
      return;
    }
  }
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
    if (isReactionEcho === true) {
      const tapbackText = String(body || '');
      const message = await client.messages.create({
        from: TWILIO_PHONE_NUMBER,
        to: e164,
        body: tapbackText,
      });
      console.log('sendSms reaction tapback', {
        to: e164.slice(-4),
        sid: message.sid,
        status: message.status,
      });
      res.json({ success: true, sid: message.sid, id: '' });
      return;
    }
    let sendBody = body || '';
    let storedRu = typeof bodyRu === 'string' ? bodyRu.trim() : '';
    const needEn = hasCyrillic(sendBody);
    const [smsCfg, translatedEn] = await Promise.all([
      loadSmsSendSettings(),
      needEn ? translateChat(sendBody, 'en') : Promise.resolve(sendBody),
    ]);
    const header = smsCfg.header;
    if (needEn) {
      storedRu = storedRu || sendBody;
      sendBody = translatedEn;
      if (hasCyrillic(sendBody) && !hasLatin(sendBody)) {
        res.status(500).json({ error: 'Не удалось перевести SMS на английский' });
        return;
      }
      // Перевод бережёт имена, поэтому «Hi Клиент!» он оставлял как есть —
      // латиница в тексте была, и проверка выше такое пропускала.
      sendBody = smsText.latinizeSms(sendBody, 'sendSms');
    }
    const review = await smsLinks.prepareReviewSms(sendBody || '', {
      reviewUrl: smsCfg.reviewUrl,
      company: smsCfg.company,
    });
    sendBody = review.body;
    const text = withSmsHeader(sendBody || '', header);
    const fallbackRaw = smsText.latinizeSms(
      String(fallbackBody || '').trim() || review.fallbackBody,
      'sendSms fallback'
    );
    const fallbackText = fallbackRaw && fallbackRaw !== sendBody
      ? withSmsHeader(fallbackRaw, header)
      : '';
    const payload = {
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      statusCallback: TWILIO_ACCOUNT_SID ? SMS_STATUS_CB : undefined,
    };
    if (text) payload.body = text;
    if (mediaUrls.length) payload.mediaUrl = mediaUrls;
    if (visitBooking) {
      if (req.method !== 'POST' || typeof visitBooking !== 'object' || Array.isArray(visitBooking) || mediaUrls.length) {
        res.status(400).json({ error: 'Некорректный запрос подтверждения визита' });
        return;
      }
      const result = await visitSms.sendApprovedBookingSms({
        ...visitBooking,
        to: e164,
        messageData: { from: TWILIO_PHONE_NUMBER, body: text || '', bodyRu: storedRu },
        send: () => client.messages.create({
          ...payload,
          statusCallback: `${SMS_STATUS_CB}?bookingRequestId=${encodeURIComponent(visitBooking.requestId)}`,
        }),
      });
      res.status(result.success ? 200 : result.state === 'error' ? 409 : 202).json(result);
      return;
    }
    const message = await client.messages.create(payload);
    console.log('sendSms', {
      to: e164.slice(-4),
      sid: message.sid,
      status: message.status,
      hasUrl: /https?:\/\//i.test(text),
    });

    const docRef = await messagesRef.add({
      sid: message.sid,
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text || '',
      bodyRu: storedRu,
      fallbackBody: fallbackText,
      retried30007: false,
      direction: 'outbound',
      status: message.status,
      clientId: clientId || null,
      ...(trimmedJobId ? { jobId: trimmedJobId } : {}),
      ...(!user.isOwner ? { sentByTechnicianId: user.uid } : {}),
      channel: 'sms',
      mediaUrls,
      createdAt: FieldValue.serverTimestamp(),
      read: true,
    });

    res.json({ success: true, sid: message.sid, id: docRef.id });
  } catch (error) {
    console.error('sendSms error:', error.code || '', error.message);
    res.status(error.statusCode || 500).json({ error: error.message, code: error.code || '' });
  }
});

/**
 * Сообщение, которое сервер придумал сам, лежит в `messages` со
 * `status: 'awaiting_approval'` и клиенту не ушло. Здесь мастер решает его
 * судьбу: `action: 'send'` — отдаём в Twilio прямо сейчас, `action: 'reject'` —
 * помечаем отказ, и больше о нём никто не вспомнит.
 */
exports.approveOutbox = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST required' });
    return;
  }
  const id = String((req.body || {}).id || '').trim();
  const action = String((req.body || {}).action || '').trim() === 'send' ? 'send' : 'reject';
  if (!id) {
    res.status(400).json({ error: 'Требуется поле id' });
    return;
  }
  const docRef = messagesRef.doc(id);

  if (action === 'reject') {
    const snap = await docRef.get();
    const msg = snap.exists ? snap.data() || {} : {};
    await docRef.set(
      {
        approval: 'rejected',
        status: 'rejected',
        decidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    try {
      await visitSms.clearClientDialogs({
        jobId: msg.jobId || '',
        clientId: msg.clientId || '',
        phone: msg.to || '',
      });
    } catch (error) {
      console.warn('approveOutbox clearClientDialogs:', error.message);
    }
    res.json({ success: true, state: 'rejected' });
    return;
  }

  if (!client) {
    res.status(500).json({ error: 'Twilio не настроен (TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN)' });
    return;
  }

  // Захватываем документ транзакцией: двойной тап по «Отправить» не должен
  // отправить клиенту два одинаковых SMS.
  let data;
  try {
    data = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(docRef);
      if (!snapshot.exists) throw new Error('Сообщение не найдено');
      const current = snapshot.data() || {};
      if (current.approval !== 'pending' || current.status !== 'awaiting_approval') {
        return null;
      }
      tx.update(docRef, { approval: 'approved', status: 'sending' });
      return current;
    });
  } catch (error) {
    res.status(404).json({ error: error.message });
    return;
  }
  if (!data) {
    const current = (await docRef.get()).data() || {};
    res.status(409).json({ error: 'Решение по этому сообщению уже принято', state: current.status || '' });
    return;
  }

  try {
    const message = await client.messages.create({
      from: TWILIO_PHONE_NUMBER,
      to: String(data.to || ''),
      body: smsText.latinizeSms(String(data.body || ''), 'approveOutbox'),
      statusCallback: SMS_STATUS_CB,
    });
    await docRef.set(
      {
        sid: message.sid,
        status: message.status,
        decidedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    res.json({ success: true, sid: message.sid });
  } catch (error) {
    console.error('approveOutbox send error:', error.code || '', error.message);
    // Назад в очередь: мастер увидит тот же пузырь и сможет повторить.
    await docRef.set(
      {
        approval: 'pending',
        status: 'awaiting_approval',
        errorMsg: String(error.message || '').slice(0, 300),
      },
      { merge: true }
    );
    res.status(error.statusCode || 500).json({ error: error.message, code: error.code || '' });
  }
});

exports.translateMessage = functions.https.onRequest(
  { timeoutSeconds: 120, memory: '256MiB', invoker: 'public' },
  async (req, res) => {
    setCors(res);
    if (handleOptions(req, res)) return;
    if (!(await requireAppUser(req, res))) return;
    const payload = req.body || {};
    const text = String(payload.text || payload.body || '').trim();
    const mode = String(payload.mode || '').trim().toLowerCase();
    const to = String(payload.to || '').trim().toLowerCase() === 'en' ? 'en' : 'ru';
    if (!text) {
      res.status(400).json({ error: 'text required' });
      return;
    }
    try {
      if (mode === 'polish') {
        const polished = await polishChat(text, {
          variant: payload.variant,
          emoji: payload.emoji,
          previous: payload.previous,
        });
        res.json({ success: true, polished, translated: polished });
        return;
      }
      // Разговор переводится построчно и со сверкой количества реплик —
      // тем же путём, что и расшифровка записи. Приложению гонять диалог
      // через обычный перевод нельзя: оно теряло реплики и метки.
      if (mode === 'dialog') {
        const dialog = await translateCallTranscriptFull(text, String(payload.answeredBy || ''));
        res.json({ success: true, translated: dialog || text, to: 'ru' });
        return;
      }
      if (mode === 'job') {
        const translated = await translateJobDescription(text, to, {
          appliance: payload.appliance,
        });
        res.json({ success: true, translated, to });
        return;
      }
      const translated = await translateChat(text, to);
      res.json({ success: true, translated, to });
    } catch (error) {
      console.error('translateMessage:', error);
      res.status(500).json({ error: error.message });
    }
  }
);

// ============================================================================
// SMS: webhook входящего сообщения — Messaging URL номера в консоли Twilio
// ============================================================================

exports.incomingSms = functions.https.onRequest(
  { timeoutSeconds: 120, memory: '512MiB', invoker: 'public' },
  async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
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
        alreadyProcessed =
          prev.aiStatus === 'done' || prev.aiStatus === 'skipped_confirm';
        const missingPhoto =
          Array.isArray(prev.twilioMedia) &&
          prev.twilioMedia.length &&
          !(prev.mediaUrls && prev.mediaUrls.length);
        if (missingPhoto) alreadyProcessed = false;
        matchedClient = prev.clientId
          ? { id: prev.clientId, fullName: '' }
          : await findClientForInboundPhone(from);
        if (!twilioMedia.length && Array.isArray(prev.twilioMedia)) {
          twilioMedia = prev.twilioMedia.filter((item) => item && item.url);
        }
      }
    }

    if (!twilioMedia.length && sid && numMedia > 0) {
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
      matchedClient = await findClientForInboundPhone(from);
    }
  } catch (error) {
    console.error('incomingSms error:', error);
  }

  // Отвечаем Twilio сразу, чтобы webhook не истекал, пока работает ИИ.
  try {
    if (!docRef) {
      const id = sid ? `sms_${crypto.createHash('sha256').update(String(sid)).digest('hex')}` : null;
      docRef = id ? messagesRef.doc(id) : messagesRef.doc();
      try {
        await docRef.create({
          sid: sid || '', from: from || '', to: to || '', body,
          direction: 'inbound', status: 'received',
          clientId: matchedClient ? matchedClient.id : null,
          clientName: matchedClient
            ? voiceFacts.stripClientPrefix(matchedClient.fullName || matchedClient.name || '', from)
            : '',
          mediaUrls: [], twilioMedia, channel: 'sms',
          aiStatus: twilioMedia.length || body.trim() ? 'processing' : 'none',
          createdAt: FieldValue.serverTimestamp(), read: false,
        });
      } catch (error) {
        if (Number(error.code) !== 6 && error.code !== 'already-exists') throw error;
      }
    }
    if (!alreadyProcessed) {
      await docRef.set({ processingVersion: 2, smsProcessingRequestId: String(sid || docRef.id) }, { merge: true });
    }
    res.type('text/xml').send('<Response></Response>');
  } catch (error) {
    console.error('incomingSms save error:', error.message);
    res.status(503).send('Message storage unavailable');
  }
});

exports.processIncomingSms = onDocumentWritten({
  document: `companies/${COMPANY_ID}/messages/{messageId}`,
  timeoutSeconds: 540, memory: '512MiB', retry: true,
}, async (event) => {
  const after = event.data?.after;
  if (!after?.exists) return;
  const data = after.data() || {};
  const before = event.data.before.exists ? event.data.before.data() || {} : {};
  const isInboundSms =
    data.processingVersion === 2 &&
    data.direction === 'inbound' &&
    data.channel === 'sms' &&
    Boolean(data.smsProcessingRequestId) &&
    before.smsProcessingRequestId !== data.smsProcessingRequestId;

  if (!isInboundSms) {
    // Онлайн-перевод всех остальных сообщений (авто-SMS, исходящие на английском,
    // письма) сразу при записи в Firestore — без задержки при отправке и открытии.
    const body = String(data.body || '').trim();
    const bodyRu = String(data.bodyRu || '').trim();
    const needsRu =
      !data.deletedAt &&
      data.isReactionEcho !== true &&
      (data.channel === 'sms' || data.channel === 'email') &&
      !data.autoBodyRuAt &&
      body.length > 0 &&
      hasLatin(body) &&
      !skipTranslate(body, 'ru') &&
      (!bodyRu || bodyRu === body || !hasCyrillic(bodyRu));
    if (needsRu && (genAI || OPENAI_API_KEY)) {
      try {
        const ru = String((await translateChat(body, 'ru')) || '').trim();
        const patch = { autoBodyRuAt: FieldValue.serverTimestamp() };
        if (ru && ru !== body && hasCyrillic(ru)) {
          patch.bodyRu = ru;
        }
        await after.ref.set(patch, { merge: true });
      } catch (error) {
        console.warn('autoTranslateMessage:', error.message);
      }
    }
    return;
  }

  await withProcessingLease({
    db, ref: after.ref, field: 'smsProcessingLease',
    shouldRun: (current) => !messageAiBlocked(current) &&
      !['done', 'skipped_confirm'].includes(current.aiStatus) && Number(current.smsProcessingLeaseAttempts || 0) < 3,
  }, async (current) => {
    await processIncomingSmsData(after.ref, current);
  });
});

async function processIncomingSmsData(docRef, data) {
  const from = String(data.from || '');
  const body = String(data.body || '');
  const sid = String(data.sid || '');
  const twilioMedia = Array.isArray(data.twilioMedia) ? data.twilioMedia : [];
  const matchedClient = data.clientId ? { id: data.clientId, fullName: data.clientName || '' } : null;
  const alreadyProcessed = false;
  const preview = body.trim() ? body.trim().slice(0, 80) : twilioMedia.length ? 'Фото' : 'Новое сообщение';
  const senderLabel = voiceFacts.stripClientPrefix(matchedClient?.fullName || '', from);
  const title = senderLabel ? `SMS от ${senderLabel}` : 'Новое SMS';
  const existingRu = String(data.bodyRu || '').trim();
  const shouldTranslate =
    Boolean(docRef) &&
    !alreadyProcessed &&
    String(body || '').trim().length > 0 &&
    hasLatin(body) &&
    (!existingRu || existingRu === body.trim() || !hasCyrillic(existingRu));
  const translatePromise = shouldTranslate
    ? translateChat(body, 'ru').catch((error) => {
        console.warn('incomingSms translate:', error.message);
        return '';
      })
    : Promise.resolve('');

  let confirmHandled = false;
  if (!alreadyProcessed) {
    try {
      confirmHandled = await visitSms.tryHandleConfirmReply({
        from,
        body,
        clientId: matchedClient ? matchedClient.id : null,
      });
    } catch (error) {
      console.error('incomingSms confirm error:', error);
    }
  }

  const ruRaw = String((await translatePromise) || '').trim();
  const ruValid = ruRaw && ruRaw !== body.trim() && hasCyrillic(ruRaw) ? ruRaw : '';
  if (docRef && ruValid) {
    try {
      await docRef.set({ bodyRu: ruValid }, { merge: true });
    } catch (error) {
      console.warn('incomingSms save bodyRu:', error.message);
    }
  }

  if (docRef && confirmHandled) {
    try {
      // `read: true` здесь больше не ставим (решение FIX, 21.10.2026).
      // Ответ клиента разбирает автоответчик, и push о нём не идёт —
      // `aiStatus: 'skipped_confirm'` этого и добивается. Но раньше он же
      // гасил сообщение совсем: «1» в ответ на подтверждение визита нигде
      // не появлялась, а отдельная карточка «Заявка подтверждена» убрана.
      // Теперь сообщение остаётся непрочитанным и видно там, где его
      // разбирают, — на вкладке «Связь» и в самой переписке.
      await docRef.set({ aiStatus: 'skipped_confirm' }, { merge: true });
    } catch (error) {
      console.error('incomingSms confirm mark error:', error);
    }
  }

  if (!alreadyProcessed && !confirmHandled) {
    try {
      const openJob = await findOpenJobForContact({
        phone: from,
        clientId: matchedClient ? matchedClient.id : null,
      }).catch(() => null);
      if (docRef && openJob && openJob.id) {
        await docRef.set({ jobId: openJob.id }, { merge: true }).catch(() => {});
      }
      await notifyMaster(title, preview, {
        type: 'sms',
        from: from || '',
        messageId: docRef ? docRef.id : sid || '',
        clientId: matchedClient ? matchedClient.id : '',
        ...(openJob && openJob.id ? { jobId: openJob.id } : {}),
      });
      if (
        openJob &&
        technicians.isAssignedToTechnician(openJob) &&
        typeof notifyApi.notifyUser === 'function'
      ) {
        await notifyApi.notifyUser(openJob.assignedTo, title, preview, {
          type: 'job',
          from: from || '',
          messageId: docRef ? docRef.id : sid || '',
          jobId: openJob.id,
        });
      }
    } catch (error) {
      console.error('incomingSms notify error:', error.message);
    }
  }

  if (docRef && !alreadyProcessed && !confirmHandled) {
    try {
      const latest = await docRef.get();
      if (messageAiBlocked(latest.exists ? latest.data() : null)) {
        await docRef.set({ aiStatus: 'skipped' }, { merge: true });
        return;
      }
      await processSmsWithAi({
        // Без канала заявка из SMS уезжала в ветку писем: в карточке стояло
        // source: 'email' и sourceEmailFrom с номером телефона, а разбор
        // «SMS ждёт заявку» не срабатывал вовсе (FIX, 12.10.2026).
        channel: 'sms',
        messageId: docRef.id,
        from,
        body,
        twilioMedia,
        clientId: matchedClient ? matchedClient.id : null,
        clientName: matchedClient
          ? voiceFacts.stripClientPrefix(matchedClient.fullName || matchedClient.name || '', from)
          : '',
      });
    } catch (error) {
      console.error('incomingSms AI error:', error);
      await docRef.set({ aiStatus: 'error', aiError: error.message }, { merge: true });
      throw error;
    }
  }
}

exports.onJobWritten = visitSms.onJobWritten;
exports.sendVisitReminders = visitSms.sendVisitReminders;
exports.sendOwnerReminders = visitSms.sendOwnerReminders;
exports.onJobNonCashMonth = require('./noncash_alert').onJobNonCashMonth;


// ============================================================================
// SMS: статус доставки исходящего сообщения
// ============================================================================

/** Человеческая причина для шторки: код Twilio → почему SMS не дошло. */
function smsFailureReason(errorCode) {
  const code = String(errorCode || '').trim();
  const known = {
    30003: 'телефон выключен или вне сети',
    30004: 'номер заблокировал приём SMS',
    30005: 'номер не существует',
    30006: 'стационарный номер, SMS не принимает',
    30007: 'оператор заблокировал (спам-фильтр)',
    30008: 'ошибка оператора',
    21211: 'неверный номер',
    21610: 'клиент отписался (STOP)',
    21614: 'номер не принимает SMS',
  };
  return known[code] || (code ? `ошибка ${code}` : 'оператор не доставил');
}

exports.smsStatusCallback = functions.https.onRequest(async (req, res) => {
  if (!requireTwilioSignature(req, res)) return;
  const sid = req.body.MessageSid;
  const status = req.body.MessageStatus;
  const errorCode = String(req.body.ErrorCode || '').trim();
  const bookingRequestId = String(req.query.bookingRequestId || '');
  if (bookingRequestId && sid && ['accepted', 'queued', 'sending', 'sent', 'delivered', 'read', 'failed', 'undelivered', 'canceled'].includes(status)) {
    try {
      await visitSms.recordBookingDelivery(bookingRequestId, { sid, status, errorCode });
      res.status(200).send('OK');
    } catch (error) {
      console.error('booking SMS status error:', error.message);
      res.status(error.statusCode || 500).send('Booking SMS status update failed');
    }
    return;
  }

  try {
    if (sid) {
      const snapshot = await messagesRef.where('sid', '==', sid).limit(1).get();
      if (!snapshot.empty) {
        const doc = snapshot.docs[0];
        // Колбэки Twilio приходят не по порядку: «sent» после «delivered» —
        // обычное дело. Без этой лестницы галочка в переписке откатывалась с
        // «Доставлено» на «Отправлено».
        const rank = { accepted: 1, queued: 1, scheduled: 1, sending: 2, sent: 3, delivered: 4, read: 5 };
        const current = String((doc.data() || {}).status || '');
        const settled = ['failed', 'undelivered', 'canceled'].includes(status);
        if (settled || (rank[status] || 0) >= (rank[current] || 0)) {
          const statusUpdate = { status };
          if (status === 'delivered' && current !== 'read') {
            statusUpdate.deliveredAt = FieldValue.serverTimestamp();
          }
          if (status === 'read') {
            statusUpdate.readAt = FieldValue.serverTimestamp();
          }
          await doc.ref.update(statusUpdate);
        }
        let retried = false;
        if (
          (status === 'undelivered' || status === 'failed') &&
          errorCode === '30007' &&
          client
        ) {
          const data = doc.data() || {};
          const fallback = String(data.fallbackBody || '').trim();
          if (fallback && data.retried30007 !== true) {
            retried = true;
            await doc.ref.update({ retried30007: true });
            const retry = await client.messages.create({
              from: TWILIO_PHONE_NUMBER,
              to: data.to,
              body: fallback,
              statusCallback: TWILIO_ACCOUNT_SID ? SMS_STATUS_CB : undefined,
            });
            await messagesRef.add({
              sid: retry.sid,
              from: TWILIO_PHONE_NUMBER,
              to: data.to,
              body: fallback,
              direction: 'outbound',
              status: retry.status,
              clientId: data.clientId || null,
              jobId: data.jobId || null,
              kind: data.kind || null,
              channel: 'sms',
              retried30007: true,
              createdAt: FieldValue.serverTimestamp(),
              read: true,
            });
            console.warn('smsStatus retried 30007', {
              sid,
              retrySid: retry.sid,
              to: String(data.to || '').slice(-4),
            });
          }
        }
        // Клиент SMS не получил, и запасного текста больше нет. Раньше это
        // было видно только в логах: в чате сообщение так и висело
        // «отправлено». Теперь помечаем документ и будим мастера.
        if ((status === 'undelivered' || status === 'failed') && !retried) {
          const data = doc.data() || {};
          const phone = String(data.to || req.body.To || '');
          await doc.ref.update({
            deliveryFailed: true,
            errorCode,
            failedAt: FieldValue.serverTimestamp(),
          });
          try {
            await notifyMaster('SMS не доставлено', `${phone} · ${smsFailureReason(errorCode)}`, {
              type: 'sms',
              peer: phone,
              to: phone,
              messageId: doc.id,
              clientId: data.clientId || '',
              jobId: data.jobId || '',
              smsFailed: '1',
              errorCode,
            });
          } catch (error) {
            console.warn('smsStatus notify:', error.message);
          }
        }
      }
    }
    if (status === 'undelivered' || status === 'failed') {
      console.warn('smsStatus', {
        sid,
        status,
        errorCode,
        to: String(req.body.To || '').slice(-4),
      });
    }
  } catch (error) {
    console.error('smsStatusCallback error:', error);
  }

  res.status(200).send('OK');
});


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
    const bucket = getStorage().bucket(bucketName);
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

async function findRecentEmailIntakeJob({ from, messageId, fingerprint }) {
  const fromEmail = String(from || '').trim().toLowerCase();
  const fp = String(fingerprint || '').trim();
  const srcId = String(messageId || '').trim();
  const snapshot = await jobsRef.get();
  let fallback = null;
  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    if (isClosedJobData(data) || data.deletedAt) continue;
    const isEmail =
      String(data.source || '').toLowerCase() === 'email' ||
      Boolean(data.sourceEmailId) ||
      String(data.sourceEmailFrom || '').includes('@');
    if (!isEmail) continue;
    if (srcId && String(data.sourceEmailId || '') === srcId) {
      return { id: doc.id, ...data };
    }
    if (fp && String(data.emailFingerprint || '') === fp) {
      return { id: doc.id, ...data };
    }
    const srcFrom = String(data.sourceEmailFrom || '').trim().toLowerCase();
    const created =
      data.createdAt && typeof data.createdAt.toDate === 'function'
        ? data.createdAt.toDate()
        : null;
    if (
      fromEmail &&
      srcFrom === fromEmail &&
      created &&
      Date.now() - created.getTime() < 3 * 60 * 1000
    ) {
      if (!fallback) fallback = { id: doc.id, ...data };
    }
  }
  return fallback;
}

async function findOpenJobForContact({ phone, clientId, email, text, extracted }) {
  const fold = (v) =>
    String(v || '')
      .toLowerCase()
      .replace(/[^a-z0-9а-яё]+/gi, ' ')
      .replace(/\s+/g, ' ')
      .trim();

  const pickBest = (items) => {
    const open = items.filter((item) => !schedule.isClosedJob(item));
    if (!open.length) return null;
    if (open.length > 1 && (text || extracted)) {
      const blob = fold(
        [
          text,
          extracted && extracted.address,
          extracted && extracted.city,
          extracted && extracted.contact_on_site_name,
          extracted && extracted.contact_on_site_phone,
          extracted && extracted.appliance_type,
        ]
          .filter(Boolean)
          .join(' ')
      );
      const exAddr = String((extracted && extracted.address) || '').trim();
      if (blob) {
        let bestJob = null;
        let bestScore = 0;
        for (const item of open) {
          let score = 0;
          const addr = jobWorkAddress(item);
          const addrWords = fold(addr.split(',')[0]).split(' ').filter((w) => w.length >= 2);
          for (const w of addrWords) {
            if (blob.includes(w)) score += /^\d+$/.test(w) ? 5 : 3;
          }
          const siteName = fold(item.jobSiteName);
          if (siteName.length >= 3 && blob.includes(siteName)) score += 5;
          const sitePhone = normalizePhone(item.jobSitePhone);
          const exSitePhone = normalizePhone(extracted && extracted.contact_on_site_phone);
          if (sitePhone && exSitePhone && sitePhone === exSitePhone) score += 6;
          if (score > bestScore) {
            bestScore = score;
            bestJob = item;
          }
        }
        if (bestJob && bestScore >= 4) return bestJob;
      }
      // Если у клиента несколько открытых заявок, у всех уже указан свой адрес,
      // а в сообщении назван совсем другой новый адрес с поломкой — не затираем
      // чужую открытую заявку, пусть предложится новая заявка на этот адрес.
      if (exAddr.length >= 4 && hasRepairData(extracted)) {
        const nextFull = buildFullAddress(extracted, null);
        const allHaveDifferentAddress = open.every((item) => {
          const cur = jobWorkAddress(item);
          return cur && voiceFacts.addressesLookDifferent(cur, nextFull);
        });
        if (allHaveDifferentAddress) return null;
      }
    }
    open.sort((a, b) => {
      const millis = (v) =>
        v && typeof v.toMillis === 'function'
          ? v.toMillis()
          : v instanceof Date
            ? v.getTime()
            : 0;
      return millis(b.createdAt) - millis(a.createdAt);
    });
    return open[0] || null;
  };

  const normalized = normalizePhone(phone);
  if (clientId) {
    const snap = await jobsRef.where('clientId', '==', clientId).get();
    const items = snap.docs
      .map((doc) => ({ id: doc.id, ...doc.data() }))
      .filter((item) => !item.deletedAt);
    if (normalized) {
      const siteMatched = items.filter(
        (item) =>
          normalizePhone(item.jobSitePhone) === normalized &&
          normalizePhone(item.clientPhone) !== normalized
      );
      const pickedSite = pickBest(siteMatched);
      if (pickedSite) return pickedSite;
    }
    const picked = pickBest(items);
    if (picked) return picked;
  }

  const needle = String(email || '').trim().toLowerCase();
  if (needle.includes('@')) {
    const snapshot = await jobsRef.get();
    const byEmail = [];
    for (const doc of snapshot.docs) {
      const data = doc.data() || {};
      const emails = [
        data.clientEmail,
        data.sourceEmailFrom,
        data.jobSiteEmail,
      ].map((value) => String(value || '').trim().toLowerCase());
      if (emails.includes(needle)) byEmail.push({ id: doc.id, ...data });
    }
    const picked = pickBest(byEmail);
    if (picked) return picked;
  }

  if (!normalized) return null;
  const snapshot = await jobsRef.get();
  const all = [];
  for (const doc of snapshot.docs) {
    const data = doc.data();
    if (data.deletedAt) continue;
    const phones = [data.clientPhone, data.jobSitePhone].map(normalizePhone);
    if (!phones.includes(normalized)) continue;
    all.push({ id: doc.id, ...data });
  }
  return pickBest(all);
}

async function findJobByPhone(phone) {
  return findOpenJobForContact({ phone });
}

// Секретарь говорит по-английски, а тип техники в базе лежит по-русски.
/**
 * Пункт 17: повторный звонок. Секретарь должна знать, что заказ уже принят,
 * иначе она берёт его заново и просит подтвердить ещё раз. Возвращает короткую
 * строку для промпта или '' если открытой заявки нет.
 */
async function voiceOpenJobBrief({ phone, clientId }) {
  try {
    return (await schedule.loadCallerSchedule({ phone, clientId })).brief;
  } catch (error) {
    console.warn('voiceOpenJobBrief:', error.message);
    return 'Caller calendar is unavailable. Do not claim there is a booking or no booking; say you cannot verify it right now.';
  }
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

function extractedHasAddress(extracted) {
  if (!extracted) return false;
  const street = String(extracted.address || '').trim();
  const city = String(extracted.city || '').trim();
  const postal = String(extracted.postal_code || '').trim();
  return street.length >= 4 || (Boolean(street) && Boolean(city)) || postal.length >= 5;
}

function clientHasStoredAddress(client) {
  if (!client) return false;
  if (String(client.address || '').trim().length >= 4) return true;
  const locs = Array.isArray(client.locations) ? client.locations : [];
  for (const loc of locs) {
    const street = String((loc && loc.street) || '').trim();
    const city = String((loc && loc.city) || '').trim();
    const postal = String((loc && (loc.postalCode || loc.postal)) || '').trim();
    if (street.length >= 4 || (street && city) || postal.length >= 5) return true;
  }
  return false;
}

function guessAddressFromText(body) {
  const text = String(body || '').replace(/\s+/g, ' ').trim();
  if (text.length < 6) return null;
  const postalMatch = text.match(/\b([A-Za-z]\d[A-Za-z][ -]?\d[A-Za-z]\d)\b/);
  const postal = postalMatch
    ? postalMatch[1].toUpperCase().replace(/\s+/g, ' ')
    : null;
  const streetMatch = text.match(
    /\b(\d{1,6}(?:-\d{1,4})?\s+(?:[A-Za-z][A-Za-z0-9.'\-]*\s+){0,5}(?:Street|St|Road|Rd|Ave|Avenue|Blvd|Boulevard|Drive|Dr|Way|Court|Ct|Cres|Crescent|Lane|Ln|Place|Pl|Circle|Cir|Trail|Parkway|Pkwy|Highway|Hwy|Terrace|Ter)\.?(?:\s+(?:North|South|East|West|N|S|E|W|NW|NE|SW|SE))?(?:\s+(?:Unit|Apt|Apartment|#)\s*[A-Za-z0-9-]+)?)\b/i
  );
  let street = streetMatch ? streetMatch[1].replace(/\s+/g, ' ').trim() : null;
  let city = null;
  if (street) {
    const at = text.toLowerCase().indexOf(street.toLowerCase());
    if (at >= 0) {
      const after = text.slice(at + street.length);
      const cityMatch = after.match(
        /^\s*,\s*([A-Za-z][A-Za-z .'-]{1,28}?)(?=,|\s+[A-Z]{2}\b|\s+[A-Za-z]\d[A-Za-z]|$)/
      );
      if (cityMatch) city = cityMatch[1].trim();
    }
  }
  if (!street && postal && postalMatch) {
    const before = text.slice(0, postalMatch.index).trim();
    const loose = before.match(/(\d{1,6}\s+[A-Za-z][A-Za-z0-9.'\-\s,]{3,60})$/);
    if (loose) street = loose[1].replace(/[,\s]+$/, '').trim();
  }
  if (!street && !postal) return null;
  return {
    address: street || null,
    city: city || null,
    postal_code: postal,
  };
}

/**
 * Почта из входящего сообщения — в карточку клиента.
 *
 * Только в пустое поле: адрес, который мастер вписал руками, важнее того,
 * с которого сегодня написали. Имя кладёт `applyPersonNameToClient` — оно
 * тоже перетирает лишь заглушку вида «Клиент +1…».
 */
async function applyInboundEmailToClient(clientId, rawEmail) {
  const email = String(rawEmail || '').trim().toLowerCase();
  if (!clientId || !email.includes('@')) return;
  if (/^(wordpress|wpadmin|wpforms|wp|webmaster|no-?reply)@/.test(email)) return;
  const snap = await clientsRef.doc(clientId).get();
  if (!snap.exists) return;
  if (String((snap.data() || {}).email || '').trim()) return;
  await clientsRef.doc(clientId).set(
    { email, lastActiveAt: FieldValue.serverTimestamp() },
    { merge: true }
  );
}

/** «Где работа» заявки — как `Job.workAddress` в приложении. */
function jobWorkAddress(job) {
  const site = String((job && job.jobSiteAddress) || '').trim();
  if (job && job.hasJobSite && site) return site;
  return String((job && job.clientAddress) || '').trim();
}

/**
 * Номер квартиры из SMS дописывается к адресу, который уже есть: в заявке
 * (её «Где работа»), а если это адрес самого клиента — и в его карточке.
 */
async function applyInboundUnit({ clientId, client, existingFull, job, unitLabel }) {
  const jobUsesSite = Boolean(job && job.hasJobSite && String(job.jobSiteAddress || '').trim());
  const jobBase = job ? jobWorkAddress(job) : '';
  const base = jobBase || existingFull;
  if (!base) return { mode: null, full: '' };
  const merged = voiceFacts.addressWithUnit(base, unitLabel);

  if (job && job.id && merged !== jobBase) {
    await jobsRef.doc(job.id).set(
      {
        [jobUsesSite ? 'jobSiteAddress' : 'clientAddress']: merged,
        clientId,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
  const ownAddress =
    !jobUsesSite &&
    existingFull &&
    !voiceFacts.addressesLookDifferent(
      voiceFacts.addressWithUnit(existingFull, ''),
      voiceFacts.addressWithUnit(base, '')
    );
  if (ownAddress) {
    const locations = Array.isArray(client.locations)
      ? client.locations.map((loc) => ({ ...(loc || {}) }))
      : [];
    if (locations.length) locations[0] = { ...locations[0], unit: unitLabel };
    await clientsRef.doc(clientId).set(
      {
        address: voiceFacts.addressWithUnit(existingFull, unitLabel),
        ...(locations.length ? { locations } : {}),
        lastActiveAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
  console.log(`SMS unit ${unitLabel} added to ${jobUsesSite ? 'job site' : 'address'} for client ${clientId} job ${job && job.id}`);
  return { mode: jobUsesSite ? 'jobsite' : 'primary', full: merged };
}

async function applyInboundAddressToClient({ clientId, extracted, job }) {
  if (!clientId || !extractedHasAddress(extracted)) {
    return { mode: null, full: '' };
  }
  const snap = await clientsRef.doc(clientId).get();
  if (!snap.exists) return { mode: null, full: '' };
  const client = { id: snap.id, ...(snap.data() || {}) };
  const street = String(extracted.address || '').trim();
  const city = String(extracted.city || '').trim();
  const postal = String(extracted.postal_code || '').trim();
  const nextFull = buildFullAddress(extracted, null);
  if (!nextFull) return { mode: null, full: '' };

  const existingFull =
    String(client.address || '').trim() || voiceFacts.clientAddressFrom(client) || '';
  // «Unit 23» вслед за адресом — это квартира того же дома, а не другое место
  // работы. Раньше такая SMS становилась «Где работа: Unit 23» (Sue Rathbone,
  // 25.10.2026), и мастер вписывал адрес в заявку руками.
  const unitLabel = voiceFacts.unitOnlyAddress(street);
  if (unitLabel) {
    return applyInboundUnit({ clientId, client, existingFull, job, unitLabel });
  }

  const alreadyHas = clientHasStoredAddress(client);
  const different =
    alreadyHas &&
    existingFull &&
    voiceFacts.addressesLookDifferent(existingFull, nextFull);

  if (!alreadyHas) {
    const locations = Array.isArray(client.locations)
      ? client.locations.map((loc) => ({ ...(loc || {}) }))
      : [];
    if (!locations.length) {
      locations.push({
        id: 'primary',
        street,
        city,
        postalCode: postal,
        contacts: [
          {
            id: 'owner',
            name: voiceFacts.stripClientPrefix(
              client.fullName || client.name || '',
              client.phone || ''
            ),
            phone: client.phone || '',
            role: 'owner',
            isPrimary: true,
          },
        ],
      });
    } else {
      locations[0] = {
        ...locations[0],
        street: street || locations[0].street || '',
        city: city || locations[0].city || '',
        postalCode: postal || locations[0].postalCode || locations[0].postal || '',
      };
    }
    await clientsRef.doc(clientId).set(
      {
        address: nextFull,
        locations,
        lastActiveAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    if (job && job.id && !String(job.clientAddress || '').trim()) {
      await jobsRef.doc(job.id).set(
        {
          clientAddress: nextFull,
          clientId,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }
    console.log(`SMS address saved as primary for client ${clientId}`);
    return { mode: 'primary', full: nextFull };
  }

  if (!different) {
    // Адрес тот же, что в карточке клиента, а в заявке места работы нет —
    // кладём его и в заявку: «Где работа» читает адрес заявки, не карточки.
    if (job && job.id && !jobWorkAddress(job)) {
      await jobsRef.doc(job.id).set(
        {
          clientAddress: existingFull.length >= nextFull.length ? existingFull : nextFull,
          clientId,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }
    return { mode: null, full: nextFull };
  }

  const ownerLabel = voiceFacts.stripClientPrefix(
    client.fullName || client.name || '',
    client.phone || ''
  );
  await upsertClientJobSite(
    clientId,
    client,
    { ...extracted, has_job_site: true },
    ownerLabel,
    client.phone || ''
  );
  if (job && job.id) {
    // Контакт на адресе: другой человек заменяет записанного, а если его
    // не назвали — берём клиента (или уже записанного человека).
    const site = voiceFacts.onSiteContactFrom(
      extracted,
      ownerLabel,
      client.phone || ''
    );
    const explicitSitePhone = normalizePhone(
      extracted && extracted.contact_on_site_phone
    );
    const existingSitePhone = normalizePhone(job.jobSitePhone);
    const ownerNorm = normalizePhone(client.phone);
    await jobsRef.doc(job.id).set(
      {
        hasJobSite: true,
        jobSiteAddress: nextFull,
        jobSiteName: site.explicit
          ? site.name
          : job.jobSiteName || site.name || '',
        jobSitePhone: explicitSitePhone
          ? explicitSitePhone
          : existingSitePhone && existingSitePhone !== ownerNorm
            ? job.jobSitePhone
            : site.explicit
              ? site.phone
              : job.jobSitePhone || site.phone || '',
        clientId,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
  console.log(`SMS address saved as job site for client ${clientId} job ${job && job.id}`);
  return { mode: 'jobsite', full: nextFull };
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
    .replace(/^(Клиент|ИИ|AI|Me|Моё|Секретарь)\s*:.*$/gim, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function jobDescriptionFromExtract(extracted) {
  const model = String((extracted && extracted.model) || '').trim();
  const problem = String((extracted && extracted.problem_description) || '').trim();
  return [model ? `Модель: ${model}` : '', problem].filter(Boolean).join('\n');
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

function hasIntakeLead(extracted) {
  if (!extracted) return false;
  return Boolean(
    hasRepairData(extracted) ||
      extracted.client_name ||
      extracted.client_phone ||
      extracted.address ||
      extracted.city
  );
}

async function ensureClientFromEmailIntake({ extracted, fromEmail, existingClientId }) {
  const phone = normalizePhone(extracted && extracted.client_phone);
  const email = String((extracted && extracted.client_email) || '')
    .trim()
    .toLowerCase();
  const name =
    voiceFacts.usableClientName((extracted && extracted.client_name) || '') ||
    phone ||
    '';
  let client = null;
  if (existingClientId) {
    const snap = await clientsRef.doc(existingClientId).get();
    if (snap.exists) client = { id: snap.id, ...snap.data() };
  }
  if (!client && phone) client = await findClientByPhone(phone);
  if (!client && email.includes('@')) client = await findClientByEmail(email);
  const address = buildFullAddress(extracted || {}, client);
  const city = String((extracted && extracted.city) || '').trim();
  const street = String((extracted && extracted.address) || '').trim();
  const postal = String((extracted && extracted.postal_code) || '').trim();

  if (!client) {
    const clientDoc = await clientsRef.add({
      fullName: name,
      phone: phone || '',
      email: email.includes('@') ? email : '',
      address,
      locations: [
        {
          id: 'primary',
          street,
          city,
          postalCode: postal,
          email: email.includes('@') ? email : '',
          contacts: [
            {
              id: 'owner',
              name,
              phone: phone || '',
              email: email.includes('@') ? email : '',
              role: 'owner',
              isPrimary: true,
            },
          ],
        },
      ],
      createdAt: FieldValue.serverTimestamp(),
      lastActiveAt: FieldValue.serverTimestamp(),
      createdByAi: true,
      createdFromEmail: true,
    });
    return { id: clientDoc.id, fullName: name, phone, email, address };
  }

  const updates = { lastActiveAt: FieldValue.serverTimestamp() };
  if (name && !client.fullName) updates.fullName = name;
  if (phone && !client.phone) updates.phone = phone;
  if (email.includes('@') && !client.email) updates.email = email;
  if (address && !client.address) updates.address = address;
  await clientsRef.doc(client.id).set(updates, { merge: true });
  return {
    id: client.id,
    fullName: updates.fullName || client.fullName || name,
    phone: updates.phone || client.phone || phone,
    email: updates.email || client.email || email,
    address: updates.address || client.address || address,
  };
}

async function processSmsWithAi({
  messageId,
  from,
  body,
  twilioMedia,
  clientId,
  clientName,
  preloadedImages,
  channel,
  intake,
  websiteForm,
  emailFingerprint,
}) {
  const messageRef = messagesRef.doc(messageId);
  const existing = await messageRef.get();
  const existingData = existing.exists ? existing.data() || {} : {};
  if (messageAiBlocked(existingData)) {
    await messageRef.set({ aiStatus: 'skipped' }, { merge: true });
    return;
  }
  const messageSid = existingData.sid || '';
  const isWebsite = Boolean(websiteForm || existingData.websiteForm);
  const isIntake = Boolean(intake || existingData.emailIntake || isWebsite);
  const fromIsEmail = String(from || '').includes('@');
  const fromPhone = fromIsEmail ? '' : from;

  const images = Array.isArray(preloadedImages) ? [...preloadedImages] : [];
  const storedUrls = [];
  if (!images.length) {
    let mediaItems = Array.isArray(twilioMedia) ? [...twilioMedia] : [];
    if (!mediaItems.length && messageSid) {
      try {
        mediaItems = await listTwilioMedia(messageSid);
      } catch (error) {
        console.warn('listTwilioMedia failed:', error.message);
      }
    }
    for (let i = 0; i < mediaItems.length; i++) {
      const item = mediaItems[i];
      if (!item.url) continue;
      if (
        item.contentType &&
        !String(item.contentType).startsWith('image/') &&
        item.contentType !== 'application/octet-stream'
      ) {
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

  const prompt = isIntake
    ? `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Клиент прислал письмо с заявкой на ремонт${images.length ? ' и фото' : ''}.
Из письма нужно собрать карточку клиента и новую заявку.

Правила:
- Не путай отправителя письма с мастером — это клиент или агрегатор заявок
- Если это форма с сайта (WordPress) — отправитель письма это почтовый ящик сайта, НЕ клиент
- client_email — email клиента из текста письма или Reply-To, не wordpress@ и не адрес сайта
- client_name — имя из полей формы, не имя отправителя WordPress / Dale / администратора сайта
- Имя, телефон, адрес, город, индекс извлеки, если они есть
- ${voiceFacts.EXTRACT_CARD_RULES}
- Если в письме есть улица, дом или индекс — обязательно заполни address / city / postal_code
- Если ремонт не у клиента дома, а по другому адресу — has_job_site=true, address = куда ехать, contact_on_site_name / contact_on_site_phone = кто встретит. Если на месте будет сам клиент — contact_on_site_name / contact_on_site_phone = null
- Если это письмо существующего клиента только с адресом — relevant может быть false, но адрес всё равно заполни
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Телефон форматируй как 10 цифр
- Если письмо НЕ про ремонт бытовой техники — relevant: false
- Если данных мало, но это ремонт техники — relevant: true, если есть хотя бы имя, телефон, адрес, email или техника

Верни СТРОГО один JSON без markdown:
{
  "relevant": true,
  "client_name": null,
  "client_phone": null,
  "client_email": null,
  "address": null,
  "city": null,
  "postal_code": null,
  "appliance_type": null,
  "brand": null,
  "model": null,
  "serial_number": null,
  "problem_description": null,
  "scheduled_date": null,
  "scheduled_time": null,
  "contact_on_site_name": null,
  "contact_on_site_phone": null,
  "has_job_site": false,
  "notes": null
}

Письмо: ${body || '(нет текста)'}
Отправитель: ${from || ''}`
    : fromIsEmail
      ? `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Клиент ответил письмом по уже открытой заявке${images.length ? ' и прислал фото' : ''}.
Нужно ДОПИСАТЬ в рабочую карточку всё, что он сообщил.

Правила:
- ${voiceFacts.EXTRACT_CARD_RULES}
- client_name — имя самого отправителя, если он его назвал или подписался; иначе null
- Адрес, модель, бренд, серийник, описание поломки — заполни, если есть
- Если адрес ремонта НЕ дом клиента — has_job_site=true, address = куда ехать, contact_on_site_name / contact_on_site_phone = кто на месте. Если на месте будет сам клиент — contact_on_site_name / contact_on_site_phone = null
- Если на фото шильдик — прочитай model, brand, serial_number
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Если это только «ок / спасибо / подтверждено» без новых данных — relevant: false и все поля null
- Если есть хоть адрес, модель, бренд, серийник или описание — relevant: true

Верни СТРОГО один JSON без markdown:
{
  "relevant": true,
  "client_name": null,
  "appliance_type": null,
  "brand": null,
  "model": null,
  "serial_number": null,
  "problem_description": null,
  "address": null,
  "city": null,
  "postal_code": null,
  "contact_on_site_name": null,
  "contact_on_site_phone": null,
  "has_job_site": false,
  "notes": null
}

Письмо: ${body || '(нет текста)'}
Отправитель: ${from || ''}`
    : `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Клиент прислал SMS или письмо${images.length ? ' и фото (шильдик, модель, техника)' : ''}.
Извлеки всё, что он о себе сообщил: имя, адрес, что именно сломалось.

Правила:
- ${voiceFacts.EXTRACT_CARD_RULES}
- client_name — имя самого отправителя, если он представился («it's John», «This is Mary Smith», «меня зовут…», подпись в конце). Чужое имя, имя мастера и обычное слово — не имя, тогда null
- Если на фото шильдик/бирка — обязательно прочитай model, brand, serial_number
- Тип техники на русском: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка
- Если клиент прислал улицу, дом, город или индекс — заполни address / city / postal_code
- У одного клиента (лендлорда или управляющей компании) может быть несколько объектов и адресов ремонта, при этом переписка идёт с одного и того же номера телефона. Если в сообщении указан адрес объекта или имя/телефон арендатора (жильца на месте), обязательно извлеки address, contact_on_site_name, contact_on_site_phone и поставь has_job_site: true
- Если это только адрес без техники — relevant: false, но адрес всё равно заполни
- Если это обычное сообщение без данных о технике и без адреса (ок, спасибо, когда приедете) — все поля null, relevant: false
- Телефон форматируй как 10 цифр

Верни СТРОГО один JSON без markdown:
{
  "relevant": true,
  "client_name": null,
  "client_email": null,
  "appliance_type": null,
  "brand": null,
  "model": null,
  "serial_number": null,
  "problem_description": null,
  "address": null,
  "city": null,
  "postal_code": null,
  "contact_on_site_name": null,
  "contact_on_site_phone": null,
  "has_job_site": false,
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
  const relevant = isIntake
    ? extracted.relevant !== false && hasIntakeLead(extracted)
    : extracted.relevant !== false &&
      (hasRepairData(extracted) ||
        extractedHasAddress(extracted) ||
        Boolean(extracted.contact_on_site_name) ||
        Boolean(extracted.contact_on_site_phone));

  if (!extractedHasAddress(extracted)) {
    const guessed = guessAddressFromText(body);
    if (guessed) {
      extracted.address = extracted.address || guessed.address;
      extracted.city = extracted.city || guessed.city;
      extracted.postal_code = extracted.postal_code || guessed.postal_code;
    }
  }

  let resolvedClientId = isWebsite ? '' : clientId || existingData.clientId || '';
  if (!resolvedClientId && fromIsEmail && !isWebsite) {
    try {
      const found = await findClientByEmail(from);
      if (found && found.id) resolvedClientId = found.id;
    } catch (error) {
      console.warn('email address findClient:', error.message);
    }
  }
  if (!resolvedClientId && extracted && extracted.client_email) {
    const extractedEmail = String(extracted.client_email).trim().toLowerCase();
    const websiteMailbox =
      /^(wordpress|wpadmin|wpforms|wp|webmaster)@/.test(extractedEmail) ||
      extractedEmail.includes('wordpress');
    if (!websiteMailbox) {
      try {
        const found = await findClientByEmail(extractedEmail);
        if (found && found.id) resolvedClientId = found.id;
      } catch (error) {
        console.warn('extracted email findClient:', error.message);
      }
    }
  }
  if (!resolvedClientId) {
    try {
      const found = await findClientByPhone(
        (extracted && extracted.client_phone) || (!fromIsEmail ? from : '')
      );
      if (found && found.id) resolvedClientId = found.id;
    } catch (error) {
      console.warn('SMS address findClient:', error.message);
    }
  }

  const jobForAddress = await findOpenJobForContact({
    phone: fromPhone || (extracted && extracted.client_phone) || '',
    clientId: resolvedClientId,
    email: isWebsite
      ? String((extracted && extracted.client_email) || existingData.replyToEmail || '')
      : fromIsEmail
        ? from
        : (extracted && extracted.client_email) || '',
    text: body,
    extracted,
  });
  let addressResult = { mode: null, full: '' };
  if (extractedHasAddress(extracted) && resolvedClientId) {
    try {
      addressResult = await applyInboundAddressToClient({
        clientId: resolvedClientId,
        extracted,
        job: jobForAddress,
      });
    } catch (error) {
      console.warn('SMS address apply:', error.message);
    }
  }
  // Имя и почта из сообщения тоже идут в карточку клиента — так же, как их
  // кладёт разбор звонка. Раньше из SMS приезжал только адрес, и карточка
  // оставалась подписанной номером телефона (просьба FIX, 13.10.2026).
  const inboundName = voiceFacts.usableClientName(
    (extracted && extracted.client_name) || ''
  );
  if (resolvedClientId) {
    try {
      if (inboundName) await applyPersonNameToClient(resolvedClientId, inboundName);
      await applyInboundEmailToClient(
        resolvedClientId,
        (extracted && extracted.client_email) || (fromIsEmail ? from : '')
      );
    } catch (error) {
      console.warn('SMS client card:', error.message);
    }
  }

  const updates = {
    extractedData: extracted,
    aiStatus: relevant ? 'done' : extractedHasAddress(extracted) ? 'address' : 'none',
  };
  if (resolvedClientId) updates.clientId = resolvedClientId;

  if (isIntake) {
    try {
      const ensured = await ensureClientFromEmailIntake({
        extracted,
        fromEmail: isWebsite
          ? String((extracted && extracted.client_email) || existingData.replyToEmail || '')
          : from,
        existingClientId: isWebsite ? '' : resolvedClientId || clientId,
      });
      if (ensured && ensured.id) {
        resolvedClientId = ensured.id;
        if (ensured.fullName) clientName = ensured.fullName;
      }
    } catch (error) {
      console.warn('email intake client:', error.message);
    }
    updates.emailOfferPending = false;
    updates.emailBellPending = true;
    updates.emailIntake = true;
    if (resolvedClientId) updates.clientId = resolvedClientId;
    // Спам с формы сайта: ИИ не увидел ремонта — не дёргаем мастера:
    // письмо сразу прочитано, звонок/счётчики не крутятся, метка spam для Корзины.
    if (isWebsite && relevant === false) {
      updates.emailBellPending = false;
      updates.read = true;
      updates.spam = true;
    }
  }

  let job = jobForAddress;
  if (!job) {
    job = await findOpenJobForContact({
      phone: fromPhone || (extracted && extracted.client_phone) || '',
      clientId: resolvedClientId || (isWebsite ? '' : clientId),
      email: isWebsite
        ? String((extracted && extracted.client_email) || existingData.replyToEmail || '')
        : fromIsEmail
          ? from
          : (extracted && extracted.client_email) || '',
      text: body,
      extracted,
    });
  }
  if (!job && channel === 'email') {
    job = await findRecentEmailIntakeJob({
      from: isWebsite ? '' : from,
      messageId,
      fingerprint: emailFingerprint || existingData.emailFingerprint || '',
    });
  }
  const appliance = mergeAppliance(job && (job.appliances || [])[0], extracted);
  const smsNote = jobDescriptionFromExtract(extracted);
  const siteName = String((extracted && extracted.contact_on_site_name) || '').trim();
  const sitePhone = normalizePhone(extracted && extracted.contact_on_site_phone);
  const hasCardBits =
    hasRepairData(extracted) ||
    extractedHasAddress(extracted) ||
    Boolean(siteName) ||
    Boolean(sitePhone) ||
    Boolean(inboundName) ||
    storedUrls.length > 0;

  if (job && hasCardBits) {
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
      updatedAt: FieldValue.serverTimestamp(),
    };
    // Клиент представился в переписке, а заявка подписана номером телефона —
    // ставим настоящее имя. Живое имя на заявке не трогаем.
    if (
      inboundName &&
      (!String(job.clientName || '').trim() ||
        voiceFacts.isPlaceholderClientName(job.clientName) ||
        voiceFacts.looksLikeGarbageName(job.clientName))
    ) {
      jobUpdates.clientName = inboundName;
    }
    if (siteName) {
      jobUpdates.hasJobSite = true;
      jobUpdates.jobSiteName = siteName;
    }
    if (sitePhone) {
      jobUpdates.hasJobSite = true;
      jobUpdates.jobSitePhone = sitePhone;
    }
    if (storedUrls.length) {
      const attachments = storedUrls.map((url) => ({
        url,
        type: 'image',
        source: channel === 'email' ? 'email' : 'sms',
        createdAt: new Date().toISOString(),
      }));
      jobUpdates.attachments = FieldValue.arrayUnion(...attachments);
    }
    await jobsRef.doc(job.id).update(jobUpdates);
    updates.jobId = job.id;
    try {
      await notifyMaster(
        'Заявка обновлена',
        [job.clientName || clientName || from, appliance.type, smsNote]
          .filter(Boolean)
          .join('\n')
          .slice(0, 180),
        {
          type: 'job',
          source: channel === 'email' ? 'email' : 'sms',
          jobId: job.id,
          messageId,
          from: from || '',
        }
      );
    } catch (error) {
      console.warn('job update notify:', error.message);
    }
  } else if (!job && ((isIntake && relevant !== false) || (relevant && channel !== 'email'))) {
    if (channel === 'sms' && !isWebsite) {
      // SMS: заявка больше не создаётся автоматически — мастер решает сам.
      // Помечаем сообщение как ожидающее создания заявки.
      updates.smsOfferPending = true;
      try {
        await notifyMaster(
          'SMS: ждёт заявку',
          [clientName || inboundName || from, appliance.type, smsNote]
            .filter(Boolean)
            .join('\n')
            .slice(0, 180),
          {
            type: 'sms',
            source: 'sms',
            messageId,
            from: from || '',
          }
        );
      } catch (error) {
        console.warn('sms offer notify:', error.message);
      }
    } else {
      // Email / website: создаём заявку как раньше (мастер всё равно подтверждает через emailOfferPending)
      // Контакт на адресе: если другого человека не назвали — это сам клиент.
      const effectiveClientPhone =
        fromPhone || (extracted && extracted.client_phone) || '';
      const effectiveClientName = voiceFacts.stripClientPrefix(
        clientName || String((extracted && extracted.client_name) || '').trim(),
        effectiveClientPhone || (isIntake ? '' : from)
      );
      const siteFallback = voiceFacts.onSiteContactFrom(
        extracted,
        effectiveClientName,
        effectiveClientPhone
      );
      const created = await jobsRef.add({
        clientId: resolvedClientId || (isWebsite ? '' : clientId) || '',
        clientName: effectiveClientName,
        clientPhone: effectiveClientPhone,
        clientAddress:
          addressResult.mode === 'jobsite'
            ? ''
            : addressResult.full ||
              (extractedHasAddress(extracted) ? buildFullAddress(extracted, null) : ''),
        hasJobSite: addressResult.mode === 'jobsite',
        jobSiteAddress: addressResult.mode === 'jobsite' ? addressResult.full : '',
        jobSiteName: addressResult.mode === 'jobsite' ? siteFallback.name : '',
        jobSitePhone: addressResult.mode === 'jobsite' ? siteFallback.phone : '',
        appliances: [appliance],
        applianceType: appliance.type,
        brand: appliance.brand,
        model: appliance.model,
        serialNumber: appliance.serialNumber,
        description: smsNote,
        status: 'Вызов',
        priority: '🟢 Обычный',
        needsReview: true,
        createdByAi: true,
        source: isWebsite ? 'website' : 'email',
        sourceEmailId: channel === 'email' ? messageId : '',
        sourceEmailFrom:
          isWebsite
            ? String(
                (extracted && extracted.client_email) ||
                  existingData.replyToEmail ||
                  from ||
                  '',
              )
            : from || '',
        websiteForm: isWebsite,
        emailFingerprint: String(emailFingerprint || existingData.emailFingerprint || ''),
        attachments: storedUrls.map((url) => ({
          url,
          type: 'image',
          source: channel === 'email' ? 'email' : 'sms',
          createdAt: new Date().toISOString(),
        })),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      updates.jobId = created.id;
      try {
        await notifyMaster(
          isWebsite ? 'Заявка с сайта' : 'Заявка с почты',
          [clientName || from, appliance.type, smsNote].filter(Boolean).join('\n').slice(0, 180),
          {
            type: 'job',
            source: 'email',
            jobId: created.id,
            messageId,
            from: from || '',
          }
        );
      } catch (error) {
        console.warn('job create notify:', error.message);
      }
    }
  }

  await messageRef.set(updates, { merge: true });
  console.log(`SMS AI done for ${messageId}, job ${updates.jobId || '-'}`);
}

// ============================================================================
// STRIPE: инвойсы, депозиты, Checkout и webhook оплаты
// ============================================================================

const stripeHandlers = require('./stripe');
exports.createStripePayment = stripeHandlers.createStripePayment;
exports.createStripeRefund = stripeHandlers.createStripeRefund;
exports.getStripeBalance = stripeHandlers.getStripeBalance;
exports.createTerminalConnectionToken = stripeHandlers.createTerminalConnectionToken;
exports.createTerminalPaymentIntent = stripeHandlers.createTerminalPaymentIntent;
exports.completeTerminalPayment = stripeHandlers.completeTerminalPayment;
exports.stripeWebhook = stripeHandlers.stripeWebhook;
exports.stripePaymentComplete = stripeHandlers.stripePaymentComplete;
exports.checkStripePayment = stripeHandlers.checkStripePayment;
// Care Plan: подписка $10/мес (Stripe Checkout) и ежедневное напоминание о ТО.
exports.createCarePlanCheckout = stripeHandlers.createCarePlanCheckout;
exports.syncCarePlanSubscription = stripeHandlers.syncCarePlanSubscription;
exports.carePlanReminders = require('./care_plan').carePlanReminders;
exports.estimateConfirm = require('./estimate_confirm').estimateConfirm;
const shortLinks = require('./short_links');
exports.shortenLink = shortLinks.shortenLink;
exports.p = shortLinks.p;

const expenseHandlers = require('./expenses')({
  setCors,
  handleOptions,
  generateContentWithModelFallback,
});
exports.parseExpenseReceipt = expenseHandlers.parseExpenseReceipt;

// Картинка запчасти из интернета для карточки склада.
const partImageHandlers = require('./part_image')({
  setCors,
  handleOptions,
  generateContentWithModelFallback,
  companyId: COMPANY_ID,
});
exports.findPartImage = partImageHandlers.findPartImage;

const createEmailModule = require('./email');
const emailHandlers = createEmailModule({
  notifyMaster,
  setCors,
  handleOptions,
  processInboundAi: processSmsWithAi,
  translateChat,
});
exports.sendEmail = functions.https.onRequest(
  { timeoutSeconds: 120, memory: '512MiB', invoker: 'public' },
  async (req, res) => {
    if (req.method !== 'OPTIONS' && !(await requireAppUser(req, res))) return;
    await emailHandlers.sendEmail(req, res);
  }
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

// ============================================================================
// Отложенная отправка сообщений (SMS / email)
// ============================================================================

/**
 * Отправить одно запланированное SMS из Firestore-документа.
 * Повторяет логику exports.sendSms, но без HTTP-обёртки.
 */
async function sendScheduledSms(data) {
  if (!client) throw new Error('Twilio не настроен (TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN)');
  const toRaw = String(data.to || '').trim();
  const body = String(data.body || '').trim();
  const mediaUrls = Array.isArray(data.mediaUrls)
    ? data.mediaUrls.filter((url) => /^https?:\/\//i.test(url))
    : [];

  if (!toRaw || (!body && !mediaUrls.length)) throw new Error('Нет получателя или текста');

  const e164 = (() => {
    const digits = toRaw.replace(/\D/g, '');
    if (!digits) return null;
    if (digits.length === 10) return `+1${digits}`;
    if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
    if (toRaw.startsWith('+')) return `+${digits}`;
    return `+${digits}`;
  })();
  if (!e164) throw new Error(`Некорректный номер: ${toRaw}`);

  const header = await getSmsHeader();
  let sendBody = body;
  let storedRu = String(data.bodyRu || '').trim();
  if (hasCyrillic(sendBody)) {
    storedRu = storedRu || sendBody;
    sendBody = await translateChat(sendBody, 'en');
    if (hasCyrillic(sendBody) && !hasLatin(sendBody)) {
      throw new Error('Не удалось перевести SMS на английский');
    }
    sendBody = smsText.latinizeSms(sendBody, 'sendSms');
  }
  const review = await prepareReviewSms(sendBody || '');
  sendBody = review.body;
  const text = withSmsHeader(sendBody || '', header);
  const fallbackRaw = review.fallbackBody;
  const payload = { from: TWILIO_PHONE_NUMBER, to: e164, statusCallback: SMS_STATUS_CB };
  if (text) payload.body = text;
  if (mediaUrls.length) payload.mediaUrl = mediaUrls;

  const message = await client.messages.create(payload);
  await messagesRef.add({
    sid: message.sid,
    from: TWILIO_PHONE_NUMBER,
    to: e164,
    body: text || '',
    bodyRu: storedRu,
    fallbackBody: fallbackRaw ? withSmsHeader(fallbackRaw, header) : '',
    retried30007: false,
    direction: 'outbound',
    status: message.status,
    clientId: data.clientId || null,
    channel: 'sms',
    mediaUrls,
    createdAt: FieldValue.serverTimestamp(),
    read: true,
  });
}

/**
 * Раз в минуту отправляет накопившиеся отложенные сообщения.
 * Firestore-коллекция: companies/{id}/scheduled_messages
 * Поля: channel, to, toEmail, body, bodyRu, clientId, subject,
 *       mediaUrls, sendAt (Timestamp), status (pending→sending→sent/failed/cancelled)
 */
exports.processScheduledMessages = functions.scheduler.onSchedule(
  {
    schedule: 'every 1 minutes',
    timeZone: 'America/Toronto',
    timeoutSeconds: 120,
    memory: '512MiB',
    retryCount: 0,
  },
  async () => {
    const now = Timestamp.now();
    // Берём все pending — фильтр по sendAt делаем в коде, чтобы не требовать составной индекс
    const pendingQuery = scheduledMessagesRef
      .where('status', '==', 'pending')
      .limit(50);
    let query = pendingQuery;
    let scanned = 0;
    const due = [];
    while (due.length < 50) {
      const snapshot = await query.get();
      scanned += snapshot.size;
      for (const doc of snapshot.docs) {
        const sendAt = doc.data().sendAt?.toDate?.();
        if (sendAt && sendAt <= now.toDate()) due.push(doc);
        if (due.length >= 50) break;
      }
      if (snapshot.size < 50 || due.length >= 50) break;
      query = pendingQuery.startAfter(snapshot.docs[snapshot.docs.length - 1]);
    }
    console.log(`processScheduledMessages: scanned=${scanned}, due=${due.length}`);
    if (!due.length) return;

    for (const doc of due) {
      // Атомарно захватить документ — чтобы не отправить дважды при повторе
      let data;
      try {
        data = await db.runTransaction(async (tx) => {
          const fresh = await tx.get(doc.ref);
          if (!fresh.exists) return null;
          const current = fresh.data();
          const sendAt = current.sendAt?.toDate?.();
          if (current.status !== 'pending' || !sendAt ||
              !Number.isFinite(sendAt.getTime()) || sendAt > now.toDate()) return null;
          tx.update(doc.ref, { status: 'sending' });
          return current;
        });
      } catch (error) {
        console.warn('processScheduledMessages: claim failed', doc.id, error.message);
        continue;
      }
      if (!data) continue;

      try {
        if (data.channel === 'sms') {
          await sendScheduledSms(data);
        } else if (data.channel === 'email') {
          await emailHandlers.sendEmailDirect({
            to: String(data.toEmail || ''),
            body: String(data.body || ''),
            bodyRu: String(data.bodyRu || ''),
            clientId: data.clientId || null,
            subject: String(data.subject || ''),
            mediaUrls: Array.isArray(data.mediaUrls) ? data.mediaUrls : [],
          });
        } else {
          throw new Error('Unsupported scheduled message channel');
        }
        await doc.ref.update({
          status: 'sent',
          sentAt: FieldValue.serverTimestamp(),
        });
      } catch (error) {
        console.error('processScheduledMessages: failed to send', doc.id, error.message);
        await doc.ref.update({
          status: 'failed',
          errorMsg: String(error.message || '').slice(0, 500),
        });
      }
    }
  }
);

const secretaryLearn = require('./secretary_learn')({
  db,
  COMPANY_ID,
  extractJsonObject,
  generateContentWithModelFallback,
  notifyMaster,
  callsRef,
  FieldValue: FieldValue,
});
secretaryLearnApi.proposeFromCall = secretaryLearn.proposeFromCall;

exports.secretaryLearningDigest = functions.scheduler.onSchedule(
  {
    schedule: 'every monday 09:00',
    timeZone: 'America/Toronto',
    timeoutSeconds: 60,
    memory: '256MiB',
    retryCount: 0,
  },
  async () => {
    await secretaryLearn.weeklyDigest();
  }
);

// ============================================================================
// Копия базы в облако раз в неделю
// ============================================================================

const cloudBackup = require('./backup');

/// Куда ещё уходит копия, кроме Storage: почта мастерской (BACKUP_EMAIL, по
/// умолчанию — сам подключённый Gmail) и Telegram-бот, если заданы его ключи.
function backupSenders() {
  const senders = {
    email: ({ fileName, content, caption }) =>
      createEmailModule.sendOwnerFile({
        to: process.env.BACKUP_EMAIL,
        subject: caption,
        text: 'Резервная копия базы FIX CRM во вложении (сжатый JSON). Та же копия лежит в Firebase Storage.',
        fileName,
        content,
      }),
  };
  const token = (process.env.TELEGRAM_BOT_TOKEN || '').trim();
  const chatId = (process.env.TELEGRAM_CHAT_ID || '').trim();
  if (token && chatId) {
    senders.telegram = (file) => cloudBackup.sendTelegramDocument({ token, chatId, ...file });
  }
  return senders;
}

exports.weeklyCloudBackup = functions.scheduler.onSchedule(
  {
    schedule: 'every sunday 03:30',
    timeZone: 'America/Toronto',
    timeoutSeconds: 540,
    memory: '1GiB',
    retryCount: 1,
  },
  async () => {
    const result = await cloudBackup.runCloudBackup({
      db,
      companyId: COMPANY_ID,
      senders: backupSenders(),
    });
    if (!result) console.error('weeklyCloudBackup: копия не сохранилась');
    await cloudBackup.pruneAppErrors(db, COMPANY_ID);
  }
);

// ============================================================================
// Журнал ошибок приложения — чтобы агент в Cursor читал их сам
// ============================================================================

/// GET /appErrors?limit=40 — последние сбои телефона обычным текстом.
exports.appErrors = onRequestV2(
  { timeoutSeconds: 60, memory: '256MiB', invoker: 'public' },
  async (req, res) => {
    if (handleOptions(req, res)) return;
    setCors(res);
    if (!(await requireAppUser(req, res))) return;
    try {
      const limit = Math.min(Number(req.query.limit) || 40, 200);
      const snapshot = await db
        .collection('companies')
        .doc(COMPANY_ID)
        .collection('app_errors')
        .get();
      const items = snapshot.docs
        .map((doc) => ({ id: doc.id, ...doc.data() }))
        .filter((item) => item.at)
        .sort((a, b) => String(b.at).localeCompare(String(a.at)))
        .slice(0, limit);

      if (String(req.query.format || 'text') === 'json') {
        res.json({ success: true, count: items.length, items });
        return;
      }
      const lines = items.map((item) => {
        const head = [item.at, item.kind, item.screen, item.version]
          .filter(Boolean)
          .join(' | ');
        return [head, item.message, item.stack].filter(Boolean).join('\n');
      });
      res.set('Content-Type', 'text/plain; charset=utf-8');
      res.send(lines.join('\n---\n') || 'нет ошибок');
    } catch (error) {
      console.error('appErrors:', error);
      res.status(500).send(`error: ${error.message}`);
    }
  }
);

/// Кнопка «В облако сейчас» на экране «Копия».
exports.runCloudBackupNow = onRequestV2(
  { timeoutSeconds: 540, memory: '1GiB', invoker: 'public' },
  async (req, res) => {
    if (handleOptions(req, res)) return;
    setCors(res);
    if (!(await requireAppUser(req, res))) return;
    try {
      const result = await cloudBackup.runCloudBackup({
        db,
        companyId: COMPANY_ID,
        senders: backupSenders(),
      });
      if (!result) {
        res.status(500).json({ success: false, error: 'backup failed' });
        return;
      }
      res.json({ success: true, ...result });
    } catch (error) {
      console.error('runCloudBackupNow:', error);
      res.status(500).json({ success: false, error: error.message });
    }
  }
);

exports.secretaryOwnerTurn = functions.https.onRequest(
  { timeoutSeconds: 90, memory: '512MiB', invoker: 'public' },
  async (req, res) => {
    if (handleOptions(req, res)) return;
    setCors(res);
    if (!(await requireAppUser(req, res))) return;
    const payload = req.body || {};
    const mode = String(payload.mode || 'setup') === 'test' ? 'test' : 'setup';
    const userText = String(payload.text || '').trim();
    const history = Array.isArray(payload.history) ? payload.history.slice(-20) : [];
    if (!userText) {
      res.status(400).json({ error: 'text required' });
      return;
    }
    try {
      const voiceSnap = await db
        .collection('companies')
        .doc(COMPANY_ID)
        .collection('settings')
        .doc('ai_voice')
        .get();
      const voice = voiceSnap.exists ? voiceSnap.data() || {} : {};
      let ownerBrief = String(voice.ownerBrief || '').trim().slice(0, 1800);
      const ai = await getAiAnswerSettings();
      const prompt =
        mode === 'test'
          ? `You are the FixApplianceCA phone secretary on a TEST call. The shop owner is pretending to be a client.
Speak English only. One or two short spoken sentences. Same rules as a live call.
${ai.instructions}
Owner notes:\n${ownerBrief || '(none)'}
Recent turns: ${JSON.stringify(history)}
Client just said: ${userText}
Return STRICT JSON: {"say":"your spoken English reply"}`
          : `You help FIX, the shop owner, set up the phone secretary. Answer in Russian, like a colleague in chat.
Current live rules are already on the server (hours, calendar, no hangup, English on the phone).
Saved owner notes now:\n${ownerBrief || '(пусто)'}
If FIX gives a new rule, merge it into ownerBrief (English, short bullets, max 1800 characters). Do not repeat hours/calendar unless he changes them. If he asks to clear notes, ownerBrief="".
Recent chat: ${JSON.stringify(history)}
FIX: ${userText}
Return STRICT JSON: {"say":"ответ по-русски","ownerBrief":"updated notes or the same notes"}`;

      const result = await generateContentWithModelFallback([{ text: prompt }]);
      let raw = String((result.response && result.response.text()) || '').trim();
      if (raw.startsWith('```json')) raw = raw.slice(7);
      else if (raw.startsWith('```')) raw = raw.slice(3);
      if (raw.endsWith('```')) raw = raw.slice(0, -3);
      const parsed = extractJsonObject(raw.trim()) || {};
      const say = String(parsed.say || '').trim() || (mode === 'test' ? 'Go ahead.' : 'Хорошо.');
      if (mode === 'setup' && Object.prototype.hasOwnProperty.call(parsed, 'ownerBrief')) {
        ownerBrief = String(parsed.ownerBrief || '').trim().slice(0, 1800);
        await db
          .collection('companies')
          .doc(COMPANY_ID)
          .collection('settings')
          .doc('ai_voice')
          .set(
            {
              ownerBrief,
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
      }
      res.json({ say, ownerBrief, mode });
    } catch (error) {
      console.error('secretaryOwnerTurn:', error);
      res.status(500).json({ error: error.message });
    }
  }
);
