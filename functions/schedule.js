/**
 * Shop calendar for the phone secretary and SMS reschedule.
 * One visit = 2 hours. Never book a window that overlaps another job.
 */
const admin = require('firebase-admin');
const voiceFacts = require('./voice_facts');

const COMPANY_ID = 'fix_appliance_ca';
const BOOKING_MINUTES = 120;
const CLOSED = new Set(['Завершено', 'Отменено']);
const ACTIVE_STATUSES = [
  'Вызов',
  'В работе',
  'Перенос',
  'Ожидание запчасти',
  'Установка',
  'Позвонить',
  'Повторный визит',
  'Повтор',
];
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

let busyCache = { at: 0, windows: [] };

function jobsRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('jobs');
}

function settingsRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('settings').doc('config');
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
  if (start === 9 * 60 && end === 19 * 60) {
    start = 7 * 60;
    end = 21 * 60;
  }
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
  const outcome = String(visit.outcome || 'scheduled');
  if (outcome === 'done' || outcome === 'cancelled') return false;
  if (String(visit.smsConfirmStatus || '') === 'cancelled') return false;
  return true;
}

function occupyMinutes(visit, job) {
  const mins = Number(visit.durationMinutes || job.durationMinutes || BOOKING_MINUTES);
  if (!Number.isFinite(mins) || mins < 15) return BOOKING_MINUTES;
  return mins;
}

async function loadBusyWindows() {
  if (Date.now() - busyCache.at < 12000 && busyCache.windows) {
    return busyCache.windows;
  }
  const snap = await jobsRef().where('status', 'in', ACTIVE_STATUSES).get();
  const windows = [];
  for (const doc of snap.docs) {
    const job = doc.data() || {};
    const status = String(job.status || '').trim().toLowerCase();
    if (
      CLOSED.has(String(job.status || '')) ||
      status.includes('отмен') ||
      status === 'cancelled' ||
      status === 'canceled' ||
      status.includes('заверш') ||
      status === 'completed' ||
      job.deletedAt
    ) {
      continue;
    }
    for (const visit of coalesceVisits(job)) {
      if (!visitBlocks(visit)) continue;
      const start = toDate(visit.startAt);
      if (!start) continue;
      const mins = occupyMinutes(visit, job);
      windows.push({
        jobId: doc.id,
        startMs: start.getTime(),
        endMs: start.getTime() + mins * 60000,
        start,
      });
    }
  }
  busyCache = { at: Date.now(), windows };
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
  const wanted = start instanceof Date ? start : toDate(start);
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
  if (!upcoming.length) return 'No visits on the calendar yet.';
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
    .map(([ymd, lines]) => `${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd.slice(8)}: ${lines.join(', ')}`)
    .join('. ');
}

function briefOpen(cfg, windows, now) {
  const today = voiceFacts.torontoTodayYmd(new Date(now));
  const days = nextBookableDays(today, 5, cfg);
  const parts = [];
  for (const ymd of days) {
    const free = freeStartsOnDay(ymd, cfg, windows, now, null).slice(0, 5);
    if (!free.length) {
      parts.push(`${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd.slice(8)}: full`);
      continue;
    }
    parts.push(
      `${WEEKDAYS_SHORT[weekdayOfYmd(ymd)]} ${ymd.slice(8)}: ${free.map(formatTime).join(', ')}`
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
If they want a taken time, offer another time the SAME day first. Only offer another day if that day is full or they ask. Last start is ${lastStart} so the visit ends by ${voiceFacts.formatHour12(cfg.workEndMinutes)}.`;
}

module.exports = {
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
