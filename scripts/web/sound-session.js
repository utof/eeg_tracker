// The feedback core: samples in, sound settings and bells out. One listening session.
// Pure and sample-driven: it never reads a clock. Time is the number of samples received, and every
// decision is taken at fixed steps of 25 samples (0.1 s), so the output depends only on the samples,
// not on how they were chunked or when they arrived. That is what makes a logged session replay
// bit for bit (sound-log.js, replaySession in sound-source.js).
//
// Flow per step: quality per channel -> muscle, blink and drift-to-sleep gates -> alpha against the
// target line (z) -> sound settings (S-curve) -> block-wise line -> bell rule. DECISIONS rows 41-47.
//
// Phases: 'cal-open' (30 s eyes open, silent) -> 'cal-closed' (60 s eyes closed, silent) -> 'run';
// without calibration: 'learn' (the first 60 s with eyes closed, neutral sound) -> 'run'.
// Calibration ends only once it has 30 s of clean eyes-closed signal.
//
// Port notes (Dart): one class; push() takes a list of [O1, O2, T3, T4] rows in µV and returns the
// steps made. Values are rounded to float32 on entry (Float32List) so the log holds exactly what was used.

import { FS, NAMES, BACK, SIDE, ALPHA, THETA, MUSCLE, MAINS, BandPower, SlowWave, Ring, channelQuality, spectrum, findPeak, percentile, median } from './sound-features.js';
import { SleepGuard, guardBaseline } from './sleep-guard.js';
import { firstLine, TargetLine, Bells } from './sound-reward.js';
import { mapState, JAW_BLOCK } from './sound-mapping.js';
import { SessionLog } from './sound-log.js';

export const STEP = 25;                 // samples per analysis step
export const STEP_S = STEP / FS;        // 0.1 s
export const CAL = { openS: 30, closedS: 60, learnS: 60, settleS: 5, minCleanS: 30, minRise: Math.log10(1.5) };
export const RUN = { settleS: 1, holdS: 0.5, peakWinS: 4, primeS: 2 };
// muscle gate: the group's 30-45 Hz power against its resting level, the 20th percentile of its own last
// 2 minutes (a median would be dragged up by a clench lasting half that time); 2x rest = 0, 10x rest = 1
export const MUSCLE_GATE = { restS: 120, minS: 8, restPct: 0.2, minX: 2, spanX: 5 };
// blink gate: slow wave on O1/O2 over 40 µV and over 5x its usual size (median of the last minute)
export const BLINK = { minUv: 40, x: 5, restS: 60 };
// personal alpha band: peak of the eyes-closed spectrum in 7-13 Hz, standing 2x above the median of 6-14 Hz
export const IAF = { lo: 7, hi: 13, specLo: 6, specHi: 14, minRatio: 2, half: 2, thetaLo: 3 };

const LOG_FLOOR = 1e-6;
const log10 = (v) => Math.log10(Math.max(LOG_FLOOR, v));
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const r3 = (v) => (v === null || v === undefined ? null : Math.round(v * 1000) / 1000 + 0);  // + 0: no -0 (JSON writes it as 0)
const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;

export class Session {
  constructor({ mode = 'training', calibrate = true } = {}) {
    this.mode = mode; this.calibrate = calibrate;
    this.log = new SessionLog({ mode, calibrate, fs: FS, names: NAMES, step: STEP });
    this.n = 0; this.steps = 0; this.contactOhms = undefined;
    this.rings = NAMES.map(() => new Ring(FS * 8));
    this.bands = { alpha: ALPHA, theta: THETA };
    this.makeFilters();
    this.muscle = { side: { hist: [], rest: null }, back: { hist: [], rest: null } };
    this.blinkHist = []; this.blinkSecond = []; this.blinkRest = null;
    this.muscleUntil = -1; this.blinkUntil = -1;
    this.settleUntil = RUN.settleS * FS; this.lastGap = 0;
    this.note = calibrate ? '' : 'calibration skipped: the first minute with eyes closed is your baseline';
    this.line = null; this.bells = null; this.guard = null; this.rung = 0;
    this.startPhase(calibrate ? 'cal-open' : 'learn');
  }

  makeFilters() {
    this.alpha = BACK.map(() => new BandPower(...this.bands.alpha));
    this.theta = BACK.map(() => new BandPower(...this.bands.theta));
    this.musclePow = NAMES.map(() => new BandPower(...MUSCLE, { notch: MAINS, quadrature: false, tau: 0.25 }));
    this.slow = BACK.map(() => new SlowWave());
    this.slowMax = BACK.map(() => 0);
  }

  startPhase(phase) {
    this.phase = phase; this.phaseN = this.n;
    if (phase !== 'run') {
      this.cal = this.cal || {};
      const kind = phase === 'cal-open' ? 'open' : 'closed';
      this.cal[kind] = { raw: BACK.map(() => []), steps: [], spec: null, specN: 0 };
      this.calKind = kind;
    }
  }

  // ---- inputs (each one is logged, so a replay can repeat it at the same sample) ----

  // rows: [[O1, O2, T3, T4], ...] in µV. Returns the steps completed by these samples.
  push(rows) {
    const out = [];
    for (const r of rows) {
      const row = [Math.fround(r[0]), Math.fround(r[1]), Math.fround(r[2]), Math.fround(r[3])];
      this.log.sample(row);
      this.feed(row);
      if (this.n % STEP === 0) out.push(this.step());
    }
    return out;
  }

  // the stream had a hole (dropped link, recorder restart): restart the filters and settle 1 s
  gap() {
    this.log.line({ type: 'gap', n: this.n });
    this.makeFilters();
    if (this.guard) this.guard.reset();
    this.settleUntil = this.n + RUN.settleS * FS; this.lastGap = this.n;
  }

  // contact per channel from the recorder: {O1: ohms | null (no contact), ...}; undefined = unknown
  contact(c) {
    this.log.line({ type: 'contact', n: this.n, contact: c ?? null });
    this.contactOhms = c ?? undefined;
  }

  feed(row) {
    for (let c = 0; c < 4; c++) { this.rings[c].push(row[c]); this.musclePow[c].step(row[c]); }
    for (let b = 0; b < BACK.length; b++) {
      const v = row[BACK[b]];
      this.alpha[b].step(v); this.theta[b].step(v);
      this.slowMax[b] = Math.max(this.slowMax[b], Math.abs(this.slow[b].step(v)));
      if (this.phase !== 'run') this.cal[this.calKind].raw[b].push(v);
    }
    this.n++;
  }

  // ---- one analysis step ----

  step() {
    this.steps++;
    const t = this.n / FS, phase = this.phase;
    const q = NAMES.map((name, c) => channelQuality(this.rings[c].last(FS), this.contactOhms ? this.contactOhms[name] : undefined));
    const back = BACK.map((c, b) => (q[c] === 'ok' ? b : -1)).filter((b) => b >= 0);
    const side = SIDE.filter((c) => q[c] === 'ok');
    const jaw = this.muscleScore('side', side), backMuscle = this.muscleScore('back', back.map((b) => BACK[b]));
    const blink = this.blinkCheck(back);
    if ((jaw ?? 0) > JAW_BLOCK || (backMuscle ?? 0) > JAW_BLOCK) this.muscleUntil = this.n + RUN.holdS * FS;
    if (blink) this.blinkUntil = this.n + RUN.holdS * FS;
    const muscleOn = this.n <= this.muscleUntil, blinkOn = this.n <= this.blinkUntil;

    const alphaPow = back.length ? mean(back.map((b) => this.alpha[b].value)) : null;
    const thetaPow = back.length ? mean(back.map((b) => this.theta[b].value)) : null;
    const alphaLog = alphaPow === null ? null : log10(alphaPow);

    let quality = 'good', reason = '';
    if (!back.length) {
      quality = 'poor';
      reason = BACK.some((c) => q[c] === 'noisy') ? 'Back electrodes (O1, O2) moving' : 'Back electrodes (O1, O2) not touching';
    } else if (this.n <= this.settleUntil) {
      quality = 'settling'; reason = 'Settling the signal (1 s)';
    } else if (phase !== 'run') {
      quality = 'learning'; reason = this.calReason();
    }
    const settled = quality !== 'poor' && quality !== 'settling';

    if (phase !== 'run') {
      this.calStep(back, settled && !muscleOn && !blinkOn && this.n - this.phaseN >= CAL.settleS * FS);
    }

    let veto = null, drowsy = null, z = null;
    if (phase === 'run' && quality === 'good') {
      if (!muscleOn && !blinkOn) {
        drowsy = this.guard.update(alphaPow, thetaPow);
        if (this.steps % Math.round(1 / STEP_S) === 0) this.guard.peak(this.alphaPeak(back, IAF.specLo, IAF.specHi).hz);
      } else drowsy = this.guard.state;
      veto = muscleOn ? 'muscle' : blinkOn ? 'blink' : drowsy.drowsy ? 'drowsy' : null;
      z = this.line.z(alphaLog);
      if (veto) reason = vetoReason(veto, jaw, backMuscle);
    }

    const targets = mapState({ z, jaw, quality, veto });
    let ring = false, blockEnd = null;
    if (phase === 'run') {
      const counted = quality === 'good' && !veto;
      blockEnd = this.line.update(counted ? z > 0 : null, STEP_S);
      ring = this.bells.update(counted && jaw !== null, z !== null && z > 0);
      if (ring) this.rung++;
    }

    const silent = phase === 'cal-open' || phase === 'cal-closed';
    this.log.line({ type: 'step', n: this.n, q: quality, v: veto, z: r3(z), calm: r3(targets.calm), rough: r3(targets.rough),
      ...(silent ? { s: 1 } : {}), ...(ring ? { ring: 1 } : {}) });
    if (blockEnd) this.log.line({ type: 'block', n: this.n, ...roundBlock(blockEnd) });
    if (ring) this.log.line({ type: 'bell', n: this.n, z: r3(z) });
    const cue = this.advancePhase();   // phase changes take effect from the next sample on
    if (cue) this.log.line({ type: 'cue', n: this.n, cue });

    return { n: this.n, t, phase, cue, silent, quality, reason, veto, z, jaw, backMuscle, drowsy, targets, ring, blockEnd,
      alphaX: z === null ? null : 10 ** (alphaLog - this.line.line), block: this.line ? this.line.block : null, bands: this.bands,
      bells: this.bellWords(phase, quality, veto, jaw, side), note: this.note, rung: this.rung,
      lastMinute: this.bells ? this.bells.lastMinute : 0, channels: Object.fromEntries(NAMES.map((nm, c) => [nm, q[c]])) };
  }

  advancePhase() {
    const inPhase = (this.n - this.phaseN) / FS;
    if (this.phase === 'cal-open' && inPhase >= CAL.openS) { this.startPhase('cal-closed'); return 'close-eyes'; }
    const minS = this.phase === 'cal-closed' ? CAL.closedS : CAL.learnS;
    if ((this.phase === 'cal-closed' || this.phase === 'learn') && inPhase >= minS && this.cleanSteps() * STEP_S >= CAL.minCleanS) {
      const wasCal = this.phase === 'cal-closed';
      this.finishBaseline();
      return wasCal ? 'calibration-done' : null;
    }
    return null;
  }

  cleanSteps() { return this.cal.closed.steps.filter((s) => s.clean).length; }

  calReason() {
    const inPhase = (this.n - this.phaseN) / FS;
    if (this.phase === 'cal-open') return `Calibrating: eyes open, look at one spot, jaw loose (${Math.ceil(CAL.openS - inPhase)} s)`;
    const left = (this.phase === 'learn' ? CAL.learnS : CAL.closedS) - inPhase;
    if (left > 0) return this.phase === 'learn' ? `Close your eyes. Learning your level (${Math.ceil(left)} s)` : `Calibrating: eyes closed, relax (${Math.ceil(left)} s)`;
    return `Keep your eyes closed: needs ${Math.ceil(CAL.minCleanS - this.cleanSteps() * STEP_S)} s more clean signal`;
  }

  // ---- gates ----

  // group: 'side' (T3, T4) or 'back' (O1, O2); chans: usable channel indexes. 0 = relaxed, 1 = clenched, null = unknown.
  muscleScore(group, chans) {
    const g = this.muscle[group];
    if (!chans.length) return null;
    const lp = log10(mean(chans.map((c) => this.musclePow[c].value)));
    g.hist.push(lp);
    if (g.hist.length > MUSCLE_GATE.restS / STEP_S) g.hist.shift();
    if (this.steps % Math.round(1 / STEP_S) === 0 && g.hist.length >= MUSCLE_GATE.minS / STEP_S) {
      g.rest = percentile(g.hist, MUSCLE_GATE.restPct);
    }
    return g.rest === null ? null : clamp01((lp - g.rest - Math.log10(MUSCLE_GATE.minX)) / Math.log10(MUSCLE_GATE.spanX));
  }

  blinkCheck(back) {
    const amp = back.length ? Math.max(...back.map((b) => this.slowMax[b])) : null;
    this.slowMax = BACK.map(() => 0);
    if (amp === null) return false;
    this.blinkSecond.push(amp);
    if (this.blinkSecond.length >= Math.round(1 / STEP_S)) {
      this.blinkHist.push(median(this.blinkSecond)); this.blinkSecond = [];
      if (this.blinkHist.length > BLINK.restS) this.blinkHist.shift();
      this.blinkRest = median(this.blinkHist);
    }
    return amp > Math.max(BLINK.minUv, BLINK.x * (this.blinkRest ?? 0));
  }

  // alpha peak of the last 4 s (mean spectrum of the usable back channels), or hz null
  alphaPeak(back, lo, hi) {
    const k = RUN.peakWinS * FS;
    if (!back.length || this.n - this.lastGap < k) return { hz: null, ratio: 0, spec: null };
    const spec = meanSpectrum(back.map((b) => spectrum(this.rings[BACK[b]].last(k), FS, IAF.specLo, IAF.specHi)));
    const p = findPeak(spec, lo, hi);
    return { hz: p.ratio >= IAF.minRatio ? p.hz : null, ratio: p.ratio, spec };
  }

  // ---- calibration and baseline ----

  calStep(back, clean) {
    const c = this.cal[this.calKind];
    c.steps.push({ clean: clean && back.length > 0, ok: BACK.map((_, b) => back.includes(b)) });
    if (this.calKind === 'closed' && clean && this.steps % Math.round(1 / STEP_S) === 0) {
      const p = this.alphaPeak(back, IAF.lo, IAF.hi);
      if (p.spec && this.n - this.phaseN >= RUN.peakWinS * FS) {
        c.spec = c.spec ? c.spec.map((v, i) => v + p.spec.p[i]) : p.spec.p.slice(); c.specF = p.spec.f; c.specN++;
      }
    }
  }

  finishBaseline() {
    const closed = this.cal.closed, open = this.cal.open || null;
    let iaf = null, ratio = 0;
    if (closed.specN) {
      const pk = findPeak({ f: closed.specF, p: closed.spec }, IAF.lo, IAF.hi);
      ratio = pk.ratio;
      if (pk.hz !== null && pk.ratio >= IAF.minRatio) iaf = pk.hz;
    }
    this.bands = iaf === null ? { alpha: ALPHA, theta: THETA }
      : { alpha: [iaf - IAF.half, iaf + IAF.half], theta: [Math.max(IAF.thetaLo, iaf - 6), iaf - IAF.half] };

    // the line and the sleep guard's baseline come from the eyes-closed part, re-filtered with the personal band
    const c = rerun(closed, this.bands);
    const logs = c.alpha.filter((_, i) => c.clean[i]).map(log10);
    const first = firstLine(logs);
    const gb = guardBaseline(c.alpha, c.theta, c.clean, iaf, STEP_S);
    let rise = null;
    if (open) {
      const o = rerun(open, this.bands), oLogs = o.alpha.filter((_, i) => o.clean[i]).map(log10);
      if (oLogs.length >= 100) rise = median(logs) - median(oLogs);
    }

    // live filters with the personal band, warmed up on the last 2 s so they start settled
    this.makeFilters();
    const prime = RUN.primeS * FS;
    for (let b = 0; b < BACK.length; b++) {
      for (const v of this.rings[BACK[b]].last(prime)) { this.alpha[b].step(v); this.theta[b].step(v); this.slow[b].step(v); }
    }
    for (let ch = 0; ch < 4; ch++) for (const v of this.rings[ch].last(prime)) this.musclePow[ch].step(v);

    this.line = new TargetLine(first, STEP_S);
    this.bells = new Bells(this.mode, STEP_S);
    this.guard = new SleepGuard(gb, STEP_S);
    const band = `${fmt(this.bands.alpha[0])}-${fmt(this.bands.alpha[1])} Hz`;
    const peakWords = iaf === null ? `no clear alpha peak, using ${band}` : `your alpha peak ${fmt(iaf)} Hz, band ${band}`;
    const riseWords = rise === null ? '' : rise >= CAL.minRise ? `; eyes closed gave ${(10 ** rise).toFixed(1)}x eyes-open alpha`
      : `; eyes closed gave only ${(10 ** rise).toFixed(1)}x eyes-open alpha, so the sound may not follow you well`;
    this.note = (this.calibrate ? 'calibrated: ' : 'baseline from the first minute: ') + peakWords + riseWords;
    this.log.line({ type: 'calibration', n: this.n, iaf, peakRatio: r3(ratio), alpha: this.bands.alpha, theta: this.bands.theta,
      line: first.line, sd: first.sd, cleanS: r3(logs.length * STEP_S), rise: r3(rise), guard: gb });
    this.startPhase('run');
  }

  bellWords(phase, quality, veto, jaw, side) {
    if (phase !== 'run' || quality !== 'good') return 'off';
    if (veto) return 'paused';
    if (!side.length) return 'paused: side electrodes (T3, T4) not usable, so jaw cannot be checked';
    if (jaw === null) return 'paused: learning your resting jaw';
    return 'on';
  }
}

function vetoReason(veto, jaw, backMuscle) {
  if (veto === 'muscle') return (jaw ?? 0) > JAW_BLOCK ? 'Jaw tense: bells paused, sound neutral' : 'Muscle at the back of the head (neck?): bells paused';
  if (veto === 'blink') return 'Blink or eye movement: paused for a moment';
  return 'Alpha slowed or faded (drifting toward sleep, or eyes open): the sound brightens a little';
}

// Re-filter one calibration phase with the final bands: per step, mean alpha and theta power of the
// channels that were usable at that step, and whether the step was clean.
function rerun(phase, bands) {
  const alpha = [], theta = [], clean = [];
  const fa = BACK.map(() => new BandPower(...bands.alpha)), ft = BACK.map(() => new BandPower(...bands.theta));
  for (let s = 0; s < phase.steps.length; s++) {
    for (let b = 0; b < BACK.length; b++) {
      const raw = phase.raw[b];
      for (let i = s * STEP; i < (s + 1) * STEP && i < raw.length; i++) { fa[b].step(raw[i]); ft[b].step(raw[i]); }
    }
    const ok = phase.steps[s].ok, use = BACK.map((_, b) => b).filter((b) => ok[b]);
    alpha.push(use.length ? mean(use.map((b) => fa[b].value)) : 0);
    theta.push(use.length ? mean(use.map((b) => ft[b].value)) : 0);
    clean.push(phase.steps[s].clean);
  }
  return { alpha, theta, clean };
}

function meanSpectrum(specs) {
  return { f: specs[0].f, p: specs[0].p.map((_, i) => mean(specs.map((s) => s.p[i]))) };
}
function roundBlock(b) { return { block: b.block, share: r3(b.share), counted: r3(b.counted), from: b.from, to: b.to, moved: b.moved }; }
const fmt = (v) => (Math.round(v * 4) / 4).toString();
