# Alpha-theta training

## What it does

In the phone app (not yet run on a phone). Eyes-closed training at the back of the head: a stream sound for alpha
(the relaxed 8-12 Hz wave) crossfades to ocean waves for theta (the slower 4-8 Hz drowsy, dream-like wave), with a
soft high chime and a low gong. Ten sessions, the first three only 15 minutes, then decide.

## Evidence for this headband: weak

The headband sits where the classic protocol was first done (O1), but alpha-theta's reputation rests on tiny
studies wrapped in therapy, and it has the most reported side effects of the common feedback protocols.

## What the research says

- The famous Peniston studies used O1 with about ten patients per group; a 520-person prison study found little
  difference at 2 years.
- Documented side effects: emotional swings, spacey feelings, evoked traumatic memories, and clients who drove
  onto a curb, through a red light and into a light pole after a first session; once a seizure after slow-wave
  reward. Even healthy volunteers report some side effects.
- The "crossover" moment (theta overtakes alpha) looks a lot like falling asleep: stage-2 sleep (ordinary light
  sleep) filled 10-14% of training time, and at most 13% of people could tell they had slept.
- For PTSD, depression and addiction, only small, old or uncontrolled studies are positive; the best PTSD EEG
  trial was not better than fake feedback.
- Studies in healthy people used about 10 sessions.

## Where the data does not support it

- Treating anything. It is offered as practice, not treatment, and not at all to people with PTSD, dissociation,
  psychosis, epilepsy, active addiction or severe depression.
- A large (250-person) fake-controlled PTSD trial reports only in 2027.
- No published threshold values exist from the original protocols; every number below is a planning value.

## How the app uses this

- Its own screen, opened from the meditation screen. Before first use: nine screening questions (any "yes" and the
  mode is not offered; nothing you tick is saved), plain consent (it can bring up strong memories, leave you drowsy
  or spacey, and cause tiredness, headache, anxiety or poor sleep; at least 1 in 5 get no benefit; practice, not
  treatment), and your stop plan: someone to call and what grounds you.
- Before each session a check-in: sleepiness, distress 0-10, and a side-effect checklist for the time since the last
  session. In the first three check-ins a 1-minute reaction test sets your usual speed.
- Calibration as in meditation: 30 s eyes open, 60 s eyes closed in silence (the research suggests 1 + 2 min; the
  shorter one is a planning choice). Alpha is your peak ± 2 Hz; theta is 6 to 2 Hz below your peak.
- Sessions: 15 min in the first three, then 20 or 25 min; after ten the app asks you to decide before going on.
  Each band's line starts at your silent minute's middle value and moves every 3 minutes, aiming at alpha above it
  50-65 % of the time and theta 30-40 %. A chime after 1 s of alpha above its line, a gong after 1 s of theta above
  its line, at most one per band every 2.5 s, theta winning ties; a jaw clench, movement or blink earns nothing and
  ducks the sound a little.
- Sleep guard: when the drift-off detector says "probably asleep", the sound fades and a soft rising tone wakes you,
  again every minute while it lasts. Those minutes are shown and left out of every measure. Crossover (theta above
  alpha) is shown for awake time only, as a fact, never as a goal.
- Stop is always on the screen and never asks: the sound fades over about 10 s. Then a minute of eyes-open
  grounding, then the questions: distress, strong memories (none, pleasant, distressing), feeling unreal or
  detached, anything like a seizure, the checklist again, how in control you felt, and notes.
- Before you leave: a sleepiness rating and a 1-minute reaction test against your usual. If slower by over 10 % or
  sleepy: "do not drive or cycle yet", and a retest after 10 minutes.
- The mode pauses and suggests talking to a professional after distress of 7/10 or more, two sessions in a row with
  distressing memories, anything like dissociation, a side effect lasting into the next day, or any seizure-like
  event (then a doctor first). It resumes only when you confirm you have talked to someone.
- With the replay check on, alpha-theta has its own check (the same rules as meditation's).

## Sources

- [Hammond & Kirk 2008: side effects](https://isnr-jnt.org/article/view/16682/10648)
- [ISNR standards 2011](https://isnr-jnt.org/article/view/16583/10550)
- [Peniston & Kulkosky 1989](https://pubmed.ncbi.nlm.nih.gov/2524976/)
- [Sokhadze 2008 review](https://pmc.ncbi.nlm.nih.gov/articles/PMC2259255/)
- [Schutze & Junghanns 2015: sleep during alpha-theta](https://pubmed.ncbi.nlm.nih.gov/25835580/)
- [Rogel 2015: side effects in healthy volunteers](https://pubmed.ncbi.nlm.nih.gov/26008757/)
- [Nicholson 2023: PTSD trial](https://pmc.ncbi.nlm.nih.gov/articles/PMC10090479/)
- [Raymond 2005: dose in healthy people](https://pubmed.ncbi.nlm.nih.gov/15820636/)
- [NCT06770998: PTSD trial, results due 2027](https://clinicaltrials.gov/study/NCT06770998)
- [EEGer alpha-theta basics (sound design)](https://ellipse-marlin-482e.squarespace.com/eeger-answers/alpha-theta-basics)

## Libraries and models

- This project's own feedback core (MIT), shared with the brain sound and meditation feedback.
- [MNE-RT](https://github.com/mne-rt-org/mne-rt) (BSD-3): open feedback protocols, used as a reference.

Checked: 2026-11-18
