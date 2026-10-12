const assert = require('node:assert/strict');
const { test } = require('node:test');
const { dubTurns, createCallDubber, DUB_RATE, GAP_SECONDS } = require('./call_dub');

function speech(seconds) {
  const pcm = Buffer.alloc(Math.round(24000 * seconds) * 2);
  for (let i = 0; i < pcm.length / 2; i++) {
    pcm.writeInt16LE(Math.round(8000 * Math.sin(i / 20)), i * 2);
  }
  return pcm;
}

test('реплики разбираются по меткам говорящих, строка без метки продолжает предыдущую', () => {
  const turns = dubTurns([
    'ИИ: Чем могу помочь?',
    'Клиент: Сломалась посудомойка.',
    'и течёт вода',
    '',
    'Моё: Понял, приеду завтра.',
  ].join('\n'));
  assert.deepEqual(turns, [
    { who: 'shop', text: 'Чем могу помочь?' },
    { who: 'client', text: 'Сломалась посудомойка. и течёт вода' },
    { who: 'shop', text: 'Понял, приеду завтра.' },
  ]);
});

test('пустая расшифровка озвучку не запускает', async () => {
  const dubber = createCallDubber({ apiKey: 'test-key', fetchImpl: async () => { throw new Error('не должно вызываться'); } });
  await assert.rejects(dubber.buildRussianDub('   '), /Нет русской расшифровки/);
});

test('без ключа OpenAI озвучки нет, но это честная ошибка, а не пустой файл', async () => {
  const dubber = createCallDubber({ apiKey: '', fetchImpl: async () => { throw new Error('не должно вызываться'); } });
  await assert.rejects(dubber.buildRussianDub('ИИ: Привет'), /OPENAI_API_KEY/);
});

test('у мастерской и клиента разные голоса, а дорожка собирается в WAV 8 кГц', async () => {
  const asked = [];
  const dubber = createCallDubber({
    apiKey: 'test-key',
    fetchImpl: async (url, options) => {
      const body = JSON.parse(options.body);
      asked.push(body);
      assert.equal(url, 'https://api.openai.com/v1/audio/speech');
      assert.equal(body.response_format, 'pcm');
      return new Response(speech(1), { status: 200 });
    },
  });
  const result = await dubber.buildRussianDub('ИИ: Первая реплика.\nКлиент: Вторая реплика.');
  assert.equal(asked.length, 2);
  assert.notEqual(asked[0].voice, asked[1].voice);
  assert.match(asked[0].instructions, /по-русски/i);
  const header = result.wav.subarray(0, 44);
  assert.equal(header.toString('ascii', 0, 4), 'RIFF');
  assert.equal(header.toString('ascii', 8, 12), 'WAVE');
  assert.equal(header.readUInt16LE(22), 1);
  assert.equal(header.readUInt32LE(24), DUB_RATE);
  assert.equal(header.readUInt16LE(34), 16);
  assert.equal(header.readUInt32LE(40), result.wav.length - 44);
  // Две секунды речи плюс пауза после каждой реплики.
  assert.ok(Math.abs(result.seconds - (2 + 2 * GAP_SECONDS)) < 0.05, `${result.seconds}`);
  assert.equal(result.turns, 2);
});

test('реплики озвучиваются очередью и ложатся в дорожку в исходном порядке', async () => {
  let running = 0;
  let peak = 0;
  const dubber = createCallDubber({
    apiKey: 'test-key',
    fetchImpl: async (_, options) => {
      running += 1;
      peak = Math.max(peak, running);
      const index = Number(JSON.parse(options.body).input.replace(/\D/g, ''));
      // Первая реплика самая медленная: очередь не должна её ждать.
      await new Promise((resolve) => setTimeout(resolve, index === 1 ? 60 : 5));
      running -= 1;
      return new Response(speech(index === 1 ? 2 : 0.5), { status: 200 });
    },
  });
  const lines = Array.from({ length: 24 }, (_, i) => `${i % 2 ? 'Клиент' : 'ИИ'}: реплика ${i + 1}`);
  const result = await dubber.buildRussianDub(lines.join('\n'));
  assert.equal(result.turns, 24);
  assert.ok(peak > 1 && peak <= 10, `одновременных запросов ${peak}`);
  // Длинная первая реплика стоит в начале дорожки, а не там, где успела.
  const samples = (result.wav.length - 44) / 2;
  assert.ok(Math.abs(samples / DUB_RATE - (2 + 23 * 0.5 + 24 * GAP_SECONDS)) < 0.2);
});
