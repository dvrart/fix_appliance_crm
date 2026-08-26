/**
 * Push мастеру: на Android только data (шторку рисует приложение),
 * иначе системное notification-сообщение часто пропадает за кастомным FCM-сервисом Twilio.
 */
const admin = require('firebase-admin');

const { getCompanyId } = require('./tenant');

const COMPANY_ID = getCompanyId();

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

  const type = String(data.type || 'sms');
  const tag = `crm_${type}_${String(data.from || data.to || data.jobId || 'inbox')}`.slice(0, 50);
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
