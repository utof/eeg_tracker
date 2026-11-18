// Unit tests for the brain-reactive sound logic. Run from the repo root: node --test tests/web/
import test from 'node:test';
import assert from 'node:assert/strict';
import { bandPower, channelQuality, measure } from '../../scripts/web/sound-features.js';
import { mapState, rewardStep, newReward, NEUTRAL_CALM, REWARD } from '../../scripts/web/sound-mapping.js';
import { createMixer } from '../../scripts/web/sound-mixer.js';
import { Session, percentile } from '../../scripts/web/sound-session.js';
import { DemoSignal, autoEyesClosed, autoJaw } from '../../scripts/web/sound-demo.js';

const sine = (f, a, n = 250, fs = 250) => Array.from({ length: n }, (_, i) => a * Math.sin(2 * Math.PI * f * i / fs));

test('bandPower: a 10 Hz sine of amplitude 10 gives about 50 µV² in 8-12 Hz and little at 30-45', () => {
  const x = sine(10, 10);
  assert.ok(Math.abs(bandPower(x, 250, 8, 12) - 50) < 3);
  assert.ok(bandPower(x, 250, 30, 45) < 0.01);
  assert.ok(Math.abs(bandPower(sine(38, 10), 250, 30, 45) - 50) < 3);
});

test('channelQuality: flat, no contact, movement, fine', () => {
  assert.equal(channelQuality(new Array(250).fill(0), 1e5), 'off');
  assert.equal(channelQuality(sine(10, 10), null), 'off');
  assert.equal(channelQuality(sine(1, 200), 1e5), 'noisy');
  assert.equal(channelQuality(sine(10, 10), 1e5), 'ok');
  assert.equal(channelQuality(sine(10, 10), undefined), 'ok');
});

test('measure skips channels without contact', () => {
  const f = { fs: 250, names: ['O1', 'O2', 'T3', 'T4'], data: [sine(10, 20), sine(10, 2), sine(38, 5), sine(38, 5)],
    contact: { O1: 1e5, O2: null, T3: 1e5, T4: 1e5 } };
  const m = measure(f);
  assert.equal(m.quality.O2, 'off');
  assert.ok(Math.abs(m.alphaLog - Math.log10(200)) < 0.05);   // O1 only
  f.contact.O1 = null;
  assert.equal(measure(f).alphaLog, null);
});

test('mapState: more alpha = quieter, darker rain and a warmer drone', () => {
  const lo = mapState({ alpha: 0, jaw: 0, quality: 'good' }), hi = mapState({ alpha: 1, jaw: 0, quality: 'good' });
  assert.ok(hi.rain < lo.rain && hi.rainTone < lo.rainTone);
  assert.ok(hi.warmth > lo.warmth && hi.droneTone > lo.droneTone && hi.drone > lo.drone);
  // monotonic in between, clamped outside 0..1
  let prev = mapState({ alpha: -1, jaw: 0, quality: 'good' }).rain;
  for (let a = 0; a <= 2; a += 0.1) { const r = mapState({ alpha: a, jaw: 0, quality: 'good' }).rain; assert.ok(r <= prev); prev = r; }
  assert.deepEqual(mapState({ alpha: 5, jaw: 0, quality: 'good' }), hi);
});

test('mapState: bad contact, no data or learning give the neutral bed and no bells', () => {
  for (const quality of ['poor', 'none', 'learning']) {
    const t = mapState({ alpha: 1, jaw: 0, quality });
    assert.equal(t.calm, NEUTRAL_CALM); assert.equal(t.neutral, true); assert.equal(t.bellsAllowed, false);
  }
  assert.equal(mapState({ alpha: null, jaw: 0, quality: 'good' }).neutral, true);
});

test('mapState: jaw blocks bells and roughens; unknown jaw also blocks bells', () => {
  assert.equal(mapState({ alpha: 1, jaw: 0, quality: 'good' }).bellsAllowed, true);
  const j = mapState({ alpha: 1, jaw: 0.6, quality: 'good' });
  assert.equal(j.bellsAllowed, false); assert.equal(j.rough, 0.6);
  assert.equal(mapState({ alpha: 1, jaw: null, quality: 'good' }).bellsAllowed, false);
});

test('reward: rings after calm is held 3 s, not before; a block resets and locks', () => {
  let r = newReward(), rings = 0, ring;
  for (let i = 0; i < 11; i++) { ({ r, ring } = rewardStep(r, 0.9, true, 0.25)); rings += ring; }
  assert.equal(rings, 0);                                   // 2.75 s
  ({ r, ring } = rewardStep(r, 0.9, true, 0.25)); assert.equal(ring, true);   // 3.0 s
  // a dip below the level restarts the count
  r = newReward();
  for (let i = 0; i < 8; i++) ({ r } = rewardStep(r, 0.9, true, 0.25));
  ({ r } = rewardStep(r, 0.5, true, 0.25)); assert.equal(r.hold, 0);
  // jaw: blocked, then still locked for REWARD.lockS
  r = newReward(); ring = false;
  ({ r } = rewardStep(r, 0.9, false, 0.25));
  let t = 0;
  while (!ring) { ({ r, ring } = rewardStep(r, 0.9, true, 0.25)); t += 0.25; }
  assert.ok(t >= REWARD.lockS + REWARD.holdS - 0.25 - 1e-6 && t <= REWARD.lockS + REWARD.holdS, `first bell after ${t} s`);
});

test('mixer: rough rises fast and falls slowly; values approach targets', () => {
  const start = { calm: 0, rain: 0, rainTone: 0, drone: 0, warmth: 0, droneTone: 0, rough: 0 };
  const mx = createMixer(start);
  let v = mx.step({ ...start, rough: 1 }, 0.25);
  assert.ok(v.rough > 0.9);
  v = mx.step({ ...start, rough: 0 }, 0.25);
  assert.ok(v.rough > 0.7);
  for (let i = 0; i < 80; i++) v = mx.step({ ...start, calm: 1 }, 0.25);
  assert.ok(Math.abs(v.calm - 1) < 1e-3 && v.rough < 1e-3);
  assert.equal(mx.step({ calm: NaN }, 0.25).calm, v.calm);   // missing targets leave values alone
});

test('percentile', () => {
  assert.equal(percentile([3, 1, 2], 0.5), 2);
  assert.equal(percentile([0, 10], 0.1), 1);
});

// Whole pipeline on the demo signal (same recipe as the fake headband), 4 updates a second.
function run(seconds, calibrate, eyesDuringCal = true) {
  const demo = new DemoSignal(7), s = new Session(), out = [];
  s.begin(0, calibrate);
  for (let t = 0.25; t <= seconds; t += 0.25) {
    if (calibrate && eyesDuringCal) demo.eyes = t < 30 ? 'open' : t < 60 ? 'closed' : null;
    const r = s.update(demo.frame(t), t);
    out.push({ t, ...r, closed: demo.closed(t), jaw: demo.jaw(t) });
  }
  return { out, s };
}
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;

for (const calibrate of [true, false]) {
  test(`pipeline (${calibrate ? 'calibrated' : 'recent range'}): calmer with eyes closed, no bell near a jaw burst`, () => {
    const { out, s } = run(600, calibrate);
    if (calibrate) assert.equal(s.calRef?.from, 'calibration');
    const live = out.filter((o) => o.t > 125 && o.quality === 'good');
    const settled = (o) => o.t % 60 > 4;   // skip the first seconds after eyes switch
    const closed = live.filter((o) => o.closed && settled(o)), open = live.filter((o) => !o.closed && settled(o));
    assert.ok(mean(closed.map((o) => o.targets.calm)) > 0.8, 'calm with eyes closed');
    assert.ok(mean(open.map((o) => o.targets.calm)) < 0.2, 'not calm with eyes open');
    assert.ok(mean(closed.map((o) => o.targets.rain)) < mean(open.map((o) => o.targets.rain)) / 2);
    const bells = out.filter((o) => o.ring);
    assert.ok(bells.length > 10, `bells ring with eyes closed (${bells.length})`);
    for (const b of bells) {
      const sinceBurstStart = b.t % 45;
      assert.ok(sinceBurstStart >= 3 + 2 + 3 - 0.75, `bell at ${b.t} s, ${sinceBurstStart.toFixed(2)} s after a jaw burst began`);
      assert.ok(autoEyesClosed(b.t - 1), `bell at ${b.t} s while eyes open`);
    }
    for (const o of out.filter((o) => autoJaw(o.t - 0.5) && o.t > 65)) assert.equal(o.targets.bellsAllowed, false);
    assert.ok(mean(out.filter((o) => autoJaw(o.t - 1) && o.t > 65).map((o) => o.targets.rough)) > 0.5, 'jaw roughens');
  });
}

test('calibration with no alpha rise falls back to the recent range', () => {
  const { s } = run(70, true, false);   // demo eyes stay closed (auto) for the whole calibration
  assert.equal(s.calRef, null);
  assert.match(s.note, /no clear alpha rise/);
});

test('stale or missing data: neutral bed with a reason', () => {
  const s = new Session(); s.begin(0, false);
  let r = s.update(null, 1);
  assert.equal(r.quality, 'none'); assert.match(r.reason, /No answer/); assert.equal(r.targets.neutral, true);
  r = s.update({ fs: 250, names: ['O1', 'O2', 'T3', 'T4'], data: [[], [], [], []], age: 9 }, 2);
  assert.match(r.reason, /No data from the headband for 9 s/);
  const flat = new Array(1000).fill(0);
  r = s.update({ fs: 250, names: ['O1', 'O2', 'T3', 'T4'], data: [flat, flat, flat, flat], contact: {}, age: 0.1 }, 3);
  assert.equal(r.quality, 'poor'); assert.match(r.reason, /not touching/);
});

test('recent range with steady alpha sits mid-scale, not at the bottom', () => {
  const demo = new DemoSignal(3), s = new Session(); s.begin(0, false); demo.eyes = 'closed';
  let r;
  for (let t = 0.25; t <= 30; t += 0.25) r = s.update(demo.frame(t), t);
  assert.ok(r.targets.calm > 0.3 && r.targets.calm < 0.7, `calm ${r.targets.calm}`);
});
