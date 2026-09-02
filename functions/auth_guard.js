/**
 * Защита HTTP-функций.
 *
 * Два типа проверок:
 *  - requireAppUser: эндпоинты, которые дергает приложение — нужен Firebase
 *    ID-токен (заголовок Authorization: Bearer <token> или ?auth=<token>).
 *  - requireTwilioSignature: webhooks Twilio — проверка X-Twilio-Signature
 *    по TWILIO_AUTH_TOKEN. Если токен не задан в .env, запрос пропускается
 *    с предупреждением в логах (чтобы не уронить прод до настройки).
 */

const admin = require('firebase-admin');
const twilio = require('twilio');

const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;

function bearerToken(req) {
  const header = String(req.headers.authorization || '');
  if (header.startsWith('Bearer ')) return header.slice(7).trim();
  const q = req.query && (req.query.auth || req.query.idToken);
  if (q) return String(Array.isArray(q) ? q[0] : q).trim();
  return '';
}

async function verifyAppUser(req) {
  const token = bearerToken(req);
  if (!token) return null;
  try {
    return await admin.auth().verifyIdToken(token);
  } catch (error) {
    console.warn('auth_guard verifyIdToken:', error.message);
    return null;
  }
}

/** Возвращает decoded-токен или отвечает 401 и возвращает null. */
async function requireAppUser(req, res) {
  const user = await verifyAppUser(req);
  if (!user) {
    res.status(401).json({ error: 'Unauthorized: Firebase ID token required' });
    return null;
  }
  return user;
}

function requestUrl(req) {
  const proto = String(req.headers['x-forwarded-proto'] || 'https').split(',')[0];
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '');
  return `${proto}://${host}${req.originalUrl}`;
}

/** true — подпись валидна (или проверка невозможна и мягко пропущена). */
function twilioSignatureOk(req) {
  if (!TWILIO_AUTH_TOKEN) {
    console.warn('auth_guard: TWILIO_AUTH_TOKEN not set, skipping signature check');
    return true;
  }
  const signature = req.headers['x-twilio-signature'];
  if (!signature) return false;
  const url = requestUrl(req);
  const params = req.method === 'POST' ? req.body || {} : {};
  return twilio.validateRequest(TWILIO_AUTH_TOKEN, signature, url, params);
}

/** Проверяет подпись Twilio; при провале отвечает 403 и возвращает false. */
function requireTwilioSignature(req, res) {
  if (twilioSignatureOk(req)) return true;
  console.warn('auth_guard: bad Twilio signature', req.path);
  res.status(403).send('Forbidden: invalid Twilio signature');
  return false;
}

module.exports = {
  requireAppUser,
  verifyAppUser,
  requireTwilioSignature,
  twilioSignatureOk,
};
