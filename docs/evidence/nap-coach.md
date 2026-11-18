# Nap coach

## What it does

Built in the phone app (2026-11-19), not yet tried on a head. You pick a length (20, 30, 45 or 90 minutes) and
tap Lights off. The app watches your sleep live and wakes you with a soft rising sound before deep sleep starts,
or when your length is up, whichever comes first. Afterwards it shows how long you took to fall asleep, the
stages and why it woke you.

## Evidence for this headband: some

Short naps that end before deep sleep leave less grogginess in a small, careful study, and the sleep model reads
deep sleep from these electrodes; but the live stages have only been compared with the same model on one recorded
night, never with a sleep lab, and no study has tested an EEG-timed nap alarm.

## What the research says

- In 24 young people after a short night, a nap of 10 minutes of real sleep helped at once and for up to 2.5
  hours; naps of 20 and 30 minutes of sleep left them groggy (sleep inertia: the slow, foggy minutes after waking)
  at first, and their gains came later and were no larger.
- A review of sleep inertia: grogginess usually clears in 15-30 minutes, full recovery can take an hour; it is
  less likely after naps of 30 minutes or less, but not ruled out. Waking from deep sleep has been linked to worse
  performance in some studies, though newer work is less clear.
- A review of 54 nap studies found naps help memory and alertness (alertness d = 0.61: a medium-to-large effect),
  whatever the nap's length.
- Scoring sleep live, with only the past, costs only 1-2 accuracy points against scoring it afterwards in two
  studies (78.5 % live vs 80.7 % in one; one back-of-the-head channel scored about 5 points below a forehead one).
- Deep-sleep waves are biggest at the front of the head. Every channel of this headband is measured against a
  forehead electrode, so the waves reach all four; on one recorded night the back channels told deep sleep from
  the other stages well.
- Commercial headbands already do this: Dreem found 70 % of deep sleep live; Muse wakes you at "the shallowest
  moment" of your last cycle, with only its own, unpublished data behind it.

## Where the data does not support it

- No study has shown that an EEG-timed nap or alarm makes you less groggy than a plain timer. A bedroom alarm
  with light, sound and temperature did no better than a normal one.
- The live stages are AnySleep, the same sleep model as the morning report, read 2 minutes behind the newest
  data. On one recorded night they agreed with the model's own full-night scoring on about 9 in 10 of the
  30-second stretches; that shows the live version is consistent with the full one, not that either is right on
  this headband.
- Live mistakes lean to calling light sleep "deep", which wakes you a little early; deep sleep missed for a few
  minutes is the rarer mistake.
- Light sleep (N1) is poorly scored everywhere; the "fell asleep" time comes from the alpha rule instead, checked
  on only two recorded sleep onsets so far.
- How fast and how battery-hungry the model is on your phone has not been measured yet.

## How the app uses this

- Its own screen between nights, like the dream catcher; it holds the headband while it runs, and the screen stays
  on, black and dim. Keep the app open.
- Lights off starts three things: the nap's EEG recording (part of that day's sleep report later), the alpha rule
  for "fell asleep" (your first 60 eyes-closed seconds are the starting level), and the live sleep model.
- The live sleep model: every 30 seconds, from 5 minutes in, AnySleep scores the last 60 minutes of signal
  prepared the way a phone can (only the past) and keeps the stage of the stretch 2 minutes back. Two such
  stretches of deep sleep in a row wake you: about 3 minutes into deep sleep, before it settles.
- The length counts from Lights off and always ends the nap, so the nap works on the timer alone if the model is
  too slow (it times every check: two in a row over 15 seconds drop it to 1 of its 3 runs, then to the timer),
  fails, or the signal is lost. The screen and the report say which.
- The wake sound is three soft rising notes, a little louder every 20 seconds until you tap "I'm awake" (5
  minutes at most).
- The report: when you fell asleep, minutes of light, deep and dream sleep, why it woke you, how long you took to
  tap, and how fast the model was.
- Not built: a coffee-nap reminder, a "10 minutes of real sleep" length counted from falling asleep, and the smart
  alarm inside the night recorder.

## Sources

- [Brooks & Lack 2006: which nap length is best](https://pubmed.ncbi.nlm.nih.gov/16796222/)
- [Hilditch & McHill 2019: sleep inertia review](https://www.dovepress.com/sleep-inertia-current-insights-peer-reviewed-fulltext-article-NSS)
- [Leong 2022 nap meta-analysis (summary)](https://medicine.nus.edu.sg/newsletters/issue45/science-of-life/how-naps-can-be-beneficial-for-you)
- [Esparza-Iaizzo: live vs afterwards scoring](https://www.biorxiv.org/content/10.1101/2024.06.12.597764v1.full)
- [GSSC: past-only scoring 1-2 % below](https://pmc.ncbi.nlm.nih.gov/articles/PMC10017438/)
- [Massimini 2004: where deep-sleep waves start](https://pmc.ncbi.nlm.nih.gov/articles/PMC6729597/)
- [Debellemaniere 2018: Dreem's live deep-sleep detection](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5853451/)
- [Muse Smart Wakeup](https://choosemuse.com/blogs/news/smart-wakeup-how-muse-wakes-you-when-your-brain-is-ready)
- [Campanella 2024: a smart bedroom alarm did no better](https://pmc.ncbi.nlm.nih.gov/articles/PMC10969141)
- [AnySleep preprint](https://arxiv.org/html/2512.14461v1)

## Libraries and models

- [AnySleep](https://github.com/dslaborg/AnySleep) (MIT): the sleep model, its three runs exported to ONNX for the
  phone.
- [flutter_onnxruntime](https://pub.dev/packages/flutter_onnxruntime) (MIT) with ONNX Runtime (MIT): runs the model
  on the phone.
- [flutter_soloud](https://github.com/alnitak/flutter_soloud) (MIT): plays the wake sound.
- This project's own live preparation and drift-off detector (MIT); the Python reference is
  `analysis/live_stager.py`.

Checked: 2026-11-19
