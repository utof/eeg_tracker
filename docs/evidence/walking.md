# Walking and steps from the headband

## What it does

The headband has no motion sensor, but every step shakes it a little, and that shows in its signal as a rhythm at
your step rate. After a recording, the app finds steady walking in it, its pace in steps a minute, running (a pace of
150 or more held for a minute) and the stops between; steps are pace times time. With the optional switch in Settings,
the phone's own step counter is written down once a minute while recording, and wherever the phone counted, its steps
are used instead.

## Evidence for this headband: weak

No study has counted steps from EEG; it rests on one bench test of our own on public data and on the owner's first
recorded walk, where the rhythm was strong; the phone's step counter is the check, and until it has checked 10
minutes the steps are labelled "not yet checked".

## What the research says

- Walking puts step-locked waves into scalp EEG, up to 15 harmonics of the step rate, larger at faster speeds and much
  larger when running; head acceleration explains only about 14 % of them, so their shape is not the head's motion,
  but their timing follows the steps.
- No study uses these waves to count steps or read the pace. The nearest one sorted sitting, talking, chewing and
  walking from in-ear electrodes plus a microphone, 85 % right on test data.
- Our own test on a public treadmill recording of 9 people, using only 4 spots like this headband's: the pace was right
  (within 5 %) in 98 % of windows at a brisk walk and 99 % running, but only 59 % at a slow walk; 2 of 9 people were
  near chance at a brisk walk. When it failed, it read half or double the pace.
- A motion sensor on the head counts steps within 1-4 % (95-99 % in studies of earbuds and glasses); a phone in a front
  trouser pocket reads the pace within about 3 %, in the hand about 11 %.
- Researchers call a step count within 10-15 % of the true one acceptable for everyday use, within 5 % for a
  reference device.

## Where the data does not support it

- Slow strolling (under about 100 steps a minute), short walks indoors (under 30 seconds), turning, crowds and
  carrying bags: missed or read wrong.
- Stairs, cycling, a bus or a car, standing versus sitting: not from the headband at all; the phone does these better.
- A whole walk read at half or double the pace (the stride instead of the step) is the main way it can be wrong.
- Chewing or talking while walking makes a rhythm of its own; a loose or slipping headband gives bigger but irregular
  waves.
- The heartbeat also leaves a rhythm in these electrodes, strongest asleep: its 2nd and 3rd harmonics fall at
  walking paces. The first version called parts of a nap walking because of it; now a walk also needs a
  walking-sized shake and no heartbeat-like family, and on 3 nights and a nap no minute of sleep was called walking.
- The thresholds were set on one walk of the owner's (2026-11-20, about 81 minutes, 114 steps a minute), 3 nights and
  a nap of his, and on public data from a wet, cabled cap, not on a dry headband over weeks.

## How the app uses this

- After a recording ends (never while it records), one pass reads every electrode the recording has, any number and
  any layout: 10-second windows every 5 seconds, the rhythm's strength and pace in each; a window walks when the
  rhythm is at least 4 times the usual level at 90-200 steps a minute, the headband shakes as much as in walking,
  and the rhythm is not a heartbeat's; 7 windows vote; walking counts from 30 seconds; stops of a minute or more
  inside a walk; walks less than 15 minutes apart are one.
- Steps count only in windows whose own rhythm is clear: a floor, not a guess.
- The Archive shows a Walking lane with the pace; Trends shows Walking (minutes) and Steps (estimated) per day, with
  your usual, and says where the day's steps came from.
- The check: minutes walked the whole way with both the headband and the phone. Once there are 10, the headband's pace
  must be within 5 % of the phone's in 8 of 10 and the totals within 15 %; if not, its steps are left out and only
  walking minutes and the phone's steps show.
- The phone's steps are Android's own step counter, read once a minute only while recording and only after you allow
  "Physical activity"; nothing leaves the phone. It works best with the phone in a front trouser pocket.

## Sources

- [Kline et al. 2015, isolating gait-related movement artifacts in EEG (J Neural Eng)](https://pmc.ncbi.nlm.nih.gov/articles/PMC4946867/)
- [Castermans et al. 2014, up to 15 harmonics of the step rate in walking EEG (Neurosci Lett)](https://www.pubmed.gov/24412128/)
- [Gwin et al. 2010, removal of movement artifact from high-density EEG during walking and running (J Neurophysiol)](https://sccn.ucsd.edu/~klaus/pubs/GwinGramannMakeigFerris2010.pdf)
- [Hammour and Mandic 2021, motion artefacts in ear-EEG for activity classification (EMBC)](https://www.pubmed.gov/34892689/)
- [Lee et al. 2021, mobile BCI dataset of scalp and ear EEG while standing, walking and running (the public data of our test)](https://figshare.com/articles/dataset/Mobile_BCI_dataset_of_scalp-_and_ear-EEG_with_ERP_and_SSVEP_paradigms_during_standing_walking_and_running/13604078)
- [STEAR: step counting from earphone motion sensors](https://sinrg.csl.illinois.edu/papers/stear_earcomp.pdf)
- [Boborzi et al. 2024, activity recognition from an in-ear accelerometer (Sensors)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11085719/)
- [RRACE 2014, cadence from a phone at different body positions](https://cs.ubc.ca/labs/spin/sites/default/files/local_pdfs/2014_RRACERobustRealtimeAlgorithmforCadenceEstimation.pdf)
- [INTERLIVE 2021, how to validate step counters (BJSM)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273687/)
- [Walk-to-run cadence, Chase et al. 2023](https://www.pubmed.gov/37336086/)
- [Android: the step counter sensor](https://developer.android.com/reference/android/hardware/Sensor)

## Libraries and models

No library or model: the method is a few lines of signal processing in the app (`app/lib/walking/`) and in Python
(`analysis/walking.py`), checked against each other on made-up recordings.

Checked: 2026-11-20
