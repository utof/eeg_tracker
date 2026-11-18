# Dream catcher

## What it does

Built in the phone app (2026-11-18), not yet tried on a head. As you drift off, the app notices the half-dream
moment (the alpha wave at the back of the head fading), quietly asks "what's going through your mind?", records
your spoken answer, and lets you drift again: 3-4 rounds. For creative ideas.

## Evidence for this headband: some

Two small but careful studies back the half-dream moment for ideas, and its main sign (alpha fading at the back
electrodes, O1/O2) is what this headband sees best; spotting the moment live from the EEG is weak, and a simple timer works about as
well.

## What the research says

- People who reached the lightest sleep stage (N1, the drowsy first stage) during a 20-minute rest found a hidden
  puzzle shortcut 83% of the time (20 of 24), against 31% of those who stayed awake and 14% of those who went into
  deeper sleep. The sweet spot was measured at O1, an electrode this headband has.
- MIT's Dormio (49 adults): a theme cue played at sleep onset gave the most creative stories. It sensed sleep
  onset from hand muscle, pulse and skin, not from EEG.
- A timer-only version reached the half-dream state in 91% of 80 people, against 92% with sensors.
- Headbands with electrodes at these sites time sleep onset within a few minutes: one found onset within 2.5
  minutes on 96% of 49 nights.

## Where the data does not support it

- The studies cannot prove that the light sleep caused the insight.
- Live detection of the lightest sleep stage is weak in every system found (for example 34% in one live
  scorer).
- The app's alpha rule matched the sleep model within half a minute on the only two recorded sleep onsets, both
  abrupt; the sleep model reads the same alpha, and 3 more nights are needed before the rule is trusted.
- It is a creativity exercise, not a sleep aid or therapy.

## How the app uses this

- Its own screen, opened from the main screen between nights; it holds the headband while it runs. The screen stays
  on but black and as dim as the phone allows; keep the app open.
- Once: you record two short prompts in your own voice. The theme ("Think of a tree... and drift off") plays at
  lights off and after each answer, as you drift off (Dormio's incubation); the question plays at each round. Not
  recorded: a low tone and two rising notes instead.
- "Lights off" starts the shared drift-off detector (docs/detectors.md): the first 60 eyes-closed seconds are your
  starting level. The first question comes when alpha has stayed under half that level for a minute (30-60 s after
  it flattened), with no movement and no blinks.
- A timer is always the fallback: a random moment inside your usual time to fall asleep (10-20 minutes until the
  app has 3 of your own first rounds).
- One round: the question; your answer recorded until 3 s of silence (or 10 s without a voice, or 30 s); a one-tap
  "were you drifting?" (two big halves of the screen); then the theme again: "you can drift off again". The next
  round waits for alpha to come back and fade again, at least 2 minutes later, or 4-7 minutes at most.
- 3 or 4 rounds and a 45-minute cap. At the end, your choice: a gentle rising wake tone, or no tone and the night
  recording starts by itself.
- The session's EEG is saved as part of that night, with every question as a marker, so the morning sleep report
  covers the drift-off and the detector can be checked against the sleep model.
- Afterwards the screen lists the rounds: play each answer and type a note.
- The detector ships only when its sleep onset falls within 5 minutes of the sleep model's on 4 of 5 recorded
  nights (2 so far, both within half a minute); until then the timers make every round happen anyway.
- Optional later: a home "insight test" that rotates prompted rest, unprompted rest and awake rest on different days.

## Sources

- [Lacaux 2021: 83% vs 14% found the puzzle shortcut](https://pmc.ncbi.nlm.nih.gov/articles/PMC8654287)
- [Science News critique](https://www.sciencenews.org/article/sleep-creativity-neuroscience-brain)
- [MIT Dormio 2023](https://news.mit.edu/2023/sleep-sweet-spot-dreams-creativity-0515)
- [Dormio Light: a timer works as well](https://www.frontiersin.org/articles/10.3389/frsle.2024.1258345/full)
- [Earable: sleep onset on the phone](https://arxiv.org/abs/2211.02592)
- [ezscore-f: live light-sleep detection](https://www.biorxiv.org/content/10.1101/2025.06.02.657451v1.full)
- [Hori sleep-onset scale review (Ogilvie 2001)](https://pubmed.ncbi.nlm.nih.gov/12530990/)

## Libraries and models

- This project's own drift-off detector (MIT), grown from the brain sound's sleep guard; no machine-learning
  model.
- The microphone: `record` 7.2.0 (BSD-3-Clause); answers are kept as sound files on the phone.
- Speech-to-text for the answers is not built; an offline tool is a later idea.

Checked: 2026-11-18
