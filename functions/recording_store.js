const crypto = require('node:crypto');

function isTwilioMediaUrl(raw) {
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && (url.hostname === 'api.twilio.com' || url.hostname.endsWith('.api.twilio.com'));
  } catch (_) {
    return false;
  }
}

async function deadline(work, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      work,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Recording storage timed out')), milliseconds); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function createRecordingStore({ storage, callsRef, companyId, projectId, playableUrl, authHeaders, fetchImpl = fetch, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) }) {
  function bucketForWrite() {
    try {
      return storage().bucket();
    } catch (_) {
      return storage().bucket(`${projectId}.firebasestorage.app`);
    }
  }

  function storedLocation(raw) {
    let url;
    try { url = new URL(raw); } catch (_) { return null; }
    if (url.protocol !== 'https:' || url.hostname !== 'firebasestorage.googleapis.com') return null;
    const match = url.pathname.match(/^\/v0\/b\/([^/]+)\/o\/(.+)$/);
    if (!match) return null;
    const bucket = decodeURIComponent(match[1]);
    const path = decodeURIComponent(match[2]);
    const allowed = new Set([bucketForWrite().name, `${projectId}.firebasestorage.app`, `${projectId}.appspot.com`]);
    if (!allowed.has(bucket) || !path.startsWith(`companies/${companyId}/calls/`)) return null;
    return { bucket, path };
  }

  function audioBuffer(bytes) {
    const buffer = Buffer.from(bytes);
    if (!buffer.length) throw new Error('Recording is empty');
    if (/^\s*[<{]|Not Found|Unauthorized/i.test(buffer.subarray(0, 32).toString('utf8'))) {
      throw new Error('Recording response is not audio');
    }
    return buffer;
  }

  async function cacheRecordingToStorage(callId, buffer) {
    if (!callId || !buffer?.length) return null;
    const bucket = bucketForWrite();
    const path = `companies/${companyId}/calls/${callId}.mp3`;
    const file = bucket.file(path);
    try {
      for (let attempt = 0; attempt < 3; attempt++) {
        let metadata;
        try {
          [metadata] = await deadline(file.getMetadata(), 15000);
        } catch (error) {
          if (Number(error.code) !== 404) throw error;
        }
        const existingToken = String(metadata?.metadata?.firebaseStorageDownloadTokens || '').split(',').find(Boolean);
        const token = existingToken || crypto.randomUUID();
        if (!metadata || Number(metadata.size || 0) < buffer.length || !existingToken) {
          try {
            if (metadata && Number(metadata.size || 0) >= buffer.length && !existingToken) {
              await deadline(file.setMetadata({ metadata: { ...metadata.metadata, firebaseStorageDownloadTokens: token } }, {
                ifMetagenerationMatch: metadata.metageneration,
              }), 15000);
            } else {
              await file.save(buffer, {
                resumable: false,
                timeout: 25000,
                preconditionOpts: { ifGenerationMatch: metadata?.generation || 0 },
                metadata: {
                  contentType: 'audio/mpeg',
                  cacheControl: 'private, max-age=604800',
                  metadata: { ...metadata?.metadata, firebaseStorageDownloadTokens: token },
                },
              });
            }
          } catch (error) {
            if (Number(error.code) === 412) continue;
            throw error;
          }
        }
        const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media&token=${token}`;
        await callsRef.doc(callId).set({ storageUrl: url, playableUrl: playableUrl(callId) }, { merge: true });
        return url;
      }
      throw new Error('Recording changed concurrently; retry required');
    } catch (error) {
      console.warn('cacheRecordingToStorage:', error.code || error.name || 'failed');
      return null;
    }
  }

  async function downloadRecordingBuffer(recordingUrl) {
    const raw = String(recordingUrl || '').trim();
    const stored = storedLocation(raw);
    if (stored) {
      const [bytes] = await deadline(storage().bucket(stored.bucket).file(stored.path).download(), 30000);
      return audioBuffer(bytes);
    }
    if (!isTwilioMediaUrl(raw)) throw new Error('Unsupported recording source');
    const mp3 = new URL(raw);
    if (!/\.mp3$/i.test(mp3.pathname)) mp3.pathname = `${mp3.pathname.replace(/\.wav$/i, '').replace(/\/$/, '')}.mp3`;
    const urls = [...new Set([mp3.toString(), raw])];
    const credentials = authHeaders();
    if (!credentials.length) throw new Error('Recording authentication unavailable');
    let lastError;
    for (const url of urls) {
      for (const authorization of credentials) {
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            const response = await fetchImpl(url, {
              headers: { Authorization: authorization },
              redirect: 'follow',
              signal: AbortSignal.timeout(20000),
            });
            if (response.ok) return audioBuffer(await response.arrayBuffer());
            await response.body?.cancel();
            lastError = new Error(`Recording download HTTP ${response.status}`);
            if ([400, 401, 403, 410].includes(response.status)) break;
          } catch (error) {
            lastError = error;
          }
          if (attempt < 2) await sleep(500 * (attempt + 1));
        }
      }
    }
    throw lastError || new Error('Recording download failed');
  }

  return { cacheRecordingToStorage, downloadRecordingBuffer };
}

function appendCallRecording(twiml, callbackUrl) {
  twiml.start().recording({
    channels: 'dual',
    track: 'both',
    recordingStatusCallback: callbackUrl,
    recordingStatusCallbackEvent: ['completed'],
    recordingStatusCallbackMethod: 'POST',
  });
}

module.exports = { createRecordingStore, isTwilioMediaUrl, appendCallRecording };
