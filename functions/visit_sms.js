/**
 * SMS-цепочка визитов: запись, напоминание, ответ 1 / 0 / 5, скидка 10–25% при отмене.
 */
const admin = require('firebase-admin');
const twilio = require('twilio');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');
const voiceFacts = require('./voice_facts');
const schedule = require('./schedule');
const { notifyMaster } = require('./notify');

const COMPANY_ID = 'fix_appliance_ca';
const STATUS_CALLBACK =
  'https://us-central1-fix-appliance-crm.cloudfunctions.net/smsStatusCallback';
const DEFAULTS = {
  booking_confirm:
    'Hi {name}! ✅\n\n📅 Visit: {date}\n🕘 Time: {time}\n📍 {address}\n\nReply:\n1 ✅ confirm\n0 ❌ cancel\n5 🔁 another day',
  day_before:
    'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}\n\nReply 1 ✅ to confirm this visit, 0 ❌ to cancel, 5 🔁 to pick another day.',
  job_done:
    'Repair complete! ✅\nThank you for choosing us.\n⭐ Please leave a review:\n{review}',
  cancel_save:
    'Sorry to hear that, {name}. Would you like to reschedule instead?\n\nReply:\n• A new day and time (example: Friday 11:00)\n• 0 — confirm cancellation',
  reschedule_ask:
    'No problem, {name}. 🔁\nWhat day and time should the technician come?\nExample: Thursday at 14:00',
  confirm_rescheduled:
    'Hi {name}! 🔁\n\nYour visit is now:\n📅 {date}\n🕘 {time}\n📍 {address}\n\nReply:\n1 ✅ confirm\n0 ❌ cancel\n5 🔁 another day',
};

function db() {
  return admin.firestore();
}

function companyRef() {
  return db().collection('companies').doc(COMPANY_ID);
}

function jobsRef() {
  return companyRef().collection('jobs');
}

function callsRef() {
  return companyRef().collection('calls');
}

async function blockJobCreateOnCall(callId) {
  const id = String(callId || '').trim();
  if (!id) return;
  await callsRef().doc(id).set(
    {
      jobCreateBlocked: true,
      reviewed: true,
    },
    { merge: true }
  );
}

async function blockJobCreateForJob(jobId, sourceCallId) {
  await blockJobCreateOnCall(sourceCallId);
  const id = String(jobId || '').trim();
  if (!id) return;
  const snaps = await Promise.all([
    callsRef().where('createdJobId', '==', id).get(),
    callsRef().where('jobId', '==', id).get(),
  ]);
  const ids = new Set();
  for (const snap of snaps) {
    for (const doc of snap.docs) ids.add(doc.id);
  }
  for (const callId of ids) {
    await blockJobCreateOnCall(callId);
  }
}

function messagesRef() {
  return companyRef().collection('messages');
}

function twilioClient() {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authUser = process.env.TWILIO_API_KEY_SID || accountSid;
  const authSecret = process.env.TWILIO_API_KEY_SECRET || process.env.TWILIO_AUTH_TOKEN;
  if (!accountSid || !authUser || !authSecret || !process.env.TWILIO_PHONE_NUMBER) {
    return null;
  }
  return twilio(authUser, authSecret, { accountSid });
}

function normalizePhone(value) {
  if (!value) return '';
  const digits = String(value).replace(/\D/g, '');
  return digits.length > 10 ? digits.slice(-10) : digits;
}

function toE164(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  if (!digits) return '';
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return `+${digits}`;
}

function toDate(value) {
  if (!value) return null;
  if (value.toDate) return value.toDate();
  if (value instanceof Date) return value;
  if (typeof value === 'string') {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  if (typeof value === 'object' && (value._seconds || value.seconds)) {
    return new Date((value._seconds || value.seconds) * 1000);
  }
  return null;
}

function torontoDayKey(value) {
  const date = toDate(value);
  if (!date) return '';
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(date);
}

function visitSlotKey(value) {
  const day = torontoDayKey(value);
  const time = formatVisit(value, 'time');
  if (!day || !time) return '';
  return `${day}T${time}`;
}

function normalizeSlotKey(value) {
  return String(value || '').trim().replace(/^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})$/, '$1T$2');
}

function bookingStateFor(visit) {
  const booking = visit.smsBooking || {};
  return normalizeSlotKey(booking.slotKey) === visitSlotKey(visit.startAt)
    ? String(booking.state || '')
    : '';
}

function formatVisit(value, kind) {
  const date = toDate(value);
  if (!date) return '';
  if (kind === 'date') {
    return new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Toronto',
      month: 'long',
      day: 'numeric',
    }).format(date);
  }
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: 'America/Toronto',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date);
}

function hoursSince(value) {
  const date = toDate(value);
  if (!date) return Infinity;
  return (Date.now() - date.getTime()) / 36e5;
}

function torontoHour(value) {
  const date = toDate(value) || new Date();
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'America/Toronto',
    hour: '2-digit',
    hour12: false,
  }).formatToParts(date);
  const hour = parts.find((part) => part.type === 'hour');
  return Number(hour && hour.value);
}

function reminderOffsets(config) {
  const raw = config && config.reminderOffsets;
  if (Array.isArray(raw) && raw.length) {
    return raw.map((item) => String(item));
  }
  return ['24h'];
}

function reminderSentMap(visit) {
  const map =
    visit.smsReminders && typeof visit.smsReminders === 'object'
      ? { ...visit.smsReminders }
      : {};
  if (visit.smsReminderSentAt && !map['24h']) {
    map['24h'] = visit.smsReminderSentAt;
  }
  return map;
}

function hoursUntilVisit(visit) {
  const start = toDate(visit.startAt);
  if (!start) return null;
  return (start.getTime() - Date.now()) / 36e5;
}

function offsetMatches(offset, visit, config) {
  const hours = hoursUntilVisit(visit);
  if (hours == null || hours < -0.2) return false;
  if (offset === 'morning') {
    const visitDay = torontoDayKey(visit.startAt);
    const today = torontoDayKey(new Date());
    if (visitDay !== today) return false;
    const hour = torontoHour(new Date());
    const target = Number((config && config.reminderMorningHour) ?? 8);
    return hour === target;
  }
  const table = { '48h': 48, '24h': 24, '2h': 2 };
  const target = table[offset];
  if (!target) return false;
  return hours <= target + 0.7 && hours > target - 1.15;
}

function boolFlag(config, key, fallback = true) {
  if (!config || typeof config[key] !== 'boolean') return fallback;
  return config[key];
}

function stripUnwantedSmsBits(text) {
  return String(text || '')
    .replace(/\n?🔧\s*\{appliance\}/gi, '')
    .replace(/\n?🔧[^\n]*/g, '')
    .replace(/\n?This SMS is only for this address\.?/gi, '')
    .replace(/\{appliance\}/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function dedupeAddress(value) {
  const parts = String(value || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean);
  const seen = new Set();
  const out = [];
  for (const part of parts) {
    const key = part.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(part);
  }
  return out.join(', ');
}

function applyTemplate(template, vars) {
  let text = stripUnwantedSmsBits(String(template || ''));
  for (const [key, value] of Object.entries(vars)) {
    if (key === 'appliance') continue;
    text = text.split(`{${key}}`).join(value || '');
  }
  text = text.replace(/[ \t]{2,}/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  if (vars.review && !text.includes(vars.review)) {
    text = `${text} ${vars.review}`.trim();
  }
  return stripUnwantedSmsBits(text);
}

function jobPhone(job) {
  if (job.hasJobSite && job.jobSitePhone) return String(job.jobSitePhone);
  return String(job.clientPhone || job.jobSitePhone || '');
}

function jobName(job) {
  return String(job.clientName || job.jobSiteName || '').trim() || 'клиент';
}

function visitPersonName(job) {
  const site = String((job && job.jobSiteName) || '').trim();
  if (site && !voiceFacts.isPlaceholderClientName(site)) return site;
  const name = String((job && job.clientName) || '').trim();
  if (name && !voiceFacts.isPlaceholderClientName(name)) return name;
  return '';
}

function jobAddress(job) {
  if (job.hasJobSite && job.jobSiteAddress) return dedupeAddress(job.jobSiteAddress);
  return dedupeAddress(job.clientAddress || job.jobSiteAddress || '');
}

function isEmailJob(job) {
  const source = String((job && job.source) || '').trim().toLowerCase();
  if (source === 'email' || source === 'mail' || source === 'почта') return true;
  if (String((job && job.sourceEmailId) || '').trim()) return true;
  return String((job && job.sourceEmailFrom) || '').includes('@');
}

function visitSentSms(visit, viaEmail) {
  const via = String((visit && visit.smsBookingVia) || '').toLowerCase();
  if (via === 'sms' || via === 'both') return true;
  if (visit && visit.smsBookingSentSms === true) return true;
  // Any booking confirmation already sent at this slot counts as sent.
  // When the owner manually sends from the app the via flag may be empty,
  // so we default to SMS unless the channel was explicitly email only.
  if (visit && visit.smsBookingSentAt && !via) return true;
  return false;
}

function visitSentEmail(visit, viaEmail) {
  const via = String((visit && visit.smsBookingVia) || '').toLowerCase();
  if (via === 'email' || via === 'both') return true;
  if (visit && visit.smsBookingSentEmail === true) return true;
  // Old email-job confirms went out as a letter only.
  if (viaEmail && visit && visit.smsBookingSentAt && !via) return true;
  return false;
}

function visitHasStart(visit) {
  return Boolean(toDate(visit && visit.startAt));
}

async function jobContact(job) {
  const email = await resolveJobEmail(job);
  if (isEmailJob(job) && email) {
    return { viaEmail: true, email, phone: jobPhone(job) };
  }
  const phone = jobPhone(job);
  if (normalizePhone(phone)) {
    return { viaEmail: false, email: '', phone };
  }
  return { viaEmail: Boolean(email), email, phone: '' };
}

function emailsOfJob(job) {
  return [job && job.sourceEmailFrom, job && job.jobSiteEmail, job && job.clientEmail]
    .map((value) => String(value || '').trim().toLowerCase())
    .filter((value) => value.includes('@'));
}

async function resolveJobEmail(job) {
  const direct = emailsOfJob(job)[0] || '';
  if (direct) return direct;
  const clientId = String((job && job.clientId) || '').trim();
  if (!clientId) return '';
  try {
    const snap = await companyRef().collection('clients').doc(clientId).get();
    if (!snap.exists) return '';
    const data = snap.data() || {};
    const emails = [data.email];
    for (const location of data.locations || []) {
      emails.push(location && location.email);
      for (const contact of location.contacts || []) {
        emails.push(contact && contact.email);
      }
    }
    for (const raw of emails) {
      const email = String(raw || '').trim().toLowerCase();
      if (email.includes('@')) return email;
    }
  } catch (_) {}
  return '';
}

function visibleEmailReply(body) {
  const text = String(body || '').replace(/\r\n/g, '\n');
  const lines = text.split('\n');
  const out = [];
  for (const line of lines) {
    if (/^>/.test(line)) break;
    if (/^on .+ wrote:$/i.test(line.trim())) break;
    if (/^from:\s/i.test(line) && out.length) break;
    if (/^-----original message-----/i.test(line)) break;
    out.push(line);
  }
  return out.join('\n').trim() || text.trim();
}

function visitMailSubject(kind, vars) {
  const date = (vars && vars.date) || '';
  const time = (vars && vars.time) || '';
  const when = [date, time].filter(Boolean).join(' at ');
  if (kind === 'booking_confirm') {
    return when ? `Please confirm your visit — ${when}` : 'Please confirm your visit';
  }
  if (kind === 'day_before') {
    return when ? `Reminder: visit ${when}` : 'Visit reminder';
  }
  if (kind === 'job_done') return 'Thank you — repair complete';
  if (kind === 'cancel_save') return 'About your visit';
  if (kind === 'reschedule_ask') return 'When should we come?';
  if (kind === 'confirm_confirmed') return 'Visit confirmed';
  if (kind === 'confirm_cancelled') return 'Visit cancelled';
  if (kind === 'confirm_rescheduled') return 'Visit moved';
  if (kind === 'confirm_kept') return 'Visit kept';
  if (kind === 'confirm_slot_busy') return 'That time is not available';
  if (kind === 'confirm_clarify') return 'Please reply with a day and time';
  return when ? `Your visit — ${when}` : 'Your visit';
}

async function emailThreadMeta(job) {
  const result = { subject: '', inReplyTo: '', references: '' };
  const id = String((job && job.sourceEmailId) || '').trim();
  if (!id) return result;
  try {
    const snap = await messagesRef().doc(id).get();
    if (!snap.exists) return result;
    const data = snap.data() || {};
    const mid = String(data.emailMessageId || data.sid || '').trim();
    if (mid) {
      result.inReplyTo = mid;
      result.references = mid;
    }
    const sub = String(data.subject || '').trim();
    if (sub) result.subject = /^re:/i.test(sub) ? sub : `Re: ${sub}`;
  } catch (_) {}
  return result;
}

async function sendVisitEmail() {
  return false;
}

function coalesceVisits(job) {
  return schedule.coalesceVisits(job);
}

function isClosedJob(job) {
  return schedule.isClosedJob(job);
}

function isCompletedStatus(status) {
  const n = String(status || '').trim().toLowerCase();
  return (
    n === 'завершено' ||
    n.includes('заверш') ||
    n === 'готово' ||
    n === 'готов' ||
    n === 'completed' ||
    n === 'ready'
  );
}

function isScheduledVisit(visit) {
  return schedule.visitBlocks(visit);
}

async function loadConfig() {
  const snap = await companyRef().collection('settings').doc('config').get();
  return snap.exists ? snap.data() || {} : {};
}

async function loadTemplates() {
  const snap = await companyRef().collection('settings').doc('sms_templates').get();
  const data = snap.exists ? snap.data() || {} : {};
  return {
    booking_confirm: data.booking_confirm || DEFAULTS.booking_confirm,
    day_before: data.day_before || DEFAULTS.day_before,
    job_done: data.job_done || DEFAULTS.job_done,
    cancel_save: data.cancel_save || DEFAULTS.cancel_save,
    reschedule_ask: data.reschedule_ask || DEFAULTS.reschedule_ask,
    confirm_rescheduled: data.confirm_rescheduled || DEFAULTS.confirm_rescheduled,
  };
}

async function getSmsHeader() {
  try {
    const snap = await companyRef().collection('settings').doc('documents').get();
    const data = snap.exists ? snap.data() || {} : {};
    return sanitizeSmsHeader(data.smsHeader, data.companyName);
  } catch (_) {
    return '';
  }
}

async function sendTwilioSms({ to, body, clientId, jobId, kind }) {
  const client = twilioClient();
  const e164 = toE164(to);
  const text = String(body || '').trim();
  if (!client || !e164 || !text) {
    console.warn(
      `sendTwilioSms skip kind=${kind || ''} job=${jobId || ''} to=${e164 || '(empty)'} client=${Boolean(client)}`
    );
    return false;
  }
  const from = String(process.env.TWILIO_PHONE_NUMBER || '').trim();
  if (from && normalizePhone(from) === normalizePhone(e164)) {
    console.warn(
      `sendTwilioSms skip kind=${kind || ''} job=${jobId || ''}: to equals Twilio from`
    );
    return false;
  }
  try {
    const header = await getSmsHeader();
    const wrapped = withSmsHeader(text, header);
    const message = await client.messages.create({
      from,
      to: e164,
      body: wrapped,
      statusCallback: STATUS_CALLBACK,
    });
    await messagesRef().add({
      sid: message.sid,
      from,
      to: e164,
      body: wrapped,
      direction: 'outbound',
      status: message.status,
      clientId: clientId || null,
      jobId: jobId || null,
      kind: kind || null,
      channel: 'sms',
      mediaUrls: [],
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      read: true,
    });
    return true;
  } catch (error) {
    console.error(
      `sendTwilioSms fail kind=${kind || ''} job=${jobId || ''} to=${e164}:`,
      error && error.message ? error.message : error
    );
    return false;
  }
}

async function sendSms({ to, body, clientId, jobId, kind, job }) {
  const wantEmail = (job && isEmailJob(job)) || String(to || '').includes('@');
  if (wantEmail) {
    const ok = await sendVisitEmail({ job, to, body, clientId, jobId, kind });
    if (ok) return true;
    const phone = job ? jobPhone(job) : '';
    if (normalizePhone(phone)) {
      console.warn(`visit email failed, SMS fallback job=${jobId || ''}`);
      return sendTwilioSms({ to: phone, body, clientId, jobId, kind });
    }
    return false;
  }
  return sendTwilioSms({ to, body, clientId, jobId, kind });
}


function jobAppliance(job) {
  const fromList =
    Array.isArray(job.appliances) && job.appliances[0]
      ? job.appliances[0].type || job.appliances[0].applianceType
      : '';
  return String(fromList || job.applianceType || '').trim();
}

function visitVars(job, visit, reviewUrl) {
  return {
    name: jobName(job),
    date: formatVisit(visit.startAt, 'date'),
    time: formatVisit(visit.startAt, 'time'),
    address: jobAddress(job),
    appliance: jobAppliance(job),
    review: reviewUrl || '',
  };
}

function bookingError(message, statusCode = 409) {
  return Object.assign(new Error(message), { statusCode });
}

function bookingRequestRef(requestId) {
  if (!/^[A-Za-z0-9_-]{16,80}$/.test(String(requestId || ''))) {
    throw bookingError('Некорректный идентификатор отправки', 400);
  }
  return messagesRef().doc(`booking_${requestId}`);
}

function bookingVisit(job, visitId, slotKey, to) {
  if (!job || isClosedJob(job) || job.needsReview === true) {
    throw bookingError('Сначала проверьте открытую заявку');
  }
  const visits = coalesceVisits(job);
  const index = visits.findIndex((visit) => String(visit.id) === visitId);
  if (index < 0 || !isScheduledVisit(visits[index]) || visitSlotKey(visits[index].startAt) !== slotKey) {
    throw bookingError('Время визита изменилось. Откройте его заново');
  }
  if (normalizePhone(jobPhone(job)) !== normalizePhone(to)) {
    throw bookingError('Телефон клиента изменился. Откройте визит заново');
  }
  return { visits, index, visit: visits[index] };
}

function withBookingReceipt(message) {
  const receipt = message.bookingReceipt;
  if (!receipt || !['approved', 'sending'].includes(message.bookingState)) return message;
  const failed = ['failed', 'undelivered', 'canceled', 'unknown'].includes(receipt.status);
  return {
    ...message, sid: receipt.sid || message.sid || '', status: receipt.status,
    bookingState: failed ? 'error' : 'sent',
    bookingError: failed ? receipt.error || 'SMS не доставлено' : '',
    bookingRetryAllowed: failed && receipt.retryAllowed !== false,
  };
}

function bookingSendResult(message, id) {
  message = withBookingReceipt(message);
  return {
    success: message.bookingState === 'sent',
    state: message.bookingState,
    sid: message.sid || '',
    id,
    error: message.bookingState === 'sent' ? '' : message.bookingError || 'SMS уже отправляется. Дождитесь статуса в карточке',
  };
}

async function recordBookingDelivery(requestId, { sid = '', status, errorCode = '', error = '', retryAllowed = true }) {
  const messageRef = bookingRequestRef(requestId);
  return db().runTransaction(async (tx) => {
    const snapshot = await tx.get(messageRef);
    if (!snapshot.exists) return null;
    const message = snapshot.data();
    const meta = message.bookingSms;
    if (!meta || (message.sid && sid && message.sid !== sid)) return null;
    const jobRef = jobsRef().doc(meta.jobId);
    const jobSnap = await tx.get(jobRef);
    const ranks = { queued: 1, accepted: 1, sending: 2, sent: 3, delivered: 4, read: 5, undelivered: 5, failed: 5, canceled: 5 };
    if (message.sid && ['delivered', 'read'].includes(message.status) && !['delivered', 'read'].includes(status)) return message;
    if (message.sid && (ranks[message.status] || 0) > (ranks[status] || 0)) return message;
    if (sid && message.sid === sid && message.status === status && String(message.errorCode || '') === errorCode) return message;
    const failed = ['failed', 'undelivered', 'canceled', 'unknown'].includes(status);
    const state = failed ? 'error' : 'sent';
    const now = admin.firestore.Timestamp.now();
    const next = {
      ...message,
      sid: sid || message.sid || '',
      status,
      bookingState: state,
      bookingError: failed ? error || `SMS не доставлено${errorCode ? ` (${errorCode})` : ''}` : '',
      bookingRetryAllowed: failed && retryAllowed,
      updatedAt: now,
    };
    tx.update(messageRef, {
      sid: next.sid, status, bookingState: state, bookingError: next.bookingError,
      bookingRetryAllowed: next.bookingRetryAllowed, errorCode, updatedAt: now,
    });
    if (jobSnap.exists) {
      const visits = coalesceVisits(jobSnap.data());
      const visit = visits.find((item) => String(item.id) === meta.visitId);
      if (visit && visitSlotKey(visit.startAt) === meta.slotKey && visit.smsBooking?.requestId === requestId) {
        visit.smsBooking = {
          ...visit.smsBooking, state, messageSid: next.sid, error: next.bookingError,
          retryAllowed: next.bookingRetryAllowed, updatedAt: now,
        };
        visit.smsBookingPending = false;
        delete visit.smsBookingPendingAt;
        if (!failed) {
          visit.smsBookingSlotKey = meta.slotKey;
          visit.smsBookingDayKey = meta.slotKey.slice(0, 10);
          visit.smsBookingSentAt = message.createdAt || now;
          visit.smsBookingSentSms = true;
          visit.smsBookingVia = 'sms';
          if (!visit.smsConfirmStatus) visit.smsConfirmStatus = 'pending';
        }
        tx.update(jobRef, { visits, updatedAt: now });
      }
    }
    return next;
  });
}

async function persistBookingDelivery(requestId, result) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      return await recordBookingDelivery(requestId, result);
    } catch (error) {
      if (attempt === 1) {
        await bookingRequestRef(requestId).set({
          bookingReceipt: { ...result, recordedAt: admin.firestore.Timestamp.now() },
        }, { merge: true });
        console.warn('booking SMS result saved for reconciliation', requestId);
      }
    }
  }
  return null;
}

async function sendApprovedBookingSms({ jobId, visitId, slotKey, requestId, to, messageData, send }) {
  if (typeof jobId !== 'string' || !jobId || jobId.includes('/') || typeof visitId !== 'string' || !visitId) {
    throw bookingError('Нужны заявка и визит для отправки', 400);
  }
  slotKey = normalizeSlotKey(slotKey);
  const messageRef = bookingRequestRef(requestId);
  const jobRef = jobsRef().doc(jobId);
  await db().runTransaction(async (tx) => {
    const saved = await tx.get(messageRef);
    if (saved.exists) {
      const prior = saved.data();
      if (prior.bookingSms?.jobId !== jobId || prior.bookingSms?.visitId !== visitId ||
          prior.bookingSms?.slotKey !== slotKey || prior.to !== to || prior.body !== messageData.body) {
        throw bookingError('Эта отправка уже относится к другому сообщению');
      }
      return;
    }
    const snapshot = await tx.get(jobRef);
    const job = snapshot.exists ? snapshot.data() : null;
    const { visits, visit } = bookingVisit(job, visitId, slotKey, to);
    const state = bookingStateFor(visit);
    if (state === 'approved' || state === 'sending' || (state === 'error' && visit.smsBooking.retryAllowed === false)) {
      throw bookingError('Предыдущая отправка ещё не подтверждена. Проверьте переписку, чтобы не отправить SMS дважды');
    }
    const now = admin.firestore.Timestamp.now();
    visit.smsBooking = { state: 'approved', slotKey, requestId, approvedAt: now };
    visit.smsBookingPending = false;
    delete visit.smsBookingPendingAt;
    tx.update(jobRef, { visits, updatedAt: now });
    tx.create(messageRef, {
      ...messageData, to, sid: '', direction: 'outbound', status: 'queued', channel: 'sms',
      kind: 'booking_confirm', clientId: job.clientId || null, jobId, read: true, mediaUrls: [],
      bookingSms: { jobId, visitId, slotKey, requestId }, bookingState: 'approved', createdAt: now,
    });
  });
  const claimed = await db().runTransaction(async (tx) => {
    const snapshot = await tx.get(messageRef);
    const message = snapshot.data();
    if (message.bookingState !== 'approved') return false;
    const jobSnap = await tx.get(jobRef);
    let selected;
    try {
      selected = bookingVisit(jobSnap.exists ? jobSnap.data() : null, visitId, slotKey, to);
      if (selected.visit.smsBooking?.requestId !== requestId || selected.visit.smsBooking.state !== 'approved') {
        throw bookingError('Решение об отправке изменилось');
      }
    } catch (error) {
      tx.update(messageRef, { bookingState: 'error', bookingError: error.message, bookingRetryAllowed: true, status: 'failed' });
      if (jobSnap.exists) {
        const visits = coalesceVisits(jobSnap.data());
        const visit = visits.find((item) => String(item.id) === visitId);
        if (visit?.smsBooking?.requestId === requestId && visit.smsBooking.state === 'approved') {
          visit.smsBooking = { ...visit.smsBooking, state: 'error', error: error.message, retryAllowed: true };
          tx.update(jobRef, { visits });
        }
      }
      return false;
    }
    const now = admin.firestore.Timestamp.now();
    selected.visit.smsBooking = { ...selected.visit.smsBooking, state: 'sending', startedAt: now };
    tx.update(jobRef, { visits: selected.visits, updatedAt: now });
    tx.update(messageRef, { bookingState: 'sending', status: 'sending', updatedAt: now });
    return true;
  });
  if (claimed) {
    let message;
    let persisted;
    try {
      message = await send();
    } catch (error) {
      const definite = Number(error.status) >= 400 && Number(error.status) < 500;
      persisted = await persistBookingDelivery(requestId, {
        status: definite ? 'failed' : 'unknown', errorCode: String(error.code || ''),
        error: definite ? 'Провайдер отклонил SMS. Можно повторить отправку' : 'Результат отправки неизвестен. Проверьте переписку перед повтором',
        retryAllowed: definite,
      });
    }
    if (message) {
      persisted = await persistBookingDelivery(requestId, { sid: message.sid, status: message.status || 'queued' });
    }
    if (!persisted) {
      await queueManualBooking(jobId, null, { reconcileOnly: true });
    }
  }
  const latest = await messageRef.get();
  return bookingSendResult(latest.data(), messageRef.id);
}

async function queueManualBooking(jobId, before, { reconcileOnly = false } = {}) {
  const jobRef = jobsRef().doc(jobId);
  const queued = await db().runTransaction(async (tx) => {
    const snapshot = await tx.get(jobRef);
    const job = snapshot.exists ? snapshot.data() : null;
    if (!job || job.needsReview === true || isClosedJob(job)) return null;
    const phone = jobPhone(job);
    if (!normalizePhone(phone)) return null;
    const previous = new Map(coalesceVisits(before || {}).map((visit) => [String(visit.id), visit]));
    const visits = coalesceVisits(job);
    const messageUpdates = [];
    let changed = false;
    let manualPendingCount = 0;
    for (const visit of visits) {
      if (!isScheduledVisit(visit) || String(visit.note || '').toLowerCase().includes('уточнить')) continue;
      const start = toDate(visit.startAt);
      if (!start || (start.getTime() < Date.now() - 2 * 36e5 && !job.createdByAi)) continue;
      const slotKey = visitSlotKey(start);
      const dayKey = torontoDayKey(start);
      const booking = visit.smsBooking || {};
      let state = bookingStateFor(visit);
      if (['approved', 'sending', 'error'].includes(state) && /^[A-Za-z0-9_-]{16,80}$/.test(booking.requestId || '')) {
        const requestRef = bookingRequestRef(booking.requestId);
        const saved = await tx.get(requestRef);
        const message = saved.exists ? withBookingReceipt(saved.data()) : null;
        if (message?.bookingSms?.jobId === jobId && message.bookingSms.visitId === String(visit.id) &&
            message.bookingSms.slotKey === slotKey && ['sent', 'error'].includes(message.bookingState) &&
            (state !== message.bookingState || booking.messageSid !== message.sid || booking.error !== message.bookingError)) {
          state = message.bookingState;
          visit.smsBooking = {
            ...booking, state, messageSid: message.sid || '', error: message.bookingError || '',
            retryAllowed: message.bookingRetryAllowed === true,
          };
          if (state === 'sent') {
            visit.smsBookingSlotKey = slotKey;
            visit.smsBookingDayKey = dayKey;
            visit.smsBookingSentAt = message.createdAt || admin.firestore.Timestamp.now();
            visit.smsBookingSentSms = true;
            visit.smsBookingVia = 'sms';
          }
          if (saved.data().bookingReceipt) {
            messageUpdates.push([requestRef, {
              sid: message.sid || '', status: message.status, bookingState: state,
              bookingError: message.bookingError || '', bookingRetryAllowed: message.bookingRetryAllowed === true,
            }]);
          }
          changed = true;
        }
      }
      if (['pending', 'approved', 'rejected', 'sending', 'sent', 'error'].includes(state)) {
        const pending = state === 'pending';
        if (Boolean(visit.smsBookingPending) !== pending || (!pending && visit.smsBookingPendingAt)) {
          visit.smsBookingPending = pending;
          if (!pending) delete visit.smsBookingPendingAt;
          changed = true;
        }
        continue;
      }
      if (reconcileOnly) continue;
      const prev = previous.get(String(visit.id));
      const storedSlot = normalizeSlotKey(visit.smsBookingSlotKey);
      const stateSlot = normalizeSlotKey(booking.slotKey);
      const slotMoved = Boolean(
        (storedSlot && storedSlot !== slotKey) ||
        (stateSlot && stateSlot !== slotKey) ||
        (prev && visitSlotKey(prev.startAt) !== slotKey) ||
        (visit.smsBookingDayKey && visit.smsBookingDayKey !== dayKey)
      );
      if (visit.smsConfirmStatus === 'confirmed' && !slotMoved) continue;
      const alreadyPending = visit.smsBookingPending === true && !slotMoved;
      const alreadySent = Boolean(visit.smsBookingSentAt) && visitSentSms(visit, false) &&
        (storedSlot === slotKey || (!storedSlot && !slotMoved));
      const now = admin.firestore.Timestamp.now();
      visit.smsBookingSlotKey = slotKey;
      visit.smsBookingDayKey = dayKey;
      if (alreadySent) {
        visit.smsBooking = { state: 'sent', slotKey, sentAt: visit.smsBookingSentAt };
        visit.smsBookingPending = false;
        delete visit.smsBookingPendingAt;
      } else {
        // Manual approval mode: mark the visit as pending an owner-sent SMS.
        visit.smsBooking = { state: 'pending', slotKey, requestedAt: alreadyPending ? visit.smsBookingPendingAt || now : now };
        visit.smsBookingPending = true;
        visit.smsBookingPendingAt = visit.smsBooking.requestedAt;
        if (slotMoved) {
          visit.smsBookingSentAt = null;
          visit.smsBookingSentSms = false;
          visit.smsBookingSentEmail = false;
          visit.smsBookingVia = '';
          visit.smsReminderSentAt = null;
          visit.smsConfirmNotifiedStatus = '';
        }
        visit.smsConfirmStatus = 'pending';
        if (!alreadyPending) manualPendingCount += 1;
      }
      changed = true;
    }
    for (const [requestRef, patch] of messageUpdates) tx.update(requestRef, patch);
    if (changed) {
      tx.update(jobRef, { visits, scheduleUnconfirmed: false, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    }
    return manualPendingCount ? { job, phone } : null;
  });
  if (!queued) return;
  // type visit_confirm: тап ведёт в карточку заявки, где кнопка «Отправить»,
  // и уведомление не выглядит как входящее SMS от клиента.
  await notifyMaster(
    'SMS ждёт отправки',
    `${jobName(queued.job)} — подтверждение визита не отправлено клиенту`,
    { type: 'visit_confirm', jobId, clientId: queued.job.clientId || '', from: queued.phone }
  );
}

async function sendBookingIfNeeded(jobId, before, after, config, templates) {
  if (!after || after.deletedAt) return;
  if (after.needsReview === true) return;
  if (!boolFlag(config, 'bookingSmsEnabled', true)) {
    console.log(`sendBookingIfNeeded skip ${jobId}: bookingSmsEnabled=false`);
    return;
  }
  if (isClosedJob(after)) return;
  const { viaEmail, email, phone } = await jobContact(after);
  const hasPhone = Boolean(normalizePhone(phone));
  if (viaEmail) {
    if (!email && !hasPhone) {
      console.log(`sendBookingIfNeeded skip ${jobId}: no email or phone`);
      return;
    }
  } else if (!hasPhone) {
    console.log(`sendBookingIfNeeded skip ${jobId}: no phone`);
    return;
  }

  if (boolFlag(config, 'manualSmsApproval')) {
    await queueManualBooking(jobId, before);
    return;
  }
  const beforeById = new Map(
    coalesceVisits(before || {}).map((visit) => [String(visit.id || ''), visit])
  );
  const visits = coalesceVisits(after);
  let changed = false;
  const now = Date.now();
  const hasRealSlot = visits.some(
    (visit) => isScheduledVisit(visit) && visitHasStart(visit)
  );

  if (!hasRealSlot) {
    await sendEmailRequestAckIfNeeded(jobId, after, viaEmail, email);
    return;
  }

  for (const visit of visits) {
    if (String(visit.note || '').toLowerCase().includes('уточнить')) continue;
    if (!isScheduledVisit(visit)) continue;
    const start = toDate(visit.startAt);
    if (!start) continue;
    if (start.getTime() < now - 2 * 36e5 && !after.createdByAi) continue;
    const dayKey = torontoDayKey(start);
    if (!dayKey) continue;
    const prev = beforeById.get(String(visit.id || ''));
    const slotKey = visitSlotKey(start);
    const prevSlot = prev ? visitSlotKey(prev.startAt) : '';
    const storedSlot = normalizeSlotKey(visit.smsBookingSlotKey);
    if (['pending', 'approved', 'rejected', 'sending', 'sent', 'error'].includes(bookingStateFor(visit))) continue;

    // If the owner manually sent the confirmation, clear the pending flag.
    if (visit.smsBookingPending && visit.smsBookingSentAt) {
      const pendingSlot = String(visit.smsBookingSlotKey || '').trim();
      if (pendingSlot && pendingSlot === slotKey) {
        visit.smsBookingPending = false;
        delete visit.smsBookingPendingAt;
        changed = true;
      }
    }

    // Слот реально переехал на другое время: прежнее «да» клиента относилось
    // к старому времени, поэтому подтверждение больше не действует.
    const slotMoved = Boolean(
      (prev && prevSlot && prevSlot !== slotKey) ||
        (storedSlot && storedSlot !== slotKey) ||
        (visit.smsBookingDayKey && visit.smsBookingDayKey !== dayKey)
    );

    // Пункт 18: заказ, который клиент уже подтвердил, трогать нельзя. Любая
    // запись в заявку (например, ответ клиента в переписке) дёргает этот
    // триггер, и раньше подтверждённый визит сбрасывался в «не подтверждено».
    if (String(visit.smsConfirmStatus || '') === 'confirmed' && !slotMoved) {
      continue;
    }

    const alreadyThisSlot =
      (Boolean(visit.smsBookingSentAt) || Boolean(visit.smsBookingPending)) &&
      ((storedSlot && storedSlot === slotKey) ||
        (!storedSlot && prev && prevSlot === slotKey) ||
        (!storedSlot && !prev && visit.smsBookingDayKey === dayKey && !prevSlot));
    let texted = alreadyThisSlot && visitSentSms(visit, viaEmail);
    if (alreadyThisSlot && (texted || !hasPhone)) {
      continue;
    }
    const moved = Boolean(visit.smsBookingSentAt) && slotMoved;
    const kind = moved ? 'confirm_rescheduled' : 'booking_confirm';
    const body = applyTemplate(
      moved ? templates.confirm_rescheduled : templates.booking_confirm,
      visitVars(after, visit)
    );
    if (hasPhone && !texted) {
      texted = await sendTwilioSms({
        to: phone,
        body,
        clientId: after.clientId,
        jobId,
        kind,
      });
    }
    if (!texted) {
      console.log(`sendBookingIfNeeded skip ${jobId}: email confirm disabled, no SMS`);
      continue;
    }
    console.log(
      `sendBookingIfNeeded sent job=${jobId} kind=${moved ? 'moved' : 'new'} email=false sms=${texted}`
    );
    visit.smsBookingDayKey = dayKey;
    visit.smsBookingSlotKey = slotKey;
    visit.smsBookingSentAt = admin.firestore.Timestamp.now();
    visit.smsBookingSentSms = texted;
    visit.smsBookingSentEmail = false;
    visit.smsBookingVia = 'sms';
    visit.smsBookingPending = false;
    delete visit.smsBookingPendingAt;
    if (!alreadyThisSlot) {
      visit.smsReminderSentAt = moved ? null : visit.smsReminderSentAt || null;
      visit.smsConfirmStatus = 'pending';
    }
    changed = true;
  }

  if (changed) {
    await jobsRef().doc(jobId).update({
      visits,
      scheduleUnconfirmed: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

async function sendEmailRequestAckIfNeeded() {
  return;
}

async function sendReviewIfNeeded(jobId, before, after, config, templates) {
  if (!after || !isCompletedStatus(after.status)) return;
  if (before && isCompletedStatus(before.status) && !after.requestReviewSms) {
    return;
  }
  if (after.reviewSmsSentAt) return;
  // Only after the owner confirmed (app sets requestReviewSms). Never silent auto.
  if (after.requestReviewSms !== true) return;

  const dueMs =
    after.reviewSmsDueAt && typeof after.reviewSmsDueAt.toMillis === 'function'
      ? after.reviewSmsDueAt.toMillis()
      : 0;
  if (dueMs > Date.now()) {
    const waitMs = Math.min(dueMs - Date.now() + 400, 150000);
    await new Promise((resolve) => setTimeout(resolve, waitMs));
    const fresh = await jobsRef().doc(jobId).get();
    after = fresh.exists ? fresh.data() || {} : null;
    if (!after || after.reviewSmsSentAt || !isCompletedStatus(after.status)) {
      return;
    }
    if (after.requestReviewSms !== true) return;
  }

  const phone = jobPhone(after);
  if (!normalizePhone(phone)) {
    await jobsRef().doc(jobId).update({
      reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
      requestReviewSms: admin.firestore.FieldValue.delete(),
      reviewSmsDueAt: admin.firestore.FieldValue.delete(),
    });
    return;
  }
  const reviewUrl = String(config.googleReviewUrl || '').trim();
  const body = applyTemplate(templates.job_done, {
    name: jobName(after),
    date: '',
    time: '',
    address: jobAddress(after),
    review: reviewUrl,
  });
  const sent = await sendTwilioSms({
    to: phone,
    body,
    clientId: after.clientId,
    jobId,
    kind: 'job_done',
  });
  if (sent) {
    await jobsRef().doc(jobId).update({
      reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
      requestReviewSms: admin.firestore.FieldValue.delete(),
      reviewSmsDueAt: admin.firestore.FieldValue.delete(),
    });
  }
}

async function sendMissedBookingConfirms() {
  const config = await loadConfig();
  const templates = await loadTemplates();
  const snapshot = await jobsRef().get();
  for (const doc of snapshot.docs) {
    const job = doc.data() || {};
    try {
      await sendBookingIfNeeded(doc.id, job, job, config, templates);
    } catch (error) {
      console.error(`missed booking ${doc.id}:`, error.message);
    }
  }
}

async function sendMissedReviewSms() {
  const config = await loadConfig();
  const templates = await loadTemplates();
  const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const snapshot = await jobsRef().where('status', '==', 'Завершено').get();
  for (const doc of snapshot.docs) {
    const job = doc.data() || {};
    if (job.deletedAt || job.reviewSmsSentAt) continue;
    // Catch-up only for reviews the owner already approved.
    if (job.requestReviewSms !== true) continue;
    const dueMs =
      job.reviewSmsDueAt && typeof job.reviewSmsDueAt.toMillis === 'function'
        ? job.reviewSmsDueAt.toMillis()
        : 0;
    if (dueMs > Date.now()) continue;
    const completedAt = job.completedAt && job.completedAt.toMillis
      ? job.completedAt.toMillis()
      : job.updatedAt && job.updatedAt.toMillis
        ? job.updatedAt.toMillis()
        : 0;
    if (completedAt && completedAt < cutoff) continue;
    try {
      await sendReviewIfNeeded(
        doc.id,
        { status: 'В работе' },
        job,
        config,
        templates
      );
    } catch (error) {
      console.error(`missed review ${doc.id}:`, error.message);
    }
  }
}

async function processJobWrite(before, after, jobId) {
  if (!after) return;
  if (after.deletedAt || isClosedJob(after)) {
    await blockJobCreateForJob(jobId, after.sourceCallId);
    // Closed jobs used to return before review SMS — send it on complete.
    if (!after.deletedAt) {
      const config = await loadConfig();
      const templates = await loadTemplates();
      await sendReviewIfNeeded(jobId, before, after, config, templates);
    }
    await recordJobChanges(before, after, jobId);
    return;
  }
  const config = await loadConfig();
  const templates = await loadTemplates();
  await sendReviewIfNeeded(jobId, before, after, config, templates);
  await sendBookingIfNeeded(jobId, before, after, config, templates);
  await sendManualConfirmAckIfNeeded(jobId, before, after, templates);
  await recordJobChanges(before, after, jobId);
}

async function recordJobChanges(before, after, jobId) {
  if (!after || !jobId) return;
  const changesRef = companyRef().collection('jobs').doc(jobId).collection('changes');
  const now = admin.firestore.Timestamp.now();
  const changes = [];

  // Determine who made the change
  const by = (() => {
    if (after.suggestComplete || after.suggestCancel) return 'stripe';
    if (after.source === 'email' && !before) return 'email';
    if (after.sourceCallId && !before) return 'secretary';
    if (after.source === 'sms' && !before) return 'sms';
    if (!before) return 'owner';
    // Look for clues about who modified
    const prevStatus = String((before || {}).status || '');
    const nextStatus = String(after.status || '');
    if (prevStatus !== nextStatus && after.suggestComplete) return 'stripe';
    if (prevStatus !== nextStatus && (nextStatus === 'Перенос' || nextStatus === 'Вызов') &&
        coalesceVisits(after).some(v => String(v.smsConfirmStatus || '') === 'confirmed' &&
        coalesceVisits(before || {}).find(b => b.id === v.id && b.smsConfirmStatus !== 'confirmed'))) {
      return 'client';
    }
    return 'owner';
  })();

  // Job created
  if (!before && after) {
    const src = after.source || (after.sourceCallId ? 'secretary' : after.sourceEmailId ? 'email' : 'owner');
    changes.push({ at: now, by: src === 'phone' ? 'secretary' : src === 'email' ? 'email' : src === 'sms' ? 'sms' : src === 'website' ? 'email' : 'owner', event: 'created', detail: String(after.status || '') });
  }

  if (before) {
    // Status changed
    const prevStatus = String((before || {}).status || '');
    const nextStatus = String(after.status || '');
    if (prevStatus && nextStatus && prevStatus !== nextStatus) {
      changes.push({ at: now, by, event: 'status_changed', from: prevStatus, to: nextStatus });
    }

    // Client name changed (not placeholder)
    const prevName = String((before || {}).clientName || '').trim();
    const nextName = String(after.clientName || '').trim();
    if (prevName !== nextName && nextName && nextName !== prevName &&
        !/^(клиент|client)/i.test(nextName)) {
      changes.push({ at: now, by, event: 'client_name_set', value: nextName });
    }

    // Visit scheduled or moved
    const prevVisits = coalesceVisits(before || {});
    const nextVisits = coalesceVisits(after);
    for (const visit of nextVisits) {
      const prev = prevVisits.find(v => v.id === visit.id);
      const slot = visitSlotKey(visit.startAt);
      if (!prev) {
        if (visit.startAt) changes.push({ at: now, by, event: 'visit_added', slot });
      } else {
        const prevSlot = visitSlotKey(prev.startAt);
        if (prevSlot && slot && prevSlot !== slot) {
          changes.push({ at: now, by, event: 'visit_moved', from: prevSlot, to: slot });
        }
        // Client confirmed via SMS
        if (String(prev.smsConfirmStatus || '') !== 'confirmed' && String(visit.smsConfirmStatus || '') === 'confirmed') {
          changes.push({ at: now, by: 'client', event: 'visit_confirmed', slot });
        }
        // Client cancelled via SMS
        if (String(prev.smsConfirmStatus || '') !== 'cancelled' && String(visit.smsConfirmStatus || '') === 'cancelled') {
          changes.push({ at: now, by: 'client', event: 'visit_cancelled', slot });
        }
      }
    }

    // Invoice paid / payment recorded
    const prevDocs = Array.isArray(before.documents) ? before.documents : [];
    const nextDocs = Array.isArray(after.documents) ? after.documents : [];
    for (let i = 0; i < nextDocs.length; i++) {
      const nextDoc = nextDocs[i];
      const prevDoc = prevDocs[i] || {};
      if (!nextDoc || nextDoc.type === 'Estimate') continue;
      const nextPayments = Array.isArray(nextDoc.payments) ? nextDoc.payments : [];
      const prevPayments = Array.isArray(prevDoc.payments) ? prevDoc.payments : [];
      if (nextPayments.length > prevPayments.length) {
        const newPay = nextPayments[nextPayments.length - 1];
        const amount = Number(newPay && newPay.amount) || 0;
        const isTip = String((newPay && newPay.method) || '').includes('Чаевые');
        if (!isTip && Math.abs(amount) > 0.009) {
          const event = amount < 0 ? 'refund_recorded' : 'payment_recorded';
          changes.push({ at: now, by: 'stripe', event, amount: Math.abs(amount), method: String((newPay && newPay.method) || '') });
        }
      }
    }

    // suggestComplete flag set
    if (!before.suggestComplete && after.suggestComplete) {
      changes.push({ at: now, by: 'stripe', event: 'invoice_fully_paid' });
    }
  }

  if (!changes.length) return;
  // Write each change as a separate doc so they can be queried individually.
  // Using individual set() calls avoids a batched-write dependency in the test harness.
  await Promise.all(changes.map((change) => changesRef.doc().set(change)));
}

async function sendManualConfirmAckIfNeeded(jobId, before, after, templates) {
  if (!after || after.needsReview === true || isClosedJob(after)) return;
  const latest = await jobsRef().doc(jobId).get();
  after = latest.exists ? latest.data() : null;
  if (!after || after.needsReview === true || isClosedJob(after)) return;
  const phone = jobPhone(after);
  if (!normalizePhone(phone)) return;
  const beforeById = new Map(
    coalesceVisits(before || {}).map((visit) => [String(visit.id || ''), visit])
  );
  const visits = coalesceVisits(after);
  const acknowledged = [];
  for (let i = 0; i < visits.length; i += 1) {
    const visit = visits[i];
    const prev = beforeById.get(String(visit.id || ''));
    const nextStatus = String(visit.smsConfirmStatus || '').trim();
    const prevStatus = String((prev && prev.smsConfirmStatus) || '').trim();
    if (!nextStatus || nextStatus === prevStatus) continue;
    if (String(visit.smsConfirmNotifiedStatus || '') === nextStatus) continue;
    const vars = visitVars(after, visit);
    let body = '';
    let kind = '';
    if (nextStatus === 'confirmed') {
      body = `Thanks, ${vars.name}! See you ${vars.date} at ${vars.time}. ✅`;
      kind = 'confirm_confirmed';
    } else if (nextStatus === 'reschedule') {
      body = applyTemplate(templates.reschedule_ask, vars);
      kind = 'reschedule_ask';
    } else {
      continue;
    }
    const sent = await sendTwilioSms({
      to: phone,
      body,
      clientId: after.clientId,
      jobId,
      kind,
    });
    if (!sent) continue;
    acknowledged.push({
      ...visit,
      smsConfirmNotifiedStatus: nextStatus,
      smsDialog: nextStatus === 'reschedule' ? 'ask_slot' : '',
    });
  }
  if (acknowledged.length) {
    const jobRef = jobsRef().doc(jobId);
    await db().runTransaction(async (tx) => {
      const snapshot = await tx.get(jobRef);
      if (!snapshot.exists) return;
      const current = coalesceVisits(snapshot.data());
      let changed = false;
      for (const sent of acknowledged) {
        const visit = current.find((item) => String(item.id) === String(sent.id));
        if (!visit || visitSlotKey(visit.startAt) !== visitSlotKey(sent.startAt) ||
            visit.smsConfirmStatus !== sent.smsConfirmNotifiedStatus) continue;
        visit.smsConfirmNotifiedStatus = sent.smsConfirmNotifiedStatus;
        visit.smsDialog = sent.smsDialog;
        changed = true;
      }
      if (changed) tx.update(jobRef, { visits: current, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    });
  }
}

async function sendDayBeforeReminders() {
  const config = await loadConfig();
  if (!boolFlag(config, 'reminderSmsEnabled')) return;
  if (boolFlag(config, 'manualSmsApproval')) {
    console.log('sendDayBeforeReminders skip: manualSmsApproval=true');
    return;
  }
  const offsets = reminderOffsets(config);
  if (!offsets.length) return;
  const templates = await loadTemplates();

  const snapshot = await jobsRef().get();
  for (const doc of snapshot.docs) {
    const job = doc.data() || {};
    if (isClosedJob(job)) continue;
    if (job.needsReview === true) continue;
    const viaEmail = isEmailJob(job);
    const phone = jobPhone(job);
    const email = viaEmail ? await resolveJobEmail(job) : '';
    if (viaEmail) {
      if (!email) continue;
    } else if (!normalizePhone(phone)) {
      continue;
    }
    const visits = coalesceVisits(job);
    let changed = false;
    for (const visit of visits) {
      if (String(visit.smsDialog || '') === 'no_auto') continue;
      if (!isScheduledVisit(visit)) continue;
      const sent = reminderSentMap(visit);
      for (const offset of offsets) {
        if (sent[offset]) continue;
        if (!offsetMatches(offset, visit, config)) continue;
        if (
          (offset === '24h' || offset === '48h') &&
          visit.smsBookingSentAt &&
          hoursSince(visit.smsBookingSentAt) < 8
        ) {
          continue;
        }
        const body = applyTemplate(templates.day_before, visitVars(job, visit));
        const ok = await sendSms({
          to: viaEmail ? email : phone,
          body,
          clientId: job.clientId,
          jobId: doc.id,
          kind: 'day_before',
          job,
        });
        if (!ok) continue;
        sent[offset] = admin.firestore.Timestamp.now();
        visit.smsReminders = sent;
        visit.smsReminderSentAt = sent[offset];
        if (!visit.smsConfirmStatus) visit.smsConfirmStatus = 'pending';
        changed = true;
      }
    }
    if (changed) {
      await doc.ref.update({
        visits,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
}

function parseConfirmReply(body) {
  const raw = String(body || '')
    .trim()
    .toLowerCase()
    // strip common emoji/keycap variants: 1️⃣ → 1
    .replace(/[\uFE0F\u20E3]/g, '')
    .replace(/[.!,#:\-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!raw) return null;
  const compact = raw.replace(/\s+/g, '');
  if (
    compact === '1' ||
    ['yes', 'да', 'ok', 'ок', 'confirm', 'подтверждаю', 'confirmed', 'keep'].includes(raw) ||
    /^(yes|ok|confirm|да)\s*[!.]*$/i.test(raw)
  ) {
    return 'confirmed';
  }
  // Only a bare cancel code. "cancel August 31" / "cancel Michelle" is free-text.
  if (
    compact === '0' ||
    ['cancel', 'cancelled', 'canceled', 'отмена', 'отменил', 'отменить', 'just cancel'].includes(
      raw
    )
  ) {
    return 'cancelled';
  }
  if (compact === '5' || ['reschedule', 'перенос'].includes(raw)) {
    return 'reschedule';
  }
  return null;
}

function parseSlotFromText(text, fallbackDate, fallbackTime) {
  const today = voiceFacts.torontoTodayYmd();
  const date = voiceFacts.inferDateFromText(text, today) || fallbackDate || '';
  const time = voiceFacts.inferTimeFromText(text) || fallbackTime || '';
  if (!date || !time) return null;
  return voiceFacts.parseScheduledAtDate({
    scheduled_date: date,
    scheduled_time: time,
  });
}

function relativeAmount(raw) {
  const t = String(raw || '')
    .toLowerCase()
    .trim();
  const words = {
    a: 1,
    an: 1,
    one: 1,
    two: 2,
    three: 3,
    four: 4,
    five: 5,
    six: 6,
    один: 1,
    одна: 1,
    два: 2,
    две: 2,
    три: 3,
    четыре: 4,
    пять: 5,
  };
  if (words[t]) return words[t];
  const n = Number(t);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** "2 hours earlier" / "на 2 часа раньше" relative to the current visit. */
function parseRelativeSlotFromText(text, baseStart) {
  const base = toDate(baseStart);
  if (!base) return null;
  const t = String(text || '').toLowerCase();
  let m = t.match(
    /\b(\d+|one|two|three|four|five|six|an?)\s*(hours?|hrs?|minutes?|mins?)\s*(earlier|before|sooner|later|after)\b/i
  );
  if (!m) {
    m = t.match(
      /\b(?:на\s+)?(\d+|один|одна|два|две|три|четыре|пять)\s*(час(?:а|ов)?|минут[уыа]?)\s*(раньше|позже)\b/i
    );
  }
  if (!m) return null;
  const amount = relativeAmount(m[1]);
  if (!amount) return null;
  const unit = String(m[2] || '').toLowerCase();
  const dir = String(m[3] || '').toLowerCase();
  const minutes = /min|минут/.test(unit) ? amount : amount * 60;
  const earlier = /earlier|before|sooner|раньше/.test(dir);
  return new Date(base.getTime() + minutes * 60 * 1000 * (earlier ? -1 : 1));
}

function resolveSlotFromText(text, visit, opts = {}) {
  const relative = parseRelativeSlotFromText(text, visit && visit.startAt);
  if (relative) return relative;
  const fallbackDate = opts.useVisitDay ? fallbackDayKey(visit) : '';
  const fallbackTime = opts.useVisitTime
    ? formatVisit(visit && visit.startAt, 'time')
    : '';
  return parseSlotFromText(text, fallbackDate, fallbackTime);
}

function fallbackDayKey(visit) {
  return torontoDayKey(visit && visit.startAt);
}

function lastVisitSmsMs(visit) {
  const times = [toDate(visit.smsReminderSentAt), toDate(visit.smsBookingSentAt)]
    .filter(Boolean)
    .map((date) => date.getTime());
  return times.length ? Math.max(...times) : 0;
}

async function jobsForContact(from, clientId) {
  const email = String(from || '').includes('@') ? String(from).trim().toLowerCase() : '';
  const phone = email ? '' : normalizePhone(from);
  if (!clientId && !email && !phone) return [];
  const snap = await jobsRef().get();
  return snap.docs.filter((doc) => {
    const data = doc.data() || {};
    return (clientId && data.clientId === clientId) ||
      (email && emailsOfJob(data).includes(email)) ||
      (phone && [data.clientPhone, data.jobSitePhone].some((value) => normalizePhone(value) === phone));
  });
}

async function findPendingJob(from, clientId) {
  const docs = await jobsForContact(from, clientId);

  const now = Date.now();
  let best = null;
  for (const doc of docs) {
    const job = doc.data() || {};
    for (const visit of schedule.upcomingVisits(job, now)) {
      const start = toDate(visit.startAt);
      const status = String(visit.smsConfirmStatus || '').trim();
      // Already done — ignore. «Перенос» / empty still accept «1».
      if (status === 'confirmed' || status === 'cancelled') continue;
      const smsMs = lastVisitSmsMs(visit);
      if (
        !best ||
        smsMs > best.smsMs ||
        (smsMs === best.smsMs && start.getTime() < best.start.getTime())
      ) {
        best = { doc, job, visit, start, smsMs };
      }
    }
  }
  return best;
}

function looksLikeRescheduleIntent(body) {
  const t = String(body || '').toLowerCase();
  return /\b(postpone|reschedule|another day|different (day|time)|push (it|back)|move (it|the (visit|appointment|booking))|change (the )?(visit|appointment|time|day)|can (we|i) (postpone|reschedule|move|change)|is it possible to (postpone|reschedule)|later (day|date|time)|earlier|sooner|hours? (earlier|before|later|after)|minutes? (earlier|before|later|after)|can'?t make|cannot make|won'?t (be|make)|not going to (make|be there)|doesn'?t work|not working|can'?t come|cannot come|instead|switch to|make it|set (it|the visit) (to|for)|come (on|at)|works better|rather|перенос|перенести|отложить|другое время|другой день|вместо|не получается|раньше|позже)\b/i.test(
    t
  );
}

function looksLikeCancelIntent(body) {
  if (looksLikeRescheduleIntent(body)) return false;
  const t = String(body || '').toLowerCase();
  return /\b(cancel(led|lation)?|don't come|do not come|not coming|call(ed)? off|отмен|не приезжайте|не надо приезжать|don't need (you|the (tech|visit|appointment)))\b/i.test(
    t
  );
}

function looksLikeTenOff(body) {
  return /\b10\s*%/.test(String(body || '')) || /\bten\s*(percent|%)\b/i.test(body);
}

function looksLikeTwentyFiveOff(body) {
  const t = String(body || '').toLowerCase();
  const compact = t.replace(/[.!,]/g, '').trim();
  return compact === '2' || /\b25\s*%/.test(t) || /\btwenty[- ]?five\b/.test(t);
}

async function listUpcomingVisits(from, clientId) {
  const docs = await jobsForContact(from, clientId);
  const now = Date.now();
  const out = [];
  for (const doc of docs) {
    const job = doc.data() || {};
    for (const visit of schedule.upcomingVisits(job, now)) {
      out.push({ doc, job, visit, start: toDate(visit.startAt) });
    }
  }
  out.sort((a, b) => a.start.getTime() - b.start.getTime());
  return out;
}

async function findUpcomingVisit(from, clientId) {
  const matches = await listUpcomingVisits(from, clientId);
  return matches[0] || null;
}

function foldPick(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9а-яё]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function matchVisitFromText(text, matches) {
  if (!Array.isArray(matches) || !matches.length) return null;
  if (matches.length === 1) return matches[0];
  const raw = String(text || '').trim();
  const compact = raw.replace(/[.!,]/g, '').trim();
  const numbered = compact.match(
    /^(?:(?:just\s+)?(?:cancel|cancelled|canceled|reschedule|move|the|number|no|#|option)\s+)?([1-9])(?:st|nd|rd|th)?$/i
  );
  if (numbered) return matches[Number(numbered[1]) - 1] || null;
  const today = voiceFacts.torontoTodayYmd();
  const ymd = voiceFacts.inferDateFromText(raw, today);
  const folded = foldPick(raw);
  const dayOnly = raw.match(/\b(?:the\s+)?([12]?\d|3[01])(?:st|nd|rd|th)?\b/i);
  const dayNum = dayOnly ? Number(dayOnly[1]) : 0;
  const scored = [];
  for (const item of matches) {
    let score = 0;
    const itemYmd = torontoDayKey(item.start);
    if (ymd && itemYmd === ymd) score += 6;
    if (dayNum >= 10 && itemYmd && Number(itemYmd.slice(-2)) === dayNum) score += 3;
    const site = foldPick(item.job.jobSiteName);
    const client = foldPick(item.job.clientName);
    const person = foldPick(visitPersonName(item.job));
    for (const name of [site, person]) {
      if (name.length >= 3 && folded.includes(name)) score += 6;
      const first = name.split(' ')[0];
      if (first.length >= 3 && folded.includes(first)) score += 5;
    }
    if (client.length >= 3 && folded.includes(client) && client !== site) score += 2;
    for (const word of foldPick(jobAddress(item.job)).split(' ')) {
      if (word.length >= 4 && folded.includes(word)) score += 2;
    }
    if (score) scored.push({ item, score });
  }
  if (!scored.length) return null;
  scored.sort((a, b) => b.score - a.score);
  if (scored.length > 1 && scored[0].score === scored[1].score) return null;
  return scored[0].item;
}

async function markPickDialog(matches, kind) {
  const byJob = new Map();
  matches.forEach((item, i) => {
    const id = item.doc.id;
    if (!byJob.has(id)) byJob.set(id, { doc: item.doc, job: item.job, items: [] });
    byJob.get(id).items.push({ item, index: i + 1 });
  });
  for (const group of byJob.values()) {
    const visits = coalesceVisits(group.job);
    for (const { item, index } of group.items) {
      const idx = visits.findIndex(
        (visit) => String(visit.id || '') === String(item.visit.id || '')
      );
      if (idx < 0) continue;
      visits[idx] = {
        ...visits[idx],
        smsDialog: 'pick_job',
        smsPickKind: kind,
        smsPickIndex: index,
      };
    }
    await group.doc.ref.update({
      visits,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

async function clearPickDialog(matches) {
  const seen = new Set();
  for (const item of matches) {
    if (seen.has(item.doc.id)) continue;
    seen.add(item.doc.id);
    const snap = await item.doc.ref.get();
    const job = snap.exists ? snap.data() || {} : item.job;
    const visits = coalesceVisits(job).map((visit) => {
      if (String(visit.smsDialog || '') !== 'pick_job') return visit;
      return {
        ...visit,
        smsDialog: '',
        smsPickKind: '',
        smsPickIndex: null,
      };
    });
    await item.doc.ref.update({
      visits,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

async function askWhichVisit({ from, clientId, matches, kind }) {
  await markPickDialog(matches, kind);
  const action = kind === 'reschedule' ? 'move' : 'cancel';
  const lines = matches.map((item, i) => {
    const name = visitPersonName(item.job);
    const unique =
      name &&
      matches.filter((other) => foldPick(visitPersonName(other.job)) === foldPick(name)).length === 1;
    const named = unique ? `${name} — ` : '';
    return `${i + 1}) ${named}${formatVisit(item.start, 'date')} at ${formatVisit(item.start, 'time')} — ${jobAddress(item.job)}`;
  });
  await sendSms({
    to: from,
    body: `You have ${matches.length} visits. Which one should we ${action}?\n${lines.join('\n')}\nReply with 1 or 2, the name, or the address.`,
    clientId,
    jobId: matches[0].doc.id,
    kind: 'pick_job',
    job: matches[0].job,
  });
  await notifyMaster(
    kind === 'reschedule'
      ? 'Клиент просит перенос — уточняем какую заявку'
      : 'Клиент просит отмену — уточняем какую заявку',
    lines.join(' · '),
    { type: 'visit_confirm', from: from || '', jobId: matches[0].doc.id }
  );
  return true;
}

async function pickVisitOrAsk({ from, body, clientId, kind }) {
  const matches = await listUpcomingVisits(from, clientId);
  if (!matches.length) return null;
  const picked = matchVisitFromText(body, matches);
  if (matches.length > 1 && !picked) {
    await askWhichVisit({ from, clientId, matches, kind });
    return { asked: true };
  }
  return { match: picked || matches[0] };
}

async function beginRescheduleAsk(match, from, clientId, body) {
  if (!match) return false;
  const slot = resolveSlotFromText(body, match.visit);
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx < 0) return false;

  if (slot) {
    const wanted = visitVars(match.job, { ...match.visit, startAt: slot });
    const moved = await tryMoveVisit(
      match,
      slot,
      from,
      clientId,
      'Клиент перенёс визит по SMS',
      {
        acceptLead: `Yes, we'll move your visit to ${wanted.date} at ${wanted.time}.`,
      }
    );
    return moved;
  }

  visits[idx] = {
    ...visits[idx],
    smsDialog: 'ask_slot',
    smsConfirmStatus: 'reschedule',
    smsPickKind: '',
    smsPickIndex: null,
  };
  await match.doc.ref.update({
    visits,
    status: 'Перенос',
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const vars = visitVars(match.job, visits[idx]);
  await sendSms({
    to: from,
    body: `Yes of course, ${vars.name}. What day and time should we come?`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'reschedule_ask',
    job: match.job,
  });
  await notifyMaster(
    'Клиент просит перенос — ИИ спросил новое время',
    `${jobName(match.job)} — ${vars.date} ${vars.time}`,
    { type: 'visit_confirm', from: from || '', jobId: match.doc.id }
  );
  return true;
}

async function beginCancelSave(match, from, clientId) {
  if (!match) return false;
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx < 0) return false;

  visits[idx] = {
    ...visits[idx],
    smsDialog: 'save_offer',
    smsConfirmStatus: 'pending',
    smsPickKind: '',
    smsPickIndex: null,
  };
  await match.doc.ref.update({
    visits,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const templates = await loadTemplates();
  const vars = visitVars(match.job, visits[idx]);
  await sendSms({
    to: from,
    body: applyTemplate(templates.cancel_save, vars),
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'cancel_save',
    job: match.job,
  });
  await notifyMaster(
    'Клиент просит отмену',
    `${jobName(match.job)} — ${vars.date} ${vars.time}`,
    { type: 'visit_confirm', from: from || '', jobId: match.doc.id }
  );
  return true;
}

async function tryHandleFreeReschedule({ from, body, clientId }) {
  if (!looksLikeRescheduleIntent(body)) return false;
  const picked = await pickVisitOrAsk({ from, body, clientId, kind: 'reschedule' });
  if (!picked || picked.asked) return Boolean(picked && picked.asked);
  return beginRescheduleAsk(picked.match, from, clientId, body);
}

async function tryHandleFreeCancel({ from, body, clientId }) {
  if (!looksLikeCancelIntent(body)) return false;
  const picked = await pickVisitOrAsk({ from, body, clientId, kind: 'cancel' });
  if (!picked || picked.asked) return Boolean(picked && picked.asked);
  return beginCancelSave(picked.match, from, clientId);
}

async function findDialogJob(from, clientId) {
  const docs = await jobsForContact(from, clientId);
  let best = null;
  for (const doc of docs) {
    const job = doc.data() || {};
    for (const visit of schedule.upcomingVisits(job)) {
      const dialog = String(visit.smsDialog || '');
      if (dialog !== 'save_offer' && dialog !== 'ask_slot' && dialog !== 'pick_job') continue;
      const start = toDate(visit.startAt) || new Date();
      if (!best || start.getTime() > best.start.getTime()) {
        best = { doc, job, visit, start };
      }
    }
  }
  return best;
}

async function confirmVisitMatch(match, from, clientId) {
  if (!match) return false;
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx < 0) return false;
  const vars = visitVars(match.job, visits[idx]);
  visits[idx] = {
    ...visits[idx],
    smsConfirmStatus: 'confirmed',
    smsConfirmNotifiedStatus: 'confirmed',
    smsDialog: '',
    smsPickKind: '',
    smsPickIndex: null,
  };
  const nextStatus =
    String(match.job.status || '').trim() === 'Перенос' ? 'Вызов' : match.job.status;
  await match.doc.ref.update({
    visits,
    ...(nextStatus && nextStatus !== match.job.status ? { status: nextStatus } : {}),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await sendSms({
    to: from,
    body: `Thanks, ${vars.name}! See you ${vars.date} at ${vars.time}. ✅`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_confirmed',
    job: match.job,
  });
  await notifyMaster(
    'Заявка подтверждена',
    `${jobName(match.job)} — ${vars.date} ${vars.time}`,
    {
      type: 'visit_confirm',
      from: from || '',
      jobId: match.doc.id,
    }
  );
  return true;
}

async function tryMoveVisit(match, slot, from, clientId, notifyTitle, opts = {}) {
  const check = await schedule.checkSlot(slot, { excludeJobId: match.doc.id });
  if (!check.ok) {
    const visits = coalesceVisits(match.job);
    const idx = visits.findIndex(
      (visit) => String(visit.id || '') === String(match.visit.id || '')
    );
    if (idx >= 0 && String(visits[idx].smsDialog || '') !== 'ask_slot') {
      visits[idx] = {
        ...visits[idx],
        smsDialog: 'ask_slot',
        smsConfirmStatus: 'reschedule',
      };
      await match.doc.ref.update({
        visits,
        status: 'Перенос',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await sendSms({
      to: from,
      body: schedule.smsBusyReply(check),
      clientId: match.job.clientId || clientId,
      jobId: match.doc.id,
      kind: 'confirm_slot_busy',
      job: match.job,
    });
    await notifyMaster(
      'Клиент выбрал занятое время',
      `${jobName(match.job)} — ${check.wantedLabel}`,
      { type: 'visit_confirm', from: from || '', jobId: match.doc.id }
    );
    return false;
  }
  const nextVisit = await applyVisitSlot(match, slot);
  if (!nextVisit) {
    await sendVisitChangeConflict(match, from, clientId);
    return false;
  }
  const nextVars = visitVars(match.job, { ...match.visit, startAt: slot });
  const lead =
    String(opts.acceptLead || '').trim() ||
    `Yes, we'll move your visit to ${nextVars.date} at ${nextVars.time}.`;
  await sendSms({
    to: from,
    body: `${lead} Our technician will contact you today. ✅`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_rescheduled',
    job: match.job,
  });
  await notifyMaster(
    notifyTitle,
    `${jobName(match.job)} — ${nextVars.date} ${nextVars.time}`,
    { type: 'visit_confirm', from: from || '', jobId: match.doc.id }
  );
  return Boolean(nextVisit);
}

async function freeTimesHint(_match) {
  return '';
}

async function sendVisitChangeConflict(match, from, clientId) {
  await sendSms({
    to: from,
    body: 'That visit has changed since our last message. No change was made from this reply. Please check the current booking with the technician.',
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_visit_changed',
    job: match.job,
  });
}

async function applyVisitSlot(match, nextDate, extra = {}) {
  return admin.firestore().runTransaction(async (tx) => {
    const snapshot = await tx.get(match.doc.ref);
    if (!snapshot.exists || isClosedJob(snapshot.data())) return null;
    const visits = coalesceVisits(snapshot.data());
    const idx = visits.findIndex((visit) => String(visit.id || '') === String(match.visit.id || ''));
    if (idx < 0 || !isScheduledVisit(visits[idx]) ||
        toDate(visits[idx].startAt)?.getTime() !== toDate(match.visit.startAt)?.getTime()) return null;
    visits[idx] = {
      ...visits[idx],
      startAt: admin.firestore.Timestamp.fromDate(nextDate),
      durationMinutes: schedule.BOOKING_MINUTES,
      smsDialog: '',
      smsConfirmStatus: 'confirmed',
      smsBookingDayKey: torontoDayKey(nextDate),
      smsBookingSlotKey: visitSlotKey(nextDate),
      smsBookingSentAt: admin.firestore.Timestamp.now(),
      ...extra,
    };
    tx.update(match.doc.ref, {
      visits,
      scheduledAt: admin.firestore.Timestamp.fromDate(nextDate),
      scheduledDate: admin.firestore.Timestamp.fromDate(nextDate),
      durationMinutes: schedule.BOOKING_MINUTES,
      status: 'Вызов',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return visits[idx];
  });
}

async function handleDialogReply(match, body, from, clientId) {
  const dialog = String(match.visit.smsDialog || '');
  if (dialog === 'pick_job') {
    const upcoming = await listUpcomingVisits(from, clientId);
    const picking = upcoming
      .filter((item) => String(item.visit.smsDialog || '') === 'pick_job')
      .sort(
        (a, b) =>
          Number(a.visit.smsPickIndex || 99) - Number(b.visit.smsPickIndex || 99)
      );
    const pool = picking.length ? picking : upcoming;
    const chosen = matchVisitFromText(body, pool);
    if (!chosen) {
      await sendSms({
        to: from,
        body: 'Please reply 1 or 2, the name, or the address of the visit.',
        clientId: match.job.clientId || clientId,
        jobId: match.doc.id,
        kind: 'pick_job',
        job: match.job,
      });
      return true;
    }
    const pickKind = String(chosen.visit.smsPickKind || 'cancel');
    await clearPickDialog(pool);
    if (pickKind === 'reschedule') {
      return beginRescheduleAsk(chosen, from, clientId, body);
    }
    return beginCancelSave(chosen, from, clientId);
  }
  const templates = await loadTemplates();
  const vars = visitVars(match.job, match.visit);
  const kind = parseConfirmReply(body);

  // «1» / yes while waiting for a new slot = keep the current visit time.
  if (dialog === 'ask_slot' && kind === 'confirmed') {
    return confirmVisitMatch(match, from, clientId);
  }

  const slot = resolveSlotFromText(body, match.visit, {
    useVisitDay: !kind,
    useVisitTime: !kind,
  });

  if (dialog === 'save_offer' && kind === 'cancelled') {
    const cancelled = await admin.firestore().runTransaction(async (tx) => {
      const snapshot = await tx.get(match.doc.ref);
      if (!snapshot.exists || isClosedJob(snapshot.data())) return false;
      const current = snapshot.data();
      const visit = coalesceVisits(current).find((item) => String(item.id || '') === String(match.visit.id || ''));
      if (!isScheduledVisit(visit) || visit.smsDialog !== 'save_offer' ||
          toDate(visit.startAt)?.getTime() !== toDate(match.visit.startAt)?.getTime()) return false;
      tx.update(match.doc.ref, schedule.cancelVisitFields(current, String(visit.id || '')));
      return true;
    });
    if (!cancelled) {
      await sendVisitChangeConflict(match, from, clientId);
      return true;
    }
    await sendSms({
      to: from,
      body: `Got it — your visit on ${vars.date} at ${vars.time} is cancelled.`,
      clientId: match.job.clientId || clientId,
      jobId: match.doc.id,
      kind: 'confirm_cancelled',
      job: match.job,
    });
    await notifyMaster('Клиент отменил заявку', `${jobName(match.job)} — отмена после предложения переноса`, {
      type: 'visit_confirm',
      from: from || '',
      jobId: match.doc.id,
    });
    return true;
  }

  if (dialog === 'save_offer' && looksLikeTwentyFiveOff(body)) {
    return keepVisit(match, from, clientId);
  }

  if (dialog === 'save_offer' && (kind === 'confirmed' || looksLikeTenOff(body) || /\b(keep|discount)\b/i.test(body))) {
    return keepVisit(match, from, clientId);
  }

  if (dialog === 'save_offer' && (kind === 'reschedule' || looksLikeRescheduleIntent(body))) {
    const visits = coalesceVisits(match.job);
    const idx = visits.findIndex(
      (visit) => String(visit.id || '') === String(match.visit.id || '')
    );
    if (idx >= 0) {
      visits[idx] = { ...visits[idx], smsDialog: 'ask_slot', smsConfirmStatus: 'reschedule' };
      await match.doc.ref.update({
        visits,
        status: 'Перенос',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await sendSms({
      to: from,
      body: applyTemplate(templates.reschedule_ask, vars),
      clientId: match.job.clientId || clientId,
      jobId: match.doc.id,
      kind: 'reschedule_ask',
      job: match.job,
    });
    return true;
  }

  if (slot) {
    return tryMoveVisit(match, slot, from, clientId, 'Клиент выбрал новое время');
  }

  await sendSms({
    to: from,
    body:
      dialog === 'ask_slot'
        ? `Please send a day and time, like Friday 11:00.`
        : `Reply with a new day and time (example: Friday 11:00) or 0 to confirm cancellation.`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_clarify',
    job: match.job,
  });
  return true;
}

async function tryHandleConfirmReply({ from, body, clientId }) {
  const text = String(from || '').includes('@') ? visibleEmailReply(body) : body;
  const kind = parseConfirmReply(text);
  const compactReply = String(text || '')
    .trim()
    .toLowerCase()
    .replace(/[\uFE0F\u20E3]/g, '')
    .replace(/[.!,#:\-]/g, '')
    .replace(/\s+/g, '');

  // Bare «1» / «0» / «5» must confirm even if a leftover ask_slot dialog is open.
  if (kind === 'confirmed' && (compactReply === '1' || compactReply === 'yes' || compactReply === 'да' || compactReply === 'ok' || compactReply === 'ок')) {
    const pending = await findPendingJob(from, clientId);
    if (pending) return confirmVisitMatch(pending, from, clientId);
    // Клиент подтвердил, а подходящего визита нет: заявку удалили, закрыли или
    // визит уже прошёл. Раньше «1» в этом случае просто исчезала — владелец
    // ждал, что статус сменится, и не понимал, почему ничего не происходит.
    console.warn(`visitSms: «${text}» от ${from} не к чему привязать`);
    await notifyMaster(
      'Клиент подтвердил, но заявка не найдена',
      `${from} прислал «${String(text || '').trim().slice(0, 20)}» — открытого визита нет`,
      { type: 'visit_confirm', peer: from || '', unmatched: '1' }
    );
    return true;
  }

  const dialogMatch = await findDialogJob(from, clientId);
  if (dialogMatch) {
    return handleDialogReply(dialogMatch, text, from, clientId);
  }

  const upcoming = kind === 'cancelled' ? await listUpcomingVisits(from, clientId) : [];
  const cancelThisSms = compactReply === '0';
  if (kind && !(kind === 'cancelled' && upcoming.length > 1 && !cancelThisSms)) {
    const match = await findPendingJob(from, clientId);
    if (match) {
      const visits = coalesceVisits(match.job);
      const idx = visits.findIndex((visit) => String(visit.id || '') === String(match.visit.id || ''));
      if (idx >= 0) {
        const templates = await loadTemplates();
        const vars = visitVars(match.job, visits[idx]);

        if (kind === 'confirmed') {
          return confirmVisitMatch(match, from, clientId);
        }

        if (kind === 'cancelled') {
          visits[idx] = { ...visits[idx], smsDialog: 'save_offer', smsConfirmStatus: 'pending' };
          await match.doc.ref.update({
            visits,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          await sendSms({
            to: from,
            body: applyTemplate(templates.cancel_save, vars),
            clientId: match.job.clientId || clientId,
            jobId: match.doc.id,
            kind: 'cancel_save',
            job: match.job,
          });
          await notifyMaster(
            'Клиент просит отмену',
            `${jobName(match.job)} — ${vars.date} ${vars.time}`,
            { type: 'visit_confirm', from: from || '', jobId: match.doc.id }
          );
          return true;
        }

        visits[idx] = { ...visits[idx], smsConfirmStatus: 'reschedule', smsDialog: 'ask_slot' };
        await match.doc.ref.update({
          visits,
          status: 'Перенос',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await sendSms({
          to: from,
          body: applyTemplate(templates.reschedule_ask, vars),
          clientId: match.job.clientId || clientId,
          jobId: match.doc.id,
          kind: 'reschedule_ask',
          job: match.job,
        });
        await notifyMaster('Нужен перенос — ждём день и время от клиента', `${jobName(match.job)}`, {
          type: 'visit_confirm',
          from: from || '',
          jobId: match.doc.id,
        });
        return true;
      }
    }
  }

  const rescheduled = await tryHandleFreeReschedule({ from, body: text, clientId });
  if (rescheduled) return true;
  return tryHandleFreeCancel({ from, body: text, clientId });
}

async function keepVisit(match, from, clientId) {
  const vars = visitVars(match.job, match.visit);
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx >= 0) {
    visits[idx] = {
      ...visits[idx],
      smsDialog: '',
      smsConfirmStatus: 'confirmed',
    };
    await match.doc.ref.update({
      visits,
      status: 'Вызов',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  await sendSms({
    to: from,
    body: `Great, we'll keep your visit on ${vars.date} at ${vars.time}. ✅`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_kept',
    job: match.job,
  });
  await notifyMaster(
    'Клиент оставил заявку',
    `${jobName(match.job)} — ${vars.date} ${vars.time}`,
    {
      type: 'visit_confirm',
      from: from || '',
      jobId: match.doc.id,
    }
  );
  return true;
}

exports.onJobWritten = onDocumentWritten(
  {
    document: `companies/${COMPANY_ID}/jobs/{jobId}`,
    region: 'us-central1',
    timeoutSeconds: 180,
    memory: '512MiB',
  },
  async (event) => {
    const before = event.data && event.data.before && event.data.before.exists
      ? event.data.before.data()
      : null;
    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data()
      : null;
    try {
      await processJobWrite(before, after, event.params.jobId);
    } catch (error) {
      console.error('onJobWritten SMS error:', error);
    }
  }
);

exports.sendVisitReminders = onSchedule(
  {
    schedule: 'every 1 hours',
    timeZone: 'America/Toronto',
    region: 'us-central1',
  },
  async () => {
    try {
      await sendMissedBookingConfirms();
      await sendMissedReviewSms();
      await sendDayBeforeReminders();
    } catch (error) {
      console.error('sendVisitReminders error:', error);
    }
  }
);

exports.tryHandleConfirmReply = tryHandleConfirmReply;
exports.sendApprovedBookingSms = sendApprovedBookingSms;
exports.recordBookingDelivery = recordBookingDelivery;
