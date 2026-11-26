# Quick checks

## What it does

Soon after the headband thinks you slept or walked, the app asks: "19:08-21:14. The headband thinks you walked. Did
you?" You tap "I walked", "I did not walk" or "Not sure". Until you answer, it is only a guess. A Yes or a No
becomes a fact the app's detectors are checked against. Why it asks in these words, this seldom, and sometimes
without showing its guess is in the note "How the app asks".

## Evidence for this headband: some

Asking soon and showing the app's own guess with its times is well supported for activities. How well it works on
this headband's guesses is not known yet: that is exactly what your answers will show.

## What the research says

- People forget what they did within hours. In a 2-week study of 11 people, pressing a button at the moment missed
  41-49 % of activities; a diary corrected with a view of the sensor data missed under 8 % and had accurate start and
  end times. Confirming a guess with its times is the same idea, one tap at a time.
- Memory is freshest right after the event, and a method that takes that fading into account when choosing what to
  ask did 13.5 % better than one that only asks about what the detector is least sure of.
- Questions sent at a natural pause (a walk just ended) felt 33 % less of a burden in a 16-day field study than
  questions at random moments.
- A phone that is already in use is the best moment: in a year-long study of 246 people, a question was more than
  three times as likely to be answered when the screen was on.
- More questions a day do not make people skip more, but they make answers more careless, and careless answers
  cannot be seen in the counts. So few questions, and "Not sure" always allowed.
- People are not perfect either: asked again about their own earlier answer, students changed it about 1 time in 4.

## Where the data does not support it

- None of these studies used an EEG headband's sleep or walking guesses. The numbers are about phones and watches.
- A plain Yes does not confirm the times. If you slept 16:10-17:30 and the app says 15:59-17:49, tap "Yes, but the
  times are off" and move the ends; otherwise the times stay marked as the headband's guess.
- Seeing the app's guess can pull your answer toward it. When you do not remember, "Not sure" is the right answer.
- Only what a detector found is asked about. What it missed completely needs your own tag in the Archive.

## How the app uses this

- **Yes**: a label that it happened. **No**: a label that it did not happen, which shows where a detector gives
  false alarms; just as useful. **Not sure**: kept as its own answer, not as a fact, and the app never asks about
  that stretch again.
- At most 4 questions at a time and 2 notifications a day (More, Quick checks), 10 minutes after the stretch ended,
  never in the quiet hours (your usual sleep, or 22:00-08:00) and never while a recording runs with the screen off.
  The card in the app shows the same questions whenever you open it.
- When more than 4 wait: the newest and the ones the detector is least sure of. Nothing older than two days, nothing
  twice, and nothing you already tagged yourself.
- Works without a network. Answers are files on the phone and reach the laptop with the normal copy, where each
  detector is scored against them.
- You can add a few words to an answer; they are kept exactly as you write them.

## Sources

- [Hoelzemann and Van Laerhoven 2024, annotation methods compared](https://arxiv.org/html/2305.08752v3)
- [Esna Ashari and others 2020, memory-aware active learning](https://par.nsf.gov/biblio/10209062)
- [Okoshi and others 2015, notifications at breakpoints](https://julian-ramos.github.io/papers/Okoshi2015.pdf)
- [Prochnow and others 2025, the year-long TIME study](https://mhealth.jmir.org/2025/1/e67117)
- [Ulitzsch and others 2025, careless answers and question frequency](https://www.leibniz-ipn.de/en/research/publications/investigating-the-effect-of-experience-sampling-study-design-on-careless-and-insufficient-effort-responding-identified-with-a-screen-time-based-mixture-model)
- [Bontempelli and others 2025, people revising their own labels](https://arxiv.org/html/2510.23635v1)

The numbers are from the project's research note of 2026-11-20 (labelling the day), which read these pages.

## Libraries and models

- No model and no new library: the questions come from the app's own sleep scoring and walking detector, and the
  notification uses Android's own.

Checked: 2026-11-20
