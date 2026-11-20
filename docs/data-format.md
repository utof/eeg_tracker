# Data format

Three layers, from raw to summary. Each is written once and never edited in place.

| Layer | Files | Written by |
|---|---|---|
| Raw recording | `<stamp>.f32`, `<stamp>.idx`, `<stamp>.log`, `<stamp>.markers.jsonl`, `<stamp>.header.json` (one set per recorder run; the header since 2026-11-20) | `scripts/record_night.py` or `scripts/record_ble.py` (laptop, both through `scripts/recorder_hub.py`); the phone app will write the same kind of add-only chunks |
| Raw recording, DIY board | the same four files in `_local/recordings-diy/` (one set per board capture) | `scripts/record_diy.py` (through `scripts/recorder_hub.py`; below) |
| One night | `<night>.bdf` (BDF+, 24-bit, µV), `<night>.sleep.json`, `<night>.hypnogram.png` | `scripts/to_bdf.py`, `scripts/score_sleep.py` |
| Sleep report | `_local/nights/<date>.report.json` beside that night's `<date>.bdf`, `.sleep.json`, `.hypnogram.png` | `scripts/sleep_report.py` (the Sleep page starts it) |
| Sleep report on the phone | `files/nights/<date>.report.json` in the app's private folder | the phone app after Stop (`app/lib/sleep/scorer.dart`) |
| Morning check-in | `<start>.morning.json` (or `<start>.setup.json` for a setup test alone) | `scripts/morning_check.py` |
| Morning check-in on the phone | `files/mornings/<start>.morning.json` and the visit's raw `<stamp>.f32/.idx/.log/.markers.jsonl` | the phone app (`app/lib/morning/`) |
| The phone's export folder | `<picked folder>/eeg-export/`: the app's files in their own layout, `manifest.json`, `exports.jsonl` | the phone app's Export data (`app/lib/export/`); read by `scripts/import_phone.py` |
| The phone over Wi-Fi | `GET /files`, `GET /files/<path>` on the phone; mirrored into `_local/recordings/` and `_local/phone/`, with `_local/phone/pull-state.json` and `pulls.jsonl` | the phone app's Share on Wi-Fi (`app/lib/share/`); read by `scripts/pull_phone.py` |
| The laptop's work sessions | `_local/laptop/work/<stamp>.work.json`, `labels.jsonl` (below) | the laptop tray (`scripts/tray.py`, `scripts/laptop_work.py`) from ActivityWatch |
| Catalog of nights | `_local/catalog/catalog.json`, `<date>.sha256`, `catalog.txt`, `history.log` | `scripts/catalog.py` (below) |
| Raw recordings packed after a day | `<stamp>.f32.xz` on the laptop, `<stamp>.f32.gz` on the phone, in place of `<stamp>.f32`; `_local/packing.jsonl`, `files/packing.jsonl` | `scripts/pack_old.py` (daily), the phone app between nights (`app/lib/recorder/packed.dart`); below |
| Events for other apps | `<root>/events/<dev>/eeg-YYYY-MM.jsonl`, `<root>/events/<dev>/breaks-YYYY-MM.jsonl` | `scripts/export_events.py`, `scripts/break_hints.py` and the laptop tray |

## Raw recording (BrainBit)

- `.f32`: records of `<I4f` (little-endian): BrainBit packet number, then O1 O2 T3 T4 in **volts** as the
  headband sent them. 250 records a second. The bytes are the same as before the recording header existed; since
  2026-11-20 a `<stamp>.header.json` beside them says so (below).
- `.idx`: one `<dQ` record per batch that arrived: unix time of arrival (float seconds) and the index of the
  batch's first record. Gaps are found from these times; packet numbers can repeat. With our own driver (`record_ble.py`) one run
  spans the whole night: a Bluetooth drop leaves a gap in these times inside the same file, and the packet number
  starts again after each reconnect.
- `.log`: plain text, one line per event: connection (model, signal strength), contact resistance in ohms, a
  sample count and battery reading every 10 s, stalls and restarts. On the phone a run that ends in a drop logs
  `drop (out of range | no data | run failed); last data <time>; reconnecting`, then one line per try,
  appended after its data files are closed: `reconnect try N (direct to <address> | scan): connected | not found |
  failed after <s> s ...`. The next run's `.log` starts with `reconnected (direct | scan, try N) after a drop`,
  the previous run's stem and the time of its last data.
- `.markers.jsonl`: one JSON object per line from pages that `POST /marker`: `t` (unix time the marker
  arrived), `i` (index of the next sample in this file's `.f32`, so markers line up with samples even across
  gaps) and `text`. `scripts/to_bdf.py` turns them into BDF+ annotations at their clock time. The phone's night
  recorder writes `lights off` when the night screen's Lights off is tapped (between file sets: beside the last one,
  with that file's sample count as `i`; before the first: into the first) and the live drift-off detector's moments
  (DECISIONS 180-184): `drift-off: eyes-closed baseline done`, `drift-off: drowsy`, `drift-off: probably asleep,
  onset HH:MM:SS`, `drift-off: awake` (alpha back before sleep) and `drift-off: awake again`; each also as a line in
  the `.log`. Lights off for the sleep report (`drift_off` below) is the latest marker of the night whose text is
  `lights off`, starts with `dream catcher: lights off`, or is `sound: quiet minute (eyes closed)`.
- On the phone the night's `.log` also says `drift-off detector on; lights off counts from the first sample until
  Lights off` at the start, `drift-off detector stopped: <why>; the recording goes on` if it was switched off, and at
  the end `drift-off detector: <s> s of work for <h> h of signal (<s> s an hour)`.
- The device's Bluetooth address and serial number are in the `.log`. They stay on the owner's machine
  (`_local/` is never committed).

## Raw recording (DIY board)

`scripts/record_diy.py` ([diy-board.md](diy-board.md)) writes the same files for the owner's ADS1299 board, into
`_local/recordings-diy/` (not `_local/recordings/`: the board's nights are never scored; the sleep and morning tools
read O1 O2 T3 T4, by name since 2026-11-20). The phone app writes the same layout for the 4-, 6- and 8-channel chips
into its `files/recordings-diy/` (Wi-Fi route; diy-board.md "On the phone"): its `.log` names the link `UDP port 9000 on every IPv4 interface (Wi-Fi route)`, each sender (`datagrams
from <address>`), `a new capture: board restarted (<why>)` at the start of a set after a restart, and has the phone
recorder's own lines (`connected DIY board udp:9000 (no battery or signal-strength reading from this board)`,
`samples N (+n)`, `reconnected (scan, try n) after a drop`).

- `.f32`: records of `<I` + one `f` per channel (`<I4f`, 20 bytes, for the 4-channel chip, the BrainBit's record;
  `<I6f` for 6 channels; `<I8f`, 36 bytes, for the 8-channel chip): the board's sequence number (its data-ready count
  since it started; a jump is a missing frame, never filled in), then the channels in **volts** (counts x VREF /
  (gain x 2^23)). The `<stamp>.header.json` names them (below); the phone records 4, 6 and 8 channels since
  2026-11-20 (before, the 4-channel chip only).
- `.log`: the same kind of lines, plus, when the file set opens: `driver DIY board ...; link <USB serial port and
  baud | UDP host:port>`, `channels <names> (montage <file>: reference ...; bias ...)`, `board <n> channels, <fs> Hz,
  gain <g>, vref <V> V (assumed ...)`, `format .f32 records <I<n>f: board sequence number, then <names> in volts;
  <fs> Hz` and `mode <test signal | shorted inputs | ...>: ..., not EEG (flags 0x..)`. Later: `lost N samples in M
  gaps (board missed X, link lost Y)`, `bad frames N, bytes skipped N`, `repeated N, late N frames dropped`, `board
  says: <the firmware's own text line>`, `board link lost or not found: ...` / `board link back after N s`, `no data
  from the board for 5 s`, and at a board restart `board restarted (<why>): this file set ends here` in the old log
  and `continues <old stamp> after a board restart (<why>)` in the new one. The 10 s line says `battery ?%` (the
  board reports none).
- `.idx` and `.markers.jsonl`: as for the BrainBit. A USB drop while the board keeps running stays in one file set,
  with the gap in the `.idx` times.

## The recording header (`<stamp>.header.json`)

Owner's rule (2026-11-20): "always remember we're making features with custom arrangements and numbers of electrodes
in mind" (the DIY helmet: 8, later 16 channels at its own sites). Since 2026-11-20 every file set has a header that
says what its `.f32` holds, so a record can carry any number of channels (DECISIONS 630-639). The `.f32` record is
`<I` + one `<f` per channel: `<I4f` (20 bytes) for 4 channels, `<I8f` (36 bytes) for 8, `<I16f` (68 bytes) for 16.

- Written once, when the file set opens and before its first sample (under a temporary name, then renamed), and never
  changed. Plain JSON, UTF-8, small (under 4 KiB for 16 channels); never packed (only the `.f32` is).
- Written by the phone app (`app/lib/recorder/header.dart`, every recording: nights, check-ins, sessions) and the
  laptop's recorders (`scripts/recorder_hub.py`, `scripts/recording.py`).

| Field | Meaning |
|---|---|
| `format`, `version` | `eeg-tracker-recording`, 1. A reader refuses a higher version in words (written by a newer app). |
| `channels` | the channels in record order, 1 to 64 objects: `name` (as the device names it, 1-32 characters, each name once; `O1`, `T3`, `Ch5`), `site` (its 10-10 name when it is one, old names as the new: `T3` -> `T7`; or `null`), `xyz` (its direction on the head, unit length: right, front, up; or `null` when not known) |
| `sample_rate` | samples a second (BrainBit 250; the DIY board its own rate) |
| `unit` | `V`: the floats are volts |
| `record` | `<I` + the channel count + `f`, e.g. `<I4f`; must match `channels` |
| `counter` | what the uint32 is: `packet number` (BrainBit) or `board sequence number` (DIY board) |
| `device` | `BrainBit`, `DIY board`, ... (optional) |
| `layout` | the layout the names and positions come from: `BrainBit`, `DIY board`, `Helmet plan (8)`, a montage file name, ... (optional) |
| `reference`, `ground` | `{"name", "where", "site"}` (`where` in words, `site` a 10-10 name or `null`), or `null` when not known. BrainBit: `Ref`, `forehead`, `Fpz`; the DIY board: `Ref` on an earlobe (`A1`) and `Bias` on the other (`A2`), a plan |
| `made_by` | the program that wrote it (optional) |

Required: `format`, `version`, `channels`, `sample_rate`, `unit`, `record`, `counter`; a missing `reference` or `ground`
reads as `null`. A `site` is text of up to 16 characters (the writers fill it only for 10-10 names and A1 A2 M1 M2); an
`xyz` counts as unit length within 0.01. Unknown fields are ignored (a later version 1 may add some). A header that is
not valid JSON or breaks a rule above is an error that names the file: readers never guess past a damaged header.

- **Phone**: `app/lib/recorder/header.dart` (`readHeader`, `RecordingHeader.pick`); places (`xyz`) from the layout
  of the Signal tab and its positions file.
- **Laptop**: `scripts/recording.py` (standard library) reads, checks and writes it; every reader asks it what a
  `.f32` holds (`read`), and features find their channels with `pick`. The laptop writes `xyz` as `null`.

```json
{"format": "eeg-tracker-recording", "version": 1, "device": "BrainBit", "layout": "BrainBit",
 "channels": [{"name": "O1", "site": "O1", "xyz": [-0.309, -0.9511, 0.0]}, {"name": "O2", "site": "O2", "xyz": [0.309, -0.9511, 0.0]},
              {"name": "T3", "site": "T7", "xyz": [-1.0, 0.0, 0.0]}, {"name": "T4", "site": "T8", "xyz": [1.0, 0.0, 0.0]}],
 "reference": {"name": "Ref", "where": "forehead", "site": "Fpz"}, "ground": null,
 "sample_rate": 250, "unit": "V", "record": "<I4f", "counter": "packet number", "made_by": "eeg_tracker app"}
```

**Files without a header** (everything recorded before 2026-11-20) read as before, in this order:

1. the `.log`'s format line, `format .f32 records <I<n>f: board sequence number, then <names> in volts; <fs> Hz`
   (the DIY board's files, laptop and phone), looked for in the first 256 KiB of the `.log`: n channels at fs, the
   names from that line (`Ch1`..`Chn` when it does not hold n different names), device `DIY board`;
2. otherwise the BrainBit's: `O1 O2 T3 T4`, 250 Hz, volts, `<I4f`.

**Channels by name.** A feature that needs particular sites picks them by name from the header, never by place:
the sleep model (AnySleep), the night extras and the drift-off detector need `O1 O2 T3 T4`, the morning check-in's
measures `O1 O2` (its setup test and the phone's check-in all four). A channel matches by its exact name first, else
by its `site` (`T7` stands for `T3`, `T8` for `T4`, `P7` for `T5`, `P8` for `T6`, in any letter case). When a recording
lacks one, the feature says which sites it needs and which channels the recording has (`the sleep model needs O1 O2
T3 T4; this recording (DIY board: Ch1 ... Ch8) has no O1, O2, T3, T4`), and does not run: it never reads another
channel in its place. A night without them gets no sleep report: `sleep_report.py` says which sites are missing,
writes nothing for it, builds the other nights and exits 1; the phone's scorer keeps the same words as the night's
failure.

## Packed raw recordings (`<stamp>.f32.xz`, `<stamp>.f32.gz`)

Owner's decision (2026-11-19): raw recordings that nothing has written for a day are compressed, losslessly
(DECISIONS 540-549). Only the `.f32` is packed; its `.idx`, `.log` and `.markers.jsonl` stay plain beside it (small,
and the nights' chaining reads the last `.idx` row of every recording). Files under 64 KiB stay plain.

- **Laptop**: `<stamp>.f32.xz`, a standard xz file (`xz -d` gives back the `.f32`; `xz -lvv` shows the original's
  SHA-256 as the block's CheckVal: the file is one block with a SHA-256 check, so every unpacking checks it) with the
  `.f32`'s modified time. `scripts/pack_old.py` packs `_local/recordings/`, `_local/recordings-diy/` and
  `_local/phone/mornings/` and appends one line per run to `_local/packing.jsonl`: `packed` (time), `files`,
  `bytes`, `packed_bytes`, `failed`, `list` (`path`, `bytes`, `packed_bytes`, `sha256` of the original) and
  `problems` (`path`, `why`). A real night: 61 % smaller.
- **Phone**: `<stamp>.f32.gz` in `files/recordings/`, `files/recordings-diy/` and `files/mornings/`, a standard gzip
  file (`gunzip -N` gives back the `.f32` with its name and time) whose header holds the name (FNAME), the time in
  seconds (MTIME) and, in the comment field (FCOMMENT), `{"name", "bytes", "sha256", "modified_ms"}` of the `.f32`;
  the file keeps the `.f32`'s modified time. `files/packing.jsonl` has the laptop's fields (exported with the rest).
  A real night: 40 % smaller.
- Both are written under a temporary name (`.<stamp>.f32.xz.packing`, `.<stamp>.f32.gz.packing.tmp`), unpacked to
  check the length and SHA-256, given the original's time, renamed into place, and only then is the `.f32` removed.
- Readers use the plain name: a sleep report's `inputs` keep naming `<stamp>.f32` with its unpacked size, so a report
  stays up to date when its night is packed. On the laptop `scripts/packed.py` opens all three forms (plain, `.xz`,
  and the phone's `.gz` in an export folder or a copy of the phone's files); on the phone `packed.dart` does.

## One night (BDF+)

- One signal per channel of the recordings, labelled with the channel's name (BrainBit: `O1 O2 T3 T4`), at the
  recordings' rate (250 Hz for the BrainBit); unit `uV`, physical range ±400 000 µV, 1 s data records, `BDF+C`.
  Recordings that hold different channels or rates are not joined (`to_bdf.py` names both). A label holds up to 16
  ASCII characters; a longer name is refused.
- File time equals clock time: missing time (Bluetooth drops, restarts) is filled by holding the last value and
  covered by a `BAD_gap` annotation; the end is padded to a whole second (`BAD_padding`). MNE treats
  annotations starting with `BAD` as bad data.
- The header start time is local clock time without a zone (EDF has none; MNE will call it UTC).

## `<night>.sleep.json`

`start` (local, no zone), `epoch_s` (30), `scorer` (how AnySleep went over the night: `pytorch one-pass` up to
14 hours, `onnx-f16 two-pass-64min+8min` for a longer night, as the phone scores; DECISIONS 310; absent in files from
before 2026-11-19), `summary` (minutes per stage, sleep onset, total sleep, agreement of the two models) and `epochs`: one object per 30 s with `t`, `anysleep` and `yasa` (`W N1 N2 N3 R`, or
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
| `drift_off` | when you fell asleep after lights off, by the drift-off detector and by the sleep model (below); `null` when unscored or when the detector did not run. Added 2026-11-19 without a new `version`: a version-2 report without this key was written before it and is rebuilt once |
| `drift_off_error` | why the drift-off detector did not run (the detectors' pass failed, or the detector itself), else `null` |

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

### `drift_off` (falling asleep, DECISIONS 180-184)

Written by `analysis/night_drift.py` on the laptop and `app/lib/sleep/drift.dart` on the phone with the same rules.
Lights off is the night's latest lights-off marker (above), else its first sample (`night start`); it is moved to the
start of the next 30 s epoch from `data_start` (the stages' epochs), and the drift-off detector (DECISIONS 88) runs
over the night from there. The sleep model's onset is the first epoch at or after lights off of 10 in a row not
scored awake (`gap` epochs skipped). Seconds are counted from `data_start`.

| Field | Meaning |
|---|---|
| `version` | 1 (of this object) |
| `rules`, `validated` | the rules in words, `false` |
| `lights_off`, `lights_off_s` | the moment both count from (ISO with offset; seconds, a multiple of 30) |
| `source` | `button` (the night screen), `dream catcher`, `sound` (a fall-asleep session's quiet minute) or `night start` (no marker) |
| `tapped` | the marker's own time (ISO), `null` for `night start` |
| `baseline_s`, `drowsy_s`, `onset_s`, `known_s` | the detector: its 60 clean eyes-closed seconds complete, drowsy first known, the first "probably asleep" run's start (the onset) and when it was known; `null` = never |
| `model_onset_s`, `onset`, `model_onset` | the sleep model's onset in seconds; both onsets as ISO times |
| `onset_min`, `model_onset_min`, `diff_min` | minutes from lights off to each onset (half minutes), the detector's minus the model's |
| `agree` | `true` when both found sleep at most 5 minutes apart, `false` when farther apart or only one found sleep, `null` when neither did |
| `counted` | the night counts toward the check (4 of the newest 5 counted nights agree: the detector ships, DECISIONS 62): `source` is not `night start` and `agree` is not `null` |
| `epochs` | the detector's state after each 30 s from lights off: `b` learning the baseline, `a` awake, `d` drowsy, `s` probably asleep, `-` skipped |

## The phone's `files/nights/<date>.report.json`

The phone app scores a finished night itself (`app/lib/sleep/`, DECISIONS rows 95-98) and writes one report per
night into its private `files/nights/` folder, next to `files/recordings/`. Nights are cut by the same chain rule,
the report is rebuilt by the same 10-minute rule, and it has the fields of the laptop's report above, with these
differences: `source` is `phone`; `model` names the phone's version (`anysleep-mid-fusion-3runs@88e13e3 onnx-f16
two-pass-64min+8min` since 2026-11-19, `... pieces-1h+15min` before; a scored report naming another version is
scored again once); there is no picture, BDF or second model, so `hypnogram`, `sleep_json`, `bdf`, `cross_check`
and each period's `agreement` are `null`; `epoch_s` is 30 and `stages` holds one character per 30 s from
`data_start` (`W 1 2 3 R`, `-` where over 5 s of the epoch was missing), like the `hypnogram` of
`eeg_sleep_night`. `extras` and `extras_error` are as above (the phone runs the detectors beside the sleep model;
a pass that fails leaves `extras` `null` and the night still scored), and so are `drift_off` and `drift_off_error`. The phone
adds `wearer_signal` and, once the owner answers "Was this you?", `wearer` (both below, "Was this you?"). While a night is being scored a `<date>.scoring`
file sits beside it; if it is still there when
no scoring runs, the last attempt stopped (its text is the error, empty if the app was killed) and the app waits
for "Try again". Export data copies the reports out (below).

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
| `audio` | where the sound went at the start (DECISIONS rows 471-472): `route` (`speaker wired bluetooth bluetoothLe other unknown`), `type` (Android's device type, e.g. `a2dp`) and `device` (its name) when known; absent when the phone could not say. A change during the session is an event (`audio route: ...`) |
| `trial` | only on a session played for a fair test of two sounds (below): `plan` (the test's id), `day` (the day key it counts for, `2026-11-20`; a day runs 04:00 to 04:00) and `sound` (`a` or `b`, that day's draw). Absent in files from before fair tests; such sessions count in the comparison over weeks but never in a test |

Next to the sessions, `files/sound-states/settings.json` holds one choice, `{"screenStaysOn": true}` (Screen:
Stays on; absent or false: the phone can be locked during a session, DECISIONS row 193).

### Fair tests of two sounds: `files/sound-states/plans/<id>/`

One folder per test (`app/lib/states/trial_store.dart`, DECISIONS rows 434-438), `<id>` = when it was made and the
state, `2026-11-19-090000-asleep`; the self-experiments' layout:

- `sealed.json`: `salt` (the 32-byte secret, hex) and `allocation` (one character a day, `1` = sound a, `0` =
  sound b), drawn by the self-experiments' `drawDays`; written once, before the plan.
- `plan.json`: `{plan, sha256}`. The plan: `version` 1, `id`, `created`, `state`, `sounds` (`a` and `b`, each `bed`,
  `beat` and the `line` as shown), `minutes` (every session of the test), `start` (day 1, the day after it was made),
  `days`, `unlocks` (the day the answer opens: start + days + 1), `primary` (the number: `label`, `how`, `compared`,
  `matters`, `weak`), `design`, `analysis`, `words`, `honesty` (in words, as the app applies them) and
  `allocationSha256` (SHA-256 of `sealed.json`'s canonical JSON); `sha256` is the plan's own. Written once.
- `progress.json`: `stopped` (`at`, `day`, `daysDone`) when the test was stopped early; the self-experiments'
  `kept` and `early_looks` stay empty.
- `events.jsonl`: `plan frozen` (with the plan's hash), `stopped`.

A day's number is the first session of that day with the test's `trial` tag, the day's sound and a number (the
comparison's rules: `app/lib/states/weeks.dart`); the answer is worked out on the phone each time it is shown, never
saved.

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
| `wearer` | only once the owner answered "Was this you?": `answer` (`me` or `someone else`) and `at` (local ISO time); a check-in marked `someone else` is left out of the trends (below, "Was this you?") |

A stopped check-in, or one whose headband dropped out, leaves no files. Export data copies them out (below).

## Dream catcher answers as text (`files/dream-catcher/<stamp>-r<n>.text.json`)

One small JSON beside each answer's WAV, written by the phone's speech to text after the session (DECISIONS rows
250-256) and whenever you change the words. App-private, no backup; Export data copies it with the WAVs. Missing
until the answer has been tried; nothing else refers to it.

| Field | Meaning |
|---|---|
| `version` | 1 |
| `answer` | the WAV in the same folder, `<stamp>-r<n>.wav` |
| `machine` | what the phone heard, or `null` until it has worked: `text` (empty = no words heard), `model` (`parakeet-tdt-0.6b-v3-int8`), `at` (local ISO time), `audioS` (seconds in the WAV), `voiceS` (seconds the voice detector kept, its parts widened 0.25 s), `tookS` (seconds the phone took, model loading excluded) |
| `edited` | your own words for the answer when you changed them, else `null`: shown instead of `machine.text` and never overwritten by the machine (a later model may rewrite `machine`); an edit back to the machine's text is stored as `null` |
| `tries` | attempts so far, counted when one starts; after 2 without a `machine` text the answer waits for Try again (which sets it to 0) |
| `failed` | why the last attempt did not work, or `null`; the WAV is always kept |

## The phone's export folder (`eeg-export/`)

**Export data** in the phone app (DECISIONS rows 150-156) copies everything the app keeps in its private `files/`
folder into `eeg-export/` inside a folder the owner picked once (for example `Download/EEG`, or the phone's Syncthing
folder). It never changes or deletes anything in the app's folder, and never runs while a night records.

- The layout is the app's own: `recordings/` (raw nights, the recorder's format above), `nights/<date>.report.json`,
  `mornings/`, `meditations/`, `alpha-theta/` (sessions and `journal.json`), `replay-check/<kind>/` and
  `settings.json`, `experiments/<made at>/` (self-experiments, below), `wearer/` ("Was this you?", below), `dream-catcher/` (sessions, `<stamp>-r<n>.wav` answers and their `<stamp>-r<n>.text.json` words, below, `prompts/`), `sound-states/`, `hands-free/` (below), `unusual/` (below), `lucid/` (below), `try-these/` (below), `own-ble/`
  (`settings.json`: which headband connection is in use; `probe/<stamp>/`: the probe's result, docs/own-ble-driver.md),
  `recordings-diy/` (the DIY board's nights, the format of "Raw recording (DIY board)") and `diy-board/settings.json`
  (`useDiy`: which headband; `names`: 4, 6 or 8 names from CH1), and any folder
  a later feature adds. Left on the phone: `models/` (copies of the app's model assets), `export/` (the export's own
  index), half-written `*.tmp` files, the scorer's `*.scoring` markers, and the two files Android and a plugin keep
  there for themselves (`profileInstalled`, `flutter_callback_cache.json`; DECISIONS row 160).
- **Export new** copies files that are new or changed (size or modified time) since the last export to this folder;
  **Export everything** copies every file again. A file is replaced whole; files the app rewrites (a session file
  once you answer its question, a dream note, the alpha-theta journal, a rebuilt sleep report) are copied again.
- `manifest.json` is written last, every time. It lists every file exported to this folder so far:

| Field | Meaning |
|---|---|
| `format`, `version` | `eeg-tracker-phone-export`, 1 |
| `exported` | when this export ran (local ISO time with offset) |
| `mode` | `new` or `everything` |
| `complete` | `false` when the export stopped before copying everything it meant to |
| `files` | one object per file, sorted by path: `path` (relative, `/`-separated), `bytes`, `sha256` (of the bytes written, worked out while copying), `modified_ms` (the phone's modified time of that copy, ms since 1970), `written` (the `exported` time of the export that copied it); `on_phone: false` when the app no longer has the file (a `.f32` the phone packed is still on it); `original` (`path`, `bytes`, `sha256` of the `.f32`) for a recording packed after a day, sent as its `.f32.gz` |
| `not_exported` | paths still only on the phone (the export stopped, or the folder failed) |
| `totals` | `files`, `bytes` of the list |

- `exports.jsonl`: one line per export (`exported`, `mode`, `files`, `bytes`, `complete`, `error`), the phone's log
  copied whole.
- The manifest keeps listing a file after the owner deletes it from the export folder (to free space after an
  import): the laptop then checks it has that file with the same SHA-256.
- A recording packed after a day leaves as its `.f32.gz`, with `original`; one whose `.f32` was exported before it
  was packed is not exported again (**Export everything** copies the `.f32.gz` too).

### Self-experiments (`experiments/<made at>/`)

One folder per experiment (DECISIONS rows 200-209), named by when it was set up (`2026-11-19-143000`). The first two
files are written once, before day 1, and never change; please do not open `sealed.json` before the app shows the
answer: it holds the days ahead.

| File | Content |
|---|---|
| `sealed.json` | `salt` (the random secret, 64 hex characters) and `allocation` (one character per day from day 1: `1` = a "do" day, `0` = a "don't" day). The order can be drawn again from the salt alone |
| `plan.json` | `plan` and `sha256` (SHA-256 of `plan` as JSON with sorted keys and no spaces). `plan`: `version` 1, `id`, `created`, `question` (`preset` id or `custom`, `do`, `dont`: the two lines), `primary` (`id` and `label` of the one tested number, which `day` it is read on, how it is `compared`, `matters`: the smallest difference that matters), `start` (day 1, `YYYY-MM-DD`; a day runs 04:00 to 04:00), `days`, `unlocks` (the day the answer opens), `design`, `blockSize`, `analysis`, `words`, `secondary`, `honesty` (the rules in words) and `allocationSha256` (SHA-256 of `sealed.json`'s content in the same canonical form) |
| `progress.json` | `kept` (day -> `true` kept, `false` not kept; no entry = not answered), `early_looks` (each `at`, `day`, `daysDone`), `stopped` (the same, when the owner stopped it) |
| `events.jsonl` | one line per event: `plan frozen` (with the plan's hash), `answer` (`day`, `kept`), `early look`, `stopped` |

The tested number of day D is the trends' per-day number of day D+1 (from `nights/` and `mornings/`); the app works
the answer out again from those files each time, so nothing else is stored.

### Hands-free controls (`hands-free/`)

The switch and the newest calibration (DECISIONS rows 240-249); each file is written under a temporary name, then
renamed. A missing or damaged file reads as "off" and "not calibrated".

| File | Content |
|---|---|
| `settings.json` | `on` (the one switch, off by default) and `changed` (local ISO time) |
| `calibration.json` | `made`; `settings`: `clenchX` (the clench line, times the jaw's rest level, 10-60), `glanceUv` (the look size, µV, 70-250), `leftSign` (+1 or -1: the sign of T3 minus T4's step when the eyes go left; 0 = not known), `clenchOn`, `glanceOn` (a gesture is used only when 2 of its 3 tries were caught); `tries` (each `kind` `clench`/`glance`, `cue` second, `level`, `sign`, `why`: `ok` or the rule it broke); `clenchSeen`, `glanceSeen`, `leftKnown`, `others` (gestures recognised outside the cued windows); `recording` (the stem of its EEG); `rules` (the timing limits it was judged with) |
| `events.jsonl` | one line per change: `switched on`, `switched off`, `calibrated: ...` |
| `recordings/<stamp>.*` | the calibration's EEG in the recorder's format, with a marker per cue (`hands-free calibration: try 2 of 6, clench twice now`); never joined to a night |

Sessions write what a gesture did as a marker or event: `hands-free: sound paused (double clench)`, `hands-free:
sound back (double clench)`, `hands-free: moment (look left then right)`, `hands-free: drifting (double clench)`,
`hands-free: awake (look left then right)`, and at the end `hands-free: N gestures acted on, M ignored while probably
asleep` (sound for states in the session's `events`, meditation and alpha-theta in its log's `info`, the dream
catcher and the nap coach in the recording's `.markers.jsonl`). The night recording marks `hands-free: moment (double
clench)` and its `.log` says when hands-free is on and how many moments it marked.

### Unusual for you (`unusual/`)

The card's switch, what was noted for its cards, and its back-test log (DECISIONS rows 290-299). A missing or
damaged `settings.json` reads as "on"; damaged lines of the two logs are skipped. The card itself is worked out
again from `nights/` and `mornings/` every time (the trends page's per-day numbers), so nothing else is stored.

| File | Content |
|---|---|
| `settings.json` | `on` (the switch; on unless switched off) and `changed` (local ISO time); written under a temporary name, then renamed |
| `events.jsonl` | one line per change, `at` (local ISO time) and `event`: `switched on`, `switched off`, `causes` (`card`: the card's first day, `YYYY-MM-DD`; `causes`: the chips chosen for it, of `late night`, `alcohol`, `travel`, `stress`, `hard exercise`, `vaccine`, `feeling ill`, `not sure`; the latest line for a card wins), `resumed` (ends a pause that day). `feeling ill` pauses the card from the card's first day to 14 days after the day it was first chosen, and keeps those days out of the usual; taking it back undoes that |
| `log.jsonl` | the back-test log: one line per finished day (a day runs 04:00 to 04:00; today is written once it is over), appended once and never rewritten; days the app first judged later (it was not opened, or the card is new) carry that later `judged` time. Fields: `day`; `judged` (when it was written); `phase` (`silent` in the first 28 days with a number, `on`, `paused`); `card` (the rule held with the core numbers), `shown` (`card` while `on`: what the owner saw), `numbers` (the ids in it); `withHeadband` and `numbersWithHeadband` (the same with the headband's numbers added: the "both ways" record); `words` (the card's sentences, when `card`); `values`: per measure id with a value that day, `value`, `usual` (the median of the 28 values ending a week before), `half` (half the no-card band, on a log scale for alpha strength and the rise), `n` (values in the usual), `state` (`unjudged` under 14 values, `in`, `up`, `down`) and `run` (days outside it in a row, one missing day bridged) |

Measure ids are the trends page's: `asleep` (minutes), `kss`, `mood`, `tension`, `reaction` (ms), and from the sharp-hours log (DECISIONS row 380) `sharp` (the day's mean rating, 1-5) and `dayrt` (the day's median reaction time, ms) make the card;
`iaf` (Hz), `alpha` (µV²), `rise`, `jaw` (bursts an hour asleep) are only logged. Nothing is written while the card
is switched off.

### Was this you? (`wearer/`)

The assistant's proposal, on unless switched off in Settings (DECISIONS rows 370-379). The check is worked out again
from the nights and check-ins each time the sleep report, a check-in's result or Settings opens, so only the switch,
the answers' events and a log are stored here; the answers themselves are written into the recordings' own files.
These numbers can identify a person: they stay in the app's private folder and leave only with Export data.

| File | Content |
|---|---|
| `settings.json` | `on` (on unless switched off; missing or damaged = on), `changed` (local ISO time); written under a temporary name, then renamed |
| `events.jsonl` | one line per change: `at`, `event`: `switched on`, `switched off`, or `answer` with `kind` (`night` or `check-in`), `id` (the night's date, or the check-in's file stem `2026-11-20-091205`) and `answer` (`me`, `someone else`, or `null` when taken back) |
| `log.jsonl` | one line per recording the first time it was judged while the check was on, never rewritten: `judged` (local ISO time), `kind`, `id`, `state` (`unchecked`, `learning`, `like you`, `not like you`), `why` (for `unchecked`: `no lights off`, `too little clean signal`, `no alpha peak`), `have` and `days` (accepted recordings of the kind before it, and their different days), `distance` (root mean square of the z-scores; over 2.5 = not like you), `z` (per number), `profile_n`, `usual` (the profile's means), `biggest` (the number furthest away), `signal` (its three numbers: `iaf` Hz, `alpha` log10 µV², `slope`), `answer` (at that time) |

In a night's report (`files/nights/<date>.report.json`), written by the phone's scorer:

| Field | Meaning |
|---|---|
| `wearer_signal` | `null` for an unscored night or when the night pass did not run; else `version` 1, `from_s` (Lights off, seconds from `data_start`, a whole epoch; `null` without a Lights off marker), `epochs` (the 30 s epochs used: scored awake, nothing filled in, among the 20 from Lights off), `clean_s` (clean seconds, the smaller of O1 and O2), `iaf_hz`, `alpha_uv2`, `slope` (O1 and O2 combined, the morning check-in's rules), `why` (`null` when usable, else `no lights off`, `too little clean signal` (under 60 s) or `no alpha peak`). Reports scored before 2026-11-19 have no such field and are not part of the check |
| `wearer` | only once answered: `answer` (`me` or `someone else`) and `at`; a rescored night keeps it. A night marked `someone else` is left out of the trends, the unusual card, experiments and Sharp hours' wake-up times; the file is never deleted |

A check-in's numbers come from its result's `back` (`iaf_hz`, `alpha_ec_uv2`, `aperiodic_slope_ec`) when both back
channels have `clean_s_ec` of 60 s or more; its answer is the result's `wearer` (above).

### Sharp-hours log (`sharp-hours/`)

The assistant's proposal (DECISIONS rows 280-289), off unless switched on. Times are local with their UTC offset
(`2026-11-20T14:05:12+03:00`). The JSON-lines files only grow; a line cut off by a crash is skipped when read.
`settings.json` is written under a temporary name, then renamed. Nothing here holds EEG.

| File | Content |
|---|---|
| `settings.json` | `version` 1, `on`, `per_day` (3, 4 or 6), `awake_from` and `awake_until` (`HH:MM`; the rest of the day is quiet; past midnight when `awake_until` is earlier), `seed` (32 hex characters: the phone-made secret the moments are drawn from), `first_on`, `changed` (local ISO times) |
| `ratings.jsonl` | one line per answer: `version` 1, `at` (when answered: the moment it is about), `sharp` (1 Foggy, 2 Slow, 3 Okay, 4 Sharp, 5 Very sharp), `scale` `1-5`, `prompt` (the planned moment it answers; `null` when rated from the page), `shown` (when its notification appeared), `test_asked` (the question suggested the reaction test) |
| `reactions.jsonl` | one line per 1-minute reaction test: `version` 1, `at`, `rating_at` (the answer it followed), `length_s` 60, `median_ms` (`null` under 5 taps), `taps`, `false_starts` (taps under 100 ms or with no dot), `lapses` (taps over 500 ms), `times_ms` (every tap, 100-1500 ms) |
| `prompts.jsonl` | written by the Android side: one line per thing that happened to a planned moment: `planned`, `at`, `event` (`shown`; `skipped` with `reason` `night recording`, `sound session`, `session on screen` or `notifications off`; `late`: rang over an hour late, or came due while another waited; `snoozed`: "In 15 min"; `dismissed`: swiped away), `test` when it suggested the reaction test. A planned moment with no line never rang (the phone held it back) |
| `events.jsonl` | one line per change: `on`, `off`, `window`, `per day`, each with `per_day`, `awake_from`, `awake_until` |

The moments themselves are not stored: they are drawn again from `seed`, the day and the settings
(`app/lib/sharp/schedule.dart`): the waking window cut into `per_day` equal parts, one random minute in each, at least
60 minutes apart; two of them suggest the test. The Trends page reads two day numbers from these files (a day runs
04:00 to 04:00): `sharp`, the mean of the day's ratings, and `dayrt`, the median of the day's tests' medians.

#### Focus sessions beside the ratings (`focus-YYYY-MM.jsonl`, written by the laptop)

Not from the phone: `scripts/aw_focus.py` (DECISIONS rows 510-514) reads ActivityWatch on the laptop and writes
`_local/phone/sharp-hours/focus-YYYY-MM.jsonl` next to the imported `ratings.jsonl`. One line per day (a day runs
04:00 to 04:00, local time), sorted; a re-run replaces the lines of the days it recomputes and keeps the others, and
unchanged data gives the same bytes. Import and pull never touch these files (the phone has none of this name).

| Field | Content |
|---|---|
| `version` | 1 |
| `day` | `YYYY-MM-DD` |
| `sessions` | the number of focus sessions that started that day (0 is a real zero: the laptop was on for 35 minutes or more) |
| `blocks` | `{"08-10": 1, ...}`: sessions by the 2-hour block of the clock they STARTED in (a longer one is not counted again in later blocks); blocks with none are left out |
| `list` | one entry per session: `start` (local ISO time), `min` (its active minutes, per session: never summed into hours), `app` (the app that held most of it) |
| `through` | the last moment of laptop data that day (the day may still be going on) |
| `rule` | `focus-v1 min=35 switch=3`: the rule that made the line |

A day with under 35 active minutes on the laptop has no line: "no data" is not "no sessions". Window titles are used
in memory to tell documentation from other browsing and are never written; nothing here holds anything but app
names, times and counts. The rule is in the script's header and in `docs/break-hints.md`.

### Study reminders (`study-review/`)

The assistant's proposal "Evening study, morning review" (DECISIONS rows 400-401), off unless switched on in Settings.
Times are local with their UTC offset. The JSON-lines files only grow; a line cut off by a crash is skipped when read.
`settings.json` is written under a temporary name, then renamed. Nothing here holds EEG, and nothing records what was
studied.

| File | Content |
|---|---|
| `settings.json` | `version` 1, `on`, `evening` and `morning` (`HH:MM` when the owner set the time by hand, `null` while it follows the sleep), `first_on`, `changed` (local ISO times) |
| `log.jsonl` | one line per one-tap answer: `version` 1, `at` (when answered), `kind`: `evening` with `studied` (`true` or `false`: "Did you study something tonight?"), or `morning` with `recall` (`well`, `some` or `little`: "How much do you recall of what you studied?"); `prompt` (the planned reminder it answers; `null` when logged from the page) and `shown` (when its notification appeared) |
| `prompts.jsonl` | written by the Android side, in the sharp-hours log's format (`planned`, `at`, `event`: `shown`, `skipped` with `reason`, `late`, `snoozed`, `dismissed`); the phone's one alarm chain also carries the sharp-hours questions, whose lines stay in `sharp-hours/prompts.jsonl` |
| `events.jsonl` | one line per change: `on`, `off`, `evening time`, `morning time`, `evening automatic`, `morning automatic`, each with the times then (`auto` or `HH:MM`) |

The reminders' times are not stored when they follow the sleep: they are worked out again from the sleep reports
(`app/lib/study/schedule.dart`). The Trends page reads one day number from the log (a day runs 04:00 to 04:00):
`recall`, the mean of the day's morning answers (`little` 1, `some` 2, `well` 3).

### Work sessions (`work-sessions/`)

One file per work session (ROADMAP row 35, DECISIONS 440-449): `<stamp>.work.json`, the session's start as
`yyyy-MM-dd-HHmmss` local time. Written whole (a temporary name, then a rename) every 5 minutes while the session runs
and at Stop, so a crash loses at most the last minutes; `ended` says which. Times are local ISO times. No raw EEG: the
per-30-s numbers are enough to score a session again with other weights or lines. Compact JSON (one line); older files
are indented, and read the same.

| Field | Content |
|---|---|
| `version`, `kind`, `app` | 1, `work_session`, `eeg_tracker work` |
| `start`, `end`, `ended` | the session's span; `ended`: `running` (written during the session) or `stopped` |
| `headband`, `contact_ohms` | the headband's name; the contact check at the start, ohms per channel (`null`: no contact) |
| `closed_alpha` | the optional eyes-closed minute: median back alpha (µV²) of its clean seconds; `null` when skipped or too noisy |
| `baseline` | `alpha` (µV², 8-12 Hz at O1/O2), `events` (blinks plus sideways eye movements per 30 s), `theta` (µV², 4-7 Hz at O1/O2) and `sem` (µV², T3-T4 at 0.2-0.7 Hz): medians of the 6 scored half minutes after the first minute; `null` before |
| `calibrated_at_s` | seconds of signal when the baseline was complete |
| `worn_min`, `active_min` | minutes the headband sent a usable signal outside breaks |
| `stretch_min` | worn minutes since the last break of 5 minutes or more (the hour's count) when the file was written; a session started under 5 minutes after this one's `end` carries it on (absent in older files) |
| `minutes` | minutes after the baseline per level: `alert`, `getting_drowsy`, `drowsy`, `unknown` (not enough clean signal); `eyes_closed` (half minutes read as closed eyes, whole session) |
| `epochs` | one entry per 30 s of signal: `at` (its start, local ISO time from the phone's clock; the first version of the file had no `at`), `s` (its first second of signal), `clean_s` (seconds read for alpha), `muscle_s`, `movement_s`, `gap_s`, `blinks`, `eye_moves`, `eye_s` (seconds counted for eye events: no hole or movement, all four channels usable for the detectors; absent in older files), `events` (per 30 of those seconds; `null` under 20), `alpha`, `theta`, `sem` (medians, µV²; `null` under 10 clean seconds), `eyes_closed`, `a` and `still` (log2 against the baseline: alpha, and eye stillness = log2((baseline events + 1) / (events + 1))), `t` and `s_eye` (theta and slow eye power the same way, logged only), `index` (the mean of `a` and `still`, where a positive `still` counts only as far as alpha is up: times `a` / 0.5, between 0 and 1; `a` alone when `still` is `null`; older files used the plain mean, at most 0.25 when `a` was negative), `window` (the median index of the last 10), `level` |
| `hints` | `at`, `reason` (`stretch`, `drowsy`, `eyesClosed`, `snooze`), `active_min` (worn minutes of the stretch), `threshold_min`, `level`, `answer` (`onBreak`, `snoozed`, `notNow` or `null`), `answered_at`, `taken` (a break of 5 minutes or more started within 30 minutes) |
| `breaks` | `start`, `end`, `source` (`tapped` or `headbandOff`: no usable signal for 5 minutes, counted from when it stopped), `end_source` (`back`: Back tapped; `auto`: a tapped break whose Back was forgotten ended by itself, at the moment the headband came back after a minute or more off, or after 20 minutes' worth of readable half minutes; `signal`: a headband-off break's signal came back; `stop`: Stop; absent in older files), `before` / `before_level` (the level's median just before; for `headbandOff`, just before the headband went off), `after` / `after_level` (over the first 5 minutes after; `null` if never readable) |
| `ratings` | `at`, `value` ("How sharp do you feel?", 1 Foggy to 5 Very sharp: the sharp-hours scale), `hint` (the index of the hint it answered, or `null`) |
| `events` | `at`, `event`: the headband's drops, reconnects and stream restarts (also `no data for N s: stream restarted` and `no data for N s with the headband in range; reconnecting`), each hint, the eyes-closed minute's outcome, `chime waited: a call` (with `hint`, the hint's `at`) when a hint came during a call and its chime waited (DECISIONS 495), `break ended by itself (Back not tapped)` (with `end`), and `stretch carried over from a session that ended under 5 minutes ago` (with `stretch_min`) |
| `wearer` | optional, as in a night's report: `answer` (`me` or `someone else`) and `at`; a session marked `someone else` is left out of the Trends numbers below. The owner sets it by hand with "Someone else wore it" on the end page or under the session in the list of earlier sessions (DECISIONS rows 490-494); "Undo" removes the object. Nothing else in the file changes |

The Trends page and the self-experiments read one set of day numbers from these files (DECISIONS rows 480-489; a day
runs 04:00 to 04:00): from each epoch its own time (`at`; files from the first version have no `at`, and their `t` is the theta number, not a time, so the time is then the session's `start` plus `s`; a file that wrote a time under `t` is read too) and `level` and `eyes_closed`;
from the hints their `at` and `taken`, from the breaks their `start` and `end`, from the ratings their `at` and
`value`. Work time is the epochs read as alert, getting drowsy or drowsy, outside closed eyes and breaks; a day with
under 30 minutes of it has no number. Measure ids: `worktime` (minutes), `workdrowsy` (share of that time at getting
drowsy or drowsy, 0-100), `workfirst` (worked minutes until the level first read getting drowsy or drowsy in 8 of 12
epochs since the last break; only days with one), `workhints`, `workfollowed` (hints a break of 5 minutes or more
followed: `taken`, or the hint came in the 30 minutes before the session's Stop and 5 minutes or more passed until the
next session, or no session followed and the file says `stopped`), `workbreaks`
(5 minutes or more) and `worksharp` (the mean tap, 1-5; only days with a tap).

### Lucid dream cues (`lucid/`)

The evening practice, the nights with the cues on and the honest self-test (DECISIONS rows 300-309). Each JSON file is
written under a temporary name, then renamed; a missing or damaged file reads as "off", "never" or "none". A night's
`<stamp>` is its start (the recorder's first Start of the night), `yyyy-MM-dd-HHmmss` local time. Please do not open
`sealed.json` or `plays.jsonl` before the app shows the results: together they say which nights had sound.

| File | Content |
|---|---|
| `settings.json` | `on` (off by default), `level` (the practice's loudness, a share of the media volume, 0-1), `mediaVolume` and `mediaVolumeMax` (the phone's media volume step when it was set), `levelSet`, `changed` |
| `events.jsonl` | one line per change: `switched on`, `switched off`, `loudness set to ...`, `plan frozen (schedule ...)` |
| `practice.jsonl` | one line per evening practice: `start`, `end`, `cues` (played after the loudness step), `completed` |
| `sealed.json` | `salt` (64 hex characters) and `allocation` (one character per night of the test from night 1: `C` = sound, `S` = silent; drawn again from the salt alone, the replay check's draw) |
| `plan.json` | `plan` and `sha256` (of `plan` as JSON with sorted keys and no spaces). `plan`: `version` 1, `frozen`, `design`, `blockSize` 4, `cuePerBlock` 2, `plannedNights` 24, `maxNights` 36, `revealEvery` 12, `primary`, `secondary`, `seenTogether`, `exclusions`, `analysis`, `honesty`, `scheduleSha256` (SHA-256 of `sealed.json`'s content in the same canonical form) |
| `plays.jsonl` | one line per cue the phone was asked to play (nights with sound only): `at`, `night` (its number from 0), `ok`, `error` |
| `nights/<stamp>.json` | written by the night recorder, the same on nights with and without sound: `version` 1, `start`/`startMs`, `index` (the night's number in the test, from 0), `cuesFrom`/`cuesFromMs`, `phase` (`waiting`, `listening`, `done`, `off`, `ended`), `cues` (each `at`/`atMs`, `step`: dB over the practice level, `period`: the dream period, `confidence`: the live reading, `aroused`: a stir followed within 30 s), `arousalsMs`, `stops` (`atMs`, `why`: `per night` or `three arousals`), `running` (the live model was open when this was written), `off` (why the cues were switched off, a sentence), `model` (`mode`, `calls`, `median_ms`, `max_ms`, `skipped_windows`), `level`, `mediaVolume` |
| `mornings/<stamp>.json` | `night`, `answered`, `answers`: `lucid` (`yes`, `no`, `unsure`), `heard` (`no`, `dream`, `woke`, `unsure`), `recall` (0 nothing, 1 a bit, 2 a dream, 3 more), `signal` (`yes`/`no` after a lucid yes, else null) |
| `signals/<stamp>.json` | the morning's search over the night: `version` 1, `made`, `sweepUv` (the look size used), `clenchX` (the calibrated clench line, or null: no clench search), `staged` (false while the night had no sleep report), `signals` (each `at`/`atMs`, `kind` `lrlr` or `clench`, `pairs`, `stage`: the full-night scoring's stage there, `afterCueS`: seconds after the nearest earlier cue moment within 2 minutes) |
| `cue.wav` | the cue: 16-bit PCM, 48 kHz, mono, three tones 400, 600, 800 Hz, 0.65 s |

The night's recording carries the cues' moments as markers in its `.markers.jsonl` (and so as BDF annotations):
`lucid cues on: night N of the test; cues from HH:MM, the sleep model from HH:MM`, `lucid cues: sleep model on`,
`lucid cue N (dream sleep 0.84, +3 dB)`, `lucid cues: arousal after a cue; 3 dB quieter, 5 minutes without cues`,
`lucid cues: done for tonight (...)`, `lucid cues off: ...`, `lucid cues from HH:MM (4.5 h after Lights off)`; its
`.log` ends with the cues' share of the recorder's time (`lucid cues: ... s of the recorder's time`; on a night with
the smart alarm too, one line for both: `smart alarm and lucid cues, one sleep model: ...`), and says `lucid cues
stopped: ...` if the guard switched them off. None of these says whether sound played. The `.log` also says when the
one live sleep model the cues and the smart alarm share opens and closes (DECISIONS 330): `live sleep model on for the
... (load N tonight)`, `live sleep model: shared with the ... (no second copy)`, `live sleep model off, no one needs it
(N calls, median S s)`.

### Memory cues (`memory_cues/`)

The evening task, the nights in the test and the honest self-test (DECISIONS rows 500-509; the assistant's proposal).
Each JSON file is written under a temporary name, then renamed; a missing or damaged file reads as "off", "never" or
"none". A night's `<stamp>` is its start, `yyyy-MM-dd-HHmmss` local time. Places on the board are in board widths
from its top left corner (`x` 0-1, `y` 0-1.25). Please do not open `sealed.json` or `plays.jsonl` before the app shows
the results: together they say which nights had sound and which half.

| File | Content |
|---|---|
| `settings.json` | `on` (off by default), `changed` |
| `events.jsonl` | one line per change: `switched on`, `switched off`, `plan frozen (schedule ...)` |
| `sessions/<id>.json` | one per evening (`id` = when it was drawn, `yyyy-MM-dd-HHmmss`): `version` 1, `made`, `boardDp` (the board's width on the screen, dp), `items` (32: `object` (an English name), `x`, `y`, `sound`: 0 the bell, 1 the knock), `studyOrder`, `learn` (each placement while learning: `object`, `round`, `x`, `y`, `ms` from the start of learning), `evening` (`{object: [x, y]}`, the evening test), `eveningEnd`, `levels` (`[bell, knock]`: the "just heard" loudness, a share of the media volume), `mediaVolume`, `mediaVolumeMax`, `completed` (the test and the loudness done; only a complete session is cued, by a night starting within 3 hours) |
| `sealed.json` | `salt` (64 hex characters), `allocation` (one character per night of the test from night 1: `C` = sound, `S` = silent; shuffled blocks of 4, the replay check's draw) and `sounds` (one digit per night: the half whose sound plays, or would; the first byte of SHA-256(`salt:sound:N`) under 128 is 0) |
| `plan.json` | `plan` and `sha256` (of `plan` as JSON with sorted keys and no spaces). `plan`: `version` 1, `frozen`, `design`, `blockSize` 4, `soundPerBlock` 2, `maxNights` 36, `revealEvery` 12, `measure`, `primary`, `secondary`, `seenTogether`, `exclusions`, `analysis`, `honesty`, `scheduleSha256` (SHA-256 of `sealed.json`'s content in the same canonical form) |
| `plays.jsonl` | one line per sound the phone was asked to play (nights with sound only): `at`, `night` (its number from 0), `sound`, `ok`, `error` |
| `nights/<stamp>.json` | written by the night recorder, the same on nights with and without sound: `version` 1, `start`/`startMs`, `index` (the night's number in the test, from 0), `session` (the evening session it cues), `cuesFrom`/`cuesFromMs`, `phase` (`waiting`, `listening`, `done`, `off`, `ended`), `cues` (each `at`/`atMs`, `step`: dB against the evening loudness, -3 and lower, `period`: the stretch of N2/N3, `confidence`: the live reading, `aroused`: a stir followed within 30 s), `arousalsMs`, `stops` (`atMs`, `why`: `hours over`, `per night` or `three arousals`), `running`, `off` (why the cues were switched off, a sentence), `model` (`mode`, `calls`, `median_ms`, `max_ms`, `skipped_windows`), `mediaVolume` |
| `mornings/<stamp>.json` | the morning test of the night `<stamp>`: `version` 1, `session`, `made`, `taps` (`{object: [x, y]}`), `heard` (`no`, `yes`, `woke`, `unsure`) |
| `sound_a.wav`, `sound_b.wav` | the two sounds: 16-bit PCM, 48 kHz, mono; the bell (660 Hz with a bell's off-key overtone, 0.7 s) and the knock (two 520 Hz strikes 0.2 s apart, 0.45 s), the same RMS |

The night's recording carries the cue moments as markers in its `.markers.jsonl`: `memory cues on: night N of the
test; sounds from HH:MM to HH:MM`, `memory cues: sleep model on`, `memory cue N (N2/N3 0.91, -3 dB)`, `memory cues:
arousal after a sound; 3 dB quieter, 5 minutes without sounds`, `memory cues: done for tonight (...)`, `memory cues off:
...`, `memory cues from HH:MM (30 min after Lights off)`, or, on a night without a finished evening task, `memory cues:
no evening task finished in the 3 hours before this night, so no sounds tonight`. Its `.log` ends with the cues' share
of the recorder's time (`memory cues: ... s of the recorder's time`; with the smart alarm too, `smart alarm and memory
cues, one sleep model: ...`) and says `memory cues stopped: ...` if the guard switched them off. None of these says
whether sound played or which half.

### When I put the headband on (`auto-start/`)

Automatic recording, phase 1 (ROADMAP row 39, DECISIONS 600-609): the owner's choices, what the headband watcher
remembers between checks, and every check, guess, question, answer and outcome, so a personal model can learn from the
answers later. Times are local with their UTC offset. `settings.json`, `state.json` and `laptop.json` are written under
a temporary name, then renamed; a missing, damaged or foreign one reads as the defaults. `log.jsonl` only grows; a line
cut off by a crash is skipped. Nothing here holds EEG (the minutes kept while the app asks become a normal run in
`recordings/` only after a yes).

| File | Content |
|---|---|
| `settings.json` | `version` 1, `choices` (`night`, `work`, `other`: `start`, `ask` or `nothing`; `other` never `start` in phase 1), `work_chime` (automatic work sessions chime), `bed_min` and `wake_min` (the bedtime window set by hand, minutes after midnight; `null` while it follows the recorded nights) |
| `state.json` | `version` 1, `quiet_until` (per kind: no question before then, after Not now or no answer), `yes_streak` (per kind), `offered` (kinds offered "start automatically" in this streak), `worn_since` (the wearing in progress), `asked_this_wearing`, `charge_notice_day` |
| `laptop.json` | `version` 1, `working` (the laptop's latest word on a work session) and `at` |
| `log.jsonl` | one line per event, each with `version` 1, `at` and `event`: `check` (`trigger`: `presence`, `bedtime`, `laptop`, `opened` or `now`; `near`, `worn` (`null` when it could not be told), `how` (`resistance`, `signal`, `simulated` in a debug build, `none`), `ohms` per channel (`null` = no contact), `battery` (%), `guess` (`night`, `work`, `other`), `reasons`, `choice`, `window` (`HH:MM-HH:MM`), `phone` (`charging`, `screen_on`, `screen_off_min`, `dnd`, `laptop`, `next_alarm`), `error`); `skipped` (`trigger`, `why`); `question` (`kind`, `text`); `answer` (`kind`, `answer`: `yes`, `no`, `none` (no answer in 15 minutes or swiped away), `released` (a start by hand), for `other` also `night` or `work`; `after_s`); `start` (`kind`, `how`: `automatic` or `yes`, `preroll_s` and `stem` (the run the kept minutes became), `quiet` and `limit_min` for work, `error`); `declined` (`kind`, `why`, `battery`); `offer` (`kind`, `yes_in_a_row`); `offer_answer` (`kind`, `accept`); `released` |

A night the watcher started has a first line in its first run's `.log`: `started automatically: ...` or `started after
"Yes" ...`, and the minutes kept while asking are the night's first run, whose `.log` begins `auto-start: the headband
was found on ...`.

### Try these (`try-these/`)

The in-app list of what to try next (DECISIONS row 340): which stops the owner ticked Done or Skip, which the app
ticked itself, and the owner's notes ("What happened?"), for the assistant to read after an import
(`_local/phone/try-these/`). Card ids and titles are those of `app/lib/try_these/cards.dart`. Times are local with
their UTC offset. A missing or damaged `progress.json` reads as nothing done.

| File | Content |
|---|---|
| `progress.json` | `version` 1, `changed` (the last write), `cards`: one entry per card id the owner or the app touched: `title`, `state` (`open`, `done`, `skipped`), `at` (when the state last changed), `by` (`owner` or `app`), `seen` (what the app saw, in a sentence, when `by` is `app`), `note` (the owner's note, as typed; saved a moment after the last key), `note_changed`; written under a temporary name, then renamed |
| `events.jsonl` | one line per change of state: `at`, `card`, `title`, `event` (`done`, `skipped`, `reopened`, `seen by the app`), with `seen` and the `note` at that moment; a note typed without a change of state is not logged |

On the laptop, `scripts/import_phone.py <folder>` (standard library only) checks the manifest, copies
`recordings/<stamp>.*` into `_local/recordings/` beside the laptop's own recordings, `recordings-diy/<stamp>.*` into
`_local/recordings-diy/` beside the laptop's DIY recordings, and everything else into
`_local/phone/<path>`, and keeps `phone/manifests/<exported>.manifest.json`, one line per import in
`phone/imports.jsonl` and the copies' SHA-256 in `phone/import-index.json`. A copy is renamed into place only when its
size and SHA-256 match. A differing file on the laptop is replaced only by a copy the phone changed later (the old one
goes to `phone/replaced/<import time>/`); otherwise it is left alone and named in the summary. A packed `.f32.gz`
is checked as sent, unpacked, checked against its `original` and saved as the plain `.f32`; it is "already here" when
the laptop holds that `.f32`, plain or packed (the index keeps a packed copy's row under the plain name, with the
original's SHA-256).

## The phone over Wi-Fi (Share on Wi-Fi)

With **Share on Wi-Fi** on (DECISIONS rows 220-229), the phone app answers on port 8765, to local-network clients
that send its code (`Authorization: Bearer <code>`, `X-EEG-Token`, or `?token=`):

- The laptop recorder's live routes with the same JSON: `GET /state`, `GET /stream` (server-sent events: a hello,
  batches `{"i", "t", "uv"}`, markers), `POST /marker` (a line `{"t", "i", "text"}` in the run's `.markers.jsonl`;
  503 while nothing records). `i` counts samples within the run being recorded. `status` is `recording`,
  `reconnecting`, `checking contact`, `stopping`, `not recording`, or `session` (a meditation, check-in, dream
  catcher or sound session is recording). The field lists both recorders are tested against:
  `app/test/fixtures/share_api.json`.
- `POST /work` with `{"working": true}` or `{"working": false}`: the paired laptop's tray says a work session
  started or ended there (`scripts/laptop_work.py`; automatic recording, DECISIONS 603): 202, kept in
  `auto-start/laptop.json`; 400 for any other body; 503 during a night (the recorder's server does not take it).
- `GET /files`: `{"format": "eeg-tracker-phone-files", "version": 1, "listed", "recording", "files": [...],
  "totals"}`; each file has the manifest's `path`, `bytes`, `sha256`, `modified_ms` (the same files and paths as the
  export folder above) and, for a recording packed after a day, `original`. A file changed in the last 20 s is still
  being written: `"sha256": null, "growing": true`.
  `?sha=0` lists without working out missing SHA-256 values.
- `GET /files/<path>`: the file, with HTTP `Range: bytes=<from>-<to>` (206 and `Content-Range`; 416 with
  `Content-Range: bytes */<size>` when it starts past the end), `X-Modified-Ms`, and HEAD. Read-only.

`scripts/pull_phone.py` mirrors these into the layout of `scripts/import_phone.py` (raw nights into
`_local/recordings/`, the rest into `_local/phone/`). A recording's `<stamp>.header.json` travels with its `.f32` into
`recordings/`, `recordings-diy/` and `phone/mornings/`; `--raw-only` takes `recordings/` and `recordings-diy/`.
`/state` and `/stream` carry the recording's own channels: `names`, one `data` row and one `uv` value per channel, and
the board's `fs` (the BrainBit's four at 250 Hz otherwise). `_local/phone/pull-state.json` holds `partial` (copies of files
the phone is still writing, with their size) and `raw` (checked raw files, which the phone may add to later);
`_local/phone/pulls.jsonl` has a line per pass that fetched something or found a problem. A partial copy ends where
the phone's file ended when it was listed; readers should ignore an incomplete last record, as they do for a
recording that is still running. A packed `.f32.gz` is fetched whole, never in pieces, and lands as the plain `.f32`
(unless the laptop holds that `.f32`, plain or packed: then nothing is fetched).

**Pairing** (`scripts/phone_link.py`, DECISIONS rows 530-539, `docs/phone-link.md`): the laptop answers on port 8771
`POST /link/hello` (`{"v": 1, "via": "code" | "key", "nonce"}` -> `{"v": 1, "nonce", "proof", "name"}`) and
`POST /link/finish` (`{"v": 1, "via", "nonce", "proof", "port", "token"}` -> `{"v": 1, "name"}`, plus `"key"` after
a pairing by code); 410 for a code that expired or was used, 404 `not paired` for a key it does not have, 403 for a
wrong proof or a client outside the local network. `_local/phone/link.json` (mode 600): `version` 1, `laptop_key`,
`paired` and `told` (ISO times), `phone` (`address`, `port`, `token`). On the phone the paired laptop is the field
`laptop` (`host`, `port`, `key`, `name`, `paired_at_ms`) of the Share on Wi-Fi setting in the app's private settings.

## The catalog of nights (`_local/catalog/`)

`scripts/catalog.py` (standard library only; DECISIONS 313-318) reads `_local/` and writes:

- `catalog.json`: `format` (`eeg-tracker-catalog`), `version` 1, `made`, `local`, `nights` and `missing`. One object
  per night, oldest first: `date` (evening date, as the sleep report names it), `id` (the date; `<date>-diy` for the
  DIY board's nights, which are read from `_local/recordings-diy/` and listed apart from a BrainBit night of the same
  evening, DECISIONS 381; their hours use the board's rate and record width from the recording header, else the
  `.log`), `source`
  (`laptop`, `phone`, `laptop+phone` or `diy`), `recordings` (runs with samples), `start` and `end` (first and last data), `hours_recorded`
  (samples at 250 Hz), `minutes_missing` (time between them without samples), `raw` (`false` for a phone report
  whose raw night is not on the laptop), `report` (`by` laptop or phone, `asleep_min`, `deep_min`, `dream_min`, or
  `null`), `morning` (its check-in files), `files`, `bytes` and `file_list` (`path` from `_local/`, `bytes`,
  `mtime_ns`, `sha256`, `kind`: `raw` for `.f32 .f32.xz .idx .log .markers.jsonl .header.json`, else `derived`; a
  damaged `.header.json` is a PROBLEM ("damaged") on every run and its recording is counted in no night; for a packed
  `.f32.xz` also `original`: `path`, `bytes` and `sha256` of the `.f32` it holds). `missing`: raw files an earlier
  catalog listed that are gone, with `night` and `since` (a `.f32` that became its `.f32.xz` with the same bytes is
  "packed", not missing; with other bytes it is a PROBLEM, "changed"). `--check` unpacks every packed file and
  compares what comes out with `original`.
- `<id>.sha256`: the night's files (and its missing ones) in `sha256sum` format, so
  `cd _local && sha256sum -c catalog/<date>.sha256` checks them without the script (a packed file by its own bytes).
- `catalog.txt`: the printed summary; `history.log`: one entry per run with what changed.

## The laptop's work sessions (`_local/laptop/work/`)

Written by the laptop tray (`scripts/tray.py`, `scripts/laptop_work.py`; [laptop-tray.md](laptop-tray.md), DECISIONS
570-579) from ActivityWatch, with no headband. Beside the phone's files, not among them: `_local/phone/` is the
phone's mirror, and these files have no EEG. Times are local ISO times with their UTC offset, to the second. No window
title is ever written; app names are.

**`<stamp>.work.json`**, one per session; `<stamp>` is its start, `yyyy-MM-dd-HHmmss` local time (`-2` added if
taken). Written whole (a temporary name, then a rename) at start, at each change, every 5 minutes while it runs and
at the end.

| Field | Content |
|---|---|
| `version`, `kind`, `app` | 1, `laptop_work_session`, `eeg_tracker tray` |
| `start`, `end` | the session's span; while it runs `end` is the last moment written |
| `ended` | `running` (still going, or the tray died; a file left `running` is taken up again by a tray started within 10 minutes, else marked `lost` at its last write), `stopped` (Stop), `away` (away longer than the setting: `end` is when you left), `not_work` (relabelled "Not work"), `quit` (the tray was quit or the laptop logged out), `lost` |
| `started_by` | `manual` (Start), `asked` (Yes to "Started working?"), `auto` (started by itself) |
| `detected` | for `asked` and `auto`: `at` (when it was noticed), `run_start` (when the work began: the session's `start`), `work_min` (clock minutes in work apps less the switches), `away_min` (active minutes in other apps inside it), `clear_min` (the work minutes at its end with at most `auto_max_away_min` elsewhere), `app` (the app that held most of it), `family` (`code` or `write`, aw_focus.py's families); `null` for `manual` |
| `active_min` | minutes with keyboard or mouse use inside the session (ActivityWatch's AFK watcher, gaps under 3 minutes counted), tapped breaks left out |
| `hints` | `at`, `reason` (`stretch`: the active-time threshold; `snooze`: the one a snooze brought back), `active_min`, `threshold_min`, `via` (`notification`, or `tray` with notifications off), `answer` (`snoozed`, `onBreak`, `notNow` = OK, or `null`; the phone's names), `answered_at`, `taken` (a break of 5 minutes or more began within 30 minutes), `event` (the id of its `break_hint` event below) |
| `breaks` | `start`, `end` (`null` while it goes on), `source`: `tapped` (On a break; it ends at Back or when you come back from 5+ minutes away) or `away` (5 minutes or more without keyboard or mouse, not inside a tapped one). The time away that ended a session is after its `end`, not one of its breaks |
| `labels` | the owner's answers about this session: `at`, `label` (`work` or `not_work`), `question` (`ask` or `auto`), `answer` (`yes`, `no`, `not_work`) |
| `events` | `at`, `event`: `started (...)`, `on a break`, `back`, `back (returned)`, `hint`, `ended (...)`, `taken up again after a restart` |
| `settings` | the tray's settings when the session started (below) |
| `written` | when the file was written |

**`labels.jsonl`**: one line per answer about the detection, so the rule can be checked against what the owner said:
`version` 1, `at`, `question` (`ask`: "Started working?"; `auto`: a session it started by itself), `answer` (`yes`;
`no`; `not_work`; `none`: a question dropped unanswered at a break, a mode change or Quit, or a started session nobody
confirmed or relabelled), `run_start`, `work_min`, `away_min`, `clear_min`, `app`, `family` (as `detected`), `session`
(its `<stamp>`, or `null`), `rule` (`laptop-detect-v1 ask=5 auto=12 away=3 switch=3`: the rule and numbers in force).

**Settings** live outside the repository, in `~/.config/eeg_tracker/tray.json` (or `$XDG_CONFIG_HOME`): `version` 1,
`notifications`, `auto_start` (`off`, `ask`, `auto`), `ask_after_min` (1-60), `auto_after_min` (5-120),
`auto_max_away_min` (0-15), `ask_again_min` (0-240), `end_after_away_min` (0 = never, up to 480),
`hint_threshold_min` (50-90), `quiet` (`HH:MM-HH:MM` or `off`), `max_hints_per_day` (0-12). A missing or wrong value
takes its default. "Start at login" is the file `~/.config/autostart/eeg-tracker-tray.desktop` itself.

## Events (for utof_tracker and anything else)

Same envelope and rules as utof_tracker's `docs/data-format.md`, so its readers can take these lines as they are:
one UTF-8 JSON object per line ending in `\n`; a reader ignores a last line without a newline; readers
de-duplicate by `id`; an update is a new event whose `data.replaces` is the old `id`, and the newest wins.

```json
{"v":1,"id":"eeg:3f2a…","dev":"eeg-pc-1a2b3c4d","seq":1,"ts":"2026-11-18T02:40:13+03:00","tz":"Europe/Moscow","type":"eeg_sleep_night","data":{…}}
```

The contract for utof_tracker (what each number may be used for, exclusions, corrections, the daily command
`python3 scripts/export_events.py --daily`) is [utof-interface.md](utof-interface.md); this section is the field list.

- `dev`: `eeg-pc-` + 8 random hex characters, made once per export folder (`<root>/device_id`); the phone app
  will use `eeg-phone-…`.
- `id`: `eeg:` + sha1 of the event's content (a night: its start, model and hypnogram, plus the owner's answer when
  there is one; a check-in: its start and result; a day: the day and its data), so exporting the same result twice
  adds nothing.
- `seq` counts per month file.
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
| `wearer` | only when the owner answered "Was this you?" in either report: `me` or `someone else` (`--daily`) |
| `replaces` | the `id` of an earlier result for the same night, when re-scored |

With `--daily`, one per sleep report (the laptop's `_local/nights/` and the phone's `_local/phone/nights/`; the
laptop's when both have the night): from the `.sleep.json` named in a laptop report, else from the report's `stages`
(the phone's; then `cross_check` is the report's, `null` on the phone, and `confidence` is the periods' mean weighted
by their time asleep). A report with neither gives no night event; its numbers are still in `eeg_day`.

`sleep_night` in utof_tracker is the phone's own estimate; `eeg_sleep_night` is a separate type so neither
overwrites the other. utof_tracker imports these files with `pc/eeg_import.py` (since 2026-11-19).

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
| `reaction_ms`, `habits`, `wearer` | the phone's check-ins only: the reaction test's median (`null` under 5 taps), `habits` as in the phone's result, the owner's "Was this you?" answer |
| `replaces` | the `id` of an earlier result for the same check-in, when re-analysed |

With `--daily`, one per check-in in `_local/phone/mornings/` and `_local/recordings/` (the phone's first when both
have the same start).

### `eeg_day`

One per day (04:00 to 04:00 local time), written by `--daily` from `scripts/day_summary.py`; `ts` is the day's start.
The numbers follow the phone's Trends rules (`app/lib/trends/`), so they match what the phone shows.

| Field | Meaning |
|---|---|
| `day` | `YYYY-MM-DD` |
| `schema` | 1 (of this event) |
| `measures` | the `eeg_measure_set` version the ids below mean (1) |
| `complete` | `false` while the day is still going on when exported; a later event replaces it |
| `numbers` | measure id -> value, to 2 decimals; only measures with a value that day (an absent id = no data, never 0) |
| `counts` | what went into them: `nights`, `checkins`, `work_sessions`, `practice_sessions`, `sharp_ratings`, `sharp_tests` (absent = 0) |
| `quality` | `night_noisy_share` (time asleep read as noisy or missing, over the day's scored nights, the left-out ones too), `checkin_clean_share` (the first check-in's back channels) |
| `excluded` | `{what, id, why, ...}` per recording left out (utof-interface.md has the rules): `what` `night`, `check-in`, `work session`, `work`; `why` `someone else`, `unscored: under 5 minutes recorded`, `noisy` (+ `noisy_share`), `noisy: headband numbers left out` (+ `clean_share`), `under 30 readable minutes` (+ `minutes`) |
| `sources` | `laptop` and/or `phone`: whose files gave numbers |
| `replaces` | the `id` of the earlier event of the same day |

### `eeg_measure_set`

One per version of the measure list (`scripts/day_summary.py` `MEASURES`); a changed text within a version is a new
event that `replaces` the old one. `ts` is when it was first exported.

| Field | Meaning |
|---|---|
| `version` | 1 |
| `measures` | one per id: `id`, `label`, `unit`, `group` (`sleep morning day work practice`), `about` (`night before`, `morning`, `day before`, `day`), `source` (`headband`, `self-report`, `tap test`, `app`, `laptop`), `evidence_note` (`docs/evidence/<name>.md`), `evidence` (`strong some weak none`, `null` = not a headband measure), `status` (`seen together`), `rule` (how the day's number is made, one line) |
| `day_rule`, `status_rule`, `grades` | the rules in words |

### `break_hint`

Written by `scripts/break_hints.py` ([break-hints.md](break-hints.md)), and by the laptop tray during its work sessions
([laptop-tray.md](laptop-tray.md); the same code, so the daily cap and the back-off count both), to
`breaks-YYYY-MM.jsonl` in the same device folder, one event per thing that happened. `ts` is when it happened (local time with offset); `id` is
`eeg:` + sha1 of device, type, `ts`, kind and hint; `seq` continues from the highest `seq` in the folder.

| Field | Meaning |
|---|---|
| `kind` | `shown` (a hint appeared), `snoozed` (Snooze 20 min pressed), `dismissed` (OK pressed), `taken` (an AFK stretch of 5+ min began within 30 min of the hint) |
| `active_min` | active minutes counted when the hint was shown (0 for `taken`) |
| `threshold_min` | the threshold in force then, back-off included |
| `hint` | for `snoozed`, `dismissed`, `taken`: the `id` of the `shown` event it answers |

A hint closed or expired without a button press adds no event; "ignored" means `shown` with no `taken` after it.
