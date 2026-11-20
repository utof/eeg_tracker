# The app's own records: log, usage and battery

The phone app keeps three records about itself, so the owner and the assistant can see how the app is used and what
costs battery, and optimise (owner, 2026-11-20: "extensive logging ... record how I'm using the app ... log how the
battery drains, so we understand which features are expensive"). The choices and their alternatives are DECISIONS
rows 710-719; the owner's look at them is the README's "Logs, usage and battery" owner step.

Everything stays on the phone, in the app's private folder. Nothing is sent anywhere by these records: there is no
network code in them. They leave the phone only the way every other file does: **Export data**, **Share on Wi-Fi**
(the laptop's copy), or the log page's **Share the log**, which the owner taps.

## Where

`files/logs/` inside the app (other apps cannot read it), one file per kind, day and Flutter engine:

| File | What | Kept |
|---|---|---|
| `app-2026-11-20-screen.jsonl` | the app log: every subsystem's lines, levelled | 7 days, at most 20 MB |
| `usage-2026-11-20-screen.jsonl` | how the app is used (only while the switch is on) | 90 days, at most 10 MB |
| `metrics-2026-11-20-recorder.jsonl` | measurements: battery, CPU, memory, frames, start-up, storage, contact | 60 days, at most 20 MB |
| `settings.json` | the switches | |

The engines: `screen` (the app's screen and its sessions), `recorder` (the night recorder's service), `auto` (the
headband watcher). Each writes its own files, so two never write the same file. A file over 4 MB continues in `-2`,
`-3`. Old files are pruned when an engine starts and once a day: past the kind's days first, then the oldest of the
kind until it fits its size; a file written in the last 10 minutes is never pruned (another engine may hold it open).

On the laptop, `scripts/pull_phone.py` and `scripts/import_phone.py` put them in `_local/phone/logs/` (they are
ordinary files of `files/`). Today's files grow; the pull fetches their new ends.

## What

Every line is one JSON object with `t`, the local time with milliseconds and the offset
(`2026-11-20T14:31:02.123+03:00`).

**App log** (`level`: `fine` / `info` / `warn` / `error`; `sub`: the part of the app; `msg`; `data`: facts; for a
warning or an error also `error`, the first 25 frames of `stack`, the `screen` shown and what was `on`):

- `recorder`: the night's notes (start, Stop, restarts), `connected <band>` with its signal strength and battery,
  `headband link dropped: <cause>`, `headband back after a drop` with `reconnect_ms`, `how` and `try`
- `ble`: each scan's headband found and its signal strength (the BrainBit gives no live value, PRODUCT.md)
- `share`: Share on Wi-Fi on and off, its port and how many addresses it has (never the addresses), its errors, its
  uptime (`up_s`), whether it shares on this Wi-Fi (home, allowed here, paused), the laptop's proofs before deleting,
  and every 10 minutes the laptop copied anything: files and MB
- `scoring` (each night's scoring time), `packing` (what was packed), `export` (files, bytes, time), `sessions` (a
  session held or let go), `sound` (a call or another app taking the sound), `auto` (every line of the headband
  watcher's own log), `usage` and `battery` (their switches)
- `app`: the first frame after start, Flutter's errors and every error nobody caught (they still reach Android as
  before); `print`: every `debugPrint` of the app (at most 120 a minute); the libraries' own loggers under their names
  (flutter_soloud's warnings)

**Usage** (`ev`), only while **Record how I use the app** is on:

- `view` the screen on top: a page's widget name (`MeditationScreen`), a home tab (`tab:Signal`), `dialog`, `sheet`
- `app` the app came to the front or left it
- `tap`: `control` (its kind: `FilledButton`, `Switch`, `ListTile`, ... or `nothing` for a tap on no control),
  `label` (the control's own words, at most 40 characters, every digit as `#`; never words the owner typed, see
  below), `id` (its key), `long`
- `scroll` (by finger): `axis`, `dir`, `px`, `ms`, `reach` (how far down the page, 0-1); `drag`: a swipe that
  scrolled nothing (the 3D head): `dir`, `px`, `ms`, `fingers`
- `feature` started or stopped with how long it ran (`s`); `setting` changed
- `hint`: `kind` (`work-break`, `auto-start`), `step` (`shown`, `answered` with `answer` and `after_s`, `ignored`,
  `break`: a work break started, so a break hint can be checked against it)

**Metrics** (`kind`):

- `power`: `pct`, `uah` (the charge counter), `ua` (current; its sign differs between phones), `plug`, `temp`, `mv`,
  `screen`, `doze`, `cpu` (this process's CPU time in ms, all engines), `rss` (its memory), `on` (the features on in
  this engine), `why` (`start`, `every`, `change`, `back`, `stop`), and `band` while the night recorder holds the
  headband (its battery, signal strength, phase)
- `frames`: per screen and minute, `n`, `slow` (build or raster over 16.7 ms), `janky` (over 33 ms), `worst_ms`, `mean_ms`
- `startup`: `main_ms` (main() to the first frame), `process_ms` (the process's age at the first frame: a cold start
  when under a minute)
- `storage`: once a day, the bytes of each folder of `files/` (`cats`) and their `total`
- `contact`: each contact reading (`source`: `night`, `session`, `signal`, `auto`) with `ohms` per channel

The features (`on`, `feature`): `app-open`, `night`, `headband` (streaming), `live-model`, `cues`, `share`,
`wifi-lock`, `signal` (the Signal tab shown), `scoring`, `packing`, `export`, `auto-check`, `session:<title>`
(`session:Meditation`, `session:Work session`, ...). A subsystem marks itself with one line,
`Activity.begin('x')` / `Activity.end('x')` (`lib/logs/activity.dart`).

## What is never recorded

- Nothing outside this app: no other app, no window, no notification. That would take an Android accessibility
  service, and there is none. A switch for one (to see which apps the owner uses around a session) is a possible
  opt-in later, not built.
- Nothing the owner typed, anywhere in these files: not in a text field (a dream answer, a note, an experiment's
  name as you type it), and not later either, when the app shows it back (an archive tag, an experiment's line, a
  "Try these" note, a stop plan, a DIY board's channel names). A tap's label is the tapped control's own words: a
  button says what it does, a row says what it is. Where a row shows something the owner wrote, the app marks those
  words (`OwnText`, `lib/logs/own_text.dart`) and the label skips them, and a tooltip inside a mark; the label then
  falls to the row's other words, its kind or nothing, and `control` and `id` stay. Whoever shows owner-typed text
  inside or beside a control wraps it in `OwnText` (`test/logs_private_test.dart` checks the places that sit inside a control). A site
  name is read only when it is a 10-10 name (`O1`, `Fz`), the same word for everybody.
- No experiment's name or question in any file: the log carries only fixed words (`session:Meditation`, the screen
  `Self-experiments`). A session's name is the fixed title of its screen, never typed text (a test reads every
  `KeepSpec` title).
- No position, no network names, no sound, no EEG in these files (the recordings are their own files). No network
  address either: the app log writes any IPv4 address as `#.#.#.#` (message, data and error alike), and the DIY
  board's `.log` says "datagrams from the board on the Wi-Fi" and counts its senders, never names one.

## Turning it off and deleting it

- **More > How I use the app > Record how I use the app**: off, and no usage line is written (the switch is read by
  every engine as it starts; the night recorder's service picks a change up at its next night). **Delete what was
  recorded** removes every usage file.
- **More > Battery > Measure battery**: off, and no battery sample is taken. **Delete the battery samples** removes
  the metrics files.
- The app log cannot be switched off (it is how a failure is found), but it keeps only 7 days and 20 MB. **More > App
  log > Delete the app log** removes it. `settings.json` has `"detailed": true` for the `fine` lines (no switch yet).
- Android's **Settings > Apps > EEG Tracker > Storage > Clear data** removes everything with the rest of the app.
- The Storage page (a parallel lane) lists `logs/` as its own category.

## How the battery numbers are made

`lib/logs/battery_report.dart`, tested with made-up phones in `app/test/logs_battery_test.dart`:

1. The samples of every engine (and the night logs' own `phone battery` lines from before this existed), sorted by
   time; between two neighbours is a stretch. A charger at either end, or a charge that went up, leaves it out. Its
   use is the charge counter's drop (or the level's, times the battery's size).
2. A stretch up to 10 minutes is "watched": what was on is every engine's latest sample from the 5 minutes before, plus
   the screen. A longer one (up to a day) is the phone with the app closed: other apps and their screen time included.
3. Per combination: hours, mAh, mAh an hour, the app's CPU share.
4. Things always on together (a night and its headband link) are one group. Each group's rate is fitted so the
   groups on together add up to each combination's rate (least squares weighted by hours, no rate below 0). "Signal
   tab adds 60 mAh an hour" means: over the app's other pages, the screen counted with the open app.
5. The advice: the share of the battery an hour, what it adds, "mostly the screen" when it runs with the screen on and
   the screen costs more than it, "the app's code kept the processor busy 35 %: worth optimising" over 25 %, and its
   mAh a day as used.

Limits: the whole phone is measured, not the app alone; the charge counter moves in steps on some phones, so a group
needs 15 minutes before it gets a number; a feature that only ever runs with another cannot be told apart from it.

The headband's battery (`headbandRun`): the gauge's 0-2 % and 100 % are stuck values (DECISIONS 40), and a value that
makes up half the readings for 3 hours or more is stuck too (2026-11-19: 6 % for nine hours); a jump up of over 3 %
is a charge and starts the trend again; a straight line through the rest gives % an hour.

## Going deeper with Android's own tools (for the assistant)

The app's numbers say what was on; Android's own battery statistics say which part of the phone used it (CPU,
Bluetooth, Wi-Fi, screen, wake locks) per app. With the phone on adb and the owner's OK:

```bash
adb shell dumpsys batterystats --reset            # start a clean measurement (unplug the phone after this)
# ... a night, or an hour of the feature to measure, unplugged ...
adb shell dumpsys batterystats --charged io.github.utof.eeg_tracker > batterystats-eeg.txt
adb shell dumpsys batterystats > batterystats-all.txt   # "Estimated power use (mAh)" per UID; Bluetooth and Wi-Fi times
adb bugreport bugreport.zip                       # for Battery Historian (a timeline of wake locks, radio, screen, CPU)
docker run -p 9999:9999 gcr.io/android-battery-historian/stable:3.1 --port 9999   # then open localhost:9999, load the zip
```

Useful beside them: `adb shell dumpsys deviceidle` (Doze), `adb shell dumpsys power` (wake locks held now),
`adb shell top -H -p $(adb shell pidof io.github.utof.eeg_tracker)` (which thread burns CPU), and Perfetto
(`adb shell perfetto`, or ui.perfetto.dev) for a trace with CPU frequency; phones with power rails (Pixels) show
per-rail energy there, a Xiaomi usually does not. Join them with the app's own files by time: the metrics' `on` says
which feature ran when Battery Historian shows a wake lock or a radio burst.

Reading the app's files on the laptop:

```bash
jq -c 'select(.level=="error")' _local/phone/logs/app-*.jsonl              # every error with its screen and features
jq -c 'select(.kind=="power") | [.t, .pct, .uah, .screen, .on]' _local/phone/logs/metrics-*.jsonl
jq -r 'select(.ev=="tap") | "\(.screen) \(.label // .control)"' _local/phone/logs/usage-*.jsonl | sort | uniq -c | sort -rn | head
```
