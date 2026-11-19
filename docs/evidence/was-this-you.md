# Was this you?

## What it does

In the phone app (not yet run on a phone; the assistant's proposal, on unless you switch it off in Settings). After
it has seen 10 of your check-ins (or 10 nights) on 5 different days, it asks "Was it you?" when a later one looks
clearly unlike your usual brain signal. "Someone else" keeps that recording out of your trends, the unusual card
and experiments; nothing is deleted or locked.

## Evidence for this headband: weak

A person's eyes-closed alpha is stable over years, so a rough "this looks like you" is possible; but no study has
tested a wearer check on this headband or any dry 4-electrode one, and this simple check was tested only on
made-up people. It catches only a clearly different signal.

## What the research says

- Eyes-closed alpha at the back of the head is one of the most repeatable things about a person's EEG: its strength
  and its speed (the alpha peak frequency) repeat about as well over 5 years as over a week (ICC, the share of all
  variation that is between people, about 0.8). The slope of the background signal (the "1/f slope") repeats less
  well (about 0.55-0.75).
- The alpha speed jumps 1-2 Hz from second to second, so it has to be measured over minutes, never seconds.
- Telling people apart from EEG works but is imperfect. In the largest test (345 people, about 6,000 sessions, wet
  128-electrode lab caps) the error rate was 6.7 % a day later and 14 % a year later. With only the 4 electrodes of
  a Muse-like headband picked out of those caps it was 18 % on one short sample, and about 6 % with two enrolment
  days and four samples. That used a deep network trained on hundreds of people, not a simple rule.
- A check that knows only its owner does much worse: in a 2021 study owner-only models were close to guessing
  (40-49 % error); models that had also seen other people did far better.
- Alcohol slows the alpha speed (young binge drinkers by about 0.7 Hz), and sleeping pills and some antidepressants
  weaken alpha. So a borrowed headband and an unusual night of your own can look alike.
- People do swap wearables: a fitness-tracker study was motivated by couples wearing each other's devices.

## Where the data does not support it

- No wearer check has been tested on this headband or any dry 4-electrode headband. Dry contacts add noise the lab
  studies did not have, so the real numbers will be worse than theirs.
- This check uses three simple numbers and only your own recordings (no network trained on other people), which is
  the weaker kind of check.
- No recordings of other people were at hand to test it. On made-up people (their spread taken from the
  repeatability numbers above) it asked about a recording of the person themselves about once in 5 to 10 months of
  daily recordings, and noticed only 2 to 4 in 10 recordings of someone else.
- On your own recordings so far it could not be tested: one check-in, and nights without Lights off or without a
  clear alpha peak at their start.
- It cannot tell a moved headband, a loose electrode, alcohol, a new medicine or a short night from another person.
  That is why it only asks.

## How the app uses this

- The numbers: alpha speed, alpha strength and the background slope at the two back electrodes (O1 and O2), the
  morning check-in's own measures. From a check-in's 2 minutes with eyes closed; from a night's awake minutes in
  the first 10 minutes after Lights off (a night without Lights off is not checked). Each needs a minute of clean
  signal and a clear alpha peak.
- Check-ins and nights are learned apart. It is silent until 10 of a kind on 5 different days ("Learning what your
  brain looks like: 3 of 10"). Then each new one is compared with your newest 20 accepted ones.
- The rule: how far each number is from your usual, in your own spreads (with a small floor so a very steady start
  is not too strict), combined; past 2.5 it asks. A recording joins your usual when it looked like you or when you
  said it was you, never when you said someone else.
- "Someone else" is written into that night's report or that check-in's result and keeps it out of the trends,
  the unusual card and experiments. "Someone else wore it" is there on every recording too: when you know someone
  borrowed the headband, say so yourself. Undo takes an answer back.
- Never a lock, a notification, a name or a health claim. Everything stays on the phone (Export data copies it out
  with everything else).

## Sources

- [Large multi-session test of EEG as a biometric (Fallahi, Arias-Cabarcos and Strufe, arXiv 2501.17866 v3)](https://arxiv.org/html/2501.17866v3)
- [Resting EEG over 5 years: alpha, alpha speed and the 1/f slope (Cerebral Cortex 2026)](https://pmc.ncbi.nlm.nih.gov/articles/PMC13456336/)
- [The alpha speed jumps from second to second (eNeuro 2025)](https://www.eneuro.org/lookup/doi/10.1523/ENEURO.0118-25.2025)
- [Background slope reliability (Brain Topography 2024)](https://link.springer.com/article/10.1007/s10548-024-01067-x)
- [Owner-only checks near guessing (USENIX Security 2021)](https://www.usenix.org/system/files/sec21-arias-cabarcos.pdf)
- [Alcohol and the alpha speed in young binge drinkers](https://pmc.ncbi.nlm.nih.gov/articles/PMC5995627)
- [Drugs and alpha at the back of the head (Lozano-Soldevilla 2018)](https://frontiersin.org/articles/10.3389/fncom.2018.00023/full)
- [Couples swapping fitness trackers (Cornelius and Kotz)](https://www.cs.dartmouth.edu/dfk/research/cornelius-impedance/cornelius-impedance.pdf)
- [Two channels of home sleep EEG re-identify people (Fuhrmeister 2025)](https://arxiv.org/html/2509.20454)

## Libraries and models

- No library or trained model: the rule is this project's own code (MIT), `analysis/wearer_check.py` with its phone
  port `app/lib/wearer/check.dart`, on the morning check-in's own measures (`scripts/morning_check.py`,
  `app/lib/morning/measures.dart`). The made-up back-test: `analysis/validate_wearer.py`.

Checked: 2026-11-19
