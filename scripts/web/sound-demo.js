// Built-in synthetic headband for demo mode, so sound.html works with no recorder.
// Same recipe as tests/fake_neurosdk (µV here): O1/O2 10 Hz alpha strong when "eyes closed", weak
// when open; T3/T4 3 s bursts of fast muscle noise every 45 s; a blink-like bump every 7 s.
// Eyes: follow `eyes` when set ('open' | 'closed'), otherwise closed 60 s, open 60 s, from the start.

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

export class DemoSignal {
  constructor(seed = 1) {
    this.gauss = rng(seed); this.n = 0; this.buf = NAMES.map(() => []);
    this.eyes = null; this.jawUntil = -1; this.t = 0;
  }

  closed(t) { return this.eyes ? this.eyes === 'closed' : autoEyesClosed(t); }
  jaw(t) { return autoJaw(t) || t < this.jawUntil; }

  sample(t) {
    const g = this.gauss;
    const alpha = (this.closed(t) ? 25 : 6) * Math.sin(2 * Math.PI * 10 * t);
    const jaw = this.jaw(t) ? 40 * g() : 0;
    const blink = 80 * Math.exp(-((((t % 7) - 0.15) / 0.08) ** 2));
    return [alpha + blink + 4 * g(), 0.9 * alpha + blink + 4 * g(), jaw + 0.3 * blink + 4 * g(), jaw + 0.3 * blink + 4 * g()];
  }

  // Advance to time t (seconds since start) and return a frame shaped like GET /state.
  frame(t) {
    const end = Math.floor(t * FS);
    if (end - this.n > FS * 4) this.n = end - FS * 4;
    for (; this.n < end; this.n++) {
      const s = this.sample(this.n / FS);
      s.forEach((v, c) => this.buf[c].push(v));
    }
    for (const b of this.buf) if (b.length > FS * 4) b.splice(0, b.length - FS * 4);
    this.t = t;
    return { fs: FS, names: NAMES, data: this.buf.map((b) => b.slice()), contact: undefined, age: 0 };
  }
}
