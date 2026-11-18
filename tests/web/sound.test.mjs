// Unit tests for the brain-reactive sound logic. Run from the repo root:
//   node --test tests/web/sound.test.mjs tests/web/feedback-core.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { BandPower, channelQuality, percentile } from '../../scripts/web/sound-features.js';
import { mapState, sCurve, NEUTRAL_CALM, NUDGE_CALM } from '../../scripts/web/sound-mapping.js';
import { createMixer, MIX_TIMES } from '../../scripts/web/sound-mixer.js';
import { Session } from '../../scripts/web/sound-session.js';
import { DemoSignal, autoJaw } from '../../scripts/web/sound-demo.js';

const sine = (f, a, n = 250, fs = 250) => Array.from({ length: n }, (_, i) => a * Math.sin(2 * Math.PI * f * i / fs));
const settle = (band, x) => { let v = 0; for (const s of x) v = band.step(s); return v; };

test('BandPower: a 10 Hz sine of amplitude 10 gives about 50 µV² at 8-12 Hz and almost nothing at 30-45', () => {
  assert.ok(Math.abs(settle(new BandPower(8, 12), sine(10, 10, 1000)) - 50) < 2);
  assert.ok(settle(new BandPower(30, 45, { notch: 50, quadrature: false }), sine(10, 10, 1000)) < 0.05);
  const m = new BandPower(30, 45, { notch: 50, quadrature: false, tau: 0.25 });
  assert.ok(Math.abs(settle(m, sine(36.7, 10, 2000)) - 50) < 4);
});

test('channelQuality: flat, no contact, movement, fine', () => {
  assert.equal(channelQuality(new Array(250).fill(0), 1e5), 'off');
  assert.equal(channelQuality(sine(10, 10), null), 'off');
  assert.equal(channelQuality(sine(1, 200), 1e5), 'noisy');
  assert.equal(channelQuality(sine(10, 10), 1e5), 'ok');
  assert.equal(channelQuality(sine(10, 10), undefined), 'ok');
});

test('a channel without contact is not used; none at the back means poor quality', () => {
  const s = new Session({ calibrate: false });
  s.contact({ O1: 1e5, O2: null, T3: 1e5, T4: 1e5 });
  const demo = new DemoSignal(2);
  let steps = s.push(demo.next(500));
  assert.equal(steps.at(-1).channels.O2, 'off');
  assert.equal(steps.at(-1).channels.O1, 'ok');
  assert.equal(steps.at(-1).quality, 'learning');
  s.contact({ O1: null, O2: null, T3: 1e5, T4: 1e5 });
  steps = s.push(demo.next(50));
  assert.equal(steps.at(-1).quality, 'poor');
  assert.match(steps.at(-1).reason, /not touching/);
});

test('sCurve: 0 at 2 SD below the line, 0.5 on it, 1 at 2 SD above, rising in between', () => {
  assert.equal(sCurve(-2), 0); assert.equal(sCurve(-5), 0); assert.equal(sCurve(0), 0.5);
  assert.equal(sCurve(2), 1); assert.equal(sCurve(9), 1);
  let prev = -1;
  for (let z = -2; z <= 2; z += 0.1) { const v = sCurve(z); assert.ok(v >= prev); prev = v; }
  assert.ok(sCurve(0.2) - sCurve(0) > sCurve(1.9) - sCurve(1.7), 'steepest at the line');
});

test('mapState: more alpha above the line = quieter, darker rain and a warmer drone', () => {
  const lo = mapState({ z: -2, jaw: 0, quality: 'good', veto: null }), hi = mapState({ z: 2, jaw: 0, quality: 'good', veto: null });
  assert.ok(hi.rain < lo.rain && hi.rainTone < lo.rainTone);
  assert.ok(hi.warmth > lo.warmth && hi.droneTone > lo.droneTone && hi.drone > lo.drone);
  assert.deepEqual(mapState({ z: 7, jaw: 0, quality: 'good', veto: null }), hi);
  assert.equal(hi.bellsAllowed, true);
});

test('mapState: no signal, learning or a gate give the neutral bed and no bells; drowsy is a little brighter', () => {
  for (const quality of ['poor', 'none', 'learning', 'settling']) {
    const t = mapState({ z: 1, jaw: 0, quality, veto: null });
    assert.equal(t.calm, NEUTRAL_CALM); assert.equal(t.neutral, true); assert.equal(t.bellsAllowed, false);
  }
  for (const veto of ['muscle', 'blink']) {
    const t = mapState({ z: 1, jaw: 0, quality: 'good', veto });
    assert.equal(t.calm, NEUTRAL_CALM); assert.equal(t.bellsAllowed, false);
  }
  const d = mapState({ z: 1, jaw: 0, quality: 'good', veto: 'drowsy' });
  assert.equal(d.calm, NUDGE_CALM); assert.ok(d.rainTone > mapState({ z: 1, jaw: 0, quality: 'good', veto: 'blink' }).rainTone);
  assert.equal(mapState({ z: null, jaw: 0, quality: 'good', veto: null }).neutral, true);
});

test('mapState: jaw roughens; unknown jaw blocks bells', () => {
  const j = mapState({ z: 1, jaw: 0.6, quality: 'good', veto: 'muscle' });
  assert.equal(j.bellsAllowed, false); assert.equal(j.rough, 0.6);
  assert.equal(mapState({ z: 1, jaw: null, quality: 'good', veto: null }).bellsAllowed, false);
});

test('mixer: rough rises fast and falls slowly; training glides faster than relax', () => {
  const start = { calm: 0, rain: 0, rainTone: 0, drone: 0, warmth: 0, droneTone: 0, rough: 0 };
  const mx = createMixer(start, MIX_TIMES.relax);
  let v = mx.step({ ...start, rough: 1 }, 0.25);
  assert.ok(v.rough > 0.9);
  v = mx.step({ ...start, rough: 0 }, 0.25);
  assert.ok(v.rough > 0.7);
  for (let i = 0; i < 80; i++) v = mx.step({ ...start, calm: 1 }, 0.25);
  assert.ok(Math.abs(v.calm - 1) < 1e-3 && v.rough < 1e-3);
  assert.equal(mx.step({ calm: NaN }, 0.25).calm, v.calm);   // missing targets leave values alone
  const fast = createMixer(start, MIX_TIMES.training).step({ ...start, calm: 1, rain: 1 }, 0.25);
  assert.ok(fast.rain > 0.6, `training bed reaches ${fast.rain} of a step in 0.25 s`);
});

test('percentile', () => {
  assert.equal(percentile([3, 1, 2], 0.5), 2);
  assert.equal(percentile([0, 10], 0.1), 1);
});

// Whole pipeline on the demo signal (same recipe as the fake headband), eyes switching every minute.
// With calibration the eyes follow its cues (30 s open, then closed), and the demo's own minutes after.
function run(seconds, calibrate, { eyesDuringCal = true, seed = 7 } = {}) {
  const demo = new DemoSignal(seed), s = new Session({ calibrate }), out = [];
  while (demo.t < seconds) {
    const t = demo.t;
    demo.eyes = calibrate && eyesDuringCal && t < 120 ? (t < 30 ? 'open' : 'closed') : null;
    for (const r of s.push(demo.next(25))) out.push({ ...r, closed: demo.closed(r.t - 0.05), jawOn: demo.jaw(r.t - 0.05) });
  }
  return { out, s };
}
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;

for (const calibrate of [true, false]) {
  test(`pipeline (${calibrate ? 'calibrated' : 'first minute as baseline'}): calmer with eyes closed, no bell near a jaw burst`, () => {
    const { out, s } = run(600, calibrate);
    const cal = s.log.lines.find((l) => l.type === 'calibration');
    assert.equal(cal.iaf, 10);
    if (calibrate) assert.match(s.note, /eyes closed gave \d+\.\dx eyes-open alpha$/);
    const live = out.filter((o) => o.t > 125 && o.phase === 'run');
    const settled = (o) => o.t % 60 > 4;   // skip the first seconds after eyes switch
    const closed = live.filter((o) => o.closed && settled(o)), open = live.filter((o) => !o.closed && settled(o));
    assert.ok(mean(closed.map((o) => o.targets.calm)) > 0.45, 'calm with eyes closed');
    assert.ok(mean(open.map((o) => o.targets.calm)) < 0.3, 'not calm with eyes open');
    assert.ok(mean(closed.map((o) => o.targets.rain)) < mean(open.map((o) => o.targets.rain)));
    const bells = out.filter((o) => o.ring);
    assert.ok(bells.length >= 5, `bells ring with eyes closed (${bells.length})`);
    for (const b of bells) {
      const sinceBurstStart = b.t % 45;
      assert.ok(sinceBurstStart >= 3 + 4, `bell at ${b.t} s, ${sinceBurstStart.toFixed(2)} s after a jaw burst began`);
      const window = out.filter((o) => o.t > b.t - 3 && o.t <= b.t);
      assert.ok(window.every((o) => o.closed), `bell at ${b.t} s with eyes open in the 3 s before`);
    }
    for (const o of out.filter((o) => autoJaw(o.t - 0.3) && o.phase === 'run')) assert.equal(o.targets.bellsAllowed, false, `bells allowed at ${o.t} s in a jaw burst`);
    assert.ok(mean(out.filter((o) => autoJaw(o.t - 1) && o.phase === 'run').map((o) => o.targets.rough)) > 0.5, 'jaw roughens');
  });
}

test('calibration with no alpha rise says so', () => {
  const { s } = run(100, true, { eyesDuringCal: false });   // demo eyes stay closed (auto) for the whole calibration
  assert.match(s.note, /only \d+\.\dx eyes-open alpha/);
});

test('calibration waits for 30 s of clean eyes-closed signal', () => {
  const demo = new DemoSignal(4), s = new Session({ calibrate: true });
  s.contact({ O1: null, O2: null, T3: 1e5, T4: 1e5 });
  let last;
  for (let k = 0; k < 1000; k++) last = s.push(demo.next(25)).at(-1);   // 100 s with no back contact
  assert.equal(last.phase, 'cal-closed');
  s.contact({ O1: 1e5, O2: 1e5, T3: 1e5, T4: 1e5 });
  demo.eyes = 'closed';
  for (let k = 0; k < 300; k++) last = s.push(demo.next(25)).at(-1);
  assert.equal(last.phase, 'cal-closed', 'still not 30 s clean after 30 s (5 s settle after a phase start is not counted)');
  for (let k = 0; k < 100; k++) last = s.push(demo.next(25)).at(-1);
  assert.equal(last.phase, 'run');
});

test('without calibration a steady eyes-closed alpha sits near the middle of the sound', () => {
  const demo = new DemoSignal(3), s = new Session({ calibrate: false }); demo.eyes = 'closed';
  const out = [];
  while (demo.t < 120) out.push(...s.push(demo.next(25)));
  const calm = out.filter((o) => o.phase === 'run' && !o.veto).map((o) => o.targets.calm);
  assert.ok(mean(calm) > 0.3 && mean(calm) < 0.8, `calm ${mean(calm)}`);
});
