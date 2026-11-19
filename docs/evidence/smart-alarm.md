# Smart alarm

## What it does

Off by default. Before a night you set a "wake me by" time and a window that ends there (15, 20, 30 or 45
minutes). Inside the window the app wakes you at the first moment your sleep reads as light, dream (REM) or
awake, and not just after deep sleep. If no such moment comes, it wakes you at the set time, like a plain alarm.

## Evidence for this headband: weak

The sleep model can read deep sleep from these electrodes (graded "some" in the nap coach and sleep scoring
notes), but the claim that waking from light sleep leaves you less groggy than a plain alarm is weakly
supported: studies of the sleep stage at waking disagree, and the tests of smart alarms found no gain.

## What the research says

- Sleep inertia is the slow, foggy time after waking. A review found it rarely lasts more than 30 minutes unless
  you are short of sleep, and that waking from deep sleep (slow, large brain waves; stage N3) gives more of it
  than waking from light sleep.
- A newer review is less sure: older studies linked waking from deep sleep to worse performance (one found a 41 %
  drop), several others found no link, and "it is difficult to synthesize a clear conclusion". The worst
  grogginess is felt right away and most clears in 30 minutes, but full recovery takes at least an hour. It is
  worse after too little sleep and when you wake in your body's night.
- After normal 8-hour nights at the usual wake time, the stage people woke from made no measurable difference to
  how groggy they were or how fast it cleared. Most of them woke from dream or light sleep anyway, so the study
  says little about deep sleep; it does suggest that a plain morning alarm seldom lands in it.
- A phone app that tracks movement in bed and promises to wake you from light sleep was tested in a sleep lab on
  20 people. It named the stage correctly 45.9 % of the time. 14 of the 17 people asleep at the alarm were in
  light sleep, but light sleep filled about 60 % of their night, so that was no better than chance.
- Four more phone apps were tested at home on 21 people. Both versions of Sleep Cycle were not reliable even at
  telling sleep from wake, and none of the four could find dream sleep.
- A headband reads brain waves, which a phone on the mattress cannot. Dreem's headband found 70 % of deep sleep
  live, and scoring with only the past costs 1-2 accuracy points against scoring afterwards.
- Muse's headband has a smart wake-up. Its maker reports that across about 6,200 nights, on the nights with
  enough sleep, waking from light sleep went with a better morning mood; and that how long people slept mattered
  far more. This is the maker's own, unpublished data, with no comparison against a plain alarm.

## Where the data does not support it

- No study has shown that a smart alarm makes you less groggy than a plain alarm at the same time. In the one
  trial close to it (29 people, four lab nights), a bedroom system that started its wake-up light when a mattress
  sensor saw light sleep did no better than a beeping alarm on a reaction test, sleepiness or mood, and sleep on
  those nights was slightly more broken.
- A smart alarm wakes you up to a full window early. That is sleep lost, and too little sleep makes grogginess
  worse. Nobody has measured whether the better moment pays for the lost minutes.
- No study has tested an EEG headband alarm of this kind, and no one has checked this headband's stages against a
  sleep lab.
- The live stages are AnySleep, read 2 minutes behind the newest data. In the nap coach work they were compared
  with the model's own full-night scoring on one recorded night; that shows the live version is consistent with
  the full one, not that either is right.
- The drowsy first stage of light sleep (N1) is poorly scored everywhere, and the alarm acts on a single
  30-second stretch, so some wake-ups will come at a moment that was not what the model said.
- The 10-minute wait after deep sleep is this project's own caution. No study sets that number.
- Treat it as a pleasant way to wake up that may help a little, not as a proven fix for groggy mornings.

## How the app uses this

- Before Start on the night screen, switch it on, set "wake me by" (for example 07:30) and the window (30 minutes
  first). The window ends at that time.
- The window's end is also set as a normal phone alarm at Start. It rings even if the phone closed the app in the
  night, the sleep model was too slow or failed, or the headband's signal was lost.
- The headband records all night as always. The live sleep model runs only from 60 minutes before the window
  until it wakes you, to save battery. It is the nap coach's model: every 30 seconds AnySleep scores the last 60
  minutes of signal, prepared with only the past, and keeps the stage of the 30-second stretch 2 minutes back.
- Inside the window it wakes you at the first stretch read as light sleep, dream sleep or awake, but never within
  10 minutes after a stretch read as deep sleep. If no such moment comes, it wakes you at the window's end,
  whatever the stage.
- The sound is the nap coach's three soft rising notes, a little louder every 20 seconds. After 3 minutes without
  "I'm awake", the phone's own alarm sound takes over. "I'm awake" (on the lock screen, the notification or in
  the app) stops it. The recording goes on until you stop the night.
- The morning report says when it woke you, why (light sleep, dream sleep, awake, or the window's end), when you
  tapped "I'm awake", and what the full-night scoring says about that minute.
- If the sleep model causes any trouble (an error, too much time or memory), it switches itself off and the plain
  alarm stays. The recording is never affected.

## Sources

- [Tassi & Muzet 2000: sleep inertia review](https://doi.org/10.1053/smrv.2000.0098)
- [Hilditch & McHill 2019: sleep inertia review](https://www.dovepress.com/sleep-inertia-current-insights-peer-reviewed-fulltext-article-NSS)
- [Jewett 1999: grogginess after normal nights, no effect of stage](https://doi.org/10.1111/j.1365-2869.1999.00128.x)
- [Bhat 2015: a light-sleep alarm app against a sleep lab](https://pmc.ncbi.nlm.nih.gov/articles/PMC4481053)
- [Fino 2020: four phone sleep apps against home sleep recording](https://doi.org/10.1111/jsr.12935)
- [Campanella 2024: a smart bedroom alarm did no better](https://pmc.ncbi.nlm.nih.gov/articles/PMC10969141)
- [Debellemaniere 2018: Dreem's live deep-sleep detection](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5853451/)
- [GSSC: past-only scoring 1-2 % below](https://pmc.ncbi.nlm.nih.gov/articles/PMC10017438/)
- [Muse Smart Wakeup](https://choosemuse.com/blogs/news/smart-wakeup-how-muse-wakes-you-when-your-brain-is-ready)
- [AnySleep preprint](https://arxiv.org/html/2512.14461v1)

## Libraries and models

- [AnySleep](https://github.com/dslaborg/AnySleep) (MIT): the sleep model, its three runs exported to ONNX for the
  phone.
- [flutter_onnxruntime](https://pub.dev/packages/flutter_onnxruntime) (MIT) with ONNX Runtime (MIT): runs the model
  on the phone.
- Android's own alarm clock (AlarmManager) and media player, part of Android: the alarm at the window's end and
  the sounds.
- This project's own live preparation and wake rule (MIT); the Python reference is `analysis/live_stager.py` and
  `analysis/smart_alarm.py`.

Checked: 2026-11-19
