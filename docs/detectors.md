# What the electrodes see, and when you drift off

One set of detectors, shared by every feature that needs them: meditation feedback, the dream catcher, sound for
states, the night extras of the sleep report, and the drift-off detector during every night with its "Falling
asleep" check in the morning report. ROADMAP next step 3; DECISIONS 85-89, 140-146 and 180-186. The hands-free gestures (DECISIONS 240-249) sit on top of
them.

- **Python reference**: `analysis/eeg_detectors.py`, checked on the owner's recordings with
  `analysis/validate_detectors.py` (commands below). Tests: `analysis/tests/test_eeg_detectors.py`.
- **Phone app**: `app/lib/detectors/`, a line-by-line port with the same numbers.
  `app/test/detectors_cross_check_test.dart` runs recorded excerpts through both and expects the same events
  (fixture made by `analysis/make_detector_fixture.py`, 371 KB, no clock times or device numbers).

Every number below is a planning value set on one night, one morning sleep and one morning check-in
(2026-11-18). The only judge for sleep is AnySleep, which nobody has checked by hand on this headband.

## How the headband sees things

Each channel is its electrode minus the forehead reference (DECISIONS 78). So a blink, which makes the forehead
positive, shows as a dip on all four channels; T3 minus T4 cancels it and keeps sideways eye movements. Deep
sleep waves also come in through the forehead and show upside down on O1/O2.

## The detectors

| Detector | What it looks for | When it works | Limits |
|---|---|---|---|
| Signal quality, per 30 s | missing samples, a flat channel (under 1.4 µV range in a second), a channel at the converter's limit (390 mV), over 500 µV in a second (above 2 Hz), movement, muscle | always | *missing*: over 5 s of holes or no usable channel; *degraded*: a channel with over 3 bad seconds, 3 s of movement, or muscle in half the epoch |
| Blinks | the 4-channel mean dips 50 µV or more, at least 15 µV on every channel, under half depth for 0.04-0.2 s, T3-T4 within half of it | awake | in sleep the same shape comes from sleep waves (0.3-2.5 a minute); a light blink under 50 µV is missed |
| Sideways eye movements | T3-T4 changes 40 µV or more within 0.1 s, T3 and T4 moving apart by similar amounts, the 4-channel mean steady | awake, eyes open | left and right are not known until the setup test's glances; it does not pick out dream sleep (REM) |
| Eye movements in sleep (the dream sleep check, DECISIONS 742-743) | per second, the eye pair (T3-T4 here; from the header on any layout) band-passed 0.5-5 Hz swings over 40 µV peak to peak while the two sides correlate below -0.3 | the night report, counted per 30 s | measurement only; unvalidated against eye electrodes; wake and arousals move the eyes too, and a big one-sided burst passes now and then (`analysis/rem_check.py`, `app/lib/sleep/rem_check.dart`) |
| Slow eye rolls | T3-T4 at 0.2-0.7 Hz, a 10 s mean over 4x its lights-off level | reported only | on these recordings it fired as often before sleep as after, so nothing uses it yet |
| Jaw and muscle | 55-120 Hz at T3 and T4 (50 and 100 Hz mains notched out) over 4x that side's own level (the 20th percentile of its last 2 minutes) | needs 30 s of history | *jaw* when both sides rose (each over 2x); *one-sided* when one side did (a pillow, a hand, one electrode); *movement* when movement falls inside |
| Movement | 3 or more channels jump past 200 µV in the same second (above 2 Hz, so deep-sleep waves stay out) | always | a hard blink with eyes open can reach it on a noisy day |

## The drift-off detector (DECISIONS 62, 88)

1. **Lights off**: the night screen's Lights off button, the dream catcher's, a fall-asleep sound session's quiet
   minute, or the meditation's close-eyes cue. Close your eyes. A night without one counts from its first sample.
2. **Baseline**: the median alpha (8-12 Hz at O1/O2) of the first 60 clean seconds without a blink.
3. Every 30 s from lights off: the epoch is **faded** when over half of its clean seconds have alpha under half
   the baseline. It is not faded with 3 s of movement, or with 2 blinks before sleep (open eyes also lower
   alpha). Epochs with under 10 clean seconds are skipped.
4. **Drowsy** after 2 faded epochs in a row (1 min), **probably asleep** after 6 (3 min); the onset is the first
   of them, so the app knows 3 minutes late. **Awake again** after 2 epochs that are not faded.
5. **Timers back it up** (DECISIONS 62): sleep sounds fade over 2.5 min once probably asleep and stop 45 min
   after lights off whatever the detector says; the dream catcher asks when drowsy is known, or, if that never
   comes, at a random moment inside your usual time to fall asleep (the middle half of your earlier nights once
   there are 3, until then 10-20 min).

In meditation the detector runs from the close-eyes cue, so the calibration minute is its baseline. Its drowsy
or asleep state shows as "drifting" (with the feedback core's own faster drowsy gate); the report keeps when it
first said asleep. The controller exposes the detector for the dream catcher and the sound auto-stop.

## Validation (2026-11-18 recordings)

**Sleep onset** against AnySleep's onset (the first of 10 sleep epochs in a row):

| Recording, lights off at | AnySleep | Detector | Difference | App knows |
|---|---|---|---|---|
| Night, 02:40 (recording start) | 03:16:43 | 03:17:13 | +0.5 min | 03:20:13 |
| Night, 03:12 (signal steady again) | 03:16:43 | 03:16:43 | 0 | 03:19:43 |
| Morning sleep, 09:11 (headband back on) | 09:15:13 | 09:15:13 | 0 | 09:18:13 |
| Morning, 08:10, then an hour of tests with eyes open (stress test) | 09:15:13 | 09:15:13 | 0 | 09:18:13 |
| Morning, 08:35 (stress test) | 09:15:13 | 09:16:13 | +1.0 min | 09:19:13 |
| Back to sleep after 10 min awake, 11:35 (no button; extra) | 11:50:13 | 11:45:13 | -5.0 min | 11:48:13 |

- Both real onsets fall within 5 minutes: **2 of the 5 nights** DECISIONS 62 asks for before it ships.
- Before onset 0 of 46 (night) and 0 of 5 (morning) epochs were faded; in the 10 minutes after it, 15 of 18
  (night) and 19 of 20 (morning).
- Without the blink rule the 08:10 stress test fell "asleep" at 08:26, 48.5 min early, during eye tests:
  eyes-open alpha was under half the baseline in 67 % of the check-in's eyes-open seconds. Two blinks per epoch
  fixed it; 10 of its 107 pre-sleep epochs still faded, never 6 in a row.
- The last row: AnySleep's first light sleep was at 11:44:43, but its 10-epoch run started at 11:50:13.
- AnySleep reads the same alpha, so part of the agreement is built in; both onsets were abrupt.

**Blinks** in the morning check-in: eyes open 3.1 a minute (6, median 90 µV, T3-T4 +5 µV), eyes closed 0.5 a
minute (1). With a 30 µV threshold the closed phase had more "blinks" than the open one (14 vs 7 a minute), so
the depth and width limits matter. Cued blinks in the 08:14 eyes test were 82-130 µV. Awake at night 5.5 a
minute (median 88 µV).

**Eye movements**: check-in eyes open 5.6 a minute, eyes closed 2.0. In sleep it fired 3-14 a minute in every
stage, dream sleep included, so it is for waking use only.

**Jaw and muscle**: of the night's loudest muscle seconds (the top 10 % of wake by 20-45 Hz power, check 2 of
the night checks) 86 % were flagged (morning 82 %); of the quietest wake seconds 7-8 %. Share of seconds with
muscle: wake 34-40 %, N2 10-12 %, N3 7 %, REM 13-14 %. Jaw bursts an hour: wake 34-38, N2 12-22, N3 10, REM
30-66 (REM: 14.5 min at night). One-sided bursts come 20-41 an hour in every stage. Counting T3 and T4 together
instead (the first try) gave 30 bursts an hour in N3, mostly T4 alone.

**Epoch quality**: all 77 gap epochs of the night came out missing, plus 23 awake epochs with no usable channel.
Degraded: N2 16 % (night) and 13 % (morning), N3 14 %, wake 33 %. The morning sleep had a stretch of bad
contact (23 N2 epochs missing).

**Phone port**: three excerpts (35, 50 and 30 s, one with a hole) and three drift-off runs of 20-22 min give the
same blinks, eye movements, bursts, movement, epoch flags and drift-off steps in Dart and Python; per-second
numbers agree within 1e-9.

## Night extras in the sleep report (DECISIONS 140-146)

After a night is scored, the report says what the detectors saw over the same samples (`extras` in
`<date>.report.json`, [data-format.md](data-format.md)):

- **Signal quality** per 30 s epoch (good / noisy / no usable electrode), drawn as a Signal lane under the stage
  chart, and how much of the sleep the model read through noise in the honest note.
- **Jaw muscle bursts** (both sides at once) and **movements** (3+ channels jumping) per hour asleep: a trend to
  compare nights, not a bruxism count (row 65). Asleep = the asleep epochs inside the sleep periods.
- **Hour by hour** on the clock: minutes good / noisy / unusable, jaw, one-sided and movement bursts, movements.

Each burst or movement counts in the 30 s epoch it starts in. The same rules exist twice: `analysis/night_extras.py`
(the reference, also used by the laptop's `scripts/sleep_report.py`) and `app/lib/sleep/extras.dart` (the phone,
which runs the detectors in a background isolate beside the sleep model).

**The owner's night of 2026-11-17** (58 recordings joined, 12.9 h, 1549 epochs, the laptop's AnySleep stages for
both): the phone's code and the Python reference find the same 924 bursts and 508 movements, the same quality for
every epoch and the same number in every hour.

| | Whole recording | Asleep (6 h 27 min) |
|---|---|---|
| Good / noisy / no usable electrode | 466.5 / 151 / 157 min | 322.5 / 52 / 12.5 min (83 / 13 / 3 %) |
| Jaw bursts (both sides) | 312 | 147: 22.8 an hour |
| One-sided / movement bursts | 341 / 270 | 163 / 79 |
| Movements | 507 | 122: 18.9 an hour |

The whole recording counts 157 minutes with no usable electrode: the 109.5 minutes of gaps plus stretches with every
channel flat, railed or over 500 µV (mostly awake, the headband off or loose). These rates are higher than the
validation's per-stage numbers above because the long morning sleep was restless: in the morning
recording alone N2 had 21.8 jaw bursts and 30.5 movements an hour.

**Time and memory** on the laptop (AOT-compiled Dart, the same night): the detectors' pass 11.3 s, the sleep model's
preparation 12.5 s, both side by side 11.8 s; the pass streams the files (its own data: a few hundred kilobytes);
the Dart process running only the pass peaked at 109 MB, mostly the garbage collector's room. The Python reference
needs about 2 GB and 20-35 s; in the laptop's sleep report it made the night's job 88 s instead of 64 s, and the
peak memory stayed the scoring's 2.8 GB.

## Lights off and falling asleep in the night (DECISIONS 180-186)

- **Live**: the phone's night recorder runs the drift-off detector in its own background isolate on every batch,
  right after the batch is buffered for the files (no extra wakeup; the screen is off). Lights off counts from the
  night's first sample until the night screen's **Lights off**, which writes a `lights off` marker and starts it
  again on the next 30 s epoch. Its moments become markers (`drift-off: drowsy`, `drift-off: probably asleep, onset
  23:51:30`, ...) and the screen's line above the buttons shows its state. Every call is guarded: an exception, or
  more than 2 % of the time after the first 10 minutes, switches it off with one log line and the recording goes on.
  After Android restarts the service it waits for the next Lights off.
- **Morning**: the sleep report runs the same detector again over the joined night from its latest lights-off marker
  (the night pass that already counts jaw and movement) and compares its onset with the sleep model's (the first of
  10 epochs in a row not scored awake): `drift_off` in the report ([data-format.md](data-format.md)), "Falling
  asleep" on the screen, and the check: the detector ships when 4 of the newest 5 nights with Lights off agree within
  5 minutes. The laptop's `scripts/sleep_report.py` writes the same from `analysis/night_drift.py`.
- **Live equals morning**: the live detector places the batches on the clock as the night pass joins the files
  (pauses over 0.5 s and new file sets held, the files' float32, the BDF's clip), so both find the same onset when
  the night is the recorder's own files. On the owner's 12.9-hour night of 2026-11-17 (58 recordings, every drop)
  replayed batch by batch with `tool/live_drift.dart`: the same baseline, onset and known second as the night pass.
- **Cost**: in that replay (AOT, as the phone runs) the live detector took 42.8 s for 12.9 h of signal, **3.3 s an
  hour** (0.09 % of the time) while the laptop was busy with other work (the night pass took 44 s instead of
  its quiet 11.3 s, so about 1 s an hour on a quiet laptop); about 150 MB for the whole tool. The phone is untested
  (likely 2-4 times slower: still well under its 2 % limit); its night `.log` ends with the measured number.

The recorded night through the report's rules (the laptop's AnySleep stages; the night's own 30 s grid from 01:58:25,
so the times differ from the table above by the grid):

| Lights off at | Detector onset | Sleep model onset | Difference | Agree |
|---|---|---|---|---|
| 01:58:25 (night start: what the report says, not counted) | 03:12:55 | 03:16:55 | -4.0 min | yes |
| 02:40:25 | 03:16:55 | 03:16:55 | 0 | yes |
| 03:12:25 | 03:16:55 | 03:16:55 | 0 | yes |
| 09:11:25 (headband back on) | 09:14:55 | 09:15:25 | -0.5 min | yes |
| 11:35:25 (back to sleep after waking; extra) | 11:58:25 | 11:50:55 | +7.5 min | no |

## Hands-free gestures (DECISIONS 240-249)

Two deliberate gestures on top of the detectors, used as a switch in sessions (app/README.md, "Hands-free controls"):
`analysis/hands_free.py` (the reference) and `app/lib/detectors/gestures.dart` (the phone's line-by-line port). The
recogniser takes one whole second at a time as the detectors finish it: ten 0.1 s ticks of 55-120 Hz power at T3
and T4 (the detectors' muscle filter, through a tap that changes none of their numbers), each side's rest level (the
detectors' 20th percentile of the last 2 minutes), the second's hole and movement flags, and the eye movements known
by then.

| Gesture | Rule (planning values; the calibration tunes the level and the size) |
|---|---|
| Double clench | jaw ticks (one side over 4x its rest, both over 2x: the jaw rule at 0.1 s) form bursts (a one-tick dip does not split one); bursts under 2 s apart form a cluster, decided after 2 s with no jaw tick. A gesture: exactly 2 bursts of 2-10 ticks (0.2-1 s), 3-15 ticks apart (0.3-1.5 s), each with both sides over the clench line (10x; calibrated 10-60x) at its strongest tick |
| Look left, then right | eye movements under 2 s apart form a cluster, decided once every movement up to 2 s after its last is known. A gesture: 2 or 3 movements, each within 1.5 s of the one before, each the other way, the first two at least the look size (80 µV; calibrated 70-250), the first one left once left is known (else either way) |
| Both | nothing spoiled from 2 s before to 2 s after: no Bluetooth hole, no movement second, the rest level known (so nothing in the first 30 s). Decided 2-4 s after the gesture. The app drops it while the drift-off detector says probably asleep |

**False triggers** (nobody made a gesture in these recordings, so every gesture found is false; planning settings,
left unknown; AnySleep's stages; `analysis/validate_hands_free.py`):

| Recording | Hours | Double clench | Look left, then right |
|---|---|---|---|
| Night of 2026-11-17, awake | 4.6 | 0 (0 an hour) | 9 (1.9 an hour; 0.9-1.1 with left known) |
| Same night, asleep | 6.5 | 4 (0.6 an hour; all 4 in light sleep of the restless morning) | 4 (0.6 an hour) |
| Asleep, with the drift-off gate (lights off at the first sample) | 6.5 | 4 (the detector said awake then) | 3 |
| Morning check-in of 2026-11-18 | 0.09 | 0 | 0 |

By level: awake, a clench line of 4x gave 0.65 an hour, 8x 0.22 and 10x or more none; asleep, 10x 0.62, 20x 0.31,
30x 0.16, 40x none. Looks awake: 40 µV 30 an hour, 60 µV 6, 70 µV 2.6, 80 µV 1.9, 100 µV 0.4, 150 µV none (about half
of each with left known). The first version counted any one-sided muscle as "something else"; on the check-in's eyes-
closed minutes one electrode's flicker then kept two of three synthetic calibration clenches from ever closing, so
only jaw ticks (both sides up) count, as the detectors' jaw rule does; the night's numbers at the planning settings
stayed the same.

**Calibration** (`calibrate`, about 90 s): 32 s still, then six tries 8 s apart (three "clench twice now", three
"look left, then right"), each answer to start within 5 s of its cue. Tries with a gesture's shape at any level set the
clench line at half the weakest (10-60x) and the look size at 0.6 of the smallest (70-250 µV); left is known when at
least 2 tries had a first step and all went the same way. Each try is then judged with the tuned settings; a gesture
is used only if 2 of its 3 were caught.

**Phone port**: `app/test/gestures_cross_check_test.dart` runs four excerpts of the recordings (the check-in's eyes
open and eyes closed minutes, two stretches of the night with real jaw bursts and a hole) with synthetic clenches
and looks drawn over them through the detectors, the tap and the recogniser, and expects the Python reference's
per-second inputs (within 1e-8), clusters with their verdicts, gestures and, for a calibration run, the same tuned
settings (fixture `app/test/fixtures/gestures.json` by `analysis/make_gesture_fixture.py`, 568 KB, no clock times or
device numbers). In the night recorder the same recogniser runs inside the live drift-off detector (one guard for
both); replayed on the night of 2026-11-17 with the planning settings it marked the same 4 double clenches as the
reference.

**Cost at night**: replayed batch by batch on the 12.9-hour night (AOT, `tool/live_drift.dart`, two runs each on a quiet
laptop), the live detector took 0.85-0.86 s an hour of signal with the gestures and 0.83-0.86 s without: the gestures
add less than the run-to-run noise.

```
uv run --project analysis python analysis/validate_hands_free.py night NIGHT.bdf NIGHT.sleep.json
uv run --project analysis python analysis/validate_hands_free.py run RUN.f32 [...]
uv run --project analysis python analysis/make_gesture_fixture.py NIGHT.bdf RUN.f32 RUN.markers.jsonl app/test/fixtures/gestures.json
cd app && dart compile exe tool/live_drift.dart -o /tmp/live_drift && HANDS_FREE=1 /tmp/live_drift RECORDINGS 2026-11-17 NIGHT.sleep.json
```

The night takes about 90 s and 1.8 GB on the laptop.

## What still needs the owner

- **The extended setup test** (`morning.html`, 2 min): 20 cued blinks set the blink depth, 10 glances give µV
  per degree and left vs right, 5 clenches confirm the jaw band and the 4x threshold.
- **The hands-free calibration** (phone, Settings, 90 s): the first real double clenches and looks; its EEG is kept
  for checking the gesture rules on the laptop.
- **A Lights off tap** on each night or nap, as you close your eyes (app/README.md, "Lights off and falling asleep"):
  the morning report's check counts the nights; 4 of 5 within 5 minutes and the detector ships (DECISIONS 62).
- **A meditation on the phone** where you let yourself doze: does "drifting" come when you feel it?

## Commands

```
uv run --project analysis python analysis/validate_detectors.py onset   NIGHT.bdf NIGHT.sleep.json 03:12:00
uv run --project analysis python analysis/validate_detectors.py stages  NIGHT.bdf NIGHT.sleep.json
uv run --project analysis python analysis/validate_detectors.py checkin RUN.f32 RUN.markers.jsonl
uv run --project analysis python analysis/make_detector_fixture.py NIGHT.bdf RUN.f32 RUN.markers.jsonl MORNING.bdf app/test/fixtures/detectors.json
```

A night of 5.4 hours takes about 10 s on the laptop.

The night extras, phone code against the reference on a recorded night (same stages for both):

```
uv run --project analysis python analysis/night_extras.py RECORDINGS 2026-11-17 NIGHT.sleep.json --out py.json
cd app && dart run tool/night_extras.dart RECORDINGS 2026-11-17 NIGHT.sleep.json dart.json
uv run --project analysis python analysis/make_extras_fixture.py RECORDINGS 2026-11-17 NIGHT.sleep.json app/test/fixtures/night_extras.json
```

The live detector on a recorded night (cost per hour, live against the night pass, the report's comparison, and the
same with lights off at given times); compile it first for the phone's speed:

```
cd app && dart compile exe tool/live_drift.dart -o /tmp/live_drift
/tmp/live_drift RECORDINGS 2026-11-17 NIGHT.sleep.json 02:40:00 03:12:00 09:11:00
```
