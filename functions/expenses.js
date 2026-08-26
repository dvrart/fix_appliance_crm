const functions = require('firebase-functions');

const CATEGORIES = {
  vehicle: { gifi: '9281' },
  insurance: { gifi: '8690' },
  phone: { gifi: '9225' },
  fees: { gifi: '8715' },
  accounting: { gifi: '8862' },
  advertising: { gifi: '8521' },
  rent: { gifi: '8911' },
  wages: { gifi: '9060' },
  tools: { gifi: '9270' },
  supplies: { gifi: '9200' },
  meals: { gifi: '8523' },
  parts: { gifi: '8320' },
  other: { gifi: '9270' },
};

function extractJsonObject(text) {
  const start = String(text || '').indexOf('{');
  const end = String(text || '').lastIndexOf('}');
  if (start === -1 || end === -1) throw new Error('Нет JSON в ответе ИИ');
  return JSON.parse(String(text).slice(start, end + 1));
}

function normalizeCategory(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (CATEGORIES[raw]) return raw;
  if (/gas|fuel|petrol|diesel|parking|vehicle|car |auto |бензин|машин|топлив/.test(raw)) {
    return 'vehicle';
  }
  if (/insur|страхов/.test(raw)) return 'insurance';
  if (/phone|internet|rogers|bell|telus|телефон|интернет/.test(raw)) return 'phone';
  if (/stripe|bank fee|interac|комисс|банк/.test(raw)) return 'fees';
  if (/account|bookkeep|ufile|turbotax|бухгалтер/.test(raw)) return 'accounting';
  if (/adver|google ads|facebook|реклам/.test(raw)) return 'advertising';
  if (/rent|аренд/.test(raw)) return 'rent';
  if (/wage|payroll|salary|зарплат/.test(raw)) return 'wages';
  if (/tool|instrument|meter|drill|инструмент/.test(raw)) return 'tools';
  if (/part|compressor|pump|запчаст/.test(raw)) return 'parts';
  if (/meal|restaurant|coffee|еда|кафе/.test(raw)) return 'meals';
  if (/supply|cleaner|расход/.test(raw)) return 'supplies';
  return 'other';
}

module.exports = function createExpenseHandlers({
  setCors,
  handleOptions,
  generateContentWithModelFallback,
}) {
  async function parseExpenseReceipt(req, res) {
    setCors(res);
    if (handleOptions(req, res)) return;
    if (req.method !== 'POST') {
      res.status(405).json({ success: false, error: 'POST only' });
      return;
    }
    try {
      const imageBase64 = String((req.body && req.body.imageBase64) || '')
        .replace(/^data:[^;]+;base64,/, '')
        .trim();
      if (!imageBase64) {
        res.status(400).json({ success: false, error: 'Нет фото или PDF чека' });
        return;
      }
      const mime = String((req.body && req.body.mime) || 'image/jpeg').split(';')[0];
      if (!mime.startsWith('image/') && mime !== 'application/pdf') {
        res.status(400).json({ success: false, error: 'Нужно фото или PDF' });
        return;
      }
      const prompt = `You read Canadian business receipts for an appliance-repair corporation in Ontario (HST 13%). The attachment is a photo or a PDF of the receipt.
Extract one JSON object, no markdown.

Rules:
- Amounts in CAD. HST is tax, not an expense.
- amountExHst = subtotal before HST. total = amount paid. hst = HST/GST on the receipt.
- If only a total is printed, split Ontario HST: hst = total * 13/113, amountExHst = total - hst.
- category MUST be one of: vehicle, insurance, phone, fees, accounting, advertising, rent, wages, tools, supplies, meals, parts, other
- vehicle = gasoline, diesel, parking, oil change, car wash, vehicle repair
- insurance = insurance premium
- phone = phone/internet bill
- fees = Stripe, bank, Interac fees
- accounting = accountant, UFile, TurboTax
- advertising = ads, flyers
- rent = shop/storage rent
- wages = payroll
- tools = tools, meters, instruments, equipment for the technician
- parts = appliance spare parts for jobs (compressor, pump, not a technician tool)
- meals = restaurant / coffee (business)
- supplies = shop supplies, cleaners
- capitalLikely = true only if this is equipment/tools likely over CAD 500 that should go to CCA, not an expense
- date = YYYY-MM-DD if printed, else null
- confidence 0..1

{
  "vendor": "",
  "date": "2026-01-15",
  "total": 0,
  "hst": 0,
  "amountExHst": 0,
  "category": "vehicle",
  "label": "Gasoline",
  "note": "",
  "capitalLikely": false,
  "confidence": 0.8
}`;

      const result = await generateContentWithModelFallback([
        { text: prompt },
        { inlineData: { mimeType: mime || 'image/jpeg', data: imageBase64 } },
      ]);
      const parsed = extractJsonObject(result.response.text() || '');
      const category = normalizeCategory(parsed.category || parsed.label);
      const total = Number(parsed.total) || 0;
      let hst = Number(parsed.hst) || 0;
      let net = Number(parsed.amountExHst) || 0;
      if (total > 0 && net <= 0) {
        if (hst <= 0) hst = Math.round(((total * 13) / 113) * 100) / 100;
        net = Math.round((total - hst) * 100) / 100;
      }
      res.json({
        success: true,
        expense: {
          vendor: String(parsed.vendor || '').trim(),
          date: parsed.date || null,
          total,
          hst,
          amountExHst: net,
          category,
          gifi: CATEGORIES[category].gifi,
          label: String(parsed.label || '').trim(),
          note: String(parsed.note || '').trim(),
          capitalLikely: parsed.capitalLikely === true,
          confidence: Number(parsed.confidence) || 0,
        },
      });
    } catch (error) {
      console.warn('parseExpenseReceipt:', error.message);
      res.status(500).json({ success: false, error: error.message || 'parse failed' });
    }
  }

  return {
    parseExpenseReceipt: functions.https.onRequest(
      { timeoutSeconds: 90, memory: '512MiB', invoker: 'public' },
      parseExpenseReceipt
    ),
  };
};
