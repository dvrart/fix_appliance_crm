const { accessToken } = require('./read_logs');
const PROJECT = 'fix-appliance-crm';

async function main() {
  const sid = process.argv[2];
  const hours = Number(process.argv[3] || 72);
  const token = await accessToken();
  const since = new Date(Date.now() - hours * 3600 * 1000).toISOString();
  const filter = [
    `timestamp >= "${since}"`,
    'resource.type="cloud_run_revision"',
    'NOT logName:"requests"',
    `"${sid}"`,
  ].join(' AND ');
  const res = await fetch('https://logging.googleapis.com/v2/entries:list', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      resourceNames: [`projects/${PROJECT}`],
      filter,
      orderBy: 'timestamp desc',
      pageSize: 500,
    }),
  });
  const body = await res.json();
  if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 400));
  const rows = (body.entries || []).reverse();
  for (const e of rows) {
    const msg = (e.textPayload || (e.jsonPayload && e.jsonPayload.message) || JSON.stringify(e.jsonPayload || {}))
      .replace(/\s+/g, ' ')
      .trim();
    const svc = (e.resource.labels || {}).service_name || '';
    console.log(`${e.timestamp.slice(0, 23)} ${svc.padEnd(16)} ${msg.slice(0, 300)}`);
  }
  console.log(`\nвсего: ${rows.length}`);
}
main().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
