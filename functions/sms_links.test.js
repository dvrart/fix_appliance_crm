const test = require('node:test');
const assert = require('node:assert');

const smsLinks = require('./sms_links');

const REVIEW_SMS = [
  'The Repair is COMPLETE!',
  '🛠️😊',
  '',
  'Thank you for choosing',
  'Fix-Appliance.CA!',
  'We truly appreciate your business.🙏',
  'If you’re happy with our service, we’d greatly appreciate a quick',
  'Google Review.',
  '⭐️⭐️⭐️⭐️⭐️',
  '',
  'Leave a review here:',
  '📍 https://g.page/r/CePcNwc8SXpUEBE/review',
  '',
  'Thank you for supporting our small business!',
  '❤️',
].join('\n');

test('сокращатели, которые режут операторы', () => {
  assert.equal(smsLinks.isFilteredLink('https://g.page/r/abc/review'), true);
  assert.equal(smsLinks.isFilteredLink('https://maps.app.goo.gl/abc'), true);
  assert.equal(smsLinks.isFilteredLink('https://checkout.stripe.com/c/pay/x'), false);
  assert.equal(
    smsLinks.isFilteredLink('https://us-central1-fix-appliance-crm.cloudfunctions.net/p/x'),
    false
  );
});

test('ссылка на отзыв: своя из настроек или сокращатель', () => {
  assert.equal(smsLinks.hasReviewLink(REVIEW_SMS, ''), true);
  assert.equal(
    smsLinks.hasReviewLink('Leave a review: https://fix-appliance.ca/review', 'https://fix-appliance.ca/review'),
    true
  );
  assert.equal(
    smsLinks.hasReviewLink('Pay here: https://checkout.stripe.com/c/pay/x', 'https://fix-appliance.ca/review'),
    false
  );
});

test('запасной текст: короткий, без ссылки и без промо-блока', () => {
  const fallback = smsLinks.reviewFallbackBody(REVIEW_SMS, {
    company: 'FIX-Appliance CA',
  });
  assert.ok(!/https?:\/\//.test(fallback), fallback);
  assert.ok(fallback.includes('Search FIX-Appliance CA on Google and leave a review.'));
  assert.ok(fallback.includes('Thank you for choosing FIX-Appliance CA.'));
  // Промо-мусор, из-за которого резали и версию без ссылки.
  assert.ok(!fallback.includes('⭐'), fallback);
  assert.ok(!fallback.includes('small business'), fallback);
  assert.ok(fallback.length < 200, 'запасной текст должен быть коротким');
});

test('ссылка в середине строки тоже даёт запасной текст', () => {
  const fallback = smsLinks.reviewFallbackBody(
    'Repair complete! Please leave a review: https://g.page/r/abc/review Thanks!',
    { company: 'FIX-Appliance CA' }
  );
  assert.ok(!/https?:\/\//.test(fallback), fallback);
  assert.ok(fallback.trim().endsWith('Search FIX-Appliance CA on Google and leave a review.'));
});

test('ссылка на отзыв меняется на google-хост, остальные не трогаем', () => {
  const safeUrl = 'https://us-central1-fix-appliance-crm.cloudfunctions.net/p/review';
  const swapped = smsLinks.replaceReviewLink(REVIEW_SMS, {
    reviewUrl: 'https://g.page/r/CePcNwc8SXpUEBE/review',
    safeUrl,
  });
  assert.ok(swapped.includes(safeUrl));
  assert.ok(!swapped.includes('g.page'));
  assert.equal(
    smsLinks.replaceReviewLink('Leave a review: https://fix-appliance.ca/review', {
      reviewUrl: 'https://fix-appliance.ca/review',
      safeUrl,
    }),
    `Leave a review: ${safeUrl}`
  );
  // Ссылку на оплату не трогаем.
  const pay = 'Pay here: https://checkout.stripe.com/c/pay/x';
  assert.equal(
    smsLinks.replaceReviewLink(pay, { reviewUrl: 'https://g.page/r/a/review', safeUrl }),
    pay
  );
  // Без безопасного адреса текст остаётся как был.
  assert.equal(smsLinks.replaceReviewLink(REVIEW_SMS, { safeUrl: '' }), REVIEW_SMS);
});

test('prepareReviewSms не трогает сообщения без ссылки на отзыв', async () => {
  const result = await smsLinks.prepareReviewSms('See you September 23 at 15:00.', {
    reviewUrl: 'https://fix-appliance.ca/review',
  });
  assert.equal(result.body, 'See you September 23 at 15:00.');
  assert.equal(result.fallbackBody, '');
});

test('без ссылки на отзыв запасного текста нет', () => {
  assert.equal(smsLinks.reviewFallbackBody('See you September 23 at 15:00.', {}), '');
  assert.equal(
    smsLinks.reviewFallbackBody('Pay here: https://checkout.stripe.com/c/pay/x', {
      reviewUrl: 'https://fix-appliance.ca/review',
    }),
    ''
  );
});
