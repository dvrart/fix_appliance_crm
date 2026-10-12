/**
 * Текст, который уходит клиенту. Два правила, оба из живой переписки
 * (FIX, 07.10.2026):
 *
 * 1. Никакой кириллицы. Клиент её не прочитает, а Twilio переключает такое
 *    сообщение в UCS-2, где сегмент 70 символов вместо 160 — длинный текст
 *    молча режется на части и дорожает.
 * 2. Никаких служебных заглушек вместо имени. Карточка клиента до того, как он
 *    назвал имя, называется «Клиент +14165550101» — и это имя уходило в SMS
 *    («Hi Клиент +14165550101!»). Имени нет — обращения нет вовсе: «Hi!».
 */
const voiceFacts = require('./voice_facts');

function hasCyrillic(text) {
  return /[А-Яа-яЁё]/.test(String(text || ''));
}

/**
 * Последняя страховка перед Twilio. Перевод на английский (translateChat)
 * имена не трогает — именно поэтому «Клиент» доезжал до клиента целым.
 */
function latinizeSms(text, label = 'sms') {
  const src = String(text || '');
  if (!hasCyrillic(src)) return src;
  console.warn(`${label}: кириллица в тексте клиенту — транслитерирую: ${src.slice(0, 120)}`);
  return voiceFacts.toLatin(src);
}

/** Имя для обращения в SMS: «» для заглушки, мусора и пустого значения. */
function smsName(raw) {
  const name = voiceFacts.usableClientName(raw);
  if (!name) return '';
  return voiceFacts.toLatin(name).split(/\s+/)[0] || '';
}

/**
 * Подстановка `{name}`. Без имени убираем и само обращение, и запятую перед
 * ним, иначе клиент получает «Hi !» или «Sorry to hear that, .».
 */
function fillName(template, name) {
  const text = String(template || '');
  const clean = smsName(name);
  if (clean) return text.split('{name}').join(clean);
  return text
    .replace(/[ \t]*,?[ \t]*\{name\}/g, '')
    .split('{name}')
    .join('')
    .replace(/(^|\n)[ \t]*,[ \t]*/g, '$1');
}

module.exports = { hasCyrillic, latinizeSms, smsName, fillName };
