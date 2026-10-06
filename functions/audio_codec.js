'use strict';

const MULAW_BIAS = 0x84;
const MULAW_CLIP = 32635;
const MULAW_DECODE = new Int16Array(256);

for (let i = 0; i < 256; i++) {
  const u = ~i & 0xff;
  let t = ((u & 0x0f) << 3) + MULAW_BIAS;
  t <<= (u & 0x70) >> 4;
  MULAW_DECODE[i] = u & 0x80 ? MULAW_BIAS - t : t - MULAW_BIAS;
}

function mulawToPcm16(mulaw) {
  const out = new Int16Array(mulaw.length);
  for (let i = 0; i < mulaw.length; i++) {
    out[i] = MULAW_DECODE[mulaw[i]];
  }
  return out;
}

function linearToMulaw(sample) {
  let sign = 0;
  if (sample < 0) {
    sign = 0x80;
    sample = -sample;
  }
  if (sample > MULAW_CLIP) sample = MULAW_CLIP;
  sample += MULAW_BIAS;
  let exponent = 7;
  for (let mask = 0x4000; (sample & mask) === 0 && exponent > 0; exponent--, mask >>= 1) {}
  const mantissa = (sample >> (exponent + 3)) & 0x0f;
  return ~(sign | (exponent << 4) | mantissa) & 0xff;
}

function pcm16ToMulaw(pcm) {
  const out = Buffer.allocUnsafe(pcm.length);
  for (let i = 0; i < pcm.length; i++) {
    out[i] = linearToMulaw(pcm[i]);
  }
  return out;
}

function upsample8kTo16k(pcm8) {
  const n = pcm8.length;
  const out = new Int16Array(n * 2);
  for (let i = 0; i < n; i++) {
    const a = pcm8[i];
    const b = pcm8[Math.min(i + 1, n - 1)];
    out[i * 2] = a;
    out[i * 2 + 1] = (a + b) >> 1;
  }
  return out;
}

function concatInt16(a, b) {
  if (!a || !a.length) return b;
  if (!b || !b.length) return a;
  const out = new Int16Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// Антиалиасинг перед 24 кГц → 8 кГц. Усреднения трёх соседних сэмплов мало:
// всё, что в голосе выше 4 кГц (шипящие, призвуки синтеза), заворачивается
// обратно в слышимую полосу и даёт тот самый металлический оттенок в трубке.
// Два биквада подряд — это 4-й порядок Баттерворта: на 6 кГц уже −21 дБ, а в
// телефонной полосе до 3,4 кГц звук не трогается.
const LOWPASS_STAGE_Q = [0.5411961, 1.3065630];

function biquadLowPass(sampleRate, cutoffHz, q) {
  const w0 = (2 * Math.PI * cutoffHz) / sampleRate;
  const cos0 = Math.cos(w0);
  const alpha = Math.sin(w0) / (2 * q);
  const a0 = 1 + alpha;
  return {
    b0: ((1 - cos0) / 2) / a0,
    b1: (1 - cos0) / a0,
    b2: ((1 - cos0) / 2) / a0,
    a1: (-2 * cos0) / a0,
    a2: (1 - alpha) / a0,
    z1: 0,
    z2: 0,
  };
}

/// Фильтр живёт столько же, сколько звонок: состояние звеньев переносится из
/// чанка в чанк, иначе на каждом куске аудио был бы слышен щелчок.
function createLowPass(sampleRate, cutoffHz = 3400) {
  const rate = Number(sampleRate) || 24000;
  const cutoff = Math.max(300, Math.min(Number(cutoffHz) || 3400, rate / 2 - 100));
  const stages = LOWPASS_STAGE_Q.map((q) => biquadLowPass(rate, cutoff, q));
  return {
    sampleRate: rate,
    cutoff,
    process(pcm) {
      const out = new Int16Array(pcm.length);
      for (let i = 0; i < pcm.length; i++) {
        let x = pcm[i];
        for (const stage of stages) {
          // Transposed direct form II: меньше накопленной ошибки на длинном звонке.
          const y = stage.b0 * x + stage.z1;
          stage.z1 = stage.b1 * x - stage.a1 * y + stage.z2;
          stage.z2 = stage.b2 * x - stage.a2 * y;
          x = y;
        }
        out[i] = x >= 32767 ? 32767 : x <= -32768 ? -32768 : Math.round(x);
      }
      return out;
    },
  };
}

function downsampleTo8k(pcm, fromRate, leftover, filter) {
  const rate = Number(fromRate || 24000);
  // Остаток с прошлого раза уже отфильтрован — пропускаем только новый кусок.
  const source = filter && filter.sampleRate === rate ? filter.process(pcm) : pcm;
  const combined = concatInt16(leftover, source);
  const ratio = Math.max(1, Math.round(rate / 8000));
  const outLen = Math.floor(combined.length / ratio);
  const out = new Int16Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const start = i * ratio;
    let sum = 0;
    for (let j = 0; j < ratio; j++) sum += combined[start + j];
    out[i] = Math.round(sum / ratio);
  }
  const rem = combined.length % ratio;
  return {
    pcm8: out,
    leftover: rem ? combined.slice(combined.length - rem) : new Int16Array(0),
  };
}

function int16ToBase64(pcm) {
  return Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength).toString('base64');
}

function base64ToInt16(b64) {
  const buf = Buffer.from(b64, 'base64');
  const samples = buf.length >> 1;
  const out = new Int16Array(samples);
  for (let i = 0; i < samples; i++) {
    out[i] = buf.readInt16LE(i * 2);
  }
  return out;
}

function parsePcmRate(mimeType) {
  const match = String(mimeType || '').match(/rate=(\d+)/i);
  return match ? Number(match[1]) : 24000;
}

// mulaw-кодировка нуля. Ей добиваем неполный кадр, когда реплика кончилась,
// а до 160 байт не хватает нескольких миллисекунд.
const MULAW_SILENCE = 0xff;

module.exports = {
  mulawToPcm16,
  pcm16ToMulaw,
  upsample8kTo16k,
  downsampleTo8k,
  createLowPass,
  int16ToBase64,
  base64ToInt16,
  parsePcmRate,
  MULAW_SILENCE,
};
