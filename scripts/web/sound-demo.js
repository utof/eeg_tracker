// Built-in synthetic headband for demo mode and the tests, so the sound works with no recorder.
// Recipe of tests/fake_neurosdk (µV here): O1/O2 alpha strong when "eyes closed", weak when open;
// T3/T4 3 s bursts of fast muscle noise every 45 s; a blink-like bump every 7 s. Two additions:
// the alpha amplitude wanders slowly (+-30 %, loops of 3.1, 5.3 and 8.9 s) like real alpha that
// comes and goes, and its frequency can be lowered (alphaHz) to imitate drifting toward sleep.
// Eyes: follow `eyes` when set ('open' | 'closed'), otherwise closed 60 s, open 60 s, from the start.
//
// Port notes (Dart): seeded generator (mulberry32 + Box-Muller) so a seed gives the same signal everywhere.

export const FS = 250;
export const NAMES = ['O1', 'O2', 'T3', 'T4'];

function rng(seed) {  // mulberry32 + Box-Muller
  let a = seed >>> 0;
  const u = () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  return () => Math.sqrt(-2 * Math.log(u() || 1e-12)) * Math.cos(2 * Math.PI * u());
}

export const autoEyesClosed = (t) => Math.floor(t / 60) % 2 === 0;
export const autoJaw = (t) => t % 45 < 3;
export const wander = (t) => 1 + 0.3 * (0.5 * Math.sin((2 * Math.PI * t) / 3.1) + 0.3 * Math.sin((2 * Math.PI * t) / 5.3 + 1)
  + 0.2 * Math.sin((2 * Math.PI * t) / 8.9 + 2));

export class DemoSignal {
  constructor(seed = 1) {
    this.gauss = rng(seed); this.n = 0; this.phase = 0;
    this.eyes = null; this.jawUntil = -1;
    this.alphaHz = 10; this.alphaGain = 1; this.wanders = true; this.blinks = true; this.jawBursts = true;
  }

  get t() { return this.n / FS; }
  closed(t) { return this.eyes ? this.eyes === 'closed' : autoEyesClosed(t); }
  jaw(t) { return (this.jawBursts && autoJaw(t)) || t < this.jawUntil; }

  sample(t) {
    const g = this.gauss;
    this.phase = (this.phase + (2 * Math.PI * this.alphaHz) / FS) % (2 * Math.PI);
    const alpha = (this.closed(t) ? 25 : 6) * this.alphaGain * (this.wanders ? wander(t) : 1) * Math.sin(this.phase);
    const jaw = this.jaw(t) ? 40 * g() : 0;
    const blink = this.blinks ? 80 * Math.exp(-((((t % 7) - 0.15) / 0.08) ** 2)) : 0;
    return [alpha + blink + 4 * g(), 0.9 * alpha + blink + 4 * g(), jaw + 0.3 * blink + 4 * g(), jaw + 0.3 * blink + 4 * g()];
  }

  // the next k samples, [[O1, O2, T3, T4], ...] in µV
  next(k) {
    const rows = [];
    for (let i = 0; i < k; i++) { rows.push(this.sample(this.n / FS)); this.n++; }
    return rows;
  }
}
