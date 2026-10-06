#!/usr/bin/env node
/**
 * Прямой зонд Gemini Live: проверить секретаря без настоящих звонков.
 *
 * Говорит с Gemini теми же setup и промптом, что и боевой релей
 * (voice_relay.buildSetup / liveSystemPrompt, инструкции — DEFAULT_VOICE_INSTRUCTIONS
 * из index.js), звонящего изображает синтез речи Windows (Microsoft Zira) через
 * μ-law 8 кГц, как в Twilio. Печатает события по времени: что услышала модель
 * (in), что сказала (out), когда пошёл звук, перебивания, конец реплики.
 *
 * Ключ берётся из functions/.env и никуда не печатается:
 *   node --env-file=functions/.env tools/live_probe.js models   какие Live-модели поднимаются и как быстро
 *   node --env-file=functions/.env tools/live_probe.js vad      пауза посреди фразы: перебивает ли (VADS=160/200/HIGH,500/300/HIGH)
 *   node --env-file=functions/.env tools/live_probe.js resume   после обрыва: молчит, пока звонящий не заговорит
 *   node --env-file=functions/.env tools/live_probe.js dialog   имя, «вы человек?», фреон (DIALOG=name,human,freon)
 *   node --env-file=functions/.env tools/live_probe.js ladder   что она говорит на «тишину на линии»
 *
 * Замеры 02.10.2026 — в .cursor/rules/agent-context.mdc. Каждый прогон — это
 * несколько коротких сессий Gemini, то есть реальные (небольшие) деньги.
 */
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const { setTimeout: delay } = require('node:timers/promises');

const FN = path.join(__dirname, '..', 'functions');
const { WebSocket } = createRequire(path.join(FN, 'package.json'))('ws');
const codec = require(path.join(FN, 'audio_codec'));
const voiceRelay = require(path.join(FN, 'voice_relay'));
const voiceFacts = require(path.join(FN, 'voice_facts'));

const KEY = process.env.GEMINI_API_KEY;
const URL =
  'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta' +
  `.GenerativeService.BidiGenerateContent?key=${encodeURIComponent(KEY || '')}`;
const PRIMARY = voiceRelay._internals.liveModels()[0];

/** Фразы звонящего: синтез Windows, PCM16 8 кГц, тишина по краям срезана. */
function synth(texts) {
  if (process.platform !== 'win32') throw new Error('синтез речи есть только в Windows');
  const list = texts.map((t) => `'${t.replace(/'/g, "''")}'`).join(',');
  const command = `$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Speech;
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.SelectVoice('Microsoft Zira Desktop'); $s.Rate = 1;
$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(8000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);
$out = foreach ($t in @(${list})) { $m = New-Object System.IO.MemoryStream; $s.SetOutputToAudioStream($m, $f); $s.Speak($t); $s.SetOutputToNull(); [Convert]::ToBase64String($m.ToArray()); $m.Dispose() };
$s.Dispose(); ConvertTo-Json -InputObject @($out) -Compress`;
  const json = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], {
    encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  });
  return JSON.parse(json.replace(/^\uFEFF/, '')).map((b64) => {
    const raw = Buffer.from(b64, 'base64');
    const pcm = new Int16Array(raw.length / 2);
    for (let i = 0; i < pcm.length; i++) pcm[i] = raw.readInt16LE(i * 2);
    let a = 0;
    let b = pcm.length - 1;
    while (a < b && Math.abs(pcm[a]) < 200) a++;
    while (b > a && Math.abs(pcm[b]) < 200) b--;
    return pcm.subarray(a, b + 1);
  });
}

const silence = (ms) => new Int16Array(Math.round(ms * 8));

/** Боевые инструкции секретаря прямо из index.js (сам index.js не грузим — там Firebase). */
function realInstructions() {
  const src = fs.readFileSync(path.join(FN, 'index.js'), 'utf8');
  const m = src.match(/const DEFAULT_VOICE_INSTRUCTIONS = `([\s\S]*?)`;\r?\n/);
  if (!m) throw new Error('DEFAULT_VOICE_INSTRUCTIONS не найден в index.js');
  // eslint-disable-next-line no-new-func
  return new Function('voiceFacts', `return \`${m[1]}\`;`)(voiceFacts);
}

function profile(real) {
  return {
    instructions: real ? realInstructions() : voiceFacts.VOICE_LIVE_FLOW,
    workHours: '7 a.m. to 9 p.m.',
    workDaysLabel: 'Monday–Friday',
    serviceArea: 'Brantford, Paris, Simcoe, Tillsonburg and the villages around them.',
  };
}

async function session(model, { vad, tools = false, real = false, caller = {} } = {}) {
  const payload = voiceRelay.buildSetup(
    model,
    voiceRelay.liveSystemPrompt(profile(real), { fromNumber: '+15195550100', ...caller }),
    tools
  );
  if (vad) Object.assign(payload.setup.realtimeInputConfig.automaticActivityDetection, vad);
  const ws = new WebSocket(URL, { perMessageDeflate: false, handshakeTimeout: 15000 });
  const s = { ws, events: [], t0: 0, closed: null, ready: false, setupMs: null, turnDone: 0 };
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    const at = Math.round(performance.now() - s.t0);
    if (m.setupComplete) {
      s.ready = true;
      s.setupMs = at;
    }
    if (m.error) s.events.push({ at, k: 'error', v: m.error.message });
    const c = m.serverContent || {};
    if (c.inputTranscription && c.inputTranscription.text) s.events.push({ at, k: 'in', v: c.inputTranscription.text });
    if (c.outputTranscription && c.outputTranscription.text) s.events.push({ at, k: 'out', v: c.outputTranscription.text });
    if (c.interrupted) s.events.push({ at, k: 'INTERRUPTED' });
    for (const p of (c.modelTurn && c.modelTurn.parts) || []) {
      if (!p.inlineData || !p.inlineData.data) continue;
      if (!s.inAudio) s.events.push({ at, k: 'audio' });
      s.inAudio = true;
    }
    if (c.turnComplete) {
      s.turnDone++;
      s.inAudio = false;
      s.events.push({ at, k: 'turnComplete' });
    }
    if (m.toolCall) s.events.push({ at, k: 'tool', v: JSON.stringify(m.toolCall).slice(0, 120) });
  });
  ws.on('close', (code, reason) => {
    s.closed = { code, reason: String(reason || '').slice(0, 160) };
  });
  ws.on('error', (e) => s.events.push({ at: Math.round(performance.now() - s.t0), k: 'wserror', v: e.message }));
  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  s.t0 = performance.now();
  ws.send(JSON.stringify(payload));
  const deadline = performance.now() + 12000;
  while (!s.ready && !s.closed && performance.now() < deadline) await delay(20);
  return s;
}

/** Звук звонящего как из Twilio: μ-law 8 кГц → PCM16 16 кГц, кадры по 20 мс в реальном времени. */
function sendPcm8(s, pcm8) {
  const pcm16 = codec.upsample8kTo16k(codec.mulawToPcm16(codec.pcm16ToMulaw(pcm8)));
  s.ws.send(JSON.stringify({ realtimeInput: { audio: { data: codec.int16ToBase64(pcm16), mimeType: 'audio/pcm;rate=16000' } } }));
}

async function stream(s, pcm8, label) {
  const start = performance.now();
  if (label) s.events.push({ at: Math.round(start - s.t0), k: `>> ${label}` });
  for (let i = 0; i < pcm8.length; i += 160) {
    const wait = start + i / 8 - performance.now();
    if (wait > 0) await delay(wait);
    if (s.ws.readyState !== 1) return;
    sendPcm8(s, pcm8.subarray(i, i + 160));
  }
  if (label) s.events.push({ at: Math.round(performance.now() - s.t0), k: `<< ${label}` });
}

async function waitTurns(s, n, ms = 15000) {
  const deadline = performance.now() + ms;
  while (s.turnDone < n && !s.closed && performance.now() < deadline) {
    if (s.ws.readyState === 1) sendPcm8(s, silence(20));
    await delay(20);
  }
}

function greet(s) {
  voiceRelay.greetLive({ ready: true, greeting: '', history: [], extracted: {}, geminiWs: s.ws });
}

function show(s, title) {
  console.log(`\n--- ${title} (setup ${s.setupMs} мс${s.closed ? `, закрыт ${s.closed.code} ${s.closed.reason}` : ''})`);
  let line = '';
  let last = '';
  for (const e of s.events) {
    if ((e.k === 'in' || e.k === 'out') && last === e.k) {
      line += e.v;
      continue;
    }
    if (line) console.log(line);
    line = `${String(e.at).padStart(6)} ${e.k}${e.v !== undefined ? ` ${e.v}` : ''}`;
    last = e.k;
  }
  if (line) console.log(line);
}

async function modelsCheck() {
  for (const model of voiceRelay._internals.liveModels()) {
    let s;
    try {
      s = await session(model, { tools: true });
    } catch (e) {
      console.log(`${model}: не подключился — ${e.message}`);
      continue;
    }
    if (!s.ready) {
      show(s, `${model} НЕ ПОДНЯЛАСЬ`);
      s.ws.terminate();
      continue;
    }
    const sent = Math.round(performance.now() - s.t0);
    greet(s);
    await waitTurns(s, 1);
    const audio = s.events.find((e) => e.k === 'audio');
    show(s, `${model}: первый звук через ${audio ? audio.at - sent : '—'} мс после приветствия`);
    s.ws.close();
    await delay(300);
  }
}

async function vadCheck() {
  const [a1, a2, b1, b2] = synth([
    'My dryer is making this noise, uh,',
    'kind of a grinding sound when it spins.',
    'Hi, my name is',
    'Brad Smith, and my fridge is not cooling.',
  ]);
  const clips = [
    ['пауза 450 мс после «uh,»', [a1, 450, a2]],
    ['пауза 380 мс после «my name is»', [b1, 380, b2]],
  ];
  const model = process.env.MODEL || PRIMARY;
  const configs = (process.env.VADS || '160/200/HIGH,500/300/HIGH').split(',').map((v) => {
    const [silenceMs, prefix, end] = v.split('/');
    return { silenceDurationMs: Number(silenceMs), prefixPaddingMs: Number(prefix), endOfSpeechSensitivity: `END_SENSITIVITY_${end || 'HIGH'}` };
  });
  for (const vad of configs) {
    for (const [label, parts] of clips) {
      const s = await session(model, { vad });
      greet(s);
      await waitTurns(s, 1);
      await stream(s, silence(400));
      const before = s.turnDone;
      for (const part of parts) {
        if (typeof part === 'number') await stream(s, silence(part), `тишина ${part}`);
        else await stream(s, part, 'звонящий');
      }
      await waitTurns(s, before + 1, 12000);
      await stream(s, silence(1500));
      show(s, `${model} ${label} vad=${JSON.stringify(vad)}`);
      s.ws.close();
      await delay(300);
    }
  }
}

async function resumeCheck() {
  const [whirlpool] = synth(["It's a Whirlpool."]);
  const history = [
    { role: 'model', parts: [{ text: "FixApplianceCA, this is Sarah — what's going on?" }] },
    { role: 'user', parts: [{ text: 'My dryer is not heating.' }] },
    { role: 'model', parts: [{ text: 'Oh no — what brand is it?' }] },
  ];
  const note = 'The phone call is still connected after a brief audio glitch on our side. Same caller, not a new call. Do not greet from scratch. Do not say goodbye.';
  let s = await session(PRIMARY);
  s.ws.send(JSON.stringify({ clientContent: { turns: [...history, { role: 'user', parts: [{ text: `${note} Stay quiet and listen until the caller speaks.` }] }], turnComplete: false } }));
  await stream(s, silence(2500), 'тишина 2,5 с — она должна молчать');
  await stream(s, whirlpool, 'звонящий');
  await waitTurns(s, 1, 10000);
  await stream(s, silence(800));
  show(s, 'после сбоя последней говорила она (turnComplete=false)');
  s.ws.close();
  await delay(300);
  s = await session(PRIMARY);
  s.ws.send(JSON.stringify({ clientContent: { turns: [...history, { role: 'user', parts: [{ text: "It's a Whirlpool, about five years old." }] }, { role: 'user', parts: [{ text: `${note} Reply now to what the caller just said, as if nothing happened.` }] }], turnComplete: true } }));
  await waitTurns(s, 1, 10000);
  await stream(s, silence(800));
  show(s, 'после сбоя звонящий ждал ответа (turnComplete=true)');
  s.ws.close();
}

async function dialogCheck() {
  const scripts = {
    name: ['Hi, how are you doing today?', "Sorry, what's your name?"],
    human: ['Hi there.', 'Wait, am I talking to a real person?'],
    freon: ['Do you guys put Freon in fridges?'],
  };
  for (const name of process.env.DIALOG ? process.env.DIALOG.split(',') : Object.keys(scripts)) {
    const clips = synth(scripts[name]);
    const s = await session(PRIMARY, { real: true });
    greet(s);
    await waitTurns(s, 1);
    for (const [i, clip] of clips.entries()) {
      await stream(s, silence(300));
      await stream(s, clip, `звонящий: ${scripts[name][i]}`);
      await waitTurns(s, i + 2);
    }
    await stream(s, silence(600));
    show(s, `диалог ${name}`);
    s.ws.close();
    await delay(300);
  }
}

async function ladderCheck() {
  const src = fs.readFileSync(path.join(FN, 'voice_relay.js'), 'utf8');
  const stage1 = src.match(/\? 'The caller has not said anything[^']*'/)[0].slice(3, -1);
  const stage2 = src.match(/: 'Still nothing from the caller[^']*'/)[0].slice(3, -1);
  const s = await session(PRIMARY, { real: true, caller: { clientName: 'Maria', knownAddress: '12 King Street, Brantford' } });
  greet(s);
  await waitTurns(s, 1);
  for (const [i, text] of [stage1, stage2].entries()) {
    await stream(s, silence(1000));
    s.ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text }] }], turnComplete: true } }));
    await waitTurns(s, i + 2);
  }
  await stream(s, silence(600));
  show(s, 'лестница тишины: переспрос, затем «не слышу — перезвоните или напишите»');
  s.ws.close();
}

const runs = { models: modelsCheck, vad: vadCheck, resume: resumeCheck, dialog: dialogCheck, ladder: ladderCheck };
const mode = process.argv[2] || 'models';
if (!runs[mode]) {
  console.error(`неизвестный режим ${mode}; есть: ${Object.keys(runs).join(', ')}`);
  process.exitCode = 1;
} else if (!KEY) {
  console.error('нет GEMINI_API_KEY — запускайте с --env-file=functions/.env');
  process.exitCode = 1;
} else {
  runs[mode]().catch((e) => {
    console.error('сбой зонда:', e.message);
    process.exitCode = 1;
  });
}
