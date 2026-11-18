// One listening session: calibration, personal baseline, brain state, reward bell.
// Pure logic (time comes in as an argument), so node tests and the browser run the same code.
//
// Baseline (DECISIONS row 18): a 60 s calibration at the start, 30 s eyes open then 30 s eyes
// closed. Eyes-open alpha becomes 0 on the person's scale, eyes-closed alpha becomes 1. If eyes
// closed did not raise alpha at least 1.5x (no clear alpha, bad contact, eyes not really shut), or
// the person skips calibration, the scale comes from their own recent range instead:
// 10th to 90th percentile of the last 5 minutes, after 5 s of data. When that range is under 2x
// (alpha has hardly changed) a 2x span is centred on it, so a steady level sits mid-scale.
// Jaw: resting level = 20th percentile of the last 2 minutes of 30-45 Hz power at T3/T4.

import { measure, BACK, SIDE } from './sound-features.js';
import { mapState, rewardStep, newReward, JAW_BLOCK } from './sound-mapping.js';

export const CAL = { openS: 30, closedS: 30, settleS: 5, minRise: Math.log10(1.5) };
export const RUN = { alphaS: 300, jawS: 120, minSpan: Math.log10(2), warmupS: 5, staleS: 2, scoreTau: 0.5 };
const JAW_FLOOR = Math.log10(2), JAW_SPAN = Math.log10(5);  // 2x rest = 0, 10x rest = 1

export function percentile(a, p) {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y), i = (s.length - 1) * p, lo = Math.floor(i);
  return lo + 1 < s.length ? s[lo] + (s[lo + 1] - s[lo]) * (i - lo) : s[lo];
}
const median = (a) => percentile(a, 0.5);
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const keepSince = (h, t0) => { while (h.length && h[0][0] < t0) h.shift(); };

export class Session {
  constructor() {
    this.phase = 'idle';     // idle, cal-open, cal-closed, run
    this.ref = null;         // {lo, hi, from: 'calibration' | 'recent range'}
    this.calRef = null;
    this.note = '';
    this.alphaHist = []; this.jawHist = [];  // [t, log10 power]
    this.cal = { open: [], closed: [] };
    this.reward = newReward(); this.score = null; this.lastT = null;
  }

  begin(t, calibrate = true) {
    this.t0 = t; this.phase = calibrate ? 'cal-open' : 'run'; this.lastT = t;
    this.note = calibrate ? '' : 'calibration skipped: using your recent range';
  }

  // frame: {fs, names, data, contact, age} or null (no answer). Returns everything the page shows.
  update(frame, t) {
    const dt = this.lastT === null ? 0 : Math.min(1, Math.max(0, t - this.lastT));
    this.lastT = t;
    let cue = null;
    // phase changes
    if (this.phase === 'cal-open' && t - this.t0 >= CAL.openS) { this.phase = 'cal-closed'; cue = 'close-eyes'; }
    if (this.phase === 'cal-closed' && t - this.t0 >= CAL.openS + CAL.closedS) {
      this.phase = 'run'; cue = 'calibration-done'; this.finishCalibration();
    }

    const stale = !frame || !(frame.age <= RUN.staleS);
    const m = stale ? { alphaLog: null, jawLog: null, quality: {} } : measure(frame);
    if (m.alphaLog !== null) {
      this.alphaHist.push([t, m.alphaLog]);
      const since = t - (this.phase === 'cal-open' ? this.t0 : this.t0 + CAL.openS);
      if (this.phase === 'cal-open' && since >= CAL.settleS) this.cal.open.push(m.alphaLog);
      if (this.phase === 'cal-closed' && since >= CAL.settleS) this.cal.closed.push(m.alphaLog);
    }
    if (m.jawLog !== null) this.jawHist.push([t, m.jawLog]);
    keepSince(this.alphaHist, t - RUN.alphaS); keepSince(this.jawHist, t - RUN.jawS);

    // reference for alpha
    if (this.phase === 'run') {
      if (this.calRef) this.ref = this.calRef;
      else if (this.alphaHist.length && t - this.alphaHist[0][0] >= RUN.warmupS) {
        const v = this.alphaHist.map((h) => h[1]);
        let lo = percentile(v, 0.1), hi = percentile(v, 0.9);
        if (hi - lo < RUN.minSpan) {  // too little change to know high from low: centre a 2x span on it
          const mid = (lo + hi) / 2; lo = mid - RUN.minSpan / 2; hi = mid + RUN.minSpan / 2;
        }
        this.ref = { lo, hi, from: 'recent range' };
      }
    }

    // jaw on its own scale
    let jaw = null;
    if (m.jawLog !== null && this.jawHist.length >= 8) {
      const rest = percentile(this.jawHist.map((h) => h[1]), 0.2);
      jaw = clamp01((m.jawLog - rest - JAW_FLOOR) / JAW_SPAN);
    }

    // quality and why
    const backOk = BACK.some((n) => m.quality[n] === 'ok');
    let quality, reason;
    if (stale) {
      quality = 'none';
      reason = !frame ? 'No answer from the recorder' : `No data from the headband for ${Math.round(frame.age)} s`;
    } else if (!backOk) {
      quality = 'poor';
      reason = BACK.some((n) => m.quality[n] === 'noisy') ? 'Back electrodes (O1, O2) moving' : 'Back electrodes (O1, O2) not touching';
    } else if (this.phase === 'cal-open') {
      quality = 'learning'; reason = `Calibrating: eyes open, look at one spot, jaw loose (${Math.ceil(this.t0 + CAL.openS - t)} s)`;
    } else if (this.phase === 'cal-closed') {
      quality = 'learning'; reason = `Calibrating: eyes closed, relax (${Math.ceil(this.t0 + CAL.openS + CAL.closedS - t)} s)`;
    } else if (!this.ref) {
      quality = 'learning'; reason = 'Learning your level';
    } else {
      quality = 'good'; reason = '';
    }

    // alpha on the person's scale, lightly smoothed (time constant 0.5 s)
    let alphaX = null;
    if (quality === 'good') {
      const raw = (m.alphaLog - this.ref.lo) / (this.ref.hi - this.ref.lo);
      const k = this.score === null ? 1 : 1 - Math.exp(-dt / RUN.scoreTau);
      this.score = this.score === null ? raw : this.score + (raw - this.score) * k;
      alphaX = 10 ** (m.alphaLog - this.ref.lo);
    } else this.score = null;

    const state = { alpha: this.score, jaw, quality };
    const targets = mapState(state);
    let ring = false;
    if (this.phase === 'run') ({ r: this.reward, ring } = rewardStep(this.reward, targets.calm, targets.bellsAllowed, dt));

    let bells = 'on';
    if (quality !== 'good') bells = 'off';
    else if (!SIDE.some((n) => m.quality[n] === 'ok')) bells = 'paused: side electrodes (T3, T4) not usable, so jaw cannot be checked';
    else if (jaw === null) bells = 'paused: learning your resting jaw';
    else if (jaw > JAW_BLOCK) bells = 'paused: jaw tense';

    return { phase: this.phase, cue, quality, reason, bells, note: this.note, state, targets, ring, alphaX,
      ref: this.ref, measures: m, hold: this.reward.hold };
  }

  finishCalibration() {
    const open = median(this.cal.open), closed = median(this.cal.closed);
    const enough = this.cal.open.length >= 20 && this.cal.closed.length >= 20;
    if (enough && closed - open >= CAL.minRise) {
      this.calRef = { lo: open, hi: closed, from: 'calibration' };
      this.note = `calibrated: eyes closed gave ${(10 ** (closed - open)).toFixed(1)}x eyes-open alpha`;
    } else {
      this.note = enough
        ? `no clear alpha rise with eyes closed (${(10 ** (closed - open)).toFixed(1)}x the eyes-open level); using your recent range`
        : 'calibration had too little clean signal; using your recent range';
    }
  }
}
