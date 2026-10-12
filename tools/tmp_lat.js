const { accessToken } = require('./read_logs');
const PROJECT = 'fix-appliance-crm';

async function main() {
  const svc = process.argv[2] || 'incomingcall';
  const days = Number(process.argv[3] || 7);
  const token = await accessToken();
  const since = new Date(Date.now() - days * 86400000).toISOString();
  const filter = [
    `timestamp >= "${since}"`,
    'resource.type="cloud_run_revision"',
    `resource.labels.service_name="${svc}"`,
    'logName:"requests"',
  ].join(' AND ');
  const res = await fetch('https://logging.googleapis.com/v2/entries:list', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ resourceNames: [`projects/${PROJECT}`], filter, orderBy: 'timestamp desc', pageSize: 300 }),
  });
  const body = await res.json();
  if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 300));
  const lats = [];
  for (const e of (body.entries || []).reverse()) {
    const h = e.httpRequest || {};
    const lat = parseFloat(String(h.latency || '0').replace('s', ''));
    lats.push(lat);
    console.log(`${e.timestamp.slice(0, 19)} ${String(h.status).padEnd(4)} ${lat.toFixed(2)}s`);
  }
  lats.sort((a, b) => a - b);
  const q = (p) => lats.length ? lats[Math.min(lats.length - 1, Math.floor(lats.length * p))].toFixed(2) : '-';
  console.log(`\n${svc}: запросов ${lats.length}, медиана ${q(0.5)}s, p90 ${q(0.9)}s, max ${q(0.999)}s, >3s: ${lats.filter((l) => l > 3).length}`);
}
main().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
