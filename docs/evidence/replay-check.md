# Replay check (does the live link matter?)

## What it does

In the phone app (not yet run on a phone). When switched on (it is off by default), some meditation or alpha-theta
sessions secretly replay the sound of one of your own earlier sessions instead of following your brain live. After
every 12 sessions, the app compares live with replayed sessions: the trained brain signal, how you felt, and your
guesses about which was which.

## Evidence for this headband: some

It copies the fake-feedback controls used in good trials, and replays of people's own sound went unnoticed in one
study; but whole-session replays can be partly sensed, and one person needs many sessions.

## What the research says

- Replaying a person's own earlier sound is "a very stringent control": short replays mixed into live sessions
  went unnoticed by all 18 people reached afterwards.
- Whole-session replays felt less controllable than live ones in two of three crossover studies, so expect that
  you will sometimes guess right.
- Alpha (the wave that grows when you close your eyes) rose in every group of a double-blind study (neither the
  people nor the staff knew who got what): real,
  replayed and passive watching. Only live minus replay can show that the live link matters.
- In the own-replay study, live beat replay in only 6-11 of 24 people, so "no difference" for one person is a
  likely and legitimate result.
- Good trials compare against a fake that looks the same; a research checklist notes that few feedback programs
  are designed for this kind of blinding.

## Where the data does not support it

- It tests one thing: whether, within a session, the live link changes your signal or experience more than an
  identical-sounding replay. It does not test long-term learning or any health benefit.
- Sessions needed (the research report's own estimate): telling live from replay takes about 13-37 sessions; seeing
  your EEG follow live sessions at a large effect about 34; a small effect about 128, which is out of reach for
  one person.
- Twelve sessions is only a pilot; plan 24-36 randomised sessions.

## How the app uses this

- Off by default: Training settings, from the gear button on the meditation and alpha-theta screens. While on, the
  same reminder appears before every session: "Replay check is on. This session's sound may follow your brain live
  or replay one of your earlier sessions. Practise as usual; afterwards you'll be asked to guess."
- Each kind of session (meditation, alpha-theta) has its own check. It first collects 4 live sessions of that kind
  with a saved log (sessions from before you switched it on count), so there is something to replay.
- What is replayed: the sound settings and bells (or chimes and gongs) logged in your own earlier live sessions of
  the same kind, never the raw EEG. The app picks from the last 10 with a reward rate close to their usual, the
  least replayed first, and joins two when one is shorter than the session.
- Jaw tension always roughens the sound live, and the muscle, blink, signal and sleep checks act the same way in
  both kinds of session: the sound goes neutral and no bell sounds until the check has been clear as long as a live
  bell needs. So a jaw clench cannot give a replay away.
- Sessions are drawn in shuffled blocks of 4 (2 live, 2 replay) from a random secret made on the phone. Before the
  first such session the plan (what is measured, how many sessions, which sessions are left out, the analysis) and
  the SHA-256 fingerprint of the hidden order are saved, and they never change; Training settings shows the date
  and the start of the fingerprint. No bell count and no "settled" word are shown while the check is on.
- After each check session, before the report: how calm you feel, your guess (live, replay or not sure, and how
  sure), "how in control did you feel?" and "how random did the sound seem?".
- The measure: meditation, your alpha during the sound against the same session's silent eyes-closed minute;
  alpha-theta, the change in theta against alpha; both on awake, clean seconds only. A session with over 30 % of its
  time asleep, restless or without signal is shown but left out of the test.
- Results only for whole sets of 12 sessions, never one session: live minus replay with a test that reshuffles the
  labels the way the draw could have fallen, your guesses against chance, how the sessions felt, every session of
  the set, and a check that the plan and the order are unchanged. Plan 24 to 36; every session is reported, and
  the check never stops early on a good result.

## Sources

- [Biswas & Ray 2019: own-replay control](https://www.eneuro.org/lookup/doi/10.1523/ENEURO.0498-18.2019)
- [de Matos 2026: replay can be sensed](https://pubmed.ncbi.nlm.nih.gov/41391628/)
- [Maaz 2025 preprint: double-blind, alpha rises in all groups](https://arxiv.org/abs/2509.10046)
- [Maaz 2026](https://doi.org/10.1111/psyp.70285)
- [ICAN 2021: ADHD trial with replayed feedback](https://pubmed.ncbi.nlm.nih.gov/32853703/)
- [CRED-nf checklist](https://pmc.ncbi.nlm.nih.gov/articles/PMC7296848/)

## Libraries and models

- This project's own session log and exact replay (MIT), tested with the brain sound.
- [MNE-RT](https://github.com/mne-rt-org/mne-rt) (BSD-3): has sham and replay protocols, used as a reference. No
  tool found offers a blinded replay of your own sessions, so that part is built here.

Checked: 2026-11-18
