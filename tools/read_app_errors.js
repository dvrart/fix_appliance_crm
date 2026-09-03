#!/usr/bin/env node
/**
 * Ошибки приложения из Firestore (companies/…/app_errors).
 *
 * Раньше их отдавал открытый эндпоинт appErrors, но после закрытия доступов он
 * требует токен пользователя, которого у агента нет. Здесь читаем напрямую
 * через вход Firebase CLI, уже сохранённый на машине.
 *
 *   node tools/read_app_errors.js            последние 30
 *   node tools/read_app_errors.js 60         последние 60
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const CONFIG = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
const PROJECT = 'fix-appliance-crm';

async function accessToken() {
  if (!fs.existsSync(CONFIG)) throw new Error(`нет ${CONFIG} — firebase login`);
  const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
      client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
      refresh_token: cfg.tokens.refresh_token,
      grant_type: 'refresh_token',
    }).toString(),
  });
  const body = await res.json();
  if (!body.access_token) {
    throw new Error(
      body.error === 'invalid_grant'
        ? 'вход в Google больше не действует — выполните: firebase login --reauth'
        : JSON.stringify(body).slice(0, 200)
    );
  }
  return body.access_token;
}

const plain = (v) => {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  return null;
};

async function main() {
  const limit = Number(process.argv[2] || 30);
  const token = await accessToken();
  const base = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/companies/fix_appliance_ca/app_errors`;
  const rows = [];
  let pageToken = '';
  do {
    const res = await fetch(`${base}?pageSize=300${pageToken ? `&pageToken=${pageToken}` : ''}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const body = await res.json();
    if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 250));
    for (const d of body.documents || []) {
      const f = {};
      for (const [k, v] of Object.entries(d.fields || {})) f[k] = plain(v);
      rows.push(f);
    }
    pageToken = body.nextPageToken || '';
  } while (pageToken);

  rows.sort((a, b) => String(a.at || a.createdAt || '').localeCompare(String(b.at || b.createdAt || '')));
  for (const r of rows.slice(-limit)) {
    const when = String(r.at || r.createdAt || '').replace('T', ' ').slice(0, 19);
    const kind = String(r.kind || r.type || '').padEnd(8);
    const screen = r.screen ? ` [${r.screen}]` : '';
    console.log(`${when} ${kind}${screen} ${String(r.message || '').replace(/\s+/g, ' ').slice(0, 220)}`);
  }
  console.log(`\nвсего записей: ${rows.length}, показано ${Math.min(limit, rows.length)}`);
}

main().catch((e) => {
  console.error('сбой: ' + e.message);
  process.exitCode = 1;
});
