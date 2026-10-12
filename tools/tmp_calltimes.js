const fs = require('fs');
const path = require('path');
const https = require('https');

const envPath = path.join(__dirname, '..', 'functions', '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i === -1) continue;
    const k = t.slice(0, i).trim();
    if (!(k in process.env)) process.env[k] = t.slice(i + 1).trim();
  }
}
const sid = process.env.TWILIO_ACCOUNT_SID;
const auth = Buffer.from(`${process.env.TWILIO_API_KEY_SID}:${process.env.TWILIO_API_KEY_SECRET}`).toString('base64');

function get(p) {
  return new Promise((resolve, reject) => {
    https.get({ hostname: 'api.twilio.com', path: p, headers: { Authorization: `Basic ${auth}` } }, (res) => {
      let d = '';
      res.on('data', (c) => (d += c));
      res.on('end', () => resolve(JSON.parse(d)));
    }).on('error', reject);
  });
}
const sum = (c) => ({
  sid: c.sid, status: c.status, dir: c.direction, to: c.to, from: c.from,
  dur: c.duration, created: c.date_created, start: c.start_time, end: c.end_time,
});

(async () => {
  for (const callSid of process.argv.slice(2)) {
    const parent = await get(`/2010-04-01/Accounts/${sid}/Calls/${callSid}.json`);
    console.log('PARENT', JSON.stringify(sum(parent)));
    const kids = await get(`/2010-04-01/Accounts/${sid}/Calls.json?ParentCallSid=${callSid}`);
    for (const k of kids.calls || []) console.log('  CHILD', JSON.stringify(sum(k)));
    const ev = await get(`/2010-04-01/Accounts/${sid}/Events.json?PageSize=50&EdgeLocation=&CallSid=${callSid}`);
    if (ev.events) {
      for (const e of ev.events) console.log('  EVENT', JSON.stringify(e).slice(0, 300));
    }
    console.log('');
  }
})();
