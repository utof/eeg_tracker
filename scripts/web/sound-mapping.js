// Brain state -> sound settings. Pure functions: same input, same output; no audio, no time.
// This is the part to port to Dart (flutter_soloud) for the phone app.
//
// Brain state:
//   alpha   : back-of-head alpha on the person's own scale: 0 = their eyes-open level, 1 = their
//             eyes-closed level (can go below 0 or above 1); null = unknown.
//   jaw     : 0 = relaxed (30-45 Hz power at T3/T4 under 2x its resting level), 1 = clearly clenched
//             (10x or more); null = side electrodes not usable.
//   quality : 'good' (back electrodes usable), 'learning' (baseline not ready), 'poor' (back
//             electrodes off or moving), 'none' (no data).

export const NEUTRAL_CALM = 0.35;   // where the sound rests when it cannot follow the brain
export const JAW_BLOCK = 0.05;      // any jaw score above this blocks bells
export const REWARD = { level: 0.7, holdS: 3, lockS: 2 };

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const lerp = (a, b, t) => a + (b - a) * t;

// Layer settings for the engine. Gains are 0..1 before the engine's own level trims; tones in Hz.
export function mapState(s) {
  const usable = s.quality === 'good' && Number.isFinite(s.alpha);
  const calm = usable ? clamp01(s.alpha) : NEUTRAL_CALM;
  const jawKnown = Number.isFinite(s.jaw);
  const jaw = jawKnown ? clamp01(s.jaw) : 0;
  return {
    calm,
    rain: lerp(0.9, 0.12, calm),        // rain/wind quietens as alpha rises
    rainTone: lerp(3200, 900, calm),    // and gets darker
    drone: lerp(0.55, 0.85, calm),      // the drone comes forward
    warmth: calm,                       // fuller: low octave and third fade in
    droneTone: lerp(420, 1300, calm),   // and opens up
    rough: s.quality === 'none' ? 0 : jaw,  // jaw clench roughens the sound (fast up, slow down in the mixer)
    bellsAllowed: usable && jawKnown && jaw <= JAW_BLOCK,
    neutral: !usable,
  };
}

// Reward bell: rings when calm stays at or above REWARD.level for REWARD.holdS seconds while bells
// are allowed. Anything that blocks bells (jaw, bad contact) resets the hold and keeps it at zero
// for REWARD.lockS seconds after the block ends, so a clench never leads straight into a bell.
// r = {hold, lock} (start with newReward()); returns the next r and whether to ring now.
export const newReward = () => ({ hold: 0, lock: 0 });

export function rewardStep(r, calm, allowed, dt) {
  let { hold, lock } = r;
  if (!allowed) { lock = REWARD.lockS; hold = 0; } else lock = Math.max(0, lock - dt);
  if (lock > 0 || calm < REWARD.level) hold = 0;
  else hold += dt;
  if (hold >= REWARD.holdS - 1e-9) return { r: { hold: 0, lock }, ring: true };
  return { r: { hold, lock }, ring: false };
}
