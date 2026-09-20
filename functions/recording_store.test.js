const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');
const { createRecordingStore, isTwilioMediaUrl, appendCallRecording } = require('./recording_store');
const twilio = require('twilio');
const { settledCallStatus } = require('./voice_facts');

const BUCKET = 'test-project.firebasestorage.app';
const PATH = 'companies/test-company/calls/CA-test.mp3';
let objects;
let documents;
let downloads;
let requests;
let saves;
let fetchResponse;

function file(path) {
  return {
    getMetadata: async () => {
      if (!objects.has(path)) throw Object.assign(new Error('Not found'), { code: 404 });
      return [structuredClone(objects.get(path).metadata)];
    },
    save: async (body, options) => {
      const existing = objects.get(path);
      const generation = Number(existing?.metadata.generation || 0);
      if (Number(options.preconditionOpts?.ifGenerationMatch) !== generation) {
        throw Object.assign(new Error('Changed concurrently'), { code: 412 });
      }
      saves++;
      objects.set(path, {
        body: Buffer.from(body),
        metadata: { ...structuredClone(options.metadata), size: String(body.length), generation: String(generation + 1), metageneration: '1' },
      });
    },
    setMetadata: async (data) => {
      const object = objects.get(path);
      object.metadata = { ...object.metadata, ...structuredClone(data) };
      return [object.metadata];
    },
    download: async () => {
      downloads++;
      if (!objects.has(path)) throw Object.assign(new Error('Not found'), { code: 404 });
      return [objects.get(path).body];
    },
  };
}

function store() {
  return createRecordingStore({
    storage: () => ({ bucket: (name = BUCKET) => ({ name, file }) }),
    callsRef: { doc: (id) => ({ set: async (data) => documents.set(id, data) }) },
    companyId: 'test-company',
    projectId: 'test-project',
    playableUrl: (id) => `https://example.test/audio?callId=${id}`,
    authHeaders: () => ['Basic synthetic-primary', 'Basic synthetic-secondary'],
    sleep: async () => {},
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return fetchResponse(url, options);
    },
  });
}

beforeEach(() => {
  objects = new Map();
  documents = new Map();
  downloads = 0;
  saves = 0;
  requests = [];
  fetchResponse = async () => new Response(Buffer.from('ID3 synthetic audio'));
});

test('recording TwiML uses the supported dual-channel attributes without a second REST recording', () => {
  const response = new twilio.twiml.VoiceResponse();
  appendCallRecording(response, 'https://example.test/recordingComplete');
  const xml = response.toString();
  assert.equal((xml.match(/<Recording /g) || []).length, 1);
  assert.match(xml, /channels="dual"/);
  assert.match(xml, /track="both"/);
  assert.match(xml, /recordingStatusCallbackEvent="completed"/);
  assert.doesNotMatch(xml, /recordingTrack=/);
});

test('late ringing and secretary-pickup updates cannot reopen a completed call', () => {
  for (const incoming of ['queued', 'ringing', 'in-progress', 'failed', 'no-answer']) {
    assert.equal(settledCallStatus('completed', incoming), 'completed');
  }
  assert.equal(settledCallStatus('in-progress', 'ringing'), 'in-progress');
  assert.equal(settledCallStatus('ringing', 'in-progress'), 'in-progress');
});

test('the final completed callback can reconcile an older dial failure', () => {
  assert.equal(settledCallStatus('no-answer', 'completed'), 'completed');
  assert.equal(settledCallStatus('', 'ringing'), 'ringing');
  assert.equal(settledCallStatus('failed', 'in-progress'), 'failed');
});

test('caching the same recording twice never revokes the first download URL', async () => {
  const audio = store();
  const first = await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 first recording'));
  const second = await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 first recording'));
  assert.equal(second, first);
  assert.equal(new URL(first).searchParams.get('token'), objects.get(PATH).metadata.metadata.firebaseStorageDownloadTokens);
  assert.equal(saves, 1);
});

test('a longer recording keeps the stable token while replacing incomplete audio', async () => {
  const audio = store();
  const first = await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 short'));
  const second = await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 complete longer recording'));
  assert.equal(first, second);
  assert.equal(objects.get(PATH).body.toString(), 'ID3 complete longer recording');
});

test('a late shorter recording cannot overwrite the complete recording', async () => {
  const audio = store();
  await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 complete longer recording'));
  await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 short'));
  assert.equal(objects.get(PATH).body.toString(), 'ID3 complete longer recording');
  assert.equal(saves, 1);
});

test('concurrent function instances agree on one storage token and preserve the longest audio', async () => {
  const [first, second] = await Promise.all([
    store().cacheRecordingToStorage('CA-test', Buffer.from('ID3 short')),
    store().cacheRecordingToStorage('CA-test', Buffer.from('ID3 complete longer recording')),
  ]);
  assert.equal(first, second);
  assert.equal(new URL(documents.get('CA-test').storageUrl).searchParams.get('token'), objects.get(PATH).metadata.metadata.firebaseStorageDownloadTokens);
  assert.equal(objects.get(PATH).body.toString(), 'ID3 complete longer recording');
});

test('server processing reads its own storage using server credentials, not an expired public link', async () => {
  const audio = store();
  const current = await audio.cacheRecordingToStorage('CA-test', Buffer.from('ID3 saved recording'));
  const expired = new URL(current);
  expired.searchParams.set('token', 'expired-synthetic-token');
  fetchResponse = async () => new Response('Forbidden', { status: 403 });
  assert.equal((await audio.downloadRecordingBuffer(expired.toString())).toString(), 'ID3 saved recording');
  assert.equal(requests.length, 0);
  assert.equal(downloads, 1);
});

test('Twilio retries the alternate credential and every fetch has a deadline', async () => {
  fetchResponse = async (_, options) => options.headers.Authorization === 'Basic synthetic-primary'
    ? new Response('Forbidden', { status: 403 }) : new Response('ID3 audio');
  const audio = store();
  const bytes = await audio.downloadRecordingBuffer('https://api.twilio.com/2010-04-01/Accounts/AC-test/Recordings/RE-test?RequestedChannels=2');
  assert.equal(bytes.toString(), 'ID3 audio');
  assert.ok(requests.every((request) => request.options.signal instanceof AbortSignal));
  assert.ok(requests[0].url.includes('RE-test.mp3?RequestedChannels=2'));
  assert.equal(requests.length, 2);
});

test('lookalike media URLs cannot receive Twilio credentials', async () => {
  for (const url of [
    'https://api.twilio.com.evil.example/recording',
    'https://example.test/?next=twilio.com',
    'http://api.twilio.com/recording',
    'https://evil-twilio.com/recording',
  ]) {
    assert.equal(isTwilioMediaUrl(url), false);
    await assert.rejects(store().downloadRecordingBuffer(url), /Unsupported recording source/);
  }
  assert.equal(requests.length, 0);
});

test('foreign storage paths are never read with server privileges', async () => {
  await assert.rejects(store().downloadRecordingBuffer(`https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/companies%2Fother-company%2Fcalls%2Fprivate.mp3?alt=media`), /Unsupported recording source/);
  assert.equal(downloads, 0);
});

test('HTML and empty responses are rejected without logging signed URLs', async () => {
  fetchResponse = async () => new Response('<html>not audio</html>');
  await assert.rejects(store().downloadRecordingBuffer('https://api.twilio.com/Recordings/RE-test.mp3'), /not audio/);
  fetchResponse = async () => new Response('');
  await assert.rejects(store().downloadRecordingBuffer('https://api.twilio.com/Recordings/RE-test.mp3'), /empty/);
});
