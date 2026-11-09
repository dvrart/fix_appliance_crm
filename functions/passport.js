/**
 * Публичная страница цифрового паспорта техники: /a/<код> — код с наклейки
 * (QR). Отдаёт её функция `p`: хостинг уже переписывает все пути на неё, так
 * что https://doc.fix-appliance.ca/a/<код> работает без правки firebase.json.
 *
 * Страницу открывает кто угодно, у кого в руках наклейка (новый жилец, сосед),
 * поэтому на ней НЕТ ни имени, ни адреса, ни телефона клиента, ни цен — только
 * техника, Care Plan и история работ. Всё по-английски: это видит клиент.
 * Код — 10 знаков из 31 (≈50 бит), перебором не найти.
 */
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const COMPANY_ID = 'fix_appliance_ca';
const CODE_RE = /^[2-9a-hjkmnp-z]{6,16}$/;
const SHOP_SITE = 'https://fix-appliance.ca';

function companyRef() {
  return getFirestore().collection('companies').doc(COMPANY_ID);
}

function cleanPath(path) {
  return String(path || '').split('?')[0];
}

/** /a/<код> или /passport/<код>; через прямой адрес функции — ещё и /p/a/<код>. */
function isPassportPath(path) {
  return /^(?:\/p)?\/(?:a|passport)(?:\/|$)/i.test(cleanPath(path));
}

function passportCodeFromPath(path) {
  const match = cleanPath(path).match(/^(?:\/p)?\/(?:a|passport)\/([A-Za-z0-9]{6,16})(?:\/note)?\/?$/i);
  if (!match) return '';
  const code = match[1].toLowerCase();
  return CODE_RE.test(code) ? code : '';
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Только печатная латиница: кириллице из заметок мастера тут не место. */
function latin(value) {
  const text = String(value ?? '').trim();
  return /^[\x20-\x7E]+$/.test(text) ? text : '';
}

/**
 * Текст отчёта для публичной страницы. Мастер пишет по-русски, сервер
 * кладёт перевод в `solutionEn`; кириллицу на страницу не пускаем.
 */
function reportText(job) {
  return latin(job && job.solutionEn).slice(0, 600);
}

/** Тот же словарь, что `ApplianceEnglish` в приложении. */
function applianceEnglish(type) {
  const t = String(type || '').trim().toLowerCase();
  if (!t) return 'Appliance';
  if (t.includes('мороз') || t.includes('freezer')) return 'Freezer';
  if (t.includes('холод') || t.includes('fridge') || t.includes('refriger')) return 'Refrigerator';
  if (t.includes('посуд') || t.includes('dish')) return 'Dishwasher';
  if (t.includes('стирал') || t.includes('wash')) return 'Washer';
  if (t.includes('суш') || t.includes('dryer')) return 'Dryer';
  if (t.includes('микроволн') || t.includes('microwave')) return 'Microwave';
  if (t.includes('вароч') || t.includes('cooktop')) return 'Cooktop';
  if (t.includes('духов') || t.includes('oven')) return t.includes('плит') ? 'Range' : 'Oven';
  if (t.includes('плит') || t.includes('stove') || t.includes('range')) return 'Range';
  return latin(type) || 'Appliance';
}

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value.toDate === 'function') return value.toDate();
  if (typeof value === 'number') return new Date(value > 1e12 ? value : value * 1000);
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function formatDay(date) {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric',
  }).format(date);
}

function formatMonth(date) {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto', month: 'long', year: 'numeric',
  }).format(date);
}

function isCancelledStatus(status) {
  const s = String(status || '').trim().toLowerCase();
  return s.includes('отмен') || s.includes('cancel');
}

function isCompletedStatus(status) {
  const s = String(status || '').trim().toLowerCase();
  return s.includes('заверш') || s.includes('готов') || s.includes('complete') || s === 'done';
}

/** Даты выездов, которые мастер уже закрыл. */
function doneVisitDates(job) {
  const visits = Array.isArray(job.visits) ? job.visits : [];
  return visits
    .filter((visit) => visit && visit.outcome === 'done')
    .map((visit) => toDate(visit.startAt))
    .filter(Boolean)
    .sort((a, b) => b - a);
}

/**
 * Когда строка попадает в историю. Закрытая заявка — по дате завершения.
 * Незакрытая — только если был выезд: диагностика, после которой мастер
 * уехал, должна быть видна следующему, кто отсканирует наклейку.
 */
function jobServiceDate(job) {
  const done = doneVisitDates(job);
  if (toDate(job.completedAt)) return toDate(job.completedAt);
  if (isCompletedStatus(job.status)) return done[0] || toDate(job.updatedAt) || toDate(job.createdAt);
  return done[0] || null;
}

/** Выезд, час и скидка — не запчасть. В «что заменили» их не пишем. */
function isLabourName(name) {
  return /discount/i.test(name)
    || /^(service call|labour|labor|diagnostic|diagnosis|trip charge)$/i.test(name);
}

function invoiceItemNames(job) {
  const names = [];
  for (const doc of Array.isArray(job.documents) ? job.documents : []) {
    if (!doc || doc.deletedAt || String(doc.type || 'Invoice') === 'Estimate') continue;
    if (/cancel|void|отмен/i.test(String(doc.status || ''))) continue;
    for (const item of Array.isArray(doc.items) ? doc.items : []) {
      if (!item || item.labourDiscount) continue;
      if (String(item.type || '').toLowerCase() === 'service') continue;
      const name = latin(item.name);
      if (!name || isLabourName(name)) continue;
      if (!names.some((n) => n.toLowerCase() === name.toLowerCase())) names.push(name);
    }
  }
  return names.slice(0, 8);
}

/** История: ремонты из заявок с этим паспортом + записи ТО из самого паспорта. */
function buildHistory(appliance, jobs) {
  const entries = [];
  for (const job of jobs) {
    if (!job || job.deletedAt || isCancelledStatus(job.status) || job.mergedIntoJobId) continue;
    const date = jobServiceDate(job);
    if (!date) continue;
    entries.push({
      date,
      kind: job.carePlanKind === 'maintenance' ? 'Maintenance' : 'Repair',
      // Незакрытая заявка с выездом — диагностика, ремонт ещё не сделан.
      label: isCompletedStatus(job.status) || toDate(job.completedAt) ? '' : 'Inspected',
      report: reportText(job),
      items: invoiceItemNames(job),
      by: latin(job.technicianName),
      shop: latin(job.servicedByShop),
      phone: telHref(job.servicedByPhone),
    });
  }
  for (const log of Array.isArray(appliance.serviceLog) ? appliance.serviceLog : []) {
    const date = toDate(log && log.date);
    if (!date) continue;
    const kind = log.kind === 'repair' ? 'Repair' : log.kind === 'install' ? 'Installation' : 'Maintenance';
    // ТО по заявке уже есть строкой из заявки — дату не дублируем, а дописываем список работ.
    const twin = log.jobId
      ? entries.find((e) => e.kind === kind && Math.abs(e.date - date) < 3 * 86400000)
      : null;
    const items = (Array.isArray(log.items) ? log.items : []).map(latin).filter(Boolean);
    if (twin) {
      twin.items = [...new Set([...twin.items, ...items])];
      continue;
    }
    entries.push({
      date,
      kind,
      label: log.outside ? 'Outside shop' : '',
      report: latin(log.note),
      items,
      by: latin(log.by),
      shop: latin(log.shop),
      phone: telHref(log.phone),
    });
  }
  return entries.sort((a, b) => b.date - a.date).slice(0, 30);
}

function nextMaintenance(plan) {
  const stored = toDate(plan.nextMaintenanceDue);
  if (stored) return stored;
  const last = toDate(plan.lastMaintenanceAt);
  const months = Number(plan.maintenanceMonths) || 12;
  if (last) return new Date(last.getFullYear(), last.getMonth() + months, last.getDate());
  const signed = toDate(plan.signedAt);
  if (!signed) return null;
  return new Date(signed.getTime() + (Number(plan.firstMaintenanceDays) || 30) * 86400000);
}

function telHref(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return digits ? `+${digits}` : '';
}

/** Кто делал работу — тремя отдельными строками, не одной. Свои визиты без
 * имени берут имя из настроек компании. */
function visitWho(entry, shop, tel, technician) {
  const own = !entry.shop || entry.shop.toLowerCase() === shop.toLowerCase();
  return {
    technician: entry.by || (own ? technician : ''),
    company: entry.shop || (own ? shop : ''),
    phone: entry.phone || (own ? tel : ''),
  };
}

function renderPassportHtml({ appliance, plan, company, history, code }) {
  const brand = latin(appliance.brand);
  const title = [brand, applianceEnglish(appliance.type)].filter(Boolean).join(' ');
  const shop = latin(company.companyName) || 'FIX Appliance';
  const technician = latin(company.technicianName);
  const tel = telHref(company.companyPhone);
  const facts = [
    ['Model', latin(appliance.model)],
    ['Serial number', latin(appliance.serialNumber)],
    ['Manufactured', latin(appliance.manufactureDate)],
  ].filter(([, value]) => value);
  const retired = appliance.status === 'retired';

  let planHtml = '';
  if (plan) {
    const member = plan.status === 'active' || plan.status === 'past_due';
    const next = nextMaintenance(plan);
    planHtml = member
      ? `<div class="plan on"><b>Protected by ${escapeHtml(shop)} Care Plan</b>${
          next ? `<span>Next maintenance: ${escapeHtml(formatMonth(next))}</span>` : ''
        }</div>`
      : '<div class="plan off"><b>Care Plan is not active</b><span>Ask us how to renew it.</span></div>';
  }

  const historyHtml = history.length
    ? `<ol class="history">${history
        .map(
          (entry, index) => `<li><button type="button" class="visit" data-i="${index}"><time>${escapeHtml(formatDay(entry.date))}</time><b>${escapeHtml(entry.label || entry.kind)}</b>${
            entry.report ? `<em>${escapeHtml(entry.report)}</em>` : ''
          }</button></li>`
        )
        .join('')}</ol>`
    : '<p class="muted">No service records yet.</p>';

  const buttons = tel
    ? `<a class="btn" href="tel:${escapeHtml(tel)}">Call for service</a><a class="btn alt" href="sms:${escapeHtml(tel)}">Text us</a>`
    : `<a class="btn" href="${SHOP_SITE}">Book service</a>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<meta name="robots" content="noindex, nofollow"/>
<title>${escapeHtml(title)} — Appliance Passport</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:#eef2f6;color:#1a1a1a}
  header{background:#14557F;color:#fff;padding:22px 18px 30px}
  header .shop{font-size:20px;font-weight:800}
  header .sub{opacity:.8;font-size:14px;margin-top:2px}
  main{max-width:560px;margin:-18px auto 0;padding:0 12px 24px}
  .card{background:#fff;border-radius:16px;padding:18px;margin-bottom:12px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
  h1{margin:0 0 10px;font-size:24px}
  h2{margin:0 0 10px;font-size:18px}
  dl{margin:0;display:grid;grid-template-columns:auto 1fr;gap:6px 14px;font-size:15px}
  dt{color:#5f6770}
  dd{margin:0;font-weight:600;word-break:break-all}
  .plan{margin-top:14px;padding:12px 14px;border-radius:12px;display:flex;flex-direction:column;gap:2px}
  .plan.on{background:#e8f5e9;color:#1b5e20;border:1px solid #66bb6a}
  .plan.off{background:#f5f5f5;color:#555;border:1px solid #ddd}
  .retired{margin-top:10px;color:#8a6d00;font-weight:600}
  .history{list-style:none;margin:0;padding:0}
  .history li{border-top:1px solid #edf0f2}
  .history li:first-child{border-top:0}
  .visit{display:block;width:100%;text-align:left;background:none;border:0;padding:10px 0;font:inherit;color:inherit;cursor:pointer}
  .visit time,.visit b,.visit em{display:block}
  .history time{color:#5f6770;font-size:13px}
  .history em{font-style:normal;color:#1a1a1a;font-size:14px;white-space:pre-line}
  .line{display:block;padding:10px 0;border-top:1px solid #edf0f2}
  .line span{display:block;color:#5f6770;font-size:12px;font-weight:700;letter-spacing:.04em;text-transform:uppercase}
  .line b,.line a{display:block;margin-top:2px;font-size:16px;font-weight:700;color:#1a1a1a;text-decoration:none}
  .sheet{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:flex-end;justify-content:center}
  .sheet[hidden]{display:none}
  .panel{background:#fff;border-radius:16px 16px 0 0;padding:18px;width:min(560px,100%);max-height:85vh;overflow:auto}
  .panel h3{margin:0 0 8px;font-size:18px}
  .panel p{margin:6px 0;font-size:14px}
  .panel label{display:block;font-size:13px;color:#5f6770;margin-top:10px}
  .panel input,.panel textarea{width:100%;padding:10px;border:1px solid #ccd;border-radius:8px;font:inherit}
  .panel .row{display:flex;gap:8px;margin-top:14px}
  .err{color:#b71c1c;font-size:13px}
  .muted{color:#5f6770;margin:0}
  .cta{display:flex;gap:10px}
  .btn{flex:1;text-align:center;padding:14px;border-radius:12px;background:#14557F;color:#fff;text-decoration:none;font-weight:700}
  .btn.alt{background:#fff;color:#14557F;border:2px solid #14557F}
  footer{text-align:center;color:#78909c;font-size:12px;padding:6px 12px 28px}
  footer a{color:#78909c}
</style>
</head>
<body>
<header><div class="shop">${escapeHtml(shop)}</div><div class="sub">Digital Appliance Passport</div></header>
<main>
  <section class="card">
    <h1>${escapeHtml(title)}</h1>
    ${facts.length ? `<dl>${facts.map(([k, v]) => `<dt>${k}</dt><dd>${escapeHtml(v)}</dd>`).join('')}</dl>` : ''}
    ${retired ? '<div class="retired">This appliance has been replaced.</div>' : ''}
    ${planHtml}
  </section>
  <section class="card"><h2>Service history</h2>${historyHtml}
    <button type="button" class="btn alt" id="addVisit" style="margin-top:12px">Add a service record</button>
  </section>
  <section class="card cta">${buttons}</section>
</main>
<footer>Passport ID ${escapeHtml(code)} · <a href="${SHOP_SITE}">fix-appliance.ca</a></footer>
<div class="sheet" id="sheet" hidden><div class="panel" id="panel"></div></div>
<script>
const HISTORY = ${JSON.stringify(history.map((entry) => ({
    date: formatDay(entry.date),
    kind: entry.label || entry.kind,
    report: entry.report || '',
    parts: entry.items,
    ...visitWho(entry, shop, tel, technician),
  })))};
const sheet = document.getElementById('sheet');
const panel = document.getElementById('panel');
function text(value) {
  const node = document.createElement('span');
  node.textContent = value || '';
  return node.innerHTML;
}
function phoneHtml(value) {
  const phone = text(value);
  return phone ? '<a href="tel:' + phone + '">' + phone + '</a>' : '';
}
function closeSheet() { sheet.hidden = true; }
sheet.addEventListener('click', (event) => { if (event.target === sheet) closeSheet(); });
document.querySelectorAll('.visit').forEach((button) => {
  button.addEventListener('click', () => {
    const entry = HISTORY[Number(button.dataset.i)] || {};
    const parts = Array.isArray(entry.parts) ? entry.parts.filter(Boolean) : [];
    panel.innerHTML = '<h3>' + text(entry.kind) + '</h3>'
      + '<p>' + text(entry.date) + '</p>'
      + (entry.report ? '<p>' + text(entry.report) + '</p>' : '')
      + (parts.length ? '<div class="line"><span>Parts</span>' + parts.map((part) => '<b>' + text(part) + '</b>').join('') + '</div>' : '')
      + (entry.technician ? '<div class="line"><span>Technician</span><b>' + text(entry.technician) + '</b></div>' : '')
      + (entry.company ? '<div class="line"><span>Company</span><b>' + text(entry.company) + '</b></div>' : '')
      + (entry.phone ? '<div class="line"><span>Phone</span><b>' + phoneHtml(entry.phone) + '</b></div>' : '')
      + '<div class="row"><button type="button" class="btn" id="closeSheet">Close</button></div>';
    panel.querySelector('#closeSheet').addEventListener('click', closeSheet);
    sheet.hidden = false;
  });
});
document.getElementById('addVisit').addEventListener('click', () => {
  panel.innerHTML = '<h3>Add a service record</h3>'
    + '<p>For a technician from another company. This is added to the appliance record as written.</p>'
    + '<label>Company<input id="vShop" maxlength="80"></label>'
    + '<label>Technician<input id="vBy" maxlength="60"></label>'
    + '<label>Phone<input id="vPhone" maxlength="20" inputmode="tel"></label>'
    + '<label>What was done<textarea id="vWork" maxlength="600" rows="3"></textarea></label>'
    + '<p class="err" id="vErr" hidden></p>'
    + '<div class="row"><button type="button" class="btn alt" id="closeSheet">Cancel</button>'
    + '<button type="button" class="btn" id="vSave">Save</button></div>';
  panel.querySelector('#closeSheet').addEventListener('click', closeSheet);
  panel.querySelector('#vSave').addEventListener('click', async () => {
    const err = panel.querySelector('#vErr');
    const body = {
      shop: panel.querySelector('#vShop').value,
      by: panel.querySelector('#vBy').value,
      phone: panel.querySelector('#vPhone').value,
      work: panel.querySelector('#vWork').value,
    };
    if (!body.shop.trim() || !body.work.trim()) {
      err.textContent = 'Company and the work done are required.';
      err.hidden = false;
      return;
    }
    err.hidden = true;
    try {
      const res = await fetch(location.pathname + '/note', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error('not saved');
      location.reload();
    } catch (error) {
      err.textContent = 'Could not save. Check the connection and try again.';
      err.hidden = false;
    }
  });
  sheet.hidden = false;
});
</script>
</body>
</html>`;
}

function notFoundHtml() {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/><meta name="robots" content="noindex"/>
<title>Passport not found</title>
<style>body{font-family:sans-serif;background:#14557F;color:#fff;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#fff;color:#14557F;border-radius:16px;padding:28px;max-width:420px;text-align:center}a{color:#14557F}</style></head>
<body><div class="card"><h1>Passport not found</h1><p>Check the code on the sticker or contact us at <a href="${SHOP_SITE}">fix-appliance.ca</a>.</p></div></body></html>`;
}

const NOTE_LIMIT_PER_DAY = 10;

/** Только печатная латиница: кириллица и теги вырезаются, а не публикуются. */
function latinNote(value, max) {
  return String(value ?? '')
    .replace(/[^\x20-\x7E]/g, ' ')
    .replace(/[<>]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max);
}

/** Запись чужого мастера. Пустые компания или работа не принимаются. */
function cleanNote(body) {
  const src = body && typeof body === 'object' ? body : {};
  const shop = latinNote(src.shop, 80);
  const work = latinNote(src.work, 600);
  if (!shop || !work) return null;
  return {
    shop,
    by: latinNote(src.by, 60),
    phone: telHref(src.phone),
    work,
  };
}

async function addOutsideNote(code, body, ip) {
  const note = cleanNote(body);
  if (!note) return { status: 400, error: 'company and work are required' };
  const company = companyRef();
  const ref = company.collection('appliances').doc(code);
  const snap = await ref.get();
  if (!snap.exists) return { status: 404, error: 'not found' };
  const day = new Date().toISOString().slice(0, 10);
  const codeDay = `${code}_${day}`;
  const recent = await company
    .collection('passport_notes')
    .where('codeDay', '==', codeDay)
    .limit(NOTE_LIMIT_PER_DAY)
    .get();
  if (recent.size >= NOTE_LIMIT_PER_DAY) return { status: 429, error: 'too many records today' };
  const entry = {
    date: new Date().toISOString(),
    kind: 'repair',
    outside: true,
    shop: note.shop,
    by: note.by,
    phone: note.phone,
    note: note.work,
    items: [],
  };
  await ref.set(
    { serviceLog: FieldValue.arrayUnion(entry), updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
  await company.collection('passport_notes').add({
    code,
    day,
    codeDay,
    ip: String(ip || '').slice(0, 64),
    at: new Date().toISOString(),
  });
  return { status: 200 };
}

async function loadPassport(code) {
  const company = companyRef();
  const snap = await company.collection('appliances').doc(code).get();
  if (!snap.exists) return null;
  const appliance = snap.data() || {};
  const [planSnap, docsSnap, jobsSnap] = await Promise.all([
    appliance.planId ? company.collection('care_plans').doc(String(appliance.planId)).get() : null,
    company.collection('settings').doc('documents').get(),
    company.collection('jobs').where('applianceIds', 'array-contains', code).get(),
  ]);
  const plan = planSnap && planSnap.exists ? planSnap.data() || {} : null;
  const docs = docsSnap.exists ? docsSnap.data() || {} : {};
  const jobs = jobsSnap.docs.map((doc) => doc.data() || {});
  return {
    appliance,
    plan,
    company: {
      companyName: docs.companyName,
      companyPhone: docs.companyPhone,
      technicianName: docs.technicianName,
    },
    history: buildHistory(appliance, jobs),
    code,
  };
}

async function handlePassportRequest(req, res) {
  res.set('X-Robots-Tag', 'noindex, nofollow');
  const code = passportCodeFromPath(req.path || req.url);
  if (!code) {
    res.status(404).set('Content-Type', 'text/html; charset=utf-8').send(notFoundHtml());
    return;
  }
  if (req.method === 'POST' && /\/note\/?$/.test(String(req.path || req.url))) {
    res.set('Content-Type', 'application/json; charset=utf-8');
    try {
      const result = await addOutsideNote(code, req.body, req.ip);
      res.status(result.status).json(result.error ? { error: result.error } : { ok: true });
    } catch (error) {
      console.error('passport note:', error);
      res.status(500).json({ error: 'not saved' });
    }
    return;
  }
  res.set('Content-Type', 'text/html; charset=utf-8');
  try {
    const data = await loadPassport(code);
    if (!data) {
      res.status(404).send(notFoundHtml());
      return;
    }
    res.set('Cache-Control', 'public, max-age=60, s-maxage=60');
    res.status(200).send(renderPassportHtml(data));
  } catch (error) {
    console.error('passport page:', error);
    res.status(500).send('Passport is temporarily unavailable');
  }
}

module.exports = {
  isPassportPath,
  passportCodeFromPath,
  renderPassportHtml,
  handlePassportRequest,
  _internals: { addOutsideNote, applianceEnglish, buildHistory, cleanNote, escapeHtml, jobServiceDate, latin, loadPassport, nextMaintenance, reportText },
};
