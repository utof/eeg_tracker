# Unusual for you

## What it does

In the phone app (not yet run on a phone; the assistant's proposal, on unless you switch it off). It quietly
compares your sleep length and your morning ratings with your own usual. When one of them has been well outside it
on 2 days in a row, the Trends page says so in one plain sentence ("Your sleep has been 2 h shorter than usual for 2
nights"). It says your numbers moved, not why.

## Evidence for this headband: some

Simple personal rules like this caught most infections in smartwatch data; the same design on sleep length and
ratings has not been tested by anyone, and no EEG number has been shown to warn of anything.

## What the research says

- The best-tested early-warning system is a simple rule. Stanford's NightSignal compared each night's resting heart
  rate with your running median and raised an alert after 2 nights in a row above it. It caught 80 % of 84 COVID
  cases, a median of 3 days before symptoms, and beat a change detector (72 %) and an hourly anomaly detector
  (69 %).
- False alarms are the main cost: about 12 % of healthy days turned red, mostly after poor sleep, stress, alcohol,
  hard exercise, travel or a vaccine. Still, 73 % of people found the rate acceptable and could usually name the
  cause.
- A per-day rule that is right 95 % of the time still flagged a third of people at least once in 6 days. Using
  the nights from 3 weeks to 1 week back as "your usual" keeps a slowly starting change from dragging it along.
- Sleep behaviour carries the signal: colds and overreaching cut sleep by about 20-40 minutes, and before a
  relapse of depression sleep got less regular with more waking at night.
- After an illness the body's numbers can stay off for one to two weeks (longer after a hard COVID), so those weeks
  should not count toward "your usual".
- Fancier change detectors often do no better than "never alarm" on default settings; agreement between several
  simple signals helped more.

## Where the data does not support it

- EEG: no EEG number has been shown to warn one person of illness, stress, burnout or low mood. Inflammation
  raised the alpha frequency in one study while sleepiness lowers it, so a direction means nothing; a consumer EEG
  headband's sleep numbers did not follow daily mood.
- Sleep length and ratings: no study has tested this rule on them. The numbers below come from made-up people, not
  from you.
- Small changes are missed: a cold's 20-40 minutes are inside most people's normal night-to-night swing.
- Most cards will not be illness. A long average gap between false alarms still allows early ones.
- Health alerts can feed worry in some people; that is why there is no notification and the switch is one tap away.

## How the app uses this

- The numbers: sleep length (from the headband's sleep model), sleepiness, mood, tension and the reaction test.
  Sleep length counts both ways; the others only the way that means strain (sleepier, lower mood, more tense,
  slower). Steps are not recorded by the app.
- Your usual for this card: the middle value of the 28 days with a value that end a week before (Whoop's lagged
  window), needing 14 of them. "Outside it" is the Trends page's arrow rule: at least twice your normal day-to-day
  spread and at least the smallest change that matters (1 hour of sleep, 2 rating points, 10 % in reaction time).
- A card: one number outside your usual on 2 days in a row (NightSignal's rule); one missing day in between is
  bridged. It stays until a number comes back, then says "Back in your usual range" for 3 days.
- Silent for the first 28 days with a number: it only notes what it would have said, and later tells you how often
  that was. A break of more than 14 days starts your usual again.
- The headband's own numbers (alpha speed, alpha strength, the eyes-closed rise, jaw muscle bursts) are judged
  both ways and written down, but never make a card: on made-up people they almost tripled the false cards (1.9 a
  month instead of 0.7) and no study shows they warn of anything.
- Tested on 200 made-up people over a year each (planning values for their day-to-day wobble): 0.7 false cards a
  month (one every 6 weeks or so); 7 in 10 would see at least one false card in their first 8 weeks. Found: a
  cold-like week (sleep 40 minutes shorter, 2 points sleepier, mood 1 point lower) in 69 %, a week of low mood in
  74 %, 4 nights of 2 hours less sleep in 57 %, of 1 hour less in 20 %; usually 2 days after it began. A stricter
  rule (2 numbers together) almost never spoke, and missed nearly everything.
- "What might explain it?" chips (late night, alcohol, travel, stress, hard exercise, vaccine, feeling ill, not
  sure) are for your own record. "Feeling ill" pauses the card for 2 weeks and keeps those days out of your usual;
  Resume now ends the pause.
- Only on the Trends page and as one line on the main screen while there is a card; never a notification, never
  during a night. Every card says it is seen together, not tested, and not a diagnosis.

## Sources

- [NightSignal: real-time alerts from smartwatch heart rate (Alavi 2022)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8799466/)
- [Whoop: breathing rate and a lagged baseline (Miller 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7728254/)
- [Numbers stay off after an illness (Levi 2026, news report)](https://telehealth.org/news/smartwatches-detect-incomplete-recovery-days-after-patients-feel-better-study-finds/)
- [Depression relapse and sleep regularity (Tonon 2026)](https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=DOI:10.1001/jamapsychiatry.2025.4453&resultType=core&format=json)
- [Change detectors vs "never alarm" (van den Burg & Williams)](https://arxiv.org/abs/2003.06222)
- [Voting across detectors (Mozilla 2026)](https://arxiv.org/abs/2606.18377)
- [Long gaps between false alarms still allow early ones (2026)](https://arxiv.org/abs/2608.12660)
- [Inflammation raised the alpha frequency (van den Boogaard 2010)](https://pmc.ncbi.nlm.nih.gov/articles/PMC2911704)
- [EEG headband sleep vs daily mood (Boon, via a citing paper)](https://www.elsevier.es/en-revista-international-journal-clinical-health-psychology-355-articulo-exploring-bidirectional-within-subject-relationship-between-S169726002500105X)
- [Watch-based burnout prediction was weak (Dei Rossi 2026)](https://www.frontiersin.org/journals/digital-health/articles/10.3389/fdgth.2025.1694666)
- [Wearable alerts and health anxiety (Rosman 2024, news report)](https://news.unchealthcare.org/2024/07/wearable-devices-can-increase-health-anxiety-could-they-adversely-affect-health/)
- [Apple Vitals: two measures outside your range](https://support.apple.com/guide/watch/apd15aa7ed96)
- [Oura Symptom Radar: shifted, not why](https://ouraring.com/blog/symptom-radar/)
- [US FDA general wellness guidance (2026)](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/general-wellness-policy-low-risk-devices)

## Libraries and models

- [NightSignal, wearable-infection](https://github.com/StanfordBioinformatics/wearable-infection) (Apache-2.0):
  its alert rule (a running median, a fixed threshold, 2 nights in a row, one missing night filled in),
  re-implemented with attribution in this project's own code (MIT): `analysis/unusual.py` and its phone port
  `app/lib/unusual/detector.dart`. No library is bundled.

Checked: 2026-11-19
