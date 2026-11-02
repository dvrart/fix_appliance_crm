/**
 * Куда вести звонок мастеру: в приложение (Twilio Voice) или на обычный
 * номер SIM в его телефоне.
 *
 * Решение FIX (27.10.2026): режим выбирается в Настройки → Телефон → Звонки.
 *  - app  — как раньше, только приложение;
 *  - cell — всегда обычная сотовая связь;
 *  - auto — сначала приложение, а если звук там не поднялся, приложение
 *    просит перевести на SIM именно этот звонок. Сервер сам ничего не
 *    угадывает: признак «плохой связи» знает только телефон.
 *
 * На SIM мастер отвечает и нажимает 1 (решение FIX): без этого звонок мог бы
 * снять автоответчик оператора, и клиент остался бы без Сары.
 */
const twilio = require('twilio');

const CALL_ROUTES = ['app', 'cell', 'auto'];
const PENDING_CELL_CALL_MAX_AGE_MS = 2 * 60 * 1000;
const CELL_RING_MIN_SECONDS = 15;
const CELL_SCREEN_SECONDS = 8;
const CELL_SCREEN_PROMPT = 'Звонок в мастерскую. Нажмите 1, чтобы ответить.';
const CELL_BRIDGE_LOST_PROMPT =
  'Номер клиента не дошёл до сервера. Позвоните из приложения ещё раз.';

function digitsOnly(value) {
  return String(value || '').replace(/\D/g, '');
}

/** E.164 для Канады/США; пустая строка, если номер не похож на телефон. */
function normalizePhone(value) {
  const raw = String(value || '').trim();
  const digits = digitsOnly(raw);
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  if (raw.startsWith('+') && digits.length >= 8 && digits.length <= 15) return `+${digits}`;
  return '';
}

function sameNumber(a, b) {
  const x = digitsOnly(a);
  const y = digitsOnly(b);
  return x.length >= 10 && y.length >= 10 && x.slice(-10) === y.slice(-10);
}

/** Без номера SIM любой режим работает как «приложение». */
function readCallRouting(config) {
  const data = config || {};
  const wanted = String(data.callRoute || '').trim();
  const cell = normalizePhone(data.masterCellNumber);
  const mode = CALL_ROUTES.includes(wanted) ? wanted : 'app';
  return { mode: cell ? mode : 'app', cell };
}

function inboundGoesToCell(routing, fromNumber) {
  if (!routing || routing.mode !== 'cell' || !routing.cell) return false;
  // Мастер звонит в мастерскую со своей же SIM — набирать его самого бессмысленно.
  return !sameNumber(fromNumber, routing.cell);
}

/**
 * Сотовой сети нужно несколько секунд, чтобы телефон вообще зазвонил, поэтому
 * короче 15 секунд гудков на SIM не даём, даже если секретарь стоит на 8.
 */
function cellRingSeconds(timeoutSeconds) {
  const seconds = Math.round(Number(timeoutSeconds) || 0);
  return Math.min(60, Math.max(CELL_RING_MIN_SECONDS, seconds));
}

function millisOf(value) {
  if (!value) return 0;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  const parsed = new Date(value).getTime();
  return Number.isFinite(parsed) ? parsed : 0;
}

/** Номер клиента из свежей заявки приложения «позвони через SIM». */
function pendingCellDestination(pending, nowMs, maxAgeMs = PENDING_CELL_CALL_MAX_AGE_MS) {
  if (!pending || pending.consumedAt) return '';
  const at = millisOf(pending.at);
  if (!at || nowMs - at > maxAgeMs || at - nowMs > 60 * 1000) return '';
  return normalizePhone(pending.phone);
}

function withQuery(url, params) {
  const query = new URLSearchParams(
    Object.entries(params || {}).filter(([, value]) => value !== undefined && value !== null && value !== '')
  ).toString();
  if (!query) return url;
  return `${url}${url.includes('?') ? '&' : '?'}${query}`;
}

/**
 * Входящий клиента — на SIM мастера. Клиент слышит гудки (answerOnBridge),
 * пока мастер не нажмёт 1. Запись — как у звонка в приложение: обе стороны
 * в своих дорожках, первая — клиент.
 */
function twimlDialCell({ callerId, cell, timeoutSeconds, actionUrl, screenUrl, recordingUrl }) {
  const twiml = new twilio.twiml.VoiceResponse();
  const dial = twiml.dial({
    callerId,
    timeout: cellRingSeconds(timeoutSeconds),
    answerOnBridge: true,
    record: 'record-from-answer-dual',
    recordingStatusCallback: recordingUrl,
    recordingStatusCallbackEvent: 'completed',
    action: actionUrl,
  });
  dial.number({ url: screenUrl }, cell);
  return twiml;
}

/** Мастеру, когда он снял трубку: нажать 1. Тишина или другая цифра — Саре. */
function twimlCellScreen({ acceptUrl }) {
  const twiml = new twilio.twiml.VoiceResponse();
  const gather = twiml.gather({ numDigits: 1, timeout: CELL_SCREEN_SECONDS, action: acceptUrl });
  gather.say({ language: 'ru-RU' }, CELL_SCREEN_PROMPT);
  twiml.hangup();
  return twiml;
}

/** Нажал 1 — короткий сигнал «клиент на линии», дальше Twilio соединяет. */
function twimlCellAccepted(accepted) {
  const twiml = new twilio.twiml.VoiceResponse();
  if (accepted) twiml.play({ digits: '9' });
  else twiml.hangup();
  return twiml;
}

/** Мастер позвонил в мастерскую с SIM, а заявка приложения ещё в пути. */
function twimlWaitForPending(redirectUrl) {
  const twiml = new twilio.twiml.VoiceResponse();
  twiml.pause({ length: 1 });
  twiml.redirect({ method: 'POST' }, redirectUrl);
  return twiml;
}

function twimlCellBridgeLost() {
  const twiml = new twilio.twiml.VoiceResponse();
  twiml.say({ language: 'ru-RU' }, CELL_BRIDGE_LOST_PROMPT);
  twiml.hangup();
  return twiml;
}

module.exports = {
  CALL_ROUTES,
  CELL_SCREEN_PROMPT,
  PENDING_CELL_CALL_MAX_AGE_MS,
  normalizePhone,
  sameNumber,
  readCallRouting,
  inboundGoesToCell,
  cellRingSeconds,
  pendingCellDestination,
  withQuery,
  twimlDialCell,
  twimlCellScreen,
  twimlCellAccepted,
  twimlWaitForPending,
  twimlCellBridgeLost,
};
