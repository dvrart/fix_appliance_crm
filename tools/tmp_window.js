const { accessToken } = require('./read_logs');
const PROJECT = 'fix-appliance-crm';

async function main() {
  const from = process.argv[2];
  const to = process.argv[3];
  const token = await accessToken();
  const filter = [
    `timestamp >= "${from}"`,
    `timestamp <= "${to}"`,
    'resource.type="cloud_run_revision"',
    process.argv[4] === 'req' ? 'logName:"requests"' : 'NOT logName:"requests"',
  ].join(' AND ');
  const res = await fetch('https://logging.googleapis.com/v2/entries:list', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ resourceNames: [`projects/${PROJECT}`], filter, orderBy: 'timestamp desc', pageSize: 500 }),
  });
  const body = await res.json();
  if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 400));
  for (const e of (body.entries || []).reverse()) {
    const msg = (e.textPayload || (e.jsonPayload && e.jsonPayload.message) || JSON.stringify(e.jsonPayload || {}))
      .replace(/\s+/g, ' ').trim();
    if (/STARTUP TCP probe|Starting new instance/.test(msg)) continue;
    const svc = (e.resource.labels || {}).service_name || '';
    const h = e.httpRequest || {};
    const req = h.latency ? ` ${h.status} lat=${h.latency} ${String(h.requestUrl || '').slice(-40)}` : '';
    console.log(`${e.timestamp.slice(0, 23)} ${svc.padEnd(16)}${req} ${msg.slice(0, 200)}`);
  }
}
main().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
