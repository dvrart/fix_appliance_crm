/**
 * SMS-цепочка визитов: запись, напоминание за сутки, ответ 1/2, отзыв после завершения.
 */
const admin = require('firebase-admin');
const twilio = require('twilio');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');

const COMPANY_ID = 'fix_appliance_ca';
const STATUS_CALLBACK =
  'https://us-central1-fix-appliance-crm.cloudfunctions.net/smsStatusCallback';
const CLOSED = new Set(['Завершено', 'Отменено']);
const DEFAULTS = {
  booking_confirm:
    'Здравствуйте, {name}! Визит {date} в {time}. Адрес: {address}. Ответьте 1 — подтверждаю, 2 — перенос.',
  day_before:
    'Напоминание: завтра {date} в {time}. Ответьте 1 — подтверждаю, 2 — перенос.',
  job_done:
    'Ремонт завершен! Спасибо, что выбрали нас. Пожалуйста, оставьте отзыв. {review}',
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

function formatVisit(value, kind) {
  const date = toDate(value);
  if (!date) return '';
  if (kind === 'date') {
    return new Intl.DateTimeFormat('ru-RU', {
      timeZone: 'America/Toronto',
      day: 'numeric',
      month: 'long',
    }).format(date);
  }
  return new Intl.DateTimeFormat('ru-RU', {
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

function boolFlag(config, key, fallback = true) {
  if (!config || typeof config[key] !== 'boolean') return fallback;
  return config[key];
}

function applyTemplate(template, vars) {
  let text = String(template || '');
  for (const [key, value] of Object.entries(vars)) {
    text = text.split(`{${key}}`).join(value || '');
  }
  text = text.replace(/[ \t]{2,}/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  if (vars.review && !text.includes(vars.review)) {
    text = `${text} ${vars.review}`.trim();
  }
  return text;
}

function jobPhone(job) {
  if (job.hasJobSite && job.jobSitePhone) return String(job.jobSitePhone);
  return String(job.clientPhone || job.jobSitePhone || '');
}

function jobName(job) {
  return String(job.clientName || job.jobSiteName || '').trim() || 'клиент';
}

function jobAddress(job) {
  if (job.hasJobSite && job.jobSiteAddress) return String(job.jobSiteAddress);
  return String(job.clientAddress || job.jobSiteAddress || '');
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

function isScheduledVisit(visit) {
  return String(visit.outcome || 'scheduled') !== 'done';
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

async function sendSms({ to, body, clientId, jobId, kind }) {
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

async function notifyMaster(title, body, data = {}) {
  const snapshot = await companyRef().collection('fcm_tokens').get();
  const tokens = snapshot.docs.map((doc) => doc.data().token).filter(Boolean);
  if (!tokens.length) return;
  const stringData = {};
  for (const [key, value] of Object.entries(data)) {
    stringData[key] = String(value ?? '');
  }
  await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: stringData,
    android: { priority: 'high' },
  });
}

function visitVars(job, visit, reviewUrl) {
  return {
    name: jobName(job),
    date: formatVisit(visit.startAt, 'date'),
    time: formatVisit(visit.startAt, 'time'),
    address: jobAddress(job),
    review: reviewUrl || '',
  };
}

async function sendBookingIfNeeded(jobId, before, after, config, templates) {
  if (!after || CLOSED.has(after.status)) return;
  if (!boolFlag(config, 'bookingSmsEnabled')) return;
  const phone = jobPhone(after);
  if (!normalizePhone(phone)) return;

  const beforeById = new Map(
    coalesceVisits(before || {}).map((visit) => [String(visit.id || ''), visit])
  );
  const visits = coalesceVisits(after);
  let changed = false;
  const now = Date.now();

  for (const visit of visits) {
    if (!isScheduledVisit(visit)) continue;
    const start = toDate(visit.startAt);
    if (!start || start.getTime() < now - 2 * 36e5) continue;
    const dayKey = torontoDayKey(start);
    if (!dayKey) continue;
    const prev = beforeById.get(String(visit.id || ''));
    const prevDay = prev ? torontoDayKey(prev.startAt) : '';
    const already = visit.smsBookingDayKey === dayKey && visit.smsBookingSentAt;
    if (already && prevDay === dayKey) continue;
    const body = applyTemplate(templates.booking_confirm, visitVars(after, visit));
    const sent = await sendSms({
      to: phone,
      body,
      clientId: after.clientId,
      jobId,
      kind: 'booking_confirm',
    });
    if (!sent) continue;
    visit.smsBookingDayKey = dayKey;
    visit.smsBookingSentAt = admin.firestore.Timestamp.now();
    visit.smsReminderSentAt = prevDay && prevDay !== dayKey ? null : visit.smsReminderSentAt || null;
    visit.smsConfirmStatus = 'pending';
    changed = true;
  }

  if (changed) {
    await jobsRef().doc(jobId).update({
      visits,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

async function sendReviewIfNeeded(jobId, before, after, config, templates) {
  if (!after || after.status !== 'Завершено') return;
  if (before && before.status === 'Завершено') return;
  if (after.reviewSmsSentAt) return;
  if (!boolFlag(config, 'autoReviewSmsEnabled')) return;
  const phone = jobPhone(after);
  if (!normalizePhone(phone)) {
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
    to: phone,
    body,
    clientId: after.clientId,
    jobId,
    kind: 'job_done',
  });
  if (sent) {
    await jobsRef().doc(jobId).update({
      reviewSmsSentAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

async function processJobWrite(before, after, jobId) {
  if (!after) return;
  const config = await loadConfig();
  const templates = await loadTemplates();
  await sendReviewIfNeeded(jobId, before, after, config, templates);
  await sendBookingIfNeeded(jobId, before, after, config, templates);
}

async function sendDayBeforeReminders() {
  const config = await loadConfig();
  if (!boolFlag(config, 'reminderSmsEnabled')) return;
  const templates = await loadTemplates();
  const todayKey = torontoDayKey(new Date());
  const parts = todayKey.split('-').map(Number);
  const dayKey = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2] + 1))
    .toISOString()
    .slice(0, 10);

  const snapshot = await jobsRef().get();
  for (const doc of snapshot.docs) {
    const job = doc.data() || {};
    if (CLOSED.has(job.status)) continue;
    const phone = jobPhone(job);
    if (!normalizePhone(phone)) continue;
    const visits = coalesceVisits(job);
    let changed = false;
    for (const visit of visits) {
      if (!isScheduledVisit(visit)) continue;
      if (torontoDayKey(visit.startAt) !== dayKey) continue;
      if (visit.smsReminderSentAt) continue;
      if (visit.smsBookingSentAt && hoursSince(visit.smsBookingSentAt) < 8) continue;
      const body = applyTemplate(templates.day_before, visitVars(job, visit));
      const sent = await sendSms({
        to: phone,
        body,
        clientId: job.clientId,
        jobId: doc.id,
        kind: 'day_before',
      });
      if (!sent) continue;
      visit.smsReminderSentAt = admin.firestore.Timestamp.now();
      if (!visit.smsConfirmStatus) visit.smsConfirmStatus = 'pending';
      changed = true;
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
  if (!raw || raw.length > 24) return null;
  const compact = raw.replace(/[.!,]/g, '').trim();
  if (['1', 'yes', 'да', 'ok', 'ок', 'confirm', 'подтверждаю'].includes(compact)) {
    return 'confirmed';
  }
  if (['2', 'no', 'нет', 'reschedule', 'перенос'].includes(compact)) {
    return 'reschedule';
  }
  return null;
}

async function findPendingJob(from, clientId) {
  const phone = normalizePhone(from);
  let docs = [];
  if (clientId) {
    const snap = await jobsRef().where('clientId', '==', clientId).get();
    docs = snap.docs;
  } else {
    const snap = await jobsRef().get();
    docs = snap.docs.filter((doc) => {
      const data = doc.data() || {};
      return (
        normalizePhone(data.clientPhone) === phone ||
        normalizePhone(data.jobSitePhone) === phone
      );
    });
  }

  const now = Date.now() - 2 * 36e5;
  let best = null;
  for (const doc of docs) {
    const job = doc.data() || {};
    if (CLOSED.has(job.status)) continue;
    const visits = coalesceVisits(job);
    for (const visit of visits) {
      if (!isScheduledVisit(visit)) continue;
      const start = toDate(visit.startAt);
      if (!start || start.getTime() < now) continue;
      const waiting =
        visit.smsConfirmStatus === 'pending' ||
        visit.smsBookingSentAt ||
        visit.smsReminderSentAt;
      if (!waiting) continue;
      if (!best || start.getTime() < best.start.getTime()) {
        best = { doc, job, visit, start };
      }
    }
  }
  return best;
}

async function tryHandleConfirmReply({ from, body, clientId }) {
  const kind = parseConfirmReply(body);
  if (!kind) return false;
  const match = await findPendingJob(from, clientId);
  if (!match) return false;

  const visits = coalesceVisits(match.job);
  const idx = visits.findIndex((visit) => String(visit.id || '') === String(match.visit.id || ''));
  if (idx < 0) return false;
  visits[idx] = {
    ...visits[idx],
    smsConfirmStatus: kind,
  };

  const updates = {
    visits,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (kind === 'reschedule') {
    updates.status = 'Перенос';
  }
  await match.doc.ref.update(updates);

  const vars = visitVars(match.job, visits[idx]);
  const ack =
    kind === 'confirmed'
      ? `Спасибо, ${vars.name}! Ждём вас ${vars.date} в ${vars.time}.`
      : `Поняли, перенесём визит. Мы перезвоним, чтобы выбрать новое время.`;
  await sendSms({
    to: from,
    body: ack,
    clientId: match.job.clientId || clientId,
    jobId: match.doc.id,
    kind: `confirm_${kind}`,
  });

  const title =
    kind === 'confirmed'
      ? `Клиент подтвердил визит`
      : `Клиент просит перенос`;
  const text =
    kind === 'confirmed'
      ? `${jobName(match.job)} — ${vars.date} ${vars.time}`
      : `${jobName(match.job)} ответил 2 (перенос)`;
  try {
    await notifyMaster(title, text, {
      type: 'sms',
      from: from || '',
      jobId: match.doc.id,
    });
  } catch (error) {
    console.error('confirm notify error:', error);
  }
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
      await sendDayBeforeReminders();
    } catch (error) {
      console.error('sendVisitReminders error:', error);
    }
  }
);

exports.tryHandleConfirmReply = tryHandleConfirmReply;
