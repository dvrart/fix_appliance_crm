// Расшифровка записи звонка по каналам.
//
// Twilio пишет разговор в две дорожки (`channels="dual"`), поэтому угадывать,
// кто сейчас говорит, не нужно: канал и есть говорящий. Раньше вся запись
// одним куском уходила в Gemini с просьбой «напиши, кто что сказал», и модель
// и слышала хуже (смешанные голоса), и реплики путала. Здесь каждая дорожка
// распознаётся отдельно, а порядок реплик берётся из отметок времени.
//
// Весь разбор WAV — на чистом Node: запись приходит 8 кГц 16 бит PCM, ffmpeg
// в Cloud Functions нет и не нужен.

const { wavFromPcm16 } = require('./audio_codec');

const SPEECH_GAP_SECONDS = 0.8;
// Пауза внутри своей же реплики, когда собеседник молчал: «Стратфорд… Онтарио»
// — это одна фраза, а не две строки в расшифровке.
const TURN_MERGE_SECONDS = 3;
const CHUNK_SECONDS = 600;
const SILENCE_RMS = 0.004;

/** Разбирает WAV: заголовок переменной длины, нужны формат и сами отсчёты. */
function parseWav(buffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer || []);
  if (buf.length < 44 || buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('Not a WAV recording');
  }
  let offset = 12;
  let fmt = null;
  let data = null;
  while (offset + 8 <= buf.length) {
    const id = buf.toString('ascii', offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const body = buf.subarray(offset + 8, Math.min(buf.length, offset + 8 + size));
    if (id === 'fmt ' && body.length >= 16) {
      fmt = {
        format: body.readUInt16LE(0),
        channels: body.readUInt16LE(2),
        rate: body.readUInt32LE(4),
        bits: body.readUInt16LE(14),
      };
    } else if (id === 'data') {
      data = body;
    }
    offset += 8 + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('WAV has no fmt/data chunk');
  if (fmt.format !== 1 || fmt.bits !== 16) throw new Error('WAV is not 16-bit PCM');
  const frameBytes = (fmt.bits / 8) * fmt.channels;
  return {
    ...fmt,
    data,
    frames: Math.floor(data.length / frameBytes),
    duration: Math.floor(data.length / frameBytes) / fmt.rate,
  };
}

/** Одна дорожка как самостоятельный WAV: именно его и принимает OpenAI. */
function channelWav(wav, channel, fromSecond = 0, toSecond = Infinity) {
  const bytes = wav.bits / 8;
  const start = Math.max(0, Math.floor(fromSecond * wav.rate));
  const end = Math.min(wav.frames, Math.ceil(Math.min(toSecond, wav.duration) * wav.rate));
  const count = Math.max(0, end - start);
  const pcm = Buffer.alloc(count * bytes);
  const take = Math.min(channel, wav.channels - 1);
  for (let i = 0; i < count; i++) {
    wav.data.copy(pcm, i * bytes, ((start + i) * wav.channels + take) * bytes, ((start + i) * wav.channels + take) * bytes + bytes);
  }
  return wavFromPcm16(pcm, wav.rate);
}

/** Громкость куска дорожки, 0..1. Нужна, чтобы отличить речь от тишины. */
function channelEnergy(wav, channel, fromSecond, toSecond) {
  const bytes = wav.bits / 8;
  const take = Math.min(channel, wav.channels - 1);
  const start = Math.max(0, Math.floor(fromSecond * wav.rate));
  const end = Math.min(wav.frames, Math.ceil(toSecond * wav.rate));
  if (end <= start) return 0;
  let sum = 0;
  const step = Math.max(1, Math.floor((end - start) / 4000));
  let count = 0;
  for (let i = start; i < end; i += step) {
    const sample = wav.data.readInt16LE((i * wav.channels + take) * bytes) / 32768;
    sum += sample * sample;
    count += 1;
  }
  return count ? Math.sqrt(sum / count) : 0;
}

function normalizedLine(text) {
  return String(text || '').toLowerCase().replace(/[^a-z0-9а-яё]+/gi, ' ').trim();
}

/**
 * Whisper на тишине склонен досочинять («Bye. Bye. Bye.», «Thank you for
 * watching»), поэтому реплику выкидываем, если в этом месте дорожки тихо.
 * Решает именно громкость, а не `no_speech_prob`: на живых репликах, вокруг
 * которых много тишины, модель ставит ему 0,7–0,86 и честный разбор адреса
 * вылетал целиком.
 */
function keepSegment(segment, energy) {
  const text = String(segment.text || '').trim();
  if (!text) return false;
  if (energy < SILENCE_RMS) return false;
  const noSpeech = Number(segment.no_speech_prob || 0);
  const logprob = Number(segment.avg_logprob || 0);
  if (noSpeech > 0.9 && energy < 0.02) return false;
  if (logprob < -1.1) return false;
  return true;
}

/**
 * Распознавание сорвалось в петлю. Со словарём-подсказкой Whisper на дорожке
 * клиента выдал 202 сегмента «Hello?» подряд вместо разговора, и настоящие
 * реплики — имя, адрес, описание поломки — пропали целиком (живой звонок
 * 07.10.2026). Петля видна сразу: почти все сегменты — одна короткая фраза.
 */
function looksRepetitive(segments) {
  const texts = (segments || []).map((item) => normalizedLine(item.text)).filter(Boolean);
  if (texts.length < 8) return false;
  const counts = new Map();
  for (const text of texts) counts.set(text, (counts.get(text) || 0) + 1);
  const top = Math.max(...counts.values());
  return top / texts.length >= 0.6;
}

/** Сколько в ответе разного текста: петля из одной фразы даёт почти ноль. */
function uniqueTextLength(segments) {
  const seen = new Set();
  for (const item of segments || []) {
    const text = normalizedLine(item.text);
    if (text) seen.add(text);
  }
  return [...seen].join(' ').length;
}

function timed(item) {
  // Длинная запись режется на куски, поэтому отметка времени у сегмента своя
  // для каждого куска: сдвиг едет вместе с ним.
  const offset = Number(item.offset || 0);
  const start = Number(item.start || 0) + offset;
  return { start, end: Number(item.end ?? item.start ?? 0) + offset };
}

function liveSegments(segments, wav, channel) {
  const kept = [];
  let repeats = 0;
  for (const segment of segments || []) {
    const { start, end } = timed(segment);
    if (!keepSegment(segment, channelEnergy(wav, channel, start, end))) continue;
    const text = String(segment.text || '').trim();
    const last = kept[kept.length - 1];
    if (last && normalizedLine(last.text) === normalizedLine(text)) {
      repeats += 1;
      if (repeats >= 2) continue;
    } else {
      repeats = 0;
    }
    kept.push({ start, end, text });
  }
  return kept;
}

/**
 * Границы реплик даёт разметка по словам, а знаки препинания и заглавные
 * буквы — сегменты того же ответа модели. Слова и сегменты получены одним
 * проходом, поэтому идут в одном порядке: совмещаем их двумя указателями, а
 * на расхождении оставляем само слово.
 */
function punctuatedWords(words, segments) {
  const tokens = segments.flatMap((segment) => segment.text.trim().split(/\s+/).filter(Boolean));
  const out = [];
  let index = 0;
  for (let i = 0; i < words.length; ) {
    let matched = false;
    for (let look = index; look < Math.min(tokens.length, index + 3) && !matched; look++) {
      const token = normalizedLine(tokens[look]);
      // Один знак препинания может склеить несколько слов разметки:
      // «519-503-7091» против «519», «503», «7091»; «o'clock» против «o clock».
      for (let span = 1; span <= 4 && i + span <= words.length; span++) {
        const joined = normalizedLine(words.slice(i, i + span).map((word) => word.text).join(' '));
        if (token !== joined) continue;
        out.push({ ...words[i], text: tokens[look], end: words[i + span - 1].end });
        index = look + 1;
        i += span;
        matched = true;
        break;
      }
    }
    if (!matched) {
      out.push(words[i]);
      i += 1;
    }
  }
  return out;
}

/** Слово засчитывается, только если попало в живой сегмент этой дорожки. */
function wordsInsideSegments(words, segments) {
  return words.filter((word) =>
    segments.some((segment) => word.start >= segment.start - 0.25 && word.start <= segment.end + 0.25)
  );
}

function wordsToTurns(words, who, gap = SPEECH_GAP_SECONDS) {
  const turns = [];
  for (const word of words) {
    const last = turns[turns.length - 1];
    if (last && word.start - last.end <= gap) {
      last.text = `${last.text} ${word.text}`.trim();
      last.end = word.end;
      continue;
    }
    turns.push({ who, start: word.start, end: word.end, text: word.text });
  }
  return turns;
}

function channelTurns({ segments, words, wav, channel, who }) {
  const kept = liveSegments(segments, wav, channel);
  if (!kept.length) return [];
  const timedWords = (words || []).map((word) => ({ ...timed(word), text: String(word.word || word.text || '') }));
  if (!timedWords.length) {
    return kept.map((segment) => ({ who, start: segment.start, end: segment.end, text: segment.text }));
  }
  return wordsToTurns(punctuatedWords(wordsInsideSegments(timedWords, kept), kept), who);
}

/** Сводит две дорожки в один разговор по времени начала реплики. */
function mergeTurns(lists) {
  const all = lists.flat().sort((a, b) => a.start - b.start || a.end - b.end);
  const out = [];
  for (const turn of all) {
    const last = out[out.length - 1];
    if (last && last.who === turn.who && turn.start - last.end <= TURN_MERGE_SECONDS) {
      last.text = `${last.text} ${turn.text}`.trim();
      last.end = Math.max(last.end, turn.end);
      continue;
    }
    out.push({ ...turn });
  }
  return out;
}

function dialogText(turns, labels) {
  return turns
    .map((turn) => `${labels[turn.who] || turn.who}: ${turn.text}`)
    .join('\n')
    .trim();
}

/**
 * Какая дорожка наша. По умолчанию это решает направление звонка: у входящих
 * первая дорожка — звонящий, у исходящих — мы. Но склейка конференций иногда
 * меняет порядок, поэтому текст ещё и проверяется по фразам мастерской: если
 * «вторая» дорожка явно ведёт приём, каналы меняются местами.
 */
const SHOP_CUES = [
  /fix\s*appliance/i, /this is sarah/i, /\btechnician\b/i, /appliance repair/i,
  /how can i help/i, /what'?s the address/i, /model sticker/i, /service call/i,
  /i'?ll let the (tech|technician)/i, /have a good day/i, /\bdispatch\b/i,
];

function shopScore(text) {
  const raw = String(text || '');
  return SHOP_CUES.reduce((score, cue) => score + (cue.test(raw) ? 1 : 0), 0);
}

function pickShopChannel({ direction, left, right }) {
  const leftScore = shopScore(left);
  const rightScore = shopScore(right);
  if (leftScore !== rightScore) return leftScore > rightScore ? 0 : 1;
  return direction === 'outbound' ? 0 : 1;
}

function createCallTranscriber({ apiKey, fetchImpl = fetch, model = 'whisper-1', timeoutMs = 120000 }) {
  async function transcribeChannel(buffer, name, prompt) {
    const form = new FormData();
    form.append('file', new Blob([buffer], { type: 'audio/wav' }), name);
    form.append('model', model);
    form.append('response_format', 'verbose_json');
    form.append('timestamp_granularities[]', 'segment');
    form.append('timestamp_granularities[]', 'word');
    form.append('language', 'en');
    form.append('temperature', '0');
    if (prompt) form.append('prompt', prompt);
    const response = await fetchImpl('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`OpenAI transcription HTTP ${response.status}: ${text.slice(0, 200)}`);
    const json = JSON.parse(text);
    return {
      segments: Array.isArray(json.segments) ? json.segments : [],
      words: Array.isArray(json.words) ? json.words : [],
    };
  }

  /**
   * Словарь-подсказка правит марки и названия городов, но иногда стоит дороже,
   * чем помогает: распознавание уходит в петлю и теряет всю дорожку. Поймали —
   * переспрашиваем ту же дорожку без подсказки и берём вариант осмысленнее.
   */
  async function transcribeChannelSafely(buffer, name, prompt) {
    const first = await transcribeChannel(buffer, name, prompt);
    if (!prompt || !looksRepetitive(first.segments)) return first;
    console.warn(
      `transcribe ${name}: подсказка загнала распознавание в петлю ` +
        `(${first.segments.length} сегментов, разного текста ${uniqueTextLength(first.segments)} симв.) — повторяю без неё`
    );
    const retry = await transcribeChannel(buffer, name, '');
    return uniqueTextLength(retry.segments) > uniqueTextLength(first.segments) ? retry : first;
  }

  /**
   * Возвращает реплики обеих сторон по порядку. Если дорожка одна, вызывающий
   * код должен остаться на прежнем пути: здесь кидаем ошибку, а не гадаем.
   */
  async function transcribeDualWav(wavBuffer, { direction = 'inbound', prompt = '', labels = {} } = {}) {
    if (!apiKey) throw new Error('OPENAI_API_KEY не настроен');
    const wav = parseWav(wavBuffer);
    if (wav.channels < 2) throw new Error('Recording is not dual-channel');
    const pieces = [];
    for (let from = 0; from < wav.duration; from += CHUNK_SECONDS) {
      pieces.push({ from, to: Math.min(wav.duration, from + CHUNK_SECONDS) });
    }
    const perChannel = [{ segments: [], words: [] }, { segments: [], words: [] }];
    for (const piece of pieces) {
      const heard = await Promise.all([0, 1].map((channel) =>
        transcribeChannelSafely(
          channelWav(wav, channel, piece.from, piece.to),
          `call-${channel}-${Math.round(piece.from)}.wav`,
          prompt
        )
      ));
      heard.forEach((part, channel) => {
        perChannel[channel].segments.push(...part.segments.map((item) => ({ ...item, offset: piece.from })));
        perChannel[channel].words.push(...part.words.map((item) => ({ ...item, offset: piece.from })));
      });
    }
    const rawText = perChannel.map((part) => part.segments.map((item) => item.text).join(' '));
    const shopChannel = pickShopChannel({ direction, left: rawText[0], right: rawText[1] });
    const turns = mergeTurns([0, 1].map((channel) =>
      channelTurns({
        segments: perChannel[channel].segments,
        words: perChannel[channel].words,
        wav,
        channel,
        who: channel === shopChannel ? 'shop' : 'client',
      })
    ));
    return {
      turns,
      shopChannel,
      duration: wav.duration,
      text: dialogText(turns, { shop: labels.shop || 'AI', client: labels.client || 'Client' }),
    };
  }

  return { transcribeDualWav };
}

module.exports = {
  parseWav,
  channelWav,
  channelEnergy,
  channelTurns,
  liveSegments,
  looksRepetitive,
  punctuatedWords,
  wordsToTurns,
  mergeTurns,
  dialogText,
  pickShopChannel,
  shopScore,
  createCallTranscriber,
  SPEECH_GAP_SECONDS,
  TURN_MERGE_SECONDS,
  CHUNK_SECONDS,
};
