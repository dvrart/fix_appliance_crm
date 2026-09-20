const assert = require('node:assert/strict');
const { test } = require('node:test');
const { withProcessingLease } = require('./processing_lease');

function fixture(initial = {}) {
  let data = structuredClone(initial);
  let tail = Promise.resolve();
  let clock = 1000;
  const ref = {};
  const db = {
    runTransaction: (work) => {
      const result = tail.then(() => work({
        get: async () => ({ exists: data !== null, data: () => structuredClone(data) }),
        set: (_, patch) => { data = { ...data, ...structuredClone(patch) }; },
      }));
      tail = result.catch(() => {});
      return result;
    },
  };
  return {
    options: { db, ref, field: 'processing', now: () => clock },
    get: () => data,
    patch: (value) => { data = { ...data, ...value }; },
    advance: (ms) => { clock += ms; },
    remove: () => { data = null; },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test('concurrent webhook workers cannot process one event twice', async () => {
  const f = fixture();
  const started = deferred();
  const release = deferred();
  let runs = 0;
  const first = withProcessingLease(f.options, async () => {
    runs++;
    started.resolve();
    await release.promise;
  });
  await started.promise;
  await assert.rejects(withProcessingLease(f.options, async () => runs++), { code: 'processing-busy' });
  release.resolve();
  await first;
  assert.equal(runs, 1);
  assert.equal(f.get().processing, null);
});

test('a completed message is not replayed by a duplicate delivery', async () => {
  const f = fixture({ aiStatus: 'done' });
  let runs = 0;
  const ran = await withProcessingLease({ ...f.options, shouldRun: (data) => data.aiStatus !== 'done' }, async () => runs++);
  assert.equal(ran, false);
  assert.equal(runs, 0);
});

test('failures release the lease so a later retry can complete', async () => {
  const f = fixture();
  await assert.rejects(withProcessingLease(f.options, async () => { throw new Error('Provider unavailable'); }), /Provider unavailable/);
  assert.equal(f.get().processing, null);
  await withProcessingLease(f.options, async () => {});
  assert.equal(f.get().processingAttempts, 2);
});

test('an expired worker cannot release a lease claimed by its replacement', async () => {
  const f = fixture();
  const firstStarted = deferred();
  const releaseFirst = deferred();
  const secondStarted = deferred();
  const releaseSecond = deferred();
  const first = withProcessingLease(f.options, async () => { firstStarted.resolve(); await releaseFirst.promise; });
  await firstStarted.promise;
  f.advance(600001);
  const second = withProcessingLease(f.options, async () => { secondStarted.resolve(); await releaseSecond.promise; });
  await secondStarted.promise;
  const secondOwner = f.get().processing.owner;
  releaseFirst.resolve();
  await first;
  assert.equal(f.get().processing.owner, secondOwner);
  releaseSecond.resolve();
  await second;
  assert.equal(f.get().processing, null);
});

test('deleted documents are not recreated by workers or lease cleanup', async () => {
  const f = fixture();
  await withProcessingLease(f.options, async () => f.remove());
  assert.equal(f.get(), null);
  assert.equal(await withProcessingLease(f.options, async () => assert.fail('must not run')), false);
});
