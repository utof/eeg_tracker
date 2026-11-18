// Streaming brain measures, one sample at a time (pure: no browser, no clock).
// Input: µV at 250 Hz, channels O1 O2 T3 T4, as GET /stream sends them.
//
// Port notes (Dart): plain classes with numeric fields; Float32Array -> Float32List; Math.* -> dart:math.
// Each filter keeps its own state, so feeding the same samples gives the same numbers on any device.

export const FS = 250;
export const NAMES = ['O1', 'O2', 'T3', 'T4'];
export const BACK = [0, 1];        // O1, O2: alpha (eyes closed, relaxed)
export const SIDE = [2, 3];        // T3, T4: jaw and temple muscle
export const ALPHA = [8, 12];      // Hz, used when no personal alpha peak was found
export const THETA = [4, 8];       // Hz, same fallback
export const MUSCLE = [30, 45];    // Hz, below the 50 Hz mains hum (DECISIONS row 19)
export const MAINS = 50;           // Hz, notched out before the muscle band

const TAU_ALPHA = 0.05;   // s, smoothing of the alpha and theta envelopes (after a ~0.1 s band-pass)
const TAU_MUSCLE = 0.1;   // s, muscle power is noise-like, so it needs a little more averaging
const Q_PAIR = Math.sqrt(Math.SQRT2 - 1);  // two equal band-pass stages: -3 dB exactly at lo and hi

// One second-order IIR section (RBJ audio-EQ cookbook), transposed direct form II.
// c = [b0, b1, b2, a1, a2], already divided by a0.
export class Biquad {
  constructor(c) { this.c = c; this.z1 = 0; this.z2 = 0; }
  step(x) {
    const c = this.c, y = c[0] * x + this.z1;
    this.z1 = c[1] * x - c[3] * y + this.z2;
    this.z2 = c[2] * x - c[4] * y;
    return y;
  }
}

function norm(b0, b1, b2, a0, a1, a2) { return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]; }

// Band-pass with 0 dB at f0.
export function bandPassCoefs(f0, q, fs = FS) {
  const w = (2 * Math.PI * f0) / fs, al = Math.sin(w) / (2 * q), cw = Math.cos(w);
  return norm(al, 0, -al, 1 + al, -2 * cw, 1 - al);
}
export function notchCoefs(f0, q, fs = FS) {
  const w = (2 * Math.PI * f0) / fs, al = Math.sin(w) / (2 * q), cw = Math.cos(w);
  return norm(1, -2 * cw, 1, 1 + al, -2 * cw, 1 - al);
}
export function lowPassCoefs(f0, fs = FS) {
  const w = (2 * Math.PI * f0) / fs, al = Math.sin(w) / (2 * Math.SQRT1_2), cw = Math.cos(w);
  return norm((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + al, -2 * cw, 1 - al);
}

// Removes the electrode's DC offset (one-pole high-pass, about 0.16 Hz). Starts at the first sample,
// so a large offset does not ring through the band-pass filters after a start or a gap.
class DcBlock {
  constructor(tauS, fs) { this.k = 1 - Math.exp(-1 / (fs * tauS)); this.m = null; }
  step(x) {
    if (this.m === null) this.m = x;
    this.m += this.k * (x - this.m);
    return x - this.m;
  }
}

// Power in a band, µV², updated every sample. A sine of amplitude A inside the band gives A²/2.
// Two equal band-pass stages (about 0.1 s delay at 8-12 Hz). For narrow bands (alpha, theta) the
// envelope is taken from the signal and its slope (y² + (dy/dω)², exact for a sine at the centre
// frequency), so it barely ripples and needs only 0.05 s smoothing. Muscle is noise-like: plain y².
export class BandPower {
  constructor(lo, hi, { fs = FS, notch = 0, quadrature = true, tau = quadrature ? TAU_ALPHA : TAU_MUSCLE } = {}) {
    const f0 = Math.sqrt(lo * hi), q = (Q_PAIR * f0) / (hi - lo);
    this.lo = lo; this.hi = hi;
    this.dc = new DcBlock(1, fs);
    this.stages = [];
    if (notch) this.stages.push(new Biquad(notchCoefs(notch, 8, fs)));
    this.stages.push(new Biquad(bandPassCoefs(f0, q, fs)), new Biquad(bandPassCoefs(f0, q, fs)));
    this.quadrature = quadrature;
    this.twoSin = 2 * Math.sin((2 * Math.PI * f0) / fs);
    this.k = 1 - Math.exp(-1 / (fs * tau));
    this.y1 = 0; this.y2 = 0; this.value = 0;
  }
  step(x) {
    let y = this.dc.step(x);
    for (const s of this.stages) y = s.step(y);
    let p;
    if (this.quadrature) {
      const q = (y - this.y2) / this.twoSin;
      p = (this.y1 * this.y1 + q * q) / 2;
    } else p = y * y;
    this.y2 = this.y1; this.y1 = y;
    this.value += this.k * (p - this.value);
    return this.value;
  }
}

// Slow waves (blinks, eye movements): the signal under 4 Hz minus its 0.5 s mean, in µV.
// The forehead reference carries blinks into O1/O2 (BrainBit's reference pads sit on the forehead).
export class SlowWave {
  constructor(fs = FS) { this.dc = new DcBlock(0.5, fs); this.lp = new Biquad(lowPassCoefs(4, fs)); }
  step(x) { return this.lp.step(this.dc.step(x)); }
}

// Fixed-size history of one channel.
export class Ring {
  constructor(size) { this.a = new Float32Array(size); this.n = 0; }
  push(v) { this.a[this.n % this.a.length] = v; this.n++; }
  // the last k values (fewer if not yet there), oldest first
  last(k) {
    const m = Math.min(k, this.n, this.a.length), out = new Float32Array(m);
    for (let j = 0; j < m; j++) out[j] = this.a[(this.n - m + j) % this.a.length];
    return out;
  }
}

// 'ok', 'off' (no contact or a flat line) or 'noisy' (movement: swings over 300 µV in the last second).
// contactOhms: null = the recorder measured no contact; undefined = not known (demo), not held against it.
export function channelQuality(x, contactOhms) {
  if (contactOhms === null || !x || x.length === 0) return 'off';
  let lo = Infinity, hi = -Infinity;
  for (const v of x) { if (v < lo) lo = v; if (v > hi) hi = v; }
  const p2p = hi - lo;
  if (p2p < 1) return 'off';
  if (p2p > 300) return 'noisy';
  return 'ok';
}

// Power spectrum (any unit; only shapes are compared) at lo..hi Hz in steps of df, Hann window,
// mean removed. Goertzel per frequency, so the steps need not be whole bins.
export function spectrum(x, fs, lo, hi, df = 0.25) {
  const n = x.length, w = new Float64Array(n);
  let mean = 0;
  for (let i = 0; i < n; i++) mean += x[i];
  mean /= n;
  for (let i = 0; i < n; i++) w[i] = (x[i] - mean) * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1)));
  const f = [], p = [];
  for (let k = 0; lo + k * df <= hi + 1e-9; k++) {
    const hz = lo + k * df, c = 2 * Math.cos((2 * Math.PI * hz) / fs);
    let s1 = 0, s2 = 0;
    for (let i = 0; i < n; i++) { const s = w[i] + c * s1 - s2; s2 = s1; s1 = s; }
    f.push(hz); p.push(s1 * s1 + s2 * s2 - c * s1 * s2);
  }
  return { f, p };
}

// Highest point between lo and hi, and how far it stands above the median of the whole spectrum.
// hz is null when the top sits on the edge of lo..hi (no real peak inside).
export function findPeak(spec, lo, hi) {
  let best = -1;
  for (let i = 0; i < spec.f.length; i++) {
    if (spec.f[i] < lo - 1e-9 || spec.f[i] > hi + 1e-9) continue;
    if (best < 0 || spec.p[i] > spec.p[best]) best = i;
  }
  if (best < 0) return { hz: null, ratio: 0 };
  const sorted = [...spec.p].sort((a, b) => a - b), med = sorted[Math.floor(sorted.length / 2)];
  const edge = spec.f[best] < lo + 1e-9 || spec.f[best] > hi - 1e-9;
  return { hz: edge ? null : spec.f[best], ratio: med > 0 ? spec.p[best] / med : 0 };
}

export function percentile(a, p) {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y), i = (s.length - 1) * p, lo = Math.floor(i);
  return lo + 1 < s.length ? s[lo] + (s[lo + 1] - s[lo]) * (i - lo) : s[lo];
}
export const median = (a) => percentile(a, 0.5);
