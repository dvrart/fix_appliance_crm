#!/usr/bin/env node
/**
 * Был ли звук в звонках мастера — по двухдорожечным записям Twilio.
 *
 * Звонки, где ответил мастер, и исходящие из приложения пишутся в две дорожки
 * (`record-from-answer-dual`): в одной голос клиента, в другой — то, что пришло
 * с телефона мастера. Цифровой ноль на дорожке мастера значит, что телефон не
 * передал ни звука (звуковой канал Twilio не поднялся), а речь на дорожке
 * клиента — что клиент говорил и его голос до Twilio дошёл.
 *
 *   node tools/call_audio_scan.js scan [дней=14] [секунд=90]   сводка по всем звонкам
 *   node tools/call_audio_scan.js inspect <CallSid ноги приложения>   громкость по секундам
 *   node tools/call_audio_scan.js timeline [дней=14]   все звонки мастера, включая неотвеченные
 *
 * Ключи берутся из functions/.env. Записи никуда не сохраняются.
 */
const fs = require('fs');
const path = require('path');

for (const line of fs.readFileSync(path.join(__dirname, '..', 'functions', '.env'), 'utf8').split('\n')) {
  const t = line.trim();
  const i = t.indexOf('=');
  if (!t || t.startsWith('#') || i === -1) continue;
  const k = t.slice(0, i).trim();
  if (!(k in process.env)) process.env[k] = t.slice(i + 1).trim();
}
const ACC = process.env.TWILIO_ACCOUNT_SID;
const AUTH =
  'Basic ' + Buffer.from(`${process.env.TWILIO_API_KEY_SID}:${process.env.TWILIO_API_KEY_SECRET}`).toString('base64');
const API = `https://api.twilio.com/2010-04-01/Accounts/${ACC}`;

const get = async (url) => (await fetch(url, { headers: { Authorization: AUTH } })).json();
const local = (s) => new Date(s).toLocaleString('ru-RU', { timeZone: 'America/Toronto', hour12: false });

async function listCalls(days) {
  const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
  let url = `${API}/Calls.json?PageSize=1000&StartTime%3E=${since}`;
  const out = [];
  while (url) {
    const body = await get(url);
    out.push(...(body.calls || []));
    url = body.next_page_uri ? `https://api.twilio.com${body.next_page_uri}` : null;
  }
  return out;
}

function masterLegs(calls, onlyCompleted) {
  const bySid = new Map(calls.map((c) => [c.sid, c]));
  const legs = [];
  for (const c of calls) {
    if (c.direction === 'outbound-dial' && c.to === 'client:master') {
      if (onlyCompleted && c.status !== 'completed') continue;
      legs.push({ kind: 'IN', sdk: c, recCall: c.parent_call_sid, peer: (bySid.get(c.parent_call_sid) || {}).from || c.from, status: c.status });
    } else if (c.direction === 'inbound' && /^client:/.test(c.from || '')) {
      const child = calls.find((x) => x.parent_call_sid === c.sid) || {};
      if (onlyCompleted && (c.status !== 'completed' || child.status !== 'completed')) continue;
      legs.push({ kind: 'OUT', sdk: c, recCall: c.sid, peer: child.to || '', status: `${c.status}/${child.status || '-'}` });
    }
  }
  return legs.sort((a, b) => new Date(a.sdk.start_time) - new Date(b.sdk.start_time));
}

// Громкость (RMS) каждой дорожки по секундам.
function perSecond(buf) {
  let off = 12;
  let fmt = null;
  let data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    if (id === 'fmt ') fmt = { ch: buf.readUInt16LE(off + 10), rate: buf.readUInt32LE(off + 12) };
    if (id === 'data') { data = buf.subarray(off + 8, Math.min(buf.length, off + 8 + size)); break; }
    off += 8 + size + (size % 2);
  }
  if (!fmt || !data || fmt.ch !== 2) return null;
  const n = Math.floor(data.length / 4);
  const out = [[], []];
  for (let s = 0; s + fmt.rate <= n; s += fmt.rate) {
    const sums = [0, 0];
    for (let i = s; i < s + fmt.rate; i++) {
      for (let c = 0; c < 2; c++) sums[c] += data.readInt16LE(i * 4 + c * 2) ** 2;
    }
    for (let c = 0; c < 2; c++) out[c].push(Math.round(Math.sqrt(sums[c] / fmt.rate)));
  }
  return out;
}

async function recordingSeconds(leg, maxSecs) {
  const body = await get(`${API}/Recordings.json?CallSid=${leg.recCall}`);
  const rec = (body.recordings || []).find((r) => Number(r.channels) === 2);
  if (!rec) return null;
  const headers = { Authorization: AUTH };
  if (maxSecs) headers.Range = `bytes=0-${44 + maxSecs * 32000}`;
  const res = await fetch(`${API}/Recordings/${rec.sid}.wav?RequestedChannels=2`, { headers });
  const tracks = perSecond(Buffer.from(await res.arrayBuffer()));
  if (!tracks) return null;
  // У входящего родитель — клиент, у исходящего — приложение.
  const [master, client] = leg.kind === 'IN' ? [tracks[1], tracks[0]] : [tracks[0], tracks[1]];
  return { rec, master, client };
}

const stats = (arr) => {
  const sorted = [...arr].sort((a, b) => a - b);
  return { max: sorted[sorted.length - 1] || 0, speech: arr.filter((v) => v > 300).length, firstLive: arr.findIndex((v) => v > 2) };
};

async function scan(days, maxSecs) {
  let silent = 0;
  let total = 0;
  for (const leg of masterLegs(await listCalls(days), true)) {
    const r = await recordingSeconds(leg, maxSecs);
    const head = `${local(leg.sdk.start_time).padEnd(20)} ${leg.kind.padEnd(3)} ${String(leg.peer).padEnd(13)}`;
    if (!r) { console.log(`${head} нет двухдорожечной записи`); continue; }
    const m = stats(r.master);
    const c = stats(r.client);
    total += 1;
    let flag = '';
    if (m.max <= 2) { silent += 1; flag = c.max <= 2 ? 'ТИШИНА С ОБЕИХ СТОРОН' : 'С ТЕЛЕФОНА МАСТЕРА НИ ЗВУКА'; }
    else if (c.max <= 2) flag = 'клиент молчит';
    else if (m.firstLive > 3) flag = `звук мастера появился на ${m.firstLive}-й с`;
    console.log(`${head} запись ${String(r.rec.duration).padStart(4)}с | мастер max ${String(m.max).padStart(5)}, речь ${String(m.speech).padStart(3)}с | клиент max ${String(c.max).padStart(5)}, речь ${String(c.speech).padStart(3)}с | ${flag}`);
  }
  console.log(`\nзвонков с записью: ${total}, без звука с телефона мастера: ${silent}`);
}

async function inspect(sdkSid) {
  const call = await get(`${API}/Calls/${sdkSid}.json`);
  const incoming = call.direction === 'outbound-dial';
  const leg = { kind: incoming ? 'IN' : 'OUT', recCall: incoming ? call.parent_call_sid : call.sid };
  console.log(`${leg.kind} ${local(call.start_time)} ${call.from} → ${call.to}, нога приложения ${call.duration}с`);
  const r = await recordingSeconds(leg, 0);
  if (!r) { console.log('нет двухдорожечной записи'); return; }
  const bar = (v) => `${String(v).padStart(6)} ${'#'.repeat(Math.min(30, Math.round(v / 150)))}`.padEnd(38);
  console.log(' сек  мастер (телефон)                       клиент');
  r.master.forEach((v, i) => console.log(`${String(i).padStart(4)} ${bar(v)} ${bar(r.client[i])}`));
}

async function timeline(days) {
  for (const leg of masterLegs(await listCalls(days), false)) {
    console.log(`${local(leg.sdk.start_time).padEnd(20)} ${leg.kind.padEnd(3)} ${String(leg.peer).padEnd(13)} ${String(leg.status).padEnd(22)} нога приложения ${leg.sdk.duration || 0}с ${leg.sdk.sid}`);
  }
}

const [cmd, a, b] = process.argv.slice(2);
const run = { scan: () => scan(Number(a || 14), Number(b || 90)), inspect: () => inspect(a), timeline: () => timeline(Number(a || 14)) }[cmd];
if (!run) console.log('node tools/call_audio_scan.js scan [дней] [секунд] | inspect <CallSid> | timeline [дней]');
else run().catch((e) => { console.error('сбой: ' + e.message); process.exitCode = 1; });
