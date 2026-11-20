# The laptop tray: work sessions and break hints

A small icon in the panel at the bottom of the screen (Linux Mint, Cinnamon). It notices when you start working on
the laptop, keeps a record of each work session, and now and then suggests a short break. It needs no headband: it
reads [ActivityWatch](https://activitywatch.net), which already runs on the laptop and notes which window is in
front and whether the keyboard and mouse are in use. Window titles are read in memory only; nothing is written about
what you looked at, and nothing leaves the laptop.

## Start it

```bash
python3 scripts/tray.py
```

Use the laptop's own `python3` (it has the panel-icon library); `uv run` is not needed. A second copy just says it
is already running. To have it start with the laptop: **Settings → Start at login** in its menu (off until you tick
it; untick to stop).

Two ways to look without the icon (they write nothing):

```bash
python3 scripts/tray.py --once       # what the menu would say right now
python3 scripts/tray.py --dry-run    # the last 24 hours replayed: how often it would have asked, started, hinted
```

## What you see

The icon changes with the state (shape and colour; the menu always says it in words too):

| Icon | Means |
|---|---|
| green dot | working: a work session is running |
| amber pause bars | on a break |
| grey ring | not in a work session |
| amber circle with **!** | it is waiting for you: "Started working?" or a break hint |

Clicking it opens the menu:

- **Status lines** at the top: "Working since 10:12 (0:42)", "Next break hint about 11:05", or "On a break since
  10:51", or "Not in a work session" and how long you have been in work apps. A line about the phone appears once a
  phone has been paired.
- **Start work session / Stop work session.**
- **On a break / Back from the break.**
- **Snooze the hint 20 min**, **OK, no break now** (while a hint is waiting).
- **Yes, a work session / Not work** (while it asks), or **Not work** to undo a session it started by itself.
- **Settings** (below), **Open data folder**, **Pair phone…**, **Quit** (ends a running session first).

## Settings

In the menu, under **Settings**:

| Setting | Choices | Default |
|---|---|---|
| Notifications | on / off. Off: nothing pops up; questions and hints wait in the menu and the icon shows **!** | on |
| Start a work session by itself | **Off**: only when you press Start. **Ask me first**: after 5 minutes in work apps a notification asks "Started working?" (Yes / Not work). **Automatic when sure**: after 12 clear minutes in work apps it starts by itself and says so quietly, with a **Not work** button | Ask me first |
| End the session after this long away | 30 min / 1 hour / Never | 30 min |
| Start at login | on / off | off |

**More settings (opens the file)…** opens `~/.config/eeg_tracker/tray.json`; the tray picks up changes within a
minute. The other numbers there: `ask_after_min` (5), `auto_after_min` (12), `auto_max_away_min` (3: how much time in
other apps the 12 clear minutes may hold), `ask_again_min` (30: no new question this long after "Not work"),
`hint_threshold_min` (60, from 50 to 90), `quiet` (`23:00-08:00`, or `off`), `max_hints_per_day` (4). A wrong value
is ignored (its default is used) and the tray says so when started from a terminal.

## How it decides

- **Work apps** are the same as for the focus sessions (`scripts/aw_focus.py`): terminals, code editors, Claude and
  ChatGPT windows, and browser pages about documentation or code; writing apps (office, notes, PDFs) are a second
  kind. Other browsing, chat and video are not work.
- **Minutes in work apps** are clock minutes from when that work began, less the time you switched to other apps.
  Short switches (3 minutes or less in total between two stretches, like a quick chat reply) do not end it; a longer
  one starts the count again. A pause at the keyboard under 5 minutes counts (reading, thinking, waiting for a
  program); 5 minutes away is a break and starts the count again.
- **Ask me first** asks once per stretch of work, only while you are in a work app. "Not work" is remembered for that
  stretch, and nothing is asked for 30 minutes after it. A question nobody answers is dropped at your next break.
- **Automatic when sure** waits for 12 minutes in work apps with at most 3 minutes elsewhere among them. Replayed
  over the owner's last three days (2026-11-17 to 19): Ask me first would have asked 7 times, Automatic would have
  started 4 sessions by itself. Counting only the minutes with typing or the mouse would have started none: much of
  the work is short pauses (waiting for an assistant), so clock minutes are used.
- A session started by a "Yes" or by itself begins **when that work began**, not when it was noticed.
- **Breaks**: 5 minutes or more away from the keyboard and mouse is a break by itself; **On a break** starts one at
  once, and it ends at **Back**, or by itself when you come back after 5 or more minutes away. Away **30 minutes or
  more** ends the session at the moment you left (a setting).

## Break hints

The rules of [break hints](break-hints.md), shared with `scripts/break_hints.py` (the same code), only while a session
runs: a hint after 60 minutes of active time since your last break; each hint that no break followed adds 15 minutes
for the rest of the day; at most 4 a day (a day runs 04:00 to 04:00), at least 45 minutes apart; none from 23:00 to
08:00. The notification has **Snooze 20 min**, **On a break** and **OK**. Time in a break you tapped does not count.
The menu always shows when the next one would come if you kept working.

Run either the tray or the `break-hints` service, not both (they share one hint diary, but two programs could both
show one).

## What is saved

- `_local/laptop/work/<start>.work.json`: one file per session (start, end, how it started, breaks, hints and your
  answers, your "work" / "not work" labels, the settings it ran with). Written every 5 minutes and at the end.
- `_local/laptop/work/labels.jsonl`: one line per answer about the detection ("Started working?" Yes / Not work, a
  started session's OK / Not work, or no answer), with the minutes it had counted and the app name, so the rule can be
  checked later against what you said.
- Each hint also goes into break hints' diary, `_local/export/events/<dev>/breaks-YYYY-MM.jsonl`.

The exact fields: [data format](data-format.md#the-laptops-work-sessions-_locallaptopwork). No window titles are ever
written.

## The phone

**Pair phone…** runs `scripts/phone_link.py` in a terminal window (the QR code to scan with the phone; see
[phone-link.md](phone-link.md)), copying the phone's files into the tray's own `_local`. While that window already
runs, the item opens its page `http://127.0.0.1:8771/` with the code, bigger, instead of starting a second copy. It is
greyed out only without a terminal program. After pairing, a status line says whether the phone is connected. When a work session starts or ends here, the tray tells the paired phone (Share on Wi-Fi's `POST /work`, between nights), so the phone's automatic recording can check whether the headband is on and take it as work ("When I put the headband on" in the app). Showing the phone's own work-session drowsiness in this menu is prepared but not connected yet.

## Not done yet

- The phone's drowsiness (when you wear the headband in the phone's Work session) in this menu.
- No "how sharp do you feel" tap here (the phone has one).
- Only tested on this laptop's Cinnamon panel; other desktops need an AppIndicator / StatusNotifier panel.
