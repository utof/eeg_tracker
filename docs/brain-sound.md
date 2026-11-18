# Brain sound

A calm sound that follows one thing the headband measures well: the alpha rhythm at the back of the
head (O1, O2), which grows when you close your eyes and settle. When it rises above your own line (set from
your quiet eyes-closed minute), rain and wind quieten and a low drone warms. Stay above the line for a few
seconds and a bell rings, at most 6 times a minute. A tight jaw, a blink or drifting toward sleep pauses the
bells and moves the sound to neutral, so muscle, blinks and dozing can never earn a bell.

It is a relaxing practice, not a treatment. See "What the evidence says" below.

The page is a stopgap until the phone app: the logic lives in small pure modules (no browser inside),
each with port notes for Dart at the top, and the page only wires them up.

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

Use headphones at a low volume. Press **Start (90 s quiet calibration)**: eyes open on one spot for 30 s,
then close them when the low tone sounds, for 60 s; a second tone starts the sound. **Start without
calibration** plays a neutral sound for the first minute and uses that minute (eyes closed) as your level.
The demo has a "closed, drifting off" choice (alpha slows to 7.5 Hz) to hear the sleep guard.

**Mode**: *training* answers fast (about 0.3 s from brain to sound, before the headphones) and asks the
browser for small audio buffers; use wired headphones or the speaker, since Bluetooth headphones add about
0.15-0.5 s. *Relax* glides slowly (about 1 s), rings at most every 15 s and keeps large buffers; Bluetooth
is fine there. Phones get a lighter sound engine automatically (fewer dropouts). `?mode=relax` in the
address picks relax.

You don't need to do anything to make the rain soften. Just notice what you feel when it does. If you start
drifting off, the sound gets a little brighter: that's your cue to stay awake.

## How it works

```
GET /stream (every batch of samples, µV) ─► core, sample by sample ─► engine (glides on the audio thread)
  source seam: live / demo / replay          every 0.1 s: gates, line, bells
```

| File (`scripts/web/`) | Job | Tested in node |
|---|---|---|
| `sound-source.js` | sources behind one seam: the recorder's stream, the demo, a saved session; stream reader; `replaySession` | reader, replay |
| `sound-features.js` | filters run per sample: alpha and theta envelopes, muscle power, slow waves (blinks), contact quality, spectrum peak | yes |
| `sleep-guard.js` | **shared** drift-to-sleep detector (for the dream catcher, alpha-theta and sleep-sound auto-stop later) | yes |
| `sound-reward.js` | target line held for 3-minute blocks, bell rule (window, gap, 6 a minute) | yes |
| `sound-session.js` | the core: calibration, personal alpha band, gates, line, bells; sample-driven | yes |
| `sound-mapping.js` | brain state → sound settings (S-curve on the line) | yes |
| `sound-mixer.js` | glide times per mode (training / relax) | yes |
| `sound-log.js` | session log: control stream, events and the input samples, for exact replay | via replay |
| `sound-demo.js` | synthetic signal (the fake headband's recipe plus wandering alpha) | yes |
| `sound-engine.js` | Web Audio: the sound itself | no (browser) |
| `sound-app.js`, `sound.html` | page wiring, display, markers | end-to-end check only |

The core never reads a clock: time is the number of samples received, and it decides every 25 samples
(0.1 s). So the same samples always give the same sound settings and bells, whatever the chunking or timing.

### Measures

- **Alpha**: two band-pass filters around your alpha peak (peak ± 2 Hz; 8-12 Hz if calibration found no
  clear peak), then the envelope from the signal and its slope, smoothed 0.05 s. Mean power of the back
  electrodes with contact, on a log scale. It gets half-way to a new level about 0.1-0.2 s after the eyes
  close or open (tested). Slowed "drowsy" alpha falls outside the band and earns less.
- **Theta** (for the sleep guard): the same filter at peak − 6 to peak − 2 Hz (4-8 Hz without a peak).
- **Jaw**: 30-45 Hz power at T3/T4 after a 50 Hz notch, smoothed 0.25 s, against its resting level (20th
  percentile of the last 2 minutes): 0 under 2× rest, 1 at 10× rest. The same rule at O1/O2 catches neck or
  scalp muscle at the back.
- **Blinks**: the slow wave (under 4 Hz) at O1/O2; the forehead reference carries blinks there.
- **Contact**: a channel is unusable when the recorder measured no contact, the line is flat, or it swings over
  300 µV in 1 s (movement). Alpha needs one good back electrode; bells also need one good side electrode.
- **Alpha peak**: the highest point of the eyes-closed spectrum in 7-13 Hz (4 s windows, 0.25 Hz steps),
  if it stands 2× above the spectrum's median.

### Calibration and the target line

Calibration is silent: 30 s eyes open, then 60 s eyes closed (the first 5 s of each dropped). It ends once it
has 30 s of clean eyes-closed signal (no blink, no muscle, good contact). From the eyes-closed part:

- your alpha peak and band;
- the **line**: the 35th percentile of your eyes-closed alpha, so at rest you sit above it about 65 % of the
  time; and its spread (robust SD, at least 0.1 log units);
- the sleep guard's baseline (alpha level, theta/alpha ratio, alpha peak).

The line is held still for blocks of 3 minutes. After each block: above it over 80 % of the counted time →
raised 0.15 SD; under 50 % → lowered 0.15 SD. Gated moments are not counted. (A target that chased you every
30 s did no better than placebo in a trial; slow tightening did better.) The eyes-open part only checks that
eyes closed raised alpha (at least 1.5×), and says so if it did not. DECISIONS rows 43-44.

### Gates

| Gate | When | Effect |
|---|---|---|
| Muscle | jaw (T3/T4) or back (O1/O2) muscle score over 0.05 (just over 2× rest); held 0.5 s after | no bells, neutral sound, roughness from the jaw |
| Blink | slow wave at O1/O2 over 40 µV and over 5× its usual size; held 0.5 s after | no bells, neutral sound |
| Drifting toward sleep (`sleep-guard.js`) | theta/alpha over 1.5× your baseline for 10 s, or the alpha peak 1 Hz slower (10 s of clear peaks), or alpha under half your baseline in over half of 30 s | no bells, sound a little brighter than neutral |
| Contact, no data, settling | back electrodes off or moving; nothing from the recorder for 2 s; 1 s after a gap | no bells, neutral sound, the reason on screen |

The sleep guard cannot tell open eyes from dozing: both lower alpha at O1/O2. The page words it as
"drifting toward sleep, or eyes open". All thresholds are planning values to tune on the owner's data.

### Sound and bells

| Brain measure | Sound |
|---|---|
| alpha against the line, S-curve: 0 at 2 SD below, ½ on the line, 1 at 2 SD above | rain/wind gain 0.9 → 0.12 and its tone 3200 → 900 Hz; drone 0.55 → 0.85, tone 420 → 1300 Hz, low octave and third fade in ("warmth") |
| jaw 0 → 1 | roughness: 33 Hz tremolo and a slight detune; rises in 0.08 s, fades over about 1.2 s |
| at least 3 s above the line within the last 4 s, with no gate in those 4 s | one bell (pentatonic notes in an 11-step order); then at least 5 s (training) or 15 s (relax) before the next, and never more than 6 in a minute |

Glide times: training 0.25-0.3 s (warmth 1.5 s); relax about 1 s. The drone partials and the wind and rain
swell on slow loops of unequal length, so the bed never repeats the same way. Bells are only ever rewards.

### Session log and replay

The core keeps a log in memory: one line every 0.1 s (quality, gate, alpha against the line, sound
settings, bell), plus calibration, block and bell events, and every input sample (float32). In live mode
only short summaries go to the recording as markers (start, calibration result, each block, each bell,
stop with audio delay and dropouts). `window.__sound.session()` returns the whole log as one JSON object;
`replaySession()` in `sound-source.js` feeds its samples through a fresh core and reproduces every line
exactly (tested). It is the base for the replayed-feedback check (ROADMAP row 23).

## Checked so far (no headband)

- `node --test tests/web/sound.test.mjs tests/web/feedback-core.test.mjs` (27 tests): filters, mapping, line,
  bells, sleep guard, stream reader; on the demo signal: half-way reaction within 0.3 s of the eyes closing or
  opening; 7.5 Hz "drowsy" alpha earns no bells where 10 Hz earns about 25 in 10 minutes; at most 6 bells a
  minute and the minimum gap even with very strong alpha; no bell with a gate anywhere in the 4 s before it
  (jaw bursts, blinks, a drowsy minute, lost contact, a gap, a 60 s clench); a saved session replays line
  for line; the output does not depend on how the samples are chunked.
- `tests/web/fake_live_check.py`: the page in headless Chrome against the recorder running the fake headband,
  lined up with the fake signal by stream sample index (instructions at the top of the file).

## Not checked yet (needs the owner, about 5 minutes each)

- A real head: does alpha clear the line in eyes-closed rest, and how often do bells come?
- 20 minutes reclined: does the sleep guard catch drifting off, and does it fire falsely while awake?
- A clench test: does the muscle gate catch light and strong clenches at T3/T4, and does a clench leak into O1/O2?
- A forced-roughness test: with a relaxed jaw, does the 33 Hz roughness itself raise the jaw measure (it sits
  inside the 30-45 Hz band, and the hearing cortex follows it)?
- Wired against Bluetooth headphones: how late does the sound feel in training mode?
- Blinks: 20 cued blinks to check the blink gate's 40 µV threshold on this headband.

## What the evidence says

- Eyes-closed alpha at the back of the head is one of the most reliable things EEG shows, and these electrodes
  sit right over it. Measuring it is not the hard part.
- In careful double-blind trials, real feedback often does no better than sham feedback (sound that follows a
  recording, not you), even when people learn to move the signal. Alpha also rises during a session with fake
  feedback or none, so a rising line is not proof of learning. Much of the benefit seems to come from sitting
  quietly with eyes closed, expecting to relax, and the ritual itself.
- So: use it as a pleasant way to sit still with your eyes closed. It is not a treatment for anxiety, sleep
  problems or anything else, and the bell count is not a score of how calm you are.
- Four dry electrodes cannot measure stress, mood or focus (ROADMAP, "honest version").
