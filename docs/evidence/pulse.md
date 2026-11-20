# Pulse (heart rate from the headband)

## What it does

After a recording ends, the app looks for the pulse your heartbeat leaves in the headband's signal and shows it as a
red line in its own lane under the Archive's timeline and the sleep report's chart, only where it could be read. The
sleep report adds one line, "Pulse while asleep: about X/min (read in Y % of the night)", with the lowest 5 minutes,
and Trends shows that number night by night against your usual. An experiment: there is no pulse sensor in this
headband, and nothing here is checked against a watch yet.

## Evidence for this headband: weak

A heartbeat does show in EEG electrodes, as a slow wave where an electrode sits over an artery or presses on the
pillow, but no study has checked heart rate from EEG electrodes on a headband against a heart-rate reference. On the
owner's first recordings the app could read it in 9-29 % of the time asleep, and the numbers look like a sleeping
pulse; whether they are right is unknown until a watch's numbers are compared.

## What the research says

- A "pulse artefact" is a known nuisance in EEG: in one case report a temple electrode over a branch of the temple
  artery showed a 1.1 Hz wave matching the heart rate of 64 a minute, and it went away when the electrode was moved.
- In single-channel home sleep EEG (Fpz to behind the ear, 13 nights of older adults), heartbeat traces were visible
  in 11 of 13 recordings and almost absent in 2. A detector found the beats with 95 % sensitivity, and beat timing
  matched an ECG within about 1 ms in 2 people; no heart-rate error was published.
- Heartbeats picked up at the ear (ear-ECG) can be found reliably with dedicated methods (about 95 % of beats found
  in 36 people), but that uses electrodes placed for it.
- Headbands with the right sensor do well: one with a pulse sensor in the forehead read heart rate within about 1.2 a
  minute of a lab's. A bed sensor that feels the heartbeat through the mattress agreed within about +-4.4 a minute,
  but lost data in almost half of the people.
- How strong the pulse shows depends on the person, the night and how the head lies: the same electrode can show it
  clearly one hour and not at all the next.

## Where the data does not support it

- No study has validated heart rate from dry EEG electrodes on a headband. These numbers are this app's own, from a
  method tested on 3 of the owner's recordings and made-up signals, with no reference heart rate yet.
- It is read only in part of the night (9-29 % of the time asleep on the first recordings) and almost never in deep
  sleep, where the large slow brain waves cover it. A night's number is the median of the minutes it could read.
- Moving, walking and talking hide it, and the app says "no reading" then instead of guessing. Steps can make a rhythm
  that looks like a pulse; the app turns down rhythms that look like steps, but a slow shuffle with a small shake could
  still slip through.
- A pulse under 42 or over 120 a minute is outside what it looks for: a very slow sleeping pulse is said as unclear
  rather than read at twice its rate.
- It is not heart-rate variability, not a heart rhythm check and not a medical measurement.

## How the app uses this

- Every 30 seconds, on every electrode the recording has (any number, any layout): mains hum is notched out, the
  signal band-passed 0.5-20 Hz, and its spectrum searched for a rhythm of 42-120 a minute with its 2nd, 3rd and 4th
  harmonics (a pulse is a repeating wave, so its harmonics come with it). The electrode where it shows clearest is
  read; the more electrodes there are, the clearer it must be, so picking the best of many does not invent readings.
- No reading when over a second is missing, when no electrode is usable, when the head moves (the electrodes swing
  over 400 µV), when the rhythm looks like steps (the stride, sharp bumps) or may be twice a slower one, or when it
  is not clear enough.
- The pulse changes slowly, so neighbours count: a reading far from several agreeing readings around it is dropped,
  and an unclear half minute whose own spectrum has a smaller peak near its neighbours' readings is read with them.
- "Pulse while asleep" is the median of the readings in the asleep half minutes (from 5 minutes of readings); "read in
  Y % of the night" is the share of the time asleep with a reading; the lowest 5 minutes is the lowest median of 5
  minutes with readings in at least half of them. Trends compares each night with your usual (from 7 nights; an
  arrow from 14, only when it is beyond your normal spread and at least 5 a minute away).
- To check it, wear a watch that records heart rate the same night and run `scripts/compare_pulse.py` on the laptop
  with the watch's export (Health Connect, Mi Fitness, Samsung Health, Garmin through FitCSVTool, Apple Health, Fitbit
  or a plain CSV): it reports how far apart they are, as limits of agreement and the share within 5 a minute.

## Sources

- [Pulse artefact from the superficial temporal artery (case report)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8053133/)
- [Heartbeat traces in single-channel mobile sleep EEG (brMEGA, bioRxiv)](https://www.biorxiv.org/content/10.1101/2021.02.09.430184v1.full)
- [The same, journal version (Biomedical Signal Processing and Control)](https://www.sciencedirect.com/science/article/pii/S174680942100817X)
- [Finding heartbeats in ear-ECG](https://arxiv.org/abs/2305.14102)
- [A sleep headband with a pulse sensor against a sleep lab (Arnal 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7751170/)
- [Heart rate from a bed sensor against a reference](https://pubmed.ncbi.nlm.nih.gov/34705630/)

## Libraries and models

- No library or trained model: this project's own code (MIT), `analysis/pulse.py` with its phone port
  `app/lib/pulse/`, and the laptop's comparison with a watch, `scripts/compare_pulse.py`.

Checked: 2026-11-20
