const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const Module = require('node:module');

const COMPANY = 'companies/fix_appliance_ca';
const OWNER = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';

let store;
let authUsers;
let revokedUids;

function docRef(path) {
  return {
    id: path.split('/').pop(),
    path,
    collection: (name) => colRef(`${path}/${name}`),
    get: async () => ({
      id: path.split('/').pop(),
      ref: docRef(path),
      exists: store.has(path),
      data: () => structuredClone(store.get(path)),
    }),
    set: async (data, opts) => {
      const prev = opts?.merge ? store.get(path) || {} : {};
      store.set(path, { ...structuredClone(prev), ...structuredClone(data) });
    },
  };
}

function colRef(path, filters = []) {
  return {
    path,
    doc: (id) => docRef(`${path}/${id}`),
    where: (f, op, v) => colRef(path, [...filters, [f, op, v]]),
    get: async () => {
      const docs = [...store.keys()]
        .filter((k) => k.startsWith(`${path}/`) && !k.slice(path.length + 1).includes('/'))
        .map((k) => ({
          id: k.split('/').pop(),
          ref: docRef(k),
          exists: true,
          data: () => structuredClone(store.get(k)),
        }))
        .filter((d) => filters.every(([f, op, v]) => op !== '==' || d.data()?.[f] === v));
      return { docs, empty: !docs.length };
    },
  };
}

const fakeDb = { collection: (name) => colRef(name) };
const fakeAuth = {
  createUser: async ({ email, password, displayName, disabled }) => {
    const uid = `tech_${authUsers.size + 1}`;
    authUsers.set(uid, { uid, email, password, displayName, disabled: Boolean(disabled) });
    return { uid };
  },
  updateUser: async (uid, patch) => {
    const cur = authUsers.get(uid) || { uid };
    authUsers.set(uid, { ...cur, ...patch });
    return authUsers.get(uid);
  },
  revokeRefreshTokens: async (uid) => {
    revokedUids.push(uid);
  },
};

const load = Module._load;
Module._load = function (name) {
  if (name === 'firebase-admin/firestore') {
    return {
      getFirestore: () => fakeDb,
      FieldValue: { serverTimestamp: () => 'SERVER_TS' },
    };
  }
  if (name === 'firebase-admin/auth') {
    return { getAuth: () => fakeAuth };
  }
  return load.apply(this, arguments);
};
const technicians = require('./technicians');
const noncash = require('./noncash_alert');
Module._load = load;

function makeRes() {
  return {
    statusCode: 200,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  };
}

beforeEach(() => {
  store = new Map();
  authUsers = new Map();
  revokedUids = [];
});

test('владелец создаёт мастера, обновляет реквизиты и мгновенно блокирует доступ', async () => {
  const resCreate = makeRes();
  await technicians.handleManageTechnician(
    {
      method: 'POST',
      body: {
        action: 'create',
        name: 'Ivan',
        email: 'ivan@example.test',
        password: 'secretPassword',
        phone: '4165550177',
        profitSharePercent: 55,
        businessName: 'Ivan Repair',
        collectsHst: true,
        hstNumber: '123456789 RT0001',
        etransferEmail: 'ivan@pay.test',
      },
    },
    resCreate,
    { requireAppUser: async () => ({ uid: OWNER }), auth: fakeAuth, db: fakeDb }
  );
  assert.equal(resCreate.statusCode, 200);
  const uid = resCreate.body.uid;
  assert.equal(store.get(`${COMPANY}/technicians/${uid}`).profitSharePercent, 55);
  assert.equal(store.get(`${COMPANY}/technicians/${uid}`).phone, '+14165550177');

  // Регистрируем FCM-токен мастера и блокируем мастера:
  store.set(`${COMPANY}/fcm_tokens/dev1`, { token: 't1', userId: uid, disabled: false });
  const resBlock = makeRes();
  await technicians.handleManageTechnician(
    { method: 'POST', body: { action: 'setActive', uid, active: false } },
    resBlock,
    { requireAppUser: async () => ({ uid: OWNER }), auth: fakeAuth, db: fakeDb }
  );
  assert.equal(resBlock.statusCode, 200);
  assert.equal(authUsers.get(uid).disabled, true);
  assert.deepEqual(revokedUids, [uid]);
  assert.equal(store.get(`${COMPANY}/technicians/${uid}`).active, false);
  assert.equal(store.get(`${COMPANY}/fcm_tokens/dev1`).disabled, true);
});

test('requireAnyAppUser пускает активного мастера и отвергает заблокированного', async () => {
  store.set(`${COMPANY}/technicians/t1`, { uid: 't1', name: 'Max', active: true });
  store.set(`${COMPANY}/technicians/t2`, { uid: 't2', name: 'Blocked', active: false });

  const okRes = makeRes();
  const activeUser = await technicians.requireAnyAppUser(
    {},
    okRes,
    {
      verifyAppUser: async () => ({ uid: 't1' }),
      requireAppUser: async (_req, r) => { r.status(403).json({ error: 'no' }); return null; },
      db: fakeDb,
    }
  );
  assert.equal(activeUser.isOwner, false);
  assert.equal(activeUser.technician.name, 'Max');

  const badRes = makeRes();
  const blockedUser = await technicians.requireAnyAppUser(
    {},
    badRes,
    {
      verifyAppUser: async () => ({ uid: 't2' }),
      requireAppUser: async (_req, r) => { r.status(403).json({ error: 'no' }); return null; },
      db: fakeDb,
    }
  );
  assert.equal(blockedUser, null);
  assert.equal(badRes.statusCode, 403);
});

test('summarizeJobPayout считает долю владельца и учитывает чек запчасти', () => {
  const jobWithOwnerPart = {
    documents: [{
      type: 'Invoice',
      taxRate: 0.13,
      items: [
        { name: 'Service', type: 'Service', qty: 1, price: 200 },
        { name: 'Pump', type: 'Part', qty: 1, price: 150, costPrice: 100, partSource: 'owner' },
      ],
      payments: [{ amount: 395.5, method: 'e-Transfer' }],
    }],
  };
  const summary = technicians.summarizeJobPayout(jobWithOwnerPart, 50);
  assert.equal(Math.round(summary.revenueExTax), 350);
  assert.equal(Math.round(summary.netProfit), 250);
  assert.equal(Math.round(summary.dueToOwner), 225);
});

test('summarizeJobPayout учитывает taxScope=parts и не облагает работу налогом', () => {
  const jobPartsTaxOnly = {
    documents: [{
      type: 'Invoice',
      taxRate: 0.13,
      taxScope: 'parts',
      items: [
        { name: 'Service', type: 'Service', qty: 1, price: 200 },
        { name: 'Pump', type: 'Part', qty: 1, price: 100, costPrice: 60, partSource: 'owner' },
      ],
      // Subtotal 300 + HST only on part (13) = 313.
      payments: [{ amount: 313, method: 'e-Transfer' }],
    }],
  };
  const summary = technicians.summarizeJobPayout(jobPartsTaxOnly, 50);
  assert.equal(Math.round(summary.revenueExTax), 300);
  assert.equal(Math.round(summary.netProfit), 240);
  assert.equal(Math.round(summary.dueToOwner), 180);
});
