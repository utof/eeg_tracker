// node --test tests/web/live-page.test.mjs   (no packages needed)
// The live check page (scripts/live_page.html) on /state answers from BrainBit and from the DIY board: it draws one
// row per channel name it is given, and says "not measured" where nobody measured contact (the DIY board cannot).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('../../scripts/live_page.html', import.meta.url), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];

// Just enough DOM for the page's script: elements by id, ids found in innerHTML, a canvas that ignores drawing.
function run(state) {
  const els = {};
  const ctx2d = new Proxy({}, { get: () => () => {} });
  function el(id) {
    const e = {
      id, className: '', textContent: '', style: {}, children: [], html: '', canvas: null, owned: [],
      append(c) { this.children.push(c); },
      querySelector(sel) { return sel === 'canvas' ? this.canvas : null; },
      getContext() { return ctx2d; },
      set innerHTML(h) {  // replaces the children: their ids leave the page
        for (const c of this.children) for (const id of c.owned) delete els[id];
        for (const id of this.owned) delete els[id];
        this.html = h; this.children = []; this.owned = [];
        for (const m of h.matchAll(/id=([A-Za-z0-9_.-]+)/g)) {
          const c = el(m[1]); els[m[1]] = c; this.owned.push(m[1]);
          if (h.includes(`<canvas id=${m[1]} `)) this.canvas = c;
        }
      },
      get innerHTML() { return this.html; },
    };
    return e;
  }
  for (const id of ['top', 'chs', 'alpha', 'alphatxt', 'alphabar', 'hint']) els[id] = el(id);
  const ctx = {
    document: { getElementById: (id) => els[id] ?? null, createElement: () => el(null) },
    fetch: async () => ({ json: async () => state }), setTimeout: () => {}, Math, console,
  };
  vm.createContext(ctx);
  vm.runInContext(script, ctx);
  return els;
}

const settle = () => new Promise((r) => setTimeout(r, 20));
const sine = (uv) => Array.from({ length: 1000 }, (_, i) => uv * Math.sin(2 * Math.PI * 10 * i / 250));

function state(names, contact, contactT) {
  return { status: 'recording', battery: '?', battery_note: null, minutes: 1, age: 0.1, names, fs: 250,
           contact, contact_t: contactT, data: names.map(() => sine(20)) };
}

test('one row per channel name from /state, the DIY montage included', async () => {
  const names = ['O1', 'O2', 'Fz', 'Fp1'];
  const els = run(state(names, Object.fromEntries(names.map((n) => [n, null])), null));
  await settle();
  assert.equal(els.chs.children.length, 4);
  for (const n of names) assert.ok(els['b' + n], n);
  assert.equal(els.bT3, undefined);
  assert.equal(els.bFz.textContent, 'good');  // contact never measured: graded on the signal alone
  assert.match(els.nFz.textContent, /contact not measured/);
});

test('eight channels get eight rows', async () => {
  const names = Array.from({ length: 8 }, (_, i) => `Ch${i + 1}`);
  const els = run(state(names, Object.fromEntries(names.map((n) => [n, null])), null));
  await settle();
  assert.equal(els.chs.children.length, 8);
  assert.ok(els.bCh8);
});

test('BrainBit as before: a measured electrode without contact is "not touching"', async () => {
  const names = ['O1', 'O2', 'T3', 'T4'];
  const els = run(state(names, { O1: 150000, O2: 220000, T3: null, T4: 180000 }, 1763500000.5));
  await settle();
  assert.equal(els.chs.children.length, 4);
  assert.equal(els.bT3.textContent, 'not touching');
  assert.equal(els.bO1.textContent, 'good');
  assert.match(els.nO1.textContent, /contact 150 kΩ/);
});
