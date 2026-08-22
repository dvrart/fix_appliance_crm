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
const voiceFacts = require('./voice_facts');
const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');
const visitSms = require('./visit_sms');
const schedule = require('./schedule');

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
const secretaryLearnApi = {
  proposeFromCall: async () => {},
};
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
      if (voiceFacts.phonesOfClient(data).has(normalized)) {
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
      const data = doc.data() || {};
      const emails = [data.email];
      for (const location of data.locations || []) {
        emails.push(location.email);
        for (const contact of location.contacts || []) {
          emails.push(contact.email);
        }
      }
      if (emails.some((value) => String(value || '').trim().toLowerCase() === normalized)) {
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

function tenantContactFromExtracted(extracted) {
  const name = String((extracted && extracted.contact_on_site_name) || '').trim();
  const phone = normalizePhone(extracted && extracted.contact_on_site_phone);
  return {
    id: 'tenant',
    name: name || 'Tenant',
    phone: phone || '',
    role: 'tenant',
    isPrimary: true,
  };
}

function jobSiteLocationFromExtracted(extracted, ownerName, ownerPhone) {
  const street = String((extracted && extracted.address) || '').trim();
  const city = String((extracted && extracted.city) || '').trim();
  const postal = String((extracted && extracted.postal_code) || '').trim();
  const contacts = [tenantContactFromExtracted(extracted)];
  if (ownerName || ownerPhone) {
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
  const tenant = tenantContactFromExtracted(extracted);

  if (matchIdx >= 0) {
    const loc = locations[matchIdx];
    const contacts = Array.isArray(loc.contacts) ? [...loc.contacts] : [];
    const tenantIdx = contacts.findIndex((c) => String(c.role || '') === 'tenant');
    if (tenantIdx >= 0) {
      contacts[tenantIdx] = {
        ...contacts[tenantIdx],
        ...tenant,
        id: contacts[tenantIdx].id || 'tenant',
      };
    } else {
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
      lastActiveAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

function parseScheduledAt(extracted) {
  const date = voiceFacts.parseScheduledAtDate(extracted);
  return date ? admin.firestore.Timestamp.fromDate(date) : null;
}

function jobFillScore(data) {
  const job = data || {};
  let score = 0;
  const name = String(job.clientName || '').trim();
  if (name && name !== 'Клиент' && !/^Клиент\s+\d/.test(name)) score += 4;
  if (String(job.clientAddress || '').trim()) score += 3;
  const type = String(job.applianceType || '').trim();
  if (type && type !== 'Техника') score += 3;
  if (String(job.description || '').trim()) score += 2;
  if (String(job.brand || '').trim()) score += 1;
  const visits = Array.isArray(job.visits) ? job.visits : [];
  if (visits.length || job.scheduledAt || job.scheduledDate) score += 1;
  return score;
}

async function findJobsBySourceCall(callId) {
  if (!callId) return [];
  const snap = await jobsRef.where('sourceCallId', '==', callId).limit(10).get();
  return snap.docs;
}

async function mergeDuplicateSourceCallJobs(callId, keepId) {
  const docs = await findJobsBySourceCall(callId);
  for (const doc of docs) {
    if (doc.id === keepId) continue;
    if (jobFillScore(doc.data() || {}) > 4) continue;
    console.log(`mergeDuplicateSourceCallJobs: удаляю пустую ${doc.id}, оставляю ${keepId}`);
    await doc.ref.delete().catch((error) => {
      console.warn('mergeDuplicateSourceCallJobs delete:', error.message);
    });
  }
}

async function claimOrReuseCallJob(callId) {
  const existing = await findJobsBySourceCall(callId);
  if (existing.length) {
    existing.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
    const keep = existing[0];
    const data = keep.data() || {};
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
    if (data.createdJobId) {
      return {
        jobId: data.createdJobId,
        clientId: data.clientId || null,
        existed: true,
      };
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
  updates.lastActiveAt = admin.firestore.FieldValue.serverTimestamp();
  await clientsRef.doc(clientId).set(updates, { merge: true });
}

/**
 * После разбора звонка создаёт (или находит) клиента и черновик заявки.
 * Заявка помечается needsReview, чтобы мастер проверил её в приложении.
 */
async function createDraftJobFromCall(callId, extracted, existingClient) {
  const callSnap = await callsRef.doc(callId).get();
  const callData = callSnap.exists ? callSnap.data() || {} : {};

  extracted = voiceFacts.enrichExtracted(
    extracted,
    (callData.aiReception || {}).history,
    callData.transcription
  );

  const claimed = await claimOrReuseCallJob(callId);
  if (claimed.existed && claimed.jobId) {
    const existingJob = await jobsRef.doc(claimed.jobId).get();
    if (existingJob.exists) {
      await patchDraftJobFromCall(claimed.jobId, extracted);
      return {
        jobId: claimed.jobId,
        clientId: claimed.clientId || existingJob.data().clientId || null,
      };
    }
  }

  const phone =
    normalizePhone(extracted.client_phone) ||
    normalizePhone(callData.direction === 'inbound' ? callData.fromNumber : callData.toNumber);

  let clientId = existingClient && existingClient.id;
  let extractedName = voiceFacts.usableClientName(
    (extracted && extracted.client_name) || ''
  );
  const existingRealName = voiceFacts.usableClientName(
    (existingClient && (existingClient.fullName || existingClient.name)) || ''
  );
  let clientName =
    extractedName ||
    existingRealName ||
    (phone ? `Клиент ${phone}` : 'Клиент');
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
    const locationContacts = isJobSiteExtract(extracted)
      ? [
          {
            id: 'owner',
            name: clientName,
            phone: phone || '',
            role: 'owner',
            isPrimary: false,
          },
          tenantContactFromExtracted(extracted),
        ]
      : [
          {
            id: 'owner',
            name: clientName,
            phone: phone || '',
            role: 'owner',
            isPrimary: true,
          },
        ];
    const clientDoc = await clientsRef.add({
      fullName: clientName,
      phone: phone || '',
      address: isJobSiteExtract(extracted)
        ? String(extracted.owner_address || '').trim() || ''
        : address,
      locations: [
        {
          id: isJobSiteExtract(extracted) ? `site_${Date.now()}` : 'primary',
          street,
          city,
          postalCode: postal,
      notes: isJobSiteExtract(extracted) ? 'Job site' : '',
          contacts: locationContacts,
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
    if (extractedName) {
      await applyPersonNameToClient(clientId, extractedName);
    }
    if (address && !existingClient.address && !isJobSiteExtract(extracted)) {
      updates.address = address;
    }
    await clientsRef.doc(clientId).set(updates, { merge: true });
    await upsertClientJobSite(clientId, existingClient, extracted, clientName, phone);
  }

  const applianceType = (extracted.appliance_type && String(extracted.appliance_type).trim()) || 'Техника';
  const brand = (extracted.brand && String(extracted.brand).trim()) || '';
  const model = (extracted.model && String(extracted.model).trim()) || '';
  const issueParts = [
    extracted.problem_description && String(extracted.problem_description).trim(),
    extracted.wants_callback === true ? 'Клиент просит, чтобы перезвонил мастер' : '',
  ].filter(Boolean);
  const issue = issueParts.join('\n');
  const resolved = await resolveJobSchedule(extracted);
  const scheduleFields = resolved.fields;
  let reviewNotes = String((extracted && extracted.review_notes) || '').trim();
  if (resolved.blocked) {
    reviewNotes = [reviewNotes, schedule.reviewNote(resolved.blocked)].filter(Boolean).join('\n');
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
  await jobRef.set({
    clientId,
    clientName,
    clientPhone: phone || '',
    clientAddress: ownerAddress || workAddress,
    hasJobSite: jobSite,
    jobSiteName: jobSite
      ? String(extracted.contact_on_site_name || '').trim() || null
      : null,
    jobSitePhone: jobSite
      ? normalizePhone(extracted.contact_on_site_phone) || null
      : null,
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
    description: issue,
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
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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

  return { jobId: jobRef.id, clientId };
}

async function patchDraftJobFromCall(jobId, extracted) {
  if (!jobId || !extracted) return;
  const snap = await jobsRef.doc(jobId).get();
  if (!snap.exists) return;
  const job = snap.data() || {};
  const updates = {};
  const visits = Array.isArray(job.visits) ? job.visits : [];
  if (!job.scheduledAt && !job.scheduledDate && visits.length === 0) {
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
  const name = voiceFacts.usableClientName(extracted.client_name);
  if (
    name &&
    (!job.clientName ||
      voiceFacts.isPlaceholderClientName(job.clientName) ||
      voiceFacts.looksLikeGarbageName(job.clientName))
  ) {
    updates.clientName = name;
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
  const issue = String(extracted.problem_description || '').trim();
  if (issue && !String(job.description || '').trim()) {
    updates.description = issue;
  }
  const phone = normalizePhone(extracted.client_phone);
  if (phone && !String(job.clientPhone || '').trim()) {
    updates.clientPhone = phone;
  }
  if (isJobSiteExtract(extracted)) {
    updates.hasJobSite = true;
    const tenantName = String(extracted.contact_on_site_name || '').trim();
    const tenantPhone = normalizePhone(extracted.contact_on_site_phone);
    if (tenantName && !String(job.jobSiteName || '').trim()) {
      updates.jobSiteName = tenantName;
    }
    if (tenantPhone && !String(job.jobSitePhone || '').trim()) {
      updates.jobSitePhone = tenantPhone;
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
  }
  if (!Object.keys(updates).length) {
    const spoken = name || voiceFacts.usableClientName(job.clientName);
    if (spoken && job.clientId) await applyPersonNameToClient(job.clientId, spoken);
    return;
  }
  updates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
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
      transcription: (function pickTranscript() {
        const nextT = String(next.transcription || '');
        const prevT = String(prev.transcription || '');
        if (speakerCount(nextT) >= 2 && speakerCount(prevT) < 2) return nextT;
        if (speakerCount(prevT) >= 2 && speakerCount(nextT) < 2) return prevT;
        return nextT.length >= prevT.length ? nextT : prevT;
      })(),
      summary: next.summary || prev.summary || '',
    };
  } else {
    attachments.push(next);
  }
  await jobsRef.doc(jobId).set(
    {
      attachments,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
  let russian = hasCyrillic(raw) ? relabelTranscript(raw, answeredBy) : '';
  let english = raw;
  let summary = '';
  if (raw.length > 20) {
    try {
      const shopRu = shopSpeaker(answeredBy, 'ru');
      const result = await generateContentWithModelFallback([
        {
          text: `Переведи этот ПОЛНЫЙ телефонный разговор на русский. Сохрани каждую реплику, тот же порядок, те же говорящие (${shopRu}: / Клиент:). Ничего не сокращай и не выкидывай конец. Потом краткое резюме на 2–4 предложения.

Разговор:
${raw}

Верни СТРОГО JSON:
{"transcription_ru":"...полный текст...","summary":"..."}`,
        },
      ]);
      let text = (result.response.text() || '').trim();
      if (text.startsWith('```json')) text = text.slice(7);
      else if (text.startsWith('```')) text = text.slice(3);
      if (text.endsWith('```')) text = text.slice(0, -3);
      const parsed = extractJsonObject(text.trim()) || {};
      const nextRu = relabelTranscript(
        String(parsed.transcription_ru || parsed.transcription || '').trim(),
        answeredBy
      );
      if (nextRu && nextRu.length >= raw.length * 0.7) russian = nextRu;
      if (parsed.summary) summary = String(parsed.summary).trim();
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
    transcription: pickLongestTranscript(raw, russian, english),
    transcriptionRu: russian,
    transcriptionEn: english || raw,
    answeredBy: answeredBy || '',
    history,
    summary,
  });
  await callsRef.doc(callId).set(
    {
      playableUrl,
      transcription: pickLongestTranscript(raw, russian),
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

function isTwilioMediaUrl(url) {
  return /twilio\.com/i.test(String(url || ''));
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

async function cacheRecordingToStorage(callId, buffer) {
  if (!callId || !buffer || !buffer.length) return null;
  try {
    const project =
      process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
    const bucket = admin.storage().bucket(`${project}.firebasestorage.app`);
    const path = `companies/${COMPANY_ID}/calls/${callId}.mp3`;
    const token = crypto.randomUUID();
    await bucket.file(path).save(buffer, {
      resumable: false,
      metadata: {
        contentType: 'audio/mpeg',
        metadata: { firebaseStorageDownloadTokens: token },
      },
    });
    const encoded = encodeURIComponent(path);
    const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encoded}?alt=media&token=${token}`;
    await callsRef.doc(callId).set({ storageUrl: url }, { merge: true });
    return url;
  } catch (error) {
    console.warn('cacheRecordingToStorage:', error.message);
    return null;
  }
}

async function downloadRecordingBuffer(recordingUrl) {
  const raw = String(recordingUrl || '').trim();
  const urls = [];
  if (raw) urls.push(raw);
  if (raw && isTwilioMediaUrl(raw) && !/\.mp3(\?|$)/i.test(raw)) {
    urls.push(`${raw.replace(/\/$/, '')}.mp3`);
  }
  let lastError;
  for (const url of urls) {
    const headers = {};
    if (isTwilioMediaUrl(url) && REST_AUTH_USER && REST_AUTH_SECRET) {
      headers.Authorization =
        'Basic ' + Buffer.from(`${REST_AUTH_USER}:${REST_AUTH_SECRET}`).toString('base64');
    }
    for (let attempt = 1; attempt <= 5; attempt++) {
      const response = await fetch(url, { headers, redirect: 'follow' });
      if (response.ok) {
        const buffer = Buffer.from(await response.arrayBuffer());
        const head = buffer.slice(0, 16).toString('utf8');
        if (/^\s*</.test(head) || /Not Found|Unauthorized/i.test(head)) {
          lastError = new Error(`Запись не аудио (${url})`);
          break;
        }
        return buffer;
      }
      lastError = new Error(`Не удалось скачать запись (HTTP ${response.status})`);
      await new Promise((resolve) => setTimeout(resolve, 1500 * attempt));
    }
  }
  throw lastError || new Error('Не удалось скачать запись');
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

const DEFAULT_VOICE_GREETING = "Hi, you've reached FIX Appliance. How can I help?";

const STALE_VOICE_GREETINGS = [
  "Hi, you've reached {company}. How can I help?",
  "Hi, you've reached {company}. How can I help you today?",
  "Hi, you've reached {company}. I can take your repair details. How can I help you today?",
  "Hi, you've reached {company}. The technician's with a customer, but I can take your details. What's going on?",
  'Hi, FIX ApplianceCA. How can I help you?',
  'Hi, FIX Appliance. How can I help you?',
  'Hi, FIX Appliance. How can I help?',
  'Hi, FIX Appliance. How can I help? Чем могу помочь?',
];

const OWNER_EXTRA_RULES_EN = `Sunday is closed. Do not book Sunday.
Saturday: do not put a visit on the calendar. Say a technician will contact them and arrange a time if he can.
Price: do not mention $99 unless they asked. If they asked: a service call is $99. If they approve the repair after diagnosis, they do not pay the service call — only the repair.
If the appliance is at another house: keep their home address, take the repair address, who will be there, and that person's phone.
Near the end, if they can, they may text this number a photo or the text of the model-number sticker. Optional — do not stall the call.`;

const DEFAULT_VOICE_INSTRUCTIONS = `Tone: friendly and professional. Listen first. Do not run a survey.

Short turns: one sentence, then wait. Do not fill silence with extra questions. If they already told you something, do not ask it again.

Book visits Monday–Friday, 7 a.m. to 9 p.m. America/Toronto. Same-day is OK if it is still in those hours.
Each visit is 2 hours — one job in that window. Never confirm a time if that 2-hour window is taken. Offer another time the same day first, then another weekday.
Saturday: do not book. Say a technician will contact them and set a time if he can.
Sunday: closed. Do not book Sunday.
If they call at night or on Sunday: still answer. Only offer visits Monday–Friday 7 a.m. to 9 p.m.
If they want 6 a.m. or after 9 p.m.: do not book it. Say we don't work then. Offer another weekday or a time in those hours.

Collect naturally, without interrogating: first name, what broke, appliance kind and brand, repair address, and a day and time if booking a weekday visit.
If the appliance is at another house: take that address, who will be there, and that phone. Keep the client's home. Do not hang up.
Do not grill for model or serial. At the end, optionally ask them to text this number a photo or the text of the model-number sticker. Do not stall the call for it.

If they want a live person: do not grill for a visit time. Say a technician will call back within 30 minutes. Pass the details along.

Household appliances only. We do not repair laptops, computers, phones, TVs, or cars.

After you confirm, stay on the line. Do not say goodbye. Do not hang up. The caller hangs up.

Do not bring up price. If they asked: a service call is $99. If they approve the repair after diagnosis, they do not pay the service call — only the repair.

If the caller is angry: stay calm. Say a company employee will contact them within 30 minutes. Then wait. Do not hang up for them.

Spoken language: English only. Understand any language, including Russian, but always answer in English.`;

const VOICE_MODEL_CANDIDATES = [
  'gemini-flash-lite-latest',
  'gemini-flash-latest',
  'gemini-2.5-flash',
  'gemini-3.6-flash',
];

function describeServiceArea(config) {
  return String((config && config.serviceAreaLabel) || '').trim();
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

function stripServiceAreaLines(text) {
  return String(text || '')
    .split('\n')
    .filter((line) => !/^\s*(зона\b|service area\b)/i.test(line.trim()))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function withMappedServiceArea(instructions, serviceArea) {
  const base = stripServiceAreaLines(instructions) || DEFAULT_VOICE_INSTRUCTIONS;
  const area = String(serviceArea || '').trim();
  if (!area) {
    return `${base}\n\nService area map is not set. Do not refuse a caller based on town names from memory.`;
  }
  return `${base}\n\nService area (from Settings → Service area map): ${area}. If the caller is clearly outside this area, politely say we do not travel there, set done=true and createJob=false.`;
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
    const companyName = String(docs.companyName || '').trim() || 'Fix Appliance';
    const staleGreeting =
      voiceFacts.isStaleVoiceGreeting(greeting) || STALE_VOICE_GREETINGS.includes(greeting);
    const nextGreeting = !greeting || staleGreeting ? DEFAULT_VOICE_GREETING : greeting;
    const serviceArea = describeServiceArea(config);
    const hours = describeWorkHours(config);
    const extraSaved = String(voice.extraRules || '').trim();
    const extra =
      Number(voice.briefVersion) === 1
        ? extraSaved || OWNER_EXTRA_RULES_EN
        : OWNER_EXTRA_RULES_EN;
    if (Number(voice.briefVersion) !== 1 || staleGreeting) {
      db.collection('companies')
        .doc(COMPANY_ID)
        .collection('settings')
        .doc('ai_voice')
        .set(
          {
            greeting: nextGreeting,
            extraRules: Number(voice.briefVersion) === 1 ? extraSaved : OWNER_EXTRA_RULES_EN,
            briefVersion: 1,
            rulesVersion: 10,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        )
        .catch((error) => console.warn('work hours migrate:', error.message));
    }
    const learned = Array.isArray(voice.learnedRules) ? voice.learnedRules : [];
    const learnedLines = learned
      .map((item) => {
        if (!item) return '';
        if (typeof item === 'string') return item.trim();
        return String(item.ruleEn || '').trim();
      })
      .filter(Boolean);
    let nextInstructions = withMappedServiceArea(DEFAULT_VOICE_INSTRUCTIONS, serviceArea);
    if (extra) {
      nextInstructions += `\n\nOwner extra rules:\n${extra}`;
    }
    nextInstructions +=
      `\n\nShop hours: Monday–Friday ${hours.label} America/Toronto. Saturday: do not book, technician will follow up. Sunday: closed. If they want a visit before ${voiceFacts.formatHour12(hours.startMinutes)} or after ${voiceFacts.formatHour12(hours.endMinutes)}, do not book it.`
      + '\n\nCalendar: each visit is 2 hours. Never confirm a taken window. If the time they want overlaps another job, offer another time the same day first.'
      + '\n\nSpoken language lock: Always speak English on the phone. Understand Russian or any other language, but never answer in it. JSON "language" is always "en".';
    if (learnedLines.length) {
      nextInstructions += `\n\nOwner-approved habits. Use them only if they fit what the caller already said. Never interrupt to grill.\n${learnedLines.map((line) => `- ${line}`).join('\n')}`;
    }
    return {
      enabled: config.aiAnswerEnabled !== false,
      timeoutSeconds: Number.isFinite(timeout)
        ? Math.min(60, Math.max(0, Math.round(timeout)))
        : 20,
      companyName,
      greeting: nextGreeting,
      serviceArea,
      workHours: hours.label,
      workStartMinutes: hours.startMinutes,
      workEndMinutes: hours.endMinutes,
      instructions: nextInstructions,
    };
  } catch (_) {
    return {
      enabled: true,
      timeoutSeconds: 20,
      companyName: 'Fix Appliance',
      greeting: DEFAULT_VOICE_GREETING,
      serviceArea: '',
      workHours: voiceFacts.workHoursSpeech(7 * 60, 21 * 60),
      workStartMinutes: 7 * 60,
      workEndMinutes: 21 * 60,
      instructions: withMappedServiceArea(DEFAULT_VOICE_INSTRUCTIONS, ''),
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
    timeout: timeoutSeconds > 0 ? timeoutSeconds : 20,
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

async function consumePendingOutboundJobId(dest) {
  const ref = db
    .collection('companies')
    .doc(COMPANY_ID)
    .collection('settings')
    .doc('pending_outbound_call');
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
  const jobId = dest ? await consumePendingOutboundJobId(dest) : null;
  console.log(
    `${source}: outbound from=${req.body.From || ''} toParam=${req.body.To || ''} phone=${req.body.phone || ''} dest=${dest || '-'} job=${jobId || '-'}`
  );
  await logCall(callSid, {
    fromNumber: TWILIO_PHONE_NUMBER || '',
    toNumber: dest || '',
    direction: 'outbound',
    status: 'in-progress',
    twilioTime: req.body.Timestamp || req.body.StartTime,
    ...(jobId ? { jobId } : {}),
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
  if (aiSettings.enabled && Number(aiSettings.timeoutSeconds) === 0) {
    console.log(`${source}: AI answers immediately, skip master ring`);
    await startAiReception(req, res, callSid);
    return;
  }
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
      if (callStatus === 'completed') {
        setTimeout(() => {
          recoverCallRecording(callSid).catch((error) => {
            console.warn('recoverCallRecording:', error.message);
          });
        }, 8000);
        setTimeout(() => {
          recoverCallRecording(callSid).catch((error) => {
            console.warn('recoverCallRecording:', error.message);
          });
        }, 25000);
      }
    }
  } catch (error) {
    console.error('Error updating call status:', error);
  }

  res.type('text/xml');
  res.send('<Response></Response>');
});

const AI_VOICE_MAX_TURNS = 80;
const voiceAiRuntime = { timeoutSeconds: 180, memory: '512MiB', invoker: 'public' };

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
  if (!extracted) return false;
  if (extracted.wants_callback === true) return true;
  const problem = Boolean(extracted.appliance_type || extracted.problem_description);
  const name = Boolean(extracted.client_name);
  const address = Boolean(extracted.address) && extracted.address_uncertain !== true;
  const when = Boolean(extracted.scheduled_date && extracted.scheduled_time);
  return problem && name && address && when;
}

function hasConversationToBook(extracted, callData) {
  if (voiceFacts.isServiceDeclined(extracted, callData)) return false;
  if (hasEnoughForJob(extracted)) return true;
  if (extracted && extracted.wants_callback === true) return true;
  if (callData && callData.aiReception && callData.aiReception.createJob === true) {
    return true;
  }
  const data = extracted && typeof extracted === 'object' ? extracted : {};
  const problem = Boolean(data.appliance_type || data.problem_description);
  const who = Boolean(data.client_name || data.client_phone);
  return problem && who;
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
  const start = parseScheduledAt(extracted);
  if (!start) {
    return { fields: jobScheduleFields(extracted, durationMinutes) };
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
  if (lang === 'en') return master ? 'Master' : 'AI';
  return master ? 'Мастер' : 'ИИ';
}

function relabelTranscript(text, answeredBy) {
  const shopRu = shopSpeaker(answeredBy, 'ru');
  return String(text || '')
    .replace(/^(AI|Assistant|Secretary|Секретарь|ИИ)\s*:/gim, `${shopRu}:`)
    .replace(/^(Master|Technician|Мастер)\s*:/gim, 'Мастер:')
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
  const hasShop = /(^|\n)\s*(ИИ|AI|Assistant|Master|Мастер|Секретарь)\s*:/i.test(raw);
  const hasClient = /(^|\n)\s*(Клиент|Client|User|Caller)\s*:/i.test(raw);
  return (hasShop ? 1 : 0) + (hasClient ? 1 : 0);
}

function pickLongestTranscript(...parts) {
  return parts
    .map((part) => String(part || '').trim())
    .filter(Boolean)
    .sort((a, b) => {
      const speakers = speakerCount(b) - speakerCount(a);
      if (speakers) return speakers;
      return b.length - a.length;
    })[0] || '';
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
    const start = twiml.start();
    start.recording({
      recordingTrack: 'both',
      recordingStatusCallback: recordingUrl(req),
      recordingStatusCallbackEvent: 'completed',
    });
  } catch (error) {
    console.warn('startCallRecordingNoun:', error.message);
  }
}

function scheduleCallRecording(callSid, req) {
  if (!client || !callSid) return;
  setTimeout(() => {
    client
      .calls(callSid)
      .recordings.create({
        recordingChannels: 'dual',
        recordingStatusCallback: recordingUrl(req),
        recordingStatusCallbackEvent: ['in-progress', 'completed'],
      })
      .then((rec) => {
        console.log(`scheduleCallRecording ${callSid} ${rec.sid}`);
        return callsRef.doc(callSid).set(
          { recordingSid: rec.sid, recordingCallSid: callSid },
          { merge: true }
        );
      })
      .catch((error) => {
        console.warn('scheduleCallRecording:', error.message);
      });
  }, 1500);
}

async function recoverCallRecording(callSid) {
  if (!callSid) return;
  const callId = await resolveLoggedCallId(callSid);
  const snap = await callsRef.doc(callId).get();
  const data = snap.exists ? snap.data() || {} : {};
  if (data.storageUrl) return;
  const source = await resolveCallRecordingSource(callId, data);
  if (!source) {
    const found = await findTwilioRecordingMp3(callId);
    if (!found) {
      console.log(`recoverCallRecording: still none for ${callId}`);
      return;
    }
    await callsRef.doc(callId).set(
      {
        twilioRecordingUrl: found,
        recordingUrl: found,
        playableUrl: `${functionUrl({}, 'callRecordingAudio')}?callId=${encodeURIComponent(callId)}`,
      },
      { merge: true }
    );
    if (data.aiStatus !== 'done' && data.aiStatus !== 'processing') {
      processRecordingWithAi(callId, found).catch((error) => {
        console.warn('recoverCallRecording process:', error.message);
      });
    }
    return;
  }
  if (!data.twilioRecordingUrl && !isCallRecordingProxyUrl(source)) {
    await callsRef.doc(callId).set({ twilioRecordingUrl: source }, { merge: true });
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
  return twiml;
}

function twimlGeminiLiveStream(req, { url, callSid }) {
  const twiml = new twilio.twiml.VoiceResponse();
  startCallRecordingNoun(twiml, req);
  const connect = twiml.connect({
    action: functionUrl(req, 'aiRelayComplete'),
  });
  const stream = connect.stream({
    url,
    name: 'gemini-live',
    timeLimit: 3600,
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
    sendTwiml(
      res,
      twimlGatherSpeech(req, {
        say: 'Go ahead.',
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

  const profile = await getAiAnswerSettings();
  const existingClient = await findClientByPhone(data.fromNumber);
  const clientName = voiceFacts.usableClientName(
    existingClient ? existingClient.fullName || existingClient.name || '' : ''
  );
  const dialSeconds = parseInt(req.body.DialCallDuration || req.body.CallDuration, 10) || 0;
  const greeting = data.handoffToAi && dialSeconds > 1
    ? 'The technician had to step away. How can I help?'
    : fillVoiceTemplate(profile.greeting, {
        company: profile.companyName,
        name: firstNameOf(clientName),
      });

  const knownAddress = voiceFacts.clientAddressFrom(existingClient);
  const extracted = {};
  if (clientName) extracted.client_name = clientName;
  if (knownAddress) extracted.address = knownAddress;

  await callRef.set(
    {
      status: 'in-progress',
      answeredBy: 'ai',
      clientId: existingClient ? existingClient.id : data.clientId || null,
      aiReception: {
        history: [{ role: 'assistant', text: greeting }],
        extracted,
        language: 'en',
        turns: 0,
        knownClient: Boolean(existingClient),
        knownAddress,
      },
      transcription: appendTranscript(data.transcription, `AI: ${greeting}`),
    },
    { merge: true }
  );

  try {
    const calledAt = voiceFacts.formatTorontoStamp();
    await notifyMaster(
      'ИИ взял звонок',
      `${data.fromNumber || callSid}\n${calledAt}`,
      {
        type: 'call',
        callSid,
        answeredBy: 'ai',
        calledAt,
      }
    );
  } catch (error) {
    console.warn('startAiReception notify:', error.message);
  }

  const wss = forceGather ? '' : await resolveConversationRelayWss();
  if (wss) {
    if (process.env.USE_CONVERSATION_RELAY === '1') {
      console.log(`startAiReception relay ${callSid} ${wss}`);
      sendTwiml(res, twimlConversationRelay(req, { url: wss, greeting, callSid }));
      scheduleCallRecording(callSid, req);
      return;
    }
    console.log(`startAiReception live ${callSid} ${wss}`);
    sendTwiml(res, twimlGeminiLiveStream(req, { url: wss, callSid }));
    scheduleCallRecording(callSid, req);
    return;
  }

  sendTwiml(res, twimlGatherSpeech(req, { say: greeting, language: 'en' }));
  scheduleCallRecording(callSid, req);
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
  if (declined) {
    updates.serviceDeclined = true;
    updates.reviewed = false;
    updates.aiStatus = 'done';
    updates.extractedData = extracted && typeof extracted === 'object' ? extracted : {};
    const reason = String((extracted && extracted.decline_reason) || '').trim();
    if (reason) updates.declineReason = reason;
    try {
      await notifyMaster(
        'Звонок: заявку не создаём',
        reason || (extracted && extracted.client_name) || callData.fromNumber || '',
        { type: 'call', callSid }
      );
    } catch (error) {
      console.warn('finishAiReception declined notify:', error.message);
    }
  } else if (createJob || hasConversationToBook(extracted, callData)) {
    try {
      const matchedClient = await findClientByPhone(
        (extracted && extracted.client_phone) || callData.fromNumber
      );
      extracted = extracted && typeof extracted === 'object' ? extracted : {};
      if (!extracted.client_phone && callData.fromNumber) {
        extracted.client_phone = normalizePhone(callData.fromNumber);
      }
      extracted = voiceFacts.enrichExtracted(
        extracted,
        (callData.aiReception || {}).history,
        callData.transcription
      );
      const created = await createDraftJobFromCall(callSid, extracted, matchedClient);
      updates.createdJobId = created.jobId || null;
      updates.clientId = created.clientId || (matchedClient ? matchedClient.id : null);
      updates.extractedData = extracted;
      updates.aiStatus = created.jobId ? 'done' : 'none';
      updates.jobId = created.jobId || null;
      if (created.jobId) {
        updates.reviewed = true;
        try {
          const calledAt = voiceFacts.formatTorontoStamp(
            callData.startTime && callData.startTime.toDate
              ? callData.startTime.toDate()
              : new Date()
          );
          await notifyMaster(
            'Заявка с телефона',
            `${extracted.client_name || extracted.appliance_type || callData.fromNumber || ''}\n${calledAt}`,
            { type: 'job', source: 'phone', jobId: created.jobId, callSid, calledAt }
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
  const merged = { ...(callData || {}), ...updates };
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

  if (userText) {
    history.push({ role: 'user', text: userText });
  }

  const prompt = `You are on a live phone call for ${companyName}, a small appliance-repair shop in Ontario, Canada.
The technician didn't pick up. YOU answered. You are a real person in the office — a warm woman, maybe mid-thirties, a little busy, never an IVR, never a chatbot, never a survey.

Caller phone (already known, do not ask for it): ${caller || 'unknown'}
Today (America/Toronto): ${today}
Known CRM client: ${existingName || 'new caller'}
Known address if any: ${existingAddress || 'none'}
Shop hours: ${profile.workHours || '7 a.m. to 9 p.m.'} America/Toronto.

Company rules from the owner (facts and policy — follow these):
${instructions}

${voiceFacts.VOICE_CALL_FLOW}

HOW TO TALK — this is the most important part:
- Speak like a real Ontario phone call. Contractions: "what's", "that's", "you're", "I'll".
- "say" is 1 short sentence, maybe 2. Usually under 16 words. One question only.
- Then STOP. Do not fill silence with extra questions.
- First, briefly react like a human ("oh, the fridge isn't cooling", "okay, Brantford").
- Then ask only the next missing thing, if you still need it.
- If they already told you something, NEVER ask it again.
- Never answer with only "got it" or "I understand".
- Never say: "please provide", "I have noted", "thank you for that information", "how may I assist you", "I am an AI".
- Never list questions. Never sound like a website form.
- If they say the repair is at another address, take that street, keep their home, keep talking. Do not hang up in that moment.
- LIVE CALLBACK: if they want a live person / the technician to call them, do not grill for address or time. Say: "Okay, I'll pass your details along and a technician will call you back shortly."
- If they are angry: stop collecting. Say a person from the company will call within 30 minutes. Then wait. Do not hang up.
- If they want a visit before shop hours or after shop hours (6 a.m., 10 p.m., etc.), do not book it. Say we don't work then and offer another day or a time inside shop hours. Then wait. done=false.
- If we cannot take the job (outside the service area, laptop/computer/phone, they cancel, not a home appliance), say so in one short sentence, set createJob=false, extracted.service_declined=true, extracted.decline_reason to a short English reason. Do not create a repair job. Stay on the line. done=false.
- When you have a name, what broke, where to go, and a day or time in shop hours — or they asked for a callback — confirm once ("I'll pass this to the tech"), createJob=true, then STOP. done=false. Do not say goodbye. Do not hang up.
- done=false. The caller hangs up. If they go quiet after you confirmed, keep waiting.
- Never say bye / goodbye / see you then / have a good day.
- Speak English only. Understand Russian or any other language, but never answer in it.
- "language" in JSON is always "en".
- appliance_type in extracted must be Russian: Холодильник, Стиральная машина, Сушилка, Посудомойка, Плита, Духовка, Микроволновка.
- scheduled_date must be YYYY-MM-DD relative to Today ${today} in America/Toronto. scheduled_time must be HH:mm 24-hour.
- client_name: a normal short name as they said it. Never a phonetic spelling.

Good "say" examples:
- "Oh, the fridge isn't cooling. What brand is it?"
- "Okay Artem — what's the address there?"
- "Paris, perfect. What day works for a tech?"
- "I'll pass this to the tech and he'll call you back to confirm."
- "We don't work at 6 a.m. — we're 7 to 9. Another time after 7, or another day?"

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
    "owner_address": null,
    "appliance_type": null,
    "brand": null,
    "model": null,
    "problem_description": null,
    "scheduled_date": null,
    "scheduled_time": null,
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
    const nextExtracted = mergeExtracted(extracted, parsed.extracted, history);
    return ensureSpokenFarewell(parsed, nextExtracted);
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
        await finishAiReception(
          req,
          res,
          callSid,
          data,
          voiceFacts.farewellFor(reception.extracted, 'en'),
          'en',
          reception.extracted,
          hasEnoughForJob(reception.extracted)
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
    const hangupSay = done && !voiceFacts.saidGoodbye(say)
      ? `${say} ${voiceFacts.farewellFor(extracted, nextLanguage)}`.trim()
      : say;
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
        pendingSpeech: '',
        emptyTurns: 0,
      },
    };

    await callsRef.doc(callSid).set(
      {
        answeredBy: 'ai',
        extractedData: extracted,
        transcription: appendTranscript(nextData.transcription, `AI: ${hangupSay}`),
        aiReception: nextData.aiReception,
      },
      { merge: true }
    );

    if (done) {
      const confirm = hangupSay || voiceFacts.farewellFor(extracted, nextLanguage);
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
    const lastAsst = [...((data.aiReception && data.aiReception.history) || [])]
      .reverse()
      .find((item) => item && item.role === 'assistant');
    const alreadyBye = voiceFacts.saidGoodbye(lastAsst && lastAsst.text);
    if (data.createdJobId) {
      sendTwiml(
        res,
        twimlHangup(alreadyBye ? '' : voiceFacts.farewellFor(extracted, 'en'), 'en')
      );
      return;
    }
    await finishAiReception(
      req,
      res,
      callSid,
      data,
      alreadyBye ? '' : voiceFacts.farewellFor(extracted, 'en'),
      'en',
      extracted,
      createJob,
      { silent: alreadyBye }
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
  torontoTodayYmd: voiceFacts.torontoTodayYmd,
  calendarBrief: () => schedule.calendarBrief(),
  checkBookingSlot: (start, opts) => schedule.checkSlot(start, opts),
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
    if (duration === 0) {
      console.log(`Recording complete ${callId}: duration 0, wait for a longer take`);
      res.status(200).send('OK');
      return;
    }
    const existing = await callsRef.doc(callId).get();
    const prevDur = Number((existing.exists && existing.data() && existing.data().recordingDurationSeconds) || 0);
    if (prevDur > duration) {
      console.log(`Recording complete ${callId}: keep longer recording ${prevDur}s > ${duration}s`);
      res.status(200).send('OK');
      return;
    }
    const mp3Url = `${recordingUrl}.mp3`;
    await callsRef.doc(callId).set(
      {
        recordingUrl: mp3Url,
        twilioRecordingUrl: mp3Url,
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

// Аудиозапись без Twilio-логина: приложение открывает эту ссылку.
exports.callRecordingAudio = onRequestV2(
  {
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '1GiB',
    invoker: 'public',
    cors: true,
  },
  async (req, res) => {
    setCors(res);
    if (handleOptions(req, res)) return;
    const requested = String(req.query.callId || req.body.callId || '').trim();
    if (!requested) {
      res.status(400).send('callId required');
      return;
    }
    try {
      const callId = await resolveLoggedCallId(requested);
      const snap = await callsRef.doc(callId).get();
      if (!snap.exists) {
        const sourceOnly = await findTwilioRecordingMp3(requested);
        if (!sourceOnly) {
          res.status(404).send('not found');
          return;
        }
        const buffer = await downloadRecordingBuffer(sourceOnly);
        res.set('Content-Type', 'audio/mpeg');
        res.set('Content-Length', String(buffer.length));
        res.set('Accept-Ranges', 'bytes');
        res.set('Content-Disposition', 'inline; filename="call.mp3"');
        res.status(200).send(buffer);
        return;
      }
      const data = snap.data() || {};
      const source = await resolveCallRecordingSource(callId, data);
      if (!source) {
        res.status(404).send('no recording');
        return;
      }
      const buffer = await downloadRecordingBuffer(source);
      if (!data.storageUrl) {
        cacheRecordingToStorage(callId, buffer).catch((error) => {
          console.warn('callRecordingAudio cache:', error.message);
        });
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
  'gemini-flash-lite-latest',
  'gemini-flash-latest',
  'gemini-2.5-flash',
  'gemini-3.6-flash',
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

function hasCyrillic(text) {
  return /[А-Яа-яЁё]/.test(String(text || ''));
}

function hasLatin(text) {
  return /[A-Za-z]/.test(String(text || ''));
}

function skipTranslate(text) {
  const t = String(text || '').trim();
  if (!t) return true;
  if (t.length < 3 && !hasCyrillic(t)) return true;
  if (/^[\d\s.,:+\-/#]+$/.test(t)) return true;
  if (/^(1|2|0|5|yes|no|ok|ок|да|нет)$/i.test(t.replace(/[.!,]/g, ''))) return true;
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

async function translateChat(text, to) {
  const t = String(text || '').trim();
  if (!t || skipTranslate(t)) return t;
  if (to === 'en' && !hasCyrillic(t)) return t;
  if (to === 'ru' && hasCyrillic(t) && !hasLatin(t)) return t;
  if (to === 'ru' && !hasLatin(t)) return t;
  const isDialogue = /(^|\n)\s*(ИИ|AI|Клиент|Client|User|Assistant)\s*:/i.test(t);
  const instruction =
    to === 'en'
      ? 'Translate the technician message to the client into natural Canadian English. Keep names, addresses, model numbers, and URLs unchanged. Return ONLY the English translation, no quotes or notes.'
      : isDialogue
        ? 'Переведи этот диалог на естественный русский. Сохрани метки говорящих ИИ: и Клиент: на каждой строке. Нельзя выкидывать реплики ИИ. Верни ТОЛЬКО диалог, без кавычек и пояснений.'
        : 'Переведи сообщение клиента мастеру на естественный русский. Имена, адреса, модели и ссылки не меняй. Верни ТОЛЬКО перевод, без кавычек и пояснений.';
  const result = await generateContentWithModelFallback([
    { text: `${instruction}\n\n${t}` },
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

async function selfCheckCallExtract(transcription, extracted, summary) {
  const transcript = String(transcription || '').trim();
  if (transcript.length < 20) return null;
  const prompt = `You are a second-pass checker for an appliance-repair CRM in Ontario.
Compare the transcript with the first-pass JSON. Fix fields that are clearly in the transcript but missing or wrong.
NEVER invent an address, city, postal code, brand, or model.
If the address was mumbled, incomplete, or you would be guessing: address=null, city=null, postal_code=null, address_uncertain=true.
If the name is phonetic garbage, set client_name=null.
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

async function processRecordingWithAiOnce(callId, recordingUrl) {
    const audioBuffer = await downloadRecordingBuffer(recordingUrl);
    const storedUrl = await cacheRecordingToStorage(callId, audioBuffer);
    const audioBase64 = audioBuffer.toString('base64');

    let callerNumber = '';
    let direction = 'inbound';
    let liveHistory = [];
    let liveTranscription = '';
    let answeredBy = '';
    try {
      const callDoc = await callsRef.doc(callId).get();
      const data = callDoc.data() || {};
      direction = data.direction || 'inbound';
      callerNumber =
        direction === 'outbound' ? data.toNumber || '' : data.fromNumber || '';
      liveHistory = (data.aiReception && data.aiReception.history) || [];
      liveTranscription = data.transcription || '';
      answeredBy = String(data.answeredBy || '').trim();
      if (!answeredBy && direction === 'outbound') answeredBy = 'master';
      if (!answeredBy) answeredBy = liveHistory.length ? 'ai' : 'master';
    } catch (_) {}

    const today = voiceFacts.torontoTodayYmd();
    const shopEn = shopSpeaker(answeredBy, 'en');
    const shopRu = shopSpeaker(answeredBy, 'ru');

    const prompt = `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
Прослушай запись телефонного разговора ЦЕЛИКОМ и сделай четыре действия.
Кто говорил со стороны сервиса: ${answeredBy === 'master' ? 'мастер (техник), не ИИ' : 'ИИ-секретарь'}.
1) Полная дословная расшифровка на ЯЗЫКЕ РАЗГОВОРА (обычно английский), ОБЕ стороны, ничего не выкидывай:
${shopEn}: ...
Client: ...
2) Полный перевод того же диалога на русский, те же реплики в том же порядке:
${shopRu}: ...
Клиент: ...
Нельзя оставлять только клиента. Нельзя склеивать реплики. Нельзя обрезать конец разговора.
3) Краткая выжимка на русском: 2–4 предложения (техника, проблема, договорённость).
4) Извлеки структурированные данные для заявки на ремонт.

Известные данные звонка (уже определены системой, не выдумывай другие):
- Сегодняшняя дата (America/Toronto): ${today}
- Номер клиента: ${callerNumber || 'неизвестен'}
- Направление: ${direction === 'outbound' ? 'мастер звонил клиенту' : 'клиент звонил мастеру'}

Правила извлечения:
- client_phone: если клиент не назвал другой номер — обязательно поставь номер клиента (${callerNumber || 'null'}), 10 цифр без пробелов и плюса
- scheduled_date: YYYY-MM-DD. «Завтра»/tomorrow = следующий день от ${today}. Если день не назван — null, не подставляй сегодня просто так
- scheduled_time: HH:MM 24-часа. Если сказали «11:00» или «at 11» — запиши 11:00
- client_name: обычное короткое имя (Artem). Никогда фонетическая транскрипция вроде R Tamiyzhpurush
- address = where the technician drives (repair / job site). city, postal_code only if heard clearly
- owner_address = caller's home if it is a different place from the repair
- Если ремонт не дома у звонящего (аренда, другой дом, another address): has_job_site: true, не затирай домашний адрес владельца
- wants_callback: true, если клиент просил живого человека / мастера перезвонить
- If something was not mentioned, or the call is not about a home-appliance repair we can take, put null
- service_declined=true if we cannot take the job (outside the area, laptop/computer, they cancelled, not our work). Then do not fill a visit.

Return STRICT one JSON object without markdown:
{
  "transcription_en": "полный диалог на языке разговора с метками ${shopEn}: и Client:",
  "transcription_ru": "полный диалог на русском с метками ${shopRu}: и Клиент:",
  "transcription": "то же, что transcription_ru",
  "summary": "краткая выжимка на русском",
  "extracted": {
    "client_name": "Имя клиента (владельца)",
    "client_phone": "Телефон клиента",
    "address": "Адрес ремонта (улица и дом)",
    "city": "Город ремонта",
    "postal_code": "Почтовый индекс",
    "owner_address": "Домашний адрес владельца, если он другой",
    "appliance_type": "Тип техники",
    "brand": "Бренд",
    "model": "Модель",
    "problem_description": "Описание проблемы",
    "scheduled_date": "Дата визита",
    "scheduled_time": "Время визита",
    "wants_callback": false,
    "contact_on_site_name": "Имя контакта на месте (арендатор)",
    "contact_on_site_phone": "Телефон контакта на месте",
    "has_job_site": false,
    "notes": "Дополнительные заметки",
    "service_declined": false,
    "decline_reason": "Why we are not taking the job, English, short"
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
    const liveLabeled = labeledTranscriptFromHistory(
      liveHistory,
      liveTranscription,
      answeredBy
    );
    const fromAudioRu = relabelTranscript(
      parsed.transcription_ru || parsed.transcription || '',
      answeredBy
    );
    const fromAudioEn = String(parsed.transcription_en || '').trim();
    const liveEn = liveHistory.length
      ? liveHistory
          .map((item) => {
            const who = item.role === 'assistant' ? shopEn : 'Client';
            return `${who}: ${item.text}`;
          })
          .join('\n')
      : '';
    const transcription = pickLongestTranscript(
      fromAudioRu,
      fromAudioEn,
      liveLabeled,
      liveTranscription,
      liveEn
    );
    const transcriptionEn = pickLongestTranscript(fromAudioEn, liveEn, liveTranscription, liveLabeled);
    const transcriptionRu = pickLongestTranscript(fromAudioRu, hasCyrillic(transcription) ? transcription : '');
    const summary = String(parsed.summary || '').trim();
    let extracted = voiceFacts.enrichExtracted(
      parsed.extracted || {},
      [{ role: 'user', text: transcription }],
      transcription
    );

    try {
      const reviewed = await selfCheckCallExtract(transcription, extracted, summary);
      if (reviewed && reviewed.extracted) {
        extracted = voiceFacts.mergeExtracted(
          extracted,
          reviewed.extracted,
          [{ role: 'user', text: transcription }]
        );
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

    const matchedClient = await findClientByPhone(
      extracted.client_phone || (await getCallFromNumber(callId))
    );

    const callSnap = await callsRef.doc(callId).get();
    const callData = callSnap.exists ? callSnap.data() || {} : {};
    const declined = voiceFacts.isServiceDeclined(extracted, callData);
    const hasSubstance =
      !declined &&
      Boolean(
        extracted.appliance_type ||
          extracted.problem_description ||
          extracted.wants_callback
      );

    let jobId = callData.jobId || callData.createdJobId || null;
    if (!jobId) {
      const bySource = await findJobsBySourceCall(callId);
      if (bySource.length) {
        bySource.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
        jobId = bySource[0].id;
      }
    }
    if (!jobId && callData.answeredBy === 'ai') {
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
    if (!jobId && callData.answeredBy !== 'ai') {
      const existingJob = await findJobByPhone(
        extracted.client_phone || callerNumber
      );
      if (existingJob && existingJob.id) jobId = existingJob.id;
    }

    if (declined) {
      jobId = null;
    }

    let created = { jobId: jobId || null, clientId: matchedClient ? matchedClient.id : null };
    const existedJob = Boolean(jobId);
    if (!jobId && hasSubstance) {
      try {
        created = await createDraftJobFromCall(callId, extracted, matchedClient);
        jobId = created.jobId || jobId;
        if (!existedJob && created.jobId) {
          try {
            await notifyMaster(
              'Заявка с телефона',
              String(extracted.client_name || extracted.appliance_type || callerNumber || ''),
              { type: 'job', source: 'phone', jobId: created.jobId, callId }
            );
          } catch (error) {
            console.warn('processRecording job notify:', error.message);
          }
        }
      } catch (jobError) {
        console.error(`createDraftJobFromCall(${callId}) failed:`, jobError);
      }
    } else if (jobId && hasSubstance) {
      try {
        await patchDraftJobFromCall(jobId, extracted);
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

    await callsRef.doc(callId).set(
      {
        transcription,
        transcriptionRu: transcriptionRu || transcription,
        transcriptionEn: transcriptionEn || transcription,
        summary,
        extractedData: extracted,
        aiStatus: 'done',
        clientId: created.clientId || (matchedClient ? matchedClient.id : null),
        createdJobId: created.jobId || jobId || null,
        jobId: jobId || null,
        reviewed: Boolean(jobId),
        serviceDeclined: declined,
        declineReason: String(extracted.decline_reason || '').trim() || null,
      },
      { merge: true }
    );

    if (declined && !jobId && callData.serviceDeclined !== true) {
      try {
        await notifyMaster(
          'Звонок: заявку не создаём',
          String(extracted.decline_reason || extracted.client_name || callerNumber || ''),
          { type: 'call', callId }
        );
      } catch (error) {
        console.warn('processRecording declined notify:', error.message);
      }
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
    let recordingUrl = await resolveCallRecordingSource(resolvedId, data);
    if (recordingUrl && recordingUrl !== data.recordingUrl) {
      await callsRef.doc(resolvedId).set(
        { recordingUrl, twilioRecordingUrl: recordingUrl },
        { merge: true }
      );
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

async function recoverJobsMissingVisits(limit = 15) {
  const snap = await jobsRef.orderBy('createdAt', 'desc').limit(80).get();
  const fixed = [];
  for (const doc of snap.docs) {
    if (fixed.length >= limit) break;
    const job = doc.data() || {};
    if (!job.createdByAi && !job.sourceCallId) continue;
    const visits = Array.isArray(job.visits) ? job.visits : [];
    if (visits.length || job.scheduledAt || job.scheduledDate) continue;
    const fields = jobScheduleFields({}, schedule.BOOKING_MINUTES);
    await doc.ref.set(
      {
        ...fields,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    fixed.push(doc.id);
    console.log(`recoverJobsMissingVisits: ${doc.id} ${job.clientName || job.clientPhone || ''}`);
  }
  return fixed;
}

async function recoverAiCallsMissingJobs(limit = 12) {
  const snap = await callsRef.orderBy('startTime', 'desc').limit(80).get();
  const recovered = [];
  for (const doc of snap.docs) {
    if (recovered.length >= limit) break;
    const data = doc.data() || {};
    if ((data.createdJobId || data.jobId) && data.aiStatus === 'done') continue;
    const bySource = await findJobsBySourceCall(doc.id);
    if (bySource.length) {
      bySource.sort((a, b) => jobFillScore(b.data() || {}) - jobFillScore(a.data() || {}));
      const keep = bySource[0];
      await callsRef.doc(doc.id).set(
        {
          createdJobId: keep.id,
          jobId: keep.id,
          clientId: (keep.data() || {}).clientId || data.clientId || null,
          aiStatus: data.aiStatus === 'processing' ? data.aiStatus : 'done',
          reviewed: true,
        },
        { merge: true }
      );
      await mergeDuplicateSourceCallJobs(doc.id, keep.id);
      continue;
    }
    if (data.createdJobId || data.jobId) continue;
    const inbound = data.direction !== 'outbound';
    const answeredAi = data.answeredBy === 'ai';
    const extracted = (data.aiReception && data.aiReception.extracted) || data.extractedData || {};
    if (voiceFacts.isServiceDeclined(extracted, data)) continue;
    const canBook = hasConversationToBook(extracted, data) || Boolean(data.recordingUrl);
    if (!inbound || !answeredAi || !canBook) continue;
    if (Number(data.jobRecoverCount || 0) >= 3) continue;

    await callsRef.doc(doc.id).set(
      { jobRecoverCount: admin.firestore.FieldValue.increment(1) },
      { merge: true }
    );

    if (!data.createdJobId && !data.jobId && data.recordingUrl && data.aiStatus !== 'done') {
      console.log(`recoverAiCallsMissingJobs: запись ${doc.id}`);
      await processRecordingWithAi(doc.id, data.recordingUrl);
      recovered.push(doc.id);
      continue;
    }

    try {
      const matchedClient = await findClientByPhone(extracted.client_phone || data.fromNumber);
      if (!extracted.client_phone && data.fromNumber) {
        extracted.client_phone = normalizePhone(data.fromNumber);
      }
      const created = await createDraftJobFromCall(
        doc.id,
        voiceFacts.enrichExtracted(
          extracted,
          (data.aiReception && data.aiReception.history) || [],
          data.transcription
        ),
        matchedClient
      );
      if (created.jobId) {
        await callsRef.doc(doc.id).set(
          {
            createdJobId: created.jobId,
            jobId: created.jobId,
            clientId: created.clientId || (matchedClient && matchedClient.id) || null,
            aiStatus: 'done',
            reviewed: true,
            extractedData: extracted,
          },
          { merge: true }
        );
        recovered.push(created.jobId);
        console.log(`recoverAiCallsMissingJobs: заявка ${created.jobId} из ${doc.id}`);
      }
    } catch (error) {
      console.warn(`recoverAiCallsMissingJobs ${doc.id}:`, error.message);
    }
  }
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
    await recoverAiCallsMissingJobs(8);
  }
);

exports.recoverStuckCallJobs = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  try {
    const jobs = await recoverJobsMissingVisits(20);
    const calls = await recoverAiCallsMissingJobs(15);
    res.json({ ok: true, jobs, calls });
  } catch (error) {
    console.error('recoverStuckCallJobs:', error);
    res.status(500).json({ error: error.message });
  }
});

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

    const { to, body, clientId, bodyRu } = req.body || {};
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
    let sendBody = body || '';
    let storedRu = typeof bodyRu === 'string' ? bodyRu.trim() : '';
    if (hasCyrillic(sendBody)) {
      storedRu = storedRu || sendBody;
      sendBody = await translateChat(sendBody, 'en');
      if (hasCyrillic(sendBody) && !hasLatin(sendBody)) {
        res.status(500).json({ error: 'Не удалось перевести SMS на английский' });
        return;
      }
    }
    const text = withSmsHeader(sendBody || '', header);
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
      bodyRu: storedRu,
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

exports.translateMessage = functions.https.onRequest(
  { timeoutSeconds: 30, memory: '256MiB', invoker: 'public' },
  async (req, res) => {
    setCors(res);
    if (handleOptions(req, res)) return;
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

  if (!docRef) {
    try {
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
        aiStatus: confirmHandled
          ? 'skipped_confirm'
          : twilioMedia.length || body.trim()
            ? 'processing'
            : 'none',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: confirmHandled,
      });
    } catch (error) {
      console.error('incomingSms save error:', error);
    }
  } else if (confirmHandled) {
    try {
      await docRef.set({ aiStatus: 'skipped_confirm', read: true }, { merge: true });
    } catch (error) {
      console.error('incomingSms confirm mark error:', error);
    }
  }

  if (!alreadyProcessed) {
    try {
      await notifyMaster(title, preview, { type: 'sms', from: from || '' });
    } catch (error) {
      console.error('incomingSms notify error:', error);
    }
  }

  if (docRef && !alreadyProcessed && !confirmHandled && String(body || '').trim()) {
    try {
      const ru = await translateChat(body, 'ru');
      if (ru && ru.trim() && ru.trim() !== String(body).trim()) {
        await docRef.set({ bodyRu: ru.trim() }, { merge: true });
      }
    } catch (error) {
      console.warn('incomingSms translate:', error.message);
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
  const source = String(data.source || '');
  const secretaryAnswered = type === 'call' && String(data.answeredBy || '') === 'ai';
    const channelId =
    type === 'email' ||
    type === 'email_offer' ||
    type === 'shipment' ||
    (type === 'job' && source === 'email')
      ? 'email_messages'
      : type === 'visit_confirm'
        ? 'visit_confirm'
        : type === 'secretary_lesson'
          ? 'secretary_learn'
          : type === 'call' || type === 'job' || secretaryAnswered
            ? 'incoming_calls'
            : 'sms_messages';
  const tag = `crm_${type}_${String(data.from || data.to || 'inbox')}`.slice(0, 50);
  stringData.type = type;
  stringData.tag = tag;
  stringData.title = String(title || '');
  stringData.body = String(body || '');

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
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        priority: 'max',
        visibility: 'public',
      },
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          'interruption-level': 'time-sensitive',
        },
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

async function findOpenJobForContact({ phone, clientId }) {
  const pickLatest = (items) => {
    items.sort((a, b) => {
      const millis = (v) =>
        v && typeof v.toMillis === 'function' ? v.toMillis() : 0;
      return millis(b.createdAt) - millis(a.createdAt);
    });
    const open = items.filter(
      (item) => item.status !== 'Завершено' && item.status !== 'Отменено'
    );
    if (open.length) return open[0];
    return items[0] || null;
  };

  if (clientId) {
    const snap = await jobsRef.where('clientId', '==', clientId).get();
    const items = snap.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
    const picked = pickLatest(items);
    if (picked) return picked;
  }

  const normalized = normalizePhone(phone);
  if (!normalized) return null;
  const snapshot = await jobsRef.get();
  const all = [];
  for (const doc of snapshot.docs) {
    const data = doc.data();
    const phones = [data.clientPhone, data.jobSitePhone].map(normalizePhone);
    if (!phones.includes(normalized)) continue;
    all.push({ id: doc.id, ...data });
  }
  return pickLatest(all);
}

async function findJobByPhone(phone) {
  return findOpenJobForContact({ phone });
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
  const email = String((extracted && extracted.client_email) || fromEmail || '')
    .trim()
    .toLowerCase();
  const name =
    String((extracted && extracted.client_name) || '').trim() ||
    (phone ? `Клиент ${phone}` : email);
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
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      lastActiveAt: admin.firestore.FieldValue.serverTimestamp(),
      createdByAi: true,
      createdFromEmail: true,
    });
    return { id: clientDoc.id, fullName: name, phone, email, address };
  }

  const updates = { lastActiveAt: admin.firestore.FieldValue.serverTimestamp() };
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
}) {
  const messageRef = messagesRef.doc(messageId);
  const existing = await messageRef.get();
  const existingData = existing.exists ? existing.data() || {} : {};
  const messageSid = existingData.sid || '';
  const isIntake = Boolean(intake || existingData.emailIntake);
  const fromIsEmail = String(from || '').includes('@');

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
- Имя, телефон, адрес, город, индекс извлеки, если они есть
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
  "notes": null
}

Письмо: ${body || '(нет текста)'}
Отправитель: ${from || ''}`
    : `Ты — ассистент сервиса по ремонту бытовой техники в Канаде.
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
  const relevant = isIntake
    ? extracted.relevant !== false && hasIntakeLead(extracted)
    : extracted.relevant !== false && hasRepairData(extracted);

  const updates = {
    extractedData: extracted,
    aiStatus: relevant ? 'done' : 'none',
  };

  if (!relevant) {
    await messageRef.set(updates, { merge: true });
    return;
  }

  if (isIntake) {
    updates.emailOfferPending = relevant;
    updates.aiStatus = relevant ? 'offer' : 'none';
    if (clientId) updates.clientId = clientId;
    await messageRef.set(updates, { merge: true });
    if (!relevant) {
      console.log(`Email intake AI skipped (not repair) ${messageId}`);
      return;
    }
    const who =
      String((extracted && extracted.client_name) || clientName || from || '').trim();
    const appliance = String((extracted && extracted.appliance_type) || '').trim();
    try {
      await notifyMaster(
        'Письмо о ремонте',
        [who, appliance, 'Создать клиента и встречу?'].filter(Boolean).join('\n'),
        {
          type: 'email_offer',
          source: 'email',
          messageId,
          from: from || '',
        }
      );
    } catch (error) {
      console.warn('email intake offer notify:', error.message);
    }
    console.log(`Email intake offer ready for ${messageId}`);
    return;
  }

  const fromPhone = fromIsEmail ? '' : from;
  let job = await findOpenJobForContact({ phone: fromPhone, clientId });
  const appliance = mergeAppliance(job && (job.appliances || [])[0], extracted);
  const smsNote = [
    extracted.model ? `Модель: ${extracted.model}` : '',
    extracted.serial_number ? `Серийный номер: ${extracted.serial_number}` : '',
    extracted.brand ? `Бренд: ${extracted.brand}` : '',
  ]
    .filter(Boolean)
    .join('\n');

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
      clientPhone: fromPhone || '',
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
        source: channel === 'email' ? 'email' : 'sms',
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
exports.getStripeBalance = stripeHandlers.getStripeBalance;
exports.createTerminalConnectionToken = stripeHandlers.createTerminalConnectionToken;
exports.createTerminalPaymentIntent = stripeHandlers.createTerminalPaymentIntent;
exports.completeTerminalPayment = stripeHandlers.completeTerminalPayment;
exports.stripeWebhook = stripeHandlers.stripeWebhook;
exports.stripePaymentComplete = stripeHandlers.stripePaymentComplete;
exports.estimateConfirm = require('./estimate_confirm').estimateConfirm;

const expenseHandlers = require('./expenses')({
  setCors,
  handleOptions,
  generateContentWithModelFallback,
});
exports.parseExpenseReceipt = expenseHandlers.parseExpenseReceipt;

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

const secretaryLearn = require('./secretary_learn')({
  db,
  COMPANY_ID,
  extractJsonObject,
  generateContentWithModelFallback,
  notifyMaster,
  callsRef,
  FieldValue: admin.firestore.FieldValue,
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
