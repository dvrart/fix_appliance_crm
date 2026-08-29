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
    configRef: company.collection('settings').doc('config'),
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

function emailFingerprint(fromEmail, subject, date) {
  const from = String(fromEmail || '')
    .trim()
    .toLowerCase();
  const subj = String(subject || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
  const when = date instanceof Date && !Number.isNaN(date.getTime()) ? date : new Date();
  const minute = when.toISOString().slice(0, 16);
  return crypto
    .createHash('sha1')
    .update(`${from}|${subj}|${minute}`)
    .digest('hex');
}

function isAlreadyExists(error) {
  const code = error && error.code;
  return (
    code === 6 ||
    code === 'already-exists' ||
    /already exists/i.test(String((error && error.message) || ''))
  );
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

async function readEmailIntakeTitle() {
  try {
    const snap = await refs().configRef.get();
    return String((snap.exists ? snap.data() || {} : {}).emailIntakeTitle || '').trim();
  } catch (_) {
    return '';
  }
}

async function readWatchedEmailSenders() {
  try {
    const snap = await refs().configRef.get();
    const raw = (snap.exists ? snap.data() || {} : {}).watchedEmailSenders;
    if (!Array.isArray(raw)) return [];
    const seen = new Set();
    const result = [];
    for (const item of raw) {
      let email = '';
      if (item && typeof item === 'object') {
        email = String(item.email || item.address || '')
          .trim()
          .toLowerCase();
      } else {
        email = String(item || '').trim().toLowerCase();
      }
      if (!email.includes('@') || seen.has(email)) continue;
      seen.add(email);
      result.push(email);
    }
    return result;
  } catch (_) {
    return [];
  }
}

function subjectMatchesIntake(subject, title) {
  const needle = String(title || '').trim().toLowerCase();
  if (needle.length < 3) return false;
  return String(subject || '').toLowerCase().includes(needle);
}

function looksLikeApplianceRepair(subject, body) {
  const blob = `${subject} ${body}`.toLowerCase();
  if (blob.length < 24) return false;
  if (isPromoOrSocialCopy(blob)) return false;

  const hasAppliance =
    /refrigerator|\bfridge\b|холодильник/.test(blob) ||
    /\bfreezer\b|морозил/.test(blob) ||
    /washing machine|\bwasher\b|стиральн/.test(blob) ||
    /\bdryer\b|сушильн|\bсушилка\b/.test(blob) ||
    /dishwasher|посудомо/.test(blob) ||
    /\bstove\b|\bcooktop\b|\bcook top\b|плита|варочн/.test(blob) ||
    /\boven\b|духовк/.test(blob) ||
    /microwave|микроволн/.test(blob) ||
    /ice maker|льдогенератор/.test(blob) ||
    /\bgas range\b|\belectric range\b|\bkitchen range\b|\brange hood\b|вытяжк/.test(blob) ||
    /бытов\w*\s+техник/.test(blob);

  const hasIntent =
    /\brepair(ing|s)?\b|\bремонт\b/.test(blob) ||
    /fix(ing)? (my|the|our|this|a) /.test(blob) ||
    /not working|doesn['’]?t work|does not work|won['’]?t (start|turn on|drain|spin|cool|heat|agitate)/.test(
      blob
    ) ||
    /не работает|не включа/.test(blob) ||
    /\bbroken\b|сломал/.test(blob) ||
    /leaking|\bleak\b|течёт|течет/.test(blob) ||
    /no (cool|cold|heat|ice|power)/.test(blob) ||
    /service call|book(ing)? .*(tech|technician|repair)/.test(blob) ||
    /need(s)? (a |the )?(tech|technician|repairman|service)/.test(blob) ||
    /вызвать мастера|нужен мастер/.test(blob);

  if (hasAppliance && hasIntent) return true;
  if (
    /appliance repair|ремонт (бытовой )?техник|fix (my|the|our) (fridge|refrigerator|washer|dryer|dishwasher|stove|oven|freezer|microwave)/.test(
      blob
    )
  ) {
    return true;
  }
  return false;
}

function mightBeApplianceRepair(subject, body) {
  if (looksLikeApplianceRepair(subject, body)) return true;
  const blob = `${subject} ${body}`.toLowerCase();
  if (blob.length < 40) return false;
  if (isPromoOrSocialCopy(blob)) return false;
  return (
    /refrigerator|\bfridge\b|холодильник/.test(blob) ||
    /\bfreezer\b|морозил/.test(blob) ||
    /washing machine|\bwasher\b|стиральн/.test(blob) ||
    /\bdryer\b|сушильн|\bсушилка\b/.test(blob) ||
    /dishwasher|посудомо/.test(blob) ||
    /\bstove\b|\bcooktop\b|\bcook top\b|плита|варочн/.test(blob) ||
    /\boven\b|духовк/.test(blob) ||
    /microwave|микроволн/.test(blob) ||
    /ice maker|льдогенератор/.test(blob) ||
    /\bgas range\b|\belectric range\b|\bkitchen range\b|\brange hood\b|вытяжк/.test(blob) ||
    /бытов\w*\s+техник|\bappliance\b/.test(blob)
  );
}

function isPromoOrSocialCopy(blob) {
  return /pins? (for you|you might like)|inspired by your|trending on pinterest|shop these ideas|weekly digest|you might like these pins/.test(
    blob
  );
}

function isBulkPromoMail(fromEmail, subject, body, parsed) {
  const from = String(fromEmail || '').toLowerCase();
  if (
    /pinterest|pinimg|facebookmail|\bfacebook\.com|instagram|twitter\.com|\bx\.com|linkedin|tiktok|mailchimp|sendgrid\.net|constantcontact|hubspot|substack|beehiiv/.test(
      from
    )
  ) {
    return true;
  }
  if (
    /^(noreply|no-reply|no_reply|notifications|news|newsletter|promo|marketing|deals|offers|pinbot)@/.test(
      from
    )
  ) {
    return true;
  }
  const blob = `${subject} ${body}`.toLowerCase();
  if (isPromoOrSocialCopy(blob)) return true;
  if (/pinterest\.com|\bpin\.it\b/.test(blob) && /\bpin(s|ned|ning)?\b|board/.test(blob)) {
    return true;
  }
  const headers = parsed && parsed.headers;
  let unsub = false;
  if (headers) {
    if (typeof headers.get === 'function') {
      unsub = Boolean(headers.get('list-unsubscribe'));
    } else {
      unsub = Boolean(headers['list-unsubscribe']);
    }
  }
  if (unsub && !looksLikeApplianceRepair(subject, body)) return true;
  return false;
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

function extractName(value) {
  if (!value) return '';
  if (typeof value === 'string') {
    const match = value.match(/^"?([^"<]+)"?\s*</);
    return match ? match[1].trim() : '';
  }
  if (value.value) {
    const first = Array.isArray(value.value) ? value.value[0] : value.value;
    return String((first && first.name) || '').trim();
  }
  return '';
}

function headerValue(parsed, name) {
  const headers = parsed && parsed.headers;
  if (!headers) return '';
  try {
    if (typeof headers.get === 'function') {
      const value = headers.get(name);
      if (value == null) return '';
      if (Array.isArray(value)) return value.map(String).join(' ');
      return String(value);
    }
  } catch (_) {}
  return String(headers[name] || '');
}

function isWebsiteFormMail({ parsed, fromEmail, fromName, subject, body }) {
  const from = String(fromEmail || '')
    .trim()
    .toLowerCase();
  const name = String(fromName || extractName(parsed && parsed.from) || '').toLowerCase();
  const subj = String(subject || '').toLowerCase();
  const text = String(body || '').toLowerCase();
  const mailer = [
    headerValue(parsed, 'x-mailer'),
    headerValue(parsed, 'x-originating-script'),
    headerValue(parsed, 'x-wpforms'),
    headerValue(parsed, 'x-wpcf7'),
  ].join(' ');
  if (
    /wordpress|wpforms|wpcf7|contact form 7|gravity.?form|fluent.?form|ninja.?form|elementor|forminator/i.test(
      mailer
    )
  ) {
    return true;
  }
  if (/^(wordpress|wpadmin|wpforms|wp|webmaster)@/.test(from)) return true;
  if (from.includes('wordpress')) return true;
  if (/\bwordpress\b|\bwpforms\b|\bwpcf7\b/.test(name)) return true;
  if (
    /this e-?mail was sent from (a )?contact form|sent from (your )?(contact form on|wordpress)|powered by (wpforms|contact form 7|elementor)/i.test(
      text
    )
  ) {
    return true;
  }
  if (/contact form on .{2,160} \(https?:\/\//i.test(text)) return true;
  if (
    /\[wordpress\]|new (contact )?form (entry|submission)|website (inquiry|request|form)|форма с сайта|заявка с сайта/.test(
      subj
    )
  ) {
    return true;
  }
  if (
    /fix-appliance\.ca/.test(text) &&
    (/\*name\b|\byour name\b|\bfull name\b/.test(text) &&
      /\*email\b|\be-?mail address\b/.test(text))
  ) {
    return true;
  }
  return false;
}

function wrapAngleId(value) {
  const id = String(value || '').trim();
  if (!id) return '';
  return id.startsWith('<') ? id : `<${id}>`;
}

async function sendCrmEmail({
  to,
  body,
  subject,
  clientId,
  jobId,
  kind,
  inReplyTo,
  references,
  phone,
}) {
  const dest = String(to || '').trim().toLowerCase();
  const text = String(body || '').trim();
  if (!dest.includes('@') || !text) return false;
  const auth = await getGmailAuth();
  if (!auth) {
    console.warn('sendCrmEmail: Gmail is not connected');
    return false;
  }
  const companyName = await getCompanyName();
  const mailSubject = String(subject || '').trim() || companyName;
  const messageId = `<crm-${crypto.randomUUID()}@${String(auth.user).split('@')[1] || 'gmail.com'}>`;
  const headers = { 'X-Fix-CRM': '1' };
  const replyTo = wrapAngleId(inReplyTo);
  const refsHeader = wrapAngleId(references || inReplyTo);
  if (replyTo) headers['In-Reply-To'] = replyTo;
  if (refsHeader) headers.References = refsHeader;
  const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth,
  });
  const info = await transporter.sendMail({
    from: `"${companyName}" <${auth.user}>`,
    to: dest,
    subject: mailSubject,
    text,
    messageId,
    headers,
  });
  const storedId = normalizeMessageId(info.messageId || messageId);
  await refs().messagesRef.add({
    sid: storedId || `email-${Date.now()}`,
    from: auth.user,
    to: dest,
    fromEmail: auth.user,
    toEmail: dest,
    body: text,
    subject: mailSubject,
    direction: 'outbound',
    channel: 'email',
    status: 'sent',
    clientId: clientId || null,
    jobId: jobId || null,
    kind: kind || null,
    phone: phone || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    read: true,
    emailMessageId: storedId,
    crmThread: true,
  });
  return true;
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
    /\b(\d{16})\b/,
    /\b(FX\d{12})\b/i,
    /\b(\d{12,14})\b/,
  ];
  for (const pattern of patterns) {
    const match = blob.match(pattern);
    if (match) return match[1];
  }
  return '';
}

function extractOrderId(text) {
  const blob = String(text || '');
  const amazon = blob.match(/\b(\d{3}-\d{7}-\d{7})\b/);
  if (amazon) return amazon[1];
  const labeled = blob.match(
    /(?:order(?:\s*(?:id|number|#))?|commande|заказ)[:\s#]*([A-Z0-9-]{6,})\b/i
  );
  if (labeled) return labeled[1];
  return '';
}

const PARTS_SUPPLIERS = [
  { id: 'amazon', label: 'Amazon', match: /amazon\.(ca|com)|shipment-tracking@|auto-confirm@amazon|order-update@amazon|marketplace\.amazon/i },
  { id: 'reliable_parts', label: 'Reliable Parts', match: /reliableparts\.(ca|com)|reliable.?parts/i },
  { id: 'partselect', label: 'PartSelect', match: /partselect\.(ca|com)/i },
  { id: 'encompass', label: 'Encompass', match: /encompass\.com|repairclinic\.com|appliancepartspros/i },
  { id: 'marcone', label: 'Marcone', match: /marcone\.com/i },
  { id: 'ebay', label: 'eBay', match: /ebay\.(ca|com)|@ebay\./i },
  { id: 'carrier', label: 'UPS / FedEx / Purolator', match: /ups\.com|fedex\.com|purolator\.com|canadapost|canadapost-postescanada|shipnotify|tracking@/i },
];

function detectSupplier(fromEmail, subject, body) {
  const blob = `${fromEmail} ${subject} ${body}`;
  return PARTS_SUPPLIERS.find((item) => item.match.test(blob)) || null;
}

function isShipmentMail(fromEmail, subject, body) {
  return Boolean(detectSupplier(fromEmail, subject, body));
}

function shipmentStatus(subject, body) {
  const blob = `${subject} ${body}`.toLowerCase();
  if (/delivered|was delivered|has been delivered|left at|доставлено/.test(blob)) {
    return 'delivered';
  }
  if (/out for delivery|arriving today|today's delivery|курьер/.test(blob)) {
    return 'out_for_delivery';
  }
  if (/shipped|has shipped|on the way|отправлен|in transit|dispatched/.test(blob)) {
    return 'shipped';
  }
  return '';
}

module.exports = function createEmailModule({
  notifyMaster,
  setCors,
  handleOptions,
  processInboundAi,
  translateChat,
}) {
  async function sendEmail(req, res) {
    if (handleOptions(req, res)) return;
    setCors(res);

    const payload = parseReqBody(req);
    const to = String(payload.to || '').trim().toLowerCase();
    const body = String(payload.body || '').trim();
    const subject = String(payload.subject || '').trim();
    const clientId = payload.clientId || null;
    const phone = payload.phone || null;
    const bodyRu = String(payload.bodyRu || '').trim();
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
      let sendBody = body;
      let storedRu = bodyRu;
      if (typeof translateChat === 'function' && /[А-Яа-яЁё]/.test(body)) {
        storedRu = storedRu || body;
        sendBody = await translateChat(body, 'en');
      }
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
        text: sendBody || (attachments.length ? ' ' : ''),
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
        body: sendBody,
        bodyRu: storedRu || '',
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

  async function ingestShipmentMail(parsed, uid) {
    const fromEmail = extractAddress(parsed.from);
    const subject = String(parsed.subject || '').trim();
    const text = String(parsed.text || '')
      .trim()
      .slice(0, 12000);
    const htmlFallback = parsed.html
      ? String(parsed.html).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 12000)
      : '';
    const body = `${text} ${htmlFallback}`;
    const supplier = detectSupplier(fromEmail, subject, body);
    if (!supplier) return false;
    const status = shipmentStatus(subject, body);
    if (!status) return false;

    const messageId = normalizeMessageId(parsed.messageId || `ship-${uid}`);
    const eventRef = refs().shipmentEventsRef.doc(messageId.slice(0, 700) || `uid-${uid}`);
    const existingEvent = await eventRef.get();
    if (existingEvent.exists) return true;

    const tracking = extractTrackingNumber(`${subject} ${body}`);
    const orderId = extractOrderId(`${subject} ${body}`);
    const jobsSnap = await refs().jobsRef.get();
    let matched = null;
    for (const doc of jobsSnap.docs) {
      const data = doc.data() || {};
      const jobTrack = String(data.trackingNumber || '').replace(/\s/g, '');
      const jobOrder = String(data.amazonOrderId || data.trackingOrderId || '').trim();
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
      supplier: supplier.id,
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
          trackingCarrier: supplier.id,
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
          ? `${supplier.label}: доставлено`
          : status === 'out_for_delivery'
            ? `${supplier.label}: курьер сегодня`
            : `${supplier.label}: отправлено`;
      await notifyMaster(title, who, {
        type: 'shipment',
        jobId: matched ? matched.id : '',
        trackingStatus: status,
      });
    }
    return true;
  }

  async function findExistingInboundEmail({ messageId, fingerprint, gmailUid }) {
    const col = refs().messagesRef;
    const checks = [];
    if (messageId) {
      checks.push(col.where('emailMessageId', '==', messageId).limit(1).get());
    }
    if (fingerprint) {
      checks.push(col.where('emailFingerprint', '==', fingerprint).limit(1).get());
    }
    const uid = Number(gmailUid || 0);
    if (uid > 0) {
      checks.push(col.where('gmailUid', '==', uid).limit(1).get());
    }
    for (const snap of await Promise.all(checks)) {
      if (snap && !snap.empty) return snap.docs[0];
    }
    return null;
  }

  async function hideDuplicateEmailBells() {
    const snap = await refs().messagesRef.where('channel', '==', 'email').get();
    const groups = new Map();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.direction !== 'inbound') continue;
      if (data.emailOfferDismissed || data.aiSkip) continue;
      const from = String(data.fromEmail || data.from || '')
        .trim()
        .toLowerCase();
      const subject = String(data.subject || '')
        .trim()
        .toLowerCase()
        .replace(/\s+/g, ' ');
      const created =
        data.createdAt && typeof data.createdAt.toDate === 'function'
          ? data.createdAt.toDate()
          : new Date(0);
      const minute = created.toISOString().slice(0, 16);
      const key =
        String(data.emailFingerprint || '').trim() ||
        String(data.emailMessageId || '').trim() ||
        `${from}|${subject}|${minute}`;
      if (!key || key === '||') continue;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({
        id: doc.id,
        ref: doc.ref,
        created,
        data,
      });
    }
    let hidden = 0;
    for (const items of groups.values()) {
      if (items.length < 2) continue;
      items.sort((a, b) => a.created - b.created);
      const keep = items[0];
      for (const extra of items.slice(1)) {
        await extra.ref.set(
          {
            emailOfferPending: false,
            emailBellPending: false,
            emailOfferDismissed: true,
            read: true,
            aiSkip: true,
            aiStatus: 'duplicate',
            duplicateOf: keep.id,
          },
          { merge: true }
        );
        hidden += 1;
      }
    }
    if (hidden) console.log(`syncGmailInbox: hid ${hidden} duplicate email notices`);
    return hidden;
  }

  async function collapseDuplicateEmailJobs() {
    const snap = await refs().jobsRef.get();
    const groups = new Map();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.deletedAt) continue;
      const status = String(data.status || '');
      if (status === 'Отменено' || status === 'Завершено') continue;
      const fromEmail = String(data.sourceEmailFrom || '')
        .trim()
        .toLowerCase();
      const isEmail =
        String(data.source || '').toLowerCase() === 'email' ||
        Boolean(data.sourceEmailId) ||
        fromEmail.includes('@');
      if (!isEmail) continue;
      const created =
        data.createdAt && typeof data.createdAt.toDate === 'function'
          ? data.createdAt.toDate()
          : new Date(0);
      const minute = created.toISOString().slice(0, 16);
      const desc = String(data.description || data.clientName || '')
        .trim()
        .toLowerCase()
        .replace(/\s+/g, ' ')
        .slice(0, 80);
      const key =
        String(data.emailFingerprint || '').trim() ||
        `${fromEmail}|${minute}|${desc}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({
        id: doc.id,
        ref: doc.ref,
        created,
        data,
        fill:
          String(data.description || '').length +
          String(data.clientPhone || '').length +
          (Array.isArray(data.attachments) ? data.attachments.length * 20 : 0),
      });
    }
    let closed = 0;
    for (const items of groups.values()) {
      if (items.length < 2) continue;
      items.sort((a, b) => b.fill - a.fill || a.created - b.created);
      const keep = items[0];
      for (const extra of items.slice(1)) {
        await extra.ref.set(
          {
            status: 'Отменено',
            needsReview: false,
            cloneOfJobId: keep.id,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        closed += 1;
      }
    }
    if (closed) console.log(`syncGmailInbox: closed ${closed} duplicate email jobs`);
    return closed;
  }

  async function acquireInboxLock() {
    const ref = refs().gmailRef;
    const now = Date.now();
    try {
      return await refs().db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const data = snap.exists ? snap.data() || {} : {};
        const until = Number(data.syncLockUntil || 0);
        if (until > now + 2000) return false;
        tx.set(ref, { syncLockUntil: now + 130000 }, { merge: true });
        return true;
      });
    } catch (error) {
      console.warn('syncGmailInbox lock:', error.message);
      return false;
    }
  }

  async function releaseInboxLock() {
    await refs()
      .gmailRef.set({ syncLockUntil: 0 }, { merge: true })
      .catch(() => {});
  }

  async function reclassifyWebsiteMails() {
    const snap = await refs().messagesRef.where('channel', '==', 'email').get();
    let patched = 0;
    let batch = refs().db.batch();
    let inBatch = 0;
    const commit = async () => {
      if (!inBatch) return;
      await batch.commit();
      batch = refs().db.batch();
      inBatch = 0;
    };
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.direction === 'outbound') continue;
      if (data.websiteForm === true && !data.clientId) continue;
      const fromEmail = extractAddress(data.fromEmail || data.from);
      const website = isWebsiteFormMail({
        fromEmail,
        fromName: data.fromName,
        subject: data.subject,
        body: data.body,
      });
      if (!website) continue;
      batch.update(doc.ref, {
        websiteForm: true,
        clientId: admin.firestore.FieldValue.delete(),
      });
      patched += 1;
      inBatch += 1;
      if (inBatch >= 400) await commit();
    }
    await commit();
    if (patched) console.log(`syncGmailInbox: detached ${patched} website form emails`);
  }

  async function ingestParsed(parsed, ourUser, uid, gate) {
    const fromEmail = extractAddress(parsed.from);
    const toEmail = extractAddress(parsed.to) || ourUser.toLowerCase();
    if (!fromEmail.includes('@')) return false;
    if (fromEmail === ourUser.toLowerCase()) return false;

    if (await ingestShipmentMail(parsed, uid)) {
      return true;
    }

    const replyIds = collectHeaderIds(parsed);
    const replyClientId = replyIds.map((id) => gate.messageIds.get(id)).find(Boolean) || null;
    const isCrmReply = gate.sentTo.has(fromEmail) || replyIds.some((id) => gate.messageIds.has(id));
    const subject = String(parsed.subject || '').trim();
    const fromName = extractName(parsed.from);
    const replyToEmail = extractAddress(parsed.replyTo);
    const watched = await readWatchedEmailSenders();
    const isWatched = watched.includes(fromEmail);
    const textPreview = String(parsed.text || '')
      .trim()
      .slice(0, 4000);
    const htmlPreview = parsed.html
      ? String(parsed.html).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 4000)
      : '';
    const looksRepair = looksLikeApplianceRepair(subject, `${textPreview} ${htmlPreview}`);
    const isWebsite = isWebsiteFormMail({
      parsed,
      fromEmail,
      fromName,
      subject,
      body: `${textPreview} ${htmlPreview}`,
    });
    if (!isCrmReply && !isWatched && !isWebsite) {
      console.log(`syncGmailInbox skip non-watched ${fromEmail} uid=${uid || '-'}`);
      return false;
    }

    const created = parsed.date instanceof Date ? parsed.date : new Date();
    const messageId = normalizeMessageId(parsed.messageId || `uid-${uid}`);
    const fingerprint = emailFingerprint(fromEmail, subject, created);
    const existing = await findExistingInboundEmail({
      messageId,
      fingerprint,
      gmailUid: uid,
    });
    if (existing) {
      console.log(
        `syncGmailInbox skip duplicate ${fromEmail} uid=${uid || '-'} id=${existing.id}`
      );
      return false;
    }

    const matched = isWatched || isWebsite ? null : await findClientByEmail(fromEmail);
    const clientId = isWebsite
      ? null
      : (matched && matched.id) || replyClientId || gate.sentTo.get(fromEmail) || null;
    let hasOpenJob = false;
    if (clientId && !isWatched && !isWebsite) {
      try {
        const jobsSnap = await refs().jobsRef.where('clientId', '==', clientId).get();
        hasOpenJob = jobsSnap.docs.some((doc) => {
          const data = doc.data() || {};
          if (data.deletedAt) return false;
          const status = String(data.status || '');
          return status !== 'Завершено' && status !== 'Отменено';
        });
      } catch (error) {
        console.warn('email open job lookup:', error.message);
      }
    }
    const treatIntake = isWatched || isWebsite;
    const text = String(parsed.text || '')
      .trim()
      .slice(0, 8000);
    const htmlFallback = parsed.html
      ? String(parsed.html).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 8000)
      : '';
    const body = text || htmlFallback || '(пустое письмо)';

    const preloadedImages = [];
    for (const att of parsed.attachments || []) {
      const mime = String(att.contentType || '');
      if (!mime.startsWith('image/')) continue;
      const buf = att.content;
      if (!Buffer.isBuffer(buf) || !buf.length || buf.length > 6_000_000) continue;
      preloadedImages.push({
        mime,
        buffer: buf,
        base64: buf.toString('base64'),
      });
      if (preloadedImages.length >= 3) break;
    }

    let confirmHandled = false;
    try {
      const visitSms = require('./visit_sms');
      if (typeof visitSms.tryHandleConfirmReply === 'function') {
        confirmHandled = await visitSms.tryHandleConfirmReply({
          from: fromEmail,
          body,
          clientId,
        });
      }
    } catch (error) {
      console.warn('email visit confirm:', error.message);
    }

    const runAi = !confirmHandled && (isCrmReply || treatIntake || hasOpenJob);
    const payload = {
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
      read: confirmHandled,
      emailMessageId: messageId,
      emailFingerprint: fingerprint,
      gmailUid: uid || null,
      crmThread: true,
      emailIntake: treatIntake && !confirmHandled,
      emailOfferPending: false,
      emailBellPending: !confirmHandled,
      watchedSender: isWatched,
      websiteForm: isWebsite,
      fromName: fromName || '',
      replyToEmail: replyToEmail || '',
      applianceRepair: looksRepair,
      inReplyTo: replyIds[0] || null,
      aiStatus: confirmHandled
        ? 'skipped_confirm'
        : runAi && (body.trim() || preloadedImages.length)
          ? 'processing'
          : 'none',
    };
    const docId = treatIntake ? `em_${fingerprint.slice(0, 32)}` : null;
    let added;
    try {
      if (docId) {
        added = refs().messagesRef.doc(docId);
        await added.create(payload);
      } else {
        added = await refs().messagesRef.add(payload);
      }
    } catch (error) {
      if (isAlreadyExists(error)) {
        console.log(`syncGmailInbox skip race ${fromEmail} ${fingerprint.slice(0, 8)}`);
        return false;
      }
      throw error;
    }

    if (typeof processInboundAi === 'function' && runAi && (body.trim() || preloadedImages.length)) {
      processInboundAi({
        messageId: added.id,
        from: fromEmail,
        body: [subject, body].filter(Boolean).join('\n'),
        twilioMedia: [],
        clientId,
        clientName: matched ? matched.fullName || matched.name || '' : '',
        preloadedImages,
        channel: 'email',
        intake: treatIntake,
        websiteForm: isWebsite,
        emailFingerprint: fingerprint,
      }).catch((error) => console.warn('email inbound AI:', error.message));
    }

    if (typeof translateChat === 'function' && body.trim()) {
      translateChat(body, 'ru')
        .then((ru) => {
          if (ru && ru.trim() && ru.trim() !== body.trim()) {
            return added.update({ bodyRu: ru.trim() });
          }
        })
        .catch((error) => console.warn('email inbound translate:', error.message));
    }

    const isFresh = Date.now() - created.getTime() < 24 * 60 * 60 * 1000;
    if (isFresh && notifyMaster && !confirmHandled) {
      const who = isWebsite
        ? 'веб-сайт'
        : matched
          ? (matched.fullName || matched.name || fromEmail)
          : (fromName || fromEmail);
      const title = treatIntake
        ? (looksRepair ? 'Письмо о ремонте' : `Письмо от ${who}`)
        : `Письмо от ${who}`;
      await notifyMaster(title, subject || body.slice(0, 80), {
        type: looksRepair || treatIntake ? 'email_offer' : 'email',
        source: 'email',
        from: fromEmail,
        to: toEmail,
        messageId: added.id,
      });
      await added.update({ emailNotified: true }).catch(() => {});
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

    const gotLock = await acquireInboxLock();
    if (!gotLock) {
      console.log('syncGmailInbox: already running, skip');
      return;
    }

    try {
      await cleanupLegacyInbox();
      await reclassifyWebsiteMails();
      await hideDuplicateEmailBells();
      await collapseDuplicateEmailJobs();

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
    } finally {
      await releaseInboxLock();
    }
  }

  return { sendEmail, syncGmailInbox };
};

module.exports.sendCrmEmail = sendCrmEmail;
