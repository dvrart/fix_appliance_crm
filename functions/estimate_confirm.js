/**
 * Клиент открывает ссылку из SMS и подтверждает смету / ремонт.
 */
const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { notifyMaster } = require('./notify');

const { getCompanyId } = require('./tenant');

const COMPANY_ID = getCompanyId();

function jobsRef() {
  return admin.firestore().collection('companies').doc(COMPANY_ID).collection('jobs');
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function money(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return '0.00';
  return v.toFixed(2);
}

function page({ title, body, ok }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>${escapeHtml(title)}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif; background:#f4f6fb; margin:0; color:#1a1a1a; }
    .wrap { max-width: 480px; margin: 0 auto; padding: 24px 16px 40px; }
    .card { background:#fff; border-radius:16px; padding:20px; box-shadow:0 8px 24px rgba(0,0,0,.08); }
    h1 { font-size: 22px; margin: 0 0 8px; }
    p { line-height: 1.45; }
    .row { display:flex; justify-content:space-between; gap:12px; padding:8px 0; border-bottom:1px solid #eef2f7; }
    .total { font-size:20px; font-weight:800; margin-top:12px; }
    button, .btn { display:block; width:100%; border:0; border-radius:12px; padding:14px 16px; font-size:16px; font-weight:700; background:#14557F; color:#fff; }
    .ok { background:#16a34a; }
    .muted { color:#64748b; font-size:13px; }
  </style>
</head>
<body>
  <div class="wrap"><div class="card">${body}</div></div>
</body>
</html>`;
}

function findDocument(job, index, token) {
  const documents = Array.isArray(job.documents) ? job.documents : [];
  const i = Number(index);
  if (Number.isInteger(i) && i >= 0 && i < documents.length) {
    const doc = documents[i] || null;
    if (doc && String(doc.confirmToken || '') === token) {
      return { documents, index: i, doc };
    }
  }
  const found = documents.findIndex(
    (item) => item && String(item.confirmToken || '') === token
  );
  if (found >= 0) return { documents, index: found, doc: documents[found] };
  return { documents, index: -1, doc: null };
}

async function loadJob(jobId) {
  const snap = await jobsRef().doc(jobId).get();
  if (!snap.exists) return null;
  return { id: snap.id, ...(snap.data() || {}) };
}

exports.estimateConfirm = functions.https.onRequest(async (req, res) => {
    const jobId = String(req.query.jobId || req.body.jobId || '').trim();
    const docIndex = String(req.query.doc || req.body.doc || '').trim();
    const token = String(req.query.token || req.body.token || '').trim();
    if (!jobId || !token) {
      res.status(400).send(page({ title: 'Estimate', body: '<h1>Link is not valid</h1><p>Ask your technician to send the estimate again.</p>' }));
      return;
    }

    const job = await loadJob(jobId);
    if (!job) {
      res.status(404).send(page({ title: 'Estimate', body: '<h1>Estimate not found</h1>' }));
      return;
    }
    const found = findDocument(job, docIndex, token);
    const doc = found.doc;
    if (!doc || String(doc.confirmToken || '') !== token) {
      res.status(403).send(page({ title: 'Estimate', body: '<h1>This link has expired</h1><p>Ask your technician to send a new estimate link.</p>' }));
      return;
    }

    const items = Array.isArray(doc.items) ? doc.items : [];
    const rows = items
      .map((item) => {
        const name = escapeHtml(item.name || 'Item');
        const qty = Number(item.qty || 1);
        const price = Number(item.price || 0);
        return `<div class="row"><span>${name} × ${qty}</span><strong>$${(qty * price).toFixed(2)}</strong></div>`;
      })
      .join('');
    const total = items.reduce((sum, item) => sum + Number(item.qty || 1) * Number(item.price || 0), 0);
    const taxRate = Number(doc.taxRate || 0);
    const tax = total * (taxRate / 100);
    const grand = total + tax;
    const name = escapeHtml(job.clientName || 'there');
    const already = String(doc.estimateStatus || '') === 'approved';

    if (req.method === 'POST' && !already) {
      const documents = found.documents;
      documents[found.index] = {
        ...doc,
        estimateStatus: 'approved',
        confirmedAt: new Date().toISOString(),
      };
      await jobsRef().doc(jobId).update({
        documents,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      try {
        await notifyMaster(
          'Клиент подтвердил ремонт',
          `${job.clientName || 'Клиент'} — смета $${money(grand)}`,
          { type: 'estimate_confirm', jobId, from: job.clientPhone || '' }
        );
      } catch (error) {
        console.warn('estimateConfirm notify:', error.message);
      }
      res.send(page({
        title: 'Confirmed',
        ok: true,
        body: `<h1>Thank you</h1><p>You confirmed the repair. Our technician will contact you.</p>`,
      }));
      return;
    }

    if (already) {
      res.send(page({
        title: 'Confirmed',
        ok: true,
        body: `<h1>Already confirmed</h1><p>Hi ${name}, this estimate is already approved.</p><div class="total">$${money(grand)}</div>`,
      }));
      return;
    }

    res.send(page({
      title: 'Confirm repair',
      body: `
        <h1>Fix Appliance</h1>
        <p>Hi ${name}, please review this estimate and confirm the repair.</p>
        ${rows || '<p class="muted">No line items</p>'}
        <div class="row"><span>Subtotal</span><span>$${money(total)}</span></div>
        ${taxRate ? `<div class="row"><span>Tax</span><span>$${money(tax)}</span></div>` : ''}
        <div class="total">Total $${money(grand)}</div>
        <form method="POST" action="?jobId=${encodeURIComponent(jobId)}&doc=${encodeURIComponent(docIndex)}&token=${encodeURIComponent(token)}" style="margin-top:20px">
          <button type="submit">I agree — confirm repair</button>
        </form>
        <p class="muted">This does not charge your card. It only confirms the work.</p>
      `,
    }));
  }
);
