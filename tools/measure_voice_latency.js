const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');
const { once } = require('node:events');
const { performance } = require('node:perf_hooks');
const { setTimeout: delay } = require('node:timers/promises');
const functionRequire = createRequire(require.resolve('../functions/package.json'));
const { WebSocket } = functionRequire('ws');
const { mulawToPcm16, pcm16ToMulaw, upsample8kTo16k, downsampleTo8k, base64ToInt16, int16ToBase64, parsePcmRate } = require('../functions/audio_codec');
const voiceRelay = require('../functions/voice_relay');
const voiceFacts = require('../functions/voice_facts');

function energy(pcm) {
  let sum = 0;
  let peak = 0;
  for (const sample of pcm) {
    sum += sample * sample;
    peak = Math.max(peak, Math.abs(sample));
  }
  return { rms: Math.sqrt(sum / Math.max(1, pcm.length)), peak };
}

function summarize(frames, callerEnd, compact = false) {
  let playAt = frames[0].at;
  let quietSamples = 0;
  let spoken = false;
  let firstSpeech;
  let lastSpeechEnd;
  let leadingQuietMs = 0;
  let removedMs = 0;
  const pauses = [];
  const levels = frames.map((frame) => frame.rms).sort((a, b) => a - b);
  const speechThreshold = Math.max(120, levels[Math.floor(levels.length * 0.95)] * 0.1);
  for (const frame of frames) {
    let samples = frame.samples;
    if (compact && frame.peak <= 64) {
      const limit = spoken ? 2000 : 320;
      samples = Math.min(samples, Math.max(0, limit - quietSamples));
      quietSamples += frame.samples;
      removedMs += (frame.samples - samples) / 8;
    } else if (frame.peak > 64) {
      spoken = true;
      quietSamples = 0;
    }
    if (!samples) continue;
    const start = Math.max(frame.at, playAt);
    playAt = start + samples / 8;
    if (frame.rms < speechThreshold) {
      if (firstSpeech === undefined) leadingQuietMs += samples / 8;
      continue;
    }
    if (firstSpeech === undefined) firstSpeech = start;
    if (lastSpeechEnd !== undefined && start - lastSpeechEnd >= 150) {
      pauses.push(Math.round(start - lastSpeechEnd));
    }
    lastSpeechEnd = playAt;
  }
  return {
    firstPacketMs: Math.round(frames[0].at - callerEnd),
    firstAudibleMs: Math.round((firstSpeech ?? frames[0].at) - callerEnd),
    leadingQuietMs,
    internalPausesMs: pauses,
    removedMs,
  };
}

async function readClips() {
  let json;
  if (process.argv.includes('--synthetic')) {
    if (process.platform !== 'win32') throw new Error('Supply raw 8 kHz PCM16 clips as JSON on stdin outside Windows');
    const command = `$ErrorActionPreference = 'Stop';
Add-Type -AssemblyName System.Speech;
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer;
$speaker.SelectVoice('Microsoft Zira Desktop');
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(8000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);
$clips = foreach ($text in @('My dishwasher is leaking water onto the floor.', 'Do you work on Bosch dishwashers?', 'Can I leave the dishwasher turned on until the technician arrives?')) {
  $buffer = New-Object System.IO.MemoryStream;
  $speaker.SetOutputToAudioStream($buffer, $format);
  $speaker.Speak($text);
  $speaker.SetOutputToNull();
  [pscustomobject]@{ text = $text; pcm = [Convert]::ToBase64String($buffer.ToArray()) };
  $buffer.Dispose();
};
$speaker.Dispose();
ConvertTo-Json -InputObject @($clips) -Depth 3 -Compress;`;
    json = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], {
      encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, timeout: 30000,
    });
  } else {
    const input = [];
    for await (const chunk of process.stdin) input.push(Buffer.from(chunk));
    json = Buffer.concat(input).toString();
  }
  const clips = JSON.parse(json.replace(/^\uFEFF/, ''));
  if (!Array.isArray(clips) || !clips.length) throw new Error('Provide at least one test clip');
  return clips;
}

async function main() {
  const direct = process.argv.includes('--direct');
  const key = direct ? process.env.GEMINI_API_KEY : process.env.VOICE_RELAY_KEY;
  if (!key) throw new Error('The selected transport key is not configured');
  const clips = await readClips();
  const model = 'gemini-3.1-flash-live-preview';
  const setup = voiceRelay.buildSetup(model, voiceRelay.liveSystemPrompt({ instructions: voiceFacts.VOICE_CALL_FLOW }, {}), false);
  for (const [flag, field] of [['--prefix=', 'prefixPaddingMs'], ['--silence=', 'silenceDurationMs']]) {
    const argument = process.argv.find((value) => value.startsWith(flag));
    if (argument) {
      const value = Number(argument.slice(flag.length));
      if (!direct || !Number.isInteger(value) || value < 20 || value > 1200) throw new Error('VAD overrides require direct mode and a value between 20 and 1200');
      setup.setup.realtimeInputConfig.automaticActivityDetection[field] = value;
    }
  }
  console.log(JSON.stringify({ transport: direct ? 'direct-gemini' : 'deployed-relay', vad: direct ? setup.setup.realtimeInputConfig.automaticActivityDetection : undefined }));
  const url = direct
    ? 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=' + encodeURIComponent(key)
    : process.env.VOICE_PROBE_URL || 'wss://aivoicerelay-wmdrqa3n7q-uc.a.run.app';
  const ws = new WebSocket(url, { perMessageDeflate: false, handshakeTimeout: 15000 });
  let frames = [];
  let playoutEnd = 0;
  let socketError;
  let interrupted = false;
  let heard = '';
  let leftover = new Int16Array(0);
  const session = { ready: true, geminiWs: ws, greeting: 'Hi, FIX Appliance CA. How can I help?' };
  const capture = (pcm) => {
    const at = performance.now();
    for (let i = 0; i < pcm.length; i += 160) {
      const frame = pcm.subarray(i, i + 160);
      frames.push({ at, samples: frame.length, ...energy(frame) });
      playoutEnd = Math.max(at, playoutEnd) + frame.length / 8;
    }
  };
  const send = (message) => {
    let payload = message;
    if (direct) {
      payload = message.event === 'start' ? setup : {
        realtimeInput: { audio: { mimeType: 'audio/pcm;rate=16000', data: int16ToBase64(upsample8kTo16k(mulawToPcm16(Buffer.from(message.media.payload, 'base64')))) } },
      };
    }
    ws.send(JSON.stringify(payload));
  };
  ws.on('error', (error) => { socketError = error; });
  ws.on('message', (raw) => {
    const message = JSON.parse(raw.toString());
    if (direct) {
      if (message.error) socketError = new Error(message.error.message || 'Gemini setup failed');
      if (message.setupComplete) voiceRelay.greetLive(session);
      const content = message.serverContent || {};
      if (content.inputTranscription?.text) heard += content.inputTranscription.text;
      if (content.interrupted) {
        interrupted = true;
        playoutEnd = performance.now();
      }
      for (const part of content.modelTurn?.parts || []) {
        if (!part.inlineData?.data) continue;
        const result = downsampleTo8k(base64ToInt16(part.inlineData.data), parsePcmRate(part.inlineData.mimeType), leftover);
        leftover = result.leftover;
        capture(mulawToPcm16(pcm16ToMulaw(result.pcm8)));
      }
      return;
    }
    if (message.event === 'clear') {
      interrupted = true;
      playoutEnd = performance.now();
      return;
    }
    if (message.event === 'media' && message.media?.payload) capture(mulawToPcm16(Buffer.from(message.media.payload, 'base64')));
  });
  const waitForReply = async () => {
    const deadline = performance.now() + 25000;
    while (performance.now() < deadline) {
      if (socketError) throw socketError;
      if (ws.readyState !== WebSocket.OPEN) throw new Error('Relay closed before the probe ended');
      if (frames.length && performance.now() - frames.at(-1).at > 1800 && performance.now() > playoutEnd + 250) return;
      await delay(100);
    }
    throw new Error('No complete reply within the probe deadline');
  };
  try {
    await once(ws, 'open');
    const connectedAt = performance.now();
    send({
      event: 'start',
      start: { streamSid: 'MZ-latency-probe', customParameters: { k: process.env.VOICE_RELAY_KEY, greetingSpoken: '0' } },
    });
    await waitForReply();
    console.log(JSON.stringify({ phase: 'greeting', baseline: summarize(frames, connectedAt), silenceCapPreview: summarize(frames, connectedAt, true) }));
    for (const clip of clips) {
      const raw = Buffer.from(clip.pcm, 'base64');
      if (raw.toString('ascii', 0, 4) === 'RIFF') throw new Error('Expected raw 8 kHz mono PCM16, not WAV');
      const pcm = new Int16Array(raw.length / 2);
      for (let i = 0; i < pcm.length; i++) pcm[i] = raw.readInt16LE(i * 2);
      let first = 0;
      let last = pcm.length - 1;
      while (first < last && Math.abs(pcm[first]) < 128) first++;
      while (last > first && Math.abs(pcm[last]) < 128) last--;
      const audio = pcm.subarray(Math.max(0, first - 320), Math.min(pcm.length, last + 321));
      const mulaw = pcm16ToMulaw(audio);
      frames = [];
      interrupted = false;
      heard = '';
      const startedAt = performance.now();
      let callerEnd = startedAt;
      for (let at = 0; at < audio.length + 24000; at += 160) {
        const wait = startedAt + at / 8 - performance.now();
        if (wait > 0) await delay(wait);
        if (ws.readyState !== WebSocket.OPEN) throw new Error('Relay closed while sending test audio');
        const payload = Buffer.alloc(160, 255);
        if (at < audio.length) {
          payload.set(mulaw.subarray(at, Math.min(at + 160, mulaw.length)));
          if (energy(audio.subarray(at, Math.min(at + 160, audio.length))).peak >= 128) callerEnd = performance.now() + 20;
        }
        send({ event: 'media', media: { track: 'inbound', payload: payload.toString('base64') } });
      }
      await waitForReply();
      console.log(JSON.stringify({ phase: clip.text, interrupted, heard: direct ? heard : undefined, baseline: summarize(frames, callerEnd), silenceCapPreview: summarize(frames, callerEnd, true) }));
    }
  } finally {
    if (ws.readyState === WebSocket.OPEN) ws.close(1000, 'latency probe complete');
    else ws.terminate();
  }
}

main().catch((error) => {
  console.error('Voice latency probe failed:', error.message);
  process.exitCode = 1;
});
