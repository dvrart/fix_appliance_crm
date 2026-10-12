const assert = require('node:assert/strict');
const { test } = require('node:test');
const {
  parseWav,
  channelWav,
  channelEnergy,
  channelTurns,
  liveSegments,
  punctuatedWords,
  wordsToTurns,
  mergeTurns,
  dialogText,
  pickShopChannel,
  looksRepetitive,
  createCallTranscriber,
} = require('./call_transcribe');

const RATE = 8000;

/** Стереозапись: для каждого канала список громких отрезков [от, до]. */
function stereoWav(seconds, loud = [[], []]) {
  const frames = seconds * RATE;
  const data = Buffer.alloc(frames * 4);
  for (let i = 0; i < frames; i++) {
    for (let channel = 0; channel < 2; channel++) {
      const t = i / RATE;
      const speaking = loud[channel].some(([from, to]) => t >= from && t < to);
      const value = speaking ? Math.round(12000 * Math.sin(t * 900)) : 0;
      data.writeInt16LE(value, (i * 2 + channel) * 2);
    }
  }
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(2, 22);
  header.writeUInt32LE(RATE, 24);
  header.writeUInt32LE(RATE * 4, 28);
  header.writeUInt16LE(4, 32);
  header.writeUInt16LE(16, 34);
  header.write('data', 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

function words(pairs) {
  return pairs.map(([word, start, end]) => ({ word, start, end }));
}

test('каждая дорожка выделяется в самостоятельный моно-WAV', () => {
  const wav = parseWav(stereoWav(4, [[[0, 1]], [[2, 3]]]));
  assert.equal(wav.channels, 2);
  assert.equal(wav.rate, RATE);
  assert.equal(Math.round(wav.duration), 4);
  const left = parseWav(channelWav(wav, 0));
  assert.equal(left.channels, 1);
  assert.equal(Math.round(left.duration), 4);
  assert.ok(channelEnergy(wav, 0, 0, 1) > 0.1);
  assert.ok(channelEnergy(wav, 0, 2, 3) < 0.001);
  assert.ok(channelEnergy(wav, 1, 2, 3) > 0.1);
});

test('кусок дорожки вырезается по времени — на длинной записи это куски по очереди', () => {
  const wav = parseWav(stereoWav(10, [[[0, 10]], []]));
  const piece = parseWav(channelWav(wav, 0, 4, 7));
  assert.equal(Math.round(piece.duration), 3);
});

test('выдумки на тишине выкидываются, а тихая живая реплика остаётся', () => {
  const wav = parseWav(stereoWav(20, [[[1, 3], [10, 13]], []]));
  const kept = liveSegments(
    [
      { start: 1, end: 3, text: 'Yes, correct.', no_speech_prob: 0.86, avg_logprob: -0.66 },
      { start: 5, end: 8, text: 'Bye. Bye. Bye.', no_speech_prob: 0.4, avg_logprob: -0.5 },
      { start: 10, end: 13, text: '35 Edison Crescent.', no_speech_prob: 0.79, avg_logprob: -0.53 },
    ],
    wav,
    0
  );
  // Высокий no_speech_prob сам по себе ничего не значит: по нему раньше
  // вылетали настоящие реплики с адресом.
  assert.deepEqual(kept.map((item) => item.text), ['Yes, correct.', '35 Edison Crescent.']);
});

test('одна и та же строка подряд считается зацикливанием только с третьего раза', () => {
  const wav = parseWav(stereoWav(10, [[[0, 10]], []]));
  const kept = liveSegments(
    [
      { start: 0, end: 1, text: 'Yes.', avg_logprob: -0.3 },
      { start: 1, end: 2, text: 'Yes.', avg_logprob: -0.3 },
      { start: 2, end: 3, text: 'Yes.', avg_logprob: -0.3 },
      { start: 3, end: 4, text: 'Yes.', avg_logprob: -0.3 },
    ],
    wav,
    0
  );
  assert.equal(kept.length, 2);
});

test('знаки препинания и склеенные номера переносятся из сегментов в разметку по словам', () => {
  const spoken = words([
    ['The', 0, 0.2], ['number', 0.2, 0.5], ['is', 0.5, 0.7],
    ['519', 0.7, 1], ['503', 1, 1.3], ['7091', 1.3, 1.7],
    ['before', 2, 2.3], ['5', 2.3, 2.5], ['o', 2.5, 2.6], ['clock', 2.6, 2.9],
  ]).map((word) => ({ ...word, text: word.word }));
  const punctuated = punctuatedWords(spoken, [
    { start: 0, end: 1.7, text: 'The number is 519-503-7091.' },
    { start: 2, end: 2.9, text: "before 5 o'clock" },
  ]);
  const line = punctuated.map((word) => word.text).join(' ');
  assert.match(line, /519-503-7091\./);
  assert.match(line, /o'clock/);
  // Склеенный токен закрывает все свои слова и не повторяет их по отдельности.
  assert.equal(line.match(/519/g).length, 1);
});

test('реплика рвётся по паузе, а дорожки сводятся в разговор по времени', () => {
  const shop = wordsToTurns(
    words([['Hello', 0, 0.4], ['there', 0.4, 0.8], ['Address', 6, 6.4]]).map((w) => ({ ...w, text: w.word })),
    'shop'
  );
  const client = wordsToTurns(
    words([['Hi', 2, 2.3], ['Stratford', 4, 4.4], ['Ontario', 6.9, 7.3]]).map((w) => ({ ...w, text: w.word })),
    'client'
  );
  const merged = mergeTurns([shop, client]);
  assert.deepEqual(
    merged.map((turn) => `${turn.who}: ${turn.text}`),
    ['shop: Hello there', 'client: Hi Stratford', 'shop: Address', 'client: Ontario']
  );
  assert.equal(
    dialogText(merged, { shop: 'AI', client: 'Client' }),
    'AI: Hello there\nClient: Hi Stratford\nAI: Address\nClient: Ontario'
  );
});

test('слова вне живых сегментов в расшифровку не попадают', () => {
  const wav = parseWav(stereoWav(12, [[[0, 2]], []]));
  const turns = channelTurns({
    segments: [
      { start: 0, end: 2, text: 'Hello there.', avg_logprob: -0.3 },
      { start: 6, end: 8, text: 'Thank you for watching.', avg_logprob: -0.3 },
    ],
    words: words([
      ['Hello', 0, 0.5], ['there', 0.5, 1],
      ['Thank', 6, 6.3], ['you', 6.3, 6.6], ['for', 6.6, 6.8], ['watching', 6.8, 7.4],
    ]),
    wav,
    channel: 0,
    who: 'client',
  });
  assert.deepEqual(turns.map((turn) => turn.text), ['Hello there.']);
});

test('наша дорожка определяется по фразам приёма, иначе по направлению звонка', () => {
  assert.equal(pickShopChannel({ direction: 'inbound', left: 'My dishwasher is broken', right: 'Fix Appliance CA, this is Sarah' }), 1);
  assert.equal(pickShopChannel({ direction: 'inbound', left: 'Fix Appliance, how can I help you', right: 'my dryer died' }), 0);
  assert.equal(pickShopChannel({ direction: 'inbound', left: 'hello', right: 'hello' }), 1);
  assert.equal(pickShopChannel({ direction: 'outbound', left: 'hello', right: 'hello' }), 0);
});

// Живой звонок 07.10.2026: со словарём-подсказкой дорожка клиента вернулась
// 202 сегментами «Hello?», фильтр повторов оставил от неё две реплики, и из
// разговора пропали имя «Will», адрес и описание поломки.
test('петля распознавания видна, а обычный разговор за петлю не принимается', () => {
  const loop = Array.from({ length: 20 }, (_, i) => ({ text: 'Hello?', start: i, end: i + 0.5 }));
  assert.equal(looksRepetitive(loop), true);
  assert.equal(
    looksRepetitive([
      { text: 'Hello, can you hear me now?' }, { text: 'Yep.' }, { text: 'All right.' },
      { text: 'Early afternoon is good.' }, { text: 'My name is Will.' }, { text: 'I got an LG fridge.' },
      { text: "There's an odor coming from it." }, { text: 'It is getting worse.' }, { text: 'Okay, thank you.' },
    ]),
    false
  );
  // Короткое «да-да-да» в начале разговора петлёй не считается.
  assert.equal(looksRepetitive([{ text: 'Yeah.' }, { text: 'Yeah.' }, { text: 'Yeah.' }]), false);
});

test('сорвавшуюся в петлю дорожку переспрашивают без подсказки', async () => {
  const asked = [];
  const loop = {
    segments: Array.from({ length: 20 }, (_, i) => ({ text: 'Hello?', start: i, end: i + 0.5, avg_logprob: -0.4 })),
    words: words(Array.from({ length: 20 }, (_, i) => ['Hello?', i, i + 0.5])),
  };
  const real = {
    segments: [{ start: 1, end: 3, text: 'My name is Will.', avg_logprob: -0.3 }],
    words: words([['My', 1, 1.4], ['name', 1.4, 1.8], ['is', 1.8, 2.2], ['Will', 2.2, 3]]),
  };
  const transcriber = createCallTranscriber({
    apiKey: 'test-key',
    fetchImpl: async (url, options) => {
      const name = options.body.get('file').name;
      const prompt = options.body.get('prompt') || '';
      asked.push(`${name.startsWith('call-0') ? 'shop' : 'client'}:${prompt ? 'подсказка' : 'без'}`);
      if (name.startsWith('call-0')) {
        return new Response(JSON.stringify({
          segments: [{ start: 1, end: 2, text: 'FixApplianceCA, how can I help?', avg_logprob: -0.3 }],
          words: words([['FixApplianceCA,', 1, 1.5], ['how', 1.5, 1.7], ['can', 1.7, 1.8], ['I', 1.8, 1.9], ['help?', 1.9, 2]]),
        }), { status: 200 });
      }
      return new Response(JSON.stringify(prompt ? loop : real), { status: 200 });
    },
  });
  const result = await transcriber.transcribeDualWav(stereoWav(4, [[[1, 2]], [[1, 3]]]), {
    direction: 'inbound',
    prompt: 'Brands: Bosch, LG',
    labels: { shop: 'Me', client: 'Client' },
  });
  assert.deepEqual(asked, ['shop:подсказка', 'client:подсказка', 'client:без']);
  assert.ok(result.text.includes('Client: My name is Will.'), result.text);
});

test('запись в одну дорожку не расшифровывается здесь — вызывающий остаётся на прежнем пути', async () => {
  const mono = Buffer.from(channelWav(parseWav(stereoWav(2, [[[0, 2]], []])), 0));
  const transcriber = createCallTranscriber({ apiKey: 'test-key', fetchImpl: async () => { throw new Error('не должно вызываться'); } });
  await assert.rejects(transcriber.transcribeDualWav(mono), /not dual-channel/);
});

test('обе дорожки распознаются параллельно и сводятся в один диалог', async () => {
  const calls = [];
  const answers = {
    0: {
      segments: [{ start: 2, end: 3, text: 'My Bosch dishwasher is broken.', avg_logprob: -0.3 }],
      words: words([['My', 2, 2.2], ['Bosch', 2.2, 2.5], ['dishwasher', 2.5, 2.8], ['is', 2.8, 2.9], ['broken', 2.9, 3]]),
    },
    1: {
      segments: [{ start: 0, end: 1, text: 'FixApplianceCA, this is Sarah.', avg_logprob: -0.3 }],
      words: words([['FixApplianceCA', 0, 0.5], ['this', 0.5, 0.7], ['is', 0.7, 0.8], ['Sarah', 0.8, 1]]),
    },
  };
  const transcriber = createCallTranscriber({
    apiKey: 'test-key',
    fetchImpl: async (url, options) => {
      const name = options.body.get('file').name;
      calls.push({ url, name, prompt: options.body.get('prompt'), language: options.body.get('language') });
      return new Response(JSON.stringify(answers[name.startsWith('call-0') ? 0 : 1]), { status: 200 });
    },
  });
  const result = await transcriber.transcribeDualWav(stereoWav(4, [[[2, 3]], [[0, 1]]]), {
    direction: 'inbound',
    prompt: 'Bosch, Stratford',
    labels: { shop: 'AI', client: 'Client' },
  });
  assert.equal(calls.length, 2);
  assert.ok(calls.every((call) => call.prompt === 'Bosch, Stratford' && call.language === 'en'));
  assert.equal(result.shopChannel, 1);
  assert.equal(result.text, 'AI: FixApplianceCA, this is Sarah.\nClient: My Bosch dishwasher is broken.');
});

test('длинная запись режется на куски, и время реплик остаётся сквозным', async () => {
  const transcriber = createCallTranscriber({
    apiKey: 'test-key',
    fetchImpl: async (_, options) => {
      const name = options.body.get('file').name;
      const [, channel, piece] = name.replace('.wav', '').split('-');
      return new Response(JSON.stringify({
        segments: [{ start: 1, end: 2, text: `ch${channel}p${piece}`, avg_logprob: -0.3 }],
        words: words([[`ch${channel}p${piece}`, 1, 2]]),
      }), { status: 200 });
    },
  });
  const seconds = 1300;
  const result = await transcriber.transcribeDualWav(stereoWav(seconds, [[[0, seconds]], [[0, seconds]]]), {
    direction: 'outbound',
  });
  assert.deepEqual(result.turns.map((turn) => Math.round(turn.start)), [1, 1, 601, 601, 1201, 1201]);
  assert.deepEqual(
    result.turns.map((turn) => `${turn.who}:${turn.text}`),
    ['shop:ch0p0', 'client:ch1p0', 'shop:ch0p600', 'client:ch1p600', 'shop:ch0p1200', 'client:ch1p1200']
  );
});
