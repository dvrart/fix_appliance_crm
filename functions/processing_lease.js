const crypto = require('node:crypto');

function millis(value) {
  if (value?.toMillis) return value.toMillis();
  const result = new Date(value || 0).getTime();
  return Number.isFinite(result) ? result : 0;
}

async function withProcessingLease({ db, ref, field, shouldRun = () => true, leaseMs = 600000, now = Date.now }, work) {
  const owner = crypto.randomUUID();
  const data = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return null;
    const current = snap.data() || {};
    if (!shouldRun(current)) return null;
    if (millis(current[field]?.until) > now()) {
      const error = new Error('Processing is already running');
      error.code = 'processing-busy';
      throw error;
    }
    tx.set(ref, {
      [field]: { owner, until: new Date(now() + leaseMs) },
      [`${field}Attempts`]: Number(current[`${field}Attempts`] || 0) + 1,
    }, { merge: true });
    return current;
  });
  if (data == null) return false;
  try {
    await work(data);
    return true;
  } finally {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists && snap.data()?.[field]?.owner === owner) {
        tx.set(ref, { [field]: null }, { merge: true });
      }
    });
  }
}

module.exports = { withProcessingLease };
