const assert = require('node:assert/strict');
const { test } = require('node:test');
const {
  pickQueries,
  parseBingImages,
  parseDuckImages,
  scoreCandidate,
  rankCandidates,
  parseApplianceParts,
} = require('./part_image').internals;

test('запрос строится от номера детали', () => {
  const queries = pickQueries({
    partNumber: 'WPW10730972',
    name: 'Drain Pump',
    brand: 'Whirlpool',
  });
  assert.ok(queries[0].includes('WPW10730972'));
  assert.ok(queries.length <= 3);
});

test('без номера ищем по названию и бренду', () => {
  const queries = pickQueries({ partNumber: '', name: 'Drain Pump', brand: 'Whirlpool' });
  assert.deepEqual(queries, ['Whirlpool Drain Pump appliance part']);
});

test('разбор выдачи Bing достаёт ссылку на файл и на страницу', () => {
  const html =
    '<a class="iusc" m="{&quot;cid&quot;:&quot;1&quot;,&quot;murl&quot;:' +
    '&quot;https://photos.partsdr.com/large/WPW10730972_4.jpg&quot;,&quot;purl&quot;:' +
    '&quot;https://www.partsdr.com/part/WPW10730972&quot;,&quot;t&quot;:' +
    '&quot;Whirlpool Drain Pump&quot;}">x</a>';
  const rows = parseBingImages(html);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].image, 'https://photos.partsdr.com/large/WPW10730972_4.jpg');
  assert.equal(rows[0].page, 'https://www.partsdr.com/part/WPW10730972');
  assert.equal(rows[0].title, 'Whirlpool Drain Pump');
});

test('битый json в выдаче не роняет разбор', () => {
  assert.deepEqual(parseBingImages('<a m="{&quot;murl&quot;:}">x</a>'), []);
});

test('разбор ответа DuckDuckGo', () => {
  const rows = parseDuckImages({
    results: [{ image: 'https://cdn.site/a.jpg', url: 'https://site/a', title: 'Pump' }],
  });
  assert.deepEqual(rows, [
    { image: 'https://cdn.site/a.jpg', page: 'https://site/a', title: 'Pump' },
  ]);
});

test('карточка каталога: один номер — прямая ссылка на большое фото', () => {
  const html =
    '<title>Samsung Dryer Thermostat DC47-00018A</title>' +
    '<div style="background: #fff url(https://applianceparts.homedepot.ca/thumbnail/product/2705759/300/200)"></div>' +
    '<span>DC47-00018A</span>';
  const rows = parseApplianceParts(
    html,
    'https://applianceparts.homedepot.ca/product/21429747',
    'DC47-00018A'
  );
  assert.equal(rows.length, 1);
  assert.equal(
    rows[0].image,
    'https://applianceparts.homedepot.ca/thumbnail/product/2705759/1600/1200/DC47-00018A.jpg'
  );
});

test('карточка чужой детали не выдаётся за нашу', () => {
  const html =
    '<title>Other part</title>' +
    '<div style="url(https://applianceparts.homedepot.ca/thumbnail/product/111/300/200)"></div>';
  const rows = parseApplianceParts(
    html,
    'https://applianceparts.homedepot.ca/product/999',
    'DC47-00018A'
  );
  assert.deepEqual(rows, []);
});

test('в списке каталога берём только плитку с нашим номером', () => {
  const html =
    '<script>var product0 = new Array();product0.partNumber = "SMG DC47-00018A";' +
    'product0.url = "/product/21429747";</script>' +
    '<script>var product1 = new Array();product1.partNumber = "SMG DC47-00019B";' +
    'product1.url = "/product/21459961";</script>' +
    '<a href="https://applianceparts.homedepot.ca/product/21429747" class="product-image" ' +
    'style="background: #fff url(https://applianceparts.homedepot.ca/thumbnail/product/2705759/300/200)"></a>' +
    '<a href="https://applianceparts.homedepot.ca/product/21459961" class="product-image" ' +
    'style="background: #fff url(https://applianceparts.homedepot.ca/thumbnail/product/3297951/300/200)"></a>';
  const rows = parseApplianceParts(
    html,
    'https://applianceparts.homedepot.ca/search?q=DC47-00018A',
    'DC47-00018A'
  );
  assert.equal(rows.length, 1);
  assert.ok(rows[0].image.includes('/2705759/1600/1200/'));
  assert.equal(rows[0].page, 'https://applianceparts.homedepot.ca/product/21429747');
});

test('логотипы, svg и Pinterest выбрасываем', () => {
  const opts = { part: 'W10311524', name: 'Air Filter' };
  assert.ok(scoreCandidate({ image: 'https://shop.com/logo.png' }, opts) < 0);
  assert.ok(scoreCandidate({ image: 'https://shop.com/part.svg' }, opts) < 0);
  assert.ok(scoreCandidate({ image: 'https://i.pinimg.com/part.jpg' }, opts) < 0);
});

test('номер детали в ссылке важнее красивого магазина', () => {
  const opts = { part: 'W10311524', name: 'Air Filter' };
  const withPart = scoreCandidate(
    { image: 'https://cdn.unknownshop.io/W10311524.jpg', page: '', title: '' },
    opts
  );
  const withoutPart = scoreCandidate(
    { image: 'https://images.homedepot.ca/other.jpg', page: '', title: '' },
    opts
  );
  assert.ok(withPart > withoutPart);
});

test('повторы и отклонённые ссылки не возвращаются', () => {
  const rows = [
    { image: 'https://a.partselect.com/W10311524.jpg', page: '', title: '' },
    { image: 'https://a.partselect.com/W10311524.jpg', page: '', title: '' },
    { image: 'https://b.partsdr.com/W10311524.jpg', page: '', title: '' },
  ];
  const ranked = rankCandidates(rows, {
    part: 'W10311524',
    name: 'Air Filter',
    skip: ['https://b.partsdr.com/W10311524.jpg'],
  });
  assert.equal(ranked.length, 1);
  assert.equal(ranked[0].image, 'https://a.partselect.com/W10311524.jpg');
});
