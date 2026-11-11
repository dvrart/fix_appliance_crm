/**
 * Безнал за месяц больше $800 → одно уведомление мастеру (просьба FIX 24.10.2026).
 *
 * Считается всё, что пришло НЕ наличными: ссылка Stripe, Tap to Pay, карта,
 * e-Transfer, чек и т. п. Наличные не считаются. Чаевые безналом тоже деньги
 * на карту/счёт — считаются; возвраты вычитаются. Месяц календарный, по Торонто.
 *
 * Способ оплаты определяется так же, как в отчётах приложения
 * (`ReportMetrics.explicitPayMethod`): строка «Tip» / «Refund» без способа берёт
 * способ соседнего платежа того же счёта, поэтому чаевые к наличной оплате
 * тоже остаются наличными.
 *
 * Тяжёлый подсчёт по всем заявкам месяца идёт только когда в записанной заявке
 * безнал за текущий месяц вырос. Уведомление одно на месяц: метка
 * `settings/noncash_alert.notifiedMonth` ставится транзакцией.
 */
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { notifyMaster } = require('./notify');

const COMPANY_ID = 'fix_appliance_ca';
const OWNER_UID = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';
const NONCASH_MONTH_LIMIT = 800;
const TORONTO = 'America/Toronto';
const STRIPE_ID_FIELDS = ['stripePaymentIntentId', 'stripeSessionId', 'stripeInvoiceId', 'stripeRefundId'];
const NONCASH_HINT = /transfer|interac|перевод|stripe|card|credit|карт|кредит|tap to pay|terminal/;

function companyRef() {
  return getFirestore().collection('companies').doc(COMPANY_ID);
}

/** 'cash' | 'noncash' | null (способ в строке не указан). */
function explicitMethod(payment) {
  const method = String(payment.method || '').toLowerCase();
  if (method.includes('cash') || method.includes('налич')) return 'cash';
  if (NONCASH_HINT.test(method)) return 'noncash';
  if (STRIPE_ID_FIELDS.some((key) => String(payment[key] || '').trim())) return 'noncash';
  return null;
}

function isInvoiceDoc(doc) {
  if (!doc || typeof doc !== 'object' || doc.deletedAt) return false;
  if (String(doc.type || 'Invoice') === 'Estimate') return false;
  const status = String(doc.status || '').toLowerCase();
  return !(status.includes('cancel') || status.includes('void') || status.includes('отмен'));
}

function monthKeyOf(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return '';
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: TORONTO, year: 'numeric', month: '2-digit' })
    .formatToParts(date);
  const year = parts.find((p) => p.type === 'year')?.value;
  const month = parts.find((p) => p.type === 'month')?.value;
  return year && month ? `${year}-${month}` : '';
}

/**
 * Месяц платежа по Торонто. Приложение пишет местное время без зоны
 * («2026-10-24T21:36:13.392») — это уже часы Торонто, месяц берём как есть;
 * сервер пишет UTC с «Z».
 */
function paymentMonthKey(raw) {
  if (raw === null || raw === undefined || raw === '') return '';
  if (typeof raw === 'string') {
    const text = raw.trim();
    if (/^\d{4}-\d{2}/.test(text) && !/(z|[+-]\d{2}:?\d{2})$/i.test(text)) return text.slice(0, 7);
    return monthKeyOf(new Date(text));
  }
  if (raw instanceof Date) return monthKeyOf(raw);
  if (typeof raw.toDate === 'function') return monthKeyOf(raw.toDate());
  if (typeof raw === 'number') return monthKeyOf(new Date(raw > 1e12 ? raw : raw * 1000));
  return '';
}

function isTechnicianJob(job) {
  const assigned = String((job && job.assignedTo) || '').trim();
  return Boolean(assigned) && assigned !== OWNER_UID;
}

/** Сколько пришло безналом за месяц `monthKey` ('2026-10') по списку заявок. */
function nonCashTotalForMonth(jobs, monthKey) {
  let total = 0;
  for (const job of jobs) {
    if (!job || job.deletedAt || isTechnicianJob(job) || !Array.isArray(job.documents)) continue;
    for (const doc of job.documents) {
      if (!isInvoiceDoc(doc) || !Array.isArray(doc.payments)) continue;
      const rows = doc.payments.filter((p) => p && typeof p === 'object');
      let last = rows.map(explicitMethod).find(Boolean) || 'noncash';
      for (const payment of rows) {
        const amount = Number(payment.amount) || 0;
        if (Math.abs(amount) <= 0.009) continue;
        const explicit = explicitMethod(payment);
        if (explicit) last = explicit;
        if ((explicit || last) === 'cash') continue;
        const when = payment.date || payment.createdAt || doc.createdAt || doc.issuedAt || doc.date;
        if (paymentMonthKey(when) !== monthKey) continue;
        total += amount;
      }
    }
  }
  return Math.round(total * 100) / 100;
}

function monthStartUtc(monthKey) {
  const [year, month] = monthKey.split('-').map(Number);
  return new Date(Date.UTC(year, month - 1, 1));
}

function monthWords(monthKey) {
  const start = monthStartUtc(monthKey);
  return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long', timeZone: 'UTC' }).format(start);
}

async function handleJobWrite(before, after, jobId, now = new Date()) {
  if (!after) return { checked: false };
  const monthKey = monthKeyOf(now);
  const grew = nonCashTotalForMonth([after], monthKey) - nonCashTotalForMonth([before], monthKey) > 0.009;
  if (!grew) return { checked: false };

  const alertRef = companyRef().collection('settings').doc('noncash_alert');
  const seen = await alertRef.get();
  if (seen.exists && (seen.data() || {}).notifiedMonth === monthKey) return { checked: false };

  // Платёж месяца пишет updatedAt не раньше 1-го числа: и приложение, и сервер
  // ставят его на каждой записи заявки. Записанную заявку подставляем сами.
  const snapshot = await companyRef().collection('jobs').where('updatedAt', '>=', monthStartUtc(monthKey)).get();
  const jobs = new Map(snapshot.docs.map((doc) => [doc.id, doc.data()]));
  jobs.set(jobId, after);
  const total = nonCashTotalForMonth([...jobs.values()], monthKey);
  if (total <= NONCASH_MONTH_LIMIT) return { checked: true, total, notified: false };

  const claimed = await getFirestore().runTransaction(async (tx) => {
    const current = await tx.get(alertRef);
    if (current.exists && (current.data() || {}).notifiedMonth === monthKey) return false;
    tx.set(alertRef, {
      notifiedMonth: monthKey,
      total,
      limit: NONCASH_MONTH_LIMIT,
      jobId,
      notifiedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return true;
  });
  if (!claimed) return { checked: true, total, notified: false };

  await notifyMaster(
    `Безнал за месяц больше $${NONCASH_MONTH_LIMIT}`,
    `С ${monthWords(monthKey)} пришло $${total.toFixed(2)} картой, через Stripe и переводами. Наличные не считаются.`,
    { type: 'noncash_month', eventId: `noncash:${monthKey}`, tag: `crm_noncash_${monthKey}` }
  );
  return { checked: true, total, notified: true };
}

// Без region — как onJobWritten: функция живёт в регионе базы Firestore.
exports.onJobNonCashMonth = onDocumentWritten(
  {
    document: `companies/${COMPANY_ID}/jobs/{jobId}`,
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  async (event) => {
    const before = event.data && event.data.before && event.data.before.exists
      ? event.data.before.data()
      : null;
    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data()
      : null;
    try {
      await handleJobWrite(before, after, event.params.jobId);
    } catch (error) {
      console.error('onJobNonCashMonth error:', error);
    }
  }
);

exports._internals = {
  NONCASH_MONTH_LIMIT,
  explicitMethod,
  paymentMonthKey,
  nonCashTotalForMonth,
  handleJobWrite,
};
