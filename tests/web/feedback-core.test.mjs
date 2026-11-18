// Tests of the feedback core (research A pass 2, "Build next" item 1). Run from the repo root:
//   node --test tests/web/sound.test.mjs tests/web/feedback-core.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { Session, STEP } from '../../scripts/web/sound-session.js';
import { DemoSignal } from '../../scripts/web/sound-demo.js';
import { TargetLine, Bells, firstLine, LINE, BELL } from '../../scripts/web/sound-reward.js';
import { SleepGuard, guardBaseline } from '../../scripts/web/sleep-guard.js';
import { StreamReader, replaySession } from '../../scripts/web/sound-source.js';
import { decodeInput } from '../../scripts/web/sound-log.js';

// A calibrated session on the demo: 30 s eyes open, then eyes closed. script(demo, t) may change the demo.
function session({ seconds = 690, mode = 'training', calibrate = true, seed = 7, script = () => {}, s = new Session({ mode, calibrate }) } = {}) {
  const demo = new DemoSignal(seed), steps = [];
  while (demo.t < seconds) {
    demo.eyes = calibrate && demo.t < 30 ? 'open' : 'closed';
    script(demo, demo.t, s);
    for (const x of s.push(demo.next(STEP))) steps.push({ ...x, demoT: demo.t });   // demo clock (differs after a skipped gap)
  }
  return { s, steps };
}
const bellTimes = (steps) => steps.filter((x) => x.ring).map((x) => x.t);

test('reaction: the alpha measure gets half-way to its new level within 0.3 s of the eyes closing or opening', () => {
  const { steps } = session({ seconds: 200, script: (d, t) => {
    if (t >= 100) {
      d.eyes = Math.floor((t - 100) / 10) % 2 === 0 ? 'open' : 'closed';
      d.blinks = false; d.jawBursts = false; d.wanders = false;
    }
  } });
  const at = (t) => steps.find((x) => Math.abs(x.t - t) < 0.01).z;
  for (let t0 = 110; t0 < 200; t0 += 10) {
    const before = at(t0), after = at(t0 + 2), half = (before + after) / 2;
    assert.ok(Math.abs(after - before) > 5, `eyes switch at ${t0} s moves z from ${before} to ${after}`);
    const hit = steps.find((x) => x.t > t0 && (after > before ? x.z >= half : x.z <= half));
    assert.ok(hit.t - t0 <= 0.3 + 1e-9, `switch at ${t0} s: half-way after ${(hit.t - t0).toFixed(2)} s`);
  }
});

test('slowed 7.5 Hz alpha (drifting toward sleep) earns far fewer bells than 10 Hz', () => {
  const normal = bellTimes(session({ script: (d, t) => { if (t >= 90) d.alphaHz = 10; } }).steps);
  const slow = session({ script: (d, t) => { if (t >= 90) d.alphaHz = 7.5; } });
  const slowBells = bellTimes(slow.steps);
  assert.ok(normal.length >= 20, `10 Hz: ${normal.length} bells in 10 min`);
  assert.ok(slowBells.length * 10 <= normal.length, `7.5 Hz: ${slowBells.length} bells against ${normal.length}`);
  const drowsy = slow.steps.filter((x) => x.t > 110 && x.phase === 'run' && x.veto === 'drowsy').length;
  assert.ok(drowsy > 0.7 * slow.steps.filter((x) => x.t > 110 && x.phase === 'run').length, 'the sleep guard holds the drowsy gate');
});

for (const mode of ['training', 'relax']) {
  test(`${mode}: at most 6 bells in any minute and at least ${BELL.gapS[mode]} s between bells, even with very strong alpha`, () => {
    const { steps } = session({ mode, script: (d, t) => { if (t >= 90) d.alphaGain = 2; } });
    const b = bellTimes(steps);
    assert.ok(b.length >= (mode === 'training' ? 40 : 30), `${b.length} bells`);
    for (let i = 1; i < b.length; i++) assert.ok(b[i] - b[i - 1] >= BELL.gapS[mode] - 1e-9, `gap ${b[i] - b[i - 1]} s at ${b[i]} s`);
    for (const t0 of b) assert.ok(b.filter((t) => t >= t0 && t < t0 + 60).length <= BELL.perMinute, `over 6 bells in the minute from ${t0} s`);
  });
}

test('no bell during or right after any gate (muscle, blink, drowsy, contact, gap)', () => {
  const { steps, s } = session({ seconds: 900, script: (d, t, sess) => {
    if (t >= 300 && t < 360) d.alphaHz = 7.5; else d.alphaHz = 10;                 // a drowsy minute
    if (Math.abs(t - 420) < 1e-9) sess.contact({ O1: null, O2: null, T3: 1e5, T4: 1e5 });   // back contact lost
    if (Math.abs(t - 450) < 1e-9) sess.contact({ O1: 1e5, O2: 1e5, T3: 1e5, T4: 1e5 });
    if (Math.abs(t - 500) < 1e-9) { sess.gap(); d.next(250 * 3); }                // 3 s lost
    if (t >= 600 && t < 660) d.jawUntil = t + 2;                                   // a long clench
  } });
  const run = steps.filter((x) => x.phase === 'run');
  const kinds = new Set(run.map((x) => x.veto ?? x.quality));
  for (const k of ['muscle', 'blink', 'drowsy', 'poor', 'settling']) assert.ok(kinds.has(k), `gate ${k} seen`);
  const window = BELL.windowS / 0.1;
  let rang = 0;
  steps.forEach((x, i) => {
    if (!x.ring) return;
    rang++;
    for (let j = i - window + 1; j <= i; j++) {
      assert.equal(steps[j].quality, 'good', `bell at ${x.t} s, quality ${steps[j].quality} at ${steps[j].t} s`);
      assert.equal(steps[j].veto, null, `bell at ${x.t} s, gate ${steps[j].veto} at ${steps[j].t} s`);
    }
  });
  assert.ok(rang >= 20, `${rang} bells outside the gates`);
  // ground truth from the demo's clock: no bell within 4 s after a jaw burst, a blink, the clench or the drowsy minute
  for (const t of steps.filter((x) => x.ring).map((x) => x.demoT)) {
    assert.ok(t % 45 >= 3 + 4, `bell ${(t % 45).toFixed(1)} s after a jaw burst began`);
    assert.ok((t - 0.15) % 7 >= 0.3 + 4 || (t - 0.15) % 7 < 0, `bell ${((t - 0.15) % 7).toFixed(1)} s after a blink`);
    assert.ok(!(t >= 300 && t < 364) && !(t >= 600 && t < 666) && !(t >= 420 && t < 455), `bell at ${t} s inside a gate`);
  }
  assert.ok(s.log.lines.some((l) => l.type === 'gap'));
});

test('replay of a logged session reproduces every step, bell and line exactly', () => {
  const { s } = session({ seconds: 400, script: (d, t, sess) => {
    if (Math.abs(t - 0) < 1e-9) sess.contact({ O1: 1e5, O2: 2e5, T3: 3e5, T4: 4e5 });
    if (Math.abs(t - 200) < 1e-9) { sess.gap(); d.next(250 * 2); }
    if (Math.abs(t - 250) < 1e-9) sess.contact({ O1: null, O2: 2e5, T3: 3e5, T4: 4e5 });
    if (t >= 300) d.alphaGain = 1.4;
  } });
  const saved = JSON.parse(JSON.stringify(s.log.toJSON()));   // what a saved session file holds
  assert.equal(decodeInput(saved.input)[0].length, s.n);
  const again = replaySession(saved);
  assert.equal(again.n, s.n);
  assert.ok(saved.lines.filter((l) => l.type === 'bell').length > 5);
  assert.ok(saved.lines.some((l) => l.type === 'block'));
  assert.deepEqual(again.log.lines, saved.lines);
  assert.deepEqual(JSON.parse(JSON.stringify(again.log.toJSON())).input, saved.input);
});

test('the output does not depend on how the samples are chunked', () => {
  const rows = new DemoSignal(5).next(250 * 100);
  const a = new Session({ calibrate: false }), b = new Session({ calibrate: false });
  a.push(rows);
  for (let i = 0; i < rows.length;) { const k = 1 + (i % 23); b.push(rows.slice(i, i + k)); i += k; }
  assert.deepEqual(b.log.lines, a.log.lines);
});

test('target line: held still inside a block, raised above 80 %, lowered under 50 %, gated steps not counted', () => {
  const l = new TargetLine({ line: 2, sd: 0.2 });
  const steps = LINE.blockS / 0.1;
  for (let i = 0; i < steps - 1; i++) { assert.equal(l.update(true), null); assert.equal(l.line, 2); }
  let r = l.update(true);
  assert.equal(r.moved, 1); assert.ok(Math.abs(l.line - (2 + 0.15 * 0.2)) < 1e-12);
  for (let i = 0; i < steps - 1; i++) l.update(i % 10 < 4);   // 40 % above
  r = l.update(false);
  assert.equal(r.moved, -1); assert.ok(Math.abs(l.line - 2) < 1e-12);
  for (let i = 0; i < steps; i++) r = l.update(i < 200 ? true : null);   // only 20 s counted: too little to move
  assert.equal(r.moved, 0); assert.equal(r.counted, 20);
  for (let i = 0; i < steps; i++) r = l.update(i % 10 < 7 ? true : i % 10 < 9 ? false : null);   // 70/90 counted: keep
  assert.equal(r.moved, 0); assert.ok(Math.abs(r.share - 7 / 9) < 1e-9);
});

test('firstLine: the 35th percentile, robust SD with a floor', () => {
  const v = Array.from({ length: 101 }, (_, i) => i / 100);
  const f = firstLine(v);
  assert.ok(Math.abs(f.line - 0.35) < 1e-9);
  assert.ok(Math.abs(f.sd - 1.4826 * 0.25) < 1e-9);
  assert.equal(firstLine(new Array(50).fill(3)).sd, LINE.sdFloor);
});

test('bells: 3 s above the line within 4 clean seconds; a gate clears the count', () => {
  const b = new Bells('training');
  let rings = 0;
  for (let i = 0; i < 39; i++) rings += b.update(true, i % 4 !== 0);   // 75 % above, but under 4 s so far
  assert.equal(rings, 0);
  assert.equal(b.update(true, true), true);                           // 4 s, 30 of 40 above
  const c = new Bells('training');
  for (let i = 0; i < 39; i++) c.update(true, true);
  assert.equal(c.update(false, true), false);                         // a gate at the last step
  for (let i = 0; i < 39; i++) assert.equal(c.update(true, true), false);
  assert.equal(c.update(true, true), true);
  const d = new Bells('training');
  for (let i = 0; i < 40; i++) d.update(true, i % 3 === 0);           // a third above: never
  assert.equal(d.rung.length, 0);
});

test('sleep guard: each sign fires on its own and not on a steady baseline', () => {
  const base = { alpha: 100, ratio: 0.5, iaf: 10 };
  const feed = (g, sec, a, th, hz = null) => { let st; for (let i = 0; i < sec * 10; i++) { st = g.update(a, th); if (i % 10 === 0) g.peak(hz); } return st; };
  let g = new SleepGuard(base);
  let st = feed(g, 120, 100, 50, 10);
  assert.equal(st.drowsy, false);
  st = feed(g, 12, 100, 80, 10);                   // ratio 1.6x; the 4 s mean passes 1.5x after about 3 s
  assert.equal(st.theta, false);
  st = feed(g, 2, 100, 80, 10);
  assert.equal(st.theta, true); assert.equal(st.drowsy, true);
  g = new SleepGuard(base);
  feed(g, 30, 100, 50, 10);
  st = feed(g, 4, 100, 50, 8.75);
  assert.equal(st.slow, false, 'needs 5 clear peaks');
  st = feed(g, 8, 100, 50, 8.75);
  assert.equal(st.slow, true);
  st = feed(g, 10, 100, 50, 9.5);
  assert.equal(st.slow, false, '0.5 Hz slower is not enough');
  g = new SleepGuard(base);
  feed(g, 30, 100, 50, 10);
  st = feed(g, 15, 40, 20, null);                  // half of 30 s faded: not over half yet
  assert.equal(st.faded, false);
  st = feed(g, 1, 40, 20, null);
  assert.equal(st.faded, true); assert.equal(st.theta, false);
  g.reset();
  assert.equal(g.update(100, 50).drowsy, false);
  assert.equal(new SleepGuard({ alpha: 100, ratio: 0.5, iaf: null }).peak(7) ?? true, true);
});

test('guardBaseline: medians of the window means, clean steps only', () => {
  const alpha = new Array(100).fill(100), theta = new Array(100).fill(30), clean = new Array(100).fill(true);
  alpha[90] = 1e6; clean[90] = false;
  const b = guardBaseline(alpha, theta, clean, 9.5);
  assert.equal(b.alpha, 100); assert.ok(Math.abs(b.ratio - 0.3) < 1e-12); assert.equal(b.iaf, 9.5);
});

test('stream reader: hello, batches in channel order, gaps from a skipped index, a pause or a reconnect', () => {
  const r = new StreamReader();
  assert.equal(r.read({ marker: 'x', i: 0, t: 1 }), null);
  const h = r.read({ hello: true, names: ['T3', 'T4', 'O1', 'O2'], fs: 250, unit: 'uV', next_i: 100 });
  assert.equal(h.gap, false);
  let b = r.read({ i: 100, t: 10, uv: [[3, 4, 1, 2], [7, 8, 5, 6]] });
  assert.deepEqual(b.rows, [[1, 2, 3, 4], [5, 6, 7, 8]]); assert.equal(b.gap, false);
  b = r.read({ i: 102, t: 10.1, uv: [[0, 0, 0, 0]] }); assert.equal(b.gap, false);
  b = r.read({ i: 110, t: 10.2, uv: [[0, 0, 0, 0]] }); assert.equal(b.gap, true, 'samples skipped');
  b = r.read({ i: 111, t: 12.5, uv: [[0, 0, 0, 0]] }); assert.equal(b.gap, true, 'no batch for 2.3 s');
  assert.equal(r.read({ marker: 'sound: bell', i: 112, t: 12.6 }), null);
  assert.equal(r.read({ hello: true, names: ['O1', 'O2', 'T3', 'T4'], fs: 250, next_i: 0 }).gap, true, 'recorder restarted');
  assert.throws(() => new StreamReader().read({ hello: true, names: ['O1', 'O2', 'T3', 'T4'], fs: 500 }));
});
