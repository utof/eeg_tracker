# Replay check (does the live link matter?)

## What it does

Planned. When switched on (it is off by default), some meditation sessions secretly replay the sound of one of
your own earlier sessions instead of following your brain live. After enough sessions, the app compares live with
replayed sessions: how you felt, the trained brain signal, and your guesses about which was which.

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

- Off by default. While on, the same reminder appears before every session: "Replay check is on. This session's
  sound may follow your brain live or replay one of your earlier sessions. Practise as usual; afterwards you'll be
  asked to guess."
- What is replayed: the logged sound settings and bells of one of your own earlier live sessions of the same
  kind, with a similar length and reward rate. The first 4-6 sessions are always live.
- The muscle, blink, contact and sleep checks act the same way in both kinds of session, so a jaw clench cannot
  give a replay away.
- Sessions are drawn in shuffled blocks of 4 (2 live, 2 replay), fixed before each session starts. No live alpha
  bar or bell count is shown while the check is on.
- After each session: your ratings first, then a guess (live, replay or don't know, with how sure), "how in
  control did you feel?" and "how random did the sound seem?".
- Results are revealed every 8-12 sessions, never per session. The plan is saved before the first randomised
  session; every session is reported, and the check never stops early on a good result.

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
