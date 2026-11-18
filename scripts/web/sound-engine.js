// Web Audio ambient engine: a warm drone, a rain/wind noise layer, reward bells.
// Every slow movement uses loops of unequal length (prime-ish seconds), so the mix never repeats
// the same way. Settings come from the mapping (sound-mapping.js); this file only turns them into sound.
// Smoothness: the page's timers never touch the sound sample by sample. glide() hands each new target
// to the audio thread once (setTargetAtTime with the mixer's rise/fall times), and the audio thread
// moves there smoothly on its own, so a busy or throttled page cannot make the sound step or stutter.
import { MIX_TIMES } from './sound-mixer.js';

const ROOT = 110;  // A2
// drone partials: [frequency, level, LFO period s, part of "warmth"]
const PARTIALS = [
  [ROOT / 2, 0.55, 23, true],       // low octave
  [ROOT, 0.7, 17, false],
  [ROOT * 1.5, 0.35, 29, false],    // fifth
  [ROOT * 2, 0.3, 37, false],
  [ROOT * 2.52, 0.18, 31, true],    // major third, an octave up
];
const BELL_NOTES = [440, 554.37, 659.25, 493.88, 739.99, 587.33, 830.61];  // A major pentatonic-ish
const BELL_ORDER = [0, 2, 1, 4, 2, 6, 3, 0, 5, 2, 1];                      // 11 steps against the 7 notes

function noiseBuffer(ctx, seconds, kind) {
  const n = Math.floor(ctx.sampleRate * seconds), buf = ctx.createBuffer(2, n, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    let b0 = 0, b1 = 0, b2 = 0, br = 0;
    for (let i = 0; i < n; i++) {
      const w = Math.random() * 2 - 1;
      if (kind === 'pink') {  // Paul Kellet's economy pink filter
        b0 = 0.99765 * b0 + w * 0.099046; b1 = 0.963 * b1 + w * 0.2965164; b2 = 0.57 * b2 + w * 1.0526913;
        d[i] = (b0 + b1 + b2 + w * 0.1848) * 0.18;
      } else { br = (br + 0.02 * w) / 1.02; d[i] = br * 3.5; }
    }
    // short crossfade so the loop point does not click
    const f = Math.min(2000, n >> 2);
    for (let i = 0; i < f; i++) { const a = i / f; d[n - f + i] = d[n - f + i] * (1 - a) + d[i] * a; }
  }
  return buf;
}

function impulse(ctx, seconds) {
  const n = Math.floor(ctx.sampleRate * seconds), buf = ctx.createBuffer(2, n, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n) ** 3;
  }
  return buf;
}

function lfo(ctx, periodS, depth, target) {
  const o = ctx.createOscillator(), g = ctx.createGain();
  o.frequency.value = 1 / periodS;
  g.gain.value = depth; o.connect(g).connect(target); o.start();
  return o;
}

// light: for phones. No convolution reverb (the heaviest part) and no compressor: a small feedback-delay
// room instead, and no pitch-drift LFOs. Same layers, same reactions, about a third of the audio work.
export const isPhone = () => typeof navigator !== 'undefined' && /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent);

export class AmbientEngine {
  constructor({ light = false } = {}) { this.light = light; }

  // ctx: an OfflineAudioContext for tests and speed checks; by default a live one with large buffers
  // ('playback': ~0.1 s more delay, far fewer dropouts on a busy machine; nothing here needs speed).
  async start(ctx = new AudioContext({ latencyHint: 'playback' })) {
    this.ctx = ctx; this.sent = {};
    if (typeof AudioContext !== 'undefined' && ctx instanceof AudioContext && ctx.state !== 'running') await ctx.resume();
    const now = ctx.currentTime;

    this.master = ctx.createGain(); this.master.gain.value = 0;
    if (this.light) {
      this.master.connect(ctx.destination);
    } else {
      const comp = ctx.createDynamicsCompressor();
      comp.threshold.value = -18; comp.ratio.value = 3;
      this.master.connect(comp).connect(ctx.destination);
    }
    this.master.gain.setTargetAtTime(this.light ? 0.85 : 0.8, now, 0.8);   // fade in (levels match: same loudness both ways)

    // room: everything sent to this.verb (mono)
    this.verb = ctx.createGain(); this.verb.channelCount = 1; this.verb.channelCountMode = 'explicit';
    if (this.light) {  // two short delays feeding back through a low-pass: a soft room, nearly free
      const wet = ctx.createGain(); wet.gain.value = 0.25; wet.connect(this.master);
      for (const [d, fb] of [[0.043, 0.55], [0.067, 0.5]]) {
        const dl = ctx.createDelay(0.2), lp = ctx.createBiquadFilter(), g = ctx.createGain();
        dl.delayTime.value = d; lp.type = 'lowpass'; lp.frequency.value = 2200; g.gain.value = fb;
        this.verb.connect(dl); dl.connect(lp).connect(g).connect(dl); lp.connect(wet);
      }
    } else {  // convolution reverb fed in mono (2 convolutions instead of 4 for a stereo input), 2.5 s tail
      const verb = ctx.createConvolver(); verb.buffer = impulse(ctx, 2.5);
      const wet = ctx.createGain(); wet.gain.value = 0.3; verb.connect(wet).connect(this.master);
      this.verb.connect(verb);
    }

    // roughness: tremolo at 33 Hz (heard as rough, not as a beat) on the drone and rain
    this.trem = ctx.createGain(); this.trem.gain.value = 1; this.trem.connect(this.master); this.trem.connect(this.verb);
    this.tremDepth = ctx.createGain(); this.tremDepth.gain.value = 0;
    const to = ctx.createOscillator(); to.frequency.value = 33; to.connect(this.tremDepth).connect(this.trem.gain); to.start();

    // drone
    this.droneFilter = ctx.createBiquadFilter(); this.droneFilter.type = 'lowpass'; this.droneFilter.Q.value = 0.6;
    this.droneGain = ctx.createGain(); this.droneGain.gain.value = 0.5;
    this.droneFilter.connect(this.droneGain).connect(this.trem);
    this.oscs = []; this.warmGains = [];
    PARTIALS.forEach(([f, level, period, warm], i) => {
      const o = ctx.createOscillator(); o.type = i === 1 ? 'triangle' : 'sine'; o.frequency.value = f;
      const g = ctx.createGain(); g.gain.value = level * 0.7;
      lfo(ctx, period, level * 0.3, g.gain);           // slow swell, unequal periods
      if (!this.light) lfo(ctx, period * 1.7, 3, o.detune);  // slow drift of a few cents
      const w = ctx.createGain(); w.gain.value = warm ? 0 : 1;
      o.connect(g).connect(w).connect(this.droneFilter); o.start();
      this.oscs.push(o); if (warm) this.warmGains.push(w);
    });

    // rain (pink noise, 9.7 s loop) and wind (brown noise, 13.3 s loop, moving band)
    this.rainGain = ctx.createGain(); this.rainGain.gain.value = 0.3; this.rainGain.connect(this.trem);
    const rain = ctx.createBufferSource(); rain.buffer = noiseBuffer(ctx, 9.7, 'pink'); rain.loop = true;
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 350;
    this.rainFilter = ctx.createBiquadFilter(); this.rainFilter.type = 'lowpass'; this.rainFilter.frequency.value = 2000;
    rain.connect(hp).connect(this.rainFilter).connect(this.rainGain); rain.start();
    const wind = ctx.createBufferSource(); wind.buffer = noiseBuffer(ctx, 13.3, 'brown'); wind.loop = true;
    const band = ctx.createBiquadFilter(); band.type = 'bandpass'; band.frequency.value = 420; band.Q.value = 0.8;
    lfo(ctx, 19, 180, band.frequency);
    const gust = ctx.createGain(); gust.gain.value = 0.55; lfo(ctx, 11, 0.25, gust.gain);
    wind.connect(band).connect(gust).connect(this.rainGain); wind.start();

    this.bellN = 0;
  }

  // target: settings from mapState(); now: the mixer's current values (to pick the rise or fall time).
  // Call whenever the target may have changed (4 times a second is plenty); unchanged settings are skipped.
  glide(target, now) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    for (const [key, [up, down]] of Object.entries(MIX_TIMES)) {
      const v = target[key];
      if (!Number.isFinite(v) || Math.abs(v - (this.sent[key] ?? Infinity)) < 1e-3 * Math.max(1, Math.abs(v))) continue;
      this.sent[key] = v;
      // the same first-order glide the mixer computes, but run by the audio thread
      const tau = v > (now?.[key] ?? v) ? up : down, go = (param, value) => param.setTargetAtTime(value, t, tau);
      if (key === 'rain') go(this.rainGain.gain, 0.55 * v);
      else if (key === 'rainTone') go(this.rainFilter.frequency, v);
      else if (key === 'drone') go(this.droneGain.gain, 0.5 * v);
      else if (key === 'droneTone') go(this.droneFilter.frequency, v);
      else if (key === 'warmth') for (const g of this.warmGains) go(g.gain, v);
      else if (key === 'rough') {
        go(this.tremDepth.gain, 0.45 * v); go(this.trem.gain, 1 - 0.45 * v);
        this.oscs.forEach((o, i) => go(o.frequency, PARTIALS[i][0] * (1 + (i % 2 ? 0.012 : -0.012) * v)));
      }
    }
  }

  // reward bell: inharmonic partials, slow decay, into the room
  bell() {
    if (!this.ctx) return;
    const f = BELL_NOTES[BELL_ORDER[this.bellN++ % BELL_ORDER.length]];
    this.tone(f, [[1, 1, 4.5], [2.76, 0.45, 2.2], [5.4, 0.2, 1.1], [8.93, 0.08, 0.6]], 0.11);
  }

  // calibration cue: one low, soft tone (different from the reward bell)
  cue() { if (this.ctx) this.tone(220, [[1, 1, 1.8], [2, 0.25, 1]], 0.14); }

  tone(f, parts, level) {
    const ctx = this.ctx, t = ctx.currentTime, out = ctx.createGain();
    out.gain.value = level; out.connect(this.master); out.connect(this.verb);
    for (const [ratio, amp, decay] of parts) {
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.frequency.value = f * ratio;
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(amp, t + 0.01);
      g.gain.exponentialRampToValueAtTime(0.0001, t + decay);
      o.connect(g).connect(out); o.start(t); o.stop(t + decay + 0.1);
    }
  }

  async stop() {
    if (!this.ctx) return;
    const ctx = this.ctx; this.ctx = null;
    this.master.gain.setTargetAtTime(0, ctx.currentTime, 0.4);
    await new Promise((r) => setTimeout(r, 1500));
    await ctx.close();
  }
}
