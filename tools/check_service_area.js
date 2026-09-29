#!/usr/bin/env node
/**
 * Что секретарь знает про зону обслуживания.
 *
 * Подпись зоны (`serviceAreaLabel`) собирается в приложении по центру и углам
 * нарисованного полигона, поэтому городов в ней почти нет — и модель отказывала
 * Тилсонбургу, который внутри зоны. Здесь видно и подпись, и результат проверки
 * «точка внутри полигона» для всех городов из `SERVICE_TOWNS`, плюс готовая
 * строка, которая уходит в промпт.
 *
 *   node tools/check_service_area.js                 города из SERVICE_TOWNS
 *   node tools/check_service_area.js 42.86 -80.73    ещё и произвольная точка
 */
const path = require('path');
const { accessToken } = require('./read_logs.js');
const voiceFacts = require(path.join(__dirname, '..', 'functions', 'voice_facts.js'));

const PROJECT = 'fix-appliance-crm';
const COMPANY = 'fix_appliance_ca';

const SERVICE_TOWNS = voiceFacts.SERVICE_TOWNS;

const num = (v) => (v ? Number(v.doubleValue ?? v.integerValue) : NaN);

async function main() {
  const token = await accessToken();
  const url =
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)` +
    `/documents/companies/${COMPANY}/settings/config`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const body = await res.json();
  if (body.error) throw new Error(JSON.stringify(body.error).slice(0, 250));
  const f = body.fields || {};
  const label = (f.serviceAreaLabel || {}).stringValue || '';
  const polygon = (((f.servicePolygon || {}).arrayValue || {}).values || []).map((v) => ({
    lat: num(v.mapValue.fields.lat),
    lng: num(v.mapValue.fields.lng),
  }));

  console.log(`подпись зоны: ${label || '(пусто)'}`);
  console.log(`точек полигона: ${polygon.length}\n`);
  for (const town of SERVICE_TOWNS) {
    const inside = voiceFacts.pointInPolygon(town.lat, town.lng, polygon);
    console.log(`${town.name.padEnd(13)} ${inside ? 'внутри' : 'СНАРУЖИ'}`);
  }

  const extraLat = Number(process.argv[2]);
  const extraLng = Number(process.argv[3]);
  if (Number.isFinite(extraLat) && Number.isFinite(extraLng)) {
    const inside = voiceFacts.pointInPolygon(extraLat, extraLng, polygon);
    console.log(`\n${extraLat}, ${extraLng} — ${inside ? 'внутри' : 'СНАРУЖИ'}`);
  }

  const towns = voiceFacts.townsInsideArea(SERVICE_TOWNS, polygon);
  console.log(`\nв промпт уходит:\n${voiceFacts.serviceAreaSpeech(label, towns)}`);
}

main().catch((e) => {
  console.error('сбой: ' + e.message);
  process.exitCode = 1;
});
