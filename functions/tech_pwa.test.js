const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const techDir = path.resolve(__dirname, '..', 'hosting', 'public', 'tech');

test('iPhone PWA files, manifest, icons and service guide are present', () => {
  const required = [
    'index.html',
    'manifest.json',
    'sw.js',
    'styles.css',
    'payout.js',
    'app.js',
    'service_guide.json',
    path.join('icons', 'favicon.png'),
    path.join('icons', 'apple-touch-icon.png'),
    path.join('icons', 'icon-192.png'),
    path.join('icons', 'icon-512.png'),
  ];
  for (const rel of required) {
    const full = path.join(techDir, rel);
    assert.ok(fs.existsSync(full), `missing ${rel}`);
    assert.ok(fs.statSync(full).size > 0, `empty ${rel}`);
  }

  const manifest = JSON.parse(fs.readFileSync(path.join(techDir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.start_url, '/tech/');

  const html = fs.readFileSync(path.join(techDir, 'index.html'), 'utf8');
  assert.match(html, /apple-mobile-web-app-capable/);
  assert.match(html, /apple-touch-icon/);

  const guide = JSON.parse(fs.readFileSync(path.join(techDir, 'service_guide.json'), 'utf8'));
  assert.ok(Array.isArray(guide.records) && guide.records.length >= 80);
});

test('PWA payout calculator matches technician net profit and office balance rules', async () => {
  const payoutMod = await import(pathToFileURL(path.join(techDir, 'payout.js')).href);

  const jobWithVerifiedTechPart = {
    id: 'j1',
    documents: [
      {
        type: 'Invoice',
        number: 'INV-1',
        taxRate: 0.13,
        items: [
          { name: 'Repair labour', type: 'Service', qty: 1, price: 200 },
          {
            name: 'Pump',
            type: 'Part',
            partSource: 'tech',
            qty: 1,
            price: 100,
            costPrice: 40,
            receiptUrl: 'https://example.com/r.jpg',
          },
        ],
        payments: [{ amount: 339, method: 'e-Transfer' }],
      },
    ],
  };

  // Subtotal = 300, HST = 39 (excluded from split), verified tech part = 40 -> net = 260
  // 60% tech = 156, 40% owner = 104, dueToOwner = 104
  const r1 = payoutMod.calcJobPayout(jobWithVerifiedTechPart, 60);
  assert.equal(Math.round(r1.revenueExTax * 100), 30000);
  assert.equal(Math.round(r1.netProfit * 100), 26000);
  assert.equal(Math.round(r1.techProfit * 100), 15600);
  assert.equal(Math.round(r1.dueToOwner * 100), 10400);

  // Without receipt photo, tech part cost is NOT deducted; office part cost IS returned to owner
  const jobMixed = {
    id: 'j2',
    documents: [
      {
        type: 'Invoice',
        number: 'INV-2',
        taxRate: 0,
        items: [
          { name: 'Labour', type: 'Service', qty: 1, price: 200 },
          { name: 'Unverified part', type: 'Part', partSource: 'tech', qty: 1, price: 80, costPrice: 30 },
          { name: 'Office board', type: 'Part', partSource: 'owner', qty: 1, price: 120, costPrice: 50 },
        ],
        payments: [{ amount: 400, method: 'Cash' }],
      },
    ],
  };
  // Revenue = 400, recognized parts = 50 (only office), net = 350, 50/50 -> 175 each, dueToOwner = 50 + 175 = 225
  const r2 = payoutMod.calcJobPayout(jobMixed, 50);
  assert.equal(Math.round(r2.techUnverifiedPartsCost * 100), 3000);
  assert.equal(Math.round(r2.netProfit * 100), 35000);
  assert.equal(Math.round(r2.dueToOwner * 100), 22500);

  const summary = payoutMod.calcBalanceSummary(
    { uid: 't1', profitSharePercent: 50 },
    [jobMixed],
    [{ id: 's1', amount: 100 }]
  );
  assert.equal(Math.round(summary.balanceDueToOwner * 100), 12500);
});
