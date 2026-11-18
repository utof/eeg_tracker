// The evidence notes behind the pages' "i" buttons (docs/evidence/*.md -> scripts/web/evidence.js). Run from the
// repo root:  node --test tests/web/evidence.test.mjs   (no packages needed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { EVIDENCE } from '../../scripts/web/evidence.js';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const GRADES = ['strong', 'some', 'weak', 'none'];
const PAGES = ['scripts/live_page.html', 'scripts/web/eyes.html', 'scripts/web/beats.html', 'scripts/web/sound.html',
  'scripts/web/morning.html', 'scripts/web/sleep.html'];
const REQUIRED = ['sleep-recording', 'sleep-scoring', 'morning-check-in', 'eyes-test', 'brain-sound', 'sound-for-states',
  'break-hints', 'meditation-feedback', 'alpha-theta', 'replay-check', 'dream-catcher', 'nap-coach', 'trends', 'jaw-and-blinks',
  'noise-cleaning', 'helmet'];
const SECTIONS = ['What it does', 'Evidence for this ', 'What the research says', 'Where the data does not support it',
  'How the app uses this', 'Sources', 'Libraries and models'];
const hrefs = (html) => [...html.matchAll(/<a href="([^"]*)"/g)].map((m) => m[1]);
const pageIds = (src) => [...src.matchAll(/addInfo\([^;]*?,\s*'([a-z0-9-]+)'\)/g)].map((m) => m[1]);

test('every page has an "i" button, and every id it uses has a note', () => {
  for (const page of PAGES) {
    const ids = pageIds(read(page));
    assert.ok(ids.length > 0, `${page} has no addInfo call`);
    for (const id of ids) assert.ok(EVIDENCE[id], `${page} uses "${id}", which has no note`);
  }
});

test('the features listed in the roadmap all have a note', () => {
  for (const id of REQUIRED) assert.ok(EVIDENCE[id], `missing note "${id}"`);
});

test('every note has a title, a grade, the standard sections, a source link and a checked date', () => {
  for (const [id, n] of Object.entries(EVIDENCE)) {
    assert.ok(n.title.length > 3, id);
    assert.ok(GRADES.includes(n.grade), `${id}: grade ${n.grade}`);
    assert.match(n.html, new RegExp(`<h3>Evidence for this (headband|helmet): ${n.grade}</h3>`), id);
    let at = -1;
    for (const s of SECTIONS) {
      const i = n.html.indexOf(`<h3>${s}`);
      assert.ok(i > at, `${id}: section "${s}" missing or out of order`);
      at = i;
    }
    const sources = n.html.slice(n.html.indexOf('<h3>Sources</h3>'), n.html.indexOf('<h3>Libraries and models</h3>'));
    assert.ok(hrefs(sources).some((h) => /^https?:\/\//.test(h)), `${id}: no source link`);
    assert.match(n.html, /<p>Checked: \d{4}-\d{2}-\d{2}<\/p>$/, id);
  }
});

test('links are public web addresses that open safely in a new tab', () => {
  for (const [id, n] of Object.entries(EVIDENCE)) {
    for (const h of hrefs(n.html)) {
      assert.match(h, /^https?:\/\/[^/]+/, `${id}: ${h}`);
      assert.doesNotMatch(h, /^file:|localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]/i, `${id}: ${h}`);
    }
    for (const a of n.html.match(/<a [^>]*>/g) ?? []) {
      assert.match(a, /target="_blank"/, `${id}: ${a}`);
      assert.match(a, /rel="[^"]*noopener/, `${id}: ${a}`);
    }
  }
});

test('the html uses only the small safe tag set, with no scripts or event handlers', () => {
  const allowed = new Set(['h3', 'h4', 'p', 'ul', 'li', 'strong', 'code', 'a']);
  for (const [id, n] of Object.entries(EVIDENCE)) {
    for (const [, tag] of n.html.matchAll(/<\/?([a-zA-Z0-9]+)/g)) assert.ok(allowed.has(tag), `${id}: <${tag}>`);
    assert.doesNotMatch(n.html, /\son[a-z]+=|javascript:/i, id);
  }
});

test('evidence.js matches the notes (ids, titles, grades): rerun scripts/evidence_to_js.py after editing', () => {
  const dir = new URL('docs/evidence/', root);
  const files = readdirSync(dir).filter((f) => f.endsWith('.md') && f !== 'README.md').sort();
  assert.deepEqual(Object.keys(EVIDENCE), files.map((f) => f.slice(0, -3)));
  for (const f of files) {
    const md = readFileSync(new URL(f, dir), 'utf8');
    const n = EVIDENCE[f.slice(0, -3)];
    assert.equal(n.title, md.match(/^# (.+)$/m)[1].trim(), f);
    assert.equal(n.grade, md.match(/^## Evidence for this (?:headband|helmet): (\S+)/m)[1], f);
  }
});

test('the notes hold nothing local: no file paths or local addresses (this repository is public)', () => {
  const dir = new URL('docs/evidence/', root);
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.md'))) {
    const md = readFileSync(new URL(f, dir), 'utf8');
    assert.doesNotMatch(md, /file:\/\/|localhost|127\.0\.0\.1|\/home\/|\/media\/|[A-Z]:\\/, f);
  }
});
