/**
 * Shared extraction helpers for the Twilio phone secretary (not in-app Fix).
 * Times are wall-clock America/Toronto.
 */

const TORONTO = 'America/Toronto';

const VOICE_FAREWELL_EN = 'Okay, bye — see you then.';
const VOICE_FAREWELL_EN_CALLBACK = 'Okay. Our technician will contact you.';
const VOICE_FAREWELL_EN_DAY = 'Okay, have a good day.';
const VOICE_FAREWELL_EN_EVENING = 'Okay, have a good evening.';
const VOICE_FAREWELL_RU =
  'Всего доброго, до свидания. Наш мастер свяжется с вами в ближайшее время.';
const VOICE_FAREWELL_UK =
  'Всього доброго, до побачення. Наш майстер зв\'яжеться з вами найближчим часом.';
const VOICE_FAREWELL_ES =
  'Que esté bien, adiós. Nuestro técnico se comunicará con usted lo antes posible.';

const VOICE_CALL_FLOW = `Listen first. Take what they already said. Ask only the next missing thing, one short question, then wait.
You take orders 24 hours a day. Technician visits: Monday–Friday, 7 a.m. to 9 p.m. America/Toronto.
Saturday and Sunday: no visit. Still take the order. Offer the next weekday.
Public holidays: take the order; the technician must agree.
Each visit is 2 hours — one job in that window. Never confirm a taken window. Offer another time the same weekday first.
If they say the repair is at another address, keep their home, take the new street, who will be there, and that phone. Do not hang up.
Ask who will be home only if the repair is not at the owner's house.
If they want a live person, do not grill for a visit time. Say a technician will call back within 30 minutes.
If they asked the price: a service call is $99. If they approve the repair after diagnosis, they do not pay the service call, only the repair. Do not bring up $99 unless they asked.
Bare clock times ("2", "at 2", "two") mean 2 p.m., not 2 a.m., unless they said morning or a.m.
After you confirm, ask for a model-sticker photo to this number, then ask if anything else. If they say no, say "Have a good day." Do not hang up. The caller hangs up.
We repair washers, dryers, dishwashers, gas ovens, electric ovens, electric cooktops, fridges, freezers, microwaves. Not gas cooktops, TVs, laptops, phones, or cars.
If we cannot take the job, say so in one short sentence, stay on the line, and do not create a job.`;

const EXTRACT_CARD_RULES = `Keep street, city, unit, and postal code in the original English/Canadian spelling. Never translate or transliterate into Russian (write "King Street", not "Кинг-стрит"; "Toronto", not "Торонто"). Person names stay in English as spoken. problem_description is ONLY the appliance fault and model number — never the SMS, email, or call transcript. client_email is the customer's email from the letter body, not a booking-agency From: address.`;

const VOICE_LIVE_FLOW = `Listen. One short sentence, then wait. If they ask a side question, answer briefly, then return to the repair. Never freeze.
Take orders 24/7. Visits Mon–Fri 7 a.m.–9 p.m. Saturday and Sunday: no visit — offer a weekday. Holiday: take the order; technician must agree.
Each visit is 2 hours. Never book a taken window; offer another time the same weekday first.
Bare clock times ("2", "at 2", "two") mean 2 p.m., not 2 a.m., unless they said morning or a.m.
If they ask for 6 a.m. or a start after 7 p.m. (visit would end after 9 p.m.), say we don't work then and offer a time that ends by 9 p.m.
If they want a live person: technician calls back in 30 minutes. Do not hang up.
If we cannot take the job, say so, stay on the line, do not create a job.
After you confirm, ask for a model-sticker photo, then if anything else. If they say no: "Have a good day." Do not hang up.`;

const NAME_STOP = new Set([
  'so', 'the', 'and', 'for', 'your', 'there', 'that', 'this', 'what', 'how', 'can',
  'help', 'yeah', 'sure', 'wait', 'one', 'great', 'perfect', 'okay', 'alright',
  'thanks', 'thank', 'hi', 'hello', 'sorry', 'please', 'today', 'tomorrow',
  'fridge', 'washer', 'dryer', 'stove', 'oven', 'yes', 'no', 'here', 'well',
  'right', 'just', 'got', 'let', 'me', 'you', 'our', 'tech', 'master',
]);

const WEEKDAYS = {
  sunday: 0,
  monday: 1,
  tuesday: 2,
  wednesday: 3,
  thursday: 4,
  friday: 5,
  saturday: 6,
  воскресенье: 0,
  понедельник: 1,
  вторник: 2,
  среда: 3,
  среду: 3,
  четверг: 4,
  пятница: 5,
  пятницу: 5,
  суббота: 6,
  субботу: 6,
};

function pad2(n) {
  return String(n).padStart(2, '0');
}

function torontoParts(date = new Date()) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: TORONTO,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const map = {};
  for (const part of fmt.formatToParts(date)) {
    if (part.type !== 'literal') map[part.type] = part.value;
  }
  return {
    y: Number(map.year),
    m: Number(map.month),
    d: Number(map.day),
    h: Number(map.hour),
    min: Number(map.minute),
  };
}

function torontoTodayYmd(date = new Date()) {
  const p = torontoParts(date);
  return `${p.y}-${pad2(p.m)}-${pad2(p.d)}`;
}

function addDaysYmd(ymd, days) {
  const [y, m, d] = String(ymd).split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + Number(days) || 0);
  return `${dt.getUTCFullYear()}-${pad2(dt.getUTCMonth() + 1)}-${pad2(dt.getUTCDate())}`;
}

function fromTorontoWallClock(y, mo, d, h, mi) {
  let utc = Date.UTC(y, mo - 1, d, h, mi, 0);
  for (let i = 0; i < 4; i++) {
    const p = torontoParts(new Date(utc));
    const got = Date.UTC(p.y, p.m - 1, p.d, p.h, p.min);
    const want = Date.UTC(y, mo - 1, d, h, mi);
    const delta = want - got;
    if (delta === 0) break;
    utc += delta;
  }
  return new Date(utc);
}

function nextWeekdayYmd(todayYmd, weekdayIndex) {
  const [y, m, d] = String(todayYmd).split('-').map(Number);
  const current = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const add = (Number(weekdayIndex) - current + 7) % 7;
  return addDaysYmd(todayYmd, add);
}

function normalizeTime(raw) {
  if (raw == null) return '';
  const s = String(raw).trim().toLowerCase().replace(/\./g, '').replace(/\s+/g, ' ');
  if (!s) return '';
  const m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?$/i);
  if (!m) return '';
  let h = Number(m[1]);
  const min = Number(m[2] || 0);
  const ap = (m[3] || '').toLowerCase();
  if (!Number.isFinite(h) || h > 23 || min > 59) return '';
  if (ap === 'pm' || ap === 'p') {
    if (h < 12) h += 12;
  } else if (ap === 'am' || ap === 'a') {
    if (h === 12) h = 0;
  }
  return `${pad2(h)}:${pad2(min)}`;
}

function conversationText(extracted, history, extra) {
  const bits = [];
  if (Array.isArray(history)) {
    for (const item of history) {
      if (item && item.text) bits.push(String(item.text));
    }
  }
  if (extracted) {
    if (extracted.notes) bits.push(String(extracted.notes));
    if (extracted.problem_description) bits.push(String(extracted.problem_description));
  }
  if (extra) bits.push(String(extra));
  return bits.join('\n');
}

function inferApplianceFromText(text) {
  const t = String(text || '');
  const rules = [
    [/dish\s*wash|посудомое/i, 'Dishwasher'],
    [/\b(washer|washing machine|стиральн)/i, 'Washer'],
    [/\b(dryer|сушильн)/i, 'Dryer'],
    [/\b(fridge|refrigerator|холодильн)/i, 'Fridge'],
    [/\b(freezer|морозил)/i, 'Freezer'],
    [/\b(microwave|микроволн)/i, 'Microwave'],
    [/\b(cooktop|cook top|варочн)/i, 'Cooktop'],
    [/\b(stove|range|плит)/i, 'Stove'],
    [/\b(oven|духовк)/i, 'Oven'],
  ];
  for (const [re, type] of rules) {
    if (re.test(t)) return type;
  }
  return '';
}

function looksLikeRepairConversation(text) {
  const t = String(text || '');
  if (t.replace(/\s+/g, ' ').trim().length < 60) return false;
  const hasClient = /(^|\n)\s*(Client|Клиент)\s*:/im.test(t);
  const appliance = inferApplianceFromText(t);
  const repair =
    Boolean(appliance) ||
    /\b(repair|fix|broken|not working|leak|leaking|noise|won't (start|spin|drain|heat)|book(ed|ing)?|appointment|visit|technician|service call|ремонт|починить|сломал|не работает|заявк)\b/i.test(
      t
    );
  return repair && (hasClient || t.length > 180);
}

const MONTHS = {
  january: 1,
  february: 2,
  march: 3,
  april: 4,
  may: 5,
  june: 6,
  july: 7,
  august: 8,
  september: 9,
  october: 10,
  november: 11,
  december: 12,
  jan: 1,
  feb: 2,
  mar: 3,
  apr: 4,
  jun: 6,
  jul: 7,
  aug: 8,
  sep: 9,
  sept: 9,
  oct: 10,
  nov: 11,
  dec: 12,
  января: 1,
  февраля: 2,
  марта: 3,
  апреля: 4,
  мая: 5,
  июня: 6,
  июля: 7,
  августа: 8,
  сентября: 9,
  октября: 10,
  ноября: 11,
  декабря: 12,
  август: 8,
};

function inferMonthDay(text, todayYmd) {
  const names = Object.keys(MONTHS)
    .sort((a, b) => b.length - a.length)
    .join('|');
  const re = new RegExp(
    `\\b(?:(${names})\\s+(\\d{1,2})(?:st|nd|rd|th)?|(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(${names}))\\b`,
    'i'
  );
  const m = String(text || '').match(re);
  if (!m) return '';
  const month = MONTHS[String(m[1] || m[4] || '').toLowerCase()];
  const day = Number(m[2] || m[3]);
  if (!month || !day || day > 31) return '';
  const year = Number(String(todayYmd).slice(0, 4));
  let ymd = `${year}-${pad2(month)}-${pad2(day)}`;
  if (ymd < todayYmd) ymd = `${year + 1}-${pad2(month)}-${pad2(day)}`;
  return ymd;
}

function inferDateFromText(text, todayYmd) {
  const t = String(text || '');
  if (/\b(day after tomorrow|послезавтра)\b/i.test(t)) return addDaysYmd(todayYmd, 2);
  if (/\b(tomorrow|завтра)\b/i.test(t)) return addDaysYmd(todayYmd, 1);
  if (/\b(today|сегодня)\b/i.test(t)) return todayYmd;
  const iso = t.match(/\b(20\d{2})-(\d{2})-(\d{2})\b/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const monthDay = inferMonthDay(t, todayYmd);
  if (monthDay) return monthDay;
  const wantsNext = /\bnext\b|\bследующ/i.test(t);
  for (const [name, idx] of Object.entries(WEEKDAYS)) {
    if (new RegExp(`\\b${name}\\b`, 'i').test(t)) {
      let ymd = nextWeekdayYmd(todayYmd, idx);
      if (wantsNext && ymd === todayYmd) ymd = addDaysYmd(todayYmd, 7);
      return ymd;
    }
  }
  return '';
}

const HOUR_WORDS = {
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  noon: 12,
  midday: 12,
  один: 1,
  два: 2,
  три: 3,
  четыре: 4,
  пять: 5,
  шесть: 6,
  семь: 7,
  восемь: 8,
  девять: 9,
  десять: 10,
  одиннадцать: 11,
  двенадцать: 12,
};

function hourWordPattern() {
  return Object.keys(HOUR_WORDS)
    .sort((a, b) => b.length - a.length)
    .join('|');
}

function looksMorning(text) {
  const t = String(text || '');
  return (
    /\b\d{1,2}(?::\d{2})?\s*a\.?m\.?\b/i.test(t) ||
    /\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+a\.?m\.?\b/i.test(
      t
    ) ||
    /\b\d{1,2}(?::\d{2})?\s+in the morning\b/i.test(t) ||
    /\b(утра|утром)\b/i.test(t)
  );
}

function looksEvening(text) {
  const t = String(text || '');
  return (
    /\b\d{1,2}(?::\d{2})?\s*p\.?m\.?\b/i.test(t) ||
    /\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+p\.?m\.?\b/i.test(
      t
    ) ||
    /\b(?:afternoon|this evening|tonight)\b/i.test(t) ||
    /\b(вечера|вечером)\b/i.test(t)
  );
}

/** Shop clock: bare "2" / "at 2" / "two" is 14:00, not 02:00. */
function preferShopVisitTime(hhmm, spokenText) {
  const m = String(hhmm || '').match(/^(\d{2}):(\d{2})$/);
  if (!m) return hhmm || '';
  let h = Number(m[1]);
  const min = m[2];
  if (!Number.isFinite(h) || h > 23) return hhmm;
  const spoken = String(spokenText || '');
  const morning = looksMorning(spoken);
  const evening = looksEvening(spoken);
  if (morning && !evening) return `${pad2(h)}:${min}`;
  if (evening && h > 0 && h < 12) return `${pad2(h + 12)}:${min}`;
  if (!morning && !evening && h >= 1 && h <= 6) return `${pad2(h + 12)}:${min}`;
  return `${pad2(h)}:${min}`;
}

function inferTimeFromText(text) {
  const t = String(text || '');
  if (/\bnoon\b|\bполдень\b/i.test(t) && !/\bafternoon\b/i.test(t)) {
    return preferShopVisitTime('12:00', t);
  }
  const patterns = [
    /\b(?:at|around|about|by|for)\s+(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\b/i,
    /\b(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)?\b/i,
    /\b(\d{1,2})\s*o['’]?clock\b/i,
    /\b(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)\b/i,
    /\b(?:в|к)\s+(\d{1,2})(?::(\d{2}))?\b/i,
  ];
  for (const re of patterns) {
    const m = t.match(re);
    if (!m) continue;
    const hour = m[1];
    const min = m[2] && /^\d{2}$/.test(m[2]) ? m[2] : '00';
    const ap = m[3] || '';
    const normalized = normalizeTime(`${hour}:${min}${ap}`);
    if (!normalized) continue;
    const h = Number(normalized.slice(0, 2));
    if (!Number.isFinite(h) || h > 23) continue;
    return preferShopVisitTime(normalized, `${t} ${ap}`);
  }
  const words = hourWordPattern();
  const wordRes = [
    new RegExp(
      `\\b(?:at|around|about|by|for|в)\\s+(${words})(?:\\s+(thirty|o['’]?clock))?\\b`,
      'i'
    ),
    new RegExp(`\\bhalf\\s+past\\s+(${words})\\b`, 'i'),
    new RegExp(`\\b(${words})\\s+o['’]?clock\\b`, 'i'),
  ];
  for (const re of wordRes) {
    const m = t.match(re);
    if (!m) continue;
    const hour = HOUR_WORDS[String(m[1] || '').toLowerCase()];
    if (!hour) continue;
    const min = /half\s+past/i.test(m[0]) || /thirty/i.test(m[2] || '') ? '30' : '00';
    const normalized = normalizeTime(`${hour}:${min}`);
    if (!normalized) continue;
    return preferShopVisitTime(normalized, t);
  }
  const utterances = String(t)
    .split(/\n+/)
    .map((line) =>
      String(line)
        .replace(/^(client|caller|user|assistant|ai|shop)\s*:\s*/i, '')
        .replace(/[.!?]+$/g, '')
        .trim()
    )
    .filter(Boolean);
  for (const line of utterances.slice().reverse()) {
    const bareNum = line.match(
      /^(?:at|around|about|by|for|в)?\s*(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?$/i
    );
    if (bareNum) {
      const hour = Number(bareNum[1]);
      if (hour >= 1 && hour <= 12) {
        const min = bareNum[2] && /^\d{2}$/.test(bareNum[2]) ? bareNum[2] : '00';
        const normalized = normalizeTime(`${hour}:${min}${bareNum[3] || ''}`);
        if (normalized) {
          return preferShopVisitTime(normalized, `${t} ${bareNum[3] || ''}`);
        }
      }
    }
    const bareWord = line.match(
      new RegExp(
        `^(?:at|around|about|by|for|в)?\\s*(${words})(?:\\s+(thirty|o['’]?clock))?$`,
        'i'
      )
    );
    if (bareWord) {
      const hour = HOUR_WORDS[String(bareWord[1] || '').toLowerCase()];
      if (hour) {
        const min = /thirty/i.test(bareWord[2] || '') ? '30' : '00';
        const normalized = normalizeTime(`${hour}:${min}`);
        if (normalized) return preferShopVisitTime(normalized, t);
      }
    }
  }
  return '';
}

function isPlaceholderClientName(name) {
  const s = String(name || '').trim();
  if (!s) return true;
  if (/^(клиент|client)(\s|$|\+)/i.test(s)) return true;
  if (/^без имени$/i.test(s)) return true;
  if (/^\+?\d[\d\s\-().]{6,}$/.test(s)) return true;
  return false;
}

function usableClientName(raw) {
  const s = String(raw || '').trim();
  if (!s || isPlaceholderClientName(s) || !looksLikePersonName(s)) return '';
  return titleCaseName(s);
}

function looksLikeGarbageName(name) {
  const s = String(name || '').trim();
  if (!s) return true;
  if (s.length > 36) return true;
  const parts = s.split(/\s+/).filter(Boolean);
  if (!parts.length || parts.length > 4) return true;
  if (parts.some((p) => p.length === 1) && parts.length >= 2) return true;
  if (/[^A-Za-zА-Яа-яЁё\s'\-]/.test(s)) return true;
  if (parts.some((p) => p.length > 16)) return true;
  if (parts.some((p) => /[bcdfghjklmnpqrstvwxz]{5,}/i.test(p))) return true;
  if (parts.some((p) => /(.)\1{3,}/i.test(p))) return true;
  return false;
}

function looksLikePersonName(name) {
  const s = String(name || '').trim();
  if (!s || looksLikeGarbageName(s)) return false;
  return s.split(/\s+/).every((p) =>
    /^[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё'\-]{1,15}$/.test(p)
  );
}

function titleCaseName(name) {
  return String(name || '')
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1).toLowerCase())
    .join(' ');
}

function nameFromHistory(history) {
  if (!Array.isArray(history)) return '';
  const userRe =
    /(?:my name is|this is|i(?:'|’| a)?m|меня зовут)\s+([A-Za-zА-Яа-яЁё]{2,16})\b/i;
  const asstRe =
    /(?:okay|ok|alright|thanks|thank you|hi|hello|perfect|great)\s+([A-Za-zА-Яа-яЁё]{2,16})\b/i;
  for (const item of [...history].reverse()) {
    const m = String((item && item.text) || '').match(userRe);
    if (m && looksLikePersonName(m[1]) && !NAME_STOP.has(m[1].toLowerCase())) {
      return titleCaseName(m[1]);
    }
  }
  for (const item of [...history].reverse()) {
    if (!item || item.role !== 'assistant') continue;
    const m = String(item.text || '').match(asstRe);
    if (m && looksLikePersonName(m[1]) && !NAME_STOP.has(m[1].toLowerCase())) {
      return titleCaseName(m[1]);
    }
  }
  return '';
}

function pickClientName(prev, next, history) {
  const spoken = nameFromHistory(history);
  const nextS = String(next || '').trim();
  const prevS = String(prev || '').trim();
  if (spoken && looksLikeGarbageName(nextS)) return spoken;
  if (looksLikePersonName(nextS)) {
    if (looksLikePersonName(prevS) && nextS.length > Math.max(prevS.length + 6, 14)) {
      return titleCaseName(prevS);
    }
    return titleCaseName(nextS);
  }
  if (looksLikePersonName(spoken)) return spoken;
  if (looksLikePersonName(prevS)) return titleCaseName(prevS);
  return '';
}

function detectLiveCallback(text) {
  return /\b(?:speak (?:to|with)|talk (?:to|with)|call me back|have (?:him|her|someone|the (?:tech|technician|master)|a (?:person|human)) call|live (?:person|human)|real (?:person|human)|want (?:a )?(?:person|human|someone)(?: to call)?)\b/i.test(
    String(text || '')
  ) || /перезвон|живой\s+(?:человек|мастер)|поговорить с|с мастером|пусть мастер/i.test(
    String(text || '')
  );
}

function saidCallbackPromise(text) {
  return /pass your details along|technician will call you back shortly|передам ваши данные|перезвонит мастер в ближайшее время/i.test(
    String(text || '')
  );
}

function saidGoodbye(text) {
  return /okay,?\s*bye|see you then|our technician will contact you|all the best,\s*goodbye|technician will contact you as soon as possible|see you at the scheduled time|всего доброго|до свидания|свяжется с вами в ближайшее время|увидимся в назначенное/i.test(
    String(text || '')
  );
}

function isCheckInUtterance(text) {
  const t = String(text || '')
    .trim()
    .toLowerCase()
    .replace(/[?.!,]+/g, '')
    .replace(/\s+/g, ' ');
  if (!t) return false;
  if (t.length > 48) return false;
  return /^(well\s+|so\s+|um+\s+|uh+\s+)?(hello|hi|hey|allo|алло|привет)(\s+(there|again))?$/.test(t)
    || /^(are you (there|still there|still on the line)|can you hear me|you there|hello\s*\?)$/.test(t)
    || /^(вы (ещё |еще )?здесь|меня слышно|алло алло)$/.test(t);
}

function callerAskedToStop(text) {
  const t = String(text || '').trim();
  if (!t || isCheckInUtterance(t)) return false;
  if (/\bi(?:'m| am) good with\b/i.test(t)) return false;
  if (/\b(sounds good|that's fine|that's good|perfect|great|okay|ok|yes|yeah)\b/i.test(t)
      && !/\b(bye|goodbye|that's all|nothing else)\b/i.test(t)) {
    return false;
  }
  return /\b(that's all|that is all|nothing else|no thanks|no thank you|i(?:'m| am) done|hang up|got to go|gotta go|goodbye|good bye|bye bye|bye now|talk (?:to you )?later)\b/i.test(
    t
  )
    || /(?:^|[\s,])bye[.!?]?$/i.test(t)
    || /^(thanks?,?\s*)?(have a (?:good|nice) (?:day|evening|night)|see you(?: then)?)[.!]?$/i.test(t)
    || /всё,? спасибо|все,? спасибо|больше ничего|давайте заканчивать|кладите трубку|до свидания|всего доброго|пока[.!]?$/i.test(
      t
    );
}

function askedAnythingElse(text) {
  return /anything else|help you with anything|is there anything else|can i (?:help|do) anything else|need anything else/i.test(
    String(text || '')
  );
}

function declinedMoreHelp(text) {
  const t = String(text || '')
    .trim()
    .toLowerCase()
    .replace(/[?!.,]+/g, ' ')
    .replace(/\s+/g, ' ');
  if (!t || t.length > 90) return false;
  if (isCheckInUtterance(t)) return false;
  if (/\bi(?:'m| am) good with\b/.test(t)) return false;
  if (/^(thanks|thank you|okay|ok|yes|yeah|yep|perfect|great|sounds good)(\s|$)/.test(t)
      && !/\b(no|nothing else|that's all|bye)\b/.test(t)) {
    return false;
  }
  return /^(no|nope|nah|no thanks|no thank you|that's all|that is all|that's it|that is it|nothing else|nothing|i'm done|i am done|i'm all set|all set|we're good)(\s|$)/i.test(
    t
  )
    || /\bno\b.*\b(thanks|thank you|that's all|nothing else|i'm good|everything(?:'s| is) (?:fine|good|ok|okay))\b/i.test(
      t
    )
    || /нет,?\s*(всё|все|спасибо)|больше ничего|давайте заканчивать/.test(t);
}

function historyAskedAnythingElse(history) {
  const items = Array.isArray(history) ? history : [];
  const start = Math.max(0, items.length - 8);
  for (let i = items.length - 1; i >= start; i--) {
    const item = items[i];
    if (item && item.role === 'assistant' && askedAnythingElse(item.text)) return true;
  }
  return false;
}

function askedForVisitTime(text) {
  return /\b((what|which) (day|time)|what time of day|when (can|should|would|works|are you)|morning or afternoon|day and time|clock time|what day works)\b/i.test(
    String(text || '')
  );
}

function askedForAddress(text) {
  return /\b(address|street|where (is|are|should)|same address|another address|different address|home on file)\b/i.test(
    String(text || '')
  );
}

function looksLikeStreetUtterance(text) {
  const t = String(text || '');
  if (detectJobSite(t) && !askedForVisitTime(t)) return true;
  return /\b\d{1,6}\s+[A-Za-zА-Яа-я]/.test(t)
    && /\b(street|st|avenue|ave|road|rd|drive|dr|lane|ln|blvd|way|court|ct|crescent|circle|place|pl|unit|apt|boulevard)\b/i.test(t);
}

function missingVisitDetails(extracted) {
  const e = extracted && typeof extracted === 'object' ? extracted : {};
  if (e.wants_callback === true) return '';
  if (!e.address || e.address_uncertain === true) {
    return 'street number, street name, and town';
  }
  if (!e.scheduled_date || !e.scheduled_time) {
    return 'a day AND a clock time';
  }
  return '';
}

function justGaveOtherAddress(lastUser, extracted) {
  const e = extracted && typeof extracted === 'object' ? extracted : {};
  if (e.wants_callback === true) return false;
  return detectJobSite(lastUser);
}

function mayHangUp({ lastUser, lastAsst, history, extracted }) {
  if (isCheckInUtterance(lastUser)) return false;
  return callerAskedToStop(lastUser);
}

function looksOutOfScopeItem(text) {
  return /\b(laptop|notebook|macbook|chromebook|computer|desktop|pc\b|iphone|android phone|tablet|ipad)\b/i.test(
    String(text || '')
  )
    || /ноутбук|компьютер|ноут\b|макбук/i.test(String(text || ''));
}

function clientAddressFrom(client) {
  if (!client || typeof client !== 'object') return '';
  const direct = String(client.address || '').trim();
  if (direct) return direct;
  const loc = Array.isArray(client.locations) ? client.locations[0] : null;
  if (!loc || typeof loc !== 'object') return '';
  return [loc.unit, loc.street, loc.city, loc.postalCode || loc.postal]
    .map((part) => String(part || '').trim())
    .filter(Boolean)
    .join(', ');
}

function phonesOfClient(client) {
  const out = new Set();
  const add = (value) => {
    const digits = String(value || '').replace(/\D/g, '');
    const normalized = digits.length > 10 ? digits.slice(-10) : digits;
    if (normalized) out.add(normalized);
  };
  if (!client || typeof client !== 'object') return out;
  add(client.phone);
  add(client.mobile);
  for (const loc of Array.isArray(client.locations) ? client.locations : []) {
    add(loc && loc.phone);
    for (const contact of Array.isArray(loc && loc.contacts) ? loc.contacts : []) {
      add(contact && contact.phone);
    }
  }
  return out;
}

function wantsEnglish(text) {
  const t = String(text || '').toLowerCase();
  return /don'?t understand|do not understand|speak english|in english|english please|я не понимаю|не понимаю|по-английски|на английском|no entiendo|en ingl[eé]s|no hablo/i.test(
    t
  );
}

function detectSpokenLanguage(text) {
  const t = String(text || '');
  if (/[ІіЇїЄєҐґ]/.test(t)) return 'uk';
  if (/[А-Яа-яЁё]/.test(t)) return 'ru';
  if (
    /[¿¡ñáéíóúü]/i.test(t) ||
    /\b(hola|gracias|buenos|lavadora|refrigerador|estufa|secadora)\b/i.test(t)
  ) {
    return 'es';
  }
  return '';
}

function formatTorontoStamp(date = new Date()) {
  const p = torontoParts(date instanceof Date ? date : new Date());
  return `${pad2(p.d)}.${pad2(p.m)}.${p.y} ${pad2(p.h)}:${pad2(p.min)}`;
}

function farewellFor(extracted, _language) {
  if (extracted && extracted.wants_callback === true && !extracted.scheduled_date && !extracted.scheduled_time) {
    return VOICE_FAREWELL_EN_CALLBACK;
  }
  if (extracted && (extracted.scheduled_date || extracted.scheduled_time)) {
    return VOICE_FAREWELL_EN;
  }
  const hour = torontoParts().h;
  return hour >= 17 ? VOICE_FAREWELL_EN_EVENING : VOICE_FAREWELL_EN_DAY;
}

function enrichExtracted(extracted, history, extraText) {
  const out = { ...(extracted || {}) };
  const today = torontoTodayYmd();
  const text = conversationText(out, history, extraText);
  if (!out.scheduled_date || !/^\d{4}-\d{2}-\d{2}$/.test(String(out.scheduled_date))) {
    const inferred = inferDateFromText(text, today);
    if (inferred) out.scheduled_date = inferred;
  }
  const timeNorm = normalizeTime(out.scheduled_time);
  if (timeNorm) {
    out.scheduled_time = preferShopVisitTime(
      timeNorm,
      `${out.scheduled_time}\n${text}`
    );
  } else {
    const inferredTime = inferTimeFromText(text);
    if (inferredTime) out.scheduled_time = inferredTime;
  }
  const name = pickClientName(out.client_name, out.client_name, history);
  if (name) out.client_name = name;
  else if (looksLikeGarbageName(out.client_name)) delete out.client_name;
  if (!String(out.appliance_type || '').trim()) {
    const appliance = inferApplianceFromText(text);
    if (appliance) out.appliance_type = appliance;
  }
  if (out.wants_callback !== true && detectLiveCallback(text)) {
    out.wants_callback = true;
  }
  if (out.has_job_site !== true && detectJobSite(text)) {
    out.has_job_site = true;
  }
  if (
    out.has_job_site !== true &&
    out.owner_address &&
    out.address &&
    addressesLookDifferent(out.owner_address, out.address) &&
    !detectMoved(text)
  ) {
    out.has_job_site = true;
  }
  return out;
}

function foldAddress(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/\b(street|st|avenue|ave|road|rd|drive|dr|lane|ln|boulevard|blvd)\b/g, ' ')
    .replace(/[^a-z0-9а-яё]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function addressesLookDifferent(a, b) {
  const na = foldAddress(a);
  const nb = foldAddress(b);
  if (!na || !nb) return false;
  if (na === nb) return false;
  const [shorter, longer] = na.length <= nb.length ? [na, nb] : [nb, na];
  if (shorter.length >= 10 && longer.includes(shorter)) return false;
  const numA = (na.match(/\b\d{1,6}\b/) || [])[0];
  const numB = (nb.match(/\b\d{1,6}\b/) || [])[0];
  if (numA && numB && numA !== numB) return true;
  return shorter.length / Math.max(longer.length, 1) < 0.72;
}

function detectMoved(text) {
  return /\b(i(?:'?ve| have)? moved|we moved|that'?s my new (home|address)|i live (here|there) now|я переехал|мы переехали)\b/i.test(
    String(text || '')
  );
}

function detectJobSite(text) {
  return /\b(tenant|renter|rental|landlord|property manager|job site|another address|different address|other address|another (house|home|place|property)|second (house|property)|I (don'?t|do not) live (there|at that)|we (don'?t|do not) live there|owner but|it's a rental|the appliance is at|repair is at|not (my|the) (home|house) address|арендатор|не живу (там|в этом)|это аренда|другой адрес|по другому адресу)\b/i.test(
    String(text || '')
  );
}

function mergeExtracted(prev, next, history) {
  const out = { ...(prev || {}) };
  if (next && typeof next === 'object') {
    for (const [key, value] of Object.entries(next)) {
      if (value === null || value === undefined || value === '') continue;
      if (key === 'client_name') {
        const picked = pickClientName(out.client_name, value, history);
        if (picked) out.client_name = picked;
        continue;
      }
      if (key === 'wants_callback') {
        if (value === true) out.wants_callback = true;
        continue;
      }
      if (key === 'has_job_site') {
        if (value === true || value === 'true') out.has_job_site = true;
        continue;
      }
      if (key === 'service_declined') {
        if (value === true || value === 'true') out.service_declined = true;
        continue;
      }
      out[key] = value;
    }
  }
  return enrichExtracted(out, history);
}

function parseScheduledAtDate(extracted) {
  const dateStr = extracted && extracted.scheduled_date;
  if (!dateStr) return null;
  const dateParts = String(dateStr).split('-').map((v) => Number(v));
  if (dateParts.length < 3 || dateParts.some((n) => !Number.isFinite(n))) return null;
  const [y, mo, d] = dateParts;
  if (!y || !mo || !d) return null;
  let timeStr = normalizeTime(extracted.scheduled_time);
  if (timeStr) {
    timeStr = preferShopVisitTime(timeStr, extracted.scheduled_time);
  }
  if (!timeStr) return null;
  const [hh, mm] = timeStr.split(':').map(Number);
  return fromTorontoWallClock(y, mo, d, hh, mm);
}

function isStaleVoiceGreeting(greeting) {
  const g = String(greeting || '').trim();
  if (!g) return true;
  if (g === "Hi, you've reached FixApplianceCA. How can I help?") return false;
  if (g === "Hi, you've reached FIX Appliance. How can I help?") return true;
  if (g === 'Hi, FIX Appliance. How can I help?') return true;
  if (/technician'?s with a customer/i.test(g)) return true;
  if (/i can take your (repair )?details/i.test(g)) return true;
  if (/help you today/i.test(g)) return true;
  if (/Чем могу помочь/i.test(g)) return true;
  if (/you'?ve reached \{company\}/i.test(g)) return true;
  if (g === 'Hi, FIX ApplianceCA. How can I help you?') return true;
  if (g === 'Hi, FIX Appliance. How can I help you?') return true;
  return false;
}

function formatHour12(minutes) {
  const total = Math.max(0, Math.min(24 * 60, Math.round(Number(minutes) || 0)));
  if (total >= 24 * 60) return 'midnight';
  const h = Math.floor(total / 60);
  const m = total % 60;
  const ap = h >= 12 ? 'p.m.' : 'a.m.';
  let h12 = h % 12;
  if (h12 === 0) h12 = 12;
  if (m) return `${h12}:${String(m).padStart(2, '0')} ${ap}`;
  return `${h12} ${ap}`;
}

function workHoursSpeech(startMinutes, endMinutes) {
  const start = Number.isFinite(Number(startMinutes)) ? Number(startMinutes) : 7 * 60;
  const end = Number.isFinite(Number(endMinutes)) ? Number(endMinutes) : 21 * 60;
  return `${formatHour12(start)} to ${formatHour12(end)}`;
}

function isServiceDeclined(extracted, callData) {
  const data = extracted && typeof extracted === 'object' ? extracted : {};
  if (data.service_declined === true) return true;
  if (callData && callData.serviceDeclined === true) return true;
  const rec = (callData && callData.aiReception) || {};
  return rec.serviceDeclined === true;
}

module.exports = {
  TORONTO,
  VOICE_CALL_FLOW,
  VOICE_LIVE_FLOW,
  torontoTodayYmd,
  addDaysYmd,
  fromTorontoWallClock,
  normalizeTime,
  preferShopVisitTime,
  inferDateFromText,
  inferTimeFromText,
  looksLikeGarbageName,
  looksLikePersonName,
  isPlaceholderClientName,
  usableClientName,
  titleCaseName,
  enrichExtracted,
  mergeExtracted,
  conversationText,
  inferApplianceFromText,
  looksLikeRepairConversation,
  isServiceDeclined,
  parseScheduledAtDate,
  pickClientName,
  isStaleVoiceGreeting,
  torontoParts,
  formatHour12,
  workHoursSpeech,
  detectSpokenLanguage,
  wantsEnglish,
  detectLiveCallback,
  saidCallbackPromise,
  saidGoodbye,
  isCheckInUtterance,
  callerAskedToStop,
  askedAnythingElse,
  declinedMoreHelp,
  looksOutOfScopeItem,
  missingVisitDetails,
  askedForVisitTime,
  askedForAddress,
  looksLikeStreetUtterance,
  mayHangUp,
  formatTorontoStamp,
  farewellFor,
  clientAddressFrom,
  phonesOfClient,
  detectJobSite,
  detectMoved,
  addressesLookDifferent,
  EXTRACT_CARD_RULES,
  VOICE_LIVE_FLOW,
  VOICE_FAREWELL_EN,
  VOICE_FAREWELL_EN_CALLBACK,
  VOICE_FAREWELL_RU,
};
