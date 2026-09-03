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
// Смена токена без простоя: пока Twilio ещё подписывает старым, а в .env уже
// лежит новый, принимаем оба. После промоута строку TWILIO_AUTH_TOKEN_PREV
// из .env убрать.
const TWILIO_AUTH_TOKENS = [
  TWILIO_AUTH_TOKEN,
  process.env.TWILIO_AUTH_TOKEN_PREV,
]
  .map((t) => String(t || '').trim())
  .filter(Boolean);

// Gen2-функции живут на Cloud Run, поэтому host в запросе приходит как
// *.run.app, а Twilio подписал тот адрес, что стоит у него в консоли
// (us-central1-<project>.cloudfunctions.net/<name>). Сверяем подпись по
// списку кандидатов, иначе валидные звонки получают 403.
const PROJECT_ID =
  process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
const REGION = process.env.FUNCTION_REGION || 'us-central1';
const FUNCTION_NAME = process.env.FUNCTION_TARGET || process.env.K_SERVICE || '';

// TWILIO_SIGNATURE_MODE=log — только писать в лог, запрос пропускать.
// Нужен на первый деплой: видно, какой адрес подписал Twilio, и телефон живой.
const SIGNATURE_LOG_ONLY =
  String(process.env.TWILIO_SIGNATURE_MODE || '').toLowerCase() === 'log';

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

function pathWithQuery(req) {
  const raw = String(req.originalUrl || req.url || '/');
  return raw.startsWith('/') ? raw : `/${raw}`;
}

/** Адреса, любой из которых Twilio мог подписать. */
function candidateUrls(req) {
  const pq = pathWithQuery(req);
  const query = pq.includes('?') ? pq.slice(pq.indexOf('?')) : '';
  const proto = String(req.headers['x-forwarded-proto'] || 'https').split(',')[0];
  const host = String(
    req.headers['x-forwarded-host'] || req.headers.host || ''
  ).split(',')[0].trim();

  const urls = [];
  if (host) urls.push(`${proto}://${host}${pq}`);
  if (FUNCTION_NAME) {
    // Канонический адрес функции: именно он стоит в консоли Twilio.
    const base = `https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}`;
    urls.push(`${base}${query}`);
    // Gen2 иногда отдаёт путь вместе с именем функции, иногда без него.
    if (pq !== '/' && !pq.startsWith(`/${FUNCTION_NAME}`)) urls.push(`${base}${pq}`);
  }
  return [...new Set(urls.filter(Boolean))];
}

/** true — подпись валидна (или проверка невозможна и мягко пропущена). */
function twilioSignatureOk(req) {
  if (!TWILIO_AUTH_TOKENS.length) {
    console.warn('auth_guard: TWILIO_AUTH_TOKEN not set, skipping signature check');
    return true;
  }
  const signature = req.headers['x-twilio-signature'];
  if (!signature) {
    console.warn('auth_guard: no X-Twilio-Signature header', req.path);
    return false;
  }
  const params = req.method === 'POST' ? req.body || {} : {};
  const urls = candidateUrls(req);
  const ok = urls.some((url) =>
    TWILIO_AUTH_TOKENS.some((token) =>
      twilio.validateRequest(token, signature, url, params)
    )
  );
  if (!ok) {
    // Печатаем кандидатов: по логу сразу видно, какой адрес нужно добавить.
    console.warn(
      `auth_guard: Twilio signature mismatch fn=${FUNCTION_NAME || '?'} tried=${urls.join(' | ')}`
    );
  }
  return ok;
}

/** Проверяет подпись Twilio; при провале отвечает 403 и возвращает false. */
function requireTwilioSignature(req, res) {
  if (twilioSignatureOk(req)) return true;
  if (SIGNATURE_LOG_ONLY) {
    console.warn('auth_guard: TWILIO_SIGNATURE_MODE=log, request allowed', req.path);
    return true;
  }
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
