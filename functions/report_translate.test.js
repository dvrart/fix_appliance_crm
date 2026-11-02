// Отчёт мастера для паспорта: русский уходит на перевод, английский
// возвращается как есть, ответ модели без английского текста отбрасывается.
const assert = require('node:assert/strict');
const { test } = require('node:test');

process.env.OPENAI_API_KEY = '';
process.env.GEMINI_API_KEY = '';
const report = require('./report_translate');

test('an English report needs no translation and an empty one stays empty', async () => {
  assert.equal(
    await report.translateServiceReport('Replaced the evaporator fan motor'),
    'Replaced the evaporator fan motor',
  );
  assert.equal(await report.translateServiceReport('   '), '');
});

test('without model keys a Russian report is not replaced by a guess', async () => {
  assert.equal(await report.translateServiceReport('Заменил вентилятор испарителя'), '');
});
