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

const { getCompanyId, functionsBaseUrl } = require('./tenant');

const COMPANY_ID = getCompanyId();
const STATUS_CALLBACK = `${functionsBaseUrl()}/smsStatusCallback`;
const CLOSED = new Set(['Завершено', 'Отменено']);
const DEFAULTS = {
  booking_confirm:
    'Hi {name}! ✅\n\n📅 Visit: {date}\n🕘 Time: {time}\n📍 {address}\n\nReply:\n1 ✅ confirm\n0 ❌ cancel\n5 🔁 another day',
  day_before:
    'Reminder 📅\n\n{date} at 🕘 {time}\n📍 {address}\n\nReply 1 ✅ to confirm this visit, 0 ❌ to cancel, 5 🔁 to pick another day.',
  job_done:
    'Repair complete! ✅\nThank you for choosing us.\n⭐ Please leave a review:\n{review}',
  cancel_save:
    'Sorry you need to cancel, {name}. 😔\nWe can keep the visit with 10% off, or even 25% off, or move it to another day.\n\nReply:\n• a new day and time (example: Friday 11:00)\n• 1 — keep {date} at {time} with 10% off\n• 2 — keep it with 25% off\n• 0 — cancel',
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
  // Old phone-job confirms went out as SMS only.
  if (!viaEmail && visit && visit.smsBookingSentAt && !via) return true;
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
  const raw = Array.isArray(job.visits) ? job.visits : [];
  if (raw.length) return raw.map((visit) => ({ ...visit }));
  const scheduled = job.scheduledAt || job.scheduledDate;
  if (!scheduled) return [];
  return [
    {
      id: 'legacy',
      startAt: scheduled,
      durationMinutes: job.durationMinutes || 60,
      outcome: 'scheduled',
    },
  ];
}

function isClosedJob(job) {
  if (!job) return false;
  if (job.deletedAt) return true;
  const status = String(job.status || '').trim();
  if (CLOSED.has(status)) return true;
  const n = status.toLowerCase();
  return (
    n.includes('отмен') ||
    n === 'cancelled' ||
    n === 'canceled' ||
    n === 'cancel' ||
    n.includes('заверш') ||
    n === 'completed'
  );
}

function isScheduledVisit(visit) {
  const outcome = String(visit.outcome || 'scheduled');
  if (outcome === 'done' || outcome === 'cancelled') return false;
  if (String(visit.smsConfirmStatus || '') === 'cancelled') return false;
  return true;
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
  if (!client || !e164 || !text) return false;
  const header = await getSmsHeader();
  const wrapped = withSmsHeader(text, header);
  const message = await client.messages.create({
    from: process.env.TWILIO_PHONE_NUMBER,
    to: e164,
    body: wrapped,
    statusCallback: STATUS_CALLBACK,
  });
  await messagesRef().add({
    sid: message.sid,
    from: process.env.TWILIO_PHONE_NUMBER,
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

async function sendBookingIfNeeded(jobId, before, after, config, templates) {
  if (!after || after.deletedAt) return;
  if (after.needsReview === true) return;
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
    const storedSlot = String(visit.smsBookingSlotKey || '').trim();
    const alreadyThisSlot =
      Boolean(visit.smsBookingSentAt) &&
      ((storedSlot && storedSlot === slotKey) ||
        (!storedSlot && prev && prevSlot === slotKey) ||
        (!storedSlot && !prev && visit.smsBookingDayKey === dayKey && !prevSlot));
    let texted = alreadyThisSlot && visitSentSms(visit, viaEmail);
    if (alreadyThisSlot && (texted || !hasPhone)) {
      continue;
    }
    const moved =
      Boolean(visit.smsBookingSentAt) &&
      ((prev && prevSlot && prevSlot !== slotKey) ||
        (storedSlot && storedSlot !== slotKey) ||
        (visit.smsBookingDayKey && visit.smsBookingDayKey !== dayKey));
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
    visit.smsBookingSentAt = visit.smsBookingSentAt || admin.firestore.Timestamp.now();
    visit.smsBookingSentSms = texted;
    visit.smsBookingSentEmail = false;
    visit.smsBookingVia = 'sms';
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
  if (!after || after.status !== 'Завершено') return;
  if (before && before.status === 'Завершено') return;
  if (after.reviewSmsSentAt) return;
  if (!boolFlag(config, 'autoReviewSmsEnabled')) return;
  const viaEmail = isEmailJob(after);
  const phone = jobPhone(after);
  if (viaEmail) {
    const email = await resolveJobEmail(after);
    if (!email) {
      await jobsRef().doc(jobId).update({
        reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }
  } else if (!normalizePhone(phone)) {
    await jobsRef().doc(jobId).update({
      reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
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
  const sent = await sendSms({
    to: viaEmail ? await resolveJobEmail(after) : phone,
    body,
    clientId: after.clientId,
    jobId,
    kind: 'job_done',
    job: after,
  });
  if (sent) {
    await jobsRef().doc(jobId).update({
      reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
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

async function processJobWrite(before, after, jobId) {
  if (!after) return;
  if (after.deletedAt || isClosedJob(after)) {
    await blockJobCreateForJob(jobId, after.sourceCallId);
    return;
  }
  const config = await loadConfig();
  const templates = await loadTemplates();
  await sendReviewIfNeeded(jobId, before, after, config, templates);
  await sendBookingIfNeeded(jobId, before, after, config, templates);
}

async function sendDayBeforeReminders() {
  const config = await loadConfig();
  if (!boolFlag(config, 'reminderSmsEnabled')) return;
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
  const raw = String(body || '').trim().toLowerCase();
  if (!raw) return null;
  const compact = raw.replace(/[.!,]/g, '').trim();
  if (['1', 'yes', 'да', 'ok', 'ок', 'confirm', 'подтверждаю', 'keep'].includes(compact)) {
    return 'confirmed';
  }
  // Only a bare cancel code. "cancel August 31" / "cancel Michelle" is free-text.
  if (
    ['0', 'cancel', 'cancelled', 'canceled', 'отмена', 'отменил', 'отменить', 'just cancel'].includes(
      compact
    )
  ) {
    return 'cancelled';
  }
  if (['5', 'reschedule', 'перенос'].includes(compact)) {
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
  if (clientId) {
    const snap = await jobsRef().where('clientId', '==', clientId).get();
    return snap.docs;
  }
  const snap = await jobsRef().get();
  if (String(from || '').includes('@')) {
    const email = String(from).trim().toLowerCase();
    return snap.docs.filter((doc) => emailsOfJob(doc.data() || {}).includes(email));
  }
  const phone = normalizePhone(from);
  if (!phone) return [];
  return snap.docs.filter((doc) => {
    const data = doc.data() || {};
    return (
      normalizePhone(data.clientPhone) === phone ||
      normalizePhone(data.jobSitePhone) === phone
    );
  });
}

async function findPendingJob(from, clientId) {
  const docs = await jobsForContact(from, clientId);

  const now = Date.now() - 2 * 36e5;
  let best = null;
  for (const doc of docs) {
    const job = doc.data() || {};
    if (isClosedJob(job)) continue;
    const visits = coalesceVisits(job);
    for (const visit of visits) {
      if (!isScheduledVisit(visit)) continue;
      const start = toDate(visit.startAt);
      if (!start || start.getTime() < now) continue;
      if (
        visit.smsConfirmStatus === 'confirmed' ||
        visit.smsConfirmStatus === 'reschedule' ||
        visit.smsConfirmStatus === 'cancelled'
      ) {
        continue;
      }
      const waiting =
        visit.smsConfirmStatus === 'pending' ||
        visit.smsBookingSentAt ||
        visit.smsReminderSentAt;
      if (!waiting) continue;
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
  return /\b(postpone|reschedule|another day|different (day|time)|push (it|back)|move (it|the (visit|appointment|booking))|change (the )?(visit|appointment|time|day)|can (we|i) (postpone|reschedule|move|change)|is it possible to (postpone|reschedule)|later (day|date|time)|can'?t make|cannot make|won'?t (be|make)|not going to (make|be there)|перенос|перенести|отложить|другое время|другой день)\b/i.test(
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
  const now = Date.now() - 2 * 36e5;
  const out = [];
  for (const doc of docs) {
    const job = doc.data() || {};
    if (isClosedJob(job)) continue;
    const visits = coalesceVisits(job);
    for (const visit of visits) {
      if (!isScheduledVisit(visit)) continue;
      if (visit.smsConfirmStatus === 'cancelled') continue;
      const start = toDate(visit.startAt);
      if (!start || start.getTime() < now) continue;
      out.push({ doc, job, visit, start });
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
  const slot = parseSlotFromText(body);
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx < 0) return false;

  if (slot) {
    return tryMoveVisit(
      match,
      slot,
      from,
      clientId,
      'Клиент перенёс визит по SMS'
    );
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
    'Клиент просит отмену — ИИ предлагает скидку или перенос',
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
    const visits = coalesceVisits(job);
    for (const visit of visits) {
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

async function tryMoveVisit(match, slot, from, clientId, notifyTitle) {
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
  const nextVars = visitVars(match.job, { ...match.visit, startAt: slot });
  await sendSms({
    to: from,
    body: `Yes of course — we'll move your visit to ${nextVars.date} at ${nextVars.time}. Our technician will contact you today. ✅`,
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

async function applyVisitSlot(match, nextDate, extra = {}) {
  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex(
    (visit) => String(visit.id || '') === String(match.visit.id || '')
  );
  if (idx < 0) return null;
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
  await match.doc.ref.update({
    visits,
    scheduledAt: admin.firestore.Timestamp.fromDate(nextDate),
    durationMinutes: schedule.BOOKING_MINUTES,
    status: 'Вызов',
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return visits[idx];
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
  const fallbackDate = fallbackDayKey(match.visit);
  const fallbackTime = formatVisit(match.visit.startAt, 'time');
  const slot = parseSlotFromText(
    body,
    kind ? '' : fallbackDate,
    kind ? '' : fallbackTime
  );

  if (dialog === 'save_offer' && kind === 'cancelled') {
    const visits = coalesceVisits(match.job);
    const idx = visits.findIndex(
      (visit) => String(visit.id || '') === String(match.visit.id || '')
    );
    if (idx >= 0) {
      visits[idx] = {
        ...visits[idx],
        smsDialog: '',
        smsConfirmStatus: 'cancelled',
        outcome: 'cancelled',
      };
      await match.doc.ref.update({
        visits,
        status: 'Отменено',
        needsReview: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await sendSms({
      to: from,
      body: `Got it — your visit on ${vars.date} at ${vars.time} is cancelled.`,
      clientId: match.job.clientId || clientId,
      jobId: match.doc.id,
      kind: 'confirm_cancelled',
      job: match.job,
    });
    await notifyMaster('Клиент отменил заявку', `${jobName(match.job)} — отмена после предложения скидки`, {
      type: 'visit_confirm',
      from: from || '',
      jobId: match.doc.id,
    });
    return true;
  }

  if (dialog === 'save_offer' && looksLikeTwentyFiveOff(body)) {
    return keepVisitWithDiscount(match, from, clientId, 25);
  }

  if (dialog === 'save_offer' && (kind === 'confirmed' || looksLikeTenOff(body) || /\b(keep|discount)\b/i.test(body))) {
    return keepVisitWithDiscount(match, from, clientId, 10);
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
        : `Reply with a new day and time (Friday 11:00), 1 for 10% off, 2 for 25% off, or 0 to cancel.`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_clarify',
    job: match.job,
  });
  return true;
}

async function tryHandleConfirmReply({ from, body, clientId }) {
  const text = String(from || '').includes('@') ? visibleEmailReply(body) : body;
  const dialogMatch = await findDialogJob(from, clientId);
  if (dialogMatch) {
    return handleDialogReply(dialogMatch, text, from, clientId);
  }

  const kind = parseConfirmReply(text);
  const compactReply = String(text || '').replace(/[.!,]/g, '').trim();
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
          visits[idx] = { ...visits[idx], smsConfirmStatus: 'confirmed', smsDialog: '' };
          await match.doc.ref.update({
            visits,
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
          await notifyMaster('Заявка подтверждена', `${jobName(match.job)} — ${vars.date} ${vars.time}`, {
            type: 'visit_confirm',
            from: from || '',
            jobId: match.doc.id,
          });
          return true;
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
            'Клиент нажал 0 — ИИ предлагает скидку или перенос',
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

async function keepVisitWithDiscount(match, from, clientId, percent) {
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
      note: [visits[idx].note, `${percent}% off (kept after cancel SMS)`]
        .filter(Boolean)
        .join(' · '),
    };
    await match.doc.ref.update({
      visits,
      status: 'Вызов',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  await sendSms({
    to: from,
    body: `Great, ${vars.name}! We'll keep ${vars.date} at ${vars.time}, with ${percent}% off. See you then. ✅`,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: 'confirm_kept',
    job: match.job,
  });
  await notifyMaster(
    `Клиент оставил заявку со скидкой ${percent}%`,
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
      await sendDayBeforeReminders();
    } catch (error) {
      console.error('sendVisitReminders error:', error);
    }
  }
);

exports.tryHandleConfirmReply = tryHandleConfirmReply;
