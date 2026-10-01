// Сквозная цепочка оплаты на заглушках: ссылка → Checkout → вебхук/проверка →
// запись в счёт → карточка. Реальный Stripe не трогаем.
const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const JOB = `${COMPANY}/jobs/pay-job`;
let store;
let notifications;
let sentSms;
let transactionTail;
let stripeState;
let stripeCalls;

function snapshot(path) {
  const stored = structuredClone(store.get(path));
  return { exists: stored !== undefined, id: path.split('/').pop(), ref: ref(path), data: () => structuredClone(stored) };
}
function apply(path, data, merge = true) {
  store.set(path, { ...(merge ? store.get(path) : {}), ...structuredClone(data) });
}
function ref(path) {
  return {
    path, id: path.split('/').pop(),
    collection: (name) => ref(`${path}/${name}`),
    doc: (name = `generated-${store.size + 1}`) => ref(`${path}/${name}`),
    where() { return this; }, limit() { return this; },
    get: async () => {
      if (path.split('/').length % 2 === 0) return snapshot(path);
      const docs = [...store.keys()].filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/')).map(snapshot);
      return { docs, empty: !docs.length, size: docs.length };
    },
    set: async (data, options) => apply(path, data, options?.merge === true),
    update: async (data) => apply(path, data),
    add: async (data) => { const doc = ref(`${path}/generated-${store.size + 1}`); apply(doc.path, data, false); return doc; },
  };
}
const db = {
  collection: (name) => ref(name),
  runTransaction: (work) => {
    const result = transactionTail.then(async () => {
      const writes = [];
      const value = await work({
        get: (document) => document.get(),
        set: (document, data, options) => writes.push(() => apply(document.path, data, options?.merge === true)),
        update: (document, data) => writes.push(() => apply(document.path, data)),
      });
      writes.forEach((write) => write());
      return value;
    });
    transactionTail = result.catch(() => {});
    return result;
  },
};
const firestore = Object.assign(() => db, {
  FieldValue: { serverTimestamp: () => new Date(), increment: (value) => value },
  Timestamp: { now: () => new Date(), fromDate: (date) => date },
});

function fakeStripe() {
  const track = (name, payload) => { stripeCalls.push([name, payload]); };
  return {
    customers: {
      retrieve: async (id) => ({ id }),
      create: async (payload) => { track('customers.create', payload); return { id: 'cus_1', email: payload.email }; },
    },
    prices: { list: async () => ({ data: [{ id: 'price_tip' }] }) },
    checkout: { sessions: {
      create: async (payload) => {
        track('sessions.create', payload);
        const id = `cs_${stripeCalls.length}`;
        stripeState.sessions[id] = {
          id, url: `https://checkout.test/${id}`, metadata: payload.metadata, client_reference_id: payload.client_reference_id,
          payment_intent: `pi_${id}`, invoice: `in_${id}`, payment_status: 'unpaid', status: 'open',
          amount_total: payload.line_items.reduce((sum, item) => sum + item.price_data.unit_amount * item.quantity, 0),
        };
        return stripeState.sessions[id];
      },
      retrieve: async (id) => stripeState.sessions[id],
      expire: async (id) => { track('sessions.expire', id); stripeState.sessions[id].status = 'expired'; },
    } },
    invoices: {
      create: async (payload) => { track('invoices.create', payload); stripeState.invoices.in_manual = { id: 'in_manual', metadata: payload.metadata, status: 'open', amount_paid: 0 }; return stripeState.invoices.in_manual; },
      finalizeInvoice: async (id) => ({ id, hosted_invoice_url: `https://invoice.test/${id}` }),
      sendInvoice: async () => ({}),
      retrieve: async (id) => stripeState.invoices[id],
    },
    invoiceItems: { create: async (payload) => { track('invoiceItems.create', payload); return {}; } },
    paymentIntents: {
      create: async (payload) => { track('paymentIntents.create', payload); const pi = { id: 'pi_tap', client_secret: 'secret', status: 'requires_payment_method', ...payload, amount_received: 0 }; stripeState.intents.pi_tap = pi; return pi; },
      retrieve: async (id) => stripeState.intents[id],
    },
    refunds: { create: async (payload) => { track('refunds.create', payload); return { id: `re_${stripeCalls.length}`, ...payload }; } },
    webhooks: { constructEvent: (raw, signature) => { if (signature !== 'valid') throw new Error('bad signature'); return JSON.parse(raw); } },
  };
}

const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin') return { firestore };
  if (name === 'firebase-functions') return { https: { onRequest: (...args) => args.at(-1) } };
  if (name === './auth_guard') return { requireAppUser: async () => ({ uid: 'owner' }) };
  if (name === './notify') return { notifyMaster: async (...args) => notifications.push(args) };
  if (name === './short_links') return { shortenPayUrl: async (url) => ({ shortUrl: `https://pay.test/c/${url.split('/').pop()}` }) };
  if (name === 'stripe') return () => fakeStripe();
  if (name === 'twilio') return () => ({ messages: { create: async (payload) => { sentSms.push(payload); return { sid: 'SM1', status: 'queued' }; } } });
  return load.apply(this, arguments);
};
// Stripe и Twilio модуль подключает лениво, при первом вызове, поэтому их
// заглушки и ключи остаются на весь процесс теста (у node --test он свой на файл).
Object.assign(process.env, {
  STRIPE_SECRET_KEY: 'sk_test_synthetic', STRIPE_WEBHOOK_SECRET: 'whsec_synthetic',
  TWILIO_ACCOUNT_SID: `AC${'0'.repeat(32)}`, TWILIO_AUTH_TOKEN: 'synthetic', TWILIO_PHONE_NUMBER: '+14165550100',
});
const hooked = Module._load;
let api;
try { api = require('./stripe'); } finally {
  Module._load = function (name) {
    if (name === 'stripe' || name === 'twilio') return hooked.apply(this, arguments);
    return load.apply(this, arguments);
  };
}

function response() {
  return {
    statusCode: 200, body: null,
    status(code) { this.statusCode = code; return this; }, set() { return this; },
    send(body) { this.body = body; return this; }, json(body) { return this.send(body); },
  };
}
function request(body, extra = {}) {
  return { method: 'POST', body, headers: {}, query: {}, get: () => 'functions.test', ...extra };
}
function webhook(type, object) {
  return request({}, { rawBody: JSON.stringify({ type, data: { object } }), headers: { 'stripe-signature': 'valid' } });
}
const invoice = (patch = {}) => ({
  type: 'Invoice', number: 'INV-1', items: [{ name: 'Repair', qty: 1, price: 200 }], taxRate: 0.13, payments: [], ...patch,
});
const doc = (index = 0) => store.get(JOB).documents[index];

beforeEach(() => {
  store = new Map([
    [JOB, { clientId: 'client-1', clientName: 'Audit Client', clientPhone: '+14165550101', status: 'Вызов', documents: [invoice()] }],
    [`${COMPANY}/clients/client-1`, { fullName: 'Audit Client', phone: '+14165550101' }],
  ]);
  notifications = []; sentSms = []; stripeCalls = [];
  transactionTail = Promise.resolve();
  stripeState = { sessions: {}, invoices: {}, intents: {} };
});

test('checkout link → paid session → one payment, tip split, owner notified, duplicate webhooks ignored', async () => {
  const created = response();
  await api.createStripePayment(request({ jobId: 'pay-job', documentIndex: 0, kind: 'checkout' }), created);
  assert.equal(created.statusCode, 200, JSON.stringify(created.body));
  assert.equal(created.body.amount, 226);
  assert.equal(sentSms.length, 1);
  assert.match(sentSms[0].body, /checkout\.test/);
  assert.equal(doc().stripe.status, 'open');
  const sessionId = created.body.checkoutSessionId;

  // Клиент открыл ссылку, но ещё не заплатил: страница «спасибо» не считает оплату.
  await api.stripePaymentComplete(request({}, { query: { status: 'success', session_id: sessionId } }), response());
  assert.equal(doc().payments.length, 0);

  const session = { ...stripeState.sessions[sessionId], payment_status: 'paid', status: 'complete', amount_total: 23600 };
  stripeState.sessions[sessionId] = session;
  const invoiceObject = { id: session.invoice, payment_intent: session.payment_intent, metadata: session.metadata, status: 'paid', amount_paid: 23600 };
  await Promise.all([
    api.stripeWebhook(webhook('checkout.session.completed', session), response()),
    api.stripeWebhook(webhook('invoice.paid', invoiceObject), response()),
    api.stripeWebhook(webhook('checkout.session.completed', session), response()),
  ]);
  const check = response();
  await api.checkStripePayment(request({ jobId: 'pay-job', documentIndex: 0 }), check);

  const payments = doc().payments;
  assert.equal(payments.length, 2);
  assert.equal(payments[0].amount, 226);
  assert.equal(payments[0].method, 'Stripe');
  assert.equal(payments[1].amount, 10);
  assert.equal(payments[1].method, 'Чаевые');
  assert.equal(doc().stripe.status, 'paid');
  assert.equal(store.get(JOB).suggestComplete, true);
  assert.equal(notifications.length, 1);
  assert.match(notifications[0][0], /Счёт оплачен/);
  assert.equal(check.body.paid, true);
  assert.equal(check.body.due, 0);
});

test('invoice.paid arriving before the checkout event keeps the deposit label and the tip split', async () => {
  const created = response();
  await api.createStripePayment(request({ jobId: 'pay-job', documentIndex: 0, kind: 'deposit', amount: 100, tip: 5, sendSms: false }), created);
  const session = { ...stripeState.sessions[created.body.checkoutSessionId], payment_status: 'paid', status: 'complete' };
  await api.stripeWebhook(webhook('invoice.paid', { id: session.invoice, payment_intent: session.payment_intent, metadata: session.metadata, status: 'paid', amount_paid: session.amount_total }), response());
  await api.stripeWebhook(webhook('checkout.session.completed', session), response());
  const payments = doc().payments;
  assert.deepEqual(payments.map((p) => [p.method, p.amount]), [['Stripe (deposit)', 100], ['Чаевые', 5]]);
  assert.equal(store.get(JOB).status, 'Депозит');
});

test('an unsigned webhook and an unpaid checkout session change nothing', async () => {
  const bad = response();
  await api.stripeWebhook(request({}, { rawBody: '{}', headers: { 'stripe-signature': 'forged' } }), bad);
  assert.equal(bad.statusCode, 400);
  await api.stripeWebhook(webhook('checkout.session.completed', { id: 'cs_x', metadata: { jobId: 'pay-job', documentIndex: '0' }, payment_status: 'unpaid', status: 'complete', amount_total: 22600 }), response());
  assert.equal(doc().payments.length, 0);
  assert.equal(notifications.length, 0);
});

test('creating a payment link does not overwrite a payment recorded meanwhile', async () => {
  // Пока функция ждёт Stripe, вебхук уже записал оплату в тот же документ.
  const realGet = store.get.bind(store);
  let injected = false;
  store.get = (path) => {
    const value = realGet(path);
    if (path === JOB && !injected && stripeCalls.some(([name]) => name === 'sessions.create')) {
      injected = true;
      value.documents[0].payments = [{ amount: 50, method: 'Stripe', date: new Date().toISOString(), stripePaymentIntentId: 'pi_early' }];
      store.set(JOB, value);
    }
    return value;
  };
  await api.createStripePayment(request({ jobId: 'pay-job', documentIndex: 0, kind: 'checkout', sendSms: false }), response());
  store.get = realGet;
  assert.equal(injected, true);
  assert.equal(doc().payments.length, 1);
  assert.equal(doc().payments[0].stripePaymentIntentId, 'pi_early');
  assert.equal(doc().stripe.status, 'open');
});

test('tap to pay: only a captured intent is recorded, and the later webhook does not double it', async () => {
  const intent = response();
  await api.createTerminalPaymentIntent(request({ jobId: 'pay-job', documentIndex: 0 }), intent);
  assert.equal(intent.body.amount, 226);
  assert.equal(doc().stripe.status, 'collecting');

  const early = response();
  await api.completeTerminalPayment(request({ paymentIntentId: 'pi_tap' }), early);
  assert.equal(early.statusCode, 400);
  assert.equal(doc().payments.length, 0);

  Object.assign(stripeState.intents.pi_tap, { status: 'succeeded', amount_received: 22600 });
  const done = response();
  await api.completeTerminalPayment(request({ paymentIntentId: 'pi_tap' }), done);
  assert.equal(done.body.recorded, true);
  await api.stripeWebhook(webhook('payment_intent.succeeded', { ...stripeState.intents.pi_tap, payment_method_types: ['card_present'] }), response());
  assert.equal(doc().payments.length, 1);
  assert.equal(doc().payments[0].method, 'Stripe (card present)');
  assert.equal(notifications.length, 1);
});

test('refund goes back through the original intent, is recorded once, and suggests cancelling a finished job', async () => {
  store.set(JOB, { ...store.get(JOB), status: 'Готово', documents: [invoice({ payments: [
    { amount: 226, method: 'Stripe', date: new Date().toISOString(), stripePaymentIntentId: 'pi_paid' },
  ], stripe: { status: 'paid' } })] });
  stripeState.intents.pi_paid = { id: 'pi_paid', amount_received: 22600, amount_refunded: 0 };
  const res = response();
  await api.createStripeRefund(request({ jobId: 'pay-job', documentIndex: 0 }), res);
  assert.equal(res.statusCode, 200, JSON.stringify(res.body));
  assert.equal(res.body.refunded, 226);
  assert.equal(res.body.cashRefunded, 0);
  const refundCall = stripeCalls.find(([name]) => name === 'refunds.create')[1];
  assert.equal(refundCall.payment_intent, 'pi_paid');
  assert.equal(refundCall.amount, 22600);
  const refundId = res.body.stripeRefunds[0].refundId;
  await api.stripeWebhook(webhook('refund.created', { id: refundId, amount: 22600, payment_intent: 'pi_paid', metadata: refundCall.metadata }), response());
  assert.equal(doc().payments.length, 2);
  assert.equal(doc().payments[1].amount, -226);
  assert.equal(doc().stripe.status, 'refunded');
  assert.equal(store.get(JOB).suggestCancel, true);
});
