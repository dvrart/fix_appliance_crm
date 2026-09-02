/**
 * Stripe: инвойсы, депозиты, Checkout-ссылки и webhook оплаты.
 *
 * Ключи — functions/.env:
 *   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET (после создания webhook в Dashboard)
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { requireAppUser } = require('./auth_guard');

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
const { shortenPayUrl } = require('./short_links');

const db = admin.firestore();
const jobsRef = db.collection('companies').doc(COMPANY_ID).collection('jobs');
const clientsRef = db.collection('companies').doc(COMPANY_ID).collection('clients');
const messagesRef = db.collection('companies').doc(COMPANY_ID).collection('messages');
const SMS_STATUS_CB =
  'https://us-central1-fix-appliance-crm.cloudfunctions.net/smsStatusCallback';

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

async function getOrCreateTipPrice() {
  const stripe = getStripe();
  const listed = await stripe.prices.list({ lookup_keys: ['fix_tip_cad_1'], limit: 1 });
  if (listed.data[0]) return listed.data[0].id;
  const price = await stripe.prices.create({
    currency: CURRENCY,
    unit_amount: 100,
    lookup_key: 'fix_tip_cad_1',
    transfer_lookup_key: true,
    product_data: { name: 'Tip' },
  });
  return price.id;
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

async function sendPaymentSms({ to, body, clientId, fallbackBody }) {
  const e164 = toE164(to);
  if (!e164 || !body) {
    console.warn('sendPaymentSms skipped: no_phone');
    return { sent: false, reason: 'no_phone' };
  }
  const client = await getTwilioClient();
  if (!client) return { sent: false, reason: 'twilio_not_configured' };
  try {
    const header = await getSmsHeader();
    const text = withSmsHeader(body, header);
    const fallback = String(fallbackBody || '').trim();
    const fallbackText = fallback && fallback !== body
      ? withSmsHeader(fallback, header)
      : '';
    const message = await client.messages.create({
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text,
      statusCallback: SMS_STATUS_CB,
    });
    await messagesRef.add({
      sid: message.sid,
      from: TWILIO_PHONE_NUMBER,
      to: e164,
      body: text,
      fallbackBody: fallbackText,
      retried30007: false,
      direction: 'outbound',
      status: message.status,
      clientId: clientId || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      read: true,
    });
    console.log('sendPaymentSms', {
      to: e164.slice(-4),
      sid: message.sid,
      status: message.status,
    });
    return { sent: true, sid: message.sid };
  } catch (error) {
    console.error(
      'sendPaymentSms error:',
      error.code || '',
      error.message,
    );
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
    preferred_locales: ['en-CA', 'en'],
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

  async function useIfValid(id) {
    if (!id) return null;
    try {
      const existing = await stripe.terminal.locations.retrieve(id);
      if (existing && !existing.deleted) return existing.id;
    } catch (error) {
      console.warn('terminal location retrieve failed:', error.message);
    }
    return null;
  }

  const envId = await useIfValid(fromEnv);
  if (envId) {
    if (stored !== envId) {
      await stripeSettingsRef.set({ terminalLocationId: envId }, { merge: true });
    }
    return envId;
  }

  try {
    const readers = await stripe.terminal.readers.list({ limit: 20 });
    const registered = (readers.data || []).find((reader) => reader.location);
    if (registered && registered.location) {
      const locId =
        typeof registered.location === 'string'
          ? registered.location
          : registered.location.id;
      const valid = await useIfValid(locId);
      if (valid) {
        if (stored !== valid) {
          await stripeSettingsRef.set({ terminalLocationId: valid }, { merge: true });
        }
        return valid;
      }
    }
  } catch (error) {
    console.warn('terminal readers list failed:', error.message);
  }

  const storedId = await useIfValid(stored);
  if (storedId) return storedId;

  try {
    const listed = await stripe.terminal.locations.list({ limit: 20 });
    if (listed.data && listed.data.length) {
      const existing = listed.data[0];
      await stripeSettingsRef.set({ terminalLocationId: existing.id }, { merge: true });
      return existing.id;
    }
  } catch (error) {
    console.warn('terminal location list failed, creating a new one:', error.message);
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

exports.getStripeBalance = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  if (req.method !== 'GET' && req.method !== 'POST') {
    res.status(405).json({ error: 'GET or POST' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();
  try {
    const balance = await stripe.balance.retrieve();
    const sum = (rows) =>
      (rows || []).reduce((total, row) => total + Number(row.amount || 0), 0);
    const availableCents = sum(balance.available);
    const pendingCents = sum(balance.pending);
    const currency =
      (balance.available && balance.available[0] && balance.available[0].currency) ||
      (balance.pending && balance.pending[0] && balance.pending[0].currency) ||
      CURRENCY;
    res.json({
      success: true,
      available: availableCents / 100,
      pending: pendingCents / 100,
      currency: String(currency).toUpperCase(),
      livemode: balance.livemode === true,
    });
  } catch (error) {
    console.error('getStripeBalance error:', error);
    res.status(500).json({ error: error.message || 'Не удалось прочитать баланс Stripe' });
  }
});

exports.createStripePayment = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
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
    to: toPhone,
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
    const dueCents = toCents(totals.due);
    const tipCents = Math.max(0, toCents(req.body.tip));
    let baseCents = 0;
    if (kindNorm === 'deposit') {
      baseCents = toCents(amount);
      if (baseCents <= 0) {
        res.status(400).json({ error: 'Укажите сумму депозита' });
        return;
      }
      if (baseCents > dueCents) {
        res.status(400).json({ error: 'Депозит не может быть больше остатка' });
        return;
      }
    } else {
      baseCents = dueCents;
      if (baseCents <= 0) {
        res.status(400).json({ error: 'По этому документу нечего оплачивать' });
        return;
      }
    }
    const chargeCents = baseCents + tipCents;

    const customer = await getOrCreateStripeCustomer({
      clientId: job.clientId || '',
      name: job.clientName || '',
      phone: toPhone || job.clientPhone || job.jobSitePhone || '',
    });

    await expirePreviousCheckout(doc);

    const metadata = {
      jobId,
      documentIndex: String(index),
      companyId: COMPANY_ID,
      kind: kindNorm,
      dueCents: String(baseCents),
      tipCents: String(tipCents),
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
        description: `Fix Appliance — ${job.clientName || 'customer'}`.trim(),
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
            ? `${String(item.name || 'Item')} × ${qty}`
            : String(item.name || 'Item'),
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
          description: 'Already paid',
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
          ? `Deposit — Fix Appliance`
          : `Invoice payment — Fix Appliance`;
      const lineItems = [
        {
          quantity: 1,
          price_data: {
            currency: CURRENCY,
            unit_amount: baseCents,
            product_data: {
              name: label,
              description: job.clientName ? `Customer: ${job.clientName}` : undefined,
            },
          },
        },
      ];
      if (tipCents > 0) {
        lineItems.push({
          quantity: 1,
          price_data: {
            currency: CURRENCY,
            unit_amount: tipCents,
            product_data: { name: 'Tip' },
          },
        });
      }
      let optionalItems;
      if (tipCents === 0) {
        try {
          const tipPriceId = await getOrCreateTipPrice();
          optionalItems = [
            {
              price: tipPriceId,
              quantity: 0,
              adjustable_quantity: { enabled: true, minimum: 0, maximum: 250 },
            },
          ];
        } catch (error) {
          console.warn('optional tip price:', error.message);
        }
      }
      let session;
      try {
        session = await stripe.checkout.sessions.create({
          mode: 'payment',
          customer: customer.id,
          client_reference_id: jobId,
          metadata,
          locale: 'en',
          success_url: `${base}/stripePaymentComplete?status=success`,
          cancel_url: `${base}/stripePaymentComplete?status=cancel`,
          invoice_creation: {
            enabled: true,
            invoice_data: {
              description: label,
              metadata,
            },
          },
          line_items: lineItems,
          ...(optionalItems ? { optional_items: optionalItems } : {}),
        });
      } catch (error) {
        if (!optionalItems) throw error;
        console.warn('checkout optional tip skipped:', error.message);
        session = await stripe.checkout.sessions.create({
          mode: 'payment',
          customer: customer.id,
          client_reference_id: jobId,
          metadata,
          locale: 'en',
          success_url: `${base}/stripePaymentComplete?status=success`,
          cancel_url: `${base}/stripePaymentComplete?status=cancel`,
          invoice_creation: {
            enabled: true,
            invoice_data: {
              description: label,
              metadata,
            },
          },
          line_items: lineItems,
        });
      }
      checkoutSessionId = session.id;
      url = session.url;
    }

    if (!url) {
      res.status(500).json({ error: 'Stripe не вернул ссылку на оплату' });
      return;
    }

    let publicUrl = url;
    let carrierUrl = '';
    try {
      const shortened = await shortenPayUrl(url, {
        type: kindNorm === 'deposit' ? 'deposit' : 'pay',
        jobId,
        code: doc.stripe && doc.stripe.shortCode,
      });
      if (shortened && shortened.shortUrl) publicUrl = shortened.shortUrl;
      if (shortened && shortened.carrierUrl) carrierUrl = shortened.carrierUrl;
    } catch (error) {
      console.warn('shorten payment url:', error.message);
    }
    const shortCode = (() => {
      try {
        const parsed = new URL(publicUrl);
        return parsed.searchParams.get('c') ||
            parsed.searchParams.get('code') ||
            parsed.pathname.split('/').filter(Boolean).pop() ||
            '';
      } catch (_) {
        return String(publicUrl).split('/').filter(Boolean).pop() || '';
      }
    })();

    doc.stripe = {
      mode: kindNorm,
      status: 'open',
      url: publicUrl,
      rawUrl: url,
      smsUrl: url,
      amount: fromCents(chargeCents),
      checkoutSessionId: checkoutSessionId || doc.stripe?.checkoutSessionId || '',
      invoiceId: invoiceId || '',
      hostedInvoiceUrl: hostedInvoiceUrl || '',
      shortUrl: publicUrl,
      shortCode,
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
      const tipNote =
        tipCents === 0 && kindNorm !== 'deposit'
          ? '\nYou can add a tip on the payment page if you wish.'
          : '';
      // SMS uses the long Stripe Checkout URL (same idea as estimateConfirm).
      // Short shop / pay. links are copied in the app but carriers drop them (Twilio 30007).
      const payBody = (link) =>
        kindNorm === 'deposit'
          ? `Thank you for choosing FIX-Appliance CA.\n\nPlease pay a $${dollars} deposit for your repair.\n\nOpen this page to pay:\n${link}`
          : `Thank you for choosing FIX-Appliance CA.\n\nPlease pay $${dollars} for your repair.${tipNote}\n\nOpen this page to pay:\n${link}`;
      const fallbackLink = carrierUrl && carrierUrl !== url ? carrierUrl : '';
      sms = await sendPaymentSms({
        to: toPhone || job.clientPhone || job.jobSitePhone,
        body: payBody(url),
        fallbackBody: fallbackLink ? payBody(fallbackLink) : '',
        clientId: job.clientId,
      });
    }

    res.json({
      success: true,
      kind: kindNorm,
      url: publicUrl,
      rawUrl: url,
      smsUrl: url,
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
  if (!(await requireAppUser(req, res))) return;
  if (req.method !== 'POST' && req.method !== 'GET') {
    res.status(405).json({ error: 'GET or POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  try {
    const locationId = await getOrCreateTerminalLocation();
    const token = await stripe.terminal.connectionTokens.create();
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
  if (!(await requireAppUser(req, res))) return;
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
    const dueCents = toCents(totals.due);
    const tipCents = Math.max(0, toCents(req.body.tip));
    const requested = toCents(req.body.amount);
    const maxCents = Math.max(dueCents, Math.round(dueCents * 2.5));
    let chargeCents = requested > 0 ? requested : dueCents + tipCents;
    if (tipCents > 0 && requested <= 0) chargeCents = dueCents + tipCents;
    if (chargeCents > maxCents) chargeCents = maxCents;
    if (chargeCents <= 0) {
      res.status(400).json({ error: 'По этому документу нечего оплачивать' });
      return;
    }
    const baseCents = Math.max(0, chargeCents - tipCents);

    await expirePreviousCheckout(doc);

    const paymentIntent = await stripe.paymentIntents.create({
      amount: chargeCents,
      currency: CURRENCY,
      payment_method_types: ['card_present'],
      capture_method: 'automatic',
      description: `Fix Appliance — ${job.clientName || 'customer'}`.trim(),
      payment_method_options: {
        card_present: {},
      },
      metadata: {
        jobId,
        documentIndex: String(index),
        companyId: COMPANY_ID,
        kind: 'tap_to_pay',
        dueCents: String(baseCents),
        tipCents: String(tipCents),
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
      due: fromCents(dueCents),
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
  if (!(await requireAppUser(req, res))) return;
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
    const tipCents =
      (pi.amount_details && pi.amount_details.tip && pi.amount_details.tip.amount) || 0;
    const dueCents = Number(metadata.dueCents || 0);
    const tip = fromCents(tipCents) || (dueCents > 0 ? Math.max(0, amount - fromCents(dueCents)) : 0);
    const recorded = await recordStripePayment({
      jobId: metadata.jobId,
      documentIndex: metadata.documentIndex,
      amount,
      tip,
      ids: [pi.id].filter(Boolean),
      methodLabel: 'Stripe (card present)',
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

function asMoney(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function invoiceDocTotal(doc) {
  const items = Array.isArray(doc.items) ? doc.items : [];
  let subtotal = 0;
  for (const item of items) {
    if (!item || typeof item !== 'object') continue;
    const qty = item.qty == null ? 1 : asMoney(item.qty);
    subtotal += qty * asMoney(item.price);
  }
  return subtotal + subtotal * asMoney(doc.taxRate);
}

function invoiceDocPaid(doc) {
  const payments = Array.isArray(doc.payments) ? doc.payments : [];
  let total = 0;
  for (const payment of payments) {
    if (payment && typeof payment === 'object') total += asMoney(payment.amount);
  }
  if (
    total <= 0.009 &&
    doc.stripe &&
    typeof doc.stripe === 'object' &&
    String(doc.stripe.status || '') === 'paid'
  ) {
    return invoiceDocTotal(doc);
  }
  return total;
}

function isInvoiceDoc(doc) {
  if (!doc || typeof doc !== 'object') return false;
  const type = String(doc.type || 'Invoice');
  if (type === 'Estimate') return false;
  const status = String(doc.status || '').toLowerCase();
  if (status.includes('cancel') || status.includes('void') || status.includes('отмен')) {
    return false;
  }
  return true;
}

function isInvoiceFullyPaid(doc) {
  if (!isInvoiceDoc(doc) || doc.deletedAt) return false;
  const total = invoiceDocTotal(doc);
  if (total <= 0.009) return false;
  return total - invoiceDocPaid(doc) <= 0.009;
}

function isCompletedJobStatus(status) {
  const n = String(status || '').trim().toLowerCase();
  return (
    n === 'завершено' ||
    n.includes('заверш') ||
    n === 'готово' ||
    n === 'готов' ||
    n === 'completed' ||
    n === 'ready'
  );
}

function markJobVisitsDone(job) {
  const visits = Array.isArray(job.visits) ? job.visits : [];
  if (!visits.length) return null;
  return visits.map((visit) => {
    if (!visit || typeof visit !== 'object') return visit;
    const outcome = String(visit.outcome || 'scheduled');
    if (outcome === 'done' || outcome === 'cancelled') return visit;
    if (String(visit.smsConfirmStatus || '') === 'cancelled') return visit;
    return { ...visit, outcome: 'done' };
  });
}

function markJobVisitsCancelled(job) {
  const visits = Array.isArray(job.visits) ? job.visits : [];
  if (!visits.length) return null;
  return visits.map((visit) => {
    if (!visit || typeof visit !== 'object') return visit;
    const outcome = String(visit.outcome || 'scheduled');
    if (outcome === 'cancelled') return visit;
    return { ...visit, outcome: 'cancelled' };
  });
}

function alreadyRefundRecorded(doc, refundId) {
  if (!refundId) return false;
  const payments = Array.isArray(doc.payments) ? doc.payments : [];
  return payments.some((p) => p && String(p.stripeRefundId || '') === String(refundId));
}

function isStripePaymentEntry(p) {
  if (!p || typeof p !== 'object') return false;
  if ((Number(p.amount) || 0) <= 0.009) return false;
  if (p.stripePaymentIntentId || p.stripeSessionId || p.stripeInvoiceId) return true;
  return String(p.method || '').includes('Stripe');
}

async function resolvePaymentIntentId(payment) {
  const stripe = getStripe();
  const direct = String(payment.stripePaymentIntentId || '').trim();
  if (direct.startsWith('pi_')) return direct;

  const sessionId = String(payment.stripeSessionId || '').trim();
  if (sessionId.startsWith('cs_')) {
    const session = await stripe.checkout.sessions.retrieve(sessionId);
    const pi = session.payment_intent;
    return typeof pi === 'string' ? pi : (pi && pi.id) || null;
  }

  const invoiceId = String(payment.stripeInvoiceId || '').trim();
  if (invoiceId.startsWith('in_')) {
    const invoice = await stripe.invoices.retrieve(invoiceId);
    const pi = invoice.payment_intent;
    return typeof pi === 'string' ? pi : (pi && pi.id) || null;
  }
  return null;
}

function collectUniqueStripePayments(doc) {
  const payments = Array.isArray(doc.payments) ? doc.payments : [];
  const seen = new Set();
  const list = [];
  for (const payment of payments) {
    if (!isStripePaymentEntry(payment)) continue;
    const key =
      payment.stripePaymentIntentId ||
      payment.stripeSessionId ||
      payment.stripeInvoiceId ||
      `${payment.method}|${payment.date}|${payment.amount}`;
    if (seen.has(key)) continue;
    seen.add(key);
    list.push(payment);
  }
  return list;
}

async function recordDocumentRefund({
  jobId,
  documentIndex,
  amount,
  methodLabel,
  stripeRefundId = '',
  paymentIntentId = '',
  cancelCompletedJob = true,
}) {
  if (!jobId || documentIndex === undefined || documentIndex === null) {
    return { recorded: false, refunded: 0, jobCancelled: false };
  }
  const refundAmount = Math.max(0, Number(amount) || 0);
  if (refundAmount <= 0.009) {
    return { recorded: false, refunded: 0, jobCancelled: false };
  }

  const index = Number(documentIndex);
  const jobRef = jobsRef.doc(jobId);
  let recorded = false;
  let jobCancelled = false;
  let netPaid = 0;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(jobRef);
    if (!snap.exists) return;
    const job = snap.data() || {};
    const documents = Array.isArray(job.documents) ? [...job.documents] : [];
    if (index < 0 || index >= documents.length) return;
    const doc = { ...documents[index] };
    if (stripeRefundId && alreadyRefundRecorded(doc, stripeRefundId)) {
      recorded = true;
      netPaid = invoiceDocPaid(doc);
      return;
    }

    const payments = Array.isArray(doc.payments) ? [...doc.payments] : [];
    payments.push({
      amount: -refundAmount,
      method: methodLabel,
      date: new Date().toISOString(),
      stripeRefundId: stripeRefundId || '',
      stripePaymentIntentId: paymentIntentId || '',
    });
    doc.payments = payments;

    const paid = invoiceDocPaid(doc);
    netPaid = paid;
    const prevStripe = doc.stripe && typeof doc.stripe === 'object' ? doc.stripe : {};
    doc.stripe = {
      ...prevStripe,
      status: paid <= 0.009 ? 'refunded' : 'partially_refunded',
      refundedAt: new Date().toISOString(),
      lastRefundAmount: refundAmount,
    };
    documents[index] = doc;

    const updates = {
      documents,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (
      cancelCompletedJob &&
      paid <= 0.009 &&
      isCompletedJobStatus(job.status)
    ) {
      updates.status = 'Отменено';
      updates.needsReview = false;
      updates.requestReviewSms = false;
      const visits = markJobVisitsCancelled(job);
      if (visits) updates.visits = visits;
      jobCancelled = true;
    }

    tx.update(jobRef, updates);
    recorded = true;
  });

  return { recorded, refunded: refundAmount, jobCancelled, netPaid };
}

async function recordStripePayment({ jobId, documentIndex, amount, ids, methodLabel, tip = 0 }) {
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
    const tipAmount = tip > 0.009 ? tip : 0;
    const jobAmount = Math.max(0, Number(amount) - tipAmount);
    payments.push({
      amount: jobAmount,
      method: methodLabel,
      date: new Date().toISOString(),
      tip: tipAmount,
      stripeSessionId: ids.find((id) => id && String(id).startsWith('cs_')) || '',
      stripePaymentIntentId: ids.find((id) => id && String(id).startsWith('pi_')) || '',
      stripeInvoiceId: ids.find((id) => id && String(id).startsWith('in_')) || '',
    });
    if (tipAmount) {
      payments.push({
        amount: tipAmount,
        method: 'Чаевые',
        date: new Date().toISOString(),
        stripePaymentIntentId: ids.find((id) => id && String(id).startsWith('pi_')) || '',
      });
    }
    doc.payments = payments;
    doc.stripe = {
      ...(doc.stripe || {}),
      status: 'paid',
    };
    documents[index] = doc;
    const updates = {
      documents,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (isInvoiceFullyPaid(doc) && !isCompletedJobStatus(job.status)) {
      updates.status = 'Завершено';
      updates.completedAt = admin.firestore.FieldValue.serverTimestamp();
      const visits = markJobVisitsDone(job);
      if (visits) updates.visits = visits;
    }
    tx.update(jobRef, updates);
    recorded = true;
  });

  return recorded;
}

async function handleCheckoutCompleted(session) {
  const metadata = session.metadata || {};
  const amount = fromCents(session.amount_total);
  const dueCents = Number(metadata.dueCents || 0);
  const tip =
    dueCents > 0
      ? Math.max(0, amount - fromCents(dueCents))
      : fromCents(metadata.tipCents || 0);
  await recordStripePayment({
    jobId: metadata.jobId,
    documentIndex: metadata.documentIndex,
    amount,
    tip,
    ids: [session.id, session.payment_intent, session.invoice].filter(Boolean),
    methodLabel: metadata.kind === 'deposit' ? 'Stripe (deposit)' : 'Stripe',
  });
}

/**
 * Возврат по счёту: Stripe refund по PaymentIntent + запись отрицательного
 * платежа. Остаток без Stripe (наличные) пишется локально.
 * Полный возврат по оплаченному счёту переводит завершённую работу в «Отменено».
 */
exports.createStripeRefund = functions.https.onRequest(async (req, res) => {
  if (handleOptions(req, res)) return;
  setCors(res);
  if (!(await requireAppUser(req, res))) return;
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST only' });
    return;
  }
  if (requireStripe(res)) return;
  const stripe = getStripe();

  const { jobId, documentIndex, amount } = req.body || {};
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
    const documents = Array.isArray(job.documents) ? job.documents : [];
    const index = Number(documentIndex);
    if (index < 0 || index >= documents.length) {
      res.status(400).json({ error: 'Документ не найден' });
      return;
    }

    const doc = documents[index] || {};
    if (doc.status === 'cancelled' || doc.deletedAt) {
      res.status(400).json({ error: 'Документ отменён или удалён' });
      return;
    }
    if (String(doc.type || 'Invoice') === 'Estimate') {
      res.status(400).json({ error: 'Смету нельзя возвращать — нужен счёт' });
      return;
    }

    const totals = calcDocTotals(doc);
    if (totals.paid <= 0.009) {
      res.status(400).json({ error: 'По этому счёту нечего возвращать' });
      return;
    }

    const requested = amount == null || amount === ''
      ? totals.paid
      : Number(amount);
    if (!Number.isFinite(requested) || requested <= 0.009) {
      res.status(400).json({ error: 'Укажите сумму возврата' });
      return;
    }
    let remainingCents = toCents(Math.min(requested, totals.paid));
    if (remainingCents <= 0) {
      res.status(400).json({ error: 'Укажите сумму возврата' });
      return;
    }

    const stripeRefunds = [];
    const stripePayments = collectUniqueStripePayments(doc);
    for (const payment of stripePayments) {
      if (remainingCents <= 0) break;
      let paymentIntentId = null;
      try {
        paymentIntentId = await resolvePaymentIntentId(payment);
      } catch (error) {
        console.warn('resolvePaymentIntentId:', error.message);
        continue;
      }
      if (!paymentIntentId) continue;

      const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
      const received = Number(pi.amount_received || pi.amount || 0);
      const already = Number(pi.amount_refunded || 0);
      const available = Math.max(0, received - already);
      if (available <= 0) continue;

      const refundThis = Math.min(remainingCents, available);
      const refund = await stripe.refunds.create(
        {
          payment_intent: paymentIntentId,
          amount: refundThis,
          reason: 'requested_by_customer',
          metadata: {
            jobId: String(jobId),
            documentIndex: String(index),
            companyId: COMPANY_ID,
            source: 'createStripeRefund',
          },
        },
        {
          idempotencyKey: `job_${jobId}_doc_${index}_${paymentIntentId}_${refundThis}`,
        }
      );

      const dollars = fromCents(refundThis);
      await recordDocumentRefund({
        jobId,
        documentIndex: index,
        amount: dollars,
        methodLabel: 'Stripe (refund)',
        stripeRefundId: refund.id,
        paymentIntentId,
        cancelCompletedJob: true,
      });
      stripeRefunds.push({
        refundId: refund.id,
        paymentIntentId,
        amount: dollars,
      });
      remainingCents -= refundThis;
    }

    let cashRefunded = 0;
    if (remainingCents > 0) {
      cashRefunded = fromCents(remainingCents);
      await recordDocumentRefund({
        jobId,
        documentIndex: index,
        amount: cashRefunded,
        methodLabel: 'Возврат (наличные)',
        cancelCompletedJob: true,
      });
      remainingCents = 0;
    }

    const freshSnap = await jobsRef.doc(jobId).get();
    const freshJob = freshSnap.exists ? freshSnap.data() || {} : {};
    const freshDocs = Array.isArray(freshJob.documents) ? freshJob.documents : [];
    const freshDoc = freshDocs[index] || {};
    const freshTotals = calcDocTotals(freshDoc);
    const jobCancelled =
      String(freshJob.status || '') === 'Отменено' &&
      isCompletedJobStatus(job.status);

    const totalRefunded =
      stripeRefunds.reduce((s, r) => s + (Number(r.amount) || 0), 0) + cashRefunded;

    res.json({
      success: true,
      refunded: totalRefunded,
      stripeRefunds,
      cashRefunded,
      netPaid: freshTotals.paid,
      due: freshTotals.due,
      stripeStatus: (freshDoc.stripe && freshDoc.stripe.status) || '',
      jobStatus: freshJob.status || '',
      jobCancelled,
    });
  } catch (error) {
    console.error('createStripeRefund error:', error);
    res.status(500).json({ error: error.message || 'Не удалось вернуть средства' });
  }
});

async function handleRefundCreated(refund) {
  const refundId = refund && refund.id;
  if (!refundId) return false;
  const amount = fromCents(refund.amount);
  if (amount <= 0.009) return false;

  let jobId = (refund.metadata && refund.metadata.jobId) || '';
  let documentIndex = (refund.metadata && refund.metadata.documentIndex);
  const paymentIntentId =
    typeof refund.payment_intent === 'string'
      ? refund.payment_intent
      : (refund.payment_intent && refund.payment_intent.id) || '';

  if ((!jobId || documentIndex === undefined || documentIndex === null) && paymentIntentId) {
    try {
      const stripe = getStripe();
      const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
      jobId = jobId || (pi.metadata && pi.metadata.jobId) || '';
      if (documentIndex === undefined || documentIndex === null) {
        documentIndex = pi.metadata && pi.metadata.documentIndex;
      }
    } catch (error) {
      console.warn('handleRefundCreated PI lookup:', error.message);
    }
  }

  // Уже записали из createStripeRefund — не дублируем.
  if ((refund.metadata && refund.metadata.source) === 'createStripeRefund') {
    return false;
  }

  if (!jobId || documentIndex === undefined || documentIndex === null) {
    console.warn('handleRefundCreated: no job metadata on refund', refundId);
    return false;
  }

  const result = await recordDocumentRefund({
    jobId,
    documentIndex: Number(documentIndex),
    amount,
    methodLabel: 'Stripe (refund)',
    stripeRefundId: refundId,
    paymentIntentId,
    cancelCompletedJob: true,
  });
  return result.recorded;
}

async function handlePaymentIntentSucceeded(pi) {
  const metadata = pi.metadata || {};
  const types = Array.isArray(pi.payment_method_types) ? pi.payment_method_types : [];
  if (metadata.kind !== 'tap_to_pay' && !types.includes('card_present')) return;
  if (!metadata.jobId) return;
  const amount = fromCents(pi.amount_received || pi.amount);
  const dueCents = Number(metadata.dueCents || 0);
  const tip =
    dueCents > 0
      ? Math.max(0, amount - fromCents(dueCents))
      : fromCents(metadata.tipCents || 0);
  await recordStripePayment({
    jobId: metadata.jobId,
    documentIndex: metadata.documentIndex,
    amount,
    tip,
    ids: [pi.id].filter(Boolean),
    methodLabel: metadata.kind === 'tap_to_pay' ? 'Stripe (card present)' : 'Stripe',
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
      case 'refund.created':
        await handleRefundCreated(event.data.object);
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
    <h1>${ok ? 'Thank you' : 'Payment cancelled'}</h1>
    <p>${ok
      ? 'Payment received. You can close this page.'
      : 'You can close this page and open the link again when you are ready to pay.'}</p>
  </div>
</body>
</html>`);
});
