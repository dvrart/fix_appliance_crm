import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getAuth,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signOut,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import {
  initializeFirestore,
  persistentLocalCache,
  getFirestore,
  collection,
  doc,
  getDoc,
  setDoc,
  updateDoc,
  onSnapshot,
  query,
  where,
  serverTimestamp,
  Timestamp,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';
import {
  getStorage,
  ref as storageRef,
  uploadBytes,
  getDownloadURL,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-storage.js';

import {
  OWNER_UID,
  num,
  isInvoiceDoc,
  isEstimateDoc,
  isPartItem,
  partSourceOf,
  documentSubtotal,
  documentTax,
  documentTotal,
  paymentsOf,
  calcJobPayout,
  calcBalanceSummary,
} from './payout.js';

const FIREBASE_CONFIG = {
  apiKey: 'AIzaSyC_jEoKtsoQlnkWENAK89HAsuXBVkhvY_s',
  appId: '1:772324431093:web:5fc387809e29e86d2fe1bc',
  messagingSenderId: '772324431093',
  projectId: 'fix-appliance-crm',
  authDomain: 'fix-appliance-crm.firebaseapp.com',
  storageBucket: 'fix-appliance-crm.firebasestorage.app',
};

let COMPANY_ID = 'fix_appliance_ca';
const FUNCTIONS_URL = 'https://us-central1-fix-appliance-crm.cloudfunctions.net';
const CALL_AUDIO_URL = 'https://callrecordingaudio-wmdrqa3n7q-uc.a.run.app';

const fbApp = initializeApp(FIREBASE_CONFIG);
const auth = getAuth(fbApp);
let db;
try {
  db = initializeFirestore(fbApp, { localCache: persistentLocalCache() });
} catch (_) {
  db = getFirestore(fbApp);
}
const storage = getStorage(fbApp);

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/tech/sw.js').catch(() => {});
  });
}

// ------------------------------- State -------------------------------
const state = {
  lang: localStorage.getItem('fix_tech_lang') || 'ru',
  online: navigator.onLine,
  authReady: false,
  user: null,
  forcedNotice: '',
  techProfile: null,
  shopDocs: { companyName: 'Fix Appliance', invoiceTerms: '', warrantyTerms: '' },
  shopPhone: localStorage.getItem('fix_shop_phone') || '',
  jobs: [],
  settlements: [],
  guideLocal: [],
  guideRemote: [],
  tab: 'calendar', // calendar | jobs | earnings | guide
  selectedDate: startOfDay(new Date()),
  jobsFilter: 'active', // active | all
  jobsQuery: '',
  guideCategory: 'all',
  guideKind: 'all',
  guideQuery: '',
  expandedGuideId: '',
  openJobId: '',
  jobTab: 'details', // details | finance | comms
  jobMessages: [],
  jobCalls: [],
  busy: false,
};

const unsubs = {
  profile: null,
  jobs: null,
  settlements: null,
  shopDocs: null,
  guide: null,
  jobMsgs: null,
  jobCallsA: null,
  jobCallsB: null,
};

function tr(ru, en) {
  return state.lang === 'en' ? en : ru;
}

function toggleLang() {
  state.lang = state.lang === 'en' ? 'ru' : 'en';
  localStorage.setItem('fix_tech_lang', state.lang);
  render();
}

window.addEventListener('online', () => {
  state.online = true;
  render();
});
window.addEventListener('offline', () => {
  state.online = false;
  render();
});

// ------------------------------- Helpers -------------------------------
function esc(v) {
  return String(v ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function money(v) {
  const n = num(v, 0);
  const sign = n < -0.004 ? '-' : '';
  return `${sign}$${Math.abs(n).toFixed(2)}`;
}

function parseDate(v) {
  if (!v) return null;
  if (v instanceof Date) return isNaN(v.getTime()) ? null : v;
  if (typeof v.toDate === 'function') return v.toDate();
  if (typeof v.seconds === 'number') return new Date(v.seconds * 1000);
  const d = new Date(v);
  return isNaN(d.getTime()) ? null : d;
}

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function sameDay(a, b) {
  return (
    a &&
    b &&
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

function fmtDate(d) {
  const dt = parseDate(d);
  if (!dt) return '—';
  return dt.toLocaleDateString(state.lang === 'en' ? 'en-CA' : 'ru-RU', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });
}

function fmtTime(d) {
  const dt = parseDate(d);
  if (!dt) return '';
  return dt.toLocaleTimeString(state.lang === 'en' ? 'en-CA' : 'ru-RU', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
}

function fmtDateTime(d) {
  const dt = parseDate(d);
  if (!dt) return tr('Не назначено', 'Unscheduled');
  return `${fmtDate(dt)} · ${fmtTime(dt)}`;
}

function toDateInputValue(d) {
  const dt = parseDate(d) || new Date();
  const y = dt.getFullYear();
  const m = String(dt.getMonth() + 1).padStart(2, '0');
  const day = String(dt.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function toTimeInputValue(d) {
  const dt = parseDate(d);
  if (!dt) return '10:00';
  return `${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
}

function normalizePhone(raw) {
  const digits = String(raw || '').replace(/\D/g, '');
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  if (String(raw || '').trim().startsWith('+') && digits.length >= 8) return `+${digits}`;
  return String(raw || '').trim();
}

function toast(msg) {
  const root = document.getElementById('toastRoot');
  if (!root) return;
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  root.innerHTML = '';
  root.appendChild(el);
  setTimeout(() => {
    if (el.parentNode) el.parentNode.removeChild(el);
  }, 2800);
}

const STATUS_META = [
  { key: 'Вызов', ru: 'Вызов', en: 'Service Call', color: '#1E88E5' },
  { key: 'Ожидание', ru: 'Ожидание', en: 'Waiting', color: '#546E7A' },
  { key: 'Ожидание запчасти', ru: 'Запчасти', en: 'Waiting Part', color: '#FB8C00' },
  { key: 'Установка', ru: 'Установка', en: 'Installation', color: '#3F51B5' },
  { key: 'Повторный визит', ru: 'Повторный визит', en: 'Recall Visit', color: '#5C6BC0' },
  { key: 'Позвонить', ru: 'Позвонить', en: 'Call Back', color: '#00897B' },
  { key: 'Депозит', ru: 'Депозит', en: 'Deposit', color: '#FFB300' },
  { key: 'Ожидание оплаты', ru: 'Ожидание оплаты', en: 'Awaiting Payment', color: '#546E7A' },
  { key: 'Завершено', ru: 'Готово', en: 'Completed', color: '#2E7D32' },
  { key: 'Отменено', ru: 'Отмена', en: 'Cancelled', color: '#E53935' },
];

function isClosedStatus(status) {
  const s = String(status || '').trim().toLowerCase();
  return (
    s === 'завершено' ||
    s === 'готово' ||
    s === 'готов' ||
    s === 'completed' ||
    s === 'отменено' ||
    s === 'отмена' ||
    s === 'cancelled' ||
    s === 'canceled'
  );
}

function statusBadgeHtml(status) {
  const raw = String(status || 'Вызов').trim();
  const found = STATUS_META.find((m) => m.key.toLowerCase() === raw.toLowerCase());
  const color = found ? found.color : '#14557F';
  const label = found ? (state.lang === 'en' ? found.en : found.ru) : raw;
  return `<span class="badge" style="background:${color}22;color:${color}">${esc(label)}</span>`;
}

function coalesceVisits(job) {
  const raw = Array.isArray(job?.visits) ? job.visits : [];
  if (raw.length > 0) {
    return raw
      .map((v, idx) => ({
        ...v,
        id: String(v.id || `v_${idx}`),
        startDate: parseDate(v.startAt) || new Date(),
        durationMinutes: num(v.durationMinutes, 120),
        outcome: String(v.outcome || 'scheduled'),
      }))
      .sort((a, b) => a.startDate - b.startDate);
  }
  const sched = parseDate(job?.scheduledAt);
  if (!sched) return [];
  return [
    {
      id: 'legacy',
      startAt: job.scheduledAt,
      startDate: sched,
      durationMinutes: num(job.durationMinutes, 120),
      outcome: 'scheduled',
      note: '',
    },
  ];
}

function syncVisitsPayload(visitsList) {
  const sorted = [...visitsList].sort((a, b) => a.startDate - b.startDate);
  const planned = sorted.filter((v) => (v.outcome || 'scheduled') === 'scheduled');
  const latest = (planned.length ? planned : sorted).slice(-1)[0] || null;
  const serialized = sorted.map((v) => {
    const copy = { ...v };
    const dt = v.startDate || parseDate(v.startAt) || new Date();
    delete copy.startDate;
    copy.id = String(copy.id || Date.now());
    copy.startAt = Timestamp.fromDate(dt);
    copy.durationMinutes = Math.max(15, Math.min(480, num(copy.durationMinutes, 120)));
    copy.outcome = String(copy.outcome || 'scheduled');
    copy.note = String(copy.note || '');
    return copy;
  });
  return {
    visits: serialized,
    scheduledAt: latest ? Timestamp.fromDate(latest.startDate) : null,
    scheduledDate: latest ? Timestamp.fromDate(latest.startDate) : null,
    durationMinutes: latest ? latest.durationMinutes : 120,
  };
}

function effectiveInitials(profile) {
  const name = String(profile?.name || profile?.email || 'T').trim();
  const parts = name.split(/\s+/).filter(Boolean);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return name.slice(0, 2).toUpperCase();
}

function effectiveBusinessName(profile) {
  const b = String(profile?.businessName || '').trim();
  if (b) return b;
  const n = String(profile?.name || '').trim();
  return n || 'Technician';
}

function techTaxMode(profile) {
  const raw = String(profile?.taxMode || '').trim().toLowerCase();
  if (raw === 'all' || raw === 'parts' || raw === 'none') return raw;
  return hasOwnTax(profile) ? 'all' : 'none';
}

function techTaxOptionValue(doc) {
  const rate = num(doc?.taxRate, 0);
  const scope = String(doc?.taxScope || '').trim().toLowerCase();
  if (rate <= 0.001 || scope === 'none') return 'none';
  const prefix = Math.abs(rate - 0.05) < 0.001 ? 'gst' : 'hst';
  return `${prefix}_${scope === 'parts' ? 'parts' : 'all'}`;
}

function parseTechTaxOption(val) {
  switch (val) {
    case 'hst_all': return { taxRate: 0.13, taxScope: 'all' };
    case 'hst_parts': return { taxRate: 0.13, taxScope: 'parts' };
    case 'gst_all': return { taxRate: 0.05, taxScope: 'all' };
    case 'gst_parts': return { taxRate: 0.05, taxScope: 'parts' };
    default: return { taxRate: 0, taxScope: 'none' };
  }
}

function hasOwnTax(profile) {
  const hst = String(profile?.hstNumber || '').trim();
  const collects = typeof profile?.collectsHst === 'boolean' ? profile.collectsHst : Boolean(hst);
  return collects && Boolean(hst);
}

function jobApplianceSummary(job) {
  const apps = Array.isArray(job?.appliances) ? job.appliances : [];
  if (apps.length > 0) {
    return apps
      .map((a) => [a.type, a.brand, a.model].filter(Boolean).join(' '))
      .filter(Boolean)
      .join(', ');
  }
  return [job?.applianceType, job?.brand, job?.model].filter(Boolean).join(' ') || tr('Техника', 'Appliance');
}

function jobDisplayAddress(job) {
  if (job?.hasJobSite && String(job.jobSiteAddress || '').trim()) {
    return String(job.jobSiteAddress).trim();
  }
  return String(job?.clientAddress || job?.city || '').trim();
}

function jobDisplayClient(job) {
  if (job?.hasJobSite && String(job.jobSiteName || '').trim()) {
    return String(job.jobSiteName).trim();
  }
  return String(job?.clientName || job?.clientPhone || tr('Клиент', 'Client')).trim();
}

function isIosSafariNotStandalone() {
  const ua = navigator.userAgent || '';
  const isIOS = /iPhone|iPad|iPod/i.test(ua);
  const isStandalone = window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
  return isIOS && !isStandalone;
}

// ------------------------------- Data Subscriptions -------------------------------
async function loadLocalServiceGuide() {
  try {
    const res = await fetch('/tech/service_guide.json');
    if (!res.ok) return;
    const data = await res.json();
    if (Array.isArray(data?.records)) {
      state.guideLocal = data.records;
      render();
    }
  } catch (_) {}
}
loadLocalServiceGuide();

function clearStreams() {
  for (const k of Object.keys(unsubs)) {
    if (typeof unsubs[k] === 'function') {
      unsubs[k]();
      unsubs[k] = null;
    }
  }
}

async function fetchShopPhoneIfNeeded() {
  if (!auth.currentUser) return state.shopPhone;
  try {
    const token = await auth.currentUser.getIdToken();
    const isTesterScope = COMPANY_ID.startsWith('tester_');
    const identity = isTesterScope
      ? `tester_${auth.currentUser.uid}`
      : `tech_${auth.currentUser.uid}`;
    const suffix = isTesterScope ? '&tester=1' : '';
    const res = await fetch(`${FUNCTIONS_URL}/twilioAccessToken?identity=${encodeURIComponent(identity)}${suffix}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.ok) {
      const data = await res.json();
      if (data?.shopNumber) {
        state.shopPhone = normalizePhone(data.shopNumber);
        localStorage.setItem('fix_shop_phone', state.shopPhone);
      }
    }
  } catch (_) {}
  return state.shopPhone;
}

async function resolveCompanyForUser(uid) {
  if (!uid || uid === OWNER_UID) return 'fix_appliance_ca';
  try {
    const testerSnap = await getDoc(doc(db, 'testers', uid));
    if (testerSnap.exists()) {
      const data = testerSnap.data() || {};
      if (data.role === 'technician' && data.parentCompanyId) {
        return String(data.parentCompanyId).trim();
      }
    }
  } catch (_) {}
  return 'fix_appliance_ca';
}

async function bindUserStreams(user) {
  clearStreams();
  const uid = user.uid;
  COMPANY_ID = await resolveCompanyForUser(uid);
  if (state.user?.uid !== uid) return;
  const companyDoc = doc(db, 'companies', COMPANY_ID);

  if (uid === OWNER_UID) {
    state.techProfile = {
      uid,
      name: 'Owner Preview',
      email: user.email || '',
      profitSharePercent: 100,
      businessName: 'Fix Appliance',
      collectsHst: true,
      hstNumber: '',
      etransferEmail: '',
      active: true,
    };
  } else {
    unsubs.profile = onSnapshot(
      doc(companyDoc, 'technicians', uid),
      (snap) => {
        if (!snap.exists()) {
          if (!snap.metadata.fromCache) {
            state.forcedNotice = tr('Доступ отключён владельцем', 'Access revoked by owner');
            signOut(auth);
          }
          return;
        }
        const data = snap.data() || {};
        state.techProfile = { uid: snap.id, ...data };
        if (data.active === false && !snap.metadata.fromCache) {
          state.forcedNotice = tr('Доступ отключён владельцем', 'Access revoked by owner');
          signOut(auth);
          return;
        }
        render();
      },
      () => {}
    );
  }

  const jobsQ =
    uid === OWNER_UID
      ? collection(companyDoc, 'jobs')
      : query(collection(companyDoc, 'jobs'), where('assignedTo', '==', uid));

  unsubs.jobs = onSnapshot(
    jobsQ,
    (snap) => {
      const list = [];
      snap.forEach((d) => {
        const raw = d.data() || {};
        if (!raw.deletedAt) list.push({ id: d.id, ...raw });
      });
      list.sort((a, b) => {
        const da = parseDate(a.scheduledAt) || parseDate(a.createdAt) || new Date(0);
        const db2 = parseDate(b.scheduledAt) || parseDate(b.createdAt) || new Date(0);
        return db2 - da;
      });
      state.jobs = list;
      render();
    },
    () => {}
  );

  const setQ =
    uid === OWNER_UID
      ? collection(companyDoc, 'technician_settlements')
      : query(collection(companyDoc, 'technician_settlements'), where('technicianId', '==', uid));

  unsubs.settlements = onSnapshot(
    setQ,
    (snap) => {
      const list = [];
      snap.forEach((d) => list.push({ id: d.id, ...(d.data() || {}) }));
      list.sort((a, b) => (parseDate(b.createdAt) || 0) - (parseDate(a.createdAt) || 0));
      state.settlements = list;
      render();
    },
    () => {}
  );

  unsubs.shopDocs = onSnapshot(
    doc(companyDoc, 'settings', 'documents'),
    (snap) => {
      if (snap.exists()) {
        state.shopDocs = { ...state.shopDocs, ...(snap.data() || {}) };
      }
    },
    () => {}
  );

  unsubs.guide = onSnapshot(
    collection(companyDoc, 'service_guide'),
    (snap) => {
      const list = [];
      snap.forEach((d) => list.push({ id: d.id, ...(d.data() || {}) }));
      state.guideRemote = list;
      render();
    },
    () => {}
  );

  fetchShopPhoneIfNeeded();
}

function bindOpenJobComms(jobId) {
  if (unsubs.jobMsgs) {
    unsubs.jobMsgs();
    unsubs.jobMsgs = null;
  }
  if (unsubs.jobCallsA) {
    unsubs.jobCallsA();
    unsubs.jobCallsA = null;
  }
  if (unsubs.jobCallsB) {
    unsubs.jobCallsB();
    unsubs.jobCallsB = null;
  }
  state.jobMessages = [];
  state.jobCalls = [];
  if (!jobId || !state.user) return;

  const companyDoc = doc(db, 'companies', COMPANY_ID);
  unsubs.jobMsgs = onSnapshot(
    query(collection(companyDoc, 'messages'), where('jobId', '==', jobId)),
    (snap) => {
      const items = [];
      snap.forEach((d) => items.push({ id: d.id, ...(d.data() || {}) }));
      items.sort((a, b) => (parseDate(a.createdAt) || 0) - (parseDate(b.createdAt) || 0));
      state.jobMessages = items;
      render();
    },
    () => {}
  );

  const callMap = new Map();
  const refreshCalls = () => {
    const arr = Array.from(callMap.values());
    arr.sort(
      (a, b) =>
        (parseDate(b.startTime) || parseDate(b.createdAt) || 0) -
        (parseDate(a.startTime) || parseDate(a.createdAt) || 0)
    );
    state.jobCalls = arr;
    render();
  };

  unsubs.jobCallsA = onSnapshot(
    query(collection(companyDoc, 'calls'), where('jobId', '==', jobId)),
    (snap) => {
      snap.forEach((d) => callMap.set(d.id, { id: d.id, ...(d.data() || {}) }));
      refreshCalls();
    },
    () => {}
  );
  unsubs.jobCallsB = onSnapshot(
    query(collection(companyDoc, 'calls'), where('createdJobId', '==', jobId)),
    (snap) => {
      snap.forEach((d) => callMap.set(d.id, { id: d.id, ...(d.data() || {}) }));
      refreshCalls();
    },
    () => {}
  );
}

onAuthStateChanged(auth, (user) => {
  state.authReady = true;
  state.user = user;
  if (user) {
    bindUserStreams(user);
  } else {
    clearStreams();
    state.techProfile = null;
    state.jobs = [];
    state.settlements = [];
    state.openJobId = '';
  }
  render();
});

// ------------------------------- Image Compression & Upload -------------------------------
async function compressImageFile(file, maxSide = 1800, quality = 0.84) {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        let { width, height } = img;
        if (width > maxSide || height > maxSide) {
          if (width >= height) {
            height = Math.round((height * maxSide) / width);
            width = maxSide;
          } else {
            width = Math.round((width * maxSide) / height);
            height = maxSide;
          }
        }
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, width, height);
        canvas.toBlob(
          (blob) => resolve(blob || file),
          'image/jpeg',
          quality
        );
      };
      img.onerror = () => resolve(file);
      img.src = reader.result;
    };
    reader.onerror = () => resolve(file);
    reader.readAsDataURL(file);
  });
}

async function uploadJobAttachment(job, file, kind = 'photo') {
  const blob = await compressImageFile(file);
  const prefix = kind === 'part_receipt' ? 'part_receipt' : 'photo';
  const fileName = `${prefix}_${Date.now()}.jpg`;
  const path = COMPANY_ID.startsWith('tester_')
    ? `companies/${COMPANY_ID}/jobs/${job.id}/attachments/${fileName}`
    : `jobs/${job.id}/attachments/${fileName}`;
  const sRef = storageRef(storage, path);
  await uploadBytes(sRef, blob, { contentType: 'image/jpeg' });
  const url = await getDownloadURL(sRef);
  const entry = {
    name: fileName,
    url,
    kind,
    uploadedAt: new Date().toISOString(),
  };
  const nextAttachments = [...(Array.isArray(job.attachments) ? job.attachments : []), entry];
  await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), {
    attachments: nextAttachments,
  });
  return url;
}

// ------------------------------- Actions -------------------------------
async function callClientViaBridge(job, rawPhone) {
  const clientPhone = normalizePhone(rawPhone);
  if (!clientPhone) {
    toast(tr('Номер клиента не указан', 'Client phone is missing'));
    return;
  }
  const techCell = normalizePhone(state.techProfile?.phone || '');
  if (!techCell && state.user?.uid !== OWNER_UID) {
    toast(
      tr(
        'В профиле мастера не указан ваш сотовый — звоню напрямую',
        'Your cell is not set in profile — dialing directly'
      )
    );
    window.location.href = `tel:${clientPhone}`;
    return;
  }
  toast(tr('Подключаю рабочий мост…', 'Preparing office call bridge…'));
  const shop = (await fetchShopPhoneIfNeeded()) || state.shopPhone;
  if (!shop) {
    window.location.href = `tel:${clientPhone}`;
    return;
  }
  const pendingId =
    state.user.uid === OWNER_UID ? 'pending_cell_call' : `pending_cell_call_${state.user.uid}`;
  try {
    await setDoc(doc(db, 'companies', COMPANY_ID, 'settings', pendingId), {
      phone: clientPhone,
      jobId: job.id,
      at: serverTimestamp(),
    });
  } catch (e) {
    toast(tr('Ошибка моста, звоню напрямую', 'Bridge error, dialing directly'));
    window.location.href = `tel:${clientPhone}`;
    return;
  }
  window.location.href = `tel:${shop}`;
}

async function sendJobSms(job, toPhone, text) {
  const cleanText = String(text || '').trim();
  const to = normalizePhone(toPhone);
  if (!cleanText || !to) return false;
  const token = await auth.currentUser.getIdToken();
  const res = await fetch(`${FUNCTIONS_URL}/sendSms`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      to,
      body: cleanText,
      jobId: job.id,
      clientId: job.clientId || null,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || `HTTP ${res.status}`);
  }
  return true;
}

function generateTechDocNumber(job, docType) {
  const prefix = docType === 'Estimate' ? 'EST' : 'INV';
  const init = effectiveInitials(state.techProfile);
  const now = new Date();
  const y = String(now.getFullYear()).slice(-2);
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  const seq = (Array.isArray(job?.documents) ? job.documents.length : 0) + 1;
  return `${prefix}-${init}-${y}${m}${d}-${seq}`;
}

// ------------------------------- Modals -------------------------------
function closeModal() {
  const root = document.getElementById('modalRoot');
  if (root) root.innerHTML = '';
}

function openModal(html, onBind) {
  const root = document.getElementById('modalRoot');
  if (!root) return;
  root.innerHTML = `
    <div class="modal-backdrop" id="modalBackdrop">
      <div class="modal-sheet">
        ${html}
      </div>
    </div>
  `;
  document.getElementById('modalBackdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'modalBackdrop') closeModal();
  });
  if (onBind) onBind(root);
}

function showPhotoViewer(url) {
  openModal(
    `
    <div style="text-align:right;margin-bottom:8px">
      <button class="btn btn-outline btn-sm" id="closeImgBtn">${tr('Закрыть', 'Close')}</button>
    </div>
    <img src="${esc(url)}" style="width:100%;border-radius:12px;display:block" />
    `,
    (root) => {
      root.querySelector('#closeImgBtn')?.addEventListener('click', closeModal);
    }
  );
}

function showVisitModal(job) {
  const visits = coalesceVisits(job);
  const active = visits.filter((v) => v.outcome === 'scheduled').slice(-1)[0] || visits.slice(-1)[0];
  const dateVal = toDateInputValue(active?.startDate || new Date());
  const timeVal = toTimeInputValue(active?.startDate || null);

  openModal(
    `
    <h3>${tr('Дата и время визита', 'Schedule visit')}</h3>
    <div class="field">
      <label>${tr('Дата', 'Date')}</label>
      <input type="date" id="vDate" class="input" value="${esc(dateVal)}" />
    </div>
    <div class="field">
      <label>${tr('Время начала', 'Start time')}</label>
      <input type="time" id="vTime" class="input" value="${esc(timeVal)}" />
    </div>
    <div style="display:flex;gap:8px;margin-top:14px">
      <button class="btn btn-outline btn-block" id="vCancel">${tr('Отмена', 'Cancel')}</button>
      <button class="btn btn-primary btn-block" id="vSave">${tr('Сохранить', 'Save')}</button>
    </div>
    `,
    (root) => {
      root.querySelector('#vCancel')?.addEventListener('click', closeModal);
      root.querySelector('#vSave')?.addEventListener('click', async () => {
        const dStr = root.querySelector('#vDate').value;
        const tStr = root.querySelector('#vTime').value || '10:00';
        if (!dStr) return;
        const [yy, mm, dd] = dStr.split('-').map(Number);
        const [hh, mi] = tStr.split(':').map(Number);
        const nextStart = new Date(yy, mm - 1, dd, hh || 0, mi || 0);

        const list = coalesceVisits(job);
        const schedIdx = list.findIndex((v) => v.outcome === 'scheduled');
        if (schedIdx >= 0) {
          list[schedIdx] = { ...list[schedIdx], startDate: nextStart };
        } else {
          list.push({
            id: String(Date.now()),
            startDate: nextStart,
            durationMinutes: 120,
            outcome: 'scheduled',
            note: '',
          });
        }
        const patch = syncVisitsPayload(list);
        await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), patch);
        closeModal();
        toast(tr('Время визита обновлено', 'Visit updated'));
      });
    }
  );
}

function showApplianceModal(job, index = -1) {
  const apps = Array.isArray(job.appliances) ? [...job.appliances] : [];
  const existing = index >= 0 ? apps[index] || {} : {};
  const types = [
    'Холодильник',
    'Стиральная машина',
    'Сушилка',
    'Посудомойка',
    'Плита/Духовка',
    'Варочная панель',
    'Микроволновка',
    'Морозильник',
  ];

  openModal(
    `
    <h3>${index >= 0 ? tr('Редактировать технику', 'Edit appliance') : tr('Добавить технику', 'Add appliance')}</h3>
    <div class="field">
      <label>${tr('Тип техники', 'Appliance type')}</label>
      <input list="appTypesList" id="apType" class="input" value="${esc(existing.type || '')}" placeholder="${tr('Например: Стиральная машина', 'e.g. Washer')}" />
      <datalist id="appTypesList">
        ${types.map((t) => `<option value="${esc(t)}"></option>`).join('')}
      </datalist>
    </div>
    <div class="field">
      <label>${tr('Марка (Brand)', 'Brand')}</label>
      <input id="apBrand" class="input" value="${esc(existing.brand || '')}" placeholder="LG, Samsung, Whirlpool..." />
    </div>
    <div class="field">
      <label>${tr('Модель (Model)', 'Model number')}</label>
      <input id="apModel" class="input" value="${esc(existing.model || '')}" />
    </div>
    <div class="field">
      <label>${tr('Серийный номер (S/N)', 'Serial number')}</label>
      <input id="apSerial" class="input" value="${esc(existing.serialNumber || existing.serial || '')}" />
    </div>
    <div style="display:flex;gap:8px;margin-top:14px">
      <button class="btn btn-outline btn-block" id="apCancel">${tr('Отмена', 'Cancel')}</button>
      <button class="btn btn-primary btn-block" id="apSave">${tr('Сохранить', 'Save')}</button>
    </div>
    `,
    (root) => {
      root.querySelector('#apCancel')?.addEventListener('click', closeModal);
      root.querySelector('#apSave')?.addEventListener('click', async () => {
        const entry = {
          ...(existing || {}),
          type: root.querySelector('#apType').value.trim() || tr('Техника', 'Appliance'),
          brand: root.querySelector('#apBrand').value.trim(),
          model: root.querySelector('#apModel').value.trim(),
          serialNumber: root.querySelector('#apSerial').value.trim(),
        };
        if (index >= 0) {
          apps[index] = entry;
        } else {
          apps.push(entry);
        }
        const first = apps[0] || {};
        await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), {
          appliances: apps,
          applianceType: first.type || '',
          brand: first.brand || '',
          model: first.model || '',
        });
        closeModal();
        toast(tr('Техника сохранена', 'Appliance saved'));
      });
    }
  );
}

function showItemModal(job, docIndex, itemIndex = -1) {
  const docs = Array.isArray(job.documents) ? [...job.documents] : [];
  const targetDoc = { ...(docs[docIndex] || {}) };
  const items = Array.isArray(targetDoc.items) ? [...targetDoc.items] : [];
  const existing = itemIndex >= 0 ? { ...(items[itemIndex] || {}) } : null;

  let isPart = existing ? isPartItem(existing) : false;
  let partSource = existing ? partSourceOf(existing) : 'tech';
  const fromOfficeLocked = existing && partSource === 'owner';
  let receiptUrl = String(existing?.receiptUrl || '').trim();
  let uploading = false;

  const renderModalInner = () => {
    openModal(
      `
      <h3>${existing ? tr('Позиция счёта', 'Edit line item') : tr('Добавить позицию', 'Add line item')}</h3>
      <div class="chip-row" style="margin-bottom:12px">
        <button type="button" class="chip ${!isPart ? 'active' : ''}" id="kindService" ${fromOfficeLocked ? 'disabled' : ''}>
          ${tr('Работа', 'Service / Labour')}
        </button>
        <button type="button" class="chip ${isPart ? 'active' : ''}" id="kindPart" ${fromOfficeLocked ? 'disabled' : ''}>
          ${tr('Запчасть', 'Part')}
        </button>
      </div>
      <div class="field">
        <label>${tr('Название в счёте (по-английски для клиента)', 'Description on invoice')}</label>
        <input id="itName" class="input" value="${esc(existing?.name || '')}" placeholder="${isPart ? 'Drain pump assembly' : 'Diagnostic & repair labour'}" />
      </div>
      <div style="display:grid;grid-template-columns:2fr 1fr;gap:10px">
        <div class="field">
          <label>${tr('Цена для клиента ($)', 'Client price ($)')}</label>
          <input id="itPrice" type="number" step="0.01" class="input" value="${existing?.price !== undefined ? esc(existing.price) : ''}" />
        </div>
        <div class="field">
          <label>${tr('Кол-во', 'Qty')}</label>
          <input id="itQty" type="number" step="1" min="1" class="input" value="${esc(existing?.qty ?? 1)}" />
        </div>
      </div>
      <div id="partExtra" class="${isPart ? '' : 'hidden'}">
        <div class="field">
          <label>${tr('Источник детали', 'Part source')}</label>
          <div style="font-size:13px;font-weight:700;color:var(--primary);margin-bottom:6px">
            ${fromOfficeLocked ? tr('Выдал офис (себестоимость задаёт владелец)', 'Provided by office (cost set by owner)') : tr('Купил мастер (нужно фото чека)', 'Bought by technician (receipt photo required)')}
          </div>
        </div>
        <div class="field">
          <label>${tr('Закупка за 1 шт. по чеку ($)', 'Purchase cost per unit ($)')}</label>
          <input id="itCost" type="number" step="0.01" class="input" value="${existing?.costPrice !== undefined ? esc(existing.costPrice) : ''}" ${fromOfficeLocked ? 'readonly' : ''} />
        </div>
        ${
          !fromOfficeLocked
            ? `
            <div class="field">
              <input type="file" id="itReceiptInput" accept="image/*" class="hidden" />
              <button type="button" class="btn btn-outline btn-block" id="itReceiptBtn">
                ${
                  uploading
                    ? tr('Загрузка чека…', 'Uploading receipt…')
                    : receiptUrl
                      ? tr('Чек прикреплён (заменить)', 'Receipt attached (replace)')
                      : tr('Сфотографировать / прикрепить чек', 'Attach receipt photo')
                }
              </button>
              ${
                !receiptUrl
                  ? `<div style="color:var(--danger);font-size:11.5px;font-weight:700;margin-top:5px">${tr('Без фото чека сумма детали не вычитается из чистой прибыли.', 'Without a receipt photo, part cost is not deducted from net profit.')}</div>`
                  : ''
              }
            </div>
            `
            : ''
        }
      </div>
      <div style="display:flex;gap:8px;margin-top:14px">
        ${
          existing
            ? `<button type="button" class="btn btn-danger" id="itDelete">${tr('Удалить', 'Delete')}</button>`
            : `<button type="button" class="btn btn-outline btn-block" id="itCancel">${tr('Отмена', 'Cancel')}</button>`
        }
        <button type="button" class="btn btn-primary btn-block" id="itSave">${tr('Сохранить', 'Save')}</button>
      </div>
      `,
      (root) => {
        const preserveInputs = () => ({
          name: root.querySelector('#itName')?.value || '',
          price: root.querySelector('#itPrice')?.value || '',
          qty: root.querySelector('#itQty')?.value || '1',
          costPrice: root.querySelector('#itCost')?.value || '',
        });

        root.querySelector('#kindService')?.addEventListener('click', () => {
          if (fromOfficeLocked) return;
          const cur = preserveInputs();
          Object.assign(existing || {}, cur);
          isPart = false;
          renderModalInner();
        });
        root.querySelector('#kindPart')?.addEventListener('click', () => {
          if (fromOfficeLocked) return;
          const cur = preserveInputs();
          Object.assign(existing || {}, cur);
          isPart = true;
          partSource = 'tech';
          renderModalInner();
        });

        const fileInput = root.querySelector('#itReceiptInput');
        root.querySelector('#itReceiptBtn')?.addEventListener('click', () => fileInput?.click());
        fileInput?.addEventListener('change', async (e) => {
          const f = e.target.files?.[0];
          if (!f) return;
          uploading = true;
          const btn = root.querySelector('#itReceiptBtn');
          if (btn) btn.textContent = tr('Загрузка чека…', 'Uploading receipt…');
          try {
            receiptUrl = await uploadJobAttachment(job, f, 'part_receipt');
            toast(tr('Чек прикреплён', 'Receipt attached'));
          } catch (err) {
            toast(`${tr('Ошибка загрузки чека', 'Upload failed')}: ${err.message || err}`);
          } finally {
            uploading = false;
            if (btn) {
              btn.textContent = receiptUrl
                ? tr('Чек прикреплён (заменить)', 'Receipt attached (replace)')
                : tr('Сфотографировать / прикрепить чек', 'Attach receipt photo');
            }
          }
        });

        root.querySelector('#itCancel')?.addEventListener('click', closeModal);
        root.querySelector('#itDelete')?.addEventListener('click', async () => {
          items.splice(itemIndex, 1);
          docs[docIndex] = { ...targetDoc, items };
          await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), { documents: docs });
          closeModal();
        });

        root.querySelector('#itSave')?.addEventListener('click', async () => {
          if (uploading) return;
          const name = root.querySelector('#itName').value.trim();
          if (!name) {
            toast(tr('Введите название позиции', 'Enter item description'));
            return;
          }
          const price = num(root.querySelector('#itPrice').value, 0);
          const qty = Math.max(1, Math.round(num(root.querySelector('#itQty').value, 1)));
          const costRaw = root.querySelector('#itCost')?.value ?? '';
          const nextItem = {
            ...(existing || {}),
            name,
            price,
            qty,
            type: isPart ? 'Part' : 'Service',
          };
          if (isPart) {
            nextItem.partSource = fromOfficeLocked ? 'owner' : 'tech';
            if (String(costRaw).trim() !== '') {
              nextItem.costPrice = num(costRaw, 0);
            }
            if (!fromOfficeLocked && receiptUrl) {
              nextItem.receiptUrl = receiptUrl;
            } else if (!fromOfficeLocked) {
              delete nextItem.receiptUrl;
            }
          } else {
            delete nextItem.costPrice;
            delete nextItem.partSource;
            delete nextItem.receiptUrl;
          }

          if (itemIndex >= 0) {
            items[itemIndex] = nextItem;
          } else {
            items.push(nextItem);
          }
          docs[docIndex] = { ...targetDoc, items };
          await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), { documents: docs });
          closeModal();
        });
      }
    );
  };

  renderModalInner();
}

function showPaymentModal(job, docIndex) {
  const docs = Array.isArray(job.documents) ? [...job.documents] : [];
  const targetDoc = { ...(docs[docIndex] || {}) };
  const total = documentTotal(targetDoc);
  const paid = paymentsOf(targetDoc).paidExTips;
  const remaining = Math.max(0, Math.round((total - paid) * 100) / 100);

  openModal(
    `
    <h3>${tr('Принять оплату', 'Record payment')} · ${esc(targetDoc.number || '')}</h3>
    <div style="font-size:13px;color:var(--muted);margin-bottom:10px">
      ${tr('Остаток по счёту', 'Balance remaining')}: <strong>${money(remaining)}</strong>
    </div>
    <div class="field">
      <label>${tr('Сумма оплаты ($)', 'Amount ($)')}</label>
      <input id="payAmt" type="number" step="0.01" class="input" value="${remaining > 0 ? remaining.toFixed(2) : ''}" />
    </div>
    <div style="display:flex;gap:8px;margin-bottom:14px">
      <button type="button" class="btn btn-outline btn-sm" id="payFull">100% (${money(remaining)})</button>
      <button type="button" class="btn btn-outline btn-sm" id="payHalf">50% (${money(remaining / 2)})</button>
    </div>
    <div style="display:flex;flex-direction:column;gap:8px">
      <button type="button" class="btn btn-green btn-block" data-method="Cash">${tr('Наличные (Cash)', 'Cash')}</button>
      <button type="button" class="btn btn-primary btn-block" data-method="e-Transfer">${tr('E-перевод (e-Transfer)', 'Interac e-Transfer')}</button>
      <button type="button" class="btn btn-outline btn-block" data-method="Card (tech)">${tr('Карта (терминал мастера)', 'Card (technician terminal)')}</button>
    </div>
    `,
    (root) => {
      const amtInput = root.querySelector('#payAmt');
      root.querySelector('#payFull')?.addEventListener('click', () => {
        amtInput.value = remaining.toFixed(2);
      });
      root.querySelector('#payHalf')?.addEventListener('click', () => {
        amtInput.value = (Math.round(remaining * 50) / 100).toFixed(2);
      });
      root.querySelectorAll('[data-method]').forEach((btn) => {
        btn.addEventListener('click', async () => {
          const amount = num(amtInput.value, 0);
          if (amount <= 0) {
            toast(tr('Введите сумму больше 0', 'Enter an amount > 0'));
            return;
          }
          const method = btn.getAttribute('data-method');
          const payments = Array.isArray(targetDoc.payments) ? [...targetDoc.payments] : [];
          payments.push({
            amount,
            method,
            date: new Date().toISOString(),
          });
          docs[docIndex] = { ...targetDoc, payments };
          const patch = { documents: docs };
          const newPaid = paid + amount;
          if (
            newPaid > 0.009 &&
            newPaid < total - 0.009 &&
            !isClosedStatus(job.status) &&
            String(job.status || '') !== 'Ожидание запчасти'
          ) {
            patch.status = 'Депозит';
          }
          await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), patch);
          closeModal();
          toast(tr('Оплата записана', 'Payment recorded'));
        });
      });
    }
  );
}

function printDocument(job, targetDoc) {
  const p = state.techProfile || {};
  const biz = effectiveBusinessName(p);
  const hst = hasOwnTax(p) ? String(p.hstNumber || '').trim() : '';
  const etransfer = String(p.etransferEmail || '').trim();
  const isEst = isEstimateDoc(targetDoc);
  const sub = documentSubtotal(targetDoc);
  const tax = documentTax(targetDoc);
  const tot = sub + tax;
  const paid = paymentsOf(targetDoc).paidExTips;
  const bal = Math.max(0, tot - paid);
  const items = Array.isArray(targetDoc.items) ? targetDoc.items : [];

  const area = document.getElementById('printArea');
  if (!area) return;
  area.innerHTML = `
    <div style="font-family:-apple-system,Segoe UI,sans-serif;max-width:700px;margin:0 auto;color:#111">
      <div style="display:flex;justify-content:space-between;border-bottom:2px solid #14557F;padding-bottom:12px;margin-bottom:16px">
        <div>
          <h2 style="margin:0;color:#14557F">${esc(biz)}</h2>
          ${etravelLine(etransfer)}
          ${hst ? `<div style="font-size:13px">HST/GST: ${esc(hst)}</div>` : ''}
          <div style="font-size:12px;color:#555">Service dispatched via Fix Appliance</div>
        </div>
        <div style="text-align:right">
          <h2 style="margin:0">${isEst ? 'ESTIMATE' : 'INVOICE'}</h2>
          <div>#${esc(targetDoc.number || '')}</div>
          <div style="font-size:13px;color:#555">${esc(fmtDate(targetDoc.createdAt || new Date()))}</div>
        </div>
      </div>
      <div style="margin-bottom:16px;font-size:14px">
        <strong>Bill To:</strong> ${esc(targetDoc.billToName || jobDisplayClient(job))}<br/>
        ${esc(targetDoc.billToAddress || jobDisplayAddress(job))}<br/>
        ${esc(targetDoc.billToPhone || job.clientPhone || '')}
      </div>
      <table style="width:100%;border-collapse:collapse;margin-bottom:16px;font-size:14px">
        <thead>
          <tr style="background:#F3F6F9;text-align:left">
            <th style="padding:8px;border-bottom:1px solid #ccc">Description</th>
            <th style="padding:8px;border-bottom:1px solid #ccc;text-align:right">Qty</th>
            <th style="padding:8px;border-bottom:1px solid #ccc;text-align:right">Amount</th>
          </tr>
        </thead>
        <tbody>
          ${items
            .map(
              (it) => `
            <tr>
              <td style="padding:8px;border-bottom:1px solid #eee">${esc(it.name || '')}</td>
              <td style="padding:8px;border-bottom:1px solid #eee;text-align:right">${esc(it.qty ?? 1)}</td>
              <td style="padding:8px;border-bottom:1px solid #eee;text-align:right">${money(num(it.qty ?? 1, 1) * num(it.price, 0))}</td>
            </tr>
          `
            )
            .join('')}
        </tbody>
      </table>
      <div style="margin-left:auto;max-width:260px;font-size:14px">
        <div style="display:flex;justify-content:space-between;padding:4px 0"><span>Subtotal:</span><span>${money(sub)}</span></div>
        ${tax > 0 ? `<div style="display:flex;justify-content:space-between;padding:4px 0"><span>Tax (${Math.round(num(targetDoc.taxRate, 0) * 100)}%):</span><span>${money(tax)}</span></div>` : ''}
        <div style="display:flex;justify-content:space-between;padding:6px 0;font-weight:800;border-top:1px solid #111"><span>Total:</span><span>${money(tot)}</span></div>
        ${!isEst ? `<div style="display:flex;justify-content:space-between;padding:4px 0;color:#16A34A"><span>Paid:</span><span>${money(paid)}</span></div>` : ''}
        ${!isEst ? `<div style="display:flex;justify-content:space-between;padding:4px 0;font-weight:800"><span>Balance Due:</span><span>${money(bal)}</span></div>` : ''}
      </div>
      ${
        state.shopDocs.warrantyTerms
          ? `<div style="margin-top:24px;font-size:12px;color:#555;border-top:1px solid #ddd;padding-top:10px">${esc(state.shopDocs.warrantyTerms)}</div>`
          : ''
      }
    </div>
  `;
  window.print();
}

function etravelLine(mail) {
  return mail ? `<div style="font-size:13px">Interac e-Transfer: ${esc(mail)}</div>` : '';
}

async function sendInvoiceSmsToClient(job, targetDoc) {
  const to = job.hasJobSite && job.jobSitePhone ? job.jobSitePhone : job.clientPhone;
  if (!to) {
    toast(tr('Нет телефона клиента', 'Client phone missing'));
    return;
  }
  const p = state.techProfile || {};
  const biz = effectiveBusinessName(p);
  const hst = hasOwnTax(p) ? String(p.hstNumber || '').trim() : '';
  const etransfer = String(p.etransferEmail || '').trim();
  const isEst = isEstimateDoc(targetDoc);
  const sub = documentSubtotal(targetDoc);
  const tax = documentTax(targetDoc);
  const tot = sub + tax;
  const paid = paymentsOf(targetDoc).paidExTips;
  const bal = Math.max(0, tot - paid);
  const lines = [
    `${biz} — ${isEst ? 'Estimate' : 'Invoice'} #${targetDoc.number || ''}`,
    ...(Array.isArray(targetDoc.items) ? targetDoc.items : []).map(
      (it) => `- ${it.name}: ${money(num(it.qty ?? 1, 1) * num(it.price, 0))}`
    ),
    tax > 0 ? `Subtotal: ${money(sub)} | Tax: ${money(tax)}` : null,
    `Total: ${money(tot)}${!isEst && paid > 0 ? ` (Paid: ${money(paid)}, Balance: ${money(bal)})` : ''}`,
    hst ? `HST/GST: ${hst}` : null,
    etransfer && bal > 0.009 ? `Interac e-Transfer: ${etransfer}` : null,
  ].filter(Boolean);

  try {
    await sendJobSms(job, to, lines.join('\n'));
    toast(tr('Отправлено клиенту по SMS', 'Sent to client via SMS'));
  } catch (e) {
    toast(`${tr('Ошибка SMS', 'SMS error')}: ${e.message || e}`);
  }
}

// ------------------------------- Renderers -------------------------------
function renderAuth() {
  const banner = isIosSafariNotStandalone()
    ? `
    <div class="ios-install-banner">
      <strong>${tr('Установка на iPhone:', 'Install on iPhone:')}</strong>
      ${tr(
        'нажмите кнопку «Поделиться» внизу экрана Safari и выберите «На экран Домой» — на рабочем столе появится иконка приложения.',
        'tap the Share button at the bottom of Safari and choose "Add to Home Screen".'
      )}
    </div>
    `
    : '';

  return `
    <div class="auth-screen">
      <div class="auth-card">
        <div style="display:flex;justify-content:flex-end;margin-bottom:4px">
          <button type="button" class="btn btn-outline btn-sm" id="langBtn">${state.lang === 'en' ? 'RU' : 'EN'}</button>
        </div>
        <div class="auth-header">
          <img src="/tech/icons/apple-touch-icon.png" alt="Fix Appliance" />
          <h2>Fix Appliance</h2>
          <p>${tr('Вход для мастеров', 'Technician Sign In')}</p>
        </div>
        ${state.forcedNotice ? `<div class="alert-error">${esc(state.forcedNotice)}</div>` : ''}
        <div id="loginError" class="alert-error hidden"></div>
        <form id="loginForm">
          <div class="field">
            <label>Email</label>
            <input id="loginEmail" type="email" autocomplete="username" class="input" required />
          </div>
          <div class="field">
            <label>${tr('Пароль', 'Password')}</label>
            <input id="loginPass" type="password" autocomplete="current-password" class="input" required />
          </div>
          <button type="submit" class="btn btn-primary btn-block" id="loginSubmit">
            ${tr('Войти', 'Sign In')}
          </button>
        </form>
      </div>
      ${banner}
    </div>
  `;
}

function renderJobCardRow(job, visit = null) {
  const v = visit || coalesceVisits(job).slice(-1)[0];
  const timeStr = v ? fmtTime(v.startDate) : tr('Без времени', 'No time');
  const dateStr = v ? fmtDate(v.startDate) : '';
  const payout = calcJobPayout(job, state.techProfile?.profitSharePercent ?? 50);
  const payBadge =
    payout.invoicedTotal > 0.009
      ? payout.unpaidClientBalance <= 0.009
        ? `<span class="badge" style="background:#22C55E22;color:#16A34A">${tr('Оплачено', 'Paid')}</span>`
        : payout.paidExTips > 0.009
          ? `<span class="badge" style="background:#FFB30022;color:#B45309">${tr('Депозит', 'Deposit')}</span>`
          : `<span class="badge" style="background:#E539351F;color:#E53935">${money(payout.invoicedTotal)}</span>`
      : '';

  return `
    <button type="button" class="job-card" data-open-job="${esc(job.id)}">
      <div class="job-row-top">
        <span class="job-time">${esc(timeStr)}${dateStr ? ` · ${esc(dateStr)}` : ''}</span>
        <div style="display:flex;gap:5px;align-items:center">
          ${payBadge}
          ${statusBadgeHtml(job.status)}
        </div>
      </div>
      <div class="job-client">${esc(jobDisplayClient(job))}</div>
      <div class="job-meta">${esc(jobApplianceSummary(job))}</div>
      ${jobDisplayAddress(job) ? `<div class="job-meta" style="margin-top:2px">${esc(jobDisplayAddress(job))}</div>` : ''}
    </button>
  `;
}

function renderCalendarTab() {
  const sel = state.selectedDate;
  const dow = (sel.getDay() + 6) % 7; // Monday = 0
  const monday = new Date(sel.getFullYear(), sel.getMonth(), sel.getDate() - dow);
  const days = Array.from({ length: 7 }, (_, i) => new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + i));
  const dowLabels = state.lang === 'en' ? ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'] : ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

  const visitsByDay = [];
  const unscheduled = [];
  for (const job of state.jobs) {
    const visits = coalesceVisits(job);
    if (visits.length === 0) {
      if (!isClosedStatus(job.status)) unscheduled.push(job);
      continue;
    }
    for (const v of visits) {
      if (v.outcome === 'cancelled') continue;
      visitsByDay.push({ job, visit: v });
    }
  }

  const dayEntries = visitsByDay
    .filter((x) => sameDay(x.visit.startDate, sel))
    .sort((a, b) => a.visit.startDate - b.visit.startDate);

  return `
    <div class="week-bar">
      <div class="week-nav">
        <button type="button" class="btn btn-outline btn-sm" id="prevWeekBtn">‹</button>
        <div style="font-weight:800;font-size:14.5px">${esc(fmtDate(sel))}</div>
        <div style="display:flex;gap:6px">
          <button type="button" class="btn btn-outline btn-sm" id="todayBtn">${tr('Сегодня', 'Today')}</button>
          <button type="button" class="btn btn-outline btn-sm" id="nextWeekBtn">›</button>
        </div>
      </div>
      <div class="week-days">
        ${days
          .map((d, idx) => {
            const hasV = visitsByDay.some((x) => sameDay(x.visit.startDate, d));
            const isSel = sameDay(d, sel);
            return `
              <button type="button" class="day-cell ${hasV ? 'has-visits' : ''} ${isSel ? 'selected' : ''}" data-pick-day="${d.toISOString()}">
                <div class="dow">${dowLabels[idx]}</div>
                <div class="dom">${d.getDate()}</div>
                <div class="dot"></div>
              </button>
            `;
          })
          .join('')}
      </div>
    </div>

    ${
      unscheduled.length > 0
        ? `
        <div style="margin-bottom:12px">
          <div style="font-size:12.5px;font-weight:800;color:var(--orange);margin:0 4px 6px">
            ${tr('Ждут назначения времени', 'Waiting to be scheduled')} (${unscheduled.length})
          </div>
          ${unscheduled.map((j) => renderJobCardRow(j)).join('')}
        </div>
        `
        : ''
    }

    ${
      dayEntries.length === 0
        ? `<div class="card" style="text-align:center;color:var(--muted);padding:28px 16px">${tr('На этот день визитов нет', 'No visits scheduled for this day')}</div>`
        : dayEntries.map((x) => renderJobCardRow(x.job, x.visit)).join('')
    }
  `;
}

function renderJobsTab() {
  const q = state.jobsQuery.trim().toLowerCase();
  const filtered = state.jobs.filter((j) => {
    if (state.jobsFilter === 'active' && isClosedStatus(j.status)) return false;
    if (!q) return true;
    const hay = [
      j.clientName,
      j.clientPhone,
      j.clientAddress,
      j.jobSiteName,
      j.jobSitePhone,
      j.jobSiteAddress,
      j.city,
      j.description,
      jobApplianceSummary(j),
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return hay.includes(q);
  });

  return `
    <div class="chip-row">
      <button type="button" class="chip ${state.jobsFilter === 'active' ? 'active' : ''}" data-jobs-filter="active">
        ${tr('Активные', 'Active')}
      </button>
      <button type="button" class="chip ${state.jobsFilter === 'all' ? 'active' : ''}" data-jobs-filter="all">
        ${tr('Все заказы', 'All jobs')} (${state.jobs.length})
      </button>
    </div>
    <div class="field">
      <input id="jobsSearchInput" class="input" value="${esc(state.jobsQuery)}" placeholder="${tr('Поиск по имени, адресу, телефону, технике…', 'Search client, address, phone, appliance…')}" />
    </div>
    ${
      filtered.length === 0
        ? `<div class="card" style="text-align:center;color:var(--muted);padding:28px 16px">${tr('Заявок не найдено', 'No jobs found')}</div>`
        : filtered.map((j) => renderJobCardRow(j)).join('')
    }
  `;
}

function renderEarningsTab() {
  const tech = state.techProfile || { profitSharePercent: 50 };
  const summary = calcBalanceSummary(tech, state.jobs, state.settlements);
  const pct = Math.max(0, Math.min(100, num(tech.profitSharePercent, 50)));
  const paidJobs = summary.jobs.filter((jp) => jp.hasPaidActivity || jp.invoicedTotal > 0.009);

  return `
    <div class="hero-card">
      <div style="display:flex;justify-content:space-between;align-items:flex-start">
        <div>
          <div style="font-size:12.5px;color:rgba(255,255,255,0.75)">${tr('Моя чистая прибыль', 'My net profit')}</div>
          <div style="font-size:28px;font-weight:900;color:var(--green)">${money(summary.totalTechProfit)}</div>
        </div>
        <div style="background:rgba(255,255,255,0.16);padding:5px 11px;border-radius:99px;font-weight:800;font-size:13px">
          ${pct % 1 === 0 ? pct.toFixed(0) : pct.toFixed(1)}%
        </div>
      </div>
      <hr style="border:none;border-top:1px solid rgba(255,255,255,0.2);margin:14px 0" />
      <div style="display:flex;justify-content:space-between;align-items:center">
        <span style="font-weight:700">${tr('К передаче в офис', 'Due to office')}</span>
        <span style="font-size:21px;font-weight:900;color:${summary.balanceDueToOwner > 0.009 ? 'var(--accent)' : '#fff'}">${money(summary.balanceDueToOwner)}</span>
      </div>
      <div style="font-size:11.5px;color:rgba(255,255,255,0.75);margin-top:6px">
        ${tr('Оплачено без налога', 'Paid excl. tax')}: ${money(summary.totalRevenueExTax)} · ${tr('Передано ранее', 'Already settled')}: ${money(summary.totalSettled)}
      </div>
    </div>

    ${
      summary.totalTechUnverifiedPartsCost > 0.009
        ? `<div class="alert-warn">${tr('Есть запчасти без фото чека на', 'Parts missing receipt photo:')} ${money(summary.totalTechUnverifiedPartsCost)}. ${tr('Прикрепите чек в счёте заказа, чтобы сумма вычлась из прибыли.', 'Attach the receipt in the job invoice to deduct cost.')}</div>`
        : ''
    }

    <div style="font-weight:800;margin:10px 2px 8px">${tr('По заказам', 'By job')}</div>
    ${
      paidJobs.length === 0
        ? `<div class="card" style="color:var(--muted);text-align:center">${tr('Пока нет оплаченных счетов', 'No paid invoices yet')}</div>`
        : paidJobs
            .map(
              (jp) => `
              <button type="button" class="job-card" data-open-job="${esc(jp.job.id)}" data-open-tab="finance">
                <div class="job-row-top">
                  <strong>${esc(jobDisplayClient(jp.job))}</strong>
                  <span style="font-weight:900;color:var(--green-dark)">+${money(jp.techProfit)}</span>
                </div>
                <div class="job-meta">
                  ${tr('Оплачено', 'Paid')}: ${money(jp.paidExTips)} · ${tr('Чистыми', 'Net')}: ${money(jp.netProfit)} · ${tr('В офис', 'To office')}: ${money(jp.dueToOwner)}
                </div>
                ${
                  jp.hasUnverifiedTechParts
                    ? `<div style="color:var(--danger);font-size:12px;font-weight:700;margin-top:4px">${tr('Нет фото чека запчасти:', 'Missing part receipt:')} ${money(jp.techUnverifiedPartsCost)}</div>`
                    : ''
                }
              </button>
            `
            )
            .join('')
    }

    ${
      summary.settlements.length > 0
        ? `
        <div style="font-weight:800;margin:16px 2px 8px">${tr('Принятые расчёты офисом', 'Recorded settlements')}</div>
        ${summary.settlements
          .map(
            (s) => `
          <div class="card" style="display:flex;justify-content:space-between;align-items:center;padding:11px 14px">
            <div>
              <div style="font-weight:800">${money(s.amount)}</div>
              <div style="font-size:12px;color:var(--muted)">${esc(fmtDate(s.createdAt))}${s.note ? ` · ${esc(s.note)}` : ''}</div>
            </div>
            <span class="badge" style="background:#22C55E22;color:#16A34A">${tr('Принято', 'Settled')}</span>
          </div>
        `
          )
          .join('')}
        `
        : ''
    }
  `;
}

function mergedGuideRecords() {
  const map = new Map();
  for (const r of state.guideLocal) {
    if (r?.id) map.set(r.id, r);
  }
  for (const r of state.guideRemote) {
    if (r?.id && !r.deleted) map.set(r.id, { ...(map.get(r.id) || {}), ...r });
  }
  return Array.from(map.values());
}

function renderGuideTab() {
  const all = mergedGuideRecords();
  const cats = [
    { id: 'all', label: tr('Все', 'All') },
    { id: 'fridge', label: tr('Холодильники', 'Fridges') },
    { id: 'washer', label: tr('Стиралки', 'Washers') },
    { id: 'dryer', label: tr('Сушилки', 'Dryers') },
    { id: 'dishwasher', label: tr('Посудомойки', 'Dishwashers') },
    { id: 'oven', label: tr('Плиты/Духовки', 'Ranges/Ovens') },
  ];
  const q = state.guideQuery.trim().toLowerCase();
  const filtered = all.filter((r) => {
    if (state.guideCategory !== 'all' && String(r.appliance || '') !== state.guideCategory) return false;
    if (!q) return true;
    const hay = [r.search, r.topic, r.brand, r.codes, r.platform, r.tests, r.specs, r.fix, r.notes]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return hay.includes(q);
  });

  return `
    <div class="chip-row">
      ${cats
        .map(
          (c) => `
        <button type="button" class="chip ${state.guideCategory === c.id ? 'active' : ''}" data-guide-cat="${c.id}">
          ${esc(c.label)}
        </button>
      `
        )
        .join('')}
    </div>
    <div class="field">
      <input id="guideSearchInput" class="input" value="${esc(state.guideQuery)}" placeholder="${tr('Код ошибки, бренд, модель, узел (F21, LE, ТЭН)…', 'Error code, brand, model, component…')}" />
    </div>
    ${
      filtered.length === 0
        ? `<div class="card" style="text-align:center;color:var(--muted)">${tr('Ничего не найдено', 'No matching cards')}</div>`
        : filtered
            .map((r) => {
              const open = state.expandedGuideId === r.id;
              return `
              <div class="card" style="padding:12px 14px">
                <div data-toggle-guide="${esc(r.id)}" style="cursor:pointer">
                  <div style="font-size:11.5px;font-weight:800;color:var(--primary)">${esc(r.category || '')} · ${esc(r.brand || '')}</div>
                  <div style="font-size:15px;font-weight:800;margin-top:2px">${esc(r.topic || '')}</div>
                  ${r.codes ? `<div style="font-size:12px;color:var(--orange);font-weight:700;margin-top:3px">${esc(r.codes)}</div>` : ''}
                </div>
                ${
                  open
                    ? `
                    <div style="margin-top:10px;padding-top:10px;border-top:1px solid var(--border);font-size:13.5px;white-space:pre-line">
                      ${r.platform ? `<div style="margin-bottom:8px"><strong>${tr('Платформа:', 'Platform:')}</strong> ${esc(r.platform)}</div>` : ''}
                      ${r.entry ? `<div style="margin-bottom:8px"><strong>${tr('Вход:', 'Entry:')}</strong>\n${esc(r.entry)}</div>` : ''}
                      ${r.procedure ? `<div style="margin-bottom:8px"><strong>${tr('Порядок:', 'Procedure:')}</strong>\n${esc(r.procedure)}</div>` : ''}
                      ${r.tests ? `<div style="margin-bottom:8px"><strong>${tr('Тесты / Коды:', 'Tests / Codes:')}</strong>\n${esc(r.tests)}</div>` : ''}
                      ${r.specs ? `<div style="margin-bottom:8px"><strong>${tr('Нормы и распиновка:', 'Specs & Pinouts:')}</strong>\n${esc(r.specs)}</div>` : ''}
                      ${r.fix ? `<div style="margin-bottom:8px"><strong>${tr('Решение:', 'Fix:')}</strong>\n${esc(r.fix)}</div>` : ''}
                      ${r.exit ? `<div style="margin-bottom:8px"><strong>${tr('Выход:', 'Exit:')}</strong>\n${esc(r.exit)}</div>` : ''}
                      ${r.notes ? `<div style="color:var(--muted)"><strong>${tr('Важно:', 'Notes:')}</strong>\n${esc(r.notes)}</div>` : ''}
                    </div>
                    `
                    : ''
                }
              </div>
            `;
            })
            .join('')
    }
  `;
}

// ------------------------------- Job Detail Screen -------------------------------
function renderJobDetailOverlay(job) {
  const addr = jobDisplayAddress(job);
  const encAddr = encodeURIComponent(addr);
  const visits = coalesceVisits(job);
  const latestVisit = visits.slice(-1)[0];

  let bodyHtml = '';
  if (state.jobTab === 'details') {
    const photos = (Array.isArray(job.attachments) ? job.attachments : []).filter(
      (a) => a?.url && a.kind !== 'call'
    );
    const apps = Array.isArray(job.appliances) ? job.appliances : [];

    bodyHtml = `
      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:10px">
          <div>
            <div style="font-size:12px;color:var(--muted);font-weight:700">${tr('Статус заказа', 'Job status')}</div>
            <div style="margin-top:3px">${statusBadgeHtml(job.status)}</div>
          </div>
          <select id="jobStatusSelect" class="select" style="width:auto;max-width:200px;font-weight:700;padding:8px 10px">
            ${STATUS_META.map(
              (s) => `
              <option value="${esc(s.key)}" ${String(job.status || 'Вызов') === s.key ? 'selected' : ''}>
                ${esc(state.lang === 'en' ? s.en : s.ru)}
              </option>
            `
            ).join('')}
          </select>
        </div>
        <div style="display:flex;justify-content:space-between;align-items:center;padding-top:10px;border-top:1px solid var(--border)">
          <div>
            <div style="font-size:12px;color:var(--muted);font-weight:700">${tr('Визит', 'Scheduled visit')}</div>
            <div style="font-weight:800;margin-top:2px">${esc(latestVisit ? fmtDateTime(latestVisit.startDate) : tr('Не назначено', 'Unscheduled'))}</div>
          </div>
          <button type="button" class="btn btn-outline btn-sm" id="editVisitBtn">${tr('Изменить', 'Schedule')}</button>
        </div>
      </div>

      <div class="card">
        <div style="font-size:12px;color:var(--muted);font-weight:700">${tr('Контакт и адрес', 'Contact & address')}</div>
        <div style="font-size:17px;font-weight:900;margin-top:3px">${esc(jobDisplayClient(job))}</div>
        ${addr ? `<div style="font-size:14px;margin-top:4px">${esc(addr)}</div>` : ''}
        ${
          addr
            ? `
            <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap">
              <a class="btn btn-outline btn-sm" href="https://maps.apple.com/?daddr=${encAddr}" target="_blank">Apple Maps</a>
              <a class="btn btn-outline btn-sm" href="https://www.google.com/maps/dir/?api=1&destination=${encAddr}" target="_blank">Google Maps</a>
            </div>
            `
            : ''
        }
        <div style="display:flex;flex-direction:column;gap:8px;margin-top:12px;padding-top:10px;border-top:1px solid var(--border)">
          ${
            job.clientPhone
              ? `
              <div style="display:flex;justify-content:space-between;align-items:center">
                <div>
                  <div style="font-weight:700">${esc(job.clientName || tr('Хозяин', 'Owner'))}</div>
                  <div style="font-size:12.5px;color:var(--muted)">${esc(job.clientPhone)}</div>
                </div>
                <button type="button" class="btn btn-green btn-sm" data-call-phone="${esc(job.clientPhone)}">
                  ${tr('Позвонить', 'Call')}
                </button>
              </div>
              `
              : ''
          }
          ${
            job.hasJobSite && job.jobSitePhone
              ? `
              <div style="display:flex;justify-content:space-between;align-items:center">
                <div>
                  <div style="font-weight:700">${esc(job.jobSiteName || tr('На объекте', 'On-site'))}</div>
                  <div style="font-size:12.5px;color:var(--muted)">${esc(job.jobSitePhone)}</div>
                </div>
                <button type="button" class="btn btn-green btn-sm" data-call-phone="${esc(job.jobSitePhone)}">
                  ${tr('Позвонить', 'Call')}
                </button>
              </div>
              `
              : ''
          }
        </div>
      </div>

      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
          <div style="font-weight:800">${tr('Техника', 'Appliances')}</div>
          <button type="button" class="btn btn-outline btn-sm" id="addApplianceBtn">+ ${tr('Добавить', 'Add')}</button>
        </div>
        ${
          apps.length === 0
            ? `<div style="font-size:13.5px;color:var(--muted)">${esc(jobApplianceSummary(job))}</div>`
            : apps
                .map(
                  (a, idx) => `
                <div data-edit-app="${idx}" style="padding:8px 0;border-top:${idx > 0 ? '1px solid var(--border)' : 'none'};cursor:pointer">
                  <div style="font-weight:800">${esc([a.type, a.brand].filter(Boolean).join(' · '))}</div>
                  <div style="font-size:12.5px;color:var(--muted)">
                    ${a.model ? `Model: ${esc(a.model)}` : ''} ${a.serialNumber || a.serial ? `· S/N: ${esc(a.serialNumber || a.serial)}` : ''}
                  </div>
                </div>
              `
                )
                .join('')
        }
      </div>

      <div class="card">
        <div class="field">
          <label>${tr('Описание поломки', 'Problem description')}</label>
          <textarea id="jobDescInput" class="textarea">${esc(job.description || '')}</textarea>
        </div>
        <div class="field" style="margin-bottom:10px">
          <label>${tr('Что сделано (отчёт мастера)', 'Work performed / Repair report')}</label>
          <textarea id="jobSolInput" class="textarea" placeholder="${tr('Опишите выполненный ремонт и установленные детали…', 'Describe diagnosis and repair performed…')}">${esc(job.solution || '')}</textarea>
        </div>
        <button type="button" class="btn btn-primary btn-block" id="saveNotesBtn">${tr('Сохранить описание и отчёт', 'Save notes & report')}</button>
      </div>

      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center">
          <div style="font-weight:800">${tr('Фотографии и шильдики', 'Photos')} (${photos.length})</div>
          <input type="file" id="jobPhotoInput" accept="image/*" class="hidden" />
          <button type="button" class="btn btn-outline btn-sm" id="addJobPhotoBtn">+ ${tr('Фото', 'Add photo')}</button>
        </div>
        ${
          photos.length > 0
            ? `<div class="photo-grid">
                ${photos.map((p) => `<img src="${esc(p.url)}" class="photo-thumb" data-view-photo="${esc(p.url)}" />`).join('')}
              </div>`
            : `<div style="font-size:13px;color:var(--muted);margin-top:8px">${tr('Сфотографируйте шильдик модели и результат ремонта.', 'Take photos of model tag and completed repair.')}</div>`
        }
      </div>
    `;
  } else if (state.jobTab === 'finance') {
    const share = state.techProfile?.profitSharePercent ?? 50;
    const payout = calcJobPayout(job, share);
    const docs = (Array.isArray(job.documents) ? job.documents : [])
      .map((d, idx) => ({ doc: d, idx }))
      .filter((x) => x.doc && !x.doc.deletedAt);
    const mode = techTaxMode(state.techProfile);
    const taxAllowed = hasOwnTax(state.techProfile) || mode !== 'none';
    const partsOnlyAllowed = !hasOwnTax(state.techProfile) && mode === 'parts';

    bodyHtml = `
      <div class="hero-card" style="padding:13px 15px">
        <div style="display:flex;justify-content:space-between;align-items:center">
          <span style="font-weight:800">${tr('Чистыми по заказу', 'Job net profit')}: ${money(payout.netProfit)}</span>
          <span style="font-weight:900;color:var(--accent)">${tr('Мне', 'My share')}: ${money(payout.techProfit)}</span>
        </div>
        <div style="font-size:12px;color:rgba(255,255,255,0.8);margin-top:4px">
          ${tr('К передаче в офис с заказа', 'Due to office from job')}: <strong>${money(payout.dueToOwner)}</strong>
          · ${tr('Реквизиты счёта', 'Invoice header')}: ${esc(effectiveBusinessName(state.techProfile))}${taxAllowed ? ` (HST ${esc(state.techProfile.hstNumber)})` : ` (${tr('без HST', 'No tax 0%')})`}
        </div>
      </div>

      <div style="display:flex;gap:8px;margin-bottom:12px">
        <button type="button" class="btn btn-primary btn-block" data-create-doc="Invoice">+ ${tr('Новый счёт', 'New Invoice')}</button>
        <button type="button" class="btn btn-outline btn-block" data-create-doc="Estimate">+ ${tr('Смета', 'New Estimate')}</button>
      </div>

      ${
        docs.length === 0
          ? `<div class="card" style="text-align:center;color:var(--muted);padding:24px">${tr('Счетов и смет пока нет', 'No invoices or estimates yet')}</div>`
          : docs
              .map(({ doc: d, idx }) => {
                const isEst = isEstimateDoc(d);
                const sub = documentSubtotal(d);
                const tax = documentTax(d);
                const tot = sub + tax;
                const pay = paymentsOf(d);
                const rem = Math.max(0, tot - pay.paidExTips);
                const items = Array.isArray(d.items) ? d.items : [];

                return `
                <div class="card">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                    <div>
                      <span class="badge" style="background:${isEst ? '#FB8C0022;color:#E65100' : '#14557F1F;color:#14557F'}">
                        ${isEst ? tr('СМЕТА', 'ESTIMATE') : tr('СЧЁТ', 'INVOICE')}
                      </span>
                      <strong style="margin-left:6px">#${esc(d.number || idx + 1)}</strong>
                    </div>
                    <select class="select" data-doc-tax="${idx}" style="width:auto;padding:5px 8px;font-size:13px;font-weight:700" ${!taxAllowed ? 'disabled' : ''}>
                      ${(() => {
                        const cur = techTaxOptionValue(d);
                        if (!taxAllowed) return `<option value="none" selected>No tax 0%</option>`;
                        const opts = partsOnlyAllowed
                          ? [
                              ['hst_parts', tr('HST 13% · запчасти', 'HST 13% · parts')],
                              ['gst_parts', tr('GST 5% · запчасти', 'GST 5% · parts')],
                              ['none', 'No tax 0%'],
                            ]
                          : [
                              ['hst_all', tr('HST 13% · всё', 'HST 13% · all')],
                              ['hst_parts', tr('HST 13% · запчасти', 'HST 13% · parts')],
                              ['gst_all', tr('GST 5% · всё', 'GST 5% · all')],
                              ['gst_parts', tr('GST 5% · запчасти', 'GST 5% · parts')],
                              ['none', 'No tax 0%'],
                            ];
                        return opts.map(([v, label]) => `<option value="${v}" ${cur === v ? 'selected' : ''}>${label}</option>`).join('');
                      })()}
                    </select>
                  </div>

                  ${
                    items.length === 0
                      ? `<div style="font-size:13px;color:var(--muted);padding:8px 0">${tr('Добавьте работу или запчасти', 'Add service or part items')}</div>`
                      : items
                          .map((it, iIdx) => {
                            const part = isPartItem(it);
                            const src = partSourceOf(it);
                            const rec = String(it.receiptUrl || '').trim();
                            return `
                            <div style="padding:8px 0;border-top:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;gap:8px">
                              <div data-edit-item="${idx}:${iIdx}" style="flex:1;cursor:pointer">
                                <div style="font-weight:700">${esc(it.name || '')} ${num(it.qty, 1) > 1 ? `× ${esc(it.qty)}` : ''}</div>
                                <div style="font-size:12px;color:var(--muted)">
                                  ${
                                    part
                                      ? src === 'owner'
                                        ? `${tr('Запчасть офиса · закупка', 'Office part · cost')} ${money(it.costPrice)}`
                                        : `${tr('Запчасть мастера · закупка', 'Tech part · cost')} ${money(it.costPrice)} · ${
                                            rec
                                              ? `<span style="color:var(--green-dark);font-weight:700">${tr('чек есть', 'receipt ok')}</span>`
                                              : `<span style="color:var(--danger);font-weight:700">${tr('нет чека!', 'no receipt!')}</span>`
                                          }`
                                      : tr('Работа', 'Labour / Service')
                                  }
                                </div>
                              </div>
                              <div style="display:flex;align-items:center;gap:6px">
                                ${rec ? `<button type="button" class="btn btn-outline btn-sm" data-view-photo="${esc(rec)}">${tr('Чек', 'Receipt')}</button>` : ''}
                                <strong>${money(num(it.qty ?? 1, 1) * num(it.price, 0))}</strong>
                              </div>
                            </div>
                          `;
                          })
                          .join('')
                  }

                  <button type="button" class="btn btn-outline btn-sm btn-block" style="margin:8px 0 10px" data-add-item="${idx}">
                    + ${tr('Добавить позицию', 'Add item')}
                  </button>

                  <div style="border-top:1px solid var(--border);padding-top:8px;font-size:13.5px">
                    <div style="display:flex;justify-content:space-between"><span>${tr('Подытог', 'Subtotal')}:</span><span>${money(sub)}</span></div>
                    ${tax > 0 ? `<div style="display:flex;justify-content:space-between"><span>HST/GST:</span><span>${money(tax)}</span></div>` : ''}
                    <div style="display:flex;justify-content:space-between;font-weight:900;font-size:15.5px;margin-top:3px"><span>${tr('Итого', 'Total')}:</span><span>${money(tot)}</span></div>
                    ${
                      !isEst
                        ? `<div style="display:flex;justify-content:space-between;color:var(--green-dark);font-weight:700;margin-top:2px"><span>${tr('Оплачено', 'Paid')}:</span><span>${money(pay.paidExTips)}</span></div>`
                        : ''
                    }
                  </div>

                  <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px">
                    ${
                      isEst && !d.convertedToInvoice
                        ? `<button type="button" class="btn btn-green btn-sm" data-convert-est="${idx}">${tr('В счёт', 'Convert to Invoice')}</button>`
                        : ''
                    }
                    ${
                      !isEst && rem > 0.009
                        ? `<button type="button" class="btn btn-green btn-sm" data-pay-doc="${idx}">${tr('Принять оплату', 'Record payment')} (${money(rem)})</button>`
                        : ''
                    }
                    <button type="button" class="btn btn-outline btn-sm" data-print-doc="${idx}">PDF / ${tr('Печать', 'Print')}</button>
                    <button type="button" class="btn btn-outline btn-sm" data-sms-doc="${idx}">${tr('Отправить по SMS', 'Send via SMS')}</button>
                  </div>
                </div>
              `;
              })
              .join('')
      }
    `;
  } else {
    const phones = [
      job.clientPhone ? { label: `${job.clientName || tr('Хозяин', 'Owner')} (${job.clientPhone})`, phone: job.clientPhone } : null,
      job.hasJobSite && job.jobSitePhone
        ? { label: `${job.jobSiteName || tr('На объекте', 'On-site')} (${job.jobSitePhone})`, phone: job.jobSitePhone }
        : null,
    ].filter(Boolean);

    bodyHtml = `
      <div class="card">
        <div style="font-weight:800;margin-bottom:8px">${tr('SMS по заказу', 'Job SMS messages')}</div>
        ${
          state.jobMessages.length === 0
            ? `<div style="font-size:13px;color:var(--muted);margin-bottom:10px">${tr('Сообщений по этому заказу пока нет', 'No SMS messages linked to this job yet')}</div>`
            : `<div class="chat-list">
                ${state.jobMessages
                  .map(
                    (m) => `
                  <div class="bubble ${m.direction === 'outbound' ? 'out' : 'in'}">
                    <div>${esc(m.body || '')}</div>
                    <div class="bubble-stamp">${esc(fmtDateTime(m.createdAt))}</div>
                  </div>
                `
                  )
                  .join('')}
              </div>`
        }
        ${
          phones.length > 1
            ? `<div class="field">
                <select id="smsTargetSelect" class="select">
                  ${phones.map((p) => `<option value="${esc(p.phone)}">${esc(p.label)}</option>`).join('')}
                </select>
              </div>`
            : `<input type="hidden" id="smsTargetSelect" value="${esc(phones[0]?.phone || '')}" />`
        }
        <div style="display:flex;gap:8px">
          <input id="smsBodyInput" class="input" placeholder="${tr('Сообщение клиенту (по-английски)…', 'Message to client…')}" />
          <button type="button" class="btn btn-primary" id="sendSmsBtn">${tr('Отпр.', 'Send')}</button>
        </div>
      </div>

      <div class="card">
        <div style="font-weight:800;margin-bottom:8px">${tr('Звонки и расшифровка', 'Calls & transcripts')} (${state.jobCalls.length})</div>
        ${
          state.jobCalls.length === 0
            ? `<div style="font-size:13px;color:var(--muted)">${tr('Записей звонков по заказу нет', 'No recorded calls linked to this job')}</div>`
            : state.jobCalls
                .map((c) => {
                  const text = c.transcriptionRu || c.transcription || c.summary || '';
                  return `
                  <div style="padding:10px 0;border-top:1px solid var(--border)">
                    <div style="display:flex;justify-content:space-between;align-items:center">
                      <strong style="font-size:13.5px">${esc(fmtDateTime(c.startTime || c.createdAt))}</strong>
                      <button type="button" class="btn btn-outline btn-sm" data-play-call="${esc(c.id)}">${tr('Слушать', 'Play')}</button>
                    </div>
                    <div id="audioSlot_${esc(c.id)}"></div>
                    ${text ? `<div style="font-size:13px;color:var(--ink);white-space:pre-line;margin-top:6px">${esc(text)}</div>` : ''}
                  </div>
                `;
                })
                .join('')
        }
      </div>
    `;
  }

  return `
    <div class="detail-overlay">
      <div class="topbar">
        <button type="button" class="icon-btn" id="closeJobBtn">‹ ${tr('Назад', 'Back')}</button>
        <div class="topbar-title">
          <h1>${esc(jobDisplayClient(job))}</h1>
          <div class="topbar-sub">${esc(jobApplianceSummary(job))}</div>
        </div>
      </div>
      <div class="detail-tabs">
        <button type="button" class="detail-tab ${state.jobTab === 'details' ? 'active' : ''}" data-job-tab="details">${tr('Детали', 'Details')}</button>
        <button type="button" class="detail-tab ${state.jobTab === 'finance' ? 'active' : ''}" data-job-tab="finance">${tr('Финансы', 'Finance')}</button>
        <button type="button" class="detail-tab ${state.jobTab === 'comms' ? 'active' : ''}" data-job-tab="comms">${tr('Связь', 'Comms')}</button>
      </div>
      <div class="detail-scroll">
        ${bodyHtml}
      </div>
    </div>
  `;
}

// ------------------------------- Main Render & Event Wiring -------------------------------
function render() {
  const root = document.getElementById('app');
  if (!root) return;

  if (!state.authReady) {
    root.innerHTML = `
      <div class="auth-screen">
        <img src="/tech/icons/apple-touch-icon.png" style="width:88px;height:88px;border-radius:50%" alt="Fix Appliance" />
      </div>
    `;
    return;
  }

  if (!state.user) {
    root.innerHTML = renderAuth();
    bindAuthEvents(root);
    return;
  }

  const openJob = state.openJobId ? state.jobs.find((j) => j.id === state.openJobId) : null;
  if (openJob) {
    root.innerHTML = renderJobDetailOverlay(openJob);
    bindJobDetailEvents(root, openJob);
    return;
  }

  const profileName = state.techProfile?.name || state.user.email || 'Fix Appliance';
  let tabContent = '';
  if (state.tab === 'calendar') tabContent = renderCalendarTab();
  else if (state.tab === 'jobs') tabContent = renderJobsTab();
  else if (state.tab === 'earnings') tabContent = renderEarningsTab();
  else tabContent = renderGuideTab();

  const installHint = isIosSafariNotStandalone()
    ? `<div class="alert-warn" style="margin-bottom:10px">${tr('Совет для iPhone: нажмите «Поделиться» в Safari → «На экран Домой», чтобы открывать в полный экран с иконки.', 'iPhone tip: tap Share in Safari → "Add to Home Screen" for full-screen app icon.')}</div>`
    : '';

  root.innerHTML = `
    <div class="app-shell">
      <header class="topbar">
        <img src="/tech/icons/apple-touch-icon.png" class="topbar-logo" alt="Logo" />
        <div class="topbar-title">
          <h1>${esc(profileName)}</h1>
          <div class="topbar-sub">Fix Appliance · ${tr('Мастер', 'Technician')}</div>
        </div>
        ${!state.online ? `<span class="offline-badge">${tr('Офлайн', 'Offline')}</span>` : ''}
        <button type="button" class="icon-btn" id="langBtn">${state.lang === 'en' ? 'RU' : 'EN'}</button>
        <button type="button" class="icon-btn" id="signOutBtn">${tr('Выйти', 'Exit')}</button>
      </header>

      <main class="tab-body">
        ${installHint}
        ${tabContent}
      </main>

      <nav class="bottom-nav">
        <button type="button" class="nav-item ${state.tab === 'calendar' ? 'active' : ''}" data-nav="calendar">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>
          <span>${tr('Календарь', 'Calendar')}</span>
        </button>
        <button type="button" class="nav-item ${state.tab === 'jobs' ? 'active' : ''}" data-nav="jobs">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg>
          <span>${tr('Заявки', 'Jobs')}</span>
        </button>
        <button type="button" class="nav-item ${state.tab === 'earnings' ? 'active' : ''}" data-nav="earnings">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg>
          <span>${tr('Моя прибыль', 'Earnings')}</span>
        </button>
        <button type="button" class="nav-item ${state.tab === 'guide' ? 'active' : ''}" data-nav="guide">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>
          <span>${tr('Диагностика', 'Diagnostics')}</span>
        </button>
      </nav>
    </div>
  `;

  bindShellEvents(root);
}

function bindAuthEvents(root) {
  root.querySelector('#langBtn')?.addEventListener('click', toggleLang);
  root.querySelector('#loginForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = root.querySelector('#loginEmail').value.trim();
    const pass = root.querySelector('#loginPass').value;
    const errBox = root.querySelector('#loginError');
    const btn = root.querySelector('#loginSubmit');
    errBox.classList.add('hidden');
    btn.disabled = true;
    state.forcedNotice = '';
    try {
      await signInWithEmailAndPassword(auth, email, pass);
    } catch (err) {
      errBox.textContent = tr('Неверный email или пароль, либо доступ закрыт', 'Invalid email/password or access disabled');
      errBox.classList.remove('hidden');
      btn.disabled = false;
    }
  });
}

function bindShellEvents(root) {
  root.querySelector('#langBtn')?.addEventListener('click', toggleLang);
  root.querySelector('#signOutBtn')?.addEventListener('click', () => signOut(auth));

  root.querySelectorAll('[data-nav]').forEach((btn) => {
    btn.addEventListener('click', () => {
      state.tab = btn.getAttribute('data-nav');
      render();
    });
  });

  root.querySelectorAll('[data-open-job]').forEach((el) => {
    el.addEventListener('click', () => {
      state.openJobId = el.getAttribute('data-open-job');
      state.jobTab = el.getAttribute('data-open-tab') || 'details';
      bindOpenJobComms(state.openJobId);
      render();
    });
  });

  root.querySelector('#prevWeekBtn')?.addEventListener('click', () => {
    const d = state.selectedDate;
    state.selectedDate = new Date(d.getFullYear(), d.getMonth(), d.getDate() - 7);
    render();
  });
  root.querySelector('#nextWeekBtn')?.addEventListener('click', () => {
    const d = state.selectedDate;
    state.selectedDate = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7);
    render();
  });
  root.querySelector('#todayBtn')?.addEventListener('click', () => {
    state.selectedDate = startOfDay(new Date());
    render();
  });
  root.querySelectorAll('[data-pick-day]').forEach((el) => {
    el.addEventListener('click', () => {
      state.selectedDate = startOfDay(new Date(el.getAttribute('data-pick-day')));
      render();
    });
  });

  root.querySelectorAll('[data-jobs-filter]').forEach((el) => {
    el.addEventListener('click', () => {
      state.jobsFilter = el.getAttribute('data-jobs-filter');
      render();
    });
  });

  const jobsSearch = root.querySelector('#jobsSearchInput');
  if (jobsSearch) {
    jobsSearch.addEventListener('input', (e) => {
      const pos = e.target.selectionStart;
      state.jobsQuery = e.target.value;
      render();
      const next = document.getElementById('jobsSearchInput');
      if (next) {
        next.focus();
        next.setSelectionRange(pos, pos);
      }
    });
  }

  root.querySelectorAll('[data-guide-cat]').forEach((el) => {
    el.addEventListener('click', () => {
      state.guideCategory = el.getAttribute('data-guide-cat');
      render();
    });
  });

  const guideSearch = root.querySelector('#guideSearchInput');
  if (guideSearch) {
    guideSearch.addEventListener('input', (e) => {
      const pos = e.target.selectionStart;
      state.guideQuery = e.target.value;
      render();
      const next = document.getElementById('guideSearchInput');
      if (next) {
        next.focus();
        next.setSelectionRange(pos, pos);
      }
    });
  }

  root.querySelectorAll('[data-toggle-guide]').forEach((el) => {
    el.addEventListener('click', () => {
      const id = el.getAttribute('data-toggle-guide');
      state.expandedGuideId = state.expandedGuideId === id ? '' : id;
      render();
    });
  });
}

function bindJobDetailEvents(root, job) {
  root.querySelector('#closeJobBtn')?.addEventListener('click', () => {
    state.openJobId = '';
    bindOpenJobComms('');
    render();
  });

  root.querySelectorAll('[data-job-tab]').forEach((el) => {
    el.addEventListener('click', () => {
      state.jobTab = el.getAttribute('data-job-tab');
      render();
    });
  });

  root.querySelector('#jobStatusSelect')?.addEventListener('change', async (e) => {
    const nextStatus = e.target.value;
    const patch = { status: nextStatus };
    const visits = coalesceVisits(job);
    if (nextStatus === 'Завершено') {
      patch.completedAt = serverTimestamp();
      if (visits.length > 0) {
        Object.assign(
          patch,
          syncVisitsPayload(visits.map((v) => (v.outcome === 'scheduled' ? { ...v, outcome: 'done' } : v)))
        );
      }
    } else if (nextStatus === 'Отменено') {
      if (visits.length > 0) {
        Object.assign(
          patch,
          syncVisitsPayload(visits.map((v) => (v.outcome === 'scheduled' ? { ...v, outcome: 'cancelled' } : v)))
        );
      }
    }
    await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), patch);
    toast(tr('Статус обновлён', 'Status updated'));
  });

  root.querySelector('#editVisitBtn')?.addEventListener('click', () => showVisitModal(job));

  root.querySelectorAll('[data-call-phone]').forEach((btn) => {
    btn.addEventListener('click', () => callClientViaBridge(job, btn.getAttribute('data-call-phone')));
  });

  root.querySelector('#addApplianceBtn')?.addEventListener('click', () => showApplianceModal(job, -1));
  root.querySelectorAll('[data-edit-app]').forEach((el) => {
    el.addEventListener('click', () => showApplianceModal(job, Number(el.getAttribute('data-edit-app'))));
  });

  root.querySelector('#saveNotesBtn')?.addEventListener('click', async () => {
    const description = root.querySelector('#jobDescInput').value.trim();
    const solution = root.querySelector('#jobSolInput').value.trim();
    await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), {
      description,
      solution,
      solutionEn: '',
    });
    toast(tr('Сохранено', 'Saved'));
  });

  const photoInput = root.querySelector('#jobPhotoInput');
  root.querySelector('#addJobPhotoBtn')?.addEventListener('click', () => photoInput?.click());
  photoInput?.addEventListener('change', async (e) => {
    const f = e.target.files?.[0];
    if (!f) return;
    toast(tr('Загружаю фото…', 'Uploading photo…'));
    try {
      await uploadJobAttachment(job, f, 'photo');
      toast(tr('Фото добавлено', 'Photo uploaded'));
    } catch (err) {
      toast(`${tr('Ошибка загрузки', 'Upload error')}: ${err.message || err}`);
    }
  });

  root.querySelectorAll('[data-view-photo]').forEach((el) => {
    el.addEventListener('click', (e) => {
      e.stopPropagation();
      showPhotoViewer(el.getAttribute('data-view-photo'));
    });
  });

  // Finance events
  root.querySelectorAll('[data-create-doc]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const docType = btn.getAttribute('data-create-doc');
      const docs = Array.isArray(job.documents) ? [...job.documents] : [];
      const mode = techTaxMode(state.techProfile);
      const taxRate = mode === 'none' ? 0 : 0.13;
      const taxScope = mode;
      const newDoc = {
        type: docType,
        number: generateTechDocNumber(job, docType),
        billTo: 'owner',
        billToName: jobDisplayClient(job),
        billToPhone: job.clientPhone || '',
        billToEmail: job.clientEmail || '',
        billToAddress: jobDisplayAddress(job),
        items: [],
        taxRate,
        taxScope,
        payments: [],
        createdAt: new Date().toISOString(),
      };
      docs.push(newDoc);
      await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), { documents: docs });
      showItemModal({ ...job, documents: docs }, docs.length - 1, -1);
    });
  });

  root.querySelectorAll('[data-doc-tax]').forEach((sel) => {
    sel.addEventListener('change', async (e) => {
      const idx = Number(sel.getAttribute('data-doc-tax'));
      const docs = Array.isArray(job.documents) ? [...job.documents] : [];
      if (!docs[idx]) return;
      const mode = techTaxMode(state.techProfile);
      const allowed = hasOwnTax(state.techProfile) || mode !== 'none';
      const parsed = allowed ? parseTechTaxOption(e.target.value) : { taxRate: 0, taxScope: 'none' };
      docs[idx] = { ...docs[idx], taxRate: parsed.taxRate, taxScope: parsed.taxScope };
      await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), { documents: docs });
    });
  });

  root.querySelectorAll('[data-add-item]').forEach((btn) => {
    btn.addEventListener('click', () => showItemModal(job, Number(btn.getAttribute('data-add-item')), -1));
  });

  root.querySelectorAll('[data-edit-item]').forEach((el) => {
    el.addEventListener('click', () => {
      const [dIdx, iIdx] = el.getAttribute('data-edit-item').split(':').map(Number);
      showItemModal(job, dIdx, iIdx);
    });
  });

  root.querySelectorAll('[data-pay-doc]').forEach((btn) => {
    btn.addEventListener('click', () => showPaymentModal(job, Number(btn.getAttribute('data-pay-doc'))));
  });

  root.querySelectorAll('[data-convert-est]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const idx = Number(btn.getAttribute('data-convert-est'));
      const docs = Array.isArray(job.documents) ? [...job.documents] : [];
      const est = docs[idx];
      if (!est) return;
      const invNum = generateTechDocNumber(job, 'Invoice');
      docs[idx] = {
        ...est,
        estimateStatus: 'approved',
        convertedToInvoice: true,
        convertedInvoiceNumber: invNum,
      };
      docs.push({
        ...est,
        type: 'Invoice',
        number: invNum,
        payments: [],
        createdAt: new Date().toISOString(),
        fromEstimateNumber: est.number,
      });
      await updateDoc(doc(db, 'companies', COMPANY_ID, 'jobs', job.id), { documents: docs });
      toast(tr('Смета превращена в счёт', 'Converted to invoice'));
    });
  });

  root.querySelectorAll('[data-print-doc]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = Number(btn.getAttribute('data-print-doc'));
      const d = job.documents?.[idx];
      if (d) printDocument(job, d);
    });
  });

  root.querySelectorAll('[data-sms-doc]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = Number(btn.getAttribute('data-sms-doc'));
      const d = job.documents?.[idx];
      if (d) sendInvoiceSmsToClient(job, d);
    });
  });

  // Comms events
  root.querySelector('#sendSmsBtn')?.addEventListener('click', async () => {
    const input = root.querySelector('#smsBodyInput');
    const target = root.querySelector('#smsTargetSelect')?.value;
    const text = input?.value?.trim() || '';
    if (!text) return;
    const btn = root.querySelector('#sendSmsBtn');
    btn.disabled = true;
    try {
      await sendJobSms(job, target, text);
      input.value = '';
      toast(tr('SMS отправлено', 'SMS sent'));
    } catch (err) {
      toast(`${tr('Ошибка SMS', 'SMS error')}: ${err.message || err}`);
    } finally {
      btn.disabled = false;
    }
  });

  root.querySelectorAll('[data-play-call]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const callId = btn.getAttribute('data-play-call');
      const slot = document.getElementById(`audioSlot_${callId}`);
      if (!slot) return;
      const token = await auth.currentUser.getIdToken();
      const src = `${CALL_AUDIO_URL}?callId=${encodeURIComponent(callId)}&auth=${encodeURIComponent(token)}`;
      slot.innerHTML = `<audio controls autoplay style="width:100%;margin-top:8px" src="${esc(src)}"></audio>`;
    });
  });
}

render();
