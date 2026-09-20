const { accessToken } = require('./read_logs');

const PROJECT = 'fix-appliance-crm';
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const COMPANY = 'companies/fix_appliance_ca';

function plain(value) {
  if (!value) return null;
  if ('stringValue' in value) return value.stringValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(plain);
  if ('mapValue' in value) return fields(value.mapValue.fields);
  return null;
}

function fields(raw) {
  return Object.fromEntries(Object.entries(raw || {}).map(([key, value]) => [key, plain(value)]));
}

async function main() {
  const token = await accessToken();
  async function get(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(30000),
    });
    const body = await response.json();
    if (!response.ok || body.error) throw new Error(`API ${response.status}: ${body.error?.message || 'request failed'}`);
    return body;
  }
  const [configDoc, registrations, errors, deployed] = await Promise.all([
    get(`${BASE}/${COMPANY}/settings/config`),
    get(`${BASE}/${COMPANY}/fcm_tokens?pageSize=1000`),
    get(`${BASE}/${COMPANY}/app_errors?pageSize=300`),
    get(`https://cloudfunctions.googleapis.com/v2/projects/${PROJECT}/locations/us-central1/functions?pageSize=1000`),
  ]);
  const config = fields(configDoc.fields);
  const keys = [
    'aiAnswerEnabled', 'aiAnswerTimeoutSeconds', 'manualSmsApproval', 'bookingSmsEnabled',
    'reminderSmsEnabled', 'autoReviewSmsEnabled', 'morningBriefingEnabled', 'onTheWayPromptEnabled',
    'workDays', 'workStartMinutes', 'workEndMinutes', 'holidayDates', 'vacationRanges',
    'defaultVisitMinutes', 'serviceCallFee', 'hourlyRate', 'minimumCharge', 'defaultTax',
  ];
  console.log('SETTINGS', JSON.stringify(Object.fromEntries(keys.filter((key) => key in config).map((key) => [key, config[key]]))));
  const tokens = (registrations.documents || []).map((doc) => fields(doc.fields));
  const active = tokens.filter((row) => typeof row.token === 'string' && row.token && row.disabled !== true);
  console.log('FCM', JSON.stringify({
    records: tokens.length, active: active.length,
    uniqueTokens: new Set(active.map((row) => row.token)).size,
    withDeviceId: active.filter((row) => row.deviceId).length,
    platforms: [...new Set(active.map((row) => row.platform || 'unknown'))],
    updatedAt: active.map((row) => row.updatedAt || null),
    morePages: Boolean(registrations.nextPageToken),
  }));
  const functions = deployed.functions || [];
  const names = new Set(['incomingCall', 'outgoingCall', 'dialAction', 'callStatusCallback', 'aiVoiceRelay', 'aiRelayComplete', 'processCallRecording', 'incomingSms', 'registerFcmToken', 'onJobWritten', 'sendVisitReminders', 'syncGmailInbox']);
  for (const fn of functions) {
    const name = fn.name.split('/').pop();
    if (!names.has(name)) continue;
    const service = fn.serviceConfig || {};
    const env = service.environmentVariables || {};
    console.log('FUNCTION', JSON.stringify({
      name, state: fn.state, updated: fn.updateTime, timeout: service.timeoutSeconds,
      memory: service.availableMemory, revision: service.revision,
      twilioSignatureMode: env.TWILIO_SIGNATURE_MODE || 'enforce',
      relayKeyConfigured: Boolean(env.VOICE_RELAY_KEY || service.secretEnvironmentVariables?.some((row) => row.key === 'VOICE_RELAY_KEY')),
      voicePushConfigured: Boolean(env.TWILIO_PUSH_CREDENTIAL_SID),
    }));
  }
  const errorRows = (errors.documents || []).map((doc) => fields(doc.fields))
    .sort((a, b) => String(b.at || b.createdAt || '').localeCompare(String(a.at || a.createdAt || '')));
  const seen = new Set();
  for (const row of errorRows) {
    const message = String(row.message || '').replace(/([?&](?:auth|key|token)=)[^&\s]+/gi, '$1[redacted]');
    if (seen.has(message) || row.kind === 'crash') continue;
    seen.add(message);
    console.log('APP_ERROR', JSON.stringify({ at: row.at || row.createdAt, screen: row.screen, message: message.slice(0, 450), stack: String(row.stack || row.stackTrace || '').slice(0, 3500) }));
    if (seen.size >= 8) break;
  }
  const recentCalls = await get(`${BASE}/${COMPANY}:runQuery`, {
    method: 'POST',
    body: JSON.stringify({ structuredQuery: {
      from: [{ collectionId: 'calls' }],
      orderBy: [{ field: { fieldPath: 'startTime' }, direction: 'DESCENDING' }],
      limit: 20,
      select: { fields: ['startTime', 'status', 'twilioStatus', 'direction', 'answeredBy', 'aiStatus', 'aiError', 'durationSeconds', 'aiReception.streamResumes', 'aiReception.liveError'].map((fieldPath) => ({ fieldPath })) },
    } }),
  });
  for (const row of recentCalls) {
    if (row.document) console.log('CALL', JSON.stringify({ id: row.document.name.split('/').pop().slice(-8), ...fields(row.document.fields) }));
  }
  if (process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN) {
    const twilio = require('../functions/node_modules/twilio');
    const client = twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN);
    const numbers = await client.incomingPhoneNumbers.list({ limit: 10 });
    for (const number of numbers) {
      console.log('TWILIO_NUMBER', JSON.stringify({
        last4: number.phoneNumber.slice(-4),
        voiceUrl: String(number.voiceUrl || '').split('?')[0], voiceMethod: number.voiceMethod,
        statusCallback: String(number.statusCallback || '').split('?')[0],
        smsUrl: String(number.smsUrl || '').split('?')[0], smsMethod: number.smsMethod,
      }));
    }
    if (process.env.TWILIO_TWIML_APP_SID) {
      const app = await client.applications(process.env.TWILIO_TWIML_APP_SID).fetch();
      console.log('TWILIO_APP', JSON.stringify({ voiceUrl: String(app.voiceUrl || '').split('?')[0], voiceMethod: app.voiceMethod, statusCallback: String(app.statusCallback || '').split('?')[0] }));
    }
  }
}

main().catch((error) => {
  console.error('Runtime audit failed: ' + error.message);
  process.exitCode = 1;
});
