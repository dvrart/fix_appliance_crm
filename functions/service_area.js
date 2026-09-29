/**
 * Проверка «этот адрес в зоне выезда?» для телефонного секретаря.
 *
 * Раньше зона доезжала до модели одной строкой названий, и всё, чего в строке
 * нет, звучало как отказ: живой звонок 20 сентября — «Нет, Тилсонбург не входит
 * в наш список», хотя Тилсонбург внутри нарисованного полигона. Список названий
 * никогда не будет полным: между Тилсонбургом и Брантфордом два десятка деревень.
 *
 * Здесь сервер отвечает по карте, а не по памяти: точное совпадение с городом из
 * `SERVICE_TOWNS` — сразу, всё остальное — геокодирование Google и проверка
 * попадания точки в полигон из настроек.
 */
const admin = require('firebase-admin');
const voiceFacts = require('./voice_facts.js');

const COMPANY_ID = 'fix_appliance_ca';
const GEOCODE_URL = 'https://maps.googleapis.com/maps/api/geocode/json';
const GEOCODE_TIMEOUT_MS = 6000;
const CONFIG_TTL_MS = 120000;
const CACHE_LIMIT = 200;
const MAX_HINTS = 6;

// Округ или провинция целиком — это не «деревня нашлась», это «Google сдался и
// вернул центр большой области». Такой ответ нельзя считать попаданием в зону.
const VAGUE_TYPES = new Set([
  'country',
  'administrative_area_level_1',
  'administrative_area_level_2',
  'administrative_area_level_3',
]);

let deps = {
  loadConfig: async () => {
    const snap = await admin
      .firestore()
      .collection('companies')
      .doc(COMPANY_ID)
      .collection('settings')
      .doc('config')
      .get();
    return snap.exists ? snap.data() || {} : {};
  },
  apiKey: () => process.env.GOOGLE_MAPS_API_KEY || '',
  fetchJson: async (url) => {
    const res = await fetch(url, { signal: AbortSignal.timeout(GEOCODE_TIMEOUT_MS) });
    return res.json();
  },
};

let configCache = { at: 0, area: { polygon: [], hints: [] } };
const placeCache = new Map();

function init(next = {}) {
  deps = { ...deps, ...next };
  configCache = { at: 0, area: { polygon: [], hints: [] } };
  placeCache.clear();
}

function polygonFromConfig(config) {
  const raw = config && config.servicePolygon;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((point) => point && typeof point === 'object')
    .map((point) => ({ lat: Number(point.lat), lng: Number(point.lng) }))
    .filter(
      (point) =>
        Number.isFinite(point.lat) &&
        Number.isFinite(point.lng) &&
        (point.lat !== 0 || point.lng !== 0)
    );
}

// Из подписи зоны («Ontario: Brant, Norfolk, Zorra…») получаем названия округов.
// Они и работают подсказкой геокодеру — см. `resolvePlace`.
function hintsFromLabel(label) {
  return String(label || '')
    .replace(/^[^:]*:/, '')
    .split(/[,;]/)
    .map((part) => part.trim())
    .filter((part) => part.length >= 3)
    .slice(0, MAX_HINTS);
}

async function serviceAreaConfig() {
  if (Date.now() - configCache.at < CONFIG_TTL_MS) return configCache.area;
  const config = await deps.loadConfig();
  const area = {
    polygon: polygonFromConfig(config),
    hints: hintsFromLabel(config && config.serviceAreaLabel),
  };
  configCache = { at: Date.now(), area };
  return area;
}

function knownTown(place) {
  const key = String(place || '')
    .toLowerCase()
    .replace(/[.,]/g, '')
    .replace(/\s+(ontario|on|canada)$/g, '')
    .trim();
  if (!key) return null;
  return (
    voiceFacts.SERVICE_TOWNS.find(
      (town) => town.name.toLowerCase().replace(/[.,]/g, '') === key
    ) || null
  );
}

// Ограничиваем Онтарио, иначе «Paris» уезжает во Францию.
async function geocode(address) {
  const key = deps.apiKey();
  if (!key) return null;
  const url =
    `${GEOCODE_URL}?address=${encodeURIComponent(address)}` +
    '&components=country:CA|administrative_area:ON' +
    `&key=${encodeURIComponent(key)}`;
  try {
    const body = await deps.fetchJson(url);
    const first = body && Array.isArray(body.results) ? body.results[0] : null;
    const location = first && first.geometry && first.geometry.location;
    if (!body || body.status !== 'OK' || !location) {
      if (body && body.status !== 'ZERO_RESULTS') {
        console.warn(`serviceArea geocode ${body && body.status}: ${(body && body.error_message) || ''}`);
      }
      return null;
    }
    return {
      lat: Number(location.lat),
      lng: Number(location.lng),
      label: String(first.formatted_address || address),
      vague: (first.types || []).some((type) => VAGUE_TYPES.has(type)),
    };
  } catch (error) {
    console.warn('serviceArea geocode failed:', error.message);
    return null;
  }
}

/**
 * Одноимённых деревень в Онтарио хватает: «Mount Pleasant» без подсказки уезжает
 * под Белвилл, за 300 км от зоны. Ни `bounds`, ни фильтр по округу геокодер здесь
 * не слушает — проверено запросами: единственное, что работает, это дописать округ
 * прямо в адрес. Поэтому если обычный ответ оказался вне зоны, спрашиваем ещё раз
 * с названиями округов из подписи зоны — все сразу, чтобы это был один поход в сеть,
 * и берём первый точный ответ внутри полигона.
 */
async function resolvePlace(query, area) {
  const cached = placeCache.get(query.toLowerCase());
  if (cached !== undefined) return cached;

  const plain = await geocode(query);
  let best = plain;
  const insideAlready = plain && !plain.vague && voiceFacts.pointInPolygon(plain.lat, plain.lng, area.polygon);
  if (!insideAlready && area.hints.length) {
    const tries = await Promise.all(
      area.hints.map((hint) => geocode(`${query}, ${hint}, Ontario`))
    );
    const local = tries.find(
      (found) => found && !found.vague && voiceFacts.pointInPolygon(found.lat, found.lng, area.polygon)
    );
    if (local) best = local;
  }

  if (placeCache.size >= CACHE_LIMIT) placeCache.clear();
  placeCache.set(query.toLowerCase(), best || null);
  return best || null;
}

/**
 * @param {string} place город, деревня, почтовый индекс или полный адрес.
 * @returns {{ok:boolean, inside?:boolean|null, place?:string, source?:string, say?:string, error?:string}}
 */
async function checkServiceArea(place) {
  const query = String(place || '').trim();
  if (query.length < 2) return { ok: false, error: 'no_place' };
  const area = await serviceAreaConfig();
  if (area.polygon.length < 3) {
    return {
      ok: true,
      inside: null,
      place: query,
      source: 'no_map',
      say: 'The service map is not set — take the order and let the technician confirm.',
    };
  }

  const town = knownTown(query);
  if (town) {
    return {
      ok: true,
      inside: voiceFacts.pointInPolygon(town.lat, town.lng, area.polygon),
      place: town.name,
      source: 'list',
    };
  }

  const found = await resolvePlace(query, area);
  if (!found) {
    return {
      ok: true,
      inside: null,
      place: query,
      source: 'unresolved',
      say: 'I could not place that on the map — ask for the postal code, take the order and let the technician confirm the trip.',
    };
  }
  return {
    ok: true,
    inside: voiceFacts.pointInPolygon(found.lat, found.lng, area.polygon),
    place: found.label,
    source: 'geocode',
  };
}

module.exports = { init, checkServiceArea, polygonFromConfig, hintsFromLabel };
