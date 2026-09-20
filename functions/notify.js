/**
 * Push мастеру. Data — всегда (роут по tap, Twilio Voice не трогаем).
 * На Android ещё и notification: иначе Samsung не будит убитый процесс
 * и шторка появляется только когда FIX открывает приложение.
 * Twilio Voice остаётся data-only — его шлёт Twilio, не notifyMaster.
 */
const admin = require('firebase-admin');
const crypto = require('node:crypto');

const COMPANY_ID = 'fix_appliance_ca';

function tokensRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('fcm_tokens');
}

function channelFor(data) {
  const type = String(data.type || 'sms');
  const source = String(data.source || '');
  const secretaryAnswered = type === 'call' && String(data.answeredBy || '') === 'ai';
  if (
    type === 'email' ||
    type === 'email_offer' ||
    type === 'shipment' ||
    (type === 'job' && source === 'email')
  ) {
    return 'email_messages';
  }
  if (type === 'visit_confirm' || type === 'estimate_confirm') return 'visit_confirm';
  if (type === 'secretary_lesson') return 'secretary_learn';
  if (type === 'visit_soon') return 'visit_soon';
  if (type === 'on_the_way' || type === 'leave_status') return 'on_the_way';
  if (type === 'morning' || type === 'evening') return 'morning_jobs';
  if (type === 'call' || (type === 'job' && source !== 'sms') || secretaryAnswered) return 'incoming_calls';
  return 'sms_messages';
}

function last10(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  return digits.length >= 10 ? digits.slice(-10) : '';
}

function boundedTag(tag) {
  return tag.length <= 50 ? tag : `${tag.slice(0, 16)}_${crypto.createHash('sha256').update(tag).digest('hex').slice(0, 32)}`;
}

function shadeTag(data) {
  const from = String(data.peer || data.from || data.to || '').trim();
  if (from.includes('@')) return boundedTag(`crm_inbox_${from.toLowerCase()}`);
  const phone = last10(from);
  if (phone) return `crm_inbox_${phone}`;
  const explicit = String(data.tag || '').trim();
  if (explicit) return boundedTag(explicit);
  const type = String(data.type || 'sms');
  const key = String(
    data.callSid || data.callId || data.messageId || data.jobId || 'inbox'
  );
  return boundedTag(`crm_${type}_${key}`);
}

function notificationEventId(data) {
  if (String(data.eventId || '').trim()) return String(data.eventId).trim();
  const type = String(data.type || 'sms');
  const source = String(data.source || '');
  const callId = data.callSid || data.callId || data.sourceCallId;
  if (type === 'call' && callId) return `call:${callId}`;
  const messageId = data.messageId || data.sourceEmailId || data.sourceSmsId;
  if (messageId) {
    const email = type === 'email' || type === 'email_offer' || source === 'email' || source === 'website';
    return `${email ? 'email' : 'sms'}:${messageId}`;
  }
  if (type === 'job' && callId) return `call:${callId}`;
  if (type === 'job' && data.jobId) return `job:${data.jobId}`;
  return '';
}

function cityFromAddress(address) {
  const parts = String(address || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean);
  if (!parts.length) return '';
  const postalRe = /^[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d$/;
  if (parts.length >= 2 && postalRe.test(parts[parts.length - 1])) {
    return parts.length >= 3 ? parts[parts.length - 2] : '';
  }
  if (parts.length >= 2) return parts[parts.length - 1];
  return '';
}

function applianceOf(job) {
  if (job && job.applianceType) return String(job.applianceType);
  const list = job && job.appliances;
  if (Array.isArray(list) && list[0]) return String(list[0].type || '');
  return '';
}

function nameOf(job) {
  if (!job) return '';
  if (job.hasJobSite && job.jobSiteName) return String(job.jobSiteName);
  return String(job.clientName || job.contactName || '').trim();
}

function cityOf(job) {
  if (!job) return '';
  const raw = String(job.city || job.displayCity || '').trim();
  if (raw) return raw;
  return cityFromAddress(job.hasJobSite ? job.jobSiteAddress : job.clientAddress);
}

async function attachShadeFields(stringData) {
  try {
    const company = admin.firestore().collection('companies').doc(COMPANY_ID);
    if (stringData.jobId) {
      const snap = await company.collection('jobs').doc(stringData.jobId).get();
      if (snap.exists) {
        const job = snap.data() || {};
        if (!stringData.applianceType) stringData.applianceType = applianceOf(job);
        if (!stringData.clientName) stringData.clientName = nameOf(job);
        if (!stringData.city) stringData.city = cityOf(job);
        if (stringData.type === 'job') {
          if (!stringData.callSid && stringData.source === 'phone') stringData.callSid = String(job.sourceCallId || '');
          if (!stringData.messageId) stringData.messageId = String(job.sourceEmailId || job.sourceSmsId || '');
          if (!stringData.peer && !stringData.from) {
            stringData.peer = String(stringData.source === 'email' ? job.sourceEmailFrom || '' : job.clientPhone || '');
          }
        }
      }
    }
    if ((!stringData.clientName || !stringData.city) && stringData.clientId) {
      const snap = await company.collection('clients').doc(stringData.clientId).get();
      if (snap.exists) {
        const client = snap.data() || {};
        if (!stringData.clientName) {
          stringData.clientName = String(client.fullName || client.name || '').trim();
        }
        if (!stringData.city) {
          const loc =
            Array.isArray(client.locations) && client.locations[0] ? client.locations[0] : {};
          stringData.city =
            String(loc.city || '').trim() ||
            cityFromAddress(loc.address || loc.street || '');
        }
      }
    }
  } catch (error) {
    console.warn('attachShadeFields:', error.message);
  }
}

/**
 * FCM отклоняет всё сообщение целиком, если в data есть зарезервированное имя.
 * `from` было именно таким: в логах это выглядело как
 * `messaging/invalid-argument Invalid data payload key: from`, и уведомления о
 * звонках и SMS не доходили вообще. Отдаём его как `peer`; приложение читает
 * `peer`, а при его отсутствии — старое `from`.
 */
const FCM_RESERVED = new Set(['from', 'notification', 'message_type', 'collapse_key']);

function sanitizeFcmData(payload) {
  for (const key of Object.keys(payload)) {
    if (FCM_RESERVED.has(key)) {
      if (key === 'from' && payload.peer === undefined) payload.peer = payload[key];
      delete payload[key];
      continue;
    }
    if (/^(google|gcm)/i.test(key)) delete payload[key];
  }
  return payload;
}

function selectedRegistrations(docs) {
  const latest = new Map();
  for (const doc of docs) {
    const data = doc.data() || {};
    if (typeof data.token !== 'string' || !data.token.trim() || data.disabled === true) continue;
    const token = data.token.trim();
    const key = data.deviceId ? `device:${data.userId || ''}:${data.deviceId}` : `token:${token}`;
    const at = data.updatedAt?.toMillis ? data.updatedAt.toMillis() : new Date(data.updatedAt || 0).getTime();
    const previous = latest.get(key);
    if (!previous || at >= previous.at) latest.set(key, { token, doc, at });
  }
  return [...new Map([...latest.values()].map((entry) => [entry.token, entry])).values()];
}

async function registerDeviceToken({ token, platform, deviceId, userId, previousToken }) {
  const id = deviceId
    ? `device_${crypto.createHash('sha256').update(`${userId}:${deviceId}`).digest('hex')}`
    : String(token).replace(/\//g, '_').slice(0, 700);
  const ref = tokensRef().doc(id);
  await admin.firestore().runTransaction(async (tx) => {
    const previous = await tx.get(ref);
    const oldTokens = new Set([token, previousToken, previous.data()?.token].filter((value) => typeof value === 'string' && value));
    const legacy = [];
    if (deviceId) {
      for (const oldToken of oldTokens) {
        const oldRef = tokensRef().doc(oldToken.replace(/\//g, '_').slice(0, 700));
        if (oldRef.id !== ref.id) legacy.push(await tx.get(oldRef));
      }
    }
    tx.set(ref, {
      token, platform: platform || 'unknown', userId,
      ...(deviceId ? { deviceId } : {}),
      disabled: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    for (const old of legacy) {
      if (old.exists) tx.set(old.ref, { disabled: true, replacedBy: id }, { merge: true });
    }
  });
}

async function notifyMaster(title, body, data = {}) {
  const snapshot = await tokensRef().get();
  const registrations = selectedRegistrations(snapshot.docs);
  if (!registrations.length) {
    console.warn('notifyMaster: нет сохранённых FCM-токенов');
    return;
  }

  const stringData = {};
  for (const [key, value] of Object.entries(data)) {
    stringData[key] = String(value ?? '');
  }
  await attachShadeFields(stringData);

  const type = String(data.type || 'sms');
  const tag = shadeTag({ ...stringData, type });
  const channelId = channelFor({ ...data, type });
  stringData.type = type;
  stringData.tag = tag;
  stringData.channelId = channelId;
  stringData.eventId = notificationEventId(stringData) || `event:${crypto.randomUUID()}`;
  stringData.sentAt = String(Date.now());
  stringData.title = String(title || '');
  stringData.body = String(body || '');
  sanitizeFcmData(stringData);

  for (let offset = 0; offset < registrations.length; offset += 500) {
    const batch = registrations.slice(offset, offset + 500);
    const response = await admin.messaging().sendEachForMulticast({
      tokens: batch.map((entry) => entry.token),
      data: stringData,
      android: { priority: 'high', ttl: 86400000 },
      apns: {
        headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
        payload: {
          aps: {
            alert: { title: String(title || ''), body: String(body || '') },
            sound: 'default',
            'interruption-level': 'time-sensitive',
          },
        },
      },
    });

    const stale = new Set();
    response.responses.forEach((result, i) => {
      if (result.success) return;
      const code = result.error && result.error.code;
      if (code === 'messaging/registration-token-not-registered' || code === 'messaging/invalid-registration-token') {
        stale.add(batch[i].token);
      } else {
        console.warn('notifyMaster: ошибка отправки', code, result.error && result.error.message);
      }
    });
    await Promise.all(snapshot.docs.filter((doc) => stale.has(doc.data()?.token)).map((doc) =>
      admin.firestore().runTransaction(async (tx) => {
        const current = await tx.get(doc.ref);
        if (current.exists && stale.has(current.data().token)) tx.delete(doc.ref);
      })
    ));
  }
}

module.exports = { notifyMaster, channelFor, shadeTag, notificationEventId, sanitizeFcmData, registerDeviceToken };
