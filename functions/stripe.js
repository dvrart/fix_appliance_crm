/**
 * Stripe: инвойсы, депозиты, Checkout-ссылки и webhook оплаты.
 *
 * Ключи — functions/.env:
 *   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET (после создания webhook в Dashboard)
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');

const COMPANY_ID = 'fix_appliance_ca';
const CURRENCY = 'cad';

let _stripe;
function getStripe() {
  if (_stripe !== undefined) return _stripe;
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) {
    _stripe = null;
    return null;
  }
  _stripe = require('stripe')(key);
  return _stripe;
}

const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;
const TWILIO_ACCOUNT_SID = process.env.TWILIO_ACCOUNT_SID;
const TWILIO_PHONE_NUMBER = process.env.TWILIO_PHONE_NUMBER;
const TWILIO_API_KEY_SID = process.env.TWILIO_API_KEY_SID;
const TWILIO_API_KEY_SECRET = process.env.TWILIO_API_KEY_SECRET;
const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;

const { withSmsHeader, sanitizeSmsHeader } = require('./sms_header');

const db = admin.firestore();
const jobsRef = db.collection('companies').doc(COMPANY_ID).collection('jobs');
const clientsRef = db.collection('companies').doc(COMPANY_ID).collection('clients');
const messagesRef = db.collection('companies').doc(COMPANY_ID).collection('messages');

async function getSmsHeader() {
  try {
    const snap = await db
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('documents')
      .get();
    const data = snap.exists ? snap.data() || {} : {};
    return sanitizeSmsHeader(data.smsHeader, data.companyName);
  } catch (_) {
    return '';
  }
}

function setCors(res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
}

function handleOptions(req, res) {
  if (req.method === 'OPTIONS') {
    setCors(res);
    res.status(204).send('');
    return true;
  }
  return false;
}

function toE164(phone) {
  if (!phone) return null;
  const digits = String(phone).replace(/\D/g, '');
  if (!digits) return null;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  if (String(phone).trim().startsWith('+')) return `+${digits}`;
  return `+${digits}`;
}

function toCents(amount) {
  const value = Number(amount);
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.round(value * 100);
}

function fromCents(cents) {
  return Math.round(Number(cents) || 0) / 100;
}

function calcDocTotals(doc) {
  const items = Array.isArray(doc.items) ? doc.items : [];
  const taxRate = Number(doc.taxRate) || 0;
  let subtotal = 0;
  for (const item of items) {
    const qty = Number(item.qty) || 1;
    const price = Number(item.price) || 0;
    subtotal += qty * price;
  }
  const tax = subtotal * taxRate;
  const total = subtotal + tax;
  const payments = Array.isArray(doc.payments) ? doc.payments : [];
  const paid = payments.reduce((sum, p) => sum + (Number(p.amount) || 0), 0);
  const due = Math.max(0, total - paid);
  return { items, taxRate, subtotal, tax, total, paid, due };
}

function alreadyRecorded(doc, ids, amount) {
  const payments = Array.isArray(doc.payments) ? doc.payments : [];
  if (payments.some((p) =>
    ids.some((id) => id && (p.stripeSessionId === id || p.stripePaymentIntentId === id || p.stripeInvoiceId === id))
  )) {
    return true;
  }
  return payments.some((p) => {
    if (!String(p.method || '').includes('Stripe')) return false;
    if (Math.abs((Number(p.amount) || 0) - amount) > 0.009) return false;
    const t = Date.parse(p.date || '');
    return Number.isFinite(t) && Date.now() - t < 10 * 60 * 1000;
  });
}

async function getTwilioClient() {
  const user = TWILIO_API_KEY_SID || TWILIO_ACCOUNT_SID;
  const secret = TWILIO_API_KEY_SECRET || TWILIO_AUTH_TOKEN;
  if (!TWILIO_ACCOUNT_SID || !user || !secret || !TWILIO_PHONE_NUMBER) return null;
  const twilio = require('twilio');
  return twilio(user, secret, { accountSid: TWILIO_ACCOUNT_SID });
}

async function sendPaymentSms({ to, body, clientId }) {
  const e164 = toE164(to);
  if (!e164 || !body) return { sent: false, reason: 'no_phone' };
  const client = await getTwilioClient();
  if (!client) return { sent: false, reason: 'twilio_not_configured' };
  try {
    const header = await getSmsHeader();
    const text = withSmsHeader(body, header);
    const message = await client.messages.create({
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text,
    });
    await messagesRef.add({
      sid: message.sid,
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text,
      direction: 'outbound',
      status: message.status,
      clientId: clientId || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      read: true,
    });
    return { sent: true, sid: message.sid };
  } catch (error) {
    console.error('sendPaymentSms error:', error);
    return { sent: false, reason: error.message };
  }
}

async function getOrCreateStripeCustomer({ clientId, name, email, phone }) {
  const stripe = getStripe();
  let storedEmail = email;
  let storedName = name;
  let storedPhone = phone;

  if (clientId) {
    const snap = await clientsRef.doc(clientId).get();
    if (snap.exists) {
      const data = snap.data() || {};
      storedEmail = storedEmail || data.email || '';
      storedName = storedName || data.fullName || '';
      storedPhone = storedPhone || data.phone || '';
      if (data.stripeCustomerId) {
        try {
          const existing = await stripe.customers.retrieve(data.stripeCustomerId);
          if (existing && !existing.deleted) return existing;
        } catch (error) {
          console.warn('stripe customer retrieve failed, creating a new one', error.message);
        }
      }
    }
  }

  const customer = await stripe.customers.create({
    name: storedName || undefined,
    email: storedEmail || undefined,
    phone: toE164(storedPhone) || undefined,
    metadata: {
      clientId: clientId || '',
      companyId: COMPANY_ID,
    },
  });

  if (clientId) {
    await clientsRef.doc(clientId).set({ stripeCustomerId: customer.id }, { merge: true });
  }
  return customer;
}

async function expirePreviousCheckout(doc) {
  const stripe = getStripe();
  const sessionId = doc?.stripe?.checkoutSessionId;
  if (!sessionId || doc?.stripe?.status === 'paid') return;
  try {
    await stripe.checkout.sessions.expire(sessionId);
  } catch (error) {
    console.warn('expirePreviousCheckout:', error.message);
  }
}

function publicBaseUrl(req) {
  return `https://${req.get('host')}`;
}

function requireStripe(res) {
  if (getStripe()) return false;
  res.status(500).json({
    error: 'Stripe не настроен: добавьте STRIPE_SECRET_KEY в functions/.env и задеплойте functions',
  });
  return true;
}

function isStripeTestMode() {
  const key = process.env.STRIPE_SECRET_KEY || '';
  return key.startsWith('sk_test_');
}

const stripeSettingsRef = db
  .collection('companies')
  .doc(COMPANY_ID)
  .collection('settings')
  .doc('stripe');

async function getOrCreateTerminalLocation() {
  const stripe = getStripe();
  const fromEnv = (process.env.STRIPE_TERMINAL_LOCATION_ID || '').trim();
  const snap = await stripeSettingsRef.get();
  const stored = (snap.exists && snap.data() && snap.data().terminalLocationId) || '';
  const candidate = fromEnv || stored;

  if (candidate) {
    try {
      const existing = await stripe.terminal.locations.retrieve(candidate);
      if (existing && !existing.deleted) {
        if (stored !== existing.id) {
          await stripeSettingsRef.set({ terminalLocationId: existing.id }, { merge: true });
        }
        return existing.id;
      }
    } catch (error) {
      console.warn('terminal location retrieve failed, creating a new one:', error.message);
    }
  }

  const location = await stripe.terminal.locations.create({
    display_name: 'Fix Appliance',
    address: {
      line1: '1 Main Street South',
      city: 'Waterford',
      state: 'ON',
      country: 'CA',
      postal_code: 'N0E 1Y0',
    },
  });
  await stripeSettingsRef.set({ terminalLocationId: location.id }, { merge: true });
  return location.id;
}

exports.createStripePayment = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  const {
    jobId,
    documentIndex,
    kind,
    amount,
    sendSms = true,
    sendEmail = true,
  } = req.body || {};

  if (!jobId || documentIndex === undefined || documentIndex === null) {
    res.status(400).json({ error: 'Нужны jobId и documentIndex' });
    return;
  }

  const kindNorm = String(kind || 'invoice');
  if (!['invoice', 'deposit', 'checkout'].includes(kindNorm)) {
    res.status(400).json({ error: 'kind должен быть invoice, deposit или checkout' });
    return;
  }

  try {
    const jobSnap = await jobsRef.doc(jobId).get();
    if (!jobSnap.exists) {
      res.status(404).json({ error: 'Заявка не найдена' });
      return;
    }
    const job = jobSnap.data() || {};
    const documents = Array.isArray(job.documents) ? [...job.documents] : [];
    const index = Number(documentIndex);
    if (index < 0 || index >= documents.length) {
      res.status(400).json({ error: 'Документ не найден' });
      return;
    }

    const doc = { ...documents[index] };
    if (doc.status === 'cancelled') {
      res.status(400).json({ error: 'Документ отменён' });
      return;
    }

    const totals = calcDocTotals(doc);
    let chargeCents = 0;
    if (kindNorm === 'deposit') {
      chargeCents = toCents(amount);
      if (chargeCents <= 0) {
        res.status(400).json({ error: 'Укажите сумму депозита' });
        return;
      }
      if (chargeCents > toCents(totals.due || totals.total)) {
        res.status(400).json({ error: 'Депозит не может быть больше остатка' });
        return;
      }
    } else {
      chargeCents = toCents(totals.due);
      if (chargeCents <= 0) {
        res.status(400).json({ error: 'По этому документу нечего оплачивать' });
        return;
      }
    }

    const customer = await getOrCreateStripeCustomer({
      clientId: job.clientId || '',
      name: job.clientName || '',
      phone: job.clientPhone || job.jobSitePhone || '',
    });

    await expirePreviousCheckout(doc);

    const metadata = {
      jobId,
      documentIndex: String(index),
      companyId: COMPANY_ID,
      kind: kindNorm,
    };

    const base = publicBaseUrl(req);
    let url = '';
    let checkoutSessionId = '';
    let invoiceId = '';
    let hostedInvoiceUrl = '';

    if (kindNorm === 'invoice') {
      if (doc.type === 'Estimate') {
        doc.type = 'Invoice';
      }

      const invoice = await stripe.invoices.create({
        customer: customer.id,
        collection_method: 'send_invoice',
        days_until_due: 7,
        currency: CURRENCY,
        metadata,
        description: `Fix Appliance — ${job.clientName || 'клиент'}`.trim(),
      });

      for (const item of totals.items) {
        const qty = Number(item.qty) || 1;
        const unit = toCents(item.price);
        if (unit <= 0 || qty <= 0) continue;
        await stripe.invoiceItems.create({
          customer: customer.id,
          invoice: invoice.id,
          currency: CURRENCY,
          description: qty > 1
            ? `${String(item.name || 'Позиция')} × ${qty}`
            : String(item.name || 'Позиция'),
          amount: unit * qty,
        });
      }

      const taxCents = toCents(totals.tax);
      if (taxCents > 0) {
        await stripe.invoiceItems.create({
          customer: customer.id,
          invoice: invoice.id,
          currency: CURRENCY,
          description: `HST ${Math.round(totals.taxRate * 100)}%`,
          amount: taxCents,
        });
      }

      const paidCents = toCents(totals.paid);
      if (paidCents > 0) {
        await stripe.invoiceItems.create({
          customer: customer.id,
          invoice: invoice.id,
          currency: CURRENCY,
          description: 'Уже оплачено',
          amount: -paidCents,
        });
      }

      const finalized = await stripe.invoices.finalizeInvoice(invoice.id);
      if (sendEmail && customer.email) {
        try {
          await stripe.invoices.sendInvoice(invoice.id);
        } catch (error) {
          console.warn('sendInvoice email failed:', error.message);
        }
      }

      invoiceId = finalized.id;
      hostedInvoiceUrl = finalized.hosted_invoice_url || '';
      url = hostedInvoiceUrl;
    } else {
      const label =
        kindNorm === 'deposit'
          ? `Депозит — Fix Appliance`
          : `Оплата счёта — Fix Appliance`;
      const session = await stripe.checkout.sessions.create({
        mode: 'payment',
        customer: customer.id,
        client_reference_id: jobId,
        metadata,
        success_url: `${base}/stripePaymentComplete?status=success`,
        cancel_url: `${base}/stripePaymentComplete?status=cancel`,
        invoice_creation: {
          enabled: true,
          invoice_data: {
            description: label,
            metadata,
          },
        },
        line_items: [
          {
            quantity: 1,
            price_data: {
              currency: CURRENCY,
              unit_amount: chargeCents,
              product_data: {
                name: label,
                description: job.clientName ? `Клиент: ${job.clientName}` : undefined,
              },
            },
          },
        ],
      });
      checkoutSessionId = session.id;
      url = session.url;
    }

    if (!url) {
      res.status(500).json({ error: 'Stripe не вернул ссылку на оплату' });
      return;
    }

    doc.stripe = {
      mode: kindNorm,
      status: 'open',
      url,
      amount: fromCents(chargeCents),
      checkoutSessionId: checkoutSessionId || doc.stripe?.checkoutSessionId || '',
      invoiceId: invoiceId || '',
      hostedInvoiceUrl: hostedInvoiceUrl || '',
      createdAt: new Date().toISOString(),
    };
    documents[index] = doc;
    await jobsRef.doc(jobId).update({
      documents,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    let sms = { sent: false };
    if (sendSms) {
      const dollars = fromCents(chargeCents).toFixed(2);
      const body =
        kindNorm === 'deposit'
          ? `Депозит $${dollars}. Оплатить: ${url}`
          : `Счёт на оплату $${dollars}. Оплатить: ${url}`;
      sms = await sendPaymentSms({
        to: job.clientPhone || job.jobSitePhone,
        body,
        clientId: job.clientId,
      });
    }

    res.json({
      success: true,
      kind: kindNorm,
      url,
      amount: fromCents(chargeCents),
      invoiceId,
      checkoutSessionId,
      smsSent: sms.sent === true,
      smsError: sms.sent ? null : sms.reason || null,
    });
  } catch (error) {
    console.error('createStripePayment error:', error);
    res.status(500).json({ error: error.message });
  }
});

exports.createTerminalConnectionToken = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (req.method !== 'POST' && req.method !== 'GET') {
    res.status(405).json({ error: 'GET or POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  try {
    const locationId = await getOrCreateTerminalLocation();
    const token = await stripe.terminal.connectionTokens.create({ location: locationId });
    res.json({
      success: true,
      secret: token.secret,
      locationId,
      simulated: isStripeTestMode(),
    });
  } catch (error) {
    console.error('createTerminalConnectionToken error:', error);
    res.status(500).json({ error: error.message });
  }
});

exports.createTerminalPaymentIntent = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  const { jobId, documentIndex } = req.body || {};
  if (!jobId || documentIndex === undefined || documentIndex === null) {
    res.status(400).json({ error: 'Нужны jobId и documentIndex' });
    return;
  }

  try {
    const jobSnap = await jobsRef.doc(jobId).get();
    if (!jobSnap.exists) {
      res.status(404).json({ error: 'Заявка не найдена' });
      return;
    }
    const job = jobSnap.data() || {};
    const documents = Array.isArray(job.documents) ? [...job.documents] : [];
    const index = Number(documentIndex);
    if (index < 0 || index >= documents.length) {
      res.status(400).json({ error: 'Документ не найден' });
      return;
    }

    const doc = { ...documents[index] };
    if (doc.status === 'cancelled') {
      res.status(400).json({ error: 'Документ отменён' });
      return;
    }

    const totals = calcDocTotals(doc);
    const chargeCents = toCents(totals.due);
    if (chargeCents <= 0) {
      res.status(400).json({ error: 'По этому документу нечего оплачивать' });
      return;
    }

    await expirePreviousCheckout(doc);

    const paymentIntent = await stripe.paymentIntents.create({
      amount: chargeCents,
      currency: CURRENCY,
      payment_method_types: ['card_present'],
      capture_method: 'automatic',
      description: `Fix Appliance — ${job.clientName || 'клиент'}`.trim(),
      metadata: {
        jobId,
        documentIndex: String(index),
        companyId: COMPANY_ID,
        kind: 'tap_to_pay',
      },
    });

    doc.stripe = {
      ...(doc.stripe || {}),
      mode: 'tap_to_pay',
      status: 'collecting',
      paymentIntentId: paymentIntent.id,
      amount: fromCents(chargeCents),
      createdAt: new Date().toISOString(),
    };
    documents[index] = doc;
    await jobsRef.doc(jobId).update({
      documents,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    res.json({
      success: true,
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      amount: fromCents(chargeCents),
      simulated: isStripeTestMode(),
    });
  } catch (error) {
    console.error('createTerminalPaymentIntent error:', error);
    res.status(500).json({ error: error.message });
  }
});

exports.completeTerminalPayment = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  const { paymentIntentId } = req.body || {};
  if (!paymentIntentId) {
    res.status(400).json({ error: 'Нужен paymentIntentId' });
    return;
  }

  try {
    const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
    if (!['succeeded', 'requires_capture'].includes(pi.status)) {
      res.status(400).json({
        error: `Платёж ещё не завершён (статус: ${pi.status})`,
        status: pi.status,
      });
      return;
    }

    const metadata = pi.metadata || {};
    const amount = fromCents(pi.amount_received || pi.amount);
    const recorded = await recordStripePayment({
      jobId: metadata.jobId,
      documentIndex: metadata.documentIndex,
      amount,
      ids: [pi.id].filter(Boolean),
      methodLabel: 'Stripe (карта на месте)',
    });

    res.json({
      success: true,
      recorded,
      amount,
      paymentIntentId: pi.id,
      status: pi.status,
    });
  } catch (error) {
    console.error('completeTerminalPayment error:', error);
    res.status(500).json({ error: error.message });
  }
});

async function recordStripePayment({ jobId, documentIndex, amount, ids, methodLabel }) {
  if (!jobId || documentIndex === undefined || documentIndex === null) {
    console.warn('recordStripePayment: missing job metadata');
    return false;
  }
  const index = Number(documentIndex);
  const jobRef = jobsRef.doc(jobId);
  let recorded = false;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(jobRef);
    if (!snap.exists) return;
    const job = snap.data() || {};
    const documents = Array.isArray(job.documents) ? [...job.documents] : [];
    if (index < 0 || index >= documents.length) return;
    const doc = { ...documents[index] };
    if (alreadyRecorded(doc, ids, amount)) {
      recorded = true;
      return;
    }
    const payments = Array.isArray(doc.payments) ? [...doc.payments] : [];
    payments.push({
      amount,
      method: methodLabel,
      date: new Date().toISOString(),
      stripeSessionId: ids.find((id) => id && String(id).startsWith('cs_')) || '',
      stripePaymentIntentId: ids.find((id) => id && String(id).startsWith('pi_')) || '',
      stripeInvoiceId: ids.find((id) => id && String(id).startsWith('in_')) || '',
    });
    doc.payments = payments;
    doc.stripe = {
      ...(doc.stripe || {}),
      status: 'paid',
    };
    documents[index] = doc;
    tx.update(jobRef, {
      documents,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    recorded = true;
  });

  return recorded;
}

async function handleCheckoutCompleted(session) {
  const metadata = session.metadata || {};
  const amount = fromCents(session.amount_total);
  await recordStripePayment({
    jobId: metadata.jobId,
    documentIndex: metadata.documentIndex,
    amount,
    ids: [session.id, session.payment_intent, session.invoice].filter(Boolean),
    methodLabel: metadata.kind === 'deposit' ? 'Stripe (депозит)' : 'Stripe',
  });
}

async function handlePaymentIntentSucceeded(pi) {
  const metadata = pi.metadata || {};
  const types = Array.isArray(pi.payment_method_types) ? pi.payment_method_types : [];
  if (metadata.kind !== 'tap_to_pay' && !types.includes('card_present')) return;
  if (!metadata.jobId) return;
  const amount = fromCents(pi.amount_received || pi.amount);
  await recordStripePayment({
    jobId: metadata.jobId,
    documentIndex: metadata.documentIndex,
    amount,
    ids: [pi.id].filter(Boolean),
    methodLabel: metadata.kind === 'tap_to_pay' ? 'Stripe (карта на месте)' : 'Stripe',
  });
}

async function handleInvoicePaid(invoice) {
  const metadata = invoice.metadata || {};
  let jobId = metadata.jobId;
  let documentIndex = metadata.documentIndex;
  if (!jobId && invoice.id) {
    // Checkout-created invoices inherit invoice_data.metadata
    jobId = metadata.jobId;
  }
  const amount = fromCents(invoice.amount_paid);
  await recordStripePayment({
    jobId,
    documentIndex,
    amount,
    ids: [invoice.id, invoice.payment_intent].filter(Boolean),
    methodLabel: 'Stripe',
  });
}

exports.stripeWebhook = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }
  const stripe = getStripe();
  if (!stripe) {
    res.status(500).send('Stripe is not configured');
    return;
  }
  if (!STRIPE_WEBHOOK_SECRET) {
    res.status(500).send('STRIPE_WEBHOOK_SECRET is not set');
    return;
  }

  const signature = req.headers['stripe-signature'];
  let event;
  try {
    event = stripe.webhooks.constructEvent(req.rawBody, signature, STRIPE_WEBHOOK_SECRET);
  } catch (error) {
    console.error('stripeWebhook signature error:', error.message);
    res.status(400).send(`Webhook Error: ${error.message}`);
    return;
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed':
      case 'checkout.session.async_payment_succeeded': {
        const session = event.data.object;
        if (session.payment_status === 'paid' || event.type === 'checkout.session.async_payment_succeeded') {
          await handleCheckoutCompleted(session);
        }
        break;
      }
      case 'invoice.paid':
        await handleInvoicePaid(event.data.object);
        break;
      case 'payment_intent.succeeded':
        await handlePaymentIntentSucceeded(event.data.object);
        break;
      default:
        break;
    }
    res.json({ received: true });
  } catch (error) {
    console.error('stripeWebhook handler error:', error);
    res.status(500).json({ error: error.message });
  }
});

exports.stripePaymentComplete = functions.https.onRequest(async (req, res) => {
  const status = (req.query.status || 'success').toString();
  const ok = status === 'success';
  res.set('Content-Type', 'text/html; charset=utf-8');
  res.status(200).send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${ok ? 'Payment received' : 'Payment cancelled'}</title>
  <style>
    body { font-family: sans-serif; background: #14557F; color: white; display: flex;
      align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: white; color: #14557F; border-radius: 16px; padding: 32px;
      max-width: 420px; text-align: center; }
    h1 { margin-top: 0; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${ok ? 'Спасибо!' : 'Оплата отменена'}</h1>
    <p>${ok
      ? 'Платёж принят. Можно закрыть эту страницу.'
      : 'Вы можете закрыть страницу и открыть ссылку ещё раз, когда будете готовы оплатить.'}</p>
  </div>
</body>
</html>`);
});
