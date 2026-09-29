/**
 * Ссылки в SMS и запасной текст без ссылки.
 *
 * Канадские операторы режут A2P-ссылки с локального длинного номера — Twilio
 * отдаёт `undelivered` 30007 «Message filtered». Живой замер 21.09.2026 на
 * +1 250…5149, один и тот же короткий текст:
 *
 *   https://fix-appliance.ca/review .......... undelivered 30007
 *   без ссылки ............................... delivered
 *   …cloudfunctions.net/p/review ............. delivered
 *   https://www.google.com/maps/place/… ...... delivered
 *
 * Плюс история за месяц: g.page 4 доставлено / 11 зарезано,
 * firebasestorage.googleapis.com 12 / 0. Вывод: проходят только google-хосты.
 *
 * Поэтому ссылка на отзыв уходит в SMS через наш редирект на google-хосте
 * (`short_links.js`, код `review`), а в запасе лежит `fallbackBody` без
 * ссылки вообще — его шлёт `smsStatusCallback`, когда приходит 30007.
 */

const FILTERED_LINK_HOSTS = new Set([
  'g.page',
  'goo.gl',
  'maps.app.goo.gl',
  'bit.ly',
  'tinyurl.com',
  't.co',
  'ow.ly',
  'cutt.ly',
  'rebrand.ly',
  'is.gd',
  'buff.ly',
  'lnkd.in',
  'shorturl.at',
]);

const URL_RE = /https?:\/\/[^\s<>()]+/gi;

function hostOf(url) {
  try {
    return new URL(String(url).replace(/[.,!?;:]+$/, ''))
      .host.toLowerCase()
      .replace(/^www\./, '');
  } catch (_) {
    return '';
  }
}

/** Ссылка на сокращателе, который операторы режут чаще всего. */
function isFilteredLink(url) {
  return FILTERED_LINK_HOSTS.has(hostOf(url));
}

/** Есть ли в тексте ссылка на отзыв: та, что в настройках, или сокращатель. */
function hasReviewLink(text, reviewUrl) {
  const body = String(text || '');
  const target = String(reviewUrl || '').trim();
  if (target && body.includes(target)) return true;
  return (body.match(URL_RE) || []).some(isFilteredLink);
}

function searchHint(company) {
  const name = String(company || '').trim();
  return name
    ? `Search ${name} on Google and leave a review.`
    : 'Search our shop on Google and leave a review.';
}

/**
 * Запасной текст, когда оператор зарезал основной. Нарочно короткий, без
 * ссылки, без рядов эмодзи: замер показал, что промо-блок на 431 символ
 * (`⭐️⭐️⭐️⭐️⭐️`, «supporting our small business ❤️») режется и без ссылки,
 * а короткое человеческое сообщение проходит.
 * Пустая строка — если в тексте нет ссылки на отзыв, то есть менять нечего.
 */
function reviewFallbackBody(text, { reviewUrl, company } = {}) {
  const body = String(text || '');
  if (!hasReviewLink(body, reviewUrl)) return '';
  const name = String(company || '').trim();
  const thanks = name
    ? `Thank you for choosing ${name}.`
    : 'Thank you for choosing us.';
  return `Your repair is complete. ${thanks}\nIf you have a minute, ${searchHint(company)}`;
}

/** Меняет ссылку на отзыв на ту, что операторы пропускают. */
function replaceReviewLink(text, { reviewUrl, safeUrl } = {}) {
  const body = String(text || '');
  const safe = String(safeUrl || '').trim();
  if (!safe) return body;
  const target = String(reviewUrl || '').trim();
  const swapped = target ? body.split(target).join(safe) : body;
  return swapped.replace(URL_RE, (url) => (isFilteredLink(url) ? safe : url));
}

/**
 * Наш редирект на google-хосте: `…cloudfunctions.net/p/review` → ссылка из
 * настроек. Код всегда `review`, поэтому адрес стабильный, а цель можно
 * поменять в настройках в любой момент.
 */
async function carrierSafeReviewUrl(reviewUrl) {
  const target = String(reviewUrl || '').trim();
  if (!/^https?:\/\//i.test(target)) return '';
  try {
    // Лениво: чистый модуль не должен тянуть firebase ради тестов.
    const { ensureShortLink } = require('./short_links');
    const link = await ensureShortLink({
      url: target,
      code: 'review',
      type: 'review',
      reserveCode: true,
    });
    return String((link && link.carrierUrl) || '');
  } catch (error) {
    console.warn('carrierSafeReviewUrl:', error.message);
    return '';
  }
}

/**
 * Готовит SMS с просьбой об отзыве: ссылка → на google-хост, плюс запасной
 * текст без ссылки. Тексты без ссылки на отзыв возвращаются как есть.
 */
async function prepareReviewSms(body, { reviewUrl, company } = {}) {
  const text = String(body || '');
  if (!hasReviewLink(text, reviewUrl)) return { body: text, fallbackBody: '' };
  const safeUrl = await carrierSafeReviewUrl(reviewUrl);
  const swapped = replaceReviewLink(text, { reviewUrl, safeUrl });
  return {
    body: swapped,
    fallbackBody: reviewFallbackBody(swapped, {
      reviewUrl: safeUrl || reviewUrl,
      company,
    }),
  };
}

module.exports = {
  FILTERED_LINK_HOSTS,
  hostOf,
  isFilteredLink,
  hasReviewLink,
  reviewFallbackBody,
  replaceReviewLink,
  carrierSafeReviewUrl,
  prepareReviewSms,
  searchHint,
};
