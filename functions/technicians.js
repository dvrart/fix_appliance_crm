/**
 * Управление независимыми мастерами (субподрядчиками), проверка роли мастера
 * и расчёт его доли на сервере.
 */
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const COMPANY_ID = 'fix_appliance_ca';
const OWNER_UID = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';
const TECH_CLIENT_PREFIX = 'tech_';
const TESTER_CLIENT_PREFIX = 'tester_';

function isOwnerUid(uid) {
  return typeof uid === 'string' && uid.trim() === OWNER_UID;
}

function companyRef(db = getFirestore()) {
  return db.collection('companies').doc(COMPANY_ID);
}

function techniciansRef(db = getFirestore()) {
  return companyRef(db).collection('technicians');
}

function digitsOnly(value) {
  return String(value || '').replace(/\D/g, '');
}

function normalizePhone(value) {
  const raw = String(value || '').trim();
  const digits = digitsOnly(raw);
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  if (raw.startsWith('+') && digits.length >= 8 && digits.length <= 15) {
    return `+${digits}`;
  }
  return '';
}

function samePhone(a, b) {
  const x = digitsOnly(a);
  const y = digitsOnly(b);
  return x.length >= 10 && y.length >= 10 && x.slice(-10) === y.slice(-10);
}

function techTwilioIdentity(uid) {
  const clean = String(uid || '').trim().replace(/[^a-zA-Z0-9_]/g, '_');
  return `${TECH_CLIENT_PREFIX}${clean}`;
}

function uidFromTwilioClient(fromRaw) {
  const raw = String(fromRaw || '').trim().replace(/^client:/i, '');
  if (!raw.startsWith(TECH_CLIENT_PREFIX)) return '';
  return raw.slice(TECH_CLIENT_PREFIX.length).trim();
}

function testerTwilioIdentity(uid) {
  const clean = String(uid || '').trim().replace(/[^a-zA-Z0-9_]/g, '_');
  return `${TESTER_CLIENT_PREFIX}${clean}`;
}

function testerUidFromTwilioClient(fromRaw) {
  const raw = String(fromRaw || '').trim().replace(/^client:/i, '');
  if (!raw.startsWith(TESTER_CLIENT_PREFIX)) return '';
  return raw.slice(TESTER_CLIENT_PREFIX.length).trim();
}

async function getActiveTester(uid, db = getFirestore(), { allowMissing = false } = {}) {
  const clean = String(uid || '').trim();
  if (!clean) return null;
  try {
    const snap = await db.collection('testers').doc(clean).get();
    if (!snap.exists) {
      return allowMissing
        ? { uid: clean, companyId: `tester_${clean}`, role: 'owner', active: true }
        : null;
    }
    const data = snap.data() || {};
    if (data.active === false) return null;
    const isSubTech = data.role === 'technician' && Boolean(data.parentCompanyId);
    const targetCompanyId = isSubTech
      ? String(data.parentCompanyId).trim()
      : `tester_${clean}`;
    if (isSubTech) {
      const techSnap = await db
        .collection('companies')
        .doc(targetCompanyId)
        .collection('technicians')
        .doc(clean)
        .get();
      if (!techSnap.exists || (techSnap.data() || {}).active === false) {
        return null;
      }
    }
    return {
      uid: clean,
      companyId: targetCompanyId,
      isSubTech,
      ...data,
    };
  } catch (error) {
    console.warn('getActiveTester:', error.message);
    return null;
  }
}

function isAssignedToTechnician(job) {
  const uid = String((job && job.assignedTo) || '').trim();
  return Boolean(uid) && !isOwnerUid(uid);
}

async function getActiveTechnician(uid, db = getFirestore()) {
  const clean = String(uid || '').trim();
  if (!clean || isOwnerUid(clean)) return null;
  try {
    const snap = await techniciansRef(db).doc(clean).get();
    if (!snap.exists) return null;
    const data = snap.data() || {};
    if (data.active === false) return null;
    return { uid: clean, ...data };
  } catch (error) {
    console.warn('getActiveTechnician:', error.message);
    return null;
  }
}

async function findActiveTechnicianByCell(fromPhone, db = getFirestore()) {
  if (!digitsOnly(fromPhone)) return null;
  try {
    const snap = await techniciansRef(db).where('active', '==', true).get();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.phone && samePhone(data.phone, fromPhone)) {
        return { uid: doc.id, ...data };
      }
    }
  } catch (error) {
    console.warn('findActiveTechnicianByCell:', error.message);
  }
  return null;
}

/**
 * Пускает владельца ИЛИ активного мастера из коллекции `technicians/{uid}`.
 * Возвращает `{ ...decodedToken, isOwner, technician }` или отвечает 401/403 и возвращает null.
 */
async function requireAnyAppUser(req, res, deps = {}) {
  const guardMod = require('./auth_guard');
  const verify = deps.verifyAppUser || guardMod.verifyAppUser;
  const ownerGuard = deps.requireAppUser || guardMod.requireAppUser;
  const db = deps.db || getFirestore();
  const user = await verify(req);
  if (!user || !user.uid) {
    res.status(401).json({ error: 'Unauthorized: Firebase ID token required' });
    return null;
  }
  const wantsTester =
    Boolean(req && req.query && req.query.tester === '1') ||
    String((req && req.query && req.query.identity) || '').startsWith(TESTER_CLIENT_PREFIX);
  if (isOwnerUid(user.uid)) {
    return {
      ...user,
      isOwner: true,
      isTester: wantsTester,
      testerCompanyId: wantsTester ? `tester_${user.uid}` : '',
      technician: null,
    };
  }
  const tech = await getActiveTechnician(user.uid, db);
  if (tech && !wantsTester) {
    return { ...user, isOwner: false, isTester: false, technician: tech };
  }
  const tester = await getActiveTester(user.uid, db, { allowMissing: wantsTester });
  if (tester) {
    return {
      ...user,
      isOwner: false,
      isTester: true,
      isTesterSubTech: Boolean(tester.isSubTech),
      tester,
      testerCompanyId: tester.companyId || `tester_${user.uid}`,
      technician: null,
    };
  }
  if (tech) {
    return { ...user, isOwner: false, isTester: false, technician: tech };
  }
  const asOwner = await ownerGuard(req, res);
  if (asOwner) {
    return { ...asOwner, isOwner: true, isTester: false, technician: null };
  }
  return null;
}

function sanitizeTechFields(body = {}, existing = {}) {
  const name = String(body.name ?? existing.name ?? '').trim();
  const email = String(body.email ?? existing.email ?? '').trim().toLowerCase();
  const phone = normalizePhone(body.phone ?? existing.phone ?? '') ||
    String(body.phone ?? existing.phone ?? '').trim();
  const rawColor = Number(body.colorValue ?? existing.colorValue);
  const colorValue = Number.isFinite(rawColor) && rawColor !== 0
    ? Math.trunc(rawColor)
    : 0xFF00897B;
  const rawPct = Number(body.profitSharePercent ?? existing.profitSharePercent ?? 50);
  const profitSharePercent = Number.isFinite(rawPct)
    ? Math.max(0, Math.min(100, rawPct))
    : 50;
  const businessName = String(body.businessName ?? existing.businessName ?? '').trim();
  const hstNumber = String(body.hstNumber ?? existing.hstNumber ?? '').trim();
  const collectsHst = typeof body.collectsHst === 'boolean'
    ? body.collectsHst
    : (typeof existing.collectsHst === 'boolean' ? existing.collectsHst : Boolean(hstNumber));
  const etransferEmail = String(body.etransferEmail ?? existing.etransferEmail ?? '').trim();
  const rawTaxMode = String(body.taxMode ?? existing.taxMode ?? '').trim().toLowerCase();
  const taxMode = ['all', 'parts', 'none'].includes(rawTaxMode)
    ? rawTaxMode
    : (collectsHst && Boolean(hstNumber) ? 'all' : 'none');
  const active = typeof body.active === 'boolean'
    ? body.active
    : existing.active !== false;

  return {
    name,
    email,
    phone,
    colorValue,
    profitSharePercent,
    businessName,
    collectsHst,
    hstNumber,
    etransferEmail,
    taxMode,
    active,
  };
}

async function disableTechnicianTokens(uid, db = getFirestore(), targetCompanyId = COMPANY_ID) {
  try {
    const snap = await db
      .collection('companies')
      .doc(targetCompanyId)
      .collection('fcm_tokens')
      .where('userId', '==', uid)
      .get();
    if (snap.empty) return;
    await Promise.all(
      snap.docs.map((doc) =>
        doc.ref.set({ disabled: true, disabledReason: 'tech_blocked' }, { merge: true })
      )
    );
  } catch (error) {
    console.warn('disableTechnicianTokens:', error.message);
  }
}

/**
 * HTTP-обработчик `manageTechnician` — доступен владельцу (`requireAppUser`)
 * или тестировщику-владельцу своей персональной базы `tester_<uid>`.
 */
async function handleManageTechnician(req, res, deps = {}) {
  const guardMod = require('./auth_guard');
  const auth = deps.auth || require('firebase-admin/auth').getAuth();
  const db = deps.db || getFirestore();

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST required' });
    return;
  }

  const body = req.body || {};
  const requestedCompanyId = String(body.companyId || '').trim();
  const isTesterScope = requestedCompanyId.startsWith(TESTER_CLIENT_PREFIX);

  let caller = null;
  let targetCompanyId = COMPANY_ID;

  if (isTesterScope && !deps.requireAppUser) {
    const verify = deps.verifyAppUser || guardMod.verifyAppUser;
    const verified = await verify(req);
    if (!verified || !verified.uid) {
      res.status(401).json({ error: 'Unauthorized: Firebase ID token required' });
      return;
    }
    const expectedCompanyId = `tester_${verified.uid}`;
    if (!isOwnerUid(verified.uid) && requestedCompanyId !== expectedCompanyId) {
      res.status(403).json({ error: 'Forbidden: можно управлять только мастерами своей базы' });
      return;
    }
    const testerRecord = await getActiveTester(verified.uid, db, { allowMissing: true });
    if (!testerRecord || testerRecord.isSubTech) {
      res.status(403).json({ error: 'Forbidden: доступ только для владельца базы' });
      return;
    }
    caller = verified;
    targetCompanyId = requestedCompanyId;
  } else {
    const guard = deps.requireAppUser || guardMod.requireAppUser;
    caller = await guard(req, res);
    if (!caller) return;
    if (isTesterScope && isOwnerUid(caller.uid)) {
      targetCompanyId = requestedCompanyId;
    }
  }

  const targetTechsRef = db.collection('companies').doc(targetCompanyId).collection('technicians');
  const action = String(body.action || '').trim();

  try {
    if (action === 'create') {
      const fields = sanitizeTechFields(body, {});
      const password = String(body.password || '');
      if (!fields.name) {
        res.status(400).json({ error: 'Укажите имя мастера' });
        return;
      }
      if (!fields.email || !fields.email.includes('@')) {
        res.status(400).json({ error: 'Укажите корректный email для входа' });
        return;
      }
      if (password.length < 6) {
        res.status(400).json({ error: 'Пароль должен быть не короче 6 символов' });
        return;
      }

      const created = await auth.createUser({
        email: fields.email,
        password,
        displayName: fields.name,
        disabled: false,
      });
      if (isOwnerUid(created.uid)) {
        res.status(400).json({ error: 'Нельзя перезаписать аккаунт владельца' });
        return;
      }

      const record = {
        uid: created.uid,
        ...fields,
        active: true,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      await targetTechsRef.doc(created.uid).set(record);
      if (targetCompanyId.startsWith(TESTER_CLIENT_PREFIX)) {
        await db.collection('testers').doc(created.uid).set({
          uid: created.uid,
          email: fields.email,
          name: fields.name,
          role: 'technician',
          parentCompanyId: targetCompanyId,
          parentOwnerUid: targetCompanyId.slice(TESTER_CLIENT_PREFIX.length),
          companyId: targetCompanyId,
          active: true,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      res.json({
        success: true,
        uid: created.uid,
        technician: { ...fields, uid: created.uid, active: true },
      });
      return;
    }

    if (action === 'update') {
      const uid = String(body.uid || '').trim();
      if (!uid || isOwnerUid(uid)) {
        res.status(400).json({ error: 'Некорректный идентификатор мастера' });
        return;
      }
      const docRef = targetTechsRef.doc(uid);
      const snap = await docRef.get();
      if (!snap.exists) {
        res.status(404).json({ error: 'Профиль мастера не найден' });
        return;
      }
      const existing = snap.data() || {};
      const fields = sanitizeTechFields(body, existing);
      if (!fields.name) {
        res.status(400).json({ error: 'Укажите имя мастера' });
        return;
      }
      if (!fields.email || !fields.email.includes('@')) {
        res.status(400).json({ error: 'Укажите корректный email для входа' });
        return;
      }

      const authPatch = {
        email: fields.email,
        displayName: fields.name,
        disabled: !fields.active,
      };
      const password = String(body.password || '');
      if (password) {
        if (password.length < 6) {
          res.status(400).json({ error: 'Новый пароль должен быть не короче 6 символов' });
          return;
        }
        authPatch.password = password;
      }
      await auth.updateUser(uid, authPatch);
      if (!fields.active) {
        await auth.revokeRefreshTokens(uid).catch(() => {});
        await disableTechnicianTokens(uid, db, targetCompanyId);
      }
      await docRef.set(
        {
          uid,
          ...fields,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      if (targetCompanyId.startsWith(TESTER_CLIENT_PREFIX)) {
        await db.collection('testers').doc(uid).set(
          {
            email: fields.email,
            name: fields.name,
            active: fields.active,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
      res.json({ success: true, uid, technician: { uid, ...fields } });
      return;
    }

    if (action === 'setActive') {
      const uid = String(body.uid || '').trim();
      const active = body.active === true;
      if (!uid || isOwnerUid(uid)) {
        res.status(400).json({ error: 'Некорректный идентификатор мастера' });
        return;
      }
      await auth.updateUser(uid, { disabled: !active });
      if (!active) {
        await auth.revokeRefreshTokens(uid).catch(() => {});
        await disableTechnicianTokens(uid, db, targetCompanyId);
      }
      await targetTechsRef.doc(uid).set(
        { active, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );
      if (targetCompanyId.startsWith(TESTER_CLIENT_PREFIX)) {
        await db.collection('testers').doc(uid).set(
          { active, updatedAt: FieldValue.serverTimestamp() },
          { merge: true }
        );
      }
      res.json({ success: true, uid, active });
      return;
    }

    res.status(400).json({ error: 'Неизвестное действие' });
  } catch (error) {
    console.error('manageTechnician error:', error);
    const code = String(error && error.code ? error.code : '');
    if (code === 'auth/email-already-exists') {
      res.status(400).json({ error: 'Этот email уже занят другим аккаунтом' });
      return;
    }
    res.status(500).json({ error: error.message || 'Ошибка управления мастером' });
  }
}

/**
 * Считает оплату и долю владельца по заявке мастера (для push-уведомления владельцу).
 */
function summarizeJobPayout(job, profitSharePercent = 50) {
  const docs = Array.isArray(job && job.documents) ? job.documents : [];
  const techPct = Math.max(0, Math.min(100, Number(profitSharePercent) || 50));
  const ownerPct = 100 - techPct;

  let paidExTips = 0;
  let revenueExTax = 0;
  let ownerParts = 0;
  let techVerifiedParts = 0;
  let lastMethod = '';

  for (const doc of docs) {
    if (!doc || typeof doc !== 'object' || doc.deletedAt) continue;
    if (String(doc.type || 'Invoice') === 'Estimate') continue;
    const status = String(doc.status || '').toLowerCase();
    if (status.includes('cancel') || status.includes('void') || status.includes('отмен')) {
      continue;
    }
    const items = Array.isArray(doc.items) ? doc.items : [];
    const taxRate = Number(doc.taxRate) || 0;
    const taxScope = String(doc.taxScope || '').trim().toLowerCase();
    let subtotal = 0;
    let partsSubtotal = 0;
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      const line = (Number(item.qty ?? 1) || 0) * (Number(item.price) || 0);
      subtotal += line;
      const kind = String(item.type || '').toLowerCase();
      const isPart =
        item.labourDiscount !== true &&
        (kind.includes('part') ||
          kind.includes('запчаст') ||
          (!kind && (item.warehouseItemId || item.costPrice != null)));
      if (isPart) partsSubtotal += line;
    }
    const taxable = taxRate <= 0 || taxScope === 'none'
      ? 0
      : (taxScope === 'parts' ? Math.max(0, partsSubtotal) : subtotal);
    const tax = taxable * taxRate;
    const total = subtotal + tax;

    let docPaid = 0;
    const payments = Array.isArray(doc.payments) ? doc.payments : [];
    for (const p of payments) {
      if (!p || typeof p !== 'object') continue;
      const amt = Number(p.amount) || 0;
      const m = String(p.method || '').trim();
      const lower = m.toLowerCase();
      if ((lower.includes('tip') || lower.includes('чаевые')) && amt >= 0) {
        continue;
      }
      docPaid += amt;
      if (amt > 0 && m) lastMethod = m;
    }
    if (docPaid < 0) docPaid = 0;
    paidExTips += docPaid;

    const ratio = docPaid <= 0.009 ? 0 : total <= 0.009 ? 1 : Math.min(1, docPaid / total);
    revenueExTax += subtotal * ratio;

    if (ratio > 0) {
      for (const item of items) {
        if (!item || typeof item !== 'object') continue;
        const kind = String(item.type || '').toLowerCase();
        const isPart =
          kind.includes('part') ||
          kind.includes('запчаст') ||
          (!kind && (item.warehouseItemId || item.costPrice != null));
        if (!isPart) continue;
        const cost = (Number(item.qty ?? 1) || 0) * (Number(item.costPrice) || 0) * ratio;
        const source = String(item.partSource || '').toLowerCase();
        const hasReceipt = Boolean(String(item.receiptUrl || '').trim());
        if (source === 'tech') {
          if (hasReceipt) techVerifiedParts += cost;
        } else {
          ownerParts += cost;
        }
      }
    }
  }

  const netProfit = revenueExTax - (ownerParts + techVerifiedParts);
  const ownerProfit = netProfit * (ownerPct / 100);
  const dueToOwner = ownerParts + ownerProfit;
  return {
    paidExTips,
    revenueExTax,
    netProfit,
    ownerProfit,
    dueToOwner,
    lastMethod,
  };
}

module.exports = {
  TECH_CLIENT_PREFIX,
  TESTER_CLIENT_PREFIX,
  techTwilioIdentity,
  uidFromTwilioClient,
  testerTwilioIdentity,
  testerUidFromTwilioClient,
  isAssignedToTechnician,
  getActiveTechnician,
  getActiveTester,
  findActiveTechnicianByCell,
  requireAnyAppUser,
  handleManageTechnician,
  summarizeJobPayout,
};
