const crypto = require('crypto');

/// Еженедельная копия базы в Storage. Работает на сервере, поэтому не зависит
/// от того, включён ли телефон и есть ли на нём интернет.

/// Что кладём в копию. Звонки и SMS тянут за собой мегабайты текста, но их
/// проще потерять, чем клиентов и заявки, поэтому берём разумный минимум.
const COLLECTIONS = [
  'clients',
  'jobs',
  'settings',
  'statuses',
  'catalogs',
  'warehouse',
  'expenses',
  'calendar_events',
];

/// Сколько копий храним. Раз в неделю — это примерно три месяца истории.
const KEEP = 12;

function ymd(date) {
  return date.toISOString().slice(0, 10);
}

/// Firestore отдаёт Timestamp / GeoPoint / DocumentReference — в JSON их нельзя.
function jsonSafe(value) {
  if (value === null || value === undefined) return null;
  const type = typeof value;
  if (type === 'number' || type === 'boolean' || type === 'string') return value;
  if (typeof value.toDate === 'function') {
    try {
      return value.toDate().toISOString();
    } catch (_) {
      return null;
    }
  }
  if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
    return { lat: value.latitude, lng: value.longitude };
  }
  if (value && typeof value.path === 'string' && typeof value.id === 'string') {
    return value.path;
  }
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (type === 'object') {
    const out = {};
    for (const [key, item] of Object.entries(value)) out[key] = jsonSafe(item);
    return out;
  }
  return String(value);
}

function resolveBuckets(admin) {
  const project =
    process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'fix-appliance-crm';
  const candidates = [];
  try {
    candidates.push(admin.storage().bucket());
  } catch (_) {}
  candidates.push(admin.storage().bucket(`${project}.firebasestorage.app`));
  candidates.push(admin.storage().bucket(`${project}.appspot.com`));
  const seen = new Set();
  return candidates.filter((bucket) => {
    const name = bucket && bucket.name;
    if (!name || seen.has(name)) return false;
    seen.add(name);
    return true;
  });
}

/// Собирает JSON со всеми документами перечисленных коллекций.
async function buildBackupPayload(db, companyId) {
  const root = db.collection('companies').doc(companyId);
  const payload = {
    version: 2,
    companyId,
    exportedAt: new Date().toISOString(),
    source: 'weeklyCloudBackup',
    collections: {},
  };
  const counts = {};
  for (const name of COLLECTIONS) {
    try {
      const snapshot = await root.collection(name).get();
      payload.collections[name] = snapshot.docs.map((doc) => ({
        id: doc.id,
        ...jsonSafe(doc.data()),
      }));
      counts[name] = snapshot.size;
    } catch (error) {
      console.warn(`backup: коллекция ${name} пропущена: ${error.message}`);
      payload.collections[name] = [];
      counts[name] = 0;
    }
  }
  payload.counts = counts;
  return payload;
}

/// Оставляет только последние KEEP файлов, остальные удаляет.
async function prune(bucket, prefix) {
  try {
    const [files] = await bucket.getFiles({ prefix });
    const backups = files
      .filter((file) => file.name.endsWith('.json'))
      .sort((a, b) => (a.name < b.name ? 1 : -1));
    for (const old of backups.slice(KEEP)) {
      await old.delete().catch(() => {});
    }
  } catch (error) {
    console.warn(`backup prune: ${error.message}`);
  }
}

/// Делает копию и возвращает { url, path, bytes, counts } либо null.
async function runCloudBackup({ admin, db, companyId }) {
  const payload = await buildBackupPayload(db, companyId);
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const prefix = `companies/${companyId}/backups/`;
  const path = `${prefix}fix-backup-${ymd(new Date())}.json`;
  const token = crypto.randomUUID();

  for (const bucket of resolveBuckets(admin)) {
    try {
      await bucket.file(path).save(body, {
        resumable: false,
        metadata: {
          contentType: 'application/json',
          cacheControl: 'private, max-age=0',
          metadata: { firebaseStorageDownloadTokens: token },
        },
      });
      const encoded = encodeURIComponent(path);
      const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encoded}?alt=media&token=${token}`;
      await prune(bucket, prefix);

      const total = Object.values(payload.counts).reduce((sum, n) => sum + n, 0);
      const record = {
        createdAt: new Date().toISOString(),
        url,
        path,
        bucket: bucket.name,
        bytes: body.length,
        counts: payload.counts,
        totalDocs: total,
      };
      await db
        .collection('companies')
        .doc(companyId)
        .collection('backups')
        .doc(ymd(new Date()))
        .set(record, { merge: true });

      console.log(
        `backup: ${path} (${body.length} байт, ${total} документов) → ${bucket.name}`
      );
      return record;
    } catch (error) {
      console.warn(`backup ${bucket.name}: ${error.message}`);
    }
  }
  return null;
}

/// Журнал ошибок приложения не должен расти вечно — держим две недели.
async function pruneAppErrors(db, companyId, days = 14) {
  try {
    const cutoff = new Date(Date.now() - days * 86400000).toISOString();
    const snapshot = await db
      .collection('companies')
      .doc(companyId)
      .collection('app_errors')
      .get();
    let removed = 0;
    for (const doc of snapshot.docs) {
      const at = String(doc.data().at || '');
      if (at && at < cutoff) {
        await doc.ref.delete().catch(() => {});
        removed++;
      }
    }
    if (removed) console.log(`app_errors: удалено ${removed} старых записей`);
  } catch (error) {
    console.warn(`pruneAppErrors: ${error.message}`);
  }
}

module.exports = { runCloudBackup, pruneAppErrors, COLLECTIONS, KEEP };
