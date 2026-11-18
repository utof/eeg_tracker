// Drift-to-sleep detector for eyes-closed sessions, shared by every feature that must notice dozing:
// brain sound now; later the alpha-theta sleep guard, the dream catcher and the sleep-sound auto-stop.
// Pure: it gets numbers in and says whether the person seems to be drifting off, and why.
//
// Three signs, each against the person's own eyes-closed baseline (research A pass 2, gates table):
//   theta:  theta / alpha (4 s means) above 1.5x the baseline ratio for 10 s in a row
//   slow:   the alpha peak (median of the clear peaks of the last 10 s) 1 Hz or more below the baseline peak
//   faded:  alpha (1 s means) under half the baseline for more than half of the last 30 s
// It cannot tell open eyes from dozing: both lower alpha at O1/O2. Word it as "eyes open, or drifting off".
// All numbers are planning values, to tune on the owner's recordings.
//
// Port notes (Dart): a class with fixed-size lists; feed it once per step (stepS apart) and once a
// second with the alpha peak. No clock inside: time is counted in steps.

import { median } from './sound-features.js';

export const GUARD = {
  ratioX: 1.5, ratioS: 10,       // theta/alpha above 1.5x baseline for 10 s
  peakDropHz: 1, peakS: 10, minPeaks: 5,  // alpha peak 1 Hz slower, from at least 5 clear peaks in 10 s
  fadeX: 0.5, fadeS: 30, fadeShare: 0.5,  // alpha under 0.5x baseline in over half of 30 s
  meanS: 4, alphaS: 1,           // averaging windows
};

// Baseline from eyes-closed steps: alpha and theta powers (µV², one value per step), whether each
// step was clean, and the alpha peak (Hz or null). Uses the same window means the guard uses.
export function guardBaseline(alpha, theta, clean, iaf, stepS = 0.1) {
  const nMean = Math.round(GUARD.meanS / stepS), nAlpha = Math.round(GUARD.alphaS / stepS);
  const ratios = [], alphas = [];
  for (let i = nMean - 1; i < alpha.length; i++) {
    if (!clean[i]) continue;
    let a4 = 0, t4 = 0, a1 = 0;
    for (let j = i - nMean + 1; j <= i; j++) { a4 += alpha[j]; t4 += theta[j]; }
    for (let j = i - nAlpha + 1; j <= i; j++) a1 += alpha[j];
    if (a4 > 0) ratios.push(t4 / a4);
    alphas.push(a1 / nAlpha);
  }
  return { alpha: alphas.length ? median(alphas) : null, ratio: ratios.length ? median(ratios) : null, iaf };
}

export class SleepGuard {
  constructor(base, stepS = 0.1) {
    this.base = base; this.stepS = stepS;
    this.nMean = Math.round(GUARD.meanS / stepS); this.nAlpha = Math.round(GUARD.alphaS / stepS);
    this.nFade = Math.round(GUARD.fadeS / stepS); this.nRatio = Math.round(GUARD.ratioS / stepS);
    this.nPeak = Math.round(GUARD.peakS / stepS);
    this.reset();
  }

  // after a gap in the signal: start the windows again
  reset() {
    this.alpha = []; this.theta = []; this.faded = []; this.ratioRun = 0;
    this.peaks = []; this.step = 0;
    this.state = { drowsy: false, theta: false, slow: false, faded: false, ratio: null, peakHz: null, fadedShare: 0 };
  }

  // once per step: alpha and theta power (µV²) of the clean back channels. Returns the state.
  update(alpha, theta) {
    const b = this.base, st = this.state;
    this.step++;
    push(this.alpha, alpha, this.nMean); push(this.theta, theta, this.nMean);
    const n = this.alpha.length;
    let a1 = 0;
    for (let j = Math.max(0, n - this.nAlpha); j < n; j++) a1 += this.alpha[j];
    a1 /= Math.min(n, this.nAlpha);
    push(this.faded, b.alpha !== null && a1 < GUARD.fadeX * b.alpha, this.nFade);
    const fadedCount = this.faded.filter(Boolean).length;
    st.fadedShare = fadedCount / this.nFade;
    st.faded = fadedCount > GUARD.fadeShare * this.nFade;

    if (n >= this.nMean && b.ratio !== null) {
      const a4 = sum(this.alpha), t4 = sum(this.theta);
      st.ratio = a4 > 0 ? t4 / a4 / b.ratio : null;
      this.ratioRun = st.ratio !== null && st.ratio > GUARD.ratioX ? this.ratioRun + 1 : 0;
    } else { st.ratio = null; this.ratioRun = 0; }
    st.theta = this.ratioRun >= this.nRatio;

    while (this.peaks.length && this.peaks[0][0] <= this.step - this.nPeak) this.peaks.shift();
    const hz = this.peaks.map((p) => p[1]);
    st.peakHz = hz.length ? median(hz) : null;
    st.slow = b.iaf !== null && hz.length >= GUARD.minPeaks && st.peakHz <= b.iaf - GUARD.peakDropHz + 1e-9;

    st.drowsy = st.theta || st.slow || st.faded;
    return st;
  }

  // about once a second: the alpha peak of the last few seconds (Hz), or null when there is no clear peak
  peak(hz) { if (hz !== null) this.peaks.push([this.step, hz]); }
}

function push(a, v, max) { a.push(v); if (a.length > max) a.shift(); }
function sum(a) { let s = 0; for (const v of a) s += v; return s; }
