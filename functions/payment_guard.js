/**
 * Платежи Stripe против перезаписи из приложения.
 *
 * Карточка заявки сохраняет `documents` целиком. Если вебхук Stripe записал
 * оплату, пока телефон был без сети, то очередь приложения при выходе в сеть
 * кладёт свой старый массив поверх — и оплата исчезает из счёта. Здесь
 * сравниваем документы до и после записи и возвращаем платежи Stripe
 * (у них есть id сессии, PaymentIntent, инвойса или возврата), которых в
 * новой версии не стало.
 */

function stripeKey(payment) {
  if (!payment || typeof payment !== 'object') return '';
  const id =
    payment.stripeRefundId ||
    payment.stripePaymentIntentId ||
    payment.stripeSessionId ||
    payment.stripeInvoiceId ||
    '';
  if (!id) return '';
  const amount = Number(payment.amount) || 0;
  return `${id}|${amount.toFixed(2)}|${String(payment.method || '')}`;
}

function paymentsOf(doc) {
  return doc && Array.isArray(doc.payments) ? doc.payments : [];
}

function sameDocument(a, b) {
  if (!a || !b) return false;
  if (a.id && b.id) return String(a.id) === String(b.id);
  if (a.number && b.number) return String(a.number) === String(b.number);
  return String(a.type || 'Invoice') === String(b.type || 'Invoice') &&
    String(a.createdAt || '') === String(b.createdAt || '');
}

/**
 * Возвращает `{ documents, restored }`: новый массив документов с
 * возвращёнными платежами и список того, что вернули. Если терять было
 * нечего — `restored` пустой, а `documents` — тот же объект `afterDocs`.
 */
function restoreLostStripePayments(beforeDocs, afterDocs) {
  const before = Array.isArray(beforeDocs) ? beforeDocs : [];
  const after = Array.isArray(afterDocs) ? afterDocs : [];
  const restored = [];
  if (!before.length || !after.length) return { documents: after, restored };

  const present = new Set();
  for (const doc of after) for (const payment of paymentsOf(doc)) {
    const key = stripeKey(payment);
    if (key) present.add(key);
  }

  let next = after;
  before.forEach((prevDoc, index) => {
    const lost = paymentsOf(prevDoc).filter((payment) => {
      const key = stripeKey(payment);
      return key && !present.has(key);
    });
    if (!lost.length) return;
    let target = index < after.length && sameDocument(prevDoc, after[index]) ? index : -1;
    if (target < 0) target = after.findIndex((doc) => sameDocument(prevDoc, doc));
    if (target < 0 && index < after.length && !prevDoc.id && !after[index].id) target = index;
    if (target < 0) return;
    if (next === after) next = after.map((doc) => ({ ...doc }));
    const doc = next[target];
    doc.payments = [...paymentsOf(doc), ...lost.map((payment) => ({ ...payment }))];
    const prevStripe = prevDoc.stripe && typeof prevDoc.stripe === 'object' ? prevDoc.stripe : null;
    if (prevStripe && !(doc.stripe && typeof doc.stripe === 'object' && doc.stripe.status)) {
      doc.stripe = { ...prevStripe };
    }
    for (const payment of lost) restored.push({ documentIndex: target, ...payment });
  });
  return { documents: next, restored };
}

module.exports = { restoreLostStripePayments, stripeKey };
