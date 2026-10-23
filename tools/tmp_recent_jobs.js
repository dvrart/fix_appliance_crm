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
  const res = await fetch(`${BASE}/${COMPANY}:runQuery`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: 'jobs' }],
        orderBy: [{ field: { fieldPath: 'createdAt' }, direction: 'DESCENDING' }],
        limit: 12,
      },
    }),
  });
  const body = await res.json();
  for (const row of body) {
    if (!row.document) continue;
    const d = fields(row.document.fields);
    const id = row.document.name.split('/').pop();
    console.log('=====', id, d.createdAt);
    console.log(
      JSON.stringify(
        {
          clientName: d.clientName,
          clientPhone: d.clientPhone,
          status: d.status,
          source: d.source,
          sourceCallId: d.sourceCallId,
          sourceEmailId: d.sourceEmailId,
          sourceEmailFrom: d.sourceEmailFrom,
          sourceEmailSubject: d.sourceEmailSubject,
          sourceEmailPreview: String(d.sourceEmailPreview || '').slice(0, 80),
          needsReview: d.needsReview,
          createdByAi: d.createdByAi,
          visits: (d.visits || []).map((v) => ({
            id: v.id,
            startAt: v.startAt,
            status: v.status,
            confirm: v.confirm,
            manualConfirm: v.manualConfirm,
            clientConfirm: v.clientConfirm,
            smsBooking: v.smsBooking,
          })),
        },
        null,
        1
      )
    );
  }
}

main().catch((e) => {
  console.error('сбой: ' + e.message);
  process.exitCode = 1;
});
