# One recording, and what you did inside it

## What it does

The headband records until you press Stop. Sleep, Nap, Work, Meditate and the other sessions are marked inside that one
recording as stretches of time ("Work 14:05-16:30"), on the same signal. A sleep report comes only from a stretch
marked as sleep or a nap.

## Evidence for this headband: some

Marking what you were doing while a device records is the standard way sleep and activity research gets its "ground
truth", and its limits are well known. The numbers used here (60 minutes, 6 hours, 10 minutes) are planning values,
not measured on this headband.

## What the research says

- A recording with no label is hard to use later. In sleep medicine a wrist device is normally read together with a
  sleep diary that gives the bed and rise times; the American Academy of Sleep Medicine's 2018 guideline is the
  standard reference for that use. The device alone cannot tell lying still from sleeping.
- Scoring only the marked window matters. On this headband, the awake evening recording of 2026-11-20, scored as if it
  were a night, came out with 24 minutes "asleep" (DECISIONS 886). So only a stretch marked as sleep is scored.
- The app's own sleep-period rule ignores runs of sleep under 10 minutes as noise. A sleep the app started by itself
  therefore needs 10 minutes asleep to count; this is the app's rule, not a published limit.
- Short naps are real sleep and are reported apart from nights. In a laboratory study of 24 young adults after a short
  night, a 10-minute nap improved sleepiness and performance at once, with some benefit lasting up to 155 minutes; a
  20-minute nap helped from about 35 minutes after waking, for up to 125 minutes; a 30-minute nap first left people
  groggy (Brooks & Lack 2006). A later review by the same group sums up brief naps the same way (Lovato & Lack 2010).

## Where the data does not support it

- People forget to press Stop. A marked stretch is treated as "likely", not "certain".
- "Work" or "Meditate" marked on a recording says what you meant to do, not what your brain did. The detectors' own
  readings (drowsy, eyes closed, talking) are separate and are checked against these marks, not the other way round.
- The 60-minute rule (what was marked ends when the headband has been off for an hour) and the 6-hour rule (the
  recording stops itself) are choices for convenience. No study sets them.
- A session that reads the recording's signal gets the recording's contact reading, taken when the recording started.
  Contact drifts over hours; the headband card's live signal words are the better guide later in the day.

## How the app uses this

- Record starts one recording. An activity pressed while it runs is written into it as a stretch and reads the same
  signal: no new search, no second file, no new contact check. Pressed while nothing records, it starts the recording
  and asks at its end: Stop everything, or Keep recording.
- One activity at a time. While Sleep or a nap is marked, the others wait for Stop sleep.
- Headband off or lost for 60 minutes: what was marked ends at the last moment with a signal; a notice and the Record
  tab offer Undo. After 6 hours without the headband the recording stops itself, with a notice.
- A sleep report is made for a stretch you pressed or confirmed, always. For a stretch the app started by itself only
  with 10 minutes or more asleep; under that it reads "No sleep found" and counts for nothing.
- A nap's report is kept apart from the nights (Sessions, Nap reports).
- A recording that runs for many hours is saved in pieces of 4 hours. The headband is not stopped for it: no sample is
  lost or saved twice where two pieces meet, and every report reads them as one recording. The pieces are there so the
  laptop can check the older ones, and the phone can clear them, while the recording goes on.
- A recording leaves the phone only after the laptop has checked its own copy of it, byte for byte. That holds for the
  awake hours too. More, Your data says how much the recordings take and how much still waits for the laptop.

## Sources

- [Smith et al. 2018, Use of actigraphy for the evaluation of sleep disorders: an AASM clinical practice guideline](https://doi.org/10.5664/jcsm.7230)
- [Brooks & Lack 2006, A brief afternoon nap following nocturnal sleep restriction: which nap duration is most recuperative?](https://doi.org/10.1093/sleep/29.6.831)
- [Lovato & Lack 2010, The effects of napping on cognitive functioning](https://doi.org/10.1016/B978-0-444-53702-7.00009-9)

## Libraries and models

- None of its own. The sleep reports use the sleep model of the sleep-scoring note.

Checked: 2026-11-25 (the three sources exist as cited; the nap numbers are from the 2006 paper's abstract; the
guideline's text was not re-read for this note)
