# Data format

Three layers, from raw to summary. Each is written once and never edited in place.

| Layer | Files | Written by |
|---|---|---|
| Raw recording | `<stamp>.f32`, `<stamp>.idx`, `<stamp>.log`, `<stamp>.markers.jsonl` (one set per recorder run) | `scripts/record_night.py` (laptop); the phone app will write the same kind of add-only chunks |
| One night | `<night>.bdf` (BDF+, 24-bit, µV), `<night>.sleep.json`, `<night>.hypnogram.png` | `scripts/to_bdf.py`, `scripts/score_sleep.py` |
| Sleep report | `_local/nights/<date>.report.json` beside that night's `<date>.bdf`, `.sleep.json`, `.hypnogram.png` | `scripts/sleep_report.py` (the Sleep page starts it) |
| Sleep report on the phone | `files/nights/<date>.report.json` in the app's private folder | the phone app after Stop (`app/lib/sleep/scorer.dart`) |
| Morning check-in | `<start>.morning.json` (or `<start>.setup.json` for a setup test alone) | `scripts/morning_check.py` |
| Morning check-in on the phone | `files/mornings/<start>.morning.json` and the visit's raw `<stamp>.f32/.idx/.log/.markers.jsonl` | the phone app (`app/lib/morning/`) |
| Events for other apps | `<root>/events/<dev>/eeg-YYYY-MM.jsonl`, `<root>/events/<dev>/breaks-YYYY-MM.jsonl` | `scripts/export_events.py`, `scripts/break_hints.py` |

## Raw recording (BrainBit)

- `.f32`: records of `<I4f` (little-endian): BrainBit packet number, then O1 O2 T3 T4 in **volts** as the
  headband sent them. 250 records a second.
- `.idx`: one `<dQ` record per batch that arrived: unix time of arrival (float seconds) and the index of the
  batch's first record. Gaps are found from these times; packet numbers can repeat.
- `.log`: plain text, one line per event: connection (model, signal strength), contact resistance in ohms, a
  sample count and battery reading every 10 s, stalls and restarts. On the phone a run that ends in a drop logs
  `drop (out of range | no data | run failed); last data <time>; reconnecting`, then one line per try,
  appended after its data files are closed: `reconnect try N (direct to <address> | scan): connected | not found |
  failed after <s> s ...`. The next run's `.log` starts with `reconnected (direct | scan, try N) after a drop`,
  the previous run's stem and the time of its last data.
- `.markers.jsonl`: one JSON object per line from pages that `POST /marker`: `t` (unix time the marker
  arrived), `i` (index of the next sample in this file's `.f32`, so markers line up with samples even across
  gaps) and `text`. `scripts/to_bdf.py` turns them into BDF+ annotations at their clock time.
- The device's Bluetooth address and serial number are in the `.log`. They stay on the owner's machine
  (`_local/` is never committed).

## One night (BDF+)

- Channels `O1 O2 T3 T4`, unit `uV`, physical range ±400 000 µV, 250 Hz, 1 s data records, `BDF+C`.
- File time equals clock time: missing time (Bluetooth drops, restarts) is filled by holding the last value and
  covered by a `BAD_gap` annotation; the end is padded to a whole second (`BAD_padding`). MNE treats
  annotations starting with `BAD` as bad data.
- The header start time is local clock time without a zone (EDF has none; MNE will call it UTC).

## `<night>.sleep.json`

`start` (local, no zone), `epoch_s` (30), `summary` (minutes per stage, sleep onset, total sleep, agreement
of the two models) and `epochs`: one object per 30 s with `t`, `anysleep` and `yasa` (`W N1 N2 N3 R`, or
`gap` when over 5 s of the epoch is filled in), and `p` (AnySleep probabilities in the order W N1 N2 N3 R).

## `<date>.report.json` (the Sleep page)

`scripts/sleep_report.py` writes one per night into `_local/nights/` (the folder next to the recordings). A night
is the recordings chained in time: a recording joins the previous one's night when it starts under 3 hours after
that one's last data or has the same evening date, and never 24 hours or more after the night's first recording
(`scripts/night_files.py`). `<date>` is the evening's date of the first recording (its start minus 12 hours, as
`night_of`). While a night grows, its four files are replaced whole (never edited in place) once 10+ minutes of
new samples exist; files of the same name made by hand are first renamed `<date>-manual.*`.

| Field | Meaning |
|---|---|
| `version` | 2 (since 2026-11-18: `extras` added, every other field as in 1); a report of another version is rebuilt |
| `night_of` | the evening's date, as the file name |
| `built`, `scoring_s` | when it was written (ISO with offset) and how long joining and scoring took |
| `data_start`, `data_end` | first and last moment of the joined recordings, gaps included |
| `inputs` | `[{file, bytes}]`: the `.f32` files and their sizes when read; the report is out of date once they hold 10+ minutes more |
| `scored` | `false` when under 5 minutes were recorded (then `periods` is empty and the file fields are `null`) |
| `periods` | sleep periods, below |
| `total` | the whole night: `asleep_min light_min deep_min dream_min wake_ups periods` summed over the periods, `recorded_min` (scored time), `missing_min` (time lost to gaps), `stray_sleep_min` (asleep epochs outside any period) |
| `hypnogram`, `sleep_json`, `bdf` | file names beside the report |
| `model`, `cross_check` | the stager and the second model with the whole night's agreement, as in `eeg_sleep_night` |
| `note`, `validated` | "first guess; the scorer is not yet validated on this headband", `false` |
| `rules` | `split_min` 60, `min_period_sleep_min` 10, `wake_up_over_min` 5 (below) |
| `extras` | what the shared detectors saw over the same samples (below); `null` when unscored or when that pass failed |
| `extras_error` | why the detectors' pass failed, else `null` |

A sleep period is a stretch of asleep epochs (N1 N2 N3 R by AnySleep) that no 60+ minutes of wake or missing data
interrupt; a stretch with under 10 minutes asleep is scorer noise and only counts in `stray_sleep_min`. Each period
has `start`, `end` (first and last asleep epoch, ISO with offset), `asleep_min`, `light_min` (N1 + N2), `deep_min`
(N3), `dream_min` (R), `awake_min` (W inside), `stage_min` `{W N1 N2 N3 R}`, `wake_ups` (stretches between asleep
epochs with over 5 minutes scored awake) and `wake_up_list` `[{start, awake_min}]`, `missing_min`, `agreement`
`{five_stage, wake_nrem_rem, epochs}` of AnySleep and YASA over the epochs both scored (`null` if none) and
`confidence` (AnySleep's mean top probability).

### `extras` (night extras, DECISIONS 140-146)

Written by `analysis/night_extras.py` on the laptop and `app/lib/sleep/extras.dart` on the phone with the same rules
and numbers. Readers should check `extras` is an object before using it (older reports have none).

| Field | Meaning |
|---|---|
| `version` | 1 (of this object) |
| `rules`, `validated` | the detectors used (DECISIONS 85-87, planning values), `false` |
| `epoch_s` | 30 |
| `quality` | one character per 30 s from `data_start`, the same epochs as `stages`: `g` good, `d` degraded (noisy: a channel unusable, 3+ s of movement or muscle in half the epoch), `m` missing (over 5 s of gap or no usable channel) |
| `night` | the whole recording: `min`, `good_min`, `degraded_min`, `missing_min`, `jaw_bursts` (both sides), `one_sided_bursts`, `movement_bursts` (muscle with movement inside), `moves` (3+ channels jumping at once) |
| `asleep` | the same over the asleep epochs (N1 N2 N3 R) inside the sleep periods (so `min` equals `total.asleep_min`), plus `jaw_per_hour` and `moves_per_hour` (to 0.1, halves up; `null` with no sleep). `jaw_per_hour` is the night's number for a trend: muscle bursts, not a bruxism count |
| `hours` | per clock hour: `start` (ISO with offset; the first hour starts at `data_start`, the others on the hour), `from_s` (seconds from `data_start`), `min`, `asleep_min`, then the fields of `night`. The first and last hours are partial |

A burst or a movement counts in the epoch where it starts; one starting after the last whole epoch is left out.

## The phone's `files/nights/<date>.report.json`

The phone app scores a finished night itself (`app/lib/sleep/`, DECISIONS rows 95-98) and writes one report per
night into its private `files/nights/` folder, next to `files/recordings/`. Nights are cut by the same chain rule,
the report is rebuilt by the same 10-minute rule, and it has the fields of the laptop's report above, with these
differences: `source` is `phone`; `model` names the phone's version (`anysleep-mid-fusion-3runs@88e13e3 onnx-f16
pieces-1h+15min`); there is no picture, BDF or second model, so `hypnogram`, `sleep_json`, `bdf`, `cross_check`
and each period's `agreement` are `null`; `epoch_s` is 30 and `stages` holds one character per 30 s from
`data_start` (`W 1 2 3 R`, `-` where over 5 s of the epoch was missing), like the `hypnogram` of
`eeg_sleep_night`. `extras` and `extras_error` are as above (the phone runs the detectors beside the sleep model;
a pass that fails leaves `extras` `null` and the night still scored). While a night is being scored a `<date>.scoring`
file sits beside it; if it is still there when
no scoring runs, the last attempt stopped (its text is the error, empty if the app was killed) and the app waits
for "Try again". The report is not exported yet.

## The phone's `files/sound-states/<stamp>.sound.json`

One file per sound-for-states session (`app/lib/states/store.dart`, DECISIONS row 136), in the app's private folder
next to `files/recordings/`; `<stamp>` is lights off (`2026-11-18-231205`). Written when the sound starts (`end`
`running`) and again at the end and when you answer the question. Every `...S` is whole seconds after lights off:
the start of the quiet minute with the headband, the start of the sound without it.

| Field | Meaning |
| --- | --- |
| `version` | 1 |
| `start` | lights off, local ISO time |
| `plan` | `state` (`asleep relax focus pause wake`; `pause` is Break), `bed` (`rain pink brown ocean none`), `beat` (`none pulsed isochronic binaural`), `minutes` of sound, the beat's `fromHz` `toHz` and `rampS` (exponential slide, then held), `carrierHz`, pulse `depth` (gain swings between 1 - depth and 1), `fadeInS` `fadeOutS`, `beatShare` (of the loudness power; the bed has the rest), `targetLufs` |
| `headband` | `headband` (measured), `sound only`, `night recording` (the night held it), `not found`, `lost` (no signal came) |
| `contact` | ohms per channel at the start, `null` = none |
| `recording` | stem of the session's EEG in `files/recordings/` (fall asleep with the headband only), else `null` |
| `soundStartS` `fadeFromS` `offAtS` `endS` | the sound started, began to fade, was silent; the session ended (`null`: never reached) |
| `end` | `time`, `cap` (45 min after lights off), `asleep`, `stopped`, `failed`, `running` |
| `baselineS` | clean seconds in the quiet minute (a comparison needs 20) |
| `epochs` | per 30 s of sound with a clean second: `i` (epoch from the sound's start), `cleanS`, and medians of `alpha` (8-12 Hz), `slow` (4-7 Hz) and `echo` (power at the beat's rate) as ratios to the quiet minute, O1/O2, the beat's rate and twice it (± 1 Hz) left out of alpha and slow; `null` when not computable |
| `summary` | the same over the whole sound, `null` without a comparison |
| `drift` | fall asleep with the headband: the drift-off detector's `baselineAlpha`, `baselineS`, `drowsyS`, `onsetS`, `asleepAtS` and `epochs` (one letter per 30 s from lights off: `b` baseline, `a` awake, `d` drowsy, `s` probably asleep, `-` skipped) |
| `events` | `{s, text}` in plain words: quiet minute, sound on (with the plan's line), fading and why, headband drops, the end |
| `stalls` | times the sound ran dry because the app fell behind (0 is right) |
| `engine` | the audio engine's report (sample rate, buffer, lead, output delay) |
| `night` | fall asleep with "Record the night": `started`, or why it did not start |
| `rating` | your answer to "did it help you get there?", 1 (not at all) to 5 (clearly), `null` = not answered |

## Morning check-in markers and `<start>.morning.json`

`scripts/web/morning.html` writes these marker texts, in order: `morning:start`, `morning:eyes_closed:start`,
`morning:eyes_closed:end`, `morning:eyes_open:start`, `morning:eyes_open:end`,
`morning:ratings {"kss":5,"mood":3,"tension":2}`, `morning:end`; `morning:abort` if stopped (the session is then
ignored). The setup test writes `setup:start`, `setup:blink` (at each cue), `setup:glance:left` / `right`,
`setup:clench:start` / `end`, `setup:end` (`setup:abort` if stopped).

`scripts/morning_check.py` writes `version`, `source`, `start`, `end`, `date`, `phase_s` (seconds between the
markers of each phase), `channels` (per back channel: the fields of the event below plus `clean_s_ec`,
`clean_s_eo` and `alpha_peak_above_1f`), `back` (O1 and O2 combined), `ratings`, `setup_test` (or `null`),
`method` (the analysis settings), `device`, `validated`, and `compared`: one row per measure shown on the pages
(`key` such as `back.iaf_hz`, `label`, `value`, `text` as printed, `earlier` = how many earlier check-ins have it,
`comparison` = the printed "your last N: median, range: within / above / below your range" text, and when there
are earlier ones `median`, `low`, `high`, `where`; clean data in percent). Earlier `*.morning.json` files in the
same folder are the history it compares with (the last 14 before this one). Started by the morning page
(`POST /morning-report`), it runs with `--job-dir <nights> --export <root>`: one run at a time
(`morning-report.lock`, progress in `morning-report.status.json`, output in `morning-report.log`), and it appends
the `eeg_morning_check` event itself.

## The phone's `files/mornings/`

The phone app runs the morning check-in itself (DECISIONS rows 120 and 125) and keeps each one in its private
`files/mornings/` folder (not `files/recordings/`: a check-in there would join the night before it):

- `<stamp>.f32`, `.idx`, `.log`: the raw signal of the whole visit (contact step included), the recorder's format
  above; `<stamp>` is when the signal began.
- `<stamp>.markers.jsonl`: the laptop page's markers (`morning:start`, `morning:eyes_closed:start` ... `morning:end`),
  `i` counting samples of that `.f32`. `scripts/morning_check.py` analyses an exported copy as it is.
- `<start>.morning.json`: the result, every field of the laptop's `<start>.morning.json` above (same names, same
  rounding, `compared` against the last 14 earlier phone check-ins), worked out on the phone from the samples
  rounded to float32 as the laptop reads them, so both give the same numbers. Added by the phone:

| Field | Meaning |
|---|---|
| `app` | `phone` |
| `habits` | `caffeine_cups` (cups of coffee, strong tea or energy drinks the day before, 0-5, 5 = 5 or more), `caffeine_late` (any in the 8 hours before sleep; `false` with no cups), `caffeine_today` (caffeine before this check-in), `alcohol_drinks` (0-5, 5 = 5 or more) |
| `reaction` | the 1-minute reaction test: `median_ms` (`null` with under 5 taps), `taps`, `lapses` (over 500 ms), `false_starts`, `length_s`; `null` when skipped |
| `contact` | `{O1, O2, T3, T4}` ohms from the contact check at the start, `null` = no contact |

A stopped check-in, or one whose headband dropped out, leaves no files. Nothing is exported yet.

## Events (for utof_tracker and anything else)

Same envelope and rules as utof_tracker's `docs/data-format.md`, so its readers can take these lines as they are:
one UTF-8 JSON object per line ending in `\n`; a reader ignores a last line without a newline; readers
de-duplicate by `id`; an update is a new event whose `data.replaces` is the old `id`, and the newest wins.

```json
{"v":1,"id":"eeg:3f2a…","dev":"eeg-pc-1a2b3c4d","seq":1,"ts":"2026-11-18T02:40:13+03:00","tz":"Europe/Moscow","type":"eeg_sleep_night","data":{…}}
```

- `dev`: `eeg-pc-` + 8 random hex characters, made once per export folder (`<root>/device_id`); the phone app
  will use `eeg-phone-…`.
- `id`: `eeg:` + sha1 of the night's start, model and hypnogram, so exporting the same result twice adds nothing.
- `ts`: the start of the recording that night, with the UTC offset.

### `eeg_sleep_night`

| Field | Meaning |
|---|---|
| `night_of` | the evening's date (start minus 12 hours), as in utof_tracker |
| `start`, `end` | first and last moment with scored data (ISO with offset) |
| `sleep_onset`, `final_wake` | first sleep epoch, end of the last sleep epoch; `null` if no sleep was scored |
| `total_sleep_min`, `wake_after_onset_min` | from the AnySleep stages, gap epochs excluded |
| `stage_min` | `{W, N1, N2, N3, R}` minutes |
| `recorded_min`, `gap_min` | scored time and time lost to gaps |
| `hypnogram` | one character per 30 s from `start`: `W 1 2 3 R`, `-` for a gap |
| `epoch_s` | 30 |
| `model` | the stager behind the stages, e.g. `anysleep-mid-fusion-3runs@88e13e3` |
| `cross_check` | `{model, agreement_5_stage, agreement_w_nrem_rem}` |
| `confidence` | mean top probability of the stager |
| `validated` | `false` until the stager has been checked against nights scored by hand on this headband |
| `device` | headband model and channels, e.g. `{"model": "BrainBit Black", "channels": ["O1","O2","T3","T4"]}` |
| `replaces` | the `id` of an earlier result for the same night, when re-scored |

`sleep_night` in utof_tracker is the phone's own estimate; `eeg_sleep_night` is a separate type so neither
overwrites the other. utof_tracker does not read these files yet: that needs a change there, made with the owner.

### `eeg_morning_check`

One event per morning check-in. `ts` is the moment the eyes-closed phase started; `id` is `eeg:` + sha1 of
the start and the result, so exporting the same result twice adds nothing. Values are the person's own numbers,
meant to be compared with their own earlier mornings, not with norms.

| Field | Meaning |
|---|---|
| `date` | local date of the check-in |
| `start`, `end` | start of eyes closed, end of eyes open (ISO with offset) |
| `phase_s` | `{eyes_closed, eyes_open}` seconds between the phase markers |
| `alpha_ec_uv2`, `alpha_eo_uv2` | alpha power 8-13 Hz (µV²), eyes closed / eyes open, back channels combined (geometric mean of O1, O2) |
| `ec_rise` | eyes-closed rise: alpha eyes closed / alpha eyes open (geometric mean of O1, O2) |
| `iaf_hz` | alpha speed: centre of gravity of the power above the 1/f line in 7-14 Hz, eyes closed (mean of O1, O2); `null` without a clear alpha peak |
| `aperiodic_slope_ec` | slope of log power on log frequency, 2-40 Hz without 7-14 Hz, eyes closed (negative; steeper = more negative) |
| `clean_share` | share of 2 s segments kept after artefact rejection, both phases, both back channels |
| `channels` | `{O1, O2}`, each with `alpha_ec_uv2 alpha_eo_uv2 ec_rise iaf_hz iaf_peak_hz alpha_peak_present aperiodic_slope_ec clean_share_ec clean_share_eo` |
| `ratings` | `{kss, mood, tension}`: Karolinska Sleepiness Scale 1-9, mood 1-5 (very bad to very good), tension 1-5 (none to very much); `null` if not rated |
| `setup_visible` | from a setup test in the same recording: `{blink, glance, clench}` true / false; `null` if none |
| `method` | analysis version, e.g. `morning-v1` |
| `validated` | `false`: the measures follow the literature but are not yet checked for day-to-day repeatability on this headband |
| `device` | headband model and channels |
| `replaces` | the `id` of an earlier result for the same check-in, when re-analysed |

### `break_hint`

Written by `scripts/break_hints.py` ([break-hints.md](break-hints.md)) to `breaks-YYYY-MM.jsonl` in the same
device folder, one event per thing that happened. `ts` is when it happened (local time with offset); `id` is
`eeg:` + sha1 of device, type, `ts`, kind and hint; `seq` continues from the highest `seq` in the folder.

| Field | Meaning |
|---|---|
| `kind` | `shown` (a hint appeared), `snoozed` (Snooze 20 min pressed), `dismissed` (OK pressed), `taken` (an AFK stretch of 5+ min began within 30 min of the hint) |
| `active_min` | active minutes counted when the hint was shown (0 for `taken`) |
| `threshold_min` | the threshold in force then, back-off included |
| `hint` | for `snoozed`, `dismissed`, `taken`: the `id` of the `shown` event it answers |

A hint closed or expired without a button press adds no event; "ignored" means `shown` with no `taken` after it.
