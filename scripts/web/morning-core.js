// Pure logic for morning.html: phase plan, marker texts, rating scales, signal grading.
// No DOM here, so node can test it (tests/js/morning-core.test.mjs).

export const KSS = [ // Karolinska Sleepiness Scale (Åkerstedt & Gillberg 1990), standard labels
  [1, 'Extremely alert'],
  [2, 'Very alert'],
  [3, 'Alert'],
  [4, 'Rather alert'],
  [5, 'Neither alert nor sleepy'],
  [6, 'Some signs of sleepiness'],
  [7, 'Sleepy, but no effort to keep awake'],
  [8, 'Sleepy, some effort to keep awake'],
  [9, 'Very sleepy, great effort to keep awake, fighting sleep'],
];
export const MOOD = [[1, 'Very bad'], [2, 'Bad'], [3, 'Okay'], [4, 'Good'], [5, 'Very good']];
export const TENSION = [[1, 'None'], [2, 'A little'], [3, 'Some'], [4, 'A lot'], [5, 'Very much']];

/** Phase lengths in seconds: 120 s each, or 60 s with ?short=1 (for testing). */
export function phaseSeconds(search) {
  const p = new URLSearchParams(search || '');
  return p.get('short') === '1' ? 60 : 120;
}

/** The recording part of the check-in, in order. */
export function morningPlan(sec) {
  return [
    { key: 'eyes_closed', seconds: sec, title: 'Eyes closed', say: 'Close your eyes and rest. A soft tone will tell you when to open them.' },
    { key: 'eyes_open', seconds: sec, title: 'Eyes open', say: 'Look at the dot. Relax, blink normally.' },
  ];
}

export const marker = {
  start: () => 'morning:start',
  phase: (key, edge) => `morning:${key}:${edge}`, // edge: start | end
  ratings: (r) => `morning:ratings ${JSON.stringify({ kss: r.kss, mood: r.mood, tension: r.tension })}`,
  end: () => 'morning:end',
  abort: () => 'morning:abort',
};

export function validRatings(r) {
  const ok = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
  return !!r && ok(r.kss, 1, 9) && ok(r.mood, 1, 5) && ok(r.tension, 1, 5);
}

/** Setup test ("what can it see"): a list of timed cues. Each cue: at (s from start), text shown, marker. */
export function setupPlan() {
  const cues = []; let t = 3;
  cues.push({ at: 0, show: 'Sit still, eyes open, look ahead.', marker: 'setup:start' });
  for (let k = 0; k < 20; k++) { cues.push({ at: t, show: `Blink (${k + 1} of 20)`, marker: 'setup:blink', tone: true }); t += 3; }
  cues.push({ at: t, show: 'Next: look left or right when asked, then back to the dot.', marker: null }); t += 4;
  for (let k = 0; k < 10; k++) {
    const side = k % 2 ? 'right' : 'left';
    cues.push({ at: t, show: `Look ${side}`, marker: `setup:glance:${side}`, tone: true }); t += 1.5;
    cues.push({ at: t, show: 'Back to the dot', marker: null }); t += 3;
  }
  cues.push({ at: t, show: 'Next: clench your jaw when asked, relax when asked.', marker: null }); t += 4;
  for (let k = 0; k < 5; k++) {
    cues.push({ at: t, show: `Clench your jaw (${k + 1} of 5)`, marker: 'setup:clench:start', tone: true }); t += 2;
    cues.push({ at: t, show: 'Relax', marker: 'setup:clench:end' }); t += 4;
  }
  cues.push({ at: t, show: 'Done.', marker: 'setup:end', last: true });
  return cues;
}

/** "m:ss" for a countdown. */
export function clock(s) {
  s = Math.max(0, Math.ceil(s));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** Spread of the signal in µV (standard deviation) after removing the mean. */
export function spread(x) {
  if (!x || !x.length) return 0;
  const m = x.reduce((a, b) => a + b, 0) / x.length;
  return Math.sqrt(x.reduce((a, b) => a + (b - m) * (b - m), 0) / x.length);
}

/**
 * One word per electrode from its contact (ohms, null = no contact) and its last seconds of signal (µV).
 * Thresholds follow live_page.html: flat or over 60 µV spread is bad, over 30 µV is fair.
 */
export function gradeChannel(ohms, x) {
  const s = spread(x);
  const flat = !x || x.length < 10 || Math.max(...x.map(Math.abs)) < 0.5;
  if (ohms === null || ohms === undefined || flat) return { grade: 'bad', word: 'not touching', spread: s };
  if (s > 60) return { grade: 'bad', word: 'noisy', spread: s };
  if (s > 30) return { grade: 'fair', word: 'fair', spread: s };
  return { grade: 'good', word: 'good', spread: s };
}
