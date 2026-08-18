const fs = require('fs');
const path = require('path');
const https = require('https');

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

const sid = process.env.TWILIO_ACCOUNT_SID;
const key = process.env.TWILIO_API_KEY_SID;
const secret = process.env.TWILIO_API_KEY_SECRET;
const callSid = process.argv[2];

if (!callSid) {
  console.error('Usage: node check_call.js <CallSid>');
  process.exit(1);
}

const auth = Buffer.from(`${key}:${secret}`).toString('base64');

function get(pathStr) {
  return new Promise((resolve, reject) => {
    https
      .get(
        { hostname: 'api.twilio.com', path: pathStr, headers: { Authorization: `Basic ${auth}` } },
        (res) => {
          let data = '';
          res.on('data', (chunk) => (data += chunk));
          res.on('end', () => resolve(JSON.parse(data)));
        }
      )
      .on('error', reject);
  });
}

function summarize(call) {
  return {
    sid: call.sid,
    status: call.status,
    direction: call.direction,
    to: call.to,
    from: call.from,
    duration: call.duration,
    parent_call_sid: call.parent_call_sid,
  };
}

(async () => {
  const parent = await get(`/2010-04-01/Accounts/${sid}/Calls/${callSid}.json`);
  console.log('PARENT:', JSON.stringify(summarize(parent), null, 2));

  const childrenResp = await get(
    `/2010-04-01/Accounts/${sid}/Calls.json?ParentCallSid=${callSid}`
  );
  const children = (childrenResp.calls || []).map(summarize);
  console.log('CHILDREN:', JSON.stringify(children, null, 2));
})();
