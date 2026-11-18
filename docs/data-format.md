# Data format

Three layers, from raw to summary. Each is written once and never edited in place.

| Layer | Files | Written by |
|---|---|---|
| Raw recording | `<stamp>.f32`, `<stamp>.idx`, `<stamp>.log` (one set per recorder run) | `scripts/record_night.py` (laptop); the phone app will write the same kind of add-only chunks |
| One night | `<night>.bdf` (BDF+, 24-bit, µV), `<night>.sleep.json`, `<night>.hypnogram.png` | `scripts/to_bdf.py`, `scripts/score_sleep.py` |
| Events for other apps | `<root>/events/<dev>/eeg-YYYY-MM.jsonl` | `scripts/export_events.py` |

## Raw recording (BrainBit)

- `.f32`: records of `<I4f` (little-endian): BrainBit packet number, then O1 O2 T3 T4 in **volts** as the
  headband sent them. 250 records a second.
- `.idx`: one `<dQ` record per batch that arrived: unix time of arrival (float seconds) and the index of the
  batch's first record. Gaps are found from these times; packet numbers can repeat.
- `.log`: plain text, one line per event: connection (model, signal strength), contact resistance in ohms, a
  sample count and battery reading every 10 s, stalls and restarts.
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
