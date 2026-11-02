/**
 * Care Plan на сервере: найти план звонящего / пишущего по номеру или
 * карточке клиента. Нужен пушам («Care Plan · Пропущенный звонок»), брифу
 * телефонного секретаря и напоминаниям о ТО.
 *
 * Планы лежат в `companies/{id}/care_plans`; `phones` — последние 10 цифр
 * всех номеров клиента (их ведёт приложение). Ответ кэшируется на 5 минут:
 * пуш по звонку не должен ждать лишний запрос к базе.
 */
const admin = require('firebase-admin');

const COMPANY_ID = 'fix_appliance_ca';
const MEMBER_STATUSES = new Set(['active', 'past_due']);
const CACHE_MS = 5 * 60 * 1000;
const cache = new Map();

function plansRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('care_plans');
}

function last10(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  return digits.length >= 10 ? digits.slice(-10) : '';
}

function isMember(plan) {
  return Boolean(plan) && MEMBER_STATUSES.has(String(plan.status || ''));
}

function clearCache() {
  cache.clear();
}

/** План-член (active / past_due) по номеру или карточке; null — не на плане. */
async function findMemberPlan({ phone, clientId } = {}, now = Date.now()) {
  const key = last10(phone);
  const id = String(clientId || '').trim();
  if (!key && !id) return null;
  const cacheKey = `${id}|${key}`;
  const hit = cache.get(cacheKey);
  if (hit && now - hit.at < CACHE_MS) return hit.plan;
  let plan = null;
  try {
    const queries = [];
    if (id) queries.push(plansRef().where('clientId', '==', id).get());
    if (key) queries.push(plansRef().where('phones', 'array-contains', key).get());
    const snaps = await Promise.all(queries);
    for (const snap of snaps) {
      for (const doc of snap.docs || []) {
        const data = { ...(doc.data() || {}), id: doc.id };
        if (isMember(data)) {
          plan = data;
          break;
        }
      }
      if (plan) break;
    }
  } catch (error) {
    console.warn('care plan lookup:', error.message);
    return null;
  }
  cache.set(cacheKey, { plan, at: now });
  if (cache.size > 500) cache.delete(cache.keys().next().value);
  return plan;
}

/**
 * Строка для Live-промпта секретаря. Слово «warranty» клиенту не говорим —
 * это «Care Plan member». Цены, кроме условий плана, не называем, время не
 * обещаем: визиты секретарь не назначает (решение FIX 28.09.2026).
 */
function secretaryBriefLine(plan) {
  if (!isMember(plan)) return '';
  const discount = Math.round(Number(plan.discountPercent) || 100);
  const repair = discount >= 100
    ? 'Diagnosis and repair labour are included; the member pays for parts only.'
    : `Their plan includes a free diagnostic visit and ${discount}% off repair labour.`;
  return `CARE PLAN: this caller is a FIX Care Plan member (monthly maintenance subscription), so this is a plan service call. ` +
    `${repair} The included repair applies only to appliances carrying the shop's sticker, plus priority service and yearly maintenance. ` +
    'Thank them briefly for being a member, collect the details as usual and say the technician will give their request priority. ' +
    'Do not promise a time and do not quote prices beyond these plan terms.';
}

module.exports = { findMemberPlan, secretaryBriefLine, isMember, last10, clearCache, MEMBER_STATUSES };
