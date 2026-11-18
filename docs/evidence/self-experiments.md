# Self-experiments (does this habit change that number, for you?)

## What it does

In the phone app (not yet run on a phone). You pick one habit ("no screens in the last hour before bed") and one
number (time asleep, morning sleepiness, reaction time...). The app draws random days for 4 to 8 weeks: on some you
do it, on the others you don't. At the planned end it tells you the difference, with a range, in one sentence.

## Evidence for this headband: some

Random days are the accepted way to learn what causes what in one person, and the test used needs no assumptions;
but you know which kind of day it is, the numbers are noisy, and a few weeks can only show large effects.

## What the research says

- Randomised experiments on one person (alternating or random days or blocks) beat any "seen together" link for
  saying what causes what: when chance picks the days, nothing else can explain the difference.
- Apps that only compare tagged days with untagged days cannot do this. One asks for just 5 days with and 5
  without, another for 3 and 3, and both admit that other things differing on those days distort the result.
- Published one-person trials are often analysed badly: in a review, 83.8 % ignored that one day resembles the
  next, and 99.1 % gave no range for the effect. They are also short: a median of 20 measurements and 3 switches.
- Days needed, as a rough rule from the research notes: about 31 days divided by the squared effect (in units of
  your own day-to-day spread). So about a month for a large effect (one whole spread), about four months for a
  medium one.
- People can finish such experiments when an app sets them up: 15 people completed 12-day food experiments with a
  wizard and reminders, and wanted room for days when life got in the way. Sleep apps have guided people through
  short experiments in the same way.
- When people do not keep to the plan, counting days as they were drawn stays fair; counting them by what was done
  lets the old confusions back in. Statisticians report both.
- A habit worth testing first: late caffeine. In trials it cut sleep by 45 minutes on average, and 400 mg six
  hours before bed cut measured sleep by 1.1 to 1.2 hours while sleep diaries noticed 41 minutes.

## Where the data does not support it

- You are not blinded: you know today's task, and expecting an effect can move ratings (sleepiness, mood,
  tension) by itself. Measured numbers (time asleep, reaction time) are less open to this. One writer who ran
  blinded sleep experiments for years calls an unblinded self-experiment "less than n = 1".
- Four weeks finds only large effects. "Not clear yet" is the most likely answer for a small one, and it does not
  mean "no effect".
- The answer is about you, in these weeks. It says nothing about other people, or about other seasons of your life.
- One experiment can be wrong by chance about 1 time in 20 even when nothing is there. Run it again before you
  rely on it.
- An effect that lasts longer than a day (a habit whose effect carries over) blurs the two kinds of day together and
  makes the difference look smaller than it is.
- The sleep numbers come from a sleep model that is a first guess on this headband; the experiment can only be as
  good as the number it tests.

## How the app uses this

- Trends, then Experiments. One experiment at a time. You choose a question (four ready-made ones, or your own "do"
  against "don't"), ONE number from the trends page, and 4, 6 or 8 weeks. Day 1 is the next day. Nothing can be
  changed after the start.
- The order of days comes from a random secret made on the phone, in shuffled blocks of 4 days (2 of each kind),
  drawn again until every weekday has both kinds. The plan and the SHA-256 fingerprint of the hidden order are
  saved before day 1; the page shows the fingerprint's start and checks at the end that nothing changed.
- Each day the page (and one line on the main screen and after the morning check-in) shows that day's task. The
  days ahead stay hidden. A day runs from 04:00 to 04:00.
- The next day it asks "did you keep to it?". Days you did not keep still count as they were drawn; the same
  difference by what you did is shown beside it, labelled "seen together".
- A task's number is the next day's: the night you wake from and that morning's check-in. A day without the number
  is left out.
- The answer opens the day after the last number. "Look early anyway" asks first and stays marked on the final
  answer; "Stop" keeps the days that are over and is marked too.
- The test: the difference of the two means, compared with the same difference under every order of days the draw
  could have given (all of them up to 300 000, else 50 000 random ones). The range is every size of effect that
  test does not rule out at 5 %.
- The words: "likely real for you" when chance alone would give such a difference in fewer than 1 of 20 draws;
  "little or no effect for you" when the whole range is smaller than what would matter (planning values: 30
  minutes of sleep, 1 point of a rating, 5 % of reaction time, a quarter of the jaw bursts, 0.2 Hz of alpha speed,
  a fifth of alpha strength or the eyes-closed rise); "not clear yet" otherwise; "too few days" under 5 days of
  each kind.
- Only the one chosen number is tested. Every other number is shown as a plain difference under "seen together,
  not tested".

## Sources

- [Liao 2021: review of one-person trials, autocorrelation ignored](https://arxiv.org/html/2112.13991v1)
- [Simulation paper citing Gabler 2011: typical designs](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6955665/)
- [Non-compliance in one-person trials (ISTOP)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12934031/)
- [Daza: person as population](https://arxiv.org/abs/1901.03423)
- [TummyTrials, CHI 2017](https://people.cs.umass.edu/~rkarkar/pubs/conf-chi2017-tummytrials.pdf)
- [SleepBandits, CHI 2020](https://jeffhuang.com/papers/SleepBandits_CHI20.pdf)
- [Whoop: monthly performance assessment](https://www.whoop.com/thelocker/monthly-performance-assessment)
- [Bearable: why correlations can be wrong](https://bearable.app/support/troubleshooting/my-correlations-are-wrong-dont-make-sense/)
- [gwern: Zeo sleep self-experiments](https://gwern.net/Zeo)
- [LessWrong: confirmation bias case study](https://www.lesswrong.com/lw/c5f/case_study_testing_confirmation_bias)
- [Gardiner 2023: caffeine and sleep, pooled](https://pubmed.ncbi.nlm.nih.gov/36870101/)
- [Drake 2013: caffeine 0, 3 or 6 hours before bed](https://pmc.ncbi.nlm.nih.gov/articles/PMC3805807/)

## Libraries and models

- This project's own randomisation, frozen plan and randomisation test (MIT), shared with the replay check.
- [StudyU](https://github.com/studyu-health/studyu) (MIT): an open platform for one-person trials, used as a
  reference for the design; not bundled.

Checked: 2026-11-19
