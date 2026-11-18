# Break hints (stage 0: no headband)

A small background script that now and then suggests a short break while you work at the PC. It does not
know how tired you are: it only knows how long you have been at the keyboard and mouse, from
[ActivityWatch](https://activitywatch.net), which already logs that on the laptop.

## What the evidence says, and what that means here

Short breaks reliably make people feel a bit more energetic and less tired (small effects). They do not
reliably improve performance on demanding work. A 2025 trial found a fixed 25/5 timer did no better than
breaks people chose themselves. So the hints are soft, rare and easy to ignore, and they never scold.

## What it does

- Every minute it reads ActivityWatch's AFK data (`aw-watcher-afk_<hostname>`).
- It counts **active time**: time you were not AFK. AFK gaps under 3 min count as active (reading, thinking);
  gaps of 3-5 min pause the count; **5 min or more away resets it** (that was a break).
- After **60 min** active it shows one quiet notification: *"You've been at it for 75 min. A few minutes away
  from the screen?"* with **Snooze 20 min** and **OK** buttons (plain text if your `notify-send` has no buttons).
- Rules:
  - at most **4 hints a day** (a day runs 04:00 to 04:00, so a late night does not reset the count);
  - at least **45 min** between hints;
  - each hint that did not lead to a break adds **15 min** to the threshold for the rest of the day
    (60, then 75, then 90 ...): if you are ignoring it, it backs off;
  - **Snooze** brings back one hint 20 min later (only if you are still working; a break cancels it);
  - nothing in **quiet hours** (23:00-08:00);
  - a 5+ min break that starts within 30 min of a hint is logged as "break taken".
- Every hint and what followed is saved as a `break_hint` event in
  `_local/export/events/<dev>/breaks-YYYY-MM.jsonl` ([data format](data-format.md#break_hint)), so later
  statistics can ask whether breaks change anything for you. Nothing leaves the laptop.

## Try it

```bash
python3 scripts/break_hints.py --test-notify   # one sample notification; prints which button you pressed
python3 scripts/break_hints.py --dry-run       # what would have happened over the last 24 h of your data
python3 scripts/break_hints.py                 # run in the foreground (Ctrl+C to stop)
```

Needs Python 3.10+ (standard library only), ActivityWatch running, and `notify-send` (package
`libnotify-bin`; version 0.8 or later has the buttons).

## Run it all the time (systemd user service)

```bash
mkdir -p ~/.config/systemd/user
cp scripts/break-hints.service ~/.config/systemd/user/
# if the repo is not at ~/eeg_tracker, fix the two paths in that copy
systemctl --user daemon-reload
systemctl --user enable --now break-hints
journalctl --user -u break-hints -f            # see what it decides
```

Stop: `systemctl --user disable --now break-hints`.

## Settings

Add flags to the `ExecStart=` line in `~/.config/systemd/user/break-hints.service`, then
`systemctl --user daemon-reload && systemctl --user restart break-hints`.

| Flag | Default | Meaning |
|---|---|---|
| `--threshold` | 60 | active minutes before the first hint of the day (50-90) |
| `--quiet` | `23:00-08:00` | no hints in these hours; `off` for none |
| `--max-per-day` | 4 | hints per day |
| `--root` | `<repo>/_local/export` | where the events go |

The other numbers (45 min spacing, +15 back-off, 3 / 5 min gaps, 30 min break window, 20 min snooze) are in
`Config` at the top of `scripts/break_hints.py`.

## Later stages

1. **One-tap sleepiness rating** in the hint (how sleepy are you, 1-9, the Karolinska scale): your own
   answer beside the data, and a way to learn your own threshold.
2. **Typing rhythm** from ActivityWatch or a keyboard logger that stores only timing: slower, more uneven
   typing may mark fatigue for you. Personal pattern only; not validated.
3. **EEG drowsiness trend** from the headband while you work: rising slow waves and alpha at O1/O2 after a
   per-person calibration. No validated EEG break detector exists for these 4 dry electrodes, so this would
   be a trend you can look at, not a verdict.
