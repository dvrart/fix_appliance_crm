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
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(plain);
  if ('mapValue' in value) return fields(value.mapValue.fields);
  return null;
}
function fields(raw) {
  return Object.fromEntries(Object.entries(raw || {}).map(([k, v]) => [k, plain(v)]));
}

async function main() {
  const token = await accessToken();
  const numbers = process.argv.slice(2);
  for (const num of numbers) {
    const res = await fetch(`${BASE}/${COMPANY}:runQuery`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: 'calls' }],
          where: {
            fieldFilter: { field: { fieldPath: 'fromNumber' }, op: 'EQUAL', value: { stringValue: num } },
          },
          limit: 20,
        },
      }),
    });
    const body = await res.json();
    console.log('=====', num);
    if (body.error || (body[0] && body[0].error)) {
      console.log(JSON.stringify(body).slice(0, 600));
      continue;
    }
    const docs = (body || []).filter((r) => r.document);
    if (!docs.length) console.log('(нет документов с fromNumber)');
    for (const r of docs) {
      const f = fields(r.document.fields);
      console.log(r.document.name.split('/').pop(), JSON.stringify(f).slice(0, 2500));
      console.log('---');
    }
  }
}
main().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
