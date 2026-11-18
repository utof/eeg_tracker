// Smoothing mixer (separate from the mapping, also pure: state lives in the returned object).
// Each setting follows its target with its own time constants (seconds) for
// rising and falling, so a clench roughens fast and fades slowly, and nothing clicks.
export const MIX_TIMES = {
  calm: [0.8, 0.8],
  rain: [0.9, 1.2],
  rainTone: [0.9, 1.2],
  drone: [1.0, 1.0],
  warmth: [1.0, 1.0],
  droneTone: [1.0, 1.0],
  rough: [0.08, 1.2],
};

export function createMixer(initial, times = MIX_TIMES) {
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
