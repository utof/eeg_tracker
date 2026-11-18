// Smoothing mixer (separate from the mapping, also pure: state lives in the returned object).
// Each setting follows its target with its own time constants (seconds) for rising and falling,
// so a clench roughens fast and fades slowly, and nothing clicks. The engine runs the same glide
// on the audio thread; this copy only mirrors it for the words on screen.
//
// Two sets (DECISIONS row 45): training = fast bed (0.25-0.3 s, warmth 1.5 s), so the sound answers
// within about 0.3 s; relax = the slower, smoother bed of before (about 1 s).
//
// Port notes (Dart): a map of [rise, fall] per setting; step() is one exponential update.
export const MIX_TIMES = {
  training: {
    calm: [0.25, 0.25],
    rain: [0.25, 0.25],
    rainTone: [0.3, 0.3],
    drone: [0.3, 0.3],
    warmth: [1.5, 1.5],
    droneTone: [0.3, 0.3],
    rough: [0.08, 1.2],
  },
  relax: {
    calm: [0.8, 0.8],
    rain: [0.9, 1.2],
    rainTone: [0.9, 1.2],
    drone: [1.0, 1.0],
    warmth: [1.0, 1.0],
    droneTone: [1.0, 1.0],
    rough: [0.08, 1.2],
  },
};

export function createMixer(initial, times = MIX_TIMES.training) {
  const v = {};
  for (const k of Object.keys(times)) v[k] = initial[k];
  return {
    values: v,
    step(target, dt) {
      for (const [k, [up, down]] of Object.entries(times)) {
        const t = target[k];
        if (!Number.isFinite(t)) continue;
        const tau = t > v[k] ? up : down;
        v[k] += (t - v[k]) * (1 - Math.exp(-dt / tau));
      }
      return { ...v };
    },
  };
}
