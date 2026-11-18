# What the electrodes see (jaw, blinks, eye movements)

## What it does

The side electrodes (T3, T4) sit on the main chewing muscle and the reference electrode sits on the forehead, so
the headband sees jaw clenches, blinks and sideways glances clearly. The app uses them to stop false rewards, and
later for night jaw counts and hands-free gestures. The setup test (20 blinks, 10 glances, 5 clenches, each on a
tone) shows what your headband picks up.

## Evidence for this headband: strong

Jaw muscle at T3/T4 and blinks through the forehead reference are among the most reliable things this headband
measures; eye direction, heart rate and breathing are not.

## What the research says

- Jaw muscle at the temple electrodes can mimic brain rhythms across the head, so T3 and T4 are mainly a muscle
  sensor. A clench can fake "focus" or "stress", and a lifted electrode can fake "calm".
- Blinks show on all four channels at once through the forehead reference. Blink rate depends on the task (about
  11 a minute reading, 32 talking), so it is compared only with your own usual for the same task.
- A sideways glance swings T3 and T4 in opposite directions, so T3 minus T4 doubles the eye signal and cancels
  blinks (roughly 2-3 µV per degree in studies with electrodes near the ears).
- People clench far more by day than they think: 33.6 clench episodes an hour in temple-muscle recordings, and
  23% of people who believed they did not clench did.
- Dream sleep shows as bursts of eye movement: a Muse-S headband with similar temple sites matched a sleep lab at
  0.76 agreement overall, with dream sleep and wake near perfect.
- Dry electrodes at these side positions failed least of all sites in another headband and picked up left-right
  eye movements almost as well as gel electrodes (r = 0.92).

## Where the data does not support it

- Where you are looking: on this exact headband, a study found eye jumps 90% of the time but told left from right
  only 62% of the time (50% is guessing).
- A night clench count is not a bruxism (teeth grinding) diagnosis: muscle-only setups agreed with sleep-lab
  scoring below 0.1 on a 0-1 scale, while adding sound raised it to about 0.93. At most it is a reason to ask a
  dentist.
- Jaw tension is muscle, not stress.
- Heart rate from these electrodes is only an experiment (tested in 2 people); breathing, snoring and sleeping
  position: no study gets them from EEG electrodes.
- The headband's signal may stop at 70 Hz (developer page) or 100 Hz (product page); the setup test settles which.

## How the app uses this

- Brain sound: jaw = 30-45 Hz power at T3/T4 (after removing 50 Hz mains hum) against its own resting level over
  the last 2 minutes; over about twice that level blocks the bells. The same rule at O1/O2 catches neck and scalp
  muscle. A blink is a slow swing at O1/O2 over 40 µV and 5 times its usual size.
- Setup test: blinks, glances and clenches on tones in about 2 minutes, each scored against the quiet moments
  around it; "visible" at twice the background or more.
- Planned: one shared detector for blinks, eye movements, jaw (20-70 Hz) and body movement, feeding meditation
  feedback, the drift-off detector, the night counts and the signal-quality flags. Night movement: three or more
  channels jumping past about 200 µV at once.
- Planned: the night count shown as "jaw-muscle bursts per hour, 7-day trend", never as bruxism; hands-free
  gestures (a double clench marks a moment, a long clench pauses the sound).

## Sources

- [Muscle in EEG (Goncharova 2003)](https://www.neurotechcenter.org/sites/default/files/misc/EMG%20contamination%20of%20EEG%20spectral%20and%20topographical%20characteristics.pdf)
- [Artefact guide (Kappenman and Luck 2010)](https://pmc.ncbi.nlm.nih.gov/articles/PMC2902592)
- [Blink norms study](https://pmc.ncbi.nlm.nih.gov/articles/PMC9927758/)
- [Blink detection rules (BLINKER)](https://pmc.ncbi.nlm.nih.gov/articles/PMC5289990/)
- [Sideways glances on ear electrodes (King et al. 2025)](https://arxiv.org/html/2506.07193v2)
- [Daytime clenching (Yoshida et al. 2024)](https://www.jstage.jst.go.jp/article/josnusd/66/1/66_23-0362/_article)
- [Muse-S sleep validation (Lanthier, Foti et al.)](https://pure.etsmtl.ca/en/publications/assessing-the-performance-of-a-portable-electroencephalographic-s/)
- [Earable: dry side electrodes](https://arxiv.org/abs/2211.02592)
- [Eye direction on this headband (Romaniuk & Kashevnik 2024)](https://fruct.org/files/publications/volume-36/fruct36/Rom.pdf)
- [Muscle-only vs audio-video bruxism scoring (Miettinen 2020)](https://europepmc.org/article/MED/31402440)
- [Heart rate from EEG pins (brMEGA)](https://www.biorxiv.org/content/10.1101/2021.02.09.430184v1.full)
- [Night movements in ear-EEG (Mikkelsen 2019)](https://pmc.ncbi.nlm.nih.gov/articles/PMC6856384/)
- [BrainBit developer page (forehead reference, 0-70 Hz)](https://sdk.brainbit.com/device-recommendation)

## Libraries and models

- This project's own detectors (MIT); no machine-learning model.
- [YASA](https://github.com/raphaelvallat/yasa/releases) (BSD-3): its dream-sleep eye-movement detector can take
  T3 and T4 as the left and right eye channels (planned for nights).

Checked: 2026-11-18
