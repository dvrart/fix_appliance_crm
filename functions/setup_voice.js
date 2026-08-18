/**
 * Настраивает Voice URL: номер → incomingCall, TwiML App → outgoingCall.
 * Секреты только из functions/.env, в лог не печатаются.
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
const APP_SID = process.env.TWILIO_TWIML_APP_SID;
const BASE = 'https://us-central1-fix-appliance-crm.cloudfunctions.net';
const INCOMING = `${BASE}/incomingCall`;
const OUTGOING = `${BASE}/outgoingCall`;
const STATUS = `${BASE}/callStatusCallback`;

if (!ACCOUNT_SID || !AUTH_USER || !AUTH_SECRET || !APP_SID) {
  console.error('Нет Twilio credentials / TWILIO_TWIML_APP_SID в functions/.env');
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
            ? {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Content-Length': Buffer.byteLength(body),
              }
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

async function main() {
  const appPath = `/2010-04-01/Accounts/${ACCOUNT_SID}/Applications/${APP_SID}.json`;
  const before = await request('GET', appPath);
  if (before.status !== 200) {
    console.error('TwiML App не найден:', before.status, before.json.message || '');
    process.exit(1);
  }
  console.log('TwiML App VoiceUrl было:', before.json.voice_url || '(пусто)');

  const updated = await request('POST', appPath, {
    VoiceUrl: OUTGOING,
    VoiceMethod: 'POST',
    StatusCallback: STATUS,
    StatusCallbackMethod: 'POST',
  });
  if (updated.status !== 200) {
    console.error('Не удалось обновить TwiML App:', updated.status, updated.json.message || '');
    process.exit(1);
  }
  console.log('TwiML App VoiceUrl стало:', updated.json.voice_url);

  if (PHONE) {
    const list = await request(
      'GET',
      `/2010-04-01/Accounts/${ACCOUNT_SID}/IncomingPhoneNumbers.json?PhoneNumber=${encodeURIComponent(PHONE)}`
    );
    const numbers = list.json.incoming_phone_numbers || [];
    if (!numbers.length) {
      console.log('Номер в аккаунте не найден, Voice URL номера не трогаем');
      return;
    }
    const sid = numbers[0].sid;
    console.log('Номер VoiceUrl было:', numbers[0].voice_url || '(пусто)');
    const phoneUpdated = await request(
      'POST',
      `/2010-04-01/Accounts/${ACCOUNT_SID}/IncomingPhoneNumbers/${sid}.json`,
      {
        VoiceUrl: INCOMING,
        VoiceMethod: 'POST',
        StatusCallback: STATUS,
        StatusCallbackMethod: 'POST',
      }
    );
    if (phoneUpdated.status !== 200) {
      console.error('Не удалось обновить номер:', phoneUpdated.status, phoneUpdated.json.message || '');
      process.exit(1);
    }
    console.log('Номер VoiceUrl стало:', phoneUpdated.json.voice_url);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
