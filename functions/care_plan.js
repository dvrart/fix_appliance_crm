/**
 * Care Plan: ежедневное напоминание мастеру (9:00 по Торонто) — заранее,
 * пока есть время записать клиента.
 *
 *  - «Care Plan: скоро ТО» — до планового ТО осталось carePlanRemindDays дней
 *    (по умолчанию 14);
 *  - «Care Plan: пора ТО» — срок наступил или прошёл;
 *  - «Care Plan не оплачен» — договор подписан 3+ дня назад, подписки нет.
 *
 * Каждое — один раз: ключ последнего напоминания пишется в план
 * (`lastReminderKey`). Платёж, который не прошёл, приходит сразу из вебхука
 * Stripe, а не здесь.
 */
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { notifyMaster } = require('./notify');
const { isMember } = require('./care_plan_lookup');

const COMPANY_ID = 'fix_appliance_ca';
const TORONTO = 'America/Toronto';

function companyRef() {
  return getFirestore().collection('companies').doc(COMPANY_ID);
}

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value.toDate === 'function') return value.toDate();
  if (typeof value === 'number') return new Date(value > 1e12 ? value : value * 1000);
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/** Календарный день по Торонто: 'YYYY-MM-DD'. */
function ymd(date) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: TORONTO, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(date);
}

function daysBetween(fromYmd, toYmd) {
  return Math.round((Date.parse(`${toYmd}T00:00:00Z`) - Date.parse(`${fromYmd}T00:00:00Z`)) / 86400000);
}

function addMonths(date, months) {
  const result = new Date(date.getTime());
  const day = result.getUTCDate();
  result.setUTCDate(1);
  result.setUTCMonth(result.getUTCMonth() + months);
  const last = new Date(Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)).getUTCDate();
  result.setUTCDate(Math.min(day, last));
  return result;
}

/** Как `CarePlan.maintenanceDue` в приложении. */
function nextMaintenanceDue(plan) {
  const stored = toDate(plan.nextMaintenanceDue);
  if (stored) return stored;
  const last = toDate(plan.lastMaintenanceAt);
  if (last) return addMonths(last, Number(plan.maintenanceMonths) || 12);
  const signed = toDate(plan.signedAt) || toDate(plan.createdAt);
  if (!signed) return null;
  return new Date(signed.getTime() + (Number(plan.firstMaintenanceDays) || 30) * 86400000);
}

function ruDay(date) {
  return new Intl.DateTimeFormat('ru-RU', { timeZone: TORONTO, day: '2-digit', month: '2-digit' }).format(date);
}

/** Что напомнить по плану сегодня; null — ничего. */
function reminderFor(plan, now = new Date(), remindDays = 14, applianceCount = 0) {
  const name = String(plan.clientName || '').trim() || 'Клиент';
  const today = ymd(now);
  if (String(plan.status || '') === 'pending') {
    const signed = toDate(plan.signedAt) || toDate(plan.createdAt);
    if (!signed || daysBetween(ymd(signed), today) < 3) return null;
    return {
      key: `pending:${ymd(signed)}`,
      title: 'Care Plan не оплачен',
      body: `${name}: договор подписан ${ruDay(signed)}, а подписка в Stripe не оформлена. Отправьте ссылку на оплату.`,
    };
  }
  if (!isMember(plan)) return null;
  const due = nextMaintenanceDue(plan);
  if (!due) return null;
  const dueYmd = ymd(due);
  const days = daysBetween(today, dueYmd);
  const items = applianceCount > 0 ? ` · ${applianceCount} ед. техники` : '';
  if (days <= 0) {
    return {
      key: `${dueYmd}:due`,
      title: 'Care Plan: пора ТО',
      body: `${name} — плановое ТО до ${ruDay(due)}${items}. Позвоните и запишите.`,
    };
  }
  if (days <= remindDays) {
    return {
      key: `${dueYmd}:soon`,
      title: 'Care Plan: скоро ТО',
      body: `${name} — ТО через ${days} дн. (${ruDay(due)})${items}.`,
    };
  }
  return null;
}

async function runReminders(now = new Date()) {
  const company = companyRef();
  const [configSnap, plansSnap, appliancesSnap] = await Promise.all([
    company.collection('settings').doc('config').get(),
    company.collection('care_plans').get(),
    company.collection('appliances').get(),
  ]);
  const config = configSnap.exists ? configSnap.data() || {} : {};
  const remindDays = Math.min(90, Math.max(1, Math.round(Number(config.carePlanRemindDays) || 14)));
  const counts = new Map();
  for (const doc of appliancesSnap.docs) {
    const item = doc.data() || {};
    if (!item.planId || item.status === 'retired') continue;
    counts.set(item.planId, (counts.get(item.planId) || 0) + 1);
  }
  let sent = 0;
  for (const doc of plansSnap.docs) {
    const plan = doc.data() || {};
    const reminder = reminderFor(plan, now, remindDays, counts.get(doc.id) || 0);
    if (!reminder || plan.lastReminderKey === reminder.key) continue;
    await notifyMaster(reminder.title, reminder.body, {
      type: 'care_plan',
      clientId: plan.clientId || '',
      planId: doc.id,
      eventId: `care_plan:${doc.id}:${reminder.key}`,
      tag: `crm_care_plan_${doc.id}`,
    });
    await doc.ref.set({
      lastReminderKey: reminder.key,
      lastReminderAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    sent++;
  }
  return sent;
}

const carePlanReminders = onSchedule(
  {
    schedule: 'every day 09:00',
    timeZone: TORONTO,
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '256MiB',
    retryCount: 0,
  },
  async () => {
    try {
      const sent = await runReminders();
      console.log(`carePlanReminders: sent ${sent}`);
    } catch (error) {
      console.error('carePlanReminders error:', error);
    }
  }
);

module.exports = {
  carePlanReminders,
  _internals: { reminderFor, runReminders, nextMaintenanceDue, daysBetween, ymd },
};
