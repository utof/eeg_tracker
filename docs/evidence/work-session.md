# Work session (drowsiness and break hints)

## What it does

Built in the phone app (2026-11-19), not yet worn at work. You wear the headband while you work. After 4 minutes
that become your awake baseline, the app reads every 5 minutes as alert, getting drowsy or drowsy against it, and
with a soft chime suggests a break after an hour worn, or sooner when drowsiness stays up. It notices breaks and
shows whether drowsiness went down after one.

## Evidence for this headband: some

Heavy eyelids (drowsiness) show at the back of the head and in the eyes, which these electrodes see, and on one
recorded morning the level rose 8 minutes before the sleep model saw the owner doze; but that is one morning, and
"mental fatigue" without sleepiness has no reliable sign at these electrodes (weak).

## What the research says

- In a review of 21 studies of tiring tasks, brain waves grew with fatigue, theta most (g = 1.03) and alpha next
  (g = 0.85), the biggest changes over the top and front of the head, where this headband has no electrodes.
- With eyes open, alpha at the back of the head rises as you get sleepy; with eyes closed it falls instead. Long
  nights awake also raise slow theta at the back of the head, but within a normal day the change is small.
- A study close to this headband (gel electrodes around the ear, short nights and a work day) found no theta change,
  and the EEG did not follow how sleepy people felt or how fast they reacted.
- Blinks get longer and more frequent over long computer work; heavy reading can hold blinking down instead.
- Consumer headbands that try to detect drowsiness reach 31-79 % accuracy in a 2020 review of 46 studies, with
  accuracy defined in ways that cannot be compared.
- Short breaks of up to 10 minutes make people feel a little less tired and more energetic (d = 0.35) but do not
  reliably improve demanding work; a fixed 25/5 timer did no better than breaks people chose themselves.

## Where the data does not support it

- On the owner's recordings (the laptop's `tool/work_check.dart`), theta at O1/O2 and the slow eye power at T3-T4
  fell as he got drowsy, not rose: against the forehead reference both follow eye activity. So the app does not
  use them; it uses eyes-open alpha and how still the eyes are (fewer blinks and glances).
- Still eyes can also mean deep focus. Still eyes alone never raise the level above alert; alpha must rise too.
- Tested on one morning only: an hour with eyes open after a short, restless night, where the owner then fell
  asleep. The level read alert until 08:42, getting drowsy from 08:43 and drowsy from 08:48, and a drowsy hint would
  have come at 08:47, 9 minutes before the sleep model saw him doze; 2 hours awake in bed earlier gave no drowsy
  reading. Working days, coffee, talking and other people are untested.
- With eyes closed (resting, or dozing at the desk) alpha falls as you drift off, so the level cannot follow it;
  the screen says "Eyes closed" instead, and 3 minutes of it in 6 bring a hint.
- If your first 4 minutes were not your usual awake work (tests, talking, already drowsy), every later reading is
  off: with the morning's baseline taken during eye tests the level only reached "getting drowsy".
- Taking the headband off and putting it back can shift the signal; the baseline stays the session's first minutes.
- "Mental fatigue" and "focus" are not measured: no study links these electrodes to either during real work.

## How the app uses this

- Every 30 seconds: alpha (8-12 Hz) at O1/O2 from clean seconds only (no muscle, talking, chewing, movement, blink
  or hole), and blinks plus sideways eye movements per 30 seconds; under 10 clean seconds the half minute is not
  read.
- Your baseline: after 1 minute of settling in, the medians of the next 3 minutes. The index is the mean of alpha
  against it and eye stillness against it (both on a log2 scale); the level is the median of the last 5 minutes
  (needs 3 readable minutes): under 0.5 alert, from 0.5 getting drowsy, from 1.0 drowsy.
- Closed eyes are told apart by alpha 3 times the baseline with no blink and at most one glance in 30 seconds; with
  the optional eyes-closed minute, the line is halfway (geometrically) between your open and closed alpha, at least 2
  times (the owner's closed eyes gave only 2.5 times his open-eye alpha). They are left out of the level.
- Hints, the laptop's break-hint rules: after 60 minutes worn, plus 15 minutes for each hint no break followed; or
  when the level read getting drowsy or more in 8 of the last 12 half minutes. At most 4 a day (04:00 to 04:00),
  45 minutes apart, none 23:00-08:00; Snooze brings one back 20 minutes later. A soft chime and the words on the
  lock-screen card.
- A break: On a break / Back, or the headband off (no usable signal) for 5 minutes. A break of 5 minutes or more
  resets the hour; after it the app compares the level before it with the first 5 minutes after it.
- With each hint an optional one-tap "How sharp do you feel?" (the sharp-hours scale, 1 Foggy to 5 Very sharp),
  kept in the session's file so a later check can ask whether the EEG agrees with you.
- All planning values, set on one morning; your own weeks will tell.

## Sources

- [Tran 2020: EEG and mental fatigue, a meta-analysis of 21 studies](https://researchers.mq.edu.au/en/publications/the-influence-of-mental-fatigue-on-brain-activity-evidence-from-a/)
- [Rusterholz 2010: waking theta and sleep pressure](https://pmc.ncbi.nlm.nih.gov/articles/PMC2849788)
- [van Klaren 2024: around-ear EEG after short nights](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10901434/)
- [Dry EEG in sleep-restricted trainees: theta and alpha rise](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11953059/)
- [Blinks over prolonged computer work (Sci Rep 2018)](https://www.nature.com/articles/s41598-018-31577-1.pdf)
- [LaRocco 2020: drowsiness detection with consumer EEG, 46 studies](https://pmc.ncbi.nlm.nih.gov/articles/PMC7593569)
- [Albulescu 2022: micro-breaks, a meta-analysis](https://doaj.org/article/c6f37b6ba159469296b2cb968b65505f)
- [Smits 2025: Pomodoro against self-chosen breaks](https://pmc.ncbi.nlm.nih.gov/articles/PMC12292963/)

## Libraries and models

- This project's own detectors (`app/lib/detectors/`, MIT) and drowsiness rules (`app/lib/work/`, MIT);
  flutter_soloud (MIT) for the chime; Android's foreground service for the locked phone.

Checked: 2026-11-19
