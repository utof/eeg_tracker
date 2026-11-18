# Break hints

## What it does

A small laptop program that suggests a short break after about an hour of continuous keyboard and mouse activity.
It reads ActivityWatch's activity log; it does not use the headband.

## Evidence for this headband: some

Short breaks reliably lift energy and lower tiredness a little, but no brain-based break detector has independent
proof, so the hints come from activity time only.

## What the research says

- Short breaks raise vigour and cut tiredness (small effects: d about 0.35, an effect size where 0.2
  is small and 0.5 medium) but do not reliably improve
  performance on hard work.
- A fixed 25-minutes-on, 5-off timer did no better than breaks people chose themselves in a 2025 trial, and
  tiredness rose faster under it.
- No company has independent proof for a brain-based break prompt; the best-known one has only internal data,
  and reviewers called its prompts "nagging".
- Computer activity logs explain only about 9% of how developers rated their day; mood explained 12% of
  productivity ratings and the time of day under 1%.
- Counting focus sessions (runs of related work of about 35-60 minutes) tracked how often engineers felt
  focused; total hours did not.

## Where the data does not support it

- The hints do not know how tired you are; time at the keyboard is only a stand-in.
- These four electrodes cannot give a "focus %" while coding: mental effort shows at the front and top of the
  head, and even research-grade electrodes around the ear saw only weak links.
- The popular "52/17" rule is a blog statistic that changed when it was rerun.
- The 60-minute start, the 4-a-day cap and the back-off are sensible choices, not values from research.

## How the app uses this

- Every minute it reads ActivityWatch's away-from-keyboard data. Gaps under 3 min count as work (reading,
  thinking); 3-5 min gaps pause the count; 5 min or more away resets it (that was a break).
- After 60 min of work: one quiet notification with "Snooze 20 min" and "OK".
- At most 4 a day (a day runs 04:00 to 04:00), at least 45 min apart; each hint that did not lead to a break adds
  15 min for the rest of the day; nothing between 23:00 and 08:00.
- Every hint and what followed is saved on your computer for later statistics. Nothing leaves the laptop.
- Later stages, in order: your own quick ratings, then typing rhythm (timing only, never which key), then a
  drowsiness trend from the headband.

## Sources

- [Micro-break meta-analysis (Albulescu 2022)](https://doaj.org/article/c6f37b6ba159469296b2cb968b65505f)
- [Pomodoro vs self-chosen breaks (Smits 2025)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12292963/)
- [Android Central on Neurable's prompts](https://www.androidcentral.com/accessories/headphones/neurable-mw75-neuro-brain-computer)
- [Developer productivity telemetry (Beller 2020)](https://arxiv.org/abs/2012.07428)
- [Time of day vs productivity ratings (Girardi 2021)](https://aserebre.win.tue.nl/TSE2021.pdf)
- [Focus sessions (Brown 2023)](https://arxiv.org/abs/2304.04711)
- [Code effort sits at the front of the head (Medeiros 2021)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8037053)
- [Around-ear EEG and flow (Knierim, CHI 2025)](https://publikationen.bibliothek.kit.edu/1000183587)

## Libraries and models

- [ActivityWatch](https://github.com/ActivityWatch/activitywatch/releases) (MPL-2.0): logs keyboard and mouse
  activity on the laptop.
- Python's standard library and the desktop's `notify-send`; no model.

Checked: 2026-11-18
