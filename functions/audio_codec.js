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

function downsampleTo8k(pcm, fromRate, leftover) {
  const combined = concatInt16(leftover, pcm);
  const ratio = Math.max(1, Math.round(Number(fromRate || 24000) / 8000));
  const outLen = Math.floor(combined.length / ratio);
  const out = new Int16Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const start = i * ratio;
    let sum = 0;
    for (let j = 0; j < ratio; j++) sum += combined[start + j];
    out[i] = sum / ratio;
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

module.exports = {
  mulawToPcm16,
  pcm16ToMulaw,
  upsample8kTo16k,
  downsampleTo8k,
  int16ToBase64,
  base64ToInt16,
  parsePcmRate,
};
