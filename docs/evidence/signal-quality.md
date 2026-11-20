# Headband status (contact, signal quality, battery)

## What it does

One headband card on every screen: is it connected, how good each electrode is right now (good, ok, poor, none), and
about how much battery is left. If something is wrong it says whether it is you (moving, talking) or one electrode.

## Evidence for this headband: some

The maker publishes a contact limit and says quality should be judged mainly from the signal; simple per-second signal
checks are validated on dry two-electrode headbands. The exact limits here are planning values, set from this
headband's own readings, and the battery number is an estimate because the headband's gauge sticks.

## What the research says

- BrainBit calls 1 MΩ "the threshold allowable value for conducting sessions", says contact usually gets better by
  itself "within a few minutes", and treats the ohms as an extra aid: quality is judged mainly from the signal.
- This headband on a settled fit read about 30 to 160 kΩ (median 127 kΩ over 62 recordings in three days); 88 % of
  readings were at or below 1 MΩ. The highest number ever shown was 2.45 MΩ, and BrainBit's page gives 2666 kΩ as an
  upper limit, so anything worse reads as "no contact".
- The BrainBit cannot measure contact while it streams the signal. Each check costs about 7 seconds of signal.
- A per-second check of each channel (flat line, too large, mains hum) reached 90.9 % agreement with experts on a dry
  two-electrode headband (Grosselin 2019), at about 3 ms of computing per second of signal. That study's limit for
  "too large" is ±300 µV; BrainBit's own software uses 110 µV.
- Talking, chewing, blinking and moving reach all four electrodes together through the shared forehead reference. One
  loose electrode shows up on its own channel only. This split is the most useful one for a wearer.
- Consumer headbands that judge quickly (Muse) ask you to wait 30 to 60 seconds after each adjustment. A bench study
  of dry electrodes found the most drift in the first 10 minutes.
- BrainBit is rated "up to 10 hours" on a charge. This headband went from 99 % to 79 % in 1.8 hours of signal:
  about 11 % an hour.

## Where the data does not support it

- The limits (300 kΩ, 1 MΩ, 250 and 500 µV, "three electrodes in four at once") are planning values, not measured
  limits. BrainBit does not say how it measures resistance.
- No study follows dry-electrode contact through a whole waking day.
- "Good" contact does not promise a good result: in a 2026 home sleep study, quality scores caught failed nights but
  did not predict scoring accuracy on the adequate ones.
- The battery estimate assumes the rated drain. A headband that drains faster or slower than 11 % an hour makes the
  number wrong until the gauge moves again.

## How the app uses this

- Contact in ohms: good up to 300 kΩ, ok up to 1 MΩ, poor above, none when there is no reading or the headband is off
  the head. The card shows the ohms with the time they were measured, and never pretends to measure while the signal
  runs.
- While the signal runs, each electrode is judged every second: off (a flat line under 1.4 µV, or at the amplifier's
  limit), wild (swings over 500 µV above 2 Hz), loud (over 250 µV), or calm. A contact reading still in force can only
  make the word worse, never better.
- When at least three electrodes in four (and at least two) are loud or wild in the same second, the card says "busy":
  you are moving, talking or chewing, or the band shifted. The band is on, and no electrode is blamed.
- Trouble on some electrodes only names them, with what to do: part the hair under it and press it to the skin. All
  electrodes off at once is one message: the band is off the head, or the forehead contact is lost.
- Words do not jump: in the first 5 minutes of a connection a word gets worse after 3 of the last 4 seconds and better
  after 3 calm seconds; later it takes 20 of the last 30 seconds, and 10 seconds to recover.
- In the first 5 minutes the card says to wait: contact usually gets better by itself in 2 to 5 minutes.
- The ohms are measured when the headband connects. After that only when you ask, or at the next start when the signal
  says the contact changed. Never on a timer.
- One connection for the whole app: a night or a session started while the headband is already connected uses the same
  connection, with no new search and no new contact check.
- A warning is worth sending only after 2 minutes of trouble on an electrode, and never for "busy".
- Battery: the headband's gauge sticks while it streams (it showed 6 % for nine hours, and 100 % for hours). The app
  keeps the last reading it believes and takes off 11 % for every hour of signal since. A reading is believed when the
  gauge moved and landed within 8 points of the estimate, when it is the first one, or when a new connection reads
  higher (it was charged). The card says "about 62 %", and when the gauge disagrees it shows the gauge's number too.
- Headband lost: during a recording or session, no data for 5 minutes (5 to 10, your choice) gives one notice on the
  phone, and one more when data is back. An estimated-empty battery gives one. Nothing after you tap Stop. The paired
  laptop shows the same.
- Two older rules stay as they are for now, because they are part of calculations checked against the laptop's code:
  brain sound skips a channel that swings over 300 µV in a second, and the morning check-in's analysis drops 2-second
  pieces over 150 µV.

## Sources

- [BrainBit: device recommendations (1 MΩ limit, contact improves in minutes)](https://sdk.brainbit.com/device-recommendation)
- [Grosselin 2019: quality check for dry-electrode EEG, Sensors](https://pmc.ncbi.nlm.nih.gov/articles/PMC6387437/)
- [Muse: starter guide (wait after each adjustment)](https://choosemuse.com/pages/starter-guide-muse-2)
- [BrainBit SDK: artefact rules](https://sdk.brainbit.com/lib-emotions)

## Libraries and models

- This project's own judge and battery estimate (MIT); no outside library.

Checked: 2026-11-21
