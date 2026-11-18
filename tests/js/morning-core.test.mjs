// node --test tests/js/*.test.mjs   (no packages needed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { KSS, MOOD, TENSION, phaseSeconds, morningPlan, marker, validRatings, setupPlan, clock, gradeChannel } from '../../scripts/web/morning-core.js';

test('KSS has the nine standard steps', () => {
  assert.deepEqual(KSS.map(([v]) => v), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.equal(KSS[0][1], 'Extremely alert');
  assert.equal(KSS[4][1], 'Neither alert nor sleepy');
  assert.match(KSS[8][1], /fighting sleep/);
  assert.equal(MOOD.length, 5); assert.equal(TENSION.length, 5);
});

test('phases are 2 min, or 1 min with ?short=1', () => {
  assert.equal(phaseSeconds(''), 120);
  assert.equal(phaseSeconds('?short=1'), 60);
  assert.equal(phaseSeconds('?short=0'), 120);
  assert.deepEqual(morningPlan(60).map((p) => [p.key, p.seconds]), [['eyes_closed', 60], ['eyes_open', 60]]);
});

test('marker texts match what morning_check.py reads', () => {
  assert.equal(marker.phase('eyes_closed', 'start'), 'morning:eyes_closed:start');
  assert.equal(marker.phase('eyes_open', 'end'), 'morning:eyes_open:end');
  assert.equal(marker.ratings({ kss: 5, mood: 3, tension: 2, extra: 1 }), 'morning:ratings {"kss":5,"mood":3,"tension":2}');
});

test('ratings must all be set and in range', () => {
  assert.ok(validRatings({ kss: 9, mood: 1, tension: 5 }));
  assert.ok(!validRatings({ kss: 10, mood: 1, tension: 5 }));
  assert.ok(!validRatings({ kss: 5, mood: null, tension: 2 }));
  assert.ok(!validRatings(null));
});

test('setup test: 20 blinks, 10 glances (5 each side), 5 clenches, cues in time order', () => {
  const c = setupPlan(); const n = (m) => c.filter((x) => x.marker === m).length;
  assert.equal(n('setup:blink'), 20);
  assert.equal(n('setup:glance:left'), 5); assert.equal(n('setup:glance:right'), 5);
  assert.equal(n('setup:clench:start'), 5); assert.equal(n('setup:clench:end'), 5);
  assert.equal(c[0].marker, 'setup:start'); assert.equal(c.at(-1).marker, 'setup:end');
  for (let k = 1; k < c.length; k++) assert.ok(c[k].at > c[k - 1].at);
  assert.ok(c.at(-1).at < 150, 'under 2.5 minutes');
});

test('clock and grading', () => {
  assert.equal(clock(119.2), '2:00'); assert.equal(clock(5), '0:05'); assert.equal(clock(-3), '0:00');
  const sine = (a) => Array.from({ length: 1000 }, (_, i) => a * Math.sin(i / 3));
  assert.equal(gradeChannel(null, sine(10)).word, 'not touching');
  assert.equal(gradeChannel(2e5, sine(0.1)).word, 'not touching');
  assert.equal(gradeChannel(2e5, sine(10)).grade, 'good');
  assert.equal(gradeChannel(2e5, sine(60)).grade, 'fair');
  assert.equal(gradeChannel(2e5, sine(120)).word, 'noisy');
});
