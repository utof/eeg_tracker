// Brain measures from one short window of signal (pure functions, no browser needed).
// Input samples are in µV, as GET /state sends them. Used by sound.html and the node tests.

export const ALPHA = [8, 12];   // Hz, back of the head (O1, O2), rises with eyes closed and relaxed
export const JAW = [30, 45];    // Hz, sides (T3, T4): jaw and temple muscle; stops below 50 Hz mains hum
export const BACK = ['O1', 'O2'];
export const SIDE = ['T3', 'T4'];

// Power in a band, µV², from a Hann-windowed DFT of x (mean removed). A sine of amplitude A inside
// the band gives about A²/2. With a 1 s window the bins are 1 Hz apart.
export function bandPower(x, fs, lo, hi) {
  const N = x.length;
  if (N < 8) return 0;
  let mean = 0;
  for (const v of x) mean += v;
  mean /= N;
  const w = new Float64Array(N);
  let s2 = 0;
  for (let i = 0; i < N; i++) { w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (N - 1)); s2 += w[i] * w[i]; }
  const df = fs / N;
  let total = 0;
  for (let k = Math.ceil(lo / df - 1e-9); k * df <= hi + 1e-9; k++) {
    let re = 0, im = 0;
    const a = (2 * Math.PI * k) / N;
    for (let i = 0; i < N; i++) { const v = (x[i] - mean) * w[i]; re += v * Math.cos(a * i); im -= v * Math.sin(a * i); }
    total += ((2 * (re * re + im * im)) / (fs * s2)) * df;
  }
  return total;
}

// 'ok', 'off' (no contact or a flat line) or 'noisy' (movement: swings over 300 µV in the window).
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

// One analysis step. frame = {fs, names, data: [[µV...] per channel], contact: {O1: ohms|null, ...}}.
// Uses the last windowS seconds. Returns log10 band powers from the channels that are ok
// (null when none is), and the quality of each channel.
export function measure(frame, windowS = 1) {
  const n = Math.round(frame.fs * windowS);
  const quality = {}, alpha = [], jaw = [];
  frame.names.forEach((name, c) => {
    const all = frame.data[c] || [];
    const x = all.length >= n ? all.slice(all.length - n) : [];
    const q = channelQuality(x.length ? x : null, frame.contact ? frame.contact[name] : undefined);
    quality[name] = q;
    if (q !== 'ok') return;
    if (BACK.includes(name)) alpha.push(bandPower(x, frame.fs, ...ALPHA));
    if (SIDE.includes(name)) jaw.push(bandPower(x, frame.fs, ...JAW));
  });
  const logMean = (a) => (a.length ? Math.log10(Math.max(1e-6, a.reduce((s, v) => s + v, 0) / a.length)) : null);
  return { alphaLog: logMean(alpha), jawLog: logMean(jaw), quality };
}
