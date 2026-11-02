/**
 * Английский текст отчёта мастера для публичной страницы паспорта по QR.
 *
 * Отдельный модуль, а не часть `index.js`: триггер на заявки живёт в
 * `visit_sms.js`, а тот не должен тянуть `index.js` целиком (там наоборот
 * подключают visit_sms — получился бы цикл). Ключи и модели — те же, что у
 * остального перевода, читаются из окружения здесь же.
 */
const { GoogleGenerativeAI } = require('@google/generative-ai');

const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || '';
const TEXT_MODELS = [
  process.env.GEMINI_TEXT_MODEL || 'gemini-flash-lite-latest',
  'gemini-flash-latest',
];

function hasCyrillic(text) {
  return /[А-Яа-яЁё]/.test(String(text || ''));
}

function stripFences(text) {
  return String(text || '').replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
}

/** Перевод отчёта. Пустая строка — не получилось, вызывающий не пишет мусор. */
async function translateServiceReport(text) {
  const t = String(text || '').trim();
  if (!t) return '';
  if (!hasCyrillic(t)) return t;
  const instruction = 'Translate this appliance repair report into plain Canadian English '
    + 'for another technician reading the appliance\'s service record. '
    + 'Keep it factual and about the same length. Keep brand names, model and part numbers, '
    + 'and error codes unchanged. No greeting, no emoji, no quotation marks. '
    + 'Return ONLY the English text.';
  if (OPENAI_API_KEY) {
    try {
      const response = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: process.env.OPENAI_TEXT_MODEL || 'gpt-5.4-mini',
          input: `${instruction}\nReturn strict JSON {"text":"translation"}.\n\n${t}`,
          text: { format: { type: 'json_object' } },
          max_output_tokens: 2000,
        }),
        signal: AbortSignal.timeout(60000),
      });
      const raw = await response.text();
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${raw.slice(0, 200)}`);
      const body = JSON.parse(raw);
      const joined = (body.output || [])
        .flatMap((item) => (item.content || []).map((part) => part.text || ''))
        .join('')
        .trim();
      const parsed = JSON.parse(stripFences(joined));
      const out = String((parsed && parsed.text) || '').trim();
      if (out && !hasCyrillic(out)) return out;
    } catch (error) {
      console.warn('translateServiceReport OpenAI:', error.message);
    }
  }
  if (!GEMINI_API_KEY) return '';
  const genAI = new GoogleGenerativeAI(GEMINI_API_KEY);
  for (const name of TEXT_MODELS) {
    try {
      const model = genAI.getGenerativeModel({ model: name });
      const result = await model.generateContent(`${instruction}\n\n${t}`);
      const out = stripFences(result.response && result.response.text());
      if (out && !hasCyrillic(out)) return out;
    } catch (error) {
      console.warn(`translateServiceReport Gemini ${name}:`, error.message);
    }
  }
  return '';
}

module.exports = { translateServiceReport, hasCyrillic };
