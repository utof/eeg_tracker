# Record first: one recorder, activities on top of it (design)

Design only; no product code. Written 2026-11-21 on `docs/record-first` from main `e911b2b`. Decisions are DECISIONS
rows 880-899. Read with: `_local/research/2026-11-20-20-two-trackers-boundary.md` (who holds which label), DECISIONS
700-709 (the Archive), 760-769 (the data book), 820-829 (truth labels).

## In plain words

1. One **Record** button records the headband until you press Stop, all day if you want. A recording is never assumed to be a night.
2. **Sleep, Nap, Work, Meditate, Sound, Dream catcher** become things you do *during* a recording: pressing one writes "Work from 14:05" into the same recording and switches that feature on. No new search for the headband, no new file, no new calibration.
3. Pressing one when nothing records starts the recording too; its Stop then offers "Stop everything" (default) or "Keep recording".
4. A sleep report comes only from a **sleep stretch**: one you started with Sleep or Nap, or one the app found and you confirmed. An awake recording never becomes a night.
5. On Stop, one quick sheet asks "What was this recording?": chips (*Awake the whole time, Slept, Worked, Walked, Ate...*), "only part of it" times, and your own words. Skip is one tap.
6. Labels: things about your life (alcohol, coffee, mood, medicine, illness, places) live in utof_tracker; what you did while the headband recorded lives in eeg_tracker. Both use the same label words, and the laptop joins them by time, so alcohol logged in utof at 20:00 shows on that night's report without a second tag.
7. Alcohol: utof_tracker has no Alcohol button today and needs one (one tap per drink, like coffee). The laptop shows "so far" numbers from 5 nights with and 5 without, says whether they differ from 10 of each, and needs about 16 of each for small differences.
8. Old recordings keep working; nothing is rewritten. It is built in 5 steps that each work on their own (section 12).

## 1. The owner's words (2026-11-21 01:55)

> "for now we use sleep as like a record-at-all-times button, and then other buttons change their functionality: if we
> have an app coach but we are already recording globally, then it's just an in-app feature. The EEG is already
> recording. We're just changing the state, maybe adding more labels to data because it's a specific process the user
> is undergoing. So maybe a separate sleep button... press record and it will record at all times, and all other
> buttons change their functionalities. And when you stop the general recorder, maybe you can provide labels, e.g. I
> was awake the whole time, I did this, I did that."

On labels:

> "Should we have labels that utof_tracker has, or purely eeg_tracker labels? I was thinking to label whether I had
> alcohol and see how it affects my state. But then I probably should have an alcohol label in my own personal app
> (utof_tracker). But if I'm labelling just this recording, I'd want a tag about this period. Decide on something and
> implement."

The answer to the second quote, in one line: **alcohol is a fact about your day, so it lives in utof_tracker; "what
was this period" is a fact about the recording, so it lives in eeg_tracker (the stop sheet and the Archive's tags);
the laptop puts the two side by side.**

## 2. What exists today (read on main `e911b2b` and the two running lanes)

- **The night recorder** is a foreground service with its own engine (`app/lib/recorder/recorder_service.dart`,
  `night_recorder.dart`). It owns the headband, writes file sets (`<stamp>.f32 .idx .log .markers.jsonl
  .header.json`), starts a new set after every drop, and runs the sleep features inside itself: the drift-off detector
  (`live_drift.dart`), the one live sleep model (`sleep/night_scorer.dart`), the smart alarm, the lucid or memory
  cues. The alarm and the cues are fixed when the service starts (`startRecorderService(alarm: ...)`).
- **Every other feature** (Work, Meditate, alpha-theta, Sound, Dream catcher, Nap coach, the check-ins, the hands-free
  calibration) runs in the screen's engine, reaches the headband itself through `dream/band_link.dart`, keeps the
  phone awake through `session_keeper.dart` (a second foreground service) and, where it keeps EEG, writes its own
  recording with `ChunkWriter` (Work: header `session: work`; the nap, the dream catcher and "fall asleep" sound: a
  plain recording that the chain rule adds to that day's night).
- **Only one may hold the headband.** Today "only between nights". The auto-start watcher (`auto/controller.dart`)
  does "nothing during a night recording or a session".
- **A night** is a chain of recordings (`recorder/nights.dart`, `scripts/night_files.py`): anything that is not
  `session: work` and starts within 3 hours of the last data or on the same evening date. So an awake evening recording
  becomes a "night", and a nap joins the night after it.
- **The Archive** (`archive/items.dart`) already calls a chain of file sets one *recording* and names it by its first
  set's stem. Its tags (`files/archive/<id>.tags.json`) are spans of clock time with a word.
- **Lane `feat/one-connection`** (worktree `~/code/eeg_tracker-connection`, in progress, `b292fd6` plus uncommitted
  work): `headband/connection.dart` `HeadbandConnection.shared` is the one owner of the connection in the screen's
  engine; every screen gets a handle (`SharedBand`) through its `finder`; one status and one device-status component
  (`headband/device_status.dart`, `ui/device_status.dart`); one quality judge (`signal/quality.dart`); a night started
  while the connection is live is **lent** the stream (`headband/lend.dart`) so Signal -> Start does not search again;
  headband-lost notices (`headband/lost_watch.dart`). While a night records, a session that asks for the headband gets
  the exception `HeldByNight` ("Stop the night first"). The panel during a night reads the **night tap**
  (`signal/live_tap.dart`: the recorder sends the batches it saves to the screen every 100 ms while a lease is
  renewed).
- **Lane `fix/share-anytime`** (worktree `~/code/eeg_tracker-share`, in progress, uncommitted): the share server
  inside the recording service is started again every 60 s when it ended by itself; `Phone.pushSoon()` sends closed
  files to the paired laptop after a recording or a session ends (`share/push/`); between recordings the phone pushes
  on a schedule.
- **Truth labels** (`feat/truth-labels` `a66dec4`): `scripts/truth_vocabulary.tsv` (8 kinds, 36 labels, sources,
  confidences), `scripts/truth.py`, `_local/data/truth.tsv`; an Archive tag ticked "This is what I was doing"
  becomes a truth row. **The data book** (`feat/data-book` `fb2b37a`): `scripts/data_book.py` writes `nights.tsv`,
  `sessions.tsv`, `days.tsv`, `epochs.tsv.gz`, `labels.tsv`.
- **utof_tracker** (`~/code/utof_tracker` `4fe14c2`, read only): habits are `habit_def` + `habit` events
  (`docs/data-format.md`); the app seeds only `coffee` and `meditation` (`app/lib/core/seed.dart`). There is no
  alcohol habit; "alcohol" appears only as a tag emoji (`app/lib/core/tag_meta.dart`).

## 3. Words

| Word | Meaning |
|---|---|
| **Recording** | Everything between one Record (or an activity that started the recorder) and its Stop: one or more file sets. Its id is its first set's stem, as in the Archive today (`2026-11-21-140502`). |
| **Activity** | Sleep, Nap, Work, Meditate, ...: a feature that can run on a recording. |
| **Span** | A stretch of clock time inside a recording with a kind ("work 14:05-16:30"). Pressing an activity opens one; stopping it closes it. |
| **Sleep span** | A span of kind `sleep` or `nap`. Reports come only from these. |
| **Sleep kit** | The recorder's own sleep features: drift-off detector, live sleep model, smart alarm, sound cues. |

## 4. The screens

The first tab is renamed **Record** (was Night). It holds the headband card (the one device-status component), the
Record button and the activity buttons. The Sessions tab keeps each activity's own page, settings and history.

Not recording:

```
 EEG Tracker
 ┌─────────────────────────────────────────────┐
 │ Headband  connected · good contact · 78 %   │   one device-status card (feat/one-connection)
 └─────────────────────────────────────────────┘
            (  ●  Record  )                        records until you stop it
 Start with:
  [ Sleep ]  [ Nap ]  [ Work ]  [ Meditate ]
  [ Sound ]  [ Dream catcher ]  [ More… ]          each also starts recording
 Last: recording yesterday 22:17-23:58 · awake     -> Archive
```

Recording, no activity:

```
 ┌─────────────────────────────────────────────┐
 │ Headband  good contact · 71 %               │
 └─────────────────────────────────────────────┘
  ● Recording  3 h 12 min   since 11:02   [ Stop ]
 Now doing:  nothing marked
  [ Sleep ]  [ Nap ]  [ Work ]  [ Meditate ]
  [ Sound ]  [ Dream catcher ]  [ More… ]          no search, no new file
 Today in this recording:
  Work 11:05-12:40 · Meditate 12:45-13:00
```

Recording with an activity (Work shown; each activity keeps its own card):

```
  ● Recording  5 h 03 min   since 11:02   [ Stop ]
 ┌─────────────────────────────────────────────┐
 │ Work  since 14:05 · 58 min                  │
 │ Level: alert          Next break: ~25 min   │   the activity's own live part
 │ [ Break ]                      [ Stop work ]│
 └─────────────────────────────────────────────┘
  [ Sleep ]  [ Nap ]  [ Meditate ]  [ More… ]      starting one pauses or ends Work (section 9)
```

Rules of the flow:

- **Record** starts the recorder and nothing else. **Stop** ends every open span, closes the files, then shows the
  stop sheet (section 7).
- **An activity button while recording** opens a span and switches the activity's live part on, on the same stream.
- **An activity button while not recording** starts the recorder, then the same. The span remembers that it started
  the recording. Its Stop shows a two-button sheet: **Stop everything** (filled, the default) and **Keep recording**.
  If the recording was started with Record, the activity's Stop just ends the activity.
- **Sleep** opens its small sheet first, as Start night does today (alarm, cues), then the span. Lights off stays a
  separate tap on the sleep card: being in bed and lights off are different moments, and the time to fall asleep is
  counted from lights off.
- **One notification**, the recorder's: "Recording · 5 h 03 min" / "Work since 14:05 · headband 62 %", with Stop. An
  activity that plays sound or uses the microphone still holds the session keeper for audio focus and the microphone
  type, with `headband: false`; it shows no second "headband" line.
- **Signal** is a view of the running recording, not an activity: it opens no span. A contact re-check that switches
  the headband to resistance mode is not offered while recording (as today during a night: it shows the last reading).

## 5. Data model

### 5.1 Recording

- Id: the first file set's stem. The recorder keeps it in its saved state (`NightState`, new field `recording`) so it
  survives drops and a restart of the process.
- Every file set the recorder opens writes `"recording": "<id>"` into its `<stamp>.header.json` (a new optional
  field; `RecordingHeader.version` stays, readers ignore unknown fields today: the builder checks that and bumps the
  version only if a reader refuses). A set with this field belongs to that recording and to no other; the Archive's
  15-minute rule and the nights' 3-hour rule apply only to sets without it.
- Raw files: unchanged format, same folder (`files/recordings/`). No `session` field for a recording: `session: work`
  is no longer written (the Work span says it).

### 5.2 Spans

One file per recording, `files/spans/<recording id>.spans.jsonl`, beside `files/recordings/`. One JSON object per
line, add-only. A span is written once when it opens and again whenever it changes; **the last line with a given
`span` id is the span**. A line is flushed to storage before the tap that caused it is answered.

| Field | Content |
|---|---|
| `v` | 1 |
| `span` | `<recording id>-<n>`, n counts from 1 in the recording |
| `kind` | `sleep`, `nap`, `work`, `meditate`, `alpha_theta`, `sound`, `dream_catcher`, `check_in`, `calibration`; a reader keeps a kind it does not know and shows its word |
| `label` | the shared vocabulary's label for it (section 8), or absent |
| `start`, `end` | local ISO time with the UTC offset; `end` null while open |
| `source` | `owner_button` (pressed), `owner_confirmed` (the app found it, you said yes), `auto_start` (the headband watcher), `migrated` (worked out for an old recording, never written to a file) |
| `started_recording` | true when this span's button started the recorder |
| `ended_by` | `owner`, `activity` (the nap's wake, a timed session's end), `other_activity`, `recording_stopped`, `headband_off`, `phone_restart` |
| `session` | the activity's own file, relative to `files/` (`work-sessions/2026-11-21-140502.work.json`), or absent |
| `paused` | list of `[start, end]` pairs: the span stayed open but its activity was paused (Work during a nap) |
| `estimate` | the confirm-questions estimate id this span confirms (`owner_confirmed` only) |
| `made` | when this line was written |

Why a file of its own and not the markers file or the Archive's tags: `.markers.jsonl` belongs to one file set and a
recording has many; the tags file is rewritten whole by the screen, while spans are added by the recorder as they
happen. One writer per file.

**Who writes.** The recorder's engine while the recording runs (the screen sends `openSpan` / `closeSpan` /
`addSpan` messages and gets the span back); the screen's engine once the recording has stopped (a sleep stretch
confirmed later). Both through one class (`SpanLog`), which refuses to write from the screen while the recorder's
saved state says this recording is active.

The recorder also writes one line into the current set's `.log` and `.markers.jsonl` per span start and end
(`span: work start`), so a raw file read alone still says what happened.

### 5.3 Activities' own files

Unchanged names and folders (`work-sessions/`, `meditations/`, `naps/`, `dream-catcher/`, `sound-states/`,
`mornings/`). Two fields are added to each: `recording` (the recording's id) and `span` (the span's id). An activity
running on a recording writes **no raw EEG of its own**: its `raw` / stem field names the recording instead. Readers
that open the session's raw signal take the recording's samples between the span's `start` and `end`.

### 5.4 To the laptop

`files/spans/` is a new folder under `files/`, so Export data and Share on Wi-Fi ("everything except") take it as it
is, and it lands in `_local/phone/spans/`. The builder checks that the push plan of `fix/share-anytime`
(`share/push/plan.dart`) takes it too, and calls `Phone.pushSoon()` when a span closes and when a report is written,
so the laptop has a nap's report while the recording goes on. The laptop's reader is a new `scripts/spans.py`, the
twin of the Dart reader, checked against the same golden files (section 11).

### 5.5 Old data

Nothing is rewritten or moved. A recording with no spans file whose header has no `recording` field is **old**, and
its spans are worked out each time it is read (kept only in `files/cache/`), source `migrated`:

| Old file set | Read as |
|---|---|
| header `session: work` | a `work` span over the set |
| named by a nap, dream catcher or sound session file | a span of that kind over the session's times; for the nap also a `nap` sleep span |
| a check-in's or calibration's set | `check_in` / `calibration` |
| anything else from the night recorder | one `sleep` span over the chain, as a night today |

Existing reports (`files/nights/<date>.report.json`) are read as they are; a report without the new `span` field is
an old one. An old recording that was not sleep (the awake evening of 2026-11-20 22:17-23:58) gets an Archive action
**"Not sleep"**: it writes a spans file for it that says so (one line, `{"v":1,"reviewed":"no_sleep","made":...}`),
after which it is no night and its report is hidden, never deleted. The planned join / split in the Archive stays the
tool for old chains and for breaks in recording.

## 6. Reports come from sleep spans

- **What gets a report.** A sleep span with source `owner_button` always (a night with no sleep is worth seeing).
  A span with source `owner_confirmed`. A span with source `auto_start` or `migrated` only when its scoring finds
  10 minutes or more asleep (the noise limit of `sleep/periods.dart`); otherwise it is listed as "no sleep found".
  Nothing else: a recording without a sleep span is never scored as a night and never appears in Trends' sleep rows.
- **Night or nap.** Kind `sleep` pressed: a night. Kind `nap`: a nap. Confirmed, auto-started or migrated spans:
  DECISIONS 761's rule (under 3 hours asleep is a nap).
- **Which samples.** The recording's samples from the span's start to its end, nothing outside. The after-night
  scorer scales over its whole input, so awake hours around the span must not be in it.
- **Nights from spans.** Sleep spans of kind night are joined into one night by today's rule applied to spans
  instead of recordings: the next span starts under 3 hours after the last one's end, or has the same evening date,
  within 24 hours of the first. The night keeps today's name and file, `files/nights/<evening date>.report.json`,
  so Trends, the export (`eeg_sleep_night`) and the laptop read it unchanged. New field `span`:
  `{"recording": [...ids], "spans": [...ids], "kind": "night" | "nap", "from": "pressed" | "confirmed" | "auto" | "migrated"}`.
- **Naps** get `files/nights/naps/<span start stamp>.report.json`, the same format, and never join a night. (A
  subfolder, so nothing that lists `nights/*.report.json` picks a nap up as a night.)
- **When it is built.** When a sleep span ends, and again when its recording stops (the recording's end can add a
  later span to the same night). Scoring waits while the live sleep model runs or an activity with a live part runs
  (the memory rule of DECISIONS 236 and 583), and starts when they end.
- **Sleep the app found.** Outside sleep spans the app only proposes: the confirm-questions lane owns the estimates
  ("Did you sleep 15:59-17:49?"). Yes makes a span (`owner_confirmed`, with the estimate's id) through
  `SpanLog.add`, and the report follows. No answer: the Archive shows "Maybe slept 15:59-17:49" with the question;
  no report. No: nothing here (the confirm lane keeps the negative label).
- **The laptop** follows the same rules: `scripts/night_files.py` builds nights from sleep spans where a recording
  has a spans file and from the old chain where it has none; `sleep_report.py` and the catalog take the span's
  samples. `nights.tsv` gains `recording`, `span_ids`, `span_from`; a new `spans.tsv` has one row per span.

## 7. The stop sheet

Shown after Stop, once the files are closed (and as a card on the Record tab if the app was not open, or the
recording ended without you: section 9).

```
 What was this recording?        11:02 - 19:40 · 8 h 38 min
 Already marked:  Work 11:05-12:40 · Meditate 12:45-13:00 · Work 14:05-16:30
 ( Awake the whole time )
 ( Slept ) ( Napped ) ( Worked ) ( Walked ) ( Ate )
 ( Exercised ) ( Meditated ) ( Talked / meeting ) ( Other )
 Only part of it:  [ 17:00 ] - [ 17:40 ]      shown after a chip is tapped; off = the whole recording
 In your words (optional): ______________________
 ── A few quick questions ──                   the confirm-questions batch for this recording
 Did you sleep 15:59-17:49?   [ Yes ] [ No ] [ Not sure ]
                                   [ Skip ]  [ Save ]
```

- Chips are one tap each; several may be on. "Awake the whole time" switches Slept and Napped off, and the reverse.
- Each chip has its own "only part of it" times (a long press, or the row that appears under the last tapped chip);
  without times it means "at some point in this recording".
- Chips for kinds already covered by pressed spans are shown as done ("Already marked") and are not asked again.
- **Skipped altogether** when pressed spans cover 90 % or more of the recording and no question waits (the usual
  morning: Sleep, then Stop everything, goes straight to the report).
- Skip is one tap and writes nothing. The sheet can be reopened later from the recording's page in the Archive.

**What is saved.** Each chip becomes a tag in the recording's `files/archive/<id>.tags.json` with three new optional
fields, so the Archive shows it and the laptop already reads the file:

```
{"start": iso, "end": iso, "label": "walking", "made": iso,
 "truth": true, "source": "owner_stop_sheet", "confidence": "within", "words": "walked to the shop and back"}
```

`scripts/truth.py` turns such a tag into a truth row: `source` `owner_stop_sheet` (a tag without `source` stays
`owner_app_tag`), `confidence` from the tag, `words` verbatim into `owner_words`, `context` "stop sheet". The free
text goes, unchanged, into every row the sheet makes; text with no chip makes one `other` row.

| Chip | Label | Confidence without times | With times |
|---|---|---|---|
| Awake the whole time | `awake` | `certain` (the whole recording) | not offered |
| Slept | `night_sleep` (new) | `within` | `likely` |
| Napped | `nap` | `within` | `likely` |
| Worked | `working` | `within` | `likely` |
| Walked | `walking` | `within` | `likely` |
| Ate | `eating` | `within` | `likely` |
| Exercised | `exercise` | `within` | `likely` |
| Meditated | `meditating` | `within` | `likely` |
| Talked / meeting | `meeting` | `within` | `likely` |
| Other, or text alone | `other` (new) | `within` | `likely` |

`within` is a new confidence: "it happened somewhere inside the span, not all of it". The detector check counts such
a row only as "did the detector fire at all inside it", never minute by minute.

"Slept" or "Napped" **with** times also offers "Make a sleep report for 23:50-07:10?"; yes adds a sleep span
(`owner_confirmed`). Without times it only records the fact and asks the confirm lane to put its sleep estimates for
this recording first.

**The hook with confirm-questions** (`feat/confirm-questions`, designing now). Three calls, owned by that lane; the
stop sheet only uses them:

- `ConfirmQuestions.pendingFor(recordingId, start, end, {max: 5})` -> the questions to show (its own widget
  `ConfirmBatch` draws them; the stop sheet gives it a slot under the chips and shows nothing when the list is empty
  or the lane is not merged yet).
- `ConfirmQuestions.settle(recordingId, label, start, end, {answer})`: the stop sheet tells it what a chip already
  answered, so the same thing is never asked twice. "Awake the whole time" settles every sleep estimate in the
  recording as No; "Walked 17:00-17:40" settles a walking estimate inside those times as Yes.
- A Yes on a sleep estimate calls record-first's `SpanLog.add(kind, start, end, source: owner_confirmed, estimate: id)`.

Its answers keep its own source (`owner_app_prompt`); the stop sheet's chips are `owner_stop_sheet`.

## 8. Which app holds which label

The rule (boundary note, section 4.1): **utof_tracker is where you tell things about yourself; eeg_tracker is where
the headband records and what you were doing while it recorded.**

| Label | Home for the owner | In eeg_tracker |
|---|---|---|
| Alcohol, coffee, medicine, mood, tension, illness, headache, stress, places | utof_tracker | only for people without utof: the Mark button offers the same tags; hidden when "Linked to utof_tracker" is on |
| What you did during a recording (sleep, nap, work, meditate, walk, eat, talk...) | eeg_tracker: spans, the stop sheet, Archive tags | - |
| A note about this recording's period | eeg_tracker: the stop sheet's own words, Archive tags | - |
| Headband facts (off the head, adjusted, contact) | eeg_tracker | - |

**One shared vocabulary.** `scripts/truth_vocabulary.tsv` is the list, for both apps and both directions. It becomes
part of the shared contract (`docs/tracker-contract.md`, the boundary note's section 4.4, item 5): the format doc
names the file and its version, golden files show valid and invalid rows, and each repo has a test that its own
words map into it (section 11). The phone gets it as a generated Dart file (`app/lib/labels/vocabulary.g.dart`, made
by a script from the TSV, with a test that fails when the two differ), so a chip, a span kind or a Mark tag can never
use a word the laptop does not know.

Additions (row 893):

| Field | Id | Kind | Unit | Meaning |
|---|---|---|---|---|
| label | `night_sleep` | state | | a night's sleep: mostly asleep, not every minute |
| label | `other` | activity | | something the list has no word for; `owner_words` says what |
| label | `neurofeedback` | activity | | a feedback training session (alpha-theta) |
| label | `taking_medicine` | event | doses | taking a medicine; `owner_words` names it |
| label | `stressed` | state | | under stress |
| label | `at_home`, `away` | state | | at home; out of the home (utof's places) |
| source | `owner_stop_sheet` | | | a chip or your words on the sheet after Stop |
| source | `owner_activity_button` | | | an activity you started and stopped in the app |
| source | `owner_utof` | | | you logged it in utof_tracker |
| source | `device_utof` | | | utof_tracker's phone collector (places, steps, screen) |
| confidence | `within` | | | it happened somewhere inside the span, not all of it |

Span kinds map to labels: `sleep` and `nap` -> `in_bed` (pressing Sleep says you went to bed, not that you slept; the
report says that); `work` -> `working`; `meditate` -> `meditating`; `alpha_theta` -> `neurofeedback`; `sound` ->
`sound_session`; `dream_catcher` -> `resting`; `check_in`, `calibration` -> none. `truth.py` reads
`phone/spans/*.spans.jsonl` and makes a truth row per closed span with source `owner_button` or `owner_confirmed`:
source `owner_activity_button`, confidence `likely` (you may have forgotten to stop it), `recording` filled.

### Alcohol

- **In utof_tracker** (a change for a utof lane; this lane only reads that repo): add a seeded habit beside coffee,
  `habit_def` `{key: "alcohol", name: "Alcohol", kind: "count", unit: "drink", quick: [1, 2, 3]}`. One tap per drink
  at its time, "Add earlier" as for coffee: one `habit` event per drink with `amount` and `ts`. Until that build is on
  the owner's phone, eeg_tracker's morning check-in keeps asking "yesterday's drinks".
- **To the laptop.** utof's feed for eeg (boundary note step 4, not built) writes each drink as a label row:
  `drinking_alcohol`, `value` the amount, `unit` `drinks`, `source` `owner_utof`. The data book reads the feed into
  `labels.tsv` / `truth.tsv`. For people without utof, the Mark button's alcohol tag gives the same row with source
  `owner_mark_button`. The check-in's old "yesterday's drinks" answers fill the past (source `owner_checkin`, no
  time of day).
- **Joined by time.** `nights.tsv` gains `alcohol_drinks` (the drinks from 12:00 on the night's evening date until
  the sleep span starts), `alcohol_last` (the last drink's time) and `alcohol_from` (`utof`, `eeg_mark`, `checkin`).
  An empty cell means "not known" (no source covered that evening), 0 means "a source covered it and logged none".
  The laptop's report page shows one line: "Alcohol: 2 drinks, last at 20:00 (from utof_tracker)". The phone's report
  cannot show it: the two phone apps do not talk to each other.
- **Comparing nights.** A new `scripts/compare_nights.py --by drinking_alcohol` (it works for any event label:
  coffee after 16:00, medicine) writes `_local/data/compare/alcohol.md` and `.tsv` after each data book run:
  time asleep, deep sleep, dream sleep, wake-ups, time to fall asleep, pulse asleep, and the next morning's
  sleepiness and reaction time, for nights with a drink against nights with none, from the last 90 days.
  - Under 5 nights of either kind: "Not enough nights yet (3 with, 12 without)".
  - From **5 of each**: the two middle values side by side, marked "so far, too early to tell".
  - From **10 of each**: says whether they differ (the shuffle test of DECISIONS 203, and only if the gap is at least
    the measure's smallest change that matters). The words are "seen together", never "caused": drinking nights are
    often later nights and weekends too.
  - Plainly: 10 of each catches only a big difference (more than the usual night-to-night wobble). A difference
    about the size of that wobble needs about 16 of each. At one or two drinking nights a week that is 2 to 4 months.
  - For a real answer sooner there is the self-experiment page (planned days with and without, DECISIONS 200-203).

## 9. What each feature becomes

| Feature | Today | Becomes |
|---|---|---|
| Start night | starts the recorder with the sleep kit | **Sleep**: starts the recorder if needed, opens a `sleep` span, attaches the sleep kit to the running recorder. Lights off, Alarm off, Sleep so far unchanged, counted from the span's start |
| Stop (night) | ends the night, then scoring | **Stop sleep**: closes the span, detaches the kit, scores the span; the recording goes on unless Sleep started it and you pick Stop everything |
| Nap coach | own connection, own recording, screen kept on | `nap` span; its timer, wake cue and report as today; reads the recording's stream; the nap's own `.nap.json` names the recording and span; its report is a nap report (section 6) |
| Work session | own connection, raw file `session: work` | `work` span; level, hints, breaks as today; no raw file of its own; its calibration minute runs once per span |
| Meditate, alpha-theta | own connection, session log with every input sample | `meditate` / `alpha_theta` span; the session log stays (it is the replay record) |
| Sound for states | own connection; raw kept only for "fall asleep" | `sound` span; never writes raw; "fall asleep" also opens a `sleep` span when you choose it there |
| Dream catcher | own connection and recording, microphone | `dream_catcher` span; holds the session keeper for the microphone only |
| Morning / evening check-in, hands-free calibration | own connection and short recording | `check_in` / `calibration` span |
| Signal | own connection or the tap | a view of the stream; no span |
| Auto-start (headband watcher) | starts the night recorder or opens the Work page; does nothing during a recording | starts the recorder; guess "night" -> also a `sleep` span with source `auto_start` (no alarm, no cues, as today); guess "work" -> a `work` span; "other" -> recording only. During a recording it does nothing |
| Battery guard | stops a daytime session to keep tonight's charge | never stops a recording; one notice "Headband at 35 %: charge it before bed" when the estimate says it will not last the night |
| Archive | recordings by the 15-minute rule; kinds from session files | recordings by `recording` id; each shows its spans on its timeline; old ones as before |
| Trends, export | nights from chains | nights from sleep spans; `eeg_sleep_night` unchanged in format |

**Where the live parts run.** The sleep kit stays in the recorder's engine (it must outlive the screen). Everything
else stays in the screen's engine and reads the recorder's stream through the tap. The recorder gets two new
commands for the kit, `attachSleep(alarm, cues)` and `detachSleep`, replacing "fixed at service start"; a DIY board
recording refuses the kit with the words it uses today.

**Building on one connection owner.** `feat/one-connection` delivers the owner, the handles, the lend, the status
card, the judge and the lost notices; record-first does not rebuild any of them. The build lane changes exactly:

1. `HeadbandConnection._acquire`: while a recording runs it returns a new handle, `RecordingBand`, instead of
   throwing `HeldByNight`. `RecordingBand` implements `Headband` and `KnownContact`: `signal` is the tap's batches;
   `startResist` does not touch the headband and gives the recorder's contact reading; `battery` and `rangeChanges`
   come from the recorder's status (reconnecting = out of range); `disconnectAndDispose` only ends its lease. The
   sessions' `BandLink` then works on it unchanged, and its reconnect rules stay idle (the recorder reconnects).
2. The tap (`signal/live_tap.dart`): leases are counted per user (the panel, each activity) instead of one on/off
   lease, and the tap sends every sample of N channels in order with its packet number, with no drops while a lease
   is held (the builder measures the cost of 100 ms batches across the engines over 8 hours; target under 2 % of one
   core).
3. `BandUse` gets the recording's activity for the status card ("Recording · Work").
4. An activity started while nothing records calls the owner's `lendToNight()` exactly as Start night does on that
   lane, so a live connection is handed to the recorder without a search.
5. `HeldByNight` and its message are deleted.

`fix/share-anytime` delivers sharing from inside the recording service (now the main path, since a recording may run
all day) and the push after files close; record-first adds only the two `pushSoon()` calls of section 5.4.

## 10. Edge cases

| Case | What happens |
|---|---|
| The app's screen is swiped away while recording | The recorder goes on (as today). The sleep kit goes on. A screen-side activity (Work...) loses its live part; its span **stays open**, because the span is what you said you were doing. Reopening the app shows its card with "Resume" (Work continues its session file; a timed session that ran out is closed at its planned end, `ended_by: activity`) |
| Android kills and restarts the process | The service restarts and opens a new file set in the same recording (as today). `SpanLog` reads the file back; open spans stay open; the sleep kit is attached again if a sleep span is open |
| The phone reboots | Recording does not resume by itself (today's rule, `autoRunOnBoot: false`). At the next app start, open spans are closed at the recording's last saved sample (`ended_by: phone_restart`), sleep spans are scored, a notification says "Recording stopped when the phone restarted", and the stop sheet waits as a card |
| Headband lost or off the head | The recorder keeps reconnecting (as today); spans stay open; the activity's card says "Headband lost 4 min"; the lost notices come from `feat/one-connection`. After **60 minutes** off or lost, every open span is closed at the last worn moment (`ended_by: headband_off`), sleep spans are scored, and a notice offers "Still going? Undo". After **6 hours** without any data the recording stops itself with a notice, and the stop sheet waits as a card |
| Two activities at once | Sleep and Nap pause Work (Work's own "on a break", reason "sleep"; its span stays open with a `paused` pair; it resumes when the sleep span ends) and end any other activity. Any other activity started during Work pauses Work the same way. Otherwise a new activity ends the running one (`ended_by: other_activity`), with "Undo" for 5 seconds. Sleep and Nap never run together |
| Work, then a nap, then Work | One recording; spans: work 11:05- (paused 13:00-13:35), nap 13:00-13:35; one nap report at 13:35 while the recording goes on |
| An activity with no headband found | Record and the span start anyway (the recorder shows "Looking for the headband" as today). The span is a true statement about your time and is kept. The activity's card says "Waiting for the headband" and its live part starts when data arrives. If no sample ever arrives, Stop keeps the spans file and the `.log` (the Archive lists it as "no signal") |
| An activity that needs no headband (meditation timer, sound without the headband) | When nothing records and you choose "without the headband" on its page, it runs as today, with no recorder and no span |
| Stop while a sleep report is being scored | The recording stops; scoring goes on (it reads closed samples); the stop sheet shows at once |
| The clock changes (travel, a network correction) | Spans keep clock times with their offset, as markers do; lengths shown on the cards come from the monotonic clock (`session_clock.dart`) |
| A very long recording (16 h is about 290 MB in one file set) | No roll-over in this build; the builder replays 16 hours and checks that no reader loads a whole set into memory (section 13) |
| The DIY board | Spans and the stop sheet work for any board. The sleep kit and the activities that read O1 O2 T3 T4 refuse it in words, as today; nothing is hard-wired to 4 channels in the new code |

## 11. Tests the build lane must write

Phone (Dart, on fakes and the replay headband; no real phone):

1. `SpanLog`: open, close, re-read after a kill in the middle of a line (a half line is ignored, the rest is read);
   the last line per id wins; the screen may not write while the recording is active.
2. Record -> Work -> Stop work -> Sleep -> Stop sleep -> Stop: **one** recording id in every set's header, one
   connection (the fake finder is asked once), no second contact check, no raw set written by Work, the spans as
   pressed.
3. Sleep pressed 3 hours into a recording: the live model, alarm and cues start at the span, not at the recording;
   the report covers only the span's samples; the recording continues after Stop sleep.
4. An awake recording (Record, 2 h, Stop, no sleep span): no report, no night in `nights.dart`, nothing in Trends'
   sleep rows.
5. Work, a nap inside it, Work: the `paused` pair, one nap report in `nights/naps/`, no night.
6. Sleep started the recording: Stop sleep offers Stop everything / Keep recording; each does what it says. Record
   started it: Stop sleep asks nothing.
7. Old data: the committed phone export fixture (no spans files) lists the same nights with the same reports as
   before this change, bit for bit; "Not sleep" hides one.
8. The stop sheet: each chip's tag (label, source, confidence), times, the verbatim text with a tab and a quote in
   it; Skip writes nothing; skipped by itself when pressed spans cover 90 %; "Awake the whole time" settles the fake
   confirm lane's sleep estimates.
9. `RecordingBand`: an activity started during a recording gets every sample the recorder saved (compare packet
   numbers over 10 minutes of replay, 4 and 8 channels), sees a drop as out of range and the stream again after the
   recorder reconnects, and never calls the SDK.
10. Restart cases: process kill with an open sleep span (kit attached again, same span); reboot (spans closed at the
    last sample, the card shown); headband off 60 minutes (spans closed at the last worn moment, Undo reopens).
11. The vocabulary: the generated Dart file equals the TSV; every chip, span kind and Mark tag maps to a label in it.

Laptop (pytest, `analysis/tests/`):

12. Golden span files (`tests/contract/spans/`: valid, a half last line, an unknown kind, an open span) read the same
    by `scripts/spans.py` and the Dart reader.
13. `night_files.py`: nights from spans; an awake recording gives none; an old folder gives what it gave before.
14. `truth.py`: stop-sheet tags and button spans become rows with the right source and confidence; `within` rows are
    scored only as "fired at all".
15. The data book: `spans.tsv`; `alcohol_drinks` for a night with drinks at 20:00 and 21:30 (2, last 21:30, `utof`),
    a night with a covered evening and none (0), a night no source covered (empty).
16. `compare_nights.py`: the three wordings at 3, 5 and 10 nights of each kind on made-up data with a known gap.

Contract (both repos): the vocabulary TSV and golden label rows are copied into utof_tracker's fixtures with a test
that its habit keys and tags map into it and that the copy matches (as `pc/tests/fixtures/eeg-export/` does today).

## 12. Build plan: 5 slices, each merges on its own

| # | Slice | What works after it | Needs |
|---|---|---|---|
| 1 | **Spans and the Record button.** `SpanLog`, the `recording` id in headers and saved state, span commands in the recorder, `files/spans/`, the Record tab with Record and Sleep (Sleep = Record + a sleep span + today's kit at start, so nothing a night does today changes), old-data reading, `scripts/spans.py`, `docs/data-format.md`, golden files. Tests 1, 7, 12 | You can record all day. Every recording has an id and spans. Nights still read by the old chain | int19's main |
| 2 | **Sleep on a running recording; reports from spans.** `attachSleep` / `detachSleep`, span-scored reports, naps' reports, nights from spans on the phone and the laptop, "Not sleep", auto-start's mapping, the 60-minute and 6-hour rules, restart cases. Tests 3, 4, 10, 13 | Sleep and Stop sleep inside a recording. An awake recording is not a night. Reports rebuild on span end and on Stop | slice 1 |
| 3 | **The stop sheet and its labels.** The sheet, the tags' new fields, the vocabulary additions and the generated Dart file, `truth.py` for tags and spans, the confirm-questions slot. Tests 8, 11, 14 | "What was this recording?" after Stop; answers reach `truth.tsv` | slice 1; confirm-questions for the question batch (the sheet works without it) |
| 4 | **Daytime activities on the recording.** `RecordingBand`, the tap's leases, Work, Meditate, alpha-theta, Sound, Dream catcher, Nap coach, check-ins, calibration; pause rules; Stop everything / Keep recording; the one notification; `HeldByNight` removed; the battery notice. Tests 2, 5, 6, 9 | Every button works during a recording with no new search, file or calibration | slices 1-2; `feat/one-connection` merged |
| 5 | **Labels across the two apps.** The contract's vocabulary section and conformance tests in both repos, the Alcohol habit and the label feed in utof_tracker (a utof lane), `spans.tsv` and the alcohol columns in the data book, the report line, `compare_nights.py`, the Mark tags hidden when linked. Tests 15, 16, contract | Alcohol logged in utof shows on the night; the with / without comparison | slice 3; data book and truth labels on main; a utof lane |

Slices 3 and 4 do not depend on each other and can run side by side. Each slice adds its "i" evidence note
(`docs/evidence/`) and its `docs/data-format.md` section.

## 13. Left to the builder

- Names in code: only the words the owner reads change in slice 1 ("night" -> "recording"). Renaming
  `NightRecorder`, `NightState` and the service's channel name is the builder's call; the Android channel id
  `night_recording` stays (changing it resets the owner's notification settings).
- Whether header version must rise for the `recording` field (check every reader first, Dart and Python).
- The tap's exact message shape for N channels and its measured cost; batch size.
- How far "Resume" goes for each screen-side activity after the screen was closed (Work must; the others may simply
  close at their planned end).
- The 16-hour replay: memory and time of the Archive's pass, "Sleep so far", the scorer reading a slice of a large
  set, packing a set that is still being written. Add a roll-over only if one of them fails.
- The planning values: 60 minutes off the head, 6 hours without data, 90 % cover for skipping the sheet, 5 seconds
  of Undo, 12:00 as the start of the alcohol window. Keep them as named constants.
- The exact look of the Record tab and the cards; the mocks above fix the content and order, not the pixels.

## 14. Not in this design

- The estimates themselves (which detector proposes "you slept 15:59-17:49"): the confirm-questions lane.
- The Mark button and the evening review: their own lane; this design only says which tags it offers and when it is
  hidden.
- utof's feed to the laptop as a whole (boundary note step 4): only the alcohol row is fixed here.
- A contact re-check during a recording.
