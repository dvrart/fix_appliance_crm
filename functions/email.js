const admin = require('firebase-admin');
const nodemailer = require('nodemailer');
const { ImapFlow } = require('imapflow');
const { simpleParser } = require('mailparser');
const crypto = require('crypto');

const COMPANY_ID = 'fix_appliance_ca';

function refs() {
  const db = admin.firestore();
  const company = db.collection('companies').doc(COMPANY_ID);
  return {
    db,
    messagesRef: company.collection('messages'),
    clientsRef: company.collection('clients'),
    gmailRef: company.collection('settings').doc('gmail'),
    documentsRef: company.collection('settings').doc('documents'),
    jobsRef: company.collection('jobs'),
    shipmentEventsRef: company.collection('shipment_events'),
  };
}

async function getGmailAuth() {
  const envUser = (process.env.GMAIL_USER || '').trim();
  const envPass = (process.env.GMAIL_APP_PASSWORD || '').trim();
  if (envUser && envPass) return { user: envUser, pass: envPass };

  const snap = await refs().gmailRef.get();
  const data = snap.exists ? snap.data() || {} : {};
  const user = String(data.user || '').trim();
  const pass = String(data.appPassword || '').trim();
  if (user && pass) return { user, pass };
  return null;
}

async function getCompanyName() {
  try {
    const snap = await refs().documentsRef.get();
    const name = String((snap.data() || {}).companyName || '').trim();
    return name || 'Fix Appliance';
  } catch (_) {
    return 'Fix Appliance';
  }
}

async function findClientByEmail(email) {
  const normalized = String(email || '').trim().toLowerCase();
  if (!normalized.includes('@')) return null;
  const snapshot = await refs().clientsRef.get();
  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    const emails = [data.email];
    for (const location of data.locations || []) {
      emails.push(location.email);
      for (const contact of location.contacts || []) {
        emails.push(contact.email);
      }
    }
    if (emails.some((value) => String(value || '').trim().toLowerCase() === normalized)) {
      return { id: doc.id, ...data };
    }
  }
  return null;
}

function normalizeMessageId(value) {
  return String(value || '')
    .trim()
    .replace(/^<|>$/g, '')
    .toLowerCase();
}

function collectHeaderIds(parsed) {
  const ids = [];
  const push = (value) => {
    if (!value) return;
    if (Array.isArray(value)) {
      value.forEach(push);
      return;
    }
    String(value)
      .split(/[\s,]+/)
      .forEach((part) => {
        const id = normalizeMessageId(part);
        if (id) ids.push(id);
      });
  };
  push(parsed.inReplyTo);
  push(parsed.references);
  return ids;
}

async function loadCrmEmailGate() {
  const snap = await refs().messagesRef.where('channel', '==', 'email').get();
  const sentTo = new Map();
  const messageIds = new Map();
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (data.direction !== 'outbound') continue;
    const to = extractAddress(data.toEmail || data.to);
    const clientId = data.clientId || null;
    if (to.includes('@') && (!sentTo.has(to) || (!sentTo.get(to) && clientId))) {
      sentTo.set(to, clientId);
    }
    const id = normalizeMessageId(data.emailMessageId || data.sid);
    if (id && (!messageIds.has(id) || (!messageIds.get(id) && clientId))) {
      messageIds.set(id, clientId);
    }
  }
  return { sentTo, messageIds };
}

function extractAddress(value) {
  if (!value) return '';
  if (typeof value === 'string') return value.trim().toLowerCase();
  if (value.text) return String(value.text).trim().toLowerCase();
  if (value.value) {
    const first = Array.isArray(value.value) ? value.value[0] : value.value;
    if (first && first.address) return String(first.address).trim().toLowerCase();
  }
  if (Array.isArray(value) && value[0]) {
    return String(value[0].address || value[0] || '').trim().toLowerCase();
  }
  return '';
}

function parseReqBody(req) {
  const raw = req.body;
  if (typeof raw === 'string') {
    try {
      return JSON.parse(raw);
    } catch (_) {
      return {};
    }
  }
  return raw || {};
}

function extractTrackingNumber(text) {
  const blob = String(text || '');
  const patterns = [
    /\b(TBA\d{10,})\b/i,
    /\b(\d{3}-\d{7}-\d{7})\b/,
    /\b(1Z[A-Z0-9]{16})\b/i,
    /\b([A-Z]{2}\d{9}CA)\b/i,
  ];
  for (const pattern of patterns) {
    const match = blob.match(pattern);
    if (match) return match[1];
  }
  return '';
}

function isAmazonMail(fromEmail, subject, body) {
  const blob = `${fromEmail} ${subject} ${body}`.toLowerCase();
  return /amazon\.ca|amazon\.com|amazon\.co|shipment-tracking@|auto-confirm@amazon|order-update@amazon|marketplace\.amazon/.test(
    blob
  );
}

function amazonShipmentStatus(subject, body) {
  const blob = `${subject} ${body}`.toLowerCase();
  if (/delivered|was delivered|has been delivered|left at|доставлено/.test(blob)) {
    return 'delivered';
  }
  if (/out for delivery|arriving today|today's delivery|курьер/.test(blob)) {
    return 'out_for_delivery';
  }
  if (/shipped|has shipped|on the way|отправлен/.test(blob)) {
    return 'shipped';
  }
  return '';
}

module.exports = function createEmailModule({ notifyMaster, setCors, handleOptions }) {
  async function sendEmail(req, res) {
    if (handleOptions(req, res)) return;
    setCors(res);

    const payload = parseReqBody(req);
    const to = String(payload.to || '').trim().toLowerCase();
    const body = String(payload.body || '').trim();
    const subject = String(payload.subject || '').trim();
    const clientId = payload.clientId || null;
    const phone = payload.phone || null;
    const mediaUrls = Array.isArray(payload.mediaUrls)
      ? payload.mediaUrls
          .map((url) => String(url || '').trim())
          .filter((url) => /^https?:\/\//i.test(url))
          .slice(0, 10)
      : [];

    if (!to.includes('@') || (!body && !mediaUrls.length)) {
      res.status(400).json({ error: 'Нужны поля to и body' });
      return;
    }

    const auth = await getGmailAuth();
    if (!auth) {
      res.status(400).json({ error: 'Подключите Gmail в настройках связи' });
      return;
    }

    try {
      const companyName = await getCompanyName();
      const mailSubject = subject || `${companyName}`;
      const messageId = `<crm-${crypto.randomUUID()}@${String(auth.user).split('@')[1] || 'gmail.com'}>`;
      const transporter = nodemailer.createTransport({
        service: 'gmail',
        auth,
      });
      const attachments = [];
      for (const url of mediaUrls) {
        try {
          const fileRes = await fetch(url, { signal: AbortSignal.timeout(20000) });
          if (!fileRes.ok) continue;
          const buf = Buffer.from(await fileRes.arrayBuffer());
          const contentType = (fileRes.headers.get('content-type') || 'application/octet-stream').split(';')[0];
          const rawName = decodeURIComponent((url.split('?')[0].split('/').pop() || 'file').replace(/^\d+_/, ''));
          attachments.push({
            filename: rawName || 'file',
            content: buf,
            contentType,
          });
        } catch (error) {
          console.warn('sendEmail attachment failed:', error.message);
        }
      }

      const info = await transporter.sendMail({
        from: `"${companyName}" <${auth.user}>`,
        to,
        subject: mailSubject,
        text: body || (attachments.length ? ' ' : ''),
        attachments,
        messageId,
        headers: { 'X-Fix-CRM': '1' },
      });
      const storedId = normalizeMessageId(info.messageId || messageId);

      let resolvedClientId = clientId;
      if (!resolvedClientId) {
        const matched = await findClientByEmail(to);
        resolvedClientId = matched ? matched.id : null;
      }

      await refs().messagesRef.add({
        sid: storedId || `email-${Date.now()}`,
        from: auth.user,
        to,
        fromEmail: auth.user,
        toEmail: to,
        body,
        subject: mailSubject,
        direction: 'outbound',
        channel: 'email',
        status: 'sent',
        clientId: resolvedClientId,
        phone: phone || null,
        mediaUrls,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: true,
        emailMessageId: storedId,
        crmThread: true,
      });

      res.json({ success: true });
    } catch (error) {
      console.error('sendEmail error:', error);
      res.status(500).json({ error: error.message });
    }
  }

  async function ingestAmazonShipment(parsed, uid) {
    const fromEmail = extractAddress(parsed.from);
    const subject = String(parsed.subject || '').trim();
    const text = String(parsed.text || '')
      .trim()
      .slice(0, 12000);
    const htmlFallback = parsed.html
      ? String(parsed.html).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 12000)
      : '';
    const body = `${text} ${htmlFallback}`;
    if (!isAmazonMail(fromEmail, subject, body)) return false;
    const status = amazonShipmentStatus(subject, body);
    if (!status) return false;

    const messageId = normalizeMessageId(parsed.messageId || `amazon-${uid}`);
    const eventRef = refs().shipmentEventsRef.doc(messageId.slice(0, 700) || `uid-${uid}`);
    const existingEvent = await eventRef.get();
    if (existingEvent.exists) return true;

    const tracking = extractTrackingNumber(`${subject} ${body}`);
    const orderId = (String(`${subject} ${body}`).match(/\b(\d{3}-\d{7}-\d{7})\b/) || [])[1] || '';
    const jobsSnap = await refs().jobsRef.get();
    let matched = null;
    for (const doc of jobsSnap.docs) {
      const data = doc.data() || {};
      const jobTrack = String(data.trackingNumber || '').replace(/\s/g, '');
      const jobOrder = String(data.amazonOrderId || '').trim();
      if (tracking && jobTrack && jobTrack.toLowerCase() === tracking.replace(/\s/g, '').toLowerCase()) {
        matched = { id: doc.id, ...data };
        break;
      }
      if (orderId && jobOrder && jobOrder === orderId) {
        matched = { id: doc.id, ...data };
        break;
      }
    }

    await eventRef.set({
      messageId,
      uid: uid || null,
      status,
      trackingNumber: tracking,
      amazonOrderId: orderId,
      jobId: matched ? matched.id : null,
      subject,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (matched) {
      await refs().jobsRef.doc(matched.id).set(
        {
          trackingStatus: status,
          trackingNumber: tracking || matched.trackingNumber || '',
          amazonOrderId: orderId || matched.amazonOrderId || '',
          trackingCarrier: 'amazon',
          trackingUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    if (notifyMaster) {
      const who = matched
        ? `${matched.clientName || ''} ${matched.applianceType || ''}`.trim()
        : tracking || orderId || subject;
      const title =
        status === 'delivered'
          ? 'Amazon: доставлено'
          : status === 'out_for_delivery'
            ? 'Amazon: курьер сегодня'
            : 'Amazon: отправлено';
      await notifyMaster(title, who, {
        type: 'shipment',
        jobId: matched ? matched.id : '',
        trackingStatus: status,
      });
    }
    return true;
  }

  async function ingestParsed(parsed, ourUser, uid, gate) {
    const fromEmail = extractAddress(parsed.from);
    const toEmail = extractAddress(parsed.to) || ourUser.toLowerCase();
    if (!fromEmail.includes('@')) return false;
    if (fromEmail === ourUser.toLowerCase()) return false;

    if (await ingestAmazonShipment(parsed, uid)) {
      return true;
    }

    const replyIds = collectHeaderIds(parsed);
    const replyClientId = replyIds.map((id) => gate.messageIds.get(id)).find(Boolean) || null;
    const isCrmReply = gate.sentTo.has(fromEmail) || replyIds.some((id) => gate.messageIds.has(id));
    if (!isCrmReply) {
      console.log(`syncGmailInbox skip non-CRM ${fromEmail} uid=${uid || '-'}`);
      return false;
    }

    const messageId = normalizeMessageId(parsed.messageId || `uid-${uid}`);
    const existing = await refs().messagesRef.where('emailMessageId', '==', messageId).limit(1).get();
    if (!existing.empty) return false;

    const matched = await findClientByEmail(fromEmail);
    const clientId = (matched && matched.id) || replyClientId || gate.sentTo.get(fromEmail) || null;
    const text = String(parsed.text || '')
      .trim()
      .slice(0, 8000);
    const htmlFallback = parsed.html
      ? String(parsed.html).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 8000)
      : '';
    const body = text || htmlFallback || '(пустое письмо)';
    const subject = String(parsed.subject || '').trim();
    const created = parsed.date instanceof Date ? parsed.date : new Date();

    await refs().messagesRef.add({
      sid: messageId,
      from: fromEmail,
      to: toEmail,
      fromEmail,
      toEmail,
      body,
      subject,
      direction: 'inbound',
      channel: 'email',
      status: 'received',
      clientId,
      createdAt: admin.firestore.Timestamp.fromDate(created),
      read: false,
      emailMessageId: messageId,
      gmailUid: uid || null,
      crmThread: true,
      inReplyTo: replyIds[0] || null,
    });

    const isFresh = Date.now() - created.getTime() < 20 * 60 * 1000;
    if (isFresh && notifyMaster) {
      const who = matched
        ? (matched.fullName || matched.name || fromEmail)
        : fromEmail;
      await notifyMaster(`Письмо от ${who}`, subject || body.slice(0, 80), {
        type: 'email',
        from: fromEmail,
        to: toEmail,
      });
    }
    return true;
  }

  async function cleanupLegacyInbox() {
    const stateSnap = await refs().gmailRef.get();
    const state = stateSnap.exists ? stateSnap.data() || {} : {};
    if (state.legacyInboxCleaned) return;
    const snap = await refs().messagesRef.where('channel', '==', 'email').get();
    const batch = refs().db.batch();
    let removed = 0;
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.direction === 'outbound') continue;
      if (data.crmThread === true) continue;
      batch.delete(doc.ref);
      removed += 1;
    }
    if (removed > 0) await batch.commit();
    await refs().gmailRef.set(
      { legacyInboxCleaned: true, inboxMode: 'crm-replies' },
      { merge: true }
    );
    console.log(`syncGmailInbox: removed ${removed} non-CRM inbound emails`);
  }

  async function syncGmailInbox() {
    const auth = await getGmailAuth();
    if (!auth) {
      console.log('syncGmailInbox: Gmail не подключён');
      return;
    }

    await cleanupLegacyInbox();

    const stateSnap = await refs().gmailRef.get();
    const state = stateSnap.exists ? stateSnap.data() || {} : {};
    const lastUid = Number(state.lastUid || 0);
    const client = new ImapFlow({
      host: 'imap.gmail.com',
      port: 993,
      secure: true,
      auth,
      logger: false,
    });

    await client.connect();
    const lock = await client.getMailboxLock('INBOX');
    let maxUid = lastUid;
    try {
      const uidNext = Number(client.mailbox.uidNext || 1);
      if (lastUid <= 0) {
        const skipTo = Math.max(0, uidNext - 1);
        await refs().gmailRef.set(
          { lastUid: skipTo, inboxMode: 'crm-replies' },
          { merge: true }
        );
        console.log(`syncGmailInbox: skip mailbox history, lastUid=${skipTo}`);
        return;
      }
      if (lastUid >= uidNext - 1) {
        if (state.inboxMode !== 'crm-replies') {
          await refs().gmailRef.set({ inboxMode: 'crm-replies' }, { merge: true });
        }
        return;
      }
      const gate = await loadCrmEmailGate();
      const fromUid = lastUid + 1;
      for await (const msg of client.fetch(
        { uid: `${fromUid}:*` },
        { uid: true, source: true, envelope: true }
      )) {
        maxUid = Math.max(maxUid, Number(msg.uid || 0));
        try {
          const parsed = await simpleParser(msg.source);
          await ingestParsed(parsed, auth.user, msg.uid, gate);
        } catch (error) {
          console.error(`syncGmailInbox uid ${msg.uid}:`, error.message);
        }
      }
    } finally {
      lock.release();
      await client.logout().catch(() => {});
    }

    if (maxUid > lastUid) {
      await refs().gmailRef.set(
        { lastUid: maxUid, inboxMode: 'crm-replies' },
        { merge: true }
      );
    }
  }

  return { sendEmail, syncGmailInbox };
};
