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
  if (h.toLowerCase() === 'fixappliance.ca') return 'fix-appliance.ca';
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

function protectSmsTokens(text) {
  const tokens = [];
  const stash = (match) => {
    const key = `\uE000${tokens.length}\uE001`;
    tokens.push(match);
    return key;
  };
  const stashUrl = (match) => {
    let url = match;
    let extra = '';
    while (/[.,!?;:]$/.test(url)) {
      extra = url.slice(-1) + extra;
      url = url.slice(0, -1);
    }
    return stash(url) + extra;
  };
  const protectedText = String(text || '')
    .replace(/https?:\/\/[^\s]+/gi, stashUrl)
    .replace(/\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g, stash)
    .replace(/\b(?:e\.g|i\.e)/gi, stash)
    .replace(/\b[ap]\.m/gi, stash)
    .replace(/\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|Apt|Inc|Ltd|Co|vs|etc|No)\./gi, stash)
    .replace(/\b\d{3}\.\d{3}\.\d{4}\b/g, stash)
    .replace(/(?<![A-Za-z])\d+[.,]\d+/g, stash)
    .replace(/\b(?:www\.)?[\w-]+(?:\.[\w-]+)+(?:\/[^\s]*)?/gi, stash);
  return { text: protectedText, tokens };
}

function restoreSmsTokens(text, tokens) {
  return String(text || '').replace(/\uE000(\d+)\uE001/g, (_, idx) => {
    return tokens[Number(idx)] || '';
  });
}

function splitSmsSentences(line) {
  const { text, tokens } = protectSmsTokens(line);
  const parts = [];
  let buf = '';
  for (let i = 0; i < text.length; i += 1) {
    buf += text[i];
    if (!'.!?…'.includes(text[i])) continue;
    while (i + 1 < text.length && '.!?…'.includes(text[i + 1])) {
      i += 1;
      buf += text[i];
    }
    const next = text[i + 1];
    if (next !== undefined && !/\s/.test(next)) continue;
    parts.push(restoreSmsTokens(buf.trim(), tokens));
    buf = '';
    while (i + 1 < text.length && /\s/.test(text[i + 1])) i += 1;
  }
  if (buf.trim()) parts.push(restoreSmsTokens(buf.trim(), tokens));
  return parts.filter(Boolean);
}

function formatSmsSentences(text) {
  const raw = String(text || '')
    .replace(/^\uFEFF/, '')
    .replace(/\r\n/g, '\n');
  if (!raw.trim()) return '';
  const out = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) {
      if (out.length && out[out.length - 1] !== '') out.push('');
      continue;
    }
    out.push(...splitSmsSentences(line.trim()));
  }
  while (out.length && out[out.length - 1] === '') out.pop();
  return out.join('\n');
}

function withSmsHeader(body, header, companyName) {
  const h = sanitizeSmsHeader(header, companyName);
  const stripped = stripSmsHeaders(body, [h, header]);
  const formatted = formatSmsSentences(stripped);
  if (!h) return formatted;
  if (!formatted) return h;
  const first = formatted.split(/\r?\n/)[0].trim();
  if (first.toLowerCase() === h.toLowerCase()) {
    const rest = formatSmsSentences(formatted.split(/\r?\n/).slice(1).join('\n'));
    return rest ? `${h}\n\n${rest}` : h;
  }
  return `${h}\n\n${formatted}`;
}

module.exports = {
  withSmsHeader,
  sanitizeSmsHeader,
  stripSmsHeaders,
  isBannedSmsHeader,
  formatSmsSentences,
};
