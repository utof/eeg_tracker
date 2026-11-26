# Focus sessions

## What it does

A laptop program counts the runs of related work that last 35 minutes or more, from the activity log of
ActivityWatch (which window was in front and whether you were at the keyboard). It writes the count per day and per
2-hour block of the clock, and one line per session, beside your sharp-hours answers. It does not use the headband.

## Evidence for this headband: some

One large company showed that counting such sessions from logs agreed with what its engineers wrote in diaries; nobody
has checked it for ActivityWatch or for one person, so it is a count to look at beside your ratings, not a score.

## What the research says

- Google (Brown 2023) counted a stretch as focused only while related actions stayed together for about 35-60
  minutes; a quick related interruption, such as a chat reply while coding, did not break it.
- Against the diaries of 51 engineers (97 diary days) a 60-minute window agreed best (agreement 0.71 on a scale
  where 1 is perfect); a 35-minute window was close.
- Rules that sound sensible did worse: "many events" scored 0.40 and "long sessions over 88 minutes" 0.17.
- Across a survey of 13,383 engineers, the number of focus sessions predicted how often they said they reached
  high focus; the total hours in focus did not.
- The same log pattern was called flow on one day and not flow on another, depending on how the engineer felt about
  the result, so the authors measured focus and gave up on flow.
- Microsoft (Beller 2020): the time developers spent in each app explained only about 9% of how they rated their day
  (coding time alone 7%). Activity logs say little about how a day went.

## Where the data does not support it

- No study checks focus counted from ActivityWatch against how people feel or what they get done. The Google result
  is one company's internal tools, with a learned model that decides which actions belong together.
- Here "related" is a plain word list (terminals, editors, AI-assistant windows, documentation and code pages,
  and a second family of writing and reading apps). Switching between unrelated projects inside one editor is missed.
- The count moves a lot when the allowed switch or the minimum length changes, so numbers are only comparable under
  the same rule; every line of the file names the rule it used.
- A log cannot tell focus from flow, from rote work, or from a window left open while you read something else.
- A day with under 35 active minutes on the laptop has no line: "no data" is not "no sessions".
- Feeling can disagree with doing: a block with more sessions is not a sharper block.

## How the app uses this

- `scripts/aw_focus.py` reads ActivityWatch on this laptop; nothing leaves it. A session is 35 minutes or more of
  active time in one family of windows; an away-from-keyboard gap of 5 minutes or more is a real break (shorter gaps
  pause the clock); up to 3 minutes away from the family in total between two stretches is allowed; a longer run is
  still one session.
- A session belongs to the day (04:00 to 04:00) and the 2-hour block it started in. It is counted, never summed
  into hours.
- Window titles are read in memory only, to tell documentation from other browsing, and are never written. The files
  hold the app's name, times and counts.
- The counts go to `phone/sharp-hours/focus-YYYY-MM.jsonl`, one line a day, beside the ratings. The data book keeps
  one row per session (`focus.tsv`) and the day's count (`days.tsv`). `aw_focus.py --show` puts the sessions, the
  ratings and the reaction tests side by side for each 2-hour block.
- It is seen together, not tested. Look for a pattern only after about 60 ratings and several weeks of both.

## Sources

- [Using Logs Data to Identify When Software Engineers Experience Flow or Focused Work (Brown 2023)](https://arxiv.org/abs/2304.04711)
- [Mind the Gap: automatically measured and self-reported productivity (Beller 2020)](https://arxiv.org/abs/2012.07428)
- [ActivityWatch releases](https://github.com/ActivityWatch/activitywatch/releases)

## Libraries and models

- [ActivityWatch](https://github.com/ActivityWatch/activitywatch/releases) (MPL-2.0): logs which window is in front and
  whether you are at the keyboard.
- Python's standard library; no model.

Checked: 2026-11-26
