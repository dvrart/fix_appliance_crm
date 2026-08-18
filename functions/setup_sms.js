/**
 * Настраивает Twilio Messaging webhook и прогоняет недавние входящие SMS
 * через incomingSms (ИИ + заявка). Секреты читаются только из functions/.env.
 */
const fs = require('fs');
const path = require('path');
const https = require('https');
const querystring = require('querystring');

const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx === -1) continue;
    const k = trimmed.slice(0, idx).trim();
    const v = trimmed.slice(idx + 1).trim();
    if (!(k in process.env)) process.env[k] = v;
  }
}

const ACCOUNT_SID = process.env.TWILIO_ACCOUNT_SID;
const AUTH_USER = process.env.TWILIO_API_KEY_SID || process.env.TWILIO_ACCOUNT_SID;
const AUTH_SECRET = process.env.TWILIO_API_KEY_SECRET || process.env.TWILIO_AUTH_TOKEN;
const PHONE = process.env.TWILIO_PHONE_NUMBER;
const WEBHOOK = 'https://us-central1-fix-appliance-crm.cloudfunctions.net/incomingSms';

if (!ACCOUNT_SID || !AUTH_USER || !AUTH_SECRET) {
  console.error('Нет Twilio credentials в functions/.env');
  process.exit(1);
}

const auth = Buffer.from(`${AUTH_USER}:${AUTH_SECRET}`).toString('base64');

function request(method, urlPath, form) {
  const body = form ? querystring.stringify(form) : '';
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'api.twilio.com',
        path: urlPath,
        method,
        headers: {
          Authorization: `Basic ${auth}`,
          ...(body
            ? { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }
            : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, json: data ? JSON.parse(data) : {} });
          } catch (error) {
            reject(new Error(`Twilio ${res.statusCode}: ${data.slice(0, 200)}`));
          }
        });
      }
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function postWebhook(form) {
  const body = querystring.stringify(form);
  return new Promise((resolve, reject) => {
    const url = new URL(WEBHOOK);
    const req = https.request(
      {
        hostname: url.hostname,
        path: url.pathname,
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => resolve({ status: res.statusCode, body: data }));
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

(async () => {
  const list = await request(
    'GET',
    `/2010-04-01/Accounts/${ACCOUNT_SID}/IncomingPhoneNumbers.json?PageSize=20`
  );
  const numbers = list.json.incoming_phone_numbers || [];
  const match =
    numbers.find((n) => n.phone_number === PHONE) ||
    numbers[0];
  if (!match) {
    console.error('Twilio-номер не найден');
    process.exit(1);
  }

  console.log(`Номер ${match.phone_number}`);
  console.log(`Текущий SMS webhook: ${match.sms_url || '(пусто)'}`);

  const updated = await request(
    'POST',
    `/2010-04-01/Accounts/${ACCOUNT_SID}/IncomingPhoneNumbers/${match.sid}.json`,
    {
      SmsUrl: WEBHOOK,
      SmsMethod: 'POST',
    }
  );
  if (updated.status >= 400) {
    console.error('Не удалось записать webhook', updated.status);
    process.exit(1);
  }
  console.log(`Webhook SMS: ${updated.json.sms_url}`);

  const messages = await request(
    'GET',
    `/2010-04-01/Accounts/${ACCOUNT_SID}/Messages.json?PageSize=20`
  );
  const inbound = (messages.json.messages || []).filter((m) => m.direction === 'inbound');
  console.log(`Входящих SMS в Twilio: ${inbound.length}`);

  for (const message of inbound) {
    const mediaList = await request(
      'GET',
      `/2010-04-01/Accounts/${ACCOUNT_SID}/Messages/${message.sid}/Media.json`
    );
    const media = (mediaList.json.media_list || []).filter((item) => item.uri);
    const form = {
      MessageSid: message.sid,
      From: message.from,
      To: message.to,
      Body: message.body || '',
      NumMedia: String(media.length),
    };
    media.forEach((item, i) => {
      const uri = item.uri.replace(/\.json$/, '');
      form[`MediaUrl${i}`] = `https://api.twilio.com${uri}`;
      form[`MediaContentType${i}`] = item.content_type || 'image/jpeg';
    });
    const result = await postWebhook(form);
    console.log(
      `${message.from} ${message.date_sent || ''} media=${media.length} -> HTTP ${result.status}`
    );
  }
})().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
