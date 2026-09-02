/**
 * Короткие ссылки.
 * GET /<code>, /p/<code>, /e/<code>, /i/<code> → 302 на длинный URL.
 * POST /shortenLink { url, code?, type? } → { shortUrl, code }.
 *
 * Copy in the app: https://fix-appliance.ca/pay|estimate|invoice/<code>
 * SMS uses the long target (Stripe Checkout, estimateConfirm, Storage).
 * Hostinger .htaccess (above WordPress) 302 → pay./doc. Firebase.
 * Fallback hosts: pay.fix-appliance.ca , doc.fix-appliance.ca , fxapca.
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const crypto = require('crypto');
const { requireAppUser } = require('./auth_guard');

const COMPANY_ID = 'fix_appliance_ca';
const ALPHABET = '23456789abcdefghjkmnpqrstuvwxyz';
const SHOP_BASE = 'https://fix-appliance.ca';
const PATH_SKIP = new Set(['p', 'e', 'i', 'pay', 'estimate', 'invoice']);

function linksRef() {
  return admin
    .firestore()
    .collection('companies')
    .doc(COMPANY_ID)
    .collection('short_links');
}

function setCors(res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
}

function shopBase() {
  const fromEnv = String(process.env.SHOP_LINK_BASE || '').trim().replace(/\/$/, '');
  return fromEnv || SHOP_BASE;
}

function formatShortUrl(code, type) {
  const c = String(code || '').trim();
  const t = String(type || '').toLowerCase();
  const shop = shopBase();
  if (t === 'estimate') return `${shop}/estimate/${c}`;
  if (t === 'pdf' || t === 'invoice' || t === 'receipt') return `${shop}/invoice/${c}`;
  return `${shop}/pay/${c}`;
}

/** Same Google host as estimateConfirm — used if the shop short link is filtered (30007). */
function formatCarrierUrl(code) {
  const c = String(code || '').trim();
  if (!c) return '';
  return `https://us-central1-fix-appliance-crm.cloudfunctions.net/p/${encodeURIComponent(c)}`;
}

function packLink(code, type) {
  return {
    code,
    shortUrl: formatShortUrl(code, type),
    carrierUrl: formatCarrierUrl(code),
  };
}

function randomCode(length = 8) {
  const bytes = crypto.randomBytes(length);
  let out = '';
  for (let i = 0; i < length; i++) {
    out += ALPHABET[bytes[i] % ALPHABET.length];
  }
  return out;
}

function readCode(req) {
  const query = String(req.query.c || req.query.code || '').trim();
  if (query) return query;
  const raw = String(req.path || req.url || '').split('?')[0];
  const parts = raw.split('/').filter(Boolean);
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i] && !PATH_SKIP.has(parts[i])) return parts[i];
  }
  return '';
}

function isHttpUrl(value) {
  try {
    const url = new URL(String(value || ''));
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch (_) {
    return false;
  }
}

async function ensureShortLink({ url, code, type, jobId }) {
  const col = linksRef();
  const existingCode = String(code || '').trim();
  if (existingCode) {
    const snap = await col.doc(existingCode).get();
    if (snap.exists) {
      const linkType = type || (snap.data() || {}).type || '';
      await col.doc(existingCode).set(
        {
          url,
          type: linkType,
          jobId: jobId || snap.data().jobId || '',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      return packLink(existingCode, linkType);
    }
  }

  for (let i = 0; i < 8; i++) {
    const next = randomCode(8);
    const ref = col.doc(next);
    const got = await ref.get();
    if (got.exists) continue;
    await ref.set({
      url,
      type: type || '',
      jobId: jobId || '',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return packLink(next, type);
  }
  throw new Error('Could not allocate short link');
}

async function shortenPayUrl(url, meta = {}) {
  if (!isHttpUrl(url)) return null;
  try {
    return await ensureShortLink({
      url,
      type: meta.type || 'pay',
      jobId: meta.jobId || '',
      code: meta.code || '',
    });
  } catch (error) {
    console.warn('shortenPayUrl:', error.message);
    return null;
  }
}

exports.ensureShortLink = ensureShortLink;
exports.shortenPayUrl = shortenPayUrl;
exports.formatCarrierUrl = formatCarrierUrl;

const httpOpts = { invoker: 'public', cors: true };

exports.shortenLink = functions.https.onRequest(httpOpts, async (req, res) => {
  setCors(res);
  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST only' });
    return;
  }
  if (!(await requireAppUser(req, res))) return;
  const url = String((req.body && req.body.url) || '').trim();
  if (!isHttpUrl(url)) {
    res.status(400).json({ error: 'url must be http(s)' });
    return;
  }
  try {
    const result = await ensureShortLink({
      url,
      code: req.body.code,
      type: req.body.type,
      jobId: req.body.jobId,
    });
    console.log('shortenLink', {
      type: req.body.type || '',
      code: result.code,
      shortUrl: result.shortUrl,
    });
    res.json({ success: true, ...result });
  } catch (error) {
    console.error('shortenLink:', error);
    res.status(500).json({ error: error.message || 'shorten failed' });
  }
});

exports.p = functions.https.onRequest(httpOpts, async (req, res) => {
  if (req.method === 'OPTIONS') {
    setCors(res);
    res.status(204).send('');
    return;
  }
  const code = readCode(req);
  if (!code) {
    res.status(404).send('Not found');
    return;
  }
  try {
    const snap = await linksRef().doc(code).get();
    const target = snap.exists ? String((snap.data() || {}).url || '') : '';
    if (!isHttpUrl(target)) {
      res.status(404).send('Link expired');
      return;
    }
    res.redirect(302, target);
  } catch (error) {
    console.error('short link redirect:', error);
    res.status(500).send('Link error');
  }
});
