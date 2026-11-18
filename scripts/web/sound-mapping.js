// Brain state -> sound settings. Pure functions: same input, same output; no audio, no time.
//
// Brain state:
//   z       : alpha against the person's target line, in robust SDs (0 = on the line); null = unknown
//   jaw     : 0 = relaxed (30-45 Hz power at T3/T4 under 2x its resting level), 1 = clearly clenched
//             (10x or more); null = side electrodes not usable
//   quality : 'good', or why the sound cannot follow the brain ('learning', 'settling', 'poor', 'none')
//   veto    : null, or the gate that is on: 'muscle', 'blink', 'drowsy'
//
// The bed follows an S-curve centred on the line: flat beyond 2 SD either side, steepest at the line,
// so the sound changes most where it matters. Any gate moves it to neutral; drifting toward sleep
// goes a little brighter than neutral, as a nudge to stay awake.
//
// Port notes (Dart): top-level functions returning a plain map/record; no state.

export const NEUTRAL_CALM = 0.35;   // where the sound rests when it cannot follow the brain
export const NUDGE_CALM = 0.2;      // drowsy: brighter rain than neutral
export const JAW_BLOCK = 0.05;      // any jaw score above this is a muscle gate

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const lerp = (a, b, t) => a + (b - a) * t;

// 0 at z <= -2, 1 at z >= +2, 0.5 on the line, smooth (zero slope) at both ends
export function sCurve(z) {
  const u = clamp01((z + 2) / 4);
  return u * u * (3 - 2 * u);
}

// Layer settings for the engine from two numbers (so a logged control stream can drive the sound later).
// Gains are 0..1 before the engine's own level trims; tones in Hz.
export function layers(calm, rough) {
  return {
    calm,
    rain: lerp(0.9, 0.12, calm),        // rain/wind quietens as alpha rises
    rainTone: lerp(3200, 900, calm),    // and gets darker
    drone: lerp(0.55, 0.85, calm),      // the drone comes forward
    warmth: calm,                       // fuller: low octave and third fade in
    droneTone: lerp(420, 1300, calm),   // and opens up
    rough,                              // jaw tension roughens the sound
  };
}

export function mapState(s) {
  const usable = s.quality === 'good' && Number.isFinite(s.z);
  let calm = NEUTRAL_CALM;
  if (usable && !s.veto) calm = sCurve(s.z);
  else if (usable && s.veto === 'drowsy') calm = NUDGE_CALM;
  const jawKnown = Number.isFinite(s.jaw);
  const rough = s.quality === 'none' || !jawKnown ? 0 : clamp01(s.jaw);
  return { ...layers(calm, rough), bellsAllowed: usable && !s.veto && jawKnown, neutral: !usable || !!s.veto };
}
