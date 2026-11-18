// Reward rules (research A pass 2, "Rewards: easy first, tighten between blocks, ring rarely").
// Pure: one call per analysis step; no clock, no randomness.
//
// Target line: starts at the 35th percentile of the person's eyes-closed baseline (about 65 % of
// the time above it at rest) and is HELD STILL for 3-minute blocks. Between blocks: above the line
// more than 80 % of the counted time -> raise it 0.15 robust SD; under 50 % -> lower it 0.15 SD.
// Steps under a gate (muscle, blink, drowsy, bad contact) are not counted. A target that chases the
// person every few seconds (to hold 80 % rewards) did no better than placebo, so it never moves inside a block.
//
// Bell: at least 3 s above the line within the last 4 s, with no gate anywhere in those 4 s;
// then at least 5 s (training) or 15 s (relax) since the last bell, and at most 6 bells in any minute.
//
// Port notes (Dart): two small classes with int counters; robust SD = 1.4826 x median absolute deviation.

import { percentile, median } from './sound-features.js';

export const LINE = { pct: 0.35, sdFloor: 0.1, blockS: 180, raiseAbove: 0.8, lowerBelow: 0.5, stepSd: 0.15, minCountedS: 30 };
export const BELL = { windowS: 4, aboveS: 3, gapS: { training: 5, relax: 15 }, perMinute: 6 };

// values: log10 alpha power of clean eyes-closed steps. sd is in the same log units, never under 0.1
// (a 26 % change), so a very steady signal does not make the sound jumpy.
export function firstLine(values) {
  const m = median(values), dev = values.map((v) => Math.abs(v - m));
  return { line: percentile(values, LINE.pct), sd: Math.max(LINE.sdFloor, 1.4826 * median(dev)) };
}

export class TargetLine {
  constructor({ line, sd }, stepS = 0.1) {
    this.line = line; this.sd = sd; this.block = 1;
    this.blockSteps = Math.round(LINE.blockS / stepS); this.minCounted = Math.round(LINE.minCountedS / stepS);
    this.steps = 0; this.counted = 0; this.above = 0;
  }

  // above: true / false, or null when the step is under a gate (not counted).
  // Returns null, or at the end of a block: {block, share, counted (s), from, to, moved: -1 | 0 | 1}.
  update(above, stepS = 0.1) {
    this.steps++;
    if (above !== null) { this.counted++; if (above) this.above++; }
    if (this.steps < this.blockSteps) return null;
    const share = this.counted ? this.above / this.counted : null, from = this.line;
    let moved = 0;
    if (this.counted >= this.minCounted) {
      if (share > LINE.raiseAbove) moved = 1;
      else if (share < LINE.lowerBelow) moved = -1;
    }
    this.line += moved * LINE.stepSd * this.sd;
    const out = { block: this.block, share, counted: this.counted * stepS, from, to: this.line, moved };
    this.block++; this.steps = 0; this.counted = 0; this.above = 0;
    return out;
  }

  // how far above the line, in robust SDs
  z(alphaLog) { return (alphaLog - this.line) / this.sd; }
}

export class Bells {
  constructor(mode = 'training', stepS = 0.1) {
    this.window = Math.round(BELL.windowS / stepS); this.need = Math.round(BELL.aboveS / stepS);
    this.gap = Math.round(BELL.gapS[mode] / stepS); this.minute = Math.round(60 / stepS);
    this.recent = [];   // above flags of the last clean steps (at most one window)
    this.rung = [];     // step numbers of the bells of the last minute
    this.step = 0;
  }

  // ok: no gate and good signal at this step; above: alpha above the line. Returns true to ring now.
  update(ok, above) {
    this.step++;
    while (this.rung.length && this.rung[0] <= this.step - this.minute) this.rung.shift();
    if (!ok) { this.recent = []; return false; }
    this.recent.push(above);
    if (this.recent.length > this.window) this.recent.shift();
    if (this.recent.length < this.window) return false;
    if (this.recent.filter(Boolean).length < this.need) return false;
    const last = this.rung.length ? this.rung[this.rung.length - 1] : -Infinity;
    if (this.step - last < this.gap || this.rung.length >= BELL.perMinute) return false;
    this.rung.push(this.step); this.recent = [];
    return true;
  }

  get lastMinute() { return this.rung.length; }
}
