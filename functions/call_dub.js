// Русская озвучка записи звонка.
//
// Расшифровка уже разложена по репликам и переведена, поэтому «послушать
// разговор по-русски» — это озвучить эти реплики и склеить их в одну дорожку.
// Голоса разные: мастерская одним, клиент другим, иначе на слух не разобрать,
// кто говорит. Дорожка сводится к 8 кГц — как настоящая телефонная запись, и
// весит втрое меньше.

const { createLowPass, downsampleTo8k, wavFromPcm16 } = require('./audio_codec');

const TTS_MODEL = process.env.OPENAI_TTS_MODEL || 'gpt-4o-mini-tts';
const TTS_RATE = 24000;
const DUB_RATE = 8000;
const GAP_SECONDS = 0.35;
const PARALLEL_LINES = 10;
const MAX_LINE_CHARS = 1800;

const VOICES = {
  shop: process.env.OPENAI_TTS_VOICE_SHOP || 'sage',
  client: process.env.OPENAI_TTS_VOICE_CLIENT || 'ballad',
};
const INSTRUCTIONS = {
  shop: 'Говори по-русски спокойно и доброжелательно, как диспетчер сервиса по ремонту техники. Ровный темп, без театральности.',
  client: 'Говори по-русски обычным разговорным тоном, как человек, который звонит в сервис из дома.',
};

const SHOP_LABELS = /^(ИИ|Моё|Мое|Мастер|Секретарь|AI|Me|Master|Technician|Assistant)$/i;
const CLIENT_LABELS = /^(Клиент|Client|Caller|User)$/i;

/** Строки расшифровки «ИИ: …» / «Клиент: …» в реплики с голосом. */
function dubTurns(transcript) {
  const turns = [];
  for (const raw of String(transcript || '').split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    const match = line.match(/^([^:]{1,24}):\s*(.*)$/);
    const label = match ? match[1].trim() : '';
    const text = (match ? match[2] : line).trim();
    if (!text) continue;
    const who = CLIENT_LABELS.test(label) ? 'client' : SHOP_LABELS.test(label) ? 'shop' : '';
    const last = turns[turns.length - 1];
    // Строка без метки — продолжение предыдущей реплики, а не ничья.
    if (!who && last) {
      last.text = `${last.text} ${text}`.trim();
      continue;
    }
    turns.push({ who: who || 'shop', text: text.slice(0, MAX_LINE_CHARS) });
  }
  return turns;
}

function concatPcm(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Int16Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function pcmFromBuffer(buffer) {
  const samples = buffer.length >> 1;
  const out = new Int16Array(samples);
  for (let i = 0; i < samples; i++) out[i] = buffer.readInt16LE(i * 2);
  return out;
}

function createCallDubber({ apiKey, fetchImpl = fetch, timeoutMs = 120000 }) {
  async function speak(text, who) {
    const response = await fetchImpl('https://api.openai.com/v1/audio/speech', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: TTS_MODEL,
        voice: VOICES[who] || VOICES.shop,
        input: text,
        instructions: INSTRUCTIONS[who] || INSTRUCTIONS.shop,
        // Сырые отсчёты: склеивать mp3-куски нельзя, стыки трещат.
        response_format: 'pcm',
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`OpenAI speech HTTP ${response.status}: ${detail.slice(0, 200)}`);
    }
    return pcmFromBuffer(Buffer.from(await response.arrayBuffer()));
  }

  /**
   * Готовая дорожка на русском: WAV 8 кГц. Реплики идут подряд с короткой
   * паузой — точные паузы оригинала не повторить, озвучка всегда другой
   * длины, чем живая речь.
   */
  async function buildRussianDub(transcript) {
    if (!apiKey) throw new Error('OPENAI_API_KEY не настроен');
    const turns = dubTurns(transcript);
    if (!turns.length) throw new Error('Нет русской расшифровки для озвучки');
    // Очередь, а не пачки: короткая реплика озвучивается за секунду, длинная
    // за десять, и пачка ждала бы самую медленную.
    const spoken = new Array(turns.length);
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(PARALLEL_LINES, turns.length) }, async () => {
        while (next < turns.length) {
          const index = next++;
          spoken[index] = await speak(turns[index].text, turns[index].who);
        }
      })
    );
    const filter = createLowPass(TTS_RATE);
    const gap = new Int16Array(Math.round(DUB_RATE * GAP_SECONDS));
    const pieces = [];
    let leftover = new Int16Array(0);
    for (const pcm of spoken) {
      const down = downsampleTo8k(pcm, TTS_RATE, leftover, filter);
      leftover = down.leftover;
      pieces.push(down.pcm8, gap);
    }
    return {
      wav: wavFromPcm16(concatPcm(pieces), DUB_RATE),
      turns: turns.length,
      seconds: pieces.reduce((sum, part) => sum + part.length, 0) / DUB_RATE,
    };
  }

  return { buildRussianDub };
}

module.exports = { dubTurns, createCallDubber, VOICES, DUB_RATE, GAP_SECONDS };
