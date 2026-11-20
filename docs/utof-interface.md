# The interface to utof_tracker (and anything else)

eeg_tracker hands its numbers to utof_tracker, the owner's life tracker, as **events in utof_tracker's own envelope**
(its `docs/data-format.md`). This page is the contract: what is exported, how a re-run and a correction behave, and
what each number may be used for. Field-by-field formats are in [data-format.md](data-format.md#events-for-utof_tracker-and-anything-else);
the choices behind them are DECISIONS rows 550-559.

## The daily command

```sh
python3 scripts/pull_phone.py          # or scripts/import_phone.py <folder>: the phone's files into _local/phone/
python3 scripts/export_events.py --daily [--local _local] [--root _local/export]
```

Standard library only, seconds to run, safe to run as often as you like. It reads the laptop's `_local/` (the
laptop's own sleep reports and check-ins and the phone's imported files, below) and appends to
`<root>/events/<dev>/eeg-YYYY-MM.jsonl`. utof_tracker reads that folder itself (its `pc/eeg_import.py`, hourly).
Nothing leaves the laptop.

## What is exported

| Event | One per | What it holds |
|---|---|---|
| `eeg_day` | day (04:00 to 04:00 local time) | every number the phone's Trends page has for that day, plus sleep stages, the counts behind them, signal quality, and what was left out and why |
| `eeg_measure_set` | version of the measure list | what each number of `eeg_day` is: label, unit, group, when it is about, source, evidence grade, status, rule |
| `eeg_sleep_night` | night | the night's hypnogram and totals (a laptop report's `.sleep.json`, or the phone report's `stages`) |
| `eeg_morning_check` | check-in | the check-in's alpha numbers, ratings, and on the phone also the reaction test and the day-before habits |

**`eeg_day` is the interface for analysis.** The night and check-in events are the detail behind it.

### The numbers (`eeg_measure_set` version 2)

A night counts for the day you **woke** from it ("night before" below); a check-in's number is the first of the day
that has it; the rest are the day's own. Grades are the evidence notes' (`docs/evidence/`): how well the evidence
supports the measure **for this headband**; `null` = not a headband measure (your own rating, a tap test, an app or
laptop count; the note then grades the feature, not a measurement).

| Group | Ids | About | Grade |
|---|---|---|---|
| sleep | `asleep`, `dream`, `awake_in_sleep`, `wakeups`, `fall_asleep` (min, min, min, count, min) | night before | some |
| sleep | `deep`, `light` (min) | night before | weak (the five-stage detail) |
| sleep | `efficiency` (%), `regularity` (min) | night before | weak (see below) |
| sleep | `jaw` (bursts an hour asleep) | night before | strong (a trend, not a bruxism test) |
| morning | `iaf` (Hz), `alpha` (µV²), `rise` (ratio) | morning | strong |
| morning | `kss` (1-9), `mood` (1-5), `tension` (1-5), `slept` (1-5), `caffeine`, `alcohol` (day before) | morning | null: your ratings |
| morning | `reaction` (ms) | morning | null: tap test |
| day | `sharp` (1-5), `recall` (1-3), `dayrt` (ms) | day | null: ratings and tap test |
| day | `focus` (count of 35+ minute focus sessions, ActivityWatch) | day | null: laptop count |
| work | `worktime` (min), `workdrowsy` (%), `workfirst` (min) | day | some |
| work | `workhints`, `workfollowed`, `workbreaks` (counts), `worksharp` (1-5) | day | null: app counts, taps |
| practice | `practice` (min), `settled` (%) | day | weak |

`efficiency` is the minutes asleep over the minutes from Lights off (a tap or a marker) to the last wake-up, or from the
recording's start on a night with no Lights off, at most 100. `regularity` is how far the last 7 days' first-sleep times
and last wake-up times moved (each a circular standard deviation, the two averaged, in minutes; 5 nights of the 7
needed; smaller is steadier). `slept` is the optional "How did you sleep?" tap of the phone's check-in, 1 very badly to
5 very well. DECISIONS rows 650-659.

### Status: seen together, not tested

Every number has `status: "seen together"`. A reader may place it next to other things (mood, anxiety, habits) and
say how they went together, with how many days; it must not say one **caused** the other. "Tested" is reserved for the
answer of a randomised self-experiment (the phone's Experiments), which is not exported yet: when it is, its own
event will carry `tested`, never a day number.

### What is left out (`eeg_day.excluded`)

Each entry is `{what, id, why, ...}` on the day the recording would have counted for:

| What | Why | Rule |
|---|---|---|
| night, check-in, work session | `someone else` | the owner's "Was this you?" / "Someone else wore it" answer |
| night | `unscored: under 5 minutes recorded` | the sleep report's own rule |
| night | `noisy` (with `noisy_share`) | more than half of the time asleep noisy or missing (planning value, row 553) |
| check-in | `noisy: headband numbers left out` (with `clean_share`) | under half of the signal kept; the ratings and tap test stay |
| work | `under 30 readable minutes` (with `minutes`) | the Trends rule: no work numbers that day |

`quality` holds `night_noisy_share` (over the day's scored nights) and `checkin_clean_share` (the first check-in), so a
reader can be stricter.

## Ids, re-runs and corrections

- `id` = `eeg:` + SHA-1 of the event's content (for a day: the day and its data). The same data twice adds nothing.
- A changed day, night or check-in is a **new** event with `data.replaces` = the newest earlier id for it; the newest
  wins. Nothing is rewritten in place. A day whose recordings were all later marked "someone else" gets a new event
  with no numbers and the exclusions, replacing the old one. A day whose files are no longer in `_local/` keeps its
  last event (so a run pointed at the wrong folder can never blank the history).
- The day still going on has `complete: false`; once it is over a final event replaces it.
- `eeg_day.measures` names the `eeg_measure_set` version its ids mean; a reader takes the newest set of that version.
- `ts` of `eeg_day` is the day's start (04:00 local); `dev` is `eeg-pc-` + 8 hex (one per export folder).

## Changing the contract

Add a measure: a new `eeg_measure_set` version and a new row in the tables above; existing ids never change meaning.
Version 2 (2026-11-20) added `efficiency`, `regularity` and `slept`; since every `eeg_day` names its set's version, the
first run after that wrote a replacing event for each past day (`replaces` = the earlier one) beside the new set.
Change a field of `eeg_day`: raise `schema` (now 1) and say how readers of 1 should cope. utof_tracker's importer skips
events of a schema it does not know and says so.
