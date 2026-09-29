/**
 * Картинка запчасти из интернета.
 *
 * Приложение шлёт номер детали и название, функция ищет в картинках Bing
 * (запасной источник — DuckDuckGo), скачивает несколько кандидатов, показывает
 * их Gemini и спрашивает, на каком снят именно этот узел. Победителя кладём в
 * Storage и отдаём ссылку: на телефоне хотлинк с чужого сайта часто не грузится,
 * а своя ссылка живёт вечно и работает из кэша.
 *
 * Ничего не найдено — отвечаем success:true, imageUrl:null. Склад должен
 * сохраняться и без картинки.
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const crypto = require('crypto');
const { requireAppUser } = require('./auth_guard');

const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

// Магазины запчастей: их снимок почти всегда «деталь на белом фоне».
const GOOD_HOSTS = [
  'partselect',
  'repairclinic',
  'appliancepartspros',
  'searspartsdirect',
  'partsdr',
  'reliableparts',
  'encompass',
  'marcone',
  'ereplacementparts',
  'appliancefactoryparts',
  'appliancepartscanada',
  'coastparts',
  'partswarehouse',
  'genuinereplacementparts',
  'homedepot',
  'lowes',
  'amazon',
  'walmart',
  'ebayimg',
  'shopify',
];

// Хотлинк оттуда либо запрещён, либо это не фото детали.
const BAD_HOSTS = [
  'pinterest',
  'pinimg',
  'facebook',
  'fbsbx',
  'instagram',
  'youtube',
  'ytimg',
  'tiktok',
  'bing.com',
  'bing.net',
  'gstatic',
  'wikipedia',
  'wikimedia',
];

const BAD_WORDS = [
  'logo',
  'sprite',
  'icon',
  'placeholder',
  'no-image',
  'noimage',
  'banner',
  'avatar',
  'thumb_',
];

function normalizePart(value) {
  return String(value || '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

function decodeEntities(text) {
  return String(text || '')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch (_) {
    return '';
  }
}

/** Что спрашиваем у поиска: сперва точный номер, потом номер + название. */
function pickQueries({ partNumber, name, brand, model }) {
  const part = String(partNumber || '').trim();
  const words = String(name || '').trim();
  const make = String(brand || '').trim();
  const queries = [];
  if (part) {
    queries.push(`"${part}" appliance part`);
    if (words) queries.push(`${part} ${words}`);
    queries.push(part);
  }
  if (!part && words) {
    queries.push(`${make} ${words} appliance part`.trim());
  }
  if (!part && !words && model) queries.push(`${model} appliance part`);
  return [...new Set(queries.filter(Boolean))].slice(0, 3);
}

/** Ссылки на картинки из выдачи Bing. Данные лежат в атрибуте m="{json}". */
function parseBingImages(html) {
  const out = [];
  const re = /m="([^"]+)"/g;
  let match;
  while ((match = re.exec(String(html || ''))) !== null) {
    const raw = decodeEntities(match[1]);
    if (!raw.includes('murl')) continue;
    let data;
    try {
      data = JSON.parse(raw);
    } catch (_) {
      continue;
    }
    const image = String(data.murl || '').trim();
    if (!image) continue;
    out.push({
      image,
      page: String(data.purl || '').trim(),
      title: String(data.t || '').trim(),
    });
    if (out.length >= 40) break;
  }
  return out;
}

/** Ссылки на картинки из DuckDuckGo (json-ответ i.js). */
function parseDuckImages(payload) {
  const rows = payload && Array.isArray(payload.results) ? payload.results : [];
  return rows
    .map((row) => ({
      image: String((row && row.image) || '').trim(),
      page: String((row && row.url) || '').trim(),
      title: String((row && row.title) || '').trim(),
    }))
    .filter((row) => row.image)
    .slice(0, 40);
}

/**
 * Оценка кандидата: чем выше, тем больше похоже на фото нужной детали.
 * Отрицательная — выбрасываем.
 */
function scoreCandidate(candidate, { part, name }) {
  const image = String(candidate.image || '');
  const low = image.toLowerCase();
  const host = hostOf(image).toLowerCase();
  if (!/^https?:\/\//i.test(image)) return -1;
  if (/\.(svg|gif|bmp|ico)(\?|$)/i.test(low)) return -1;
  if (BAD_HOSTS.some((bad) => host.includes(bad))) return -1;
  if (BAD_WORDS.some((bad) => low.includes(bad))) return -1;

  let score = 0;
  if (GOOD_HOSTS.some((good) => host.includes(good))) score += 30;
  const wanted = normalizePart(part);
  if (wanted.length >= 4) {
    if (normalizePart(image).includes(wanted)) score += 40;
    if (normalizePart(candidate.page).includes(wanted)) score += 25;
    if (normalizePart(candidate.title).includes(wanted)) score += 15;
  }
  const first = String(name || '')
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word.length > 3)[0];
  if (first && String(candidate.title || '').toLowerCase().includes(first)) {
    score += 8;
  }
  if (/\.(jpg|jpeg|png|webp)(\?|$)/i.test(low)) score += 5;
  return score;
}

/** Убираем повторы по хосту и имени файла, оставляем лучшие. */
function rankCandidates(rows, { part, name, skip = [] }) {
  const skipSet = new Set(skip.map((url) => String(url || '').trim()));
  const seen = new Set();
  const scored = [];
  for (const row of rows) {
    if (skipSet.has(row.image)) continue;
    const score = scoreCandidate(row, { part, name });
    if (score < 0) continue;
    const key = `${hostOf(row.image)}|${row.image.split('/').pop()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    scored.push({ ...row, score });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored;
}

/**
 * Каталог запчастей Home Depot Canada — поиск по точному номеру детали.
 *
 * Главный источник. Картинки из Bing зависят от того, что поисковик решит
 * показать нашему IP: с сервера в выдачу приезжали часы и фигурки, и ИИ честно
 * браковал всё подряд. Здесь же адрес строится от самого номера, поэтому
 * приходит именно та деталь.
 *
 * Одно совпадение — сайт сразу редиректит на карточку товара, несколько —
 * отдаёт список плиток. Разбираем оба случая.
 */
async function searchApplianceParts(part) {
  const wanted = normalizePart(part);
  if (wanted.length < 4) return [];
  const res = await fetch(
    `https://applianceparts.homedepot.ca/search?q=${encodeURIComponent(part)}`,
    {
      headers: { 'User-Agent': BROWSER_UA, Accept: 'text/html' },
      signal: AbortSignal.timeout(12000),
    }
  );
  if (!res.ok) throw new Error(`homedepot ${res.status}`);
  const html = await res.text();
  return parseApplianceParts(html, res.url, part);
}

/** Плитки каталога → ссылки на большие картинки. */
function parseApplianceParts(html, finalUrl, part) {
  const site = 'https://applianceparts.homedepot.ca';
  const wanted = normalizePart(part);
  const text = String(html || '');
  const big = (imageId) =>
    `${site}/thumbnail/product/${imageId}/1600/1200/${encodeURIComponent(part)}.jpg`;

  // Карточка товара: сайт сам увёл на неё, значит номер совпал точно.
  if (/\/product\//.test(String(finalUrl || '')) && normalizePart(text).includes(wanted)) {
    const image = text.match(/thumbnail\/product\/(\d+)/);
    if (image) {
      const title = (text.match(/<title>([^<]{0,120})/i) || ['', ''])[1].trim();
      return [{ image: big(image[1]), page: String(finalUrl), title }];
    }
  }

  // Список: у каждой плитки свой номер детали в скрипте рядом.
  const labels = new Map();
  const labelRe =
    /product(\d+)\.partNumber\s*=\s*"([^"]+)"[\s\S]{0,300}?product\1\.url\s*=\s*"\/product\/(\d+)"/g;
  for (const row of text.matchAll(labelRe)) {
    labels.set(row[3], row[2]);
  }
  const tileRe =
    /href="[^"]*\/product\/(\d+)"[^>]*class="product-image"[^>]*thumbnail\/product\/(\d+)\//g;
  const rows = [];
  for (const tile of text.matchAll(tileRe)) {
    const label = labels.get(tile[1]) || '';
    // Похожие товары в выдаче не нужны: берём только точный номер.
    if (label && !normalizePart(label).includes(wanted)) continue;
    rows.push({
      image: big(tile[2]),
      page: `${site}/product/${tile[1]}`,
      title: label,
    });
    if (rows.length >= 4) break;
  }
  return rows;
}

async function searchBing(query) {
  const url = `https://www.bing.com/images/search?q=${encodeURIComponent(
    query
  )}&form=HDRSC2&first=1`;
  const res = await fetch(url, {
    headers: {
      'User-Agent': BROWSER_UA,
      'Accept-Language': 'en-CA,en;q=0.9',
      Accept: 'text/html',
    },
    signal: AbortSignal.timeout(12000),
  });
  if (!res.ok) throw new Error(`bing ${res.status}`);
  return parseBingImages(await res.text());
}

async function searchDuck(query) {
  const q = encodeURIComponent(query);
  const first = await fetch(`https://duckduckgo.com/?q=${q}&iax=images&ia=images`, {
    headers: { 'User-Agent': BROWSER_UA, Accept: 'text/html' },
    signal: AbortSignal.timeout(12000),
  });
  const html = await first.text();
  const token = html.match(/vqd=["']?([\d-]{8,})["']?/);
  if (!token) throw new Error('duck: no vqd');
  const api =
    `https://duckduckgo.com/i.js?l=us-en&o=json&q=${q}` +
    `&vqd=${token[1]}&f=,,,&p=1`;
  const res = await fetch(api, {
    headers: {
      'User-Agent': BROWSER_UA,
      Accept: 'application/json',
      Referer: 'https://duckduckgo.com/',
    },
    signal: AbortSignal.timeout(12000),
  });
  if (!res.ok) throw new Error(`duck ${res.status}`);
  return parseDuckImages(await res.json());
}

/** Скачать картинку. null — не картинка, слишком мелкая или не отдалась. */
async function downloadImage(url) {
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': BROWSER_UA, Accept: 'image/*' },
      signal: AbortSignal.timeout(9000),
    });
    if (!res.ok) return null;
    const mime = String(res.headers.get('content-type') || '')
      .split(';')[0]
      .trim()
      .toLowerCase();
    if (!/^image\/(jpeg|jpg|png|webp)$/.test(mime)) return null;
    const buffer = Buffer.from(await res.arrayBuffer());
    // Меньше 8 КБ — это значок или заглушка, а не снимок детали.
    if (buffer.length < 8 * 1024 || buffer.length > 8 * 1024 * 1024) return null;
    return { buffer, mime: mime === 'image/jpg' ? 'image/jpeg' : mime };
  } catch (_) {
    return null;
  }
}

function extensionFor(mime) {
  if (mime === 'image/png') return 'png';
  if (mime === 'image/webp') return 'webp';
  return 'jpg';
}

/**
 * Показать снимки Gemini и выбрать лучший.
 *
 * Важно: узнать деталь «в лицо» по номеру модель не может, и когда её об этом
 * просили, она честно отвечала 0 — поиск не находил вообще ничего. Совпадение
 * номера обеспечивает сам поиск (номер стоит в адресе картинки и страницы),
 * а у ИИ спрашиваем другое: где тут нормальное фото детали, а где схема,
 * текст, логотип или целая машина.
 */
async function askGemini(images, context, generateContentWithModelFallback) {
  const { partNumber, name, brand } = context;
  const prompt = `You pick photos for an appliance-parts shop inventory card.

All ${images.length} pictures below were found by a web search for this spare part:
part number ${partNumber || '(unknown)'}, name ${name || '(unknown)'}, brand ${
    brand || '(unknown)'
  }.
The search already matched the number, so do NOT try to verify the number yourself.
Your only job is to throw out junk pictures and pick the best product photo.

Reject a picture if it is:
- a wiring diagram, schematic or exploded parts drawing;
- a page of text, a table, a screenshot or a web page;
- only a logo, a watermark or a brand banner;
- the whole appliance instead of the part;
- a person, a hand holding nothing, or an installation scene where the part is not clear;
- a collage of many different parts;
- too blurry or too dark to see the part.

Among the rest pick the clearest single part, preferably on a plain background.
Answer 0 only if every picture must be rejected.

Return ONLY JSON, no prose:
{"best": <1-${images.length} or 0>, "why": "<до 4 слов по-русски: что на фото>"}`;

  const parts = [{ text: prompt }];
  images.forEach((image, index) => {
    parts.push({ text: `Picture ${index + 1} (${hostOf(image.source)}):` });
    parts.push({
      inlineData: {
        mimeType: image.mime,
        data: image.buffer.toString('base64'),
      },
    });
  });

  const result = await generateContentWithModelFallback(parts);
  const raw = String((result.response && result.response.text()) || '');
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    console.warn(`findPartImage: ответ без json: ${raw.slice(0, 120)}`);
    return { best: 0, why: '' };
  }
  const parsed = JSON.parse(raw.slice(start, end + 1));
  const best = Number(parsed.best) || 0;
  return {
    best: best >= 1 && best <= images.length ? best : 0,
    why: String(parsed.why || '').trim().slice(0, 60),
  };
}

/**
 * Найти снимок детали: поиск → отбор → скачивание → выбор ИИ.
 * Возвращает `{ picked, why, reason }`; `picked` пустой — показывать нечего.
 */
async function resolvePartImage(
  { partNumber, name, brand, model, skip = [] },
  { generateContentWithModelFallback }
) {
  // Качаем немного: каждый файл — это секунды и мегабайты.
  async function load(rows) {
    const ranked = rankCandidates(rows, { part: partNumber, name, skip });
    const images = [];
    for (const candidate of ranked) {
      if (images.length >= 4) break;
      const file = await downloadImage(candidate.image);
      if (!file) continue;
      // Gemini получает только разумные по весу снимки.
      if (file.buffer.length > 3 * 1024 * 1024) continue;
      images.push({
        ...file,
        source: candidate.image,
        page: candidate.page,
        score: candidate.score,
      });
    }
    return { ranked: ranked.length, images };
  }

  // Каталог по точному номеру — первым. Он не зависит от того, что поисковик
  // решит показать нашему серверу.
  let source = 'каталог';
  let found = [];
  if (partNumber) {
    try {
      found = await searchApplianceParts(partNumber);
    } catch (error) {
      console.warn(`findPartImage каталог "${partNumber}": ${error.message}`);
    }
  }
  let { ranked, images } = await load(found);

  if (!images.length) {
    source = 'поиск';
    const queries = pickQueries({ partNumber, name, brand, model });
    const rows = [];
    for (const query of queries) {
      let batch = [];
      try {
        batch = await searchBing(query);
      } catch (error) {
        console.warn(`findPartImage bing "${query}": ${error.message}`);
      }
      if (!batch.length) {
        try {
          batch = await searchDuck(query);
        } catch (error) {
          console.warn(`findPartImage duck "${query}": ${error.message}`);
        }
      }
      rows.push(...batch);
      if (rows.length >= 12) break;
    }
    ({ ranked, images } = await load(rows));
  }

  images.forEach((image, index) =>
    console.log(
      `findPartImage кандидат ${index + 1} (${image.score}) ${image.source.slice(0, 110)}`
    )
  );

  if (!images.length) {
    return {
      picked: null,
      reason: ranked ? 'Картинки не открылись' : 'Ничего не нашёл',
      ranked,
      loaded: 0,
      source,
    };
  }

  let best = 0;
  let why = '';
  try {
    const verdict = await askGemini(
      images,
      { partNumber, name, brand, model },
      generateContentWithModelFallback
    );
    best = verdict.best;
    why = verdict.why;
  } catch (error) {
    console.warn('findPartImage gemini:', error.message);
    // ИИ не ответил — берём снимок только если номер детали стоит прямо
    // в адресе картинки. Наугад класть чужое фото нельзя.
    const wanted = normalizePart(partNumber);
    const sure = images.findIndex(
      (image) => wanted.length >= 4 && normalizePart(image.source).includes(wanted)
    );
    best = sure >= 0 ? sure + 1 : 0;
    why = sure >= 0 ? 'номер детали в ссылке' : '';
  }

  console.log(
    `findPartImage part=${partNumber || name} источник=${source} ranked=${ranked} ` +
      `images=${images.length} best=${best} why=${why}`
  );

  if (!best) {
    return {
      picked: null,
      reason: 'ИИ забраковал все снимки',
      ranked,
      loaded: images.length,
      source,
    };
  }
  return { picked: images[best - 1], why, ranked, loaded: images.length, source };
}

module.exports = function createPartImageHandlers({
  setCors,
  handleOptions,
  generateContentWithModelFallback,
  companyId,
}) {
  const COMPANY_ID = companyId || 'FIX';

  function bucket() {
    const project =
      process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
    return admin.storage().bucket(`${project}.firebasestorage.app`);
  }

  async function storeImage(part, picked) {
    const safePart = (normalizePart(part) || 'part').slice(0, 24);
    const path =
      `companies/${COMPANY_ID}/warehouse/web/` +
      `${Date.now()}_${safePart}.${extensionFor(picked.mime)}`;
    const file = bucket().file(path);
    const token = crypto.randomUUID();
    await file.save(picked.buffer, {
      resumable: false,
      metadata: {
        contentType: picked.mime,
        metadata: { firebaseStorageDownloadTokens: token },
      },
    });
    return (
      `https://firebasestorage.googleapis.com/v0/b/${file.bucket.name}/o/` +
      `${encodeURIComponent(path)}?alt=media&token=${token}`
    );
  }

  async function findPartImage(req, res) {
    setCors(res);
    if (handleOptions(req, res)) return;
    if (!(await requireAppUser(req, res))) return;
    if (req.method !== 'POST') {
      res.status(405).json({ success: false, error: 'POST only' });
      return;
    }

    const body = req.body || {};
    const partNumber = String(body.partNumber || '').trim().toUpperCase();
    const name = String(body.name || '').trim();
    const brand = String(body.brand || '').trim();
    const model = String(body.model || '').trim();
    const skip = Array.isArray(body.skip) ? body.skip.map(String) : [];

    if (!partNumber && name.length < 4) {
      res.status(400).json({ success: false, error: 'Нужен номер или название детали' });
      return;
    }

    try {
      const { picked, why, reason } = await resolvePartImage(
        { partNumber, name, brand, model, skip },
        { generateContentWithModelFallback }
      );
      if (!picked) {
        res.json({ success: true, imageUrl: null, reason });
        return;
      }

      const imageUrl = await storeImage(partNumber || name, picked);
      res.json({
        success: true,
        imageUrl,
        sourceUrl: picked.page || picked.source,
        sourceHost: hostOf(picked.page || picked.source),
        originalUrl: picked.source,
        why,
      });
    } catch (error) {
      console.warn('findPartImage:', error.message);
      res.status(500).json({ success: false, error: error.message || 'search failed' });
    }
  }

  return {
    findPartImage: functions.https.onRequest(
      { timeoutSeconds: 120, memory: '1GiB', invoker: 'public' },
      findPartImage
    ),
  };
};

module.exports.internals = {
  pickQueries,
  parseBingImages,
  parseDuckImages,
  scoreCandidate,
  rankCandidates,
  normalizePart,
  hostOf,
  searchBing,
  searchDuck,
  searchApplianceParts,
  parseApplianceParts,
  downloadImage,
  askGemini,
  resolvePartImage,
};
