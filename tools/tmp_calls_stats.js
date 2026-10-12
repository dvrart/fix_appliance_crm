const { accessToken } = require('./read_logs');
const PROJECT = 'fix-appliance-crm';
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const COMPANY = 'companies/fix_appliance_ca';

function plain(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(plain);
  if ('mapValue' in v) return fields(v.mapValue.fields);
  return null;
}
const fields = (raw) => Object.fromEntries(Object.entries(raw || {}).map(([k, v]) => [k, plain(v)]));

async function main() {
  const token = await accessToken();
  const rows = [];
  let pageToken = '';
  do {
    const res = await fetch(`${BASE}/${COMPANY}/calls?pageSize=300${pageToken ? `&pageToken=${pageToken}` : ''}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const body = await res.json();
    if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 300));
    for (const d of body.documents || []) rows.push(fields(d.fields));
    pageToken = body.nextPageToken || '';
  } while (pageToken);

  const inbound = rows.filter((r) => r.direction === 'inbound');
  inbound.sort((a, b) => String(a.startTime).localeCompare(String(b.startTime)));
  let missed = 0;
  for (const r of inbound.slice(-60)) {
    const dead = r.twilioStatus === 'no-answer' || r.status === 'no-answer';
    if (dead) missed += 1;
    console.log(
      `${String(r.startTime).replace('T', ' ').slice(0, 19)} ${String(r.fromNumber).padEnd(14)} ` +
        `status=${String(r.status).padEnd(11)} dur=${String(r.durationSeconds ?? '-').padEnd(4)} ` +
        `ai=${String(r.aiStatus).padEnd(6)} answeredBy=${String(r.answeredBy || '-').padEnd(6)} job=${r.createdJobId ? 'yes' : '-'}`
    );
  }
  console.log(`\nвходящих всего: ${inbound.length}, из показанных без ответа: ${missed}`);
  console.log(`без ответа за всё время: ${inbound.filter((r) => r.status === 'no-answer' || r.twilioStatus === 'no-answer').length}`);
}
main().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
