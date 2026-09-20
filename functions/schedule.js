/**
 * Shop calendar for the phone secretary and SMS reschedule.
 * One visit = 2 hours. Never book a window that overlaps another job.
 */
const admin = require('firebase-admin');
const voiceFacts = require('./voice_facts');

const COMPANY_ID = 'fix_appliance_ca';
const BOOKING_MINUTES = 120;
const CLOSED = new Set([
  'завершено', 'готов', 'готово', 'готова', 'completed', 'ready',
  'отменено', 'отмена', 'cancelled', 'canceled', 'cancel',
]);
const WEEKDAYS = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];
const WEEKDAYS_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function companyRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID);
}

function jobsRef() {
  return companyRef().collection('jobs');
}

function settingsRef() {
  return companyRef().collection('settings').doc('config');
}

function toDate(value) {
  if (value == null) return null;
  let date = null;
  if (typeof value.toDate === 'function') date = value.toDate();
  else if (value instanceof Date) date = value;
  else if (typeof value === 'string' || typeof value === 'number') date = new Date(value);
  else if (typeof value === 'object' && (value._seconds != null || value.seconds != null)) {
    date = new Date(Number(value._seconds ?? value.seconds) * 1000);
  }
  return date instanceof Date && Number.isFinite(date.getTime()) ? date : null;
}

function isClosedJob(job) {
  if (!job || job.deletedAt) return true;
  const status = String(job.status || '').trim().toLowerCase();
  return CLOSED.has(status) || status.includes('отмен') || status.includes('заверш');
}

function weekdayOfYmd(ymd) {
  const [y, m, d] = String(ymd).split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/// Настройки хранят 1 = понедельник … 7 = воскресенье; JS отдаёт 0 = воскресенье.
function isoWeekdayOfYmd(ymd) {
  const day = weekdayOfYmd(ymd);
  return day === 0 ? 7 : day;
}

/// Нерабочий день: не выездной день недели, праздник или отпуск.
function isClosedYmd(ymd, cfg) {
  const days = (cfg && cfg.workDays) || [1, 2, 3, 4, 5];
  if (!days.includes(isoWeekdayOfYmd(ymd))) return true;
  const key = String(ymd);
  if (((cfg && cfg.holidays) || []).includes(key)) return true;
  for (const range of (cfg && cfg.vacations) || []) {
    if (key >= range.from && key <= range.to) return true;
  }
  return false;
}

function workDaysLabel(days) {
  const sorted = [...(days || [])].sort((a, b) => a - b);
  if (!sorted.length) return 'no day';
  if (sorted.length === 7) return 'every day';
  const runs = [];
  for (const day of sorted) {
    const last = runs[runs.length - 1];
    if (last && last[last.length - 1] === day - 1) last.push(day);
    else runs.push([day]);
  }
  return runs
    .map((run) =>
      run.length >= 3
        ? `${WEEKDAYS[run[0] % 7]}–${WEEKDAYS[run[run.length - 1] % 7]}`
        : run.map((day) => WEEKDAYS[day % 7]).join(', ')
    )
    .join(', ');
}

function minutesOf(date) {
  const p = voiceFacts.torontoParts(date);
  return p.h * 60 + p.min;
}

function atMinutes(ymd, minutes) {
  const [y, m, d] = String(ymd).split('-').map(Number);
  const h = Math.floor(minutes / 60);
  const mi = minutes % 60;
  return voiceFacts.fromTorontoWallClock(y, m, d, h, mi);
}

function formatWhen(date) {
  const ymd = voiceFacts.torontoTodayYmd(date);
  return `${WEEKDAYS[weekdayOfYmd(ymd)]} at ${voiceFacts.formatHour12(minutesOf(date))}`;
}

function formatTime(date) {
  return voiceFacts.formatHour12(minutesOf(date));
}

async function loadBookingConfig() {
  const snap = await settingsRef().get();
  const config = snap.exists ? snap.data() || {} : {};
  let start = Number(config.workStartMinutes);
  let end = Number(config.workEndMinutes);
  if (!Number.isFinite(start)) start = 7 * 60;
  if (!Number.isFinite(end)) end = 21 * 60;

  const workDays = [];
  if (Array.isArray(config.workDays)) {
    for (const item of config.workDays) {
      const value = Number(item);
      if (Number.isFinite(value) && value >= 1 && value <= 7 && !workDays.includes(value)) {
        workDays.push(value);
      }
    }
  }
  if (!workDays.length) workDays.push(1, 2, 3, 4, 5);
  workDays.sort((a, b) => a - b);

  const holidays = Array.isArray(config.holidayDates)
    ? config.holidayDates
        .map((item) => String(item).trim())
        .filter((item) => /^\d{4}-\d{2}-\d{2}$/.test(item))
    : [];

  const vacations = [];
  if (Array.isArray(config.vacationRanges)) {
    for (const item of config.vacationRanges) {
      if (!item || typeof item !== 'object') continue;
      const from = String(item.from || '').trim();
      const to = String(item.to || from).trim();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(from)) continue;
      vacations.push({ from, to: /^\d{4}-\d{2}-\d{2}$/.test(to) ? to : from });
    }
  }

  return {
    durationMinutes: BOOKING_MINUTES,
    workStartMinutes: start,
    workEndMinutes: end,
    workDays,
    workDaysLabel: workDaysLabel(workDays),
    holidays,
    vacations,
  };
}

async function bookingDurationMinutes() {
  return BOOKING_MINUTES;
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
      durationMinutes: job.durationMinutes || BOOKING_MINUTES,
      outcome: 'scheduled',
    },
  ];
}

function visitBlocks(visit) {
  if (!visit) return false;
  const outcome = String(visit.outcome || 'scheduled').trim().toLowerCase();
  const confirmed = String(visit.smsConfirmStatus || '').trim().toLowerCase();
  return outcome === 'scheduled' && confirmed !== 'cancelled' && confirmed !== 'canceled';
}

function occupyMinutes(visit, job) {
  const mins = Number(visit.durationMinutes || job.durationMinutes || BOOKING_MINUTES);
  return Number.isFinite(mins) ? Math.max(15, Math.min(8 * 60, mins)) : BOOKING_MINUTES;
}

function activeJobVisits(job) {
  if (isClosedJob(job)) return [];
  return coalesceVisits(job)
    .filter((visit) => visitBlocks(visit) && toDate(visit.startAt))
    .sort((a, b) => toDate(a.startAt) - toDate(b.startAt));
}

function upcomingVisits(job, now = Date.now()) {
  return activeJobVisits(job).filter((visit) =>
    toDate(visit.startAt).getTime() + occupyMinutes(visit, job) * 60000 > Number(now));
}

async function loadBusyWindows() {
  const [snap, events] = await Promise.all([
    jobsRef().get(), companyRef().collection('calendar_events').get(),
  ]);
  const windows = [];
  for (const doc of snap.docs) {
    const job = doc.data() || {};
    for (const visit of activeJobVisits(job)) {
      const start = toDate(visit.startAt);
      windows.push({
        jobId: doc.id,
        visitId: String(visit.id || ''),
        startMs: start.getTime(),
        endMs: start.getTime() + occupyMinutes(visit, job) * 60000,
        start,
      });
    }
  }
  for (const doc of events.docs) {
    const event = doc.data() || {};
    const start = toDate(event.startAt);
    if (!start || event.deletedAt) continue;
    const duration = Number(event.durationMinutes ?? 60);
    windows.push({
      eventId: doc.id,
      startMs: start.getTime(),
      endMs: start.getTime() + (Number.isFinite(duration) ? Math.max(15, Math.min(720, duration)) : 60) * 60000,
      start,
    });
  }
  return windows;
}

/// Занято ли время. Запаса на дорогу больше нет — считаем только сам визит.
function overlaps(startMs, endMs, window, excludeJobId) {
  if (excludeJobId && window.jobId === excludeJobId) return false;
  return startMs < window.endMs && endMs > window.startMs;
}

function slotReason(start, cfg, now) {
  if (start.getTime() < now - 2 * 60000) return 'past';
  const ymd = voiceFacts.torontoTodayYmd(start);
  if (isClosedYmd(ymd, cfg)) return 'closed';
  const mins = minutesOf(start);
  if (mins < cfg.workStartMinutes || mins + cfg.durationMinutes > cfg.workEndMinutes) {
    return 'hours';
  }
  return '';
}

function candidateStarts(ymd, cfg, now) {
  const out = [];
  for (
    let m = cfg.workStartMinutes;
    m + cfg.durationMinutes <= cfg.workEndMinutes;
    m += 30
  ) {
    const start = atMinutes(ymd, m);
    if (start.getTime() < now - 2 * 60000) continue;
    out.push(start);
  }
  return out;
}

function preferHourStarts(dates) {
  const hours = dates.filter((date) => voiceFacts.torontoParts(date).min === 0);
  if (hours.length >= 3) return hours;
  return dates;
}

function freeStartsOnDay(ymd, cfg, windows, now, excludeJobId) {
  if (isClosedYmd(ymd, cfg)) return [];
  const durationMs = cfg.durationMinutes * 60000;
  return preferHourStarts(
    candidateStarts(ymd, cfg, now).filter((start) => {
      const startMs = start.getTime();
      return !windows.some((window) =>
        overlaps(startMs, startMs + durationMs, window, excludeJobId)
      );
    })
  );
}

function nextBookableDays(fromYmd, count, cfg) {
  const out = [];
  let ymd = fromYmd;
  for (let i = 0; i < 45 && out.length < count; i++) {
    if (!isClosedYmd(ymd, cfg)) out.push(ymd);
    ymd = voiceFacts.addDaysYmd(ymd, 1);
  }
  return out;
}

function pickAlternatives(wanted, cfg, windows, now, excludeJobId) {
  const wantedYmd = voiceFacts.torontoTodayYmd(wanted);
  const days = [wantedYmd];
  const later = nextBookableDays(voiceFacts.addDaysYmd(wantedYmd, 1), 6, cfg);
  for (const ymd of later) {
    if (!days.includes(ymd)) days.push(ymd);
  }
  const alts = [];
  for (const ymd of days) {
    const free = freeStartsOnDay(ymd, cfg, windows, now, excludeJobId);
    const take = ymd === wantedYmd ? 4 : 2;
    for (const start of free) {
      if (start.getTime() === wanted.getTime()) continue;
      alts.push(start);
      if (alts.filter((item) => voiceFacts.torontoTodayYmd(item) === ymd).length >= take) break;
    }
    if (alts.length >= 5) break;
  }
  return alts.slice(0, 5);
}

async function checkSlot(start, opts = {}) {
  const wanted = toDate(start);
  const cfg = opts.cfg || (await loadBookingConfig());
  const durationMinutes = Number(opts.durationMinutes) || cfg.durationMinutes;
  const now = Date.now();
  const wantedLabel = wanted ? formatWhen(wanted) : 'that time';
  if (!wanted) {
    return { ok: false, reason: 'invalid', wantedLabel, alternatives: [], altSpeech: '' };
  }
  const reason = slotReason(wanted, { ...cfg, durationMinutes }, now);
  const windows = await loadBusyWindows();
  const startMs = wanted.getTime();
  const endMs = startMs + durationMinutes * 60000;
  const busy =
    !reason &&
    windows.some((window) =>
      overlaps(startMs, endMs, window, opts.excludeJobId)
    );
  const ok = !reason && !busy;
  const alternatives = ok
    ? []
    : pickAlternatives(
        wanted,
        { ...cfg, durationMinutes },
        windows,
        now,
        opts.excludeJobId
      );
  const altSpeech = alternatives.map(formatWhen).join(', ');
  return {
    ok,
    reason: ok ? '' : reason || 'busy',
    wantedLabel,
    alternatives,
    altSpeech,
    workDaysLabel: cfg.workDaysLabel,
    hoursLabel: `${voiceFacts.formatHour12(cfg.workStartMinutes)} to ${voiceFacts.formatHour12(cfg.workEndMinutes)}`,
    lastStartLabel: voiceFacts.formatHour12(cfg.workEndMinutes - durationMinutes),
  };
}

function altSpeech(check) {
  return (check && check.altSpeech) || '';
}

function smsBusyReply(check) {
  const alts = altSpeech(check);
  const days = check.workDaysLabel || 'Monday–Friday';
  const hours = check.hoursLabel || '7 a.m. to 9 p.m.';
  const offer = alts
    ? `That time is taken. I can do ${alts} — reply with one of those.`
    : `That time is taken. Please send another day, ${days} ${hours}.`;
  if (check.reason === 'closed') {
    return `The technician doesn't visit that day — we work ${days}. ${offer}`;
  }
  if (check.reason === 'hours' || check.reason === 'past') {
    const last = check.lastStartLabel ? ` (last start ${check.lastStartLabel})` : '';
    return `We can't take ${check.wantedLabel} — we work ${days} ${hours}${last}. ${offer}`;
  }
  return `${check.wantedLabel} isn't free — that window overlaps another job. ${offer}`;
}

function reviewNote(check) {
  if (!check || check.ok) return '';
  const alts = altSpeech(check);
  return `Клиент хотел ${check.wantedLabel} — окно 2 часа занято (${check.reason || 'busy'}). Свободно: ${alts || 'нет в ближайшие дни'}.`;
}

async function freeSpeechForDay(ymd, opts = {}) {
  const cfg = await loadBookingConfig();
  const windows = await loadBusyWindows();
  const free = freeStartsOnDay(ymd, cfg, windows, Date.now(), opts.excludeJobId);
  if (!free.length) return '';
  return free.slice(0, 5).map(formatTime).join(', ');
}

function briefTaken(windows, cfg, now) {
  const horizon = now + 12 * 24 * 3600 * 1000;
  const upcoming = windows
    .filter((window) => window.endMs > now && window.startMs < horizon)
    .sort((a, b) => a.startMs - b.startMs)
    .slice(0, 16);
  if (!upcoming.length) return 'No occupied windows in the next 12 days.';
  const byDay = new Map();
  for (const window of upcoming) {
    const ymd = voiceFacts.torontoTodayYmd(window.start);
    const end = new Date(window.endMs);
    const line = `${formatTime(window.start)}–${formatTime(end)}`;
    const list = byDay.get(ymd) || [];
    list.push(line);
    byDay.set(ymd, list);
  }
  return [...byDay.entries()]
    .map(([ymd, lines]) => `${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd}: ${lines.join(', ')}`)
    .join('. ');
}

function briefOpen(cfg, windows, now) {
  const today = voiceFacts.torontoTodayYmd(new Date(now));
  const days = nextBookableDays(today, 5, cfg);
  const parts = [];
  for (const ymd of days) {
    // Раньше здесь стояло .slice(0, 5) — модель видела только пять утренних
    // окон и на просьбу «завтра в шесть вечера» отвечала, что всё занято, даже
    // когда день был пуст целиком. Список должен быть полным за день:
    // при рабочем дне 7:00–21:00 это не больше 13 значений.
    const free = freeStartsOnDay(ymd, cfg, windows, now, null);
    if (!free.length) {
      parts.push(`${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd}: full`);
      continue;
    }
    parts.push(
      `${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd}: ${free.map(formatTime).join(', ')}`
    );
  }
  return parts.join('. ');
}

async function calendarBrief() {
  const cfg = await loadBookingConfig();
  const windows = await loadBusyWindows();
  const now = Date.now();
  const taken = briefTaken(windows, cfg, now);
  const open = briefOpen(cfg, windows, now);
  const hours = `${voiceFacts.formatHour12(cfg.workStartMinutes)}–${voiceFacts.formatHour12(cfg.workEndMinutes)}`;
  const lastStart = voiceFacts.formatHour12(cfg.workEndMinutes - cfg.durationMinutes);
  const closed = [1, 2, 3, 4, 5, 6, 7]
    .filter((day) => !cfg.workDays.includes(day))
    .map((day) => WEEKDAYS[day % 7]);
  const closedLine = closed.length
    ? `${closed.join(' and ')}: no visit — offer the next working day.`
    : 'The technician visits every day.';
  return `CALENDAR — each visit is 2 hours, one job per window. Do not confirm a taken start time.
Take orders 24/7. Technician visits ${cfg.workDaysLabel} ${hours}. ${closedLine} Public holidays: take the order; the technician must agree.
Taken: ${taken}
Open 2-hour starts on working days: ${open}
These are shop-wide availability snapshots, NOT the caller's appointments. Personal events block time without disclosing their details. A missing time or a day outside this brief does not mean it is taken: check the current calendar before accepting or rejecting a proposed time.
Let the caller name the time first. If the live check says it is taken, offer the nearest free starts the SAME day. Only move to another day if that day is full or they ask. Last start is ${lastStart} so the visit ends by ${voiceFacts.formatHour12(cfg.workEndMinutes)}.`;
}

const APPLIANCE_EN = {
  'Холодильник': 'fridge',
  'Морозильник': 'freezer',
  'Стиральная машина': 'washer',
  'Сушилка': 'dryer',
  'Посудомойка': 'dishwasher',
  'Плита': 'cooktop',
  'Духовка': 'oven',
  'Микроволновка': 'microwave',
};

function applianceEnOf(job) {
  const list = job && Array.isArray(job.appliances) ? job.appliances : [];
  const raw = String(
    (job && job.applianceType) || (list[0] && list[0].type) || ''
  ).trim();
  if (!raw) return '';
  return APPLIANCE_EN[raw] || raw;
}

function appointmentDetails(job, visit) {
  const start = toDate(visit.startAt);
  const day = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
  }).format(start);
  return {
    jobId: job.id,
    visitId: String(visit.id || ''),
    startAt: start.toISOString(),
    when: `${day} at ${formatTime(start)} Toronto`,
    appliance: [applianceEnOf(job), String(job.brand || '').trim()].filter(Boolean).join(' '),
    address: String((job.hasJobSite ? job.jobSiteAddress : job.clientAddress) || job.clientAddress || '').trim(),
    needsReview: job.needsReview === true,
    confirmed: String(visit.smsConfirmStatus || '').trim().toLowerCase() === 'confirmed',
  };
}

function callerAppointments(jobs, now = Date.now()) {
  return jobs.flatMap((job) => upcomingVisits(job, now).map((visit) => appointmentDetails(job, visit)))
    .sort((a, b) => a.startAt.localeCompare(b.startAt));
}

function describeCallerJobs(jobs, now = Date.now()) {
  const appointments = callerAppointments(jobs, now);
  const parts = [];
  if (!appointments.length) {
    parts.push('No upcoming visits for this caller. Past, completed, cancelled and deleted entries are history, not current bookings.');
  } else {
    parts.push('Upcoming visits for THIS CALLER, earliest first (not other customers):');
    for (const visit of appointments) {
      const state = visit.needsReview ? 'provisional, awaiting technician review' : visit.confirmed ? 'booked and client-confirmed' : 'booked';
      parts.push(`${visit.when}${visit.appliance ? `, ${visit.appliance}` : ''}${visit.address ? ` at ${visit.address}` : ''} — ${state}.`);
    }
    parts.push('These orders are already on file. Do not take them again or ask to reconfirm an unchanged visit.');
  }
  const withoutVisit = jobs.filter((job) => !isClosedJob(job) && !upcomingVisits(job, now).length);
  if (withoutVisit.length) parts.push(`${withoutVisit.length} open repair job(s) have no upcoming visit. Do not invent a time or book another visit unless the caller requests one.`);
  parts.push('This is a server snapshot, not a promise. Recheck the current caller schedule before answering an appointment question. Never use an old transcript as proof of a booking.');
  return parts.join(' ');
}

function normalizedPhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits.length >= 10 ? digits.slice(-10) : '';
}

function belongsToCaller(job, { phone, clientId } = {}) {
  const normalized = normalizedPhone(phone);
  return Boolean((clientId && job.clientId === clientId) ||
    (normalized && [job.clientPhone, job.jobSitePhone].some((value) => normalizedPhone(value) === normalized)));
}

async function loadCallerSchedule(caller) {
  if (!normalizedPhone(caller && caller.phone) && !(caller && caller.clientId)) {
    return { ok: false, error: 'unknown_caller', brief: 'Caller identity is unavailable. Do not claim an appointment exists or is absent.' };
  }
  const snapshot = await jobsRef().get();
  const jobs = snapshot.docs.map((doc) => ({ ...doc.data(), id: doc.id }))
    .filter((job) => belongsToCaller(job, caller));
  const now = Date.now();
  return {
    ok: true,
    checkedAt: new Date(now).toISOString(),
    appointments: callerAppointments(jobs, now),
    brief: describeCallerJobs(jobs, now),
  };
}

function cancelVisitFields(job, visitId, callSid = '') {
  const visits = coalesceVisits(job);
  const index = visits.findIndex((visit) => String(visit.id || '') === visitId);
  if (index < 0) return null;
  visits[index] = {
    ...visits[index],
    outcome: 'cancelled',
    smsConfirmStatus: 'cancelled',
    smsDialog: '',
    smsPickKind: '',
    smsPickIndex: null,
    smsBookingPending: false,
    ...(callSid ? { cancelledByCallId: callSid, cancelledAt: admin.firestore.Timestamp.now() } : {}),
  };
  const remaining = activeJobVisits({ ...job, visits });
  const next = remaining.at(-1);
  return {
    visits,
    scheduledAt: next ? next.startAt : null,
    scheduledDate: next ? next.startAt : null,
    durationMinutes: next ? occupyMinutes(next, job) : job.durationMinutes || BOOKING_MINUTES,
    status: remaining.length ? job.status : 'Отменено',
    needsReview: remaining.length ? job.needsReview === true : false,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function cancelCallerVisit(caller, { jobId, visitId, expectedStartAt } = {}) {
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/') && id !== '.' && id !== '..';
  if (!caller || !validId(caller.callSid) || !validId(jobId) || !validId(visitId) || !toDate(expectedStartAt)) {
    return { ok: false, error: 'invalid_request' };
  }
  return admin.firestore().runTransaction(async (tx) => {
    const jobRef = jobsRef().doc(jobId);
    const callRef = companyRef().collection('calls').doc(caller.callSid);
    const [jobSnap, callSnap] = await Promise.all([tx.get(jobRef), tx.get(callRef)]);
    if (!jobSnap.exists || !callSnap.exists) return { ok: false, error: 'not_found' };
    const job = { ...jobSnap.data(), id: jobId };
    const call = callSnap.data() || {};
    const phone = normalizedPhone(call.fromNumber);
    if (!phone || phone !== normalizedPhone(caller.phone) ||
        !belongsToCaller(job, { phone, clientId: call.clientId })) {
      return { ok: false, error: 'not_found' };
    }
    const visit = coalesceVisits(job).find((item) => String(item.id || '') === visitId);
    const start = visit && toDate(visit.startAt);
    if (!start || start.getTime() !== toDate(expectedStartAt).getTime()) {
      return { ok: false, error: 'visit_changed' };
    }
    if (visit.outcome === 'cancelled' && visit.cancelledByCallId === caller.callSid) {
      return { ok: true, changed: false, status: 'cancelled', appointment: appointmentDetails(job, visit) };
    }
    if (call.deletedAt || call.jobCreateBlocked || call.aiSkip || call.status !== 'in-progress') {
      return { ok: false, error: 'call_inactive' };
    }
    if (!upcomingVisits(job).some((item) => String(item.id || '') === visitId)) {
      return { ok: false, error: 'not_active' };
    }
    tx.update(jobRef, cancelVisitFields(job, visitId, caller.callSid));
    tx.update(callRef, {
      calendarActions: [...(Array.isArray(call.calendarActions) ? call.calendarActions : []), {
        action: 'cancel', jobId, visitId, startAt: visit.startAt, at: admin.firestore.Timestamp.now(),
      }],
    });
    return { ok: true, changed: true, status: 'cancelled', appointment: appointmentDetails(job, visit) };
  });
}

module.exports = {
  describeCallerJobs,
  loadCallerSchedule,
  cancelCallerVisit,
  cancelVisitFields,
  isClosedJob,
  coalesceVisits,
  visitBlocks,
  activeJobVisits,
  upcomingVisits,
  BOOKING_MINUTES,
  bookingDurationMinutes,
  loadBookingConfig,
  checkSlot,
  calendarBrief,
  smsBusyReply,
  reviewNote,
  freeSpeechForDay,
  formatWhen,
};
