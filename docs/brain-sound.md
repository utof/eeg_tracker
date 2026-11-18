# Brain sound

A calm sound that follows one thing the headband measures well: the alpha rhythm at the back of the
head (O1, O2), which grows when you close your eyes and settle. As it rises above your own baseline,
rain and wind quieten and a low drone warms. Hold it high for about 3 s and a bell rings.
Clenching your jaw (fast muscle activity at T3, T4) pauses the bells and briefly roughens the sound,
so muscle can never earn a bell.

It is a relaxing tool, not a treatment. See "What the evidence says" below.

## Try it

With the headband (on the laptop):

```bash
scripts/record_night.sh            # or: python3 scripts/record_night.py --port 8765
# then open http://localhost:8765/sound.html
```

Without a headband, either the fake headband:

```bash
PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8765 --out /tmp/rec
# open http://localhost:8765/sound.html
```

or the page's own demo signal, with any static server (browsers do not load the page's modules from `file://`):

```bash
python3 -m http.server 8000 -d scripts/web
# open http://localhost:8000/sound.html  (no recorder found, so "demo" is picked)
```

Use headphones at a low volume. Press **Start (60 s calibration)**: keep your eyes open on one spot for 30 s,
then close them when the low tone sounds; a second tone ends calibration. Then sit with eyes closed.
**Start without calibration** skips this and learns your range as you go (see Baseline).

The page shows alpha against your baseline, your jaw (relaxed, tense, clenched), contact per electrode,
whether bells are on, and in plain words what the sound is doing and why. In live mode it saves markers
(`sound: start`, `calibration eyes closed`, `bell`, `stop`) into the recording, so they become BDF annotations.

## How it works

```
GET /state (last 4 s, µV) ─► features ─► session ─► mapping ─► mixer ─► Web Audio engine
  4 times a second            1 s window   baseline    pure       smoothing   drone, rain/wind, bells
```

| File (`scripts/web/`) | Job | Tested in node |
|---|---|---|
| `sound-features.js` | band power (Hann window, µV²), contact quality per channel | yes |
| `sound-session.js` | calibration, baseline, brain state, when to ring | yes |
| `sound-mapping.js` | **brain state → sound settings**, reward rule (pure functions) | yes |
| `sound-mixer.js` | smoothing with separate rise and fall times | yes |
| `sound-demo.js` | synthetic signal (same recipe as the fake headband) | yes |
| `sound-engine.js` | Web Audio: the sound itself | no (browser) |
| `sound-app.js`, `sound.html` | page, polling, display, markers | end-to-end check only |

The mapping and mixer are the parts to port to Dart (`flutter_soloud`) for the phone app.

### Measures

- **Alpha**: power at 8-12 Hz, mean of the back electrodes that have contact, on a log scale; 1 s window,
  new value every 0.25 s, lightly smoothed (0.5 s). Short delay on purpose: in a study that compared delays,
  alpha feedback trained best with the shortest one.
- **Jaw**: power at 30-45 Hz at T3/T4 (below the 50 Hz mains hum) against its own resting level
  (20th percentile of the last 2 minutes). 0 under 2× rest, 1 at 10× rest.
- **Contact**: a channel is unusable when the recorder measured no contact, the line is flat, or it swings over
  300 µV in 1 s (movement). Alpha needs one good back electrode; bells also need one good side electrode.

### Baseline

Calibration: 30 s eyes open, then 30 s eyes closed (first 5 s of each dropped). Your eyes-open alpha becomes 0
and your eyes-closed alpha becomes 1 on the bar. If eyes closed did not raise alpha at least 1.5× (no clear
alpha, poor contact at the back, eyes not shut), or you skip calibration, the scale comes from your recent range:
10th to 90th percentile of the last 5 minutes, starting after 5 s. If alpha has hardly changed (under 2×), a
2× span is centred on it, so a steady level sits mid-scale: without calibration the page cannot tell a high
steady level from a low one, so open and close your eyes a couple of times early on to teach it. The recent
range keeps adapting, so in a long eyes-closed sit the bar drifts back toward the middle; the calibrated scale does not.
DECISIONS row 18.

### Sound

| Brain measure | Sound |
|---|---|
| alpha 0 → 1 (eyes-open → eyes-closed level) | rain/wind gain 0.9 → 0.12 and its tone 3200 → 900 Hz; drone 0.55 → 0.85, tone 420 → 1300 Hz, low octave and third fade in ("warmth") |
| jaw 0 → 1 | roughness: 33 Hz tremolo and a slight detune; rises in 0.08 s, fades over about 1.2 s |
| alpha ≥ 0.7 for 3 s, jaw relaxed, contact good | one bell (pentatonic notes in an 11-step order); the 3 s count starts again |
| any jaw tension, or a side electrode off | no bells, and none for 2 s after it ends |
| no data for 2 s, back electrodes off or moving, still calibrating | neutral bed (as if alpha were 0.35), no bells, the reason on screen |

The drone partials and the wind and rain swell on slow loops of unequal length (11, 17, 19, 23, 29, 31, 37 s,
noise loops of 9.7 and 13.3 s), so the bed never repeats the same way. Bells are only ever rewards, so every
change you hear maps to something measured.

## Checked so far (no headband)

- `node --test tests/web/*.test.mjs`: band power, contact rules, mapping, reward rule, mixer, and the whole
  pipeline for 10 minutes of demo signal, calibrated and not: calm above 0.8 in eyes-closed minutes and below
  0.2 in eyes-open minutes, bells only in eyes-closed minutes, never within 8 s of a jaw burst starting.
- `node tests/web/fake_live_check.mjs`: the page in headless Chromium against the recorder running the fake
  headband (see the comment at the top of that file for how to run it). Two 6-minute runs on 2026-11-18:
  calibrated (calibration said "eyes closed gave 17.0x eyes-open alpha"): mean calm 0.997 in eyes-closed minutes,
  0.014 in eyes-open minutes, 38 bells, all in eyes-closed minutes; without calibration: 0.856 vs 0.033,
  36 bells. In both, bells were blocked at every analysis step inside a jaw burst, no bell came within 8 s of a
  burst starting, roughness reached its maximum during bursts, and the page logged no errors.
- With a strong steady alpha (the fake) a bell rings about every 3.2 s. That may feel busy on a real head;
  if so, raise the 3 s hold or add a gap between bells (DECISIONS row 20).

## Not checked yet

- A real head. The fake alpha is a clean 10 Hz sine; real alpha is smaller, wanders in frequency and
  comes and goes. The 1.5× calibration rise, the 0.7 reward level and the 2× jaw threshold are first guesses.
- Whether muscle from a strong clench leaks into O1/O2 alpha on this headband (bells stay blocked either way,
  but the rain could soften during a clench).
- How it sounds on laptop speakers (the low octave at 55 Hz will be faint) and on a phone.

## What the evidence says

- Eyes-closed alpha at the back of the head is one of the most reliable things EEG shows, and these electrodes
  sit right over it. Measuring it is not the hard part.
- Alpha neurofeedback for relaxation and anxiety shows moderate pooled effects in reviews, but in controlled
  trials it often does no better than sham feedback (sound that follows a recording, not you). Much of the
  benefit seems to come from sitting quietly with eyes closed, expecting to relax, and the ritual itself.
- So: use it as a pleasant way to sit still with your eyes closed. It is not a treatment for anxiety, sleep
  problems or anything else, and the bell count is not a score of how calm you are.
- Four dry electrodes cannot measure stress, mood or focus (ROADMAP, "honest version").
