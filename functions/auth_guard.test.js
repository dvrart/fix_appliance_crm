const assert = require('node:assert/strict');
const { test } = require('node:test');
const Module = require('node:module');

const OWNER = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';
let decoded;
let verificationError;
let verifiedTokens;
const load = Module._load;
let guard;
try {
  Module._load = function (name) {
    if (name === 'firebase-admin') return {
      auth: () => ({
        verifyIdToken: async (token) => {
          verifiedTokens.push(token);
          if (verificationError) throw verificationError;
          return decoded;
        },
      }),
    };
    return load.apply(this, arguments);
  };
  guard = require('./auth_guard');
} finally {
  Module._load = load;
}

function response() {
  return {
    statusCode: 200, body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

for (const [name, user, expected] of [
  ['owner', { uid: OWNER, email: 'owner@example.test' }, 200],
  ['different signed-in account', { uid: 'another-user' }, 403],
  ['same email with a different uid', { uid: 'another-user', email: 'dvrart@gmail.com' }, 403],
  ['missing uid', { email: 'owner@example.test' }, 403],
]) {
  test(`app access: ${name}`, async () => {
    decoded = user;
    verificationError = null;
    verifiedTokens = [];
    const res = response();
    const result = await guard.requireAppUser({
      headers: { authorization: 'Bearer synthetic-token' }, query: {},
    }, res);
    assert.equal(res.statusCode, expected);
    assert.equal(result, expected === 200 ? user : null);
    assert.deepEqual(verifiedTokens, ['synthetic-token']);
  });
}

test('missing or invalid tokens remain unauthorized', async () => {
  decoded = { uid: OWNER };
  verificationError = new Error('Synthetic invalid token');
  verifiedTokens = [];
  for (const headers of [{}, { authorization: 'Bearer invalid-token' }]) {
    const res = response();
    assert.equal(await guard.requireAppUser({ headers, query: {} }, res), null);
    assert.equal(res.statusCode, 401);
  }
  assert.deepEqual(verifiedTokens, ['invalid-token']);
});

test('audio query tokens must belong to the owner too', async () => {
  verificationError = null;
  verifiedTokens = [];
  for (const [uid, status] of [[OWNER, 200], ['another-user', 403]]) {
    decoded = { uid };
    const res = response();
    await guard.requireAppUser({ headers: {}, query: { auth: 'synthetic-audio-token' } }, res);
    assert.equal(res.statusCode, status);
  }
});
