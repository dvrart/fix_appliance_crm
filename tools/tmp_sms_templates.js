const { accessToken } = require('./read_logs');

const PROJECT = 'fix-appliance-crm';
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const COMPANY = 'companies/fix_appliance_ca';

function plain(value) {
  if (!value) return null;
  if ('stringValue' in value) return value.stringValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('nullValue' in value) return null;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(plain);
  if ('mapValue' in value) return fields(value.mapValue.fields);
  return null;
}
function fields(raw) {
  return Object.fromEntries(Object.entries(raw || {}).map(([k, v]) => [k, plain(v)]));
}

async function main() {
  const token = await accessToken();
  for (const doc of ['sms_templates', 'config']) {
    const res = await fetch(`${BASE}/${COMPANY}/settings/${doc}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const body = await res.json();
    console.log('=====', doc, res.status);
    if (!body.fields) {
      console.log('  (документа нет — работают значения по умолчанию)');
      continue;
    }
    const data = fields(body.fields);
    for (const [key, value] of Object.entries(data)) {
      if (doc === 'config' && !/sms|review|booking|manual|approval/i.test(key)) continue;
      console.log(`--- ${key}:\n${typeof value === 'string' ? value : JSON.stringify(value)}`);
    }
  }
}

main().catch((e) => {
  console.error('сбой: ' + e.message);
  process.exitCode = 1;
});
