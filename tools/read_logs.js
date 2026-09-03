#!/usr/bin/env node
/**
 * Чтение журнала функций через Cloud Logging API.
 *
 * Зачем: `firebase functions:log` на этом проекте отдаёт устаревшие срезы —
 * свежих записей в нём просто нет, и отладка звонков превращается в угадывание.
 * Здесь запрос идёт напрямую в Cloud Logging, порядок и время верные.
 *
 * Вход берётся тот, что уже сохранил Firebase CLI на этой машине
 * (~/.config/configstore/firebase-tools.json). Ничего никуда не отправляется,
 * только чтение. Если CLI разлогинен — сначала `firebase login --reauth`.
 *
 * Примеры:
 *   node tools/read_logs.js                       последние 30 минут, голосовые функции
 *   node tools/read_logs.js 180                   последние 3 часа
 *   node tools/read_logs.js 60 aivoicerelay       только релей
 *   node tools/read_logs.js 60 all                все функции
 *   node tools/read_logs.js 60 aivoicerelay req   журнал запросов (код, длительность)
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const CONFIG = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
// Публичные значения клиента самого firebase-tools.
const CLIENT_ID = '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com';
const CLIENT_SECRET = 'j9iVZfS8kkCEFUPaAeJV0sAi';
const PROJECT = 'fix-appliance-crm';

const VOICE = ['aivoicerelay', 'aivoiceturn', 'incomingcall', 'dialaction', 'airelaycomplete'];

async function accessToken() {
  if (!fs.existsSync(CONFIG)) {
    throw new Error(`нет ${CONFIG} — выполните firebase login`);
  }
  const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  const refresh = cfg.tokens && cfg.tokens.refresh_token;
  if (!refresh) throw new Error('в конфиге нет refresh_token — firebase login --reauth');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      refresh_token: refresh,
      grant_type: 'refresh_token',
    }).toString(),
  });
  const body = await res.json();
  if (!body.access_token) {
    throw new Error(`обмен токена не удался: ${JSON.stringify(body).slice(0, 200)}`);
  }
  return body.access_token;
}

function serviceFilter(which) {
  if (which === 'all') return '';
  const list = which && which !== 'voice' ? [which] : VOICE;
  return `resource.labels.service_name=(${list.map((s) => `"${s}"`).join(' OR ')})`;
}

async function main() {
  const minutes = Number(process.argv[2] || 30);
  const which = String(process.argv[3] || 'voice');
  const mode = String(process.argv[4] || 'app');

  const token = await accessToken();
  const since = new Date(Date.now() - minutes * 60 * 1000).toISOString();
  const filter = [
    `timestamp >= "${since}"`,
    'resource.type="cloud_run_revision"',
    serviceFilter(which),
    mode === 'req' ? 'logName:"requests"' : 'NOT logName:"requests"',
  ]
    .filter(Boolean)
    .join(' AND ');

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
  if (mode === 'req') {
    console.log('время     код  длительность   агент');
    for (const e of rows) {
      const h = e.httpRequest || {};
      console.log(
        `${e.timestamp.slice(11, 19)}  ${String(h.status || '?').padEnd(4)} ` +
          `${String(h.latency || '?').padEnd(14)} ${String(h.userAgent || '').slice(0, 40)}`
      );
    }
  } else {
    for (const e of rows) {
      const msg = (e.textPayload || (e.jsonPayload && e.jsonPayload.message) || '')
        .replace(/\s+/g, ' ')
        .trim();
      if (!msg || msg.startsWith('{"@type"')) continue;
      if (/STARTUP TCP probe|Starting new instance/.test(msg)) continue;
      const svc = (e.resource.labels || {}).service_name || '';
      console.log(`${e.timestamp.slice(11, 23)} ${svc.padEnd(15)} ${msg.slice(0, 200)}`);
    }
  }
  console.log(`\nвсего записей: ${rows.length} (за ${minutes} мин)`);
}

main().catch((e) => {
  console.error('сбой: ' + e.message);
  process.exitCode = 1;
});
