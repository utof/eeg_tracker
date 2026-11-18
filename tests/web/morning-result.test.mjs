// The morning result as shown on morning.html and sleep.html (scripts/web/morning-result.js). Run from the repo root:
// node --test tests/web/morning-result.test.mjs   (no packages needed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { morningRows, morningHtml } from '../../scripts/web/morning-result.js';

const result = (extra = {}) => ({
  start: '2026-11-18T07:00:00+03:00', date: '2026-11-18',
  back: { alpha_ec_uv2: 31.31, ec_rise: 2.6, iaf_hz: 9.62, aperiodic_slope_ec: -1.54, clean_share: 0.974 },
  ratings: { kss: 8, mood: 4, tension: 2 }, ...extra,
});
const compared = (earlier, where = 'within') => ['back.alpha_ec_uv2', 'back.ec_rise', 'back.iaf_hz',
  'back.aperiodic_slope_ec', 'back.clean_share', 'ratings.kss', 'ratings.mood', 'ratings.tension'].map((key) => ({
  key, earlier, where, comparison: earlier ? `your last ${earlier}: median 1, range 0-2: ${where} your range` : '',
}));

test('values in plain words, with the comparison from morning_check.py', () => {
  const rows = morningRows(result({ compared: compared(6, 'below') }));
  assert.deepEqual(rows.map(([label, text]) => [label, text]), [
    ['Alpha strength, eyes closed', '31.3 µV²'], ['Eyes-closed rise (closed / open)', '2.6×'], ['Alpha speed', '9.62 Hz'],
    ['1/f slope, eyes closed', '-1.54'], ['Clean data', '97 %'], ['Sleepiness', '8 of 9'], ['Mood', '4 of 5'],
    ['Tension', '2 of 5']]);
  assert.equal(rows[0][2], 'your last 6: median 1, range 0-2: below your range');
  assert.equal(rows[0][3], 'below');
});

test('missing values and results made before the comparison existed', () => {
  const r = result({ back: { alpha_ec_uv2: null, ec_rise: null, iaf_hz: null, aperiodic_slope_ec: null, clean_share: 0.2 },
    ratings: null });
  const rows = morningRows(r);
  assert.equal(rows[0][1], 'not enough clean data');
  assert.equal(rows[5][1], 'not rated');
  assert.ok(rows.every(([, , cmp]) => cmp === ''));
  assert.equal(morningHtml(null), '');
  assert.equal(morningHtml({ start: 'x' }), '');
});

test('first check-in says so; the page text is escaped', () => {
  const first = morningHtml(result({ compared: compared(0) }));
  assert.match(first, /First check-in: nothing to compare with yet/);
  assert.match(first, /<h2>Morning check-in, Wed 18 Nov 07:00<\/h2>/);
  assert.doesNotMatch(morningHtml(result({ compared: compared(3) })), /First check-in/);
  const evil = compared(3); evil[0].comparison = '<img src=x onerror=alert(1)>'; evil[0].where = '"><b>';
  const html = morningHtml(result({ compared: evil, start: '2026-11-18T<b>x' }));
  assert.doesNotMatch(html, /<img|<b>x|"><b>/);
  assert.doesNotMatch(morningHtml(result(), { title: false }), /<h2>/);
});
