/**
 * Одна шапка SMS — только поле settings/documents.smsHeader.
 * Название компании и «FIX ApplianceCA» в SMS не ставятся.
 */

function compactHeaderKey(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[\s.\-_]/g, '');
}

function isBannedSmsHeader(value, companyName) {
  const raw = String(value || '').trim();
  if (!raw) return false;
  if (raw.includes('.')) return false;
  const compact = compactHeaderKey(raw);
  if (compact === 'fixapplianceca' || compact === 'fixappliance') return true;
  const company = String(companyName || '').trim();
  if (company && !company.includes('.') && compact === compactHeaderKey(company)) {
    return true;
  }
  return false;
}

function sanitizeSmsHeader(header, companyName) {
  const h = String(header || '').trim();
  if (!h || isBannedSmsHeader(h, companyName)) return '';
  return h;
}

function isKnownHeaderLine(line, extras) {
  const raw = String(line || '').trim();
  if (!raw) return false;
  if (isBannedSmsHeader(raw)) return true;
  const lower = raw.toLowerCase();
  for (const extra of extras || []) {
    const h = String(extra || '').trim();
    if (h && lower === h.toLowerCase()) return true;
  }
  return false;
}

function stripSmsHeaders(text, extraHeaders) {
  const lines = String(text || '').replace(/^\uFEFF/, '').split(/\r?\n/);
  let i = 0;
  while (i < lines.length) {
    if (!lines[i].trim()) {
      i += 1;
      continue;
    }
    if (!isKnownHeaderLine(lines[i], extraHeaders)) break;
    i += 1;
  }
  while (i < lines.length && !lines[i].trim()) i += 1;
  return lines.slice(i).join('\n').trim();
}

function withSmsHeader(body, header, companyName) {
  const h = sanitizeSmsHeader(header, companyName);
  const stripped = stripSmsHeaders(body, [h, header]);
  if (!h) return stripped;
  if (!stripped) return h;
  const first = stripped.split(/\r?\n/)[0].trim();
  if (first.toLowerCase() === h.toLowerCase()) return stripped;
  return `${h}\n\n${stripped}`;
}

module.exports = {
  withSmsHeader,
  sanitizeSmsHeader,
  stripSmsHeaders,
  isBannedSmsHeader,
};
