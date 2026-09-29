/**
 * Дубляжи заявок с одного номера.
 *
 * Правило (утверждено владельцем): один и тот же телефон и меньше 48 часов
 * между заявками — это дубляж, даже если техника разная или не названа.
 * Исключение: если у обеих заявок стоит адрес и адреса разные, это два разных
 * вызова одного человека (управляющий домами), соединять нельзя.
 *
 * Автоматически соединяется только входящий черновик — заявка, которая пришла
 * сама (секретарь / SMS / письмо / сайт) и у которой ещё нет визита. Заявку,
 * заведённую руками, или ту, где визит уже назначен, сервер не трогает: он
 * ставит possibleDuplicateOfJobId, а решает мастер кнопкой в карточке.
 *
 * Соединение = перелить данные в главную заявку и закрыть дубль. След остаётся
 * только в истории заявки (changes), в описание служебных строк не пишем.
 */
const admin = require('firebase-admin');
const schedule = require('./schedule');
const voiceFacts = require('./voice_facts');

const COMPANY_ID = 'fix_appliance_ca';
const DUPLICATE_WINDOW_MS = 48 * 60 * 60 * 1000;
const INCOMING_SOURCES = new Set(['phone', 'secretary', 'sms', 'email', 'website']);

function companyRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID);
}

function jobsRef() {
  return companyRef().collection('jobs');
}

function callsRef() {
  return companyRef().collection('calls');
}

function messagesRef() {
  return companyRef().collection('messages');
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

function normalizePhone(value) {
  if (!value) return '';
  const digits = String(value).replace(/\D/g, '');
  return digits.length > 10 ? digits.slice(-10) : digits;
}

function jobPhones(job) {
  const out = new Set();
  for (const raw of [job && job.clientPhone, job && job.jobSitePhone]) {
    const phone = normalizePhone(raw);
    if (phone.length >= 10) out.add(phone);
  }
  return [...out];
}

function sharePhone(a, b) {
  const mine = new Set(jobPhones(a));
  return jobPhones(b).some((phone) => mine.has(phone));
}

function createdMs(job) {
  const date = toDate(job && job.createdAt);
  return date ? date.getTime() : 0;
}

function withinWindow(a, b, windowMs = DUPLICATE_WINDOW_MS) {
  const first = createdMs(a);
  const second = createdMs(b);
  // Импорт без даты создания под правило 48 часов не попадает.
  if (!first || !second) return false;
  return Math.abs(first - second) <= windowMs;
}

function isMerged(job) {
  return Boolean(job && String(job.mergedIntoJobId || '').trim());
}

function isOpenJob(job) {
  if (!job || job.deletedAt) return false;
  if (isMerged(job)) return false;
  return !schedule.isClosedJob(job);
}

function liveVisits(job) {
  const visits = Array.isArray(job && job.visits) ? job.visits : [];
  return visits.filter(
    (visit) => visit && visit.outcome !== 'cancelled' && toDate(visit.startAt)
  );
}

function hasVisit(job) {
  if (liveVisits(job).length) return true;
  return Boolean(toDate(job && job.scheduledAt) || toDate(job && job.scheduledDate));
}

/** phone / sms / email / website — заявка пришла сама, а не заведена руками. */
function jobSource(job) {
  const src = String((job && job.source) || '').trim().toLowerCase();
  if (src) return src === 'secretary' ? 'phone' : src;
  if (job && job.sourceCallId) return 'phone';
  if (job && (job.sourceEmailId || job.sourceEmailFrom)) return 'email';
  return '';
}

function isIncomingJob(job) {
  return INCOMING_SOURCES.has(jobSource(job));
}

/** Входящий черновик: пришёл сам и визита ещё нет. Такие соединяем молча. */
function isIncomingDraft(job) {
  return isOpenJob(job) && isIncomingJob(job) && !hasVisit(job);
}

function historyActor(job) {
  switch (jobSource(job)) {
    case 'phone':
      return 'secretary';
    case 'sms':
      return 'sms';
    case 'email':
    case 'website':
      return 'email';
    default:
      return 'owner';
  }
}

function addressKey(job) {
  const raw = [job && job.jobSiteAddress, job && job.clientAddress]
    .map((value) => String(value || '').trim())
    .find(Boolean);
  return String(raw || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

/** Два разных адреса у одного номера — это два разных вызова, не дубляж. */
function differentAddress(a, b) {
  const mine = addressKey(a);
  const other = addressKey(b);
  if (!mine || !other || mine === other) return false;
  return !mine.includes(other) && !other.includes(mine);
}

function isDuplicatePair(a, b, windowMs = DUPLICATE_WINDOW_MS) {
  if (!a || !b || a.id === b.id) return false;
  if (!isOpenJob(a) || !isOpenJob(b)) return false;
  if (!sharePhone(a, b)) return false;
  if (!withinWindow(a, b, windowMs)) return false;
  return !differentAddress(a, b);
}

function applianceKey(value) {
  const text = String(value || '')
    .trim()
    .toLowerCase()
    .replace(/ё/g, 'е');
  if (!text || text === 'техника' || text === 'other' || text === 'appliance') return '';
  if (/(dish|посуд)/.test(text)) return 'dishwasher';
  if (/(washer|стирал)/.test(text)) return 'washer';
  if (/(dryer|сушилн)/.test(text)) return 'dryer';
  if (/(fridge|refriger|холодиль)/.test(text)) return 'fridge';
  if (/(freezer|морозил)/.test(text)) return 'freezer';
  if (/(microwave|микроволн)/.test(text)) return 'microwave';
  if (/(cooktop|варочн)/.test(text)) return 'cooktop';
  if (/(stove|range|плит)/.test(text)) return 'stove';
  if (/(oven|духов)/.test(text)) return 'oven';
  return text.slice(0, 24);
}

function jobApplianceKey(job) {
  const fromList = Array.isArray(job && job.appliances)
    ? (job.appliances[0] && job.appliances[0].type) || ''
    : '';
  return applianceKey((job && job.applianceType) || fromList);
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
  if (hasVisit(job)) score += 1;
  return score;
}

/**
 * Главная — та, где визит, иначе та, где больше данных, иначе старшая.
 * Порядок обязан быть одинаковым с любой стороны: две копии триггера выбирают
 * одну и ту же главную и не закрывают друг друга.
 */
function pickKeeper(a, b) {
  const rank = (job) => [
    hasVisit(job) ? 1 : 0,
    jobFillScore(job),
    -(createdMs(job) || Number.MAX_SAFE_INTEGER),
  ];
  const left = rank(a);
  const right = rank(b);
  for (let i = 0; i < left.length; i += 1) {
    if (left[i] !== right[i]) {
      return left[i] > right[i] ? { keep: a, drop: b } : { keep: b, drop: a };
    }
  }
  return String(a.id) <= String(b.id) ? { keep: a, drop: b } : { keep: b, drop: a };
}

function mergeDescription(keepText, dropText) {
  const base = String(keepText || '').trim();
  const extra = String(dropText || '').trim();
  if (!extra) return base;
  if (!base) return extra;
  if (base.toLowerCase().includes(extra.toLowerCase())) return base;
  return `${base}\n\n${extra}`;
}

function fillText(keepValue, dropValue) {
  const mine = String(keepValue || '').trim();
  if (mine) return null;
  const other = String(dropValue || '').trim();
  return other || null;
}

function mergeAppliances(keep, drop) {
  const mine = Array.isArray(keep.appliances) ? [...keep.appliances] : [];
  const theirs = Array.isArray(drop.appliances) ? drop.appliances : [];
  const seen = new Set(mine.map((item) => applianceKey(item && item.type)));
  const extra = theirs.filter((item) => {
    const key = applianceKey(item && item.type);
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  if (!mine.length && !extra.length) return null;
  if (!extra.length) return null;
  return [...mine, ...extra];
}

function mergeAttachments(keep, drop) {
  const mine = Array.isArray(keep.attachments) ? [...keep.attachments] : [];
  const seen = new Set(mine.map((item) => String((item && item.url) || '')));
  const extra = (Array.isArray(drop.attachments) ? drop.attachments : []).filter((item) => {
    const url = String((item && item.url) || '');
    if (!url || seen.has(url)) return false;
    seen.add(url);
    return true;
  });
  return extra.length ? [...mine, ...extra] : null;
}

function visitKey(visit) {
  const date = toDate(visit && visit.startAt);
  return date ? date.toISOString() : '';
}

function mergeVisits(keep, drop) {
  const theirs = liveVisits(drop);
  if (!theirs.length) return null;
  const mine = Array.isArray(keep.visits) ? [...keep.visits] : [];
  const seen = new Set(mine.map((visit) => visitKey(visit)).filter(Boolean));
  const ids = new Set(mine.map((visit) => String((visit && visit.id) || '')));
  const extra = theirs.filter((visit) => {
    const key = visitKey(visit);
    if (!key || seen.has(key) || ids.has(String(visit.id || ''))) return false;
    seen.add(key);
    return true;
  });
  return extra.length ? [...mine, ...extra] : null;
}

/** Что дописать в главную заявку. Заполняем только пустые поля. */
function buildMergeUpdates(keep, drop) {
  const updates = {};
  const put = (field, value) => {
    if (value != null) updates[field] = value;
  };

  put('clientId', fillText(keep.clientId, drop.clientId));
  const keepName = String(keep.clientName || '').trim();
  const dropName = voiceFacts.usableClientName(drop.clientName || '');
  if (dropName && (!keepName || voiceFacts.isPlaceholderClientName(keepName))) {
    updates.clientName = dropName;
  }
  put('clientPhone', fillText(keep.clientPhone, drop.clientPhone));
  put('clientAddress', fillText(keep.clientAddress, drop.clientAddress));
  put('city', fillText(keep.city, drop.city));
  put('applianceType', fillText(
    String(keep.applianceType || '').trim() === 'Техника' ? '' : keep.applianceType,
    drop.applianceType
  ));
  put('brand', fillText(keep.brand, drop.brand));
  put('model', fillText(keep.model, drop.model));
  put('serialNumber', fillText(keep.serialNumber, drop.serialNumber));
  put('sourceCallId', fillText(keep.sourceCallId, drop.sourceCallId));
  put('sourceEmailId', fillText(keep.sourceEmailId, drop.sourceEmailId));
  put('sourceEmailFrom', fillText(keep.sourceEmailFrom, drop.sourceEmailFrom));
  put('source', fillText(keep.source, drop.source));

  if (drop.hasJobSite === true && keep.hasJobSite !== true) updates.hasJobSite = true;
  put('jobSiteName', fillText(keep.jobSiteName, drop.jobSiteName));
  put('jobSitePhone', fillText(keep.jobSitePhone, drop.jobSitePhone));
  put('jobSiteAddress', fillText(keep.jobSiteAddress, drop.jobSiteAddress));
  put('jobSiteEmail', fillText(keep.jobSiteEmail, drop.jobSiteEmail));

  const description = mergeDescription(keep.description, drop.description);
  if (description !== String(keep.description || '').trim()) {
    updates.description = description;
  }
  put('appliances', mergeAppliances(keep, drop));
  put('attachments', mergeAttachments(keep, drop));
  const visits = mergeVisits(keep, drop);
  if (visits) {
    updates.visits = visits;
    if (!hasVisit(keep)) {
      const first = toDate(visits[0] && visits[0].startAt);
      if (first) {
        updates.scheduledAt = admin.firestore.Timestamp.fromDate(first);
        updates.scheduledDate = admin.firestore.Timestamp.fromDate(first);
      }
    }
  }

  // Слитую заявку мастер должен увидеть в колокольчике ещё раз.
  if (drop.needsReview === true || keep.needsReview === true) updates.needsReview = true;

  const from = Array.isArray(keep.mergedFromJobIds) ? [...keep.mergedFromJobIds] : [];
  if (!from.includes(drop.id)) from.push(drop.id);
  updates.mergedFromJobIds = from;
  if (String(keep.possibleDuplicateOfJobId || '') === String(drop.id)) {
    updates.possibleDuplicateOfJobId = '';
  }
  return updates;
}

/** Дубль закрываем и гасим его визиты, чтобы календарь не держал два окна. */
function buildDropUpdates(drop, keepId) {
  const visits = Array.isArray(drop.visits)
    ? drop.visits.map((visit) => {
        if (!visit || visit.outcome === 'done' || visit.outcome === 'cancelled') return visit;
        return { ...visit, outcome: 'cancelled', smsConfirmStatus: 'cancelled' };
      })
    : [];
  return {
    status: 'Отменено',
    needsReview: false,
    mergedIntoJobId: keepId,
    cloneOfJobId: keepId,
    possibleDuplicateOfJobId: '',
    visits,
  };
}

async function addHistory(jobId, docId, entry) {
  await jobsRef()
    .doc(jobId)
    .collection('changes')
    .doc(docId)
    .set({ at: admin.firestore.Timestamp.now(), ...entry }, { merge: true });
}

/** Звонки и сообщения дубля должны показывать главную заявку. */
async function relinkJobLinks(dropId, keepId) {
  const [created, linked, messages] = await Promise.all([
    callsRef().where('createdJobId', '==', dropId).get(),
    callsRef().where('jobId', '==', dropId).get(),
    messagesRef().where('jobId', '==', dropId).get(),
  ]);
  const calls = new Map();
  for (const doc of [...created.docs, ...linked.docs]) calls.set(doc.id, doc);
  for (const doc of calls.values()) {
    await doc.ref.set({ createdJobId: keepId, jobId: keepId }, { merge: true });
  }
  for (const doc of messages.docs) {
    await doc.ref.set({ jobId: keepId }, { merge: true });
  }
}

/**
 * Соединяет dropId в keepId. force — ручное соединение из карточки: можно
 * слить и заявку с визитом, визит переезжает в главную.
 */
async function mergeJobs(keepId, dropId, { by = 'owner', force = false } = {}) {
  const keep = String(keepId || '').trim();
  const drop = String(dropId || '').trim();
  if (!keep || !drop || keep === drop) return false;
  const [keepSnap, dropSnap] = await Promise.all([
    jobsRef().doc(keep).get(),
    jobsRef().doc(drop).get(),
  ]);
  if (!keepSnap.exists || !dropSnap.exists) return false;
  const keepJob = { id: keep, ...(keepSnap.data() || {}) };
  const dropJob = { id: drop, ...(dropSnap.data() || {}) };
  if (isMerged(dropJob) || dropJob.deletedAt) return false;
  if (!isOpenJob(keepJob)) return false;
  if (!force && !isOpenJob(dropJob)) return false;

  const now = admin.firestore.FieldValue.serverTimestamp();
  await jobsRef()
    .doc(keep)
    .set({ ...buildMergeUpdates(keepJob, dropJob), updatedAt: now }, { merge: true });
  await jobsRef()
    .doc(drop)
    .set({ ...buildDropUpdates(dropJob, keep), updatedAt: now }, { merge: true });
  await relinkJobLinks(drop, keep);
  await addHistory(keep, `merged_${drop}`, {
    by,
    event: 'merged_duplicate',
    jobId: drop,
    detail: String(dropJob.applianceType || '').trim(),
  });
  await addHistory(drop, `merged_into_${keep}`, {
    by,
    event: 'merged_into',
    jobId: keep,
  });
  console.log(`mergeJobs: ${drop} → ${keep}`);
  return true;
}

async function flagPossibleDuplicate(newer, older) {
  if (!newer || !older || newer.id === older.id) return false;
  if (newer.duplicateDismissed === true) return false;
  if (String(newer.possibleDuplicateOfJobId || '') === String(older.id)) return false;
  await jobsRef().doc(newer.id).set(
    {
      possibleDuplicateOfJobId: older.id,
      possibleDuplicateAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  console.log(`possible duplicate: ${newer.id} ~ ${older.id}`);
  return true;
}

async function findDuplicateCandidates(job) {
  if (!jobPhones(job).length) return [];
  const snapshot = await jobsRef().get();
  const out = [];
  for (const doc of snapshot.docs) {
    if (doc.id === job.id) continue;
    const other = { id: doc.id, ...(doc.data() || {}) };
    if (isDuplicatePair(job, other)) out.push(other);
  }
  return out;
}

/** Номер появился или сменился — заявку стоит проверить на дубляж заново. */
function phoneChanged(before, after) {
  if (!before) return true;
  const was = jobPhones(before).sort().join(',');
  const now = jobPhones(after).sort().join(',');
  return was !== now;
}

/**
 * Точка входа из триггера заявок. Возвращает, что соединили и что пометили;
 * mergedInto — эту заявку закрыли как дубль, дальше её трогать не надо.
 */
async function checkJobForDuplicates(jobId, data) {
  const job = { id: jobId, ...(data || {}) };
  const result = { merged: [], flagged: [], mergedInto: '' };
  if (!isOpenJob(job)) return result;
  const candidates = await findDuplicateCandidates(job);
  for (const other of candidates) {
    const { keep, drop } = pickKeeper(job, other);
    if (isIncomingDraft(drop)) {
      if (await mergeJobs(keep.id, drop.id, { by: historyActor(drop) })) {
        result.merged.push(drop.id);
      }
      if (drop.id === job.id) {
        result.mergedInto = keep.id;
        break;
      }
      continue;
    }
    const newer = createdMs(job) >= createdMs(other) ? job : other;
    const older = newer.id === job.id ? other : job;
    if (await flagPossibleDuplicate(newer, older)) result.flagged.push(newer.id);
  }
  return result;
}

module.exports = {
  DUPLICATE_WINDOW_MS,
  addressKey,
  applianceKey,
  buildDropUpdates,
  buildMergeUpdates,
  checkJobForDuplicates,
  differentAddress,
  findDuplicateCandidates,
  hasVisit,
  historyActor,
  isDuplicatePair,
  isIncomingDraft,
  isOpenJob,
  jobApplianceKey,
  jobFillScore,
  jobPhones,
  jobSource,
  mergeDescription,
  mergeJobs,
  normalizePhone,
  phoneChanged,
  pickKeeper,
};
