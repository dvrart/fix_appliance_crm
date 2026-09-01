/**
 * Push мастеру. Data — всегда (роут по tap, Twilio Voice не трогаем).
 * На Android ещё и notification: иначе Samsung не будит убитый процесс
 * и шторка появляется только когда FIX открывает приложение.
 * Twilio Voice остаётся data-only — его шлёт Twilio, не notifyMaster.
 */
const admin = require('firebase-admin');

const COMPANY_ID = 'fix_appliance_ca';

function tokensRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('fcm_tokens');
}

function channelFor(data) {
  const type = String(data.type || 'sms');
  const source = String(data.source || '');
  const secretaryAnswered = type === 'call' && String(data.answeredBy || '') === 'ai';
  if (
    type === 'email' ||
    type === 'email_offer' ||
    type === 'shipment' ||
    (type === 'job' && source === 'email')
  ) {
    return 'email_messages';
  }
  if (type === 'visit_confirm' || type === 'estimate_confirm') return 'visit_confirm';
  if (type === 'secretary_lesson') return 'secretary_learn';
  if (type === 'visit_soon') return 'visit_soon';
  if (type === 'on_the_way' || type === 'leave_status') return 'on_the_way';
  if (type === 'morning' || type === 'evening') return 'morning_jobs';
  if (type === 'call' || type === 'job' || secretaryAnswered) return 'incoming_calls';
  return 'sms_messages';
}

function last10(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  return digits.length >= 10 ? digits.slice(-10) : '';
}

function shadeTag(data) {
  const from = String(data.from || data.to || '');
  const phone = last10(from);
  if (phone) return `crm_inbox_${phone}`.slice(0, 50);
  const email = from.includes('@') ? from.trim().toLowerCase() : '';
  if (email) return `crm_inbox_${email}`.slice(0, 50);
  const type = String(data.type || 'sms');
  const key = String(
    data.callSid || data.callId || data.messageId || data.jobId || 'inbox'
  );
  return `crm_${type}_${key}`.slice(0, 50);
}

function cityFromAddress(address) {
  const parts = String(address || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean);
  if (!parts.length) return '';
  const postalRe = /^[A-Za-z]\d[A-Za-z]\s?\d[A-Za-z]\d$/;
  if (parts.length >= 2 && postalRe.test(parts[parts.length - 1])) {
    return parts.length >= 3 ? parts[parts.length - 2] : '';
  }
  if (parts.length >= 2) return parts[parts.length - 1];
  return '';
}

function applianceOf(job) {
  if (job && job.applianceType) return String(job.applianceType);
  const list = job && job.appliances;
  if (Array.isArray(list) && list[0]) return String(list[0].type || '');
  return '';
}

function nameOf(job) {
  if (!job) return '';
  if (job.hasJobSite && job.jobSiteName) return String(job.jobSiteName);
  return String(job.clientName || job.contactName || '').trim();
}

function cityOf(job) {
  if (!job) return '';
  const raw = String(job.city || job.displayCity || '').trim();
  if (raw) return raw;
  return cityFromAddress(job.hasJobSite ? job.jobSiteAddress : job.clientAddress);
}

async function attachShadeFields(stringData) {
  try {
    const company = admin.firestore().collection('companies').doc(COMPANY_ID);
    if (stringData.jobId) {
      const snap = await company.collection('jobs').doc(stringData.jobId).get();
      if (snap.exists) {
        const job = snap.data() || {};
        if (!stringData.applianceType) stringData.applianceType = applianceOf(job);
        if (!stringData.clientName) stringData.clientName = nameOf(job);
        if (!stringData.city) stringData.city = cityOf(job);
      }
    }
    if ((!stringData.clientName || !stringData.city) && stringData.clientId) {
      const snap = await company.collection('clients').doc(stringData.clientId).get();
      if (snap.exists) {
        const client = snap.data() || {};
        if (!stringData.clientName) {
          stringData.clientName = String(client.fullName || client.name || '').trim();
        }
        if (!stringData.city) {
          const loc =
            Array.isArray(client.locations) && client.locations[0] ? client.locations[0] : {};
          stringData.city =
            String(loc.city || '').trim() ||
            cityFromAddress(loc.address || loc.street || '');
        }
      }
    }
  } catch (error) {
    console.warn('attachShadeFields:', error.message);
  }
}

async function notifyMaster(title, body, data = {}) {
  const snapshot = await tokensRef().get();
  const tokens = snapshot.docs.map((d) => d.data().token).filter(Boolean);
  if (!tokens.length) {
    console.warn('notifyMaster: нет сохранённых FCM-токенов');
    return;
  }

  const stringData = {};
  for (const [key, value] of Object.entries(data)) {
    stringData[key] = String(value ?? '');
  }
  await attachShadeFields(stringData);

  const type = String(data.type || 'sms');
  const tag = shadeTag({ ...stringData, type });
  const channelId = channelFor({ ...data, type });
  stringData.type = type;
  stringData.tag = tag;
  stringData.channelId = channelId;
  stringData.title = String(title || '');
  stringData.body = String(body || '');

  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    data: stringData,
    android: {
      priority: 'high',
      ttl: 86400000,
      notification: {
        title: String(title || ''),
        body: String(body || ''),
        channelId,
        tag,
        icon: 'ic_stat_notify',
        color: '#FCC520',
        sound: 'default',
        priority: 'max',
        visibility: 'public',
        notificationCount: 1,
        defaultSound: true,
        defaultVibrateTimings: true,
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
      },
    },
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-push-type': 'alert',
      },
      payload: {
        aps: {
          alert: { title: String(title || ''), body: String(body || '') },
          sound: 'default',
          'interruption-level': 'time-sensitive',
        },
      },
    },
  });

  const stale = [];
  response.responses.forEach((r, i) => {
    if (!r.success) {
      const code = r.error && r.error.code;
      if (
        code === 'messaging/registration-token-not-registered' ||
        code === 'messaging/invalid-registration-token'
      ) {
        stale.push(snapshot.docs[i].id);
      } else {
        console.warn('notifyMaster: ошибка отправки', code, r.error && r.error.message);
      }
    }
  });
  await Promise.all(stale.map((id) => tokensRef().doc(id).delete()));
}

module.exports = { notifyMaster, channelFor };
