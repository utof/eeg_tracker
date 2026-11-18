# Morning check-in

## What it does

About 5 minutes each morning: a contact check, 2 minutes with eyes closed, 2 minutes looking at a dot, then
three quick ratings (sleepiness 1-9, mood, tension). It measures your alpha rhythm (the 8-12 Hz wave at the back
of the head that grows when you close your eyes) and compares it only with your own earlier mornings.

## Evidence for this headband: strong

Eyes-closed alpha at the back of the head is one of the most reliable EEG measures and this headband's back
electrodes match lab electrodes; what a day-to-day change means for your day is less certain.

## What the research says

- A dry headband with exactly this layout matched lab gel electrodes for back-of-head alpha: correlation 0.90.
- Averaged over minutes, alpha strength and alpha speed (the exact rate of your alpha peak) are very repeatable:
  ICC about 0.84-0.87 over 5 years in lab caps (ICC: a repeatability score where 1 is perfect).
- From second to second, alpha speed jumps 1-2 Hz, so only minutes of eyes-closed data give a usable value.
- Ratios (such as eyes-closed against eyes-open alpha) repeat better month to month than single measures.
- Habits move these numbers: caffeine lowers alpha and speeds the peak, binge drinking slowed alpha speed by about
  0.7 Hz, and sleeping pills and antidepressants lower alpha strength.
- The 1-9 sleepiness rating (Karolinska scale) is the standard short rating; EEG signs of sleepiness follow it on
  average, and the rating is about as sensitive as the EEG.

## Where the data does not support it

- Nobody has published how repeatable these numbers are on a dry headband like this one; all the figures above
  come from wet lab caps.
- "Alpha slows when you are tired" is not supported: in 77 teenagers alpha speed rose after short nights. So the
  check-in does not read tiredness from alpha speed.
- About one person in ten shows little alpha when closing the eyes; for them these numbers carry less.
- The spectrum slope (how fast power falls with frequency) is less repeatable (ICC 0.54-0.62).
- Three minutes with eyes closed is better supported than two; the length is still open.

## How the app uses this

- Contact check, then 2 min eyes closed, then 2 min eyes open on a dot, with soft tones at each change; then the
  ratings. Each change is marked in the recording. The phone app runs the same routine itself, between nights
  (the main screen's Morning section), and gives the same numbers as the laptop on the same signal.
- Only clean data counts: the signal is cut into 2-second pieces, and a piece is dropped if it swings over 150 µV,
  is flat, or is far noisier than the rest of the phase. The first 3 s and last 1 s of each phase are skipped,
  and each channel needs 20 s of clean data per phase.
- Alpha speed is the centre of the power that rises above the smooth background curve in 7-14 Hz, eyes closed;
  it stays empty when there is no clear peak.
- The laptop compares each morning with the middle value and range of your last 14 check-ins: "within / above /
  below your range". A note says so until 5 exist. Never a score, never a norm from other people.
- On the phone the ratings are followed by quick taps: cups of coffee or strong tea the day before (and whether one
  came in the 8 hours before sleep), drinks of alcohol, caffeine before the check-in; then an optional 1-minute
  reaction test (the median of your taps). The numbers go to the trends page, compared with your own usual.
- Planned: a medication tap, and a fresh baseline when medication or hardware changes.
- The laptop page also has a 2-minute setup test (blinks, glances, jaw clenches); see "What the electrodes see".

## Sources

- [Mikhaylov 2024: dry headband vs gel, same layout](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)
- [Cerebral Cortex 2026: 5-year repeatability](https://pmc.ncbi.nlm.nih.gov/articles/PMC13456336/)
- [eNeuro 2025: alpha speed jumps second to second](https://www.eneuro.org/lookup/doi/10.1523/ENEURO.0118-25.2025)
- [Test-retest 2025: ratios repeat better](https://pmc.ncbi.nlm.nih.gov/articles/PMC12589806/)
- [Caffeine and alpha (Barry 2005)](https://data.zhenzhi.com/details/1/868660341)
- [Binge drinking and alpha speed](https://pmc.ncbi.nlm.nih.gov/articles/PMC5995627)
- [Caffeine and alpha speed (2023)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10049386/)
- [Sleepiness ratings vs EEG (Kaida 2006)](https://data.zhenzhi.com/details/1/905755554)
- [Campbell 2022: alpha speed rose after short nights](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9154075/)
- [Alpha basics (StatPearls)](https://www.ncbi.nlm.nih.gov/books/NBK537023/)
- [Brain Topography 2024: 3 minutes](https://link.springer.com/article/10.1007/s10548-024-01067-x)

## Libraries and models

- [numpy](https://pypi.org/project/numpy/) and [scipy](https://pypi.org/project/scipy/) (BSD-3): the spectra
  and filters in the laptop analysis.
- [pyedflib](https://github.com/holgern/pyedflib/blob/master/LICENSE) (BSD-3): reads the recording.
- No model and no outside library in the page itself.

Checked: 2026-11-18
