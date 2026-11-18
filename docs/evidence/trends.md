# Trends (sleep pressure, "your usual", forecasts)

## What it does

A page in the phone app with a few numbers per day (sleep, jaw muscle bursts in the night, morning sleepiness and
reaction time, mood, tension, the alpha numbers, practice, coffee and alcohol), each shown next to yesterday's and your usual, plus a
sleep-pressure curve built from your sleep log. Forecasts stay hidden until they prove useful for you.

## Evidence for this headband: some

Sleep pressure from your sleep log is a decades-old, well-tested model, and your usual range is plain counting;
an EEG sleep-pressure number and next-day forecasts are weak, and no study shows the EEG improves forecasts.

## What the research says

- The two-process sleep model (pressure builds while you are awake and drains in sleep, plus the body clock) is
  behind the US Army's alertness model, and sleep-tracker data are accurate enough as its input.
- Its numbers: pressure builds on a time scale of about 18-21 hours awake (people range 14-26) and drains on a
  scale of 2-4 hours of sleep; caffeine's half-life is about 5 hours (1.5-9.5 between people).
- In the best head-to-head test of daily mood forecasts (145 people), the best model beat "same as last time" by
  only 5-8%, not significantly, and several did worse.
- Showing a forecast can change the day: people falsely told they had slept badly felt less alert and more tired
  by evening. A range written in words was read right by 94% of people; the same range as a graphic was misread
  by 36%.
- Late coffee steals sleep: 45 minutes on average; 400 mg six hours before bed cut measured sleep by 1.1-1.2 hours
  while diaries noticed only 41 minutes.
- Wearable "readiness" scores are a warning: 14 composite scores from 10 companies, none with a published formula.

## Where the data does not support it

- An EEG sleep-pressure meter: after a normal day the change at the back of the head is too small, and the closest
  wearable tests found no change and no link to how sleepy people felt.
- EEG inside forecasts: no study found that sleep or morning EEG adds anything.
- Famous "tomorrow's mood" accuracies of 79-82% do not carry over: they threw out the in-between days and
  had no simple baseline to beat.
- No EEG sign has been shown to warn one person ahead of illness, burnout or low mood.

## How the app uses this

- "Your usual": the middle value of your last 28 days with a value, shown from 7 days. A day runs from 04:00 to
  04:00; a night counts for the day you woke from it. No single brain score, no red or green health colours.
- Arrows from 14 days, and only when a day is beyond your normal day-to-day spread (twice a robust spread) and
  beyond the smallest change that matters: 1 hour of sleep, 2 points on a rating, 10 % in reaction time, a quarter
  of your usual in jaw muscle bursts (a planning value). Each arrow says in words what it means, with your normal
  range.
- Jaw muscle bursts are the sleep report's count an hour asleep: a trend to compare your nights, not a test for
  teeth grinding (the jaw note says why).
- "Same as yesterday": every number shows yesterday's beside it.
- Sleep pressure comes from your sleep log (sleep periods of the phone's sleep reports; builds with an 18-hour
  time scale while awake, drains with a 4-hour one asleep), labelled as an estimate. Your body clock and coffee
  are not in it, and it stops where a night is missing. An EEG-adjusted number appears only if it beats the
  log-only one on days it has not seen.
- One forecast, tomorrow morning's sleepiness (half yesterday, half your 28-day mean), stays hidden until 60 days
  of ratings exist and it beats "same as yesterday" by at least 5 % over the last 60 days; then it is shown in
  words, with a range and its track record, and only after that morning's rating.
- Planned: weeks of recovery after an illness kept out of "your usual".

## Sources

- [Alertness model with sleep trackers as input (Reifman 2024)](https://pubmed.ncbi.nlm.nih.gov/37947051/)
- [US Army model with caffeine (Ramakrishnan 2016)](https://pubmed.ncbi.nlm.nih.gov/27397562/)
- [Caffeine half-life (IOM 2001)](https://www.ncbi.nlm.nih.gov/books/NBK223808/)
- [Fechtelpeter 2025: 7 models vs "same as last time"](https://europepmc.org/article/PMC/PMC12827976)
- [Gavriloff 2018: false "you slept badly" feedback](https://pubmed.ncbi.nlm.nih.gov/29989248/)
- [Joslyn & Savelli 2021: forecasts in words](https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2020.590232/full)
- [Caffeine and sleep meta-analysis (Gardiner 2023)](https://pubmed.ncbi.nlm.nih.gov/36870101/)
- [Caffeine 6 hours before bed (Drake 2013)](https://pmc.ncbi.nlm.nih.gov/articles/PMC3805807/)
- [Wearable readiness scores review (Doherty 2025)](https://www.degruyterbrill.com/document/doi/10.1515/teb-2025-0001/html)
- [Around-ear EEG after short sleep (van Klaren 2024)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10901434/)
- [Home EEG vs mood (Boon 2025)](https://europepmc.org/article/PMC/PMC11744226)
- [SNAPSHOT mood forecasts (Taylor 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7266106)
- [Burnout EEG review (Chmiel & Malinowska 2025)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12347992)

## Libraries and models

- [statsmodels UnobservedComponents](https://www.statsmodels.org/stable/generated/statsmodels.tsa.statespace.structural.UnobservedComponents.html)
  (BSD-3): the main forecast model (a slowly drifting personal level plus a weekday effect).
- [Chronos-2](https://github.com/amazon-science/chronos-forecasting) (Apache-2.0): a pretrained forecaster, only as
  an extra competitor.
- The sleep-pressure model and the forecast are this project's own code (MIT); the statsmodels and Chronos lines
  above are for later laptop comparisons, not in the app.

Checked: 2026-11-18
