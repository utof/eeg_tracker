# What the electrodes see, and when you drift off

One set of detectors, shared by every feature that needs them: meditation feedback now; the night extras, the
sleep-sound auto-stop and the dream catcher later. ROADMAP next step 3; DECISIONS 85-89.

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
| Slow eye rolls | T3-T4 at 0.2-0.7 Hz, a 10 s mean over 4x its lights-off level | reported only | on these recordings it fired as often before sleep as after, so nothing uses it yet |
| Jaw and muscle | 55-120 Hz at T3 and T4 (50 and 100 Hz mains notched out) over 4x that side's own level (the 20th percentile of its last 2 minutes) | needs 30 s of history | *jaw* when both sides rose (each over 2x); *one-sided* when one side did (a pillow, a hand, one electrode); *movement* when movement falls inside |
| Movement | 3 or more channels jump past 200 µV in the same second (above 2 Hz, so deep-sleep waves stay out) | always | a hard blink with eyes open can reach it on a noisy day |

## The drift-off detector (DECISIONS 62, 88)

1. **Lights off**: a button (later), or the meditation's close-eyes cue. Close your eyes.
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

## What still needs the owner

- **The extended setup test** (`morning.html`, 2 min): 20 cued blinks set the blink depth, 10 glances give µV
  per degree and left vs right, 5 clenches confirm the jaw band and the 4x threshold.
- **A "lights off" press** on each night or nap: three more onsets within 5 minutes and the detector ships
  (DECISIONS 62).
- **A meditation on the phone** where you let yourself doze: does "drifting" come when you feel it?

## Commands

```
uv run --project analysis python analysis/validate_detectors.py onset   NIGHT.bdf NIGHT.sleep.json 03:12:00
uv run --project analysis python analysis/validate_detectors.py stages  NIGHT.bdf NIGHT.sleep.json
uv run --project analysis python analysis/validate_detectors.py checkin RUN.f32 RUN.markers.jsonl
uv run --project analysis python analysis/make_detector_fixture.py NIGHT.bdf RUN.f32 RUN.markers.jsonl MORNING.bdf app/test/fixtures/detectors.json
```

A night of 5.4 hours takes about 10 s on the laptop.
