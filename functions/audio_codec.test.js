const assert = require('node:assert/strict');
const { test } = require('node:test');
const {
  mulawToPcm16,
  pcm16ToMulaw,
  downsampleTo8k,
  createLowPass,
  MULAW_SILENCE,
} = require('./audio_codec');

function tone(hz, rate, ms, amplitude = 8000) {
  const samples = Math.round((rate * ms) / 1000);
  const out = new Int16Array(samples);
  for (let i = 0; i < samples; i++) {
    out[i] = Math.round(amplitude * Math.sin((2 * Math.PI * hz * i) / rate));
  }
  return out;
}

/// Вторая половина буфера: первые миллисекунды фильтр ещё раскачивается.
function rms(pcm) {
  const from = Math.floor(pcm.length / 2);
  let sum = 0;
  for (let i = from; i < pcm.length; i++) sum += pcm[i] * pcm[i];
  return Math.sqrt(sum / (pcm.length - from));
}

test('the anti-aliasing filter keeps the voice band and kills what folds back', () => {
  const rate = 24000;
  const speech = tone(400, rate, 200);
  const passed = createLowPass(rate, 3400).process(speech);
  assert.ok(rms(passed) / rms(speech) > 0.95, 'the telephone band must come through untouched');

  // 6 кГц при даунсемплинге до 8 кГц заворачивается в 2 кГц — прямо в середину
  // речи. Это и есть металлический призвук, который слышно в трубке.
  const high = tone(6000, rate, 200);
  const blocked = createLowPass(rate, 3400).process(high);
  assert.ok(rms(blocked) / rms(high) < 0.2, 'what cannot survive 8 kHz must be removed first');
});

test('downsampling to 8 kHz aliases badly without the filter and cleanly with it', () => {
  const rate = 24000;
  const high = tone(6000, rate, 200);
  const raw = downsampleTo8k(high, rate, new Int16Array(0));
  const clean = downsampleTo8k(high, rate, new Int16Array(0), createLowPass(rate, 3400));
  assert.equal(raw.pcm8.length, clean.pcm8.length);
  assert.ok(rms(clean.pcm8) / rms(raw.pcm8) < 0.3, 'the filter must cut the folded tone');
});

test('downsampling keeps the sample remainder so chunks join without a click', () => {
  const rate = 24000;
  const filter = createLowPass(rate, 3400);
  // 100 сэмплов при соотношении 3 — это 33 кадра и остаток в 1 сэмпл.
  const first = downsampleTo8k(tone(400, rate, 10).subarray(0, 100), rate, new Int16Array(0), filter);
  assert.equal(first.pcm8.length, 33);
  assert.equal(first.leftover.length, 1);
  const second = downsampleTo8k(tone(400, rate, 10).subarray(0, 101), rate, first.leftover, filter);
  assert.equal(second.pcm8.length, 34);
  assert.equal(second.leftover.length, 0);
});

test('mulaw silence is the byte we pad short frames with', () => {
  assert.equal(pcm16ToMulaw(Int16Array.from([0]))[0], MULAW_SILENCE);
  assert.equal(mulawToPcm16(Buffer.from([MULAW_SILENCE]))[0], 0);
  // Громкая речь переживает круг кодирования без заметной потери.
  const speech = tone(400, 8000, 50);
  const round = mulawToPcm16(pcm16ToMulaw(speech));
  assert.ok(Math.abs(rms(round) - rms(speech)) / rms(speech) < 0.05);
});
