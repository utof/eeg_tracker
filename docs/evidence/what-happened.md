# What happened in a recording (the app's own guesses)

## What it does

In the phone app (checked on made-up recordings and the emulator, not yet on a day of your own). For every finished
recording the app works out one best guess per half minute of what was going on (no signal, asleep, a nap, walking,
moving, talking or chewing, eyes closed and resting, drowsy), shows it as the first lane of the recording's page with
how sure it is, and asks you about one of them: "Meditating or resting?".

## Evidence for this headband: some

The guesses are as good as what four electrodes at the back and sides of the head can see: no signal is near
certain, eyes closed is strong, asleep is good, walking is good when the step rhythm is clear, drowsy with eyes open
is only some, and telling talking from chewing is weak. None of the limits is set on your own days yet.

## What the research says

- Eyes closed: alpha (the 8 to 12 times a second rhythm at the back of the head) rises when the eyes close. This
  headband's back electrodes matched lab electrodes closely (correlation 0.90, 19 adults). About 1 person in 10 shows
  little rise, and the side electrodes show none.
- Asleep: the app's sleep scoring tells sleep from wake well; the stages inside are a first guess. Dry headbands
  reach an agreement of 0.6 to 0.75 with a sleep lab at best (1 would be perfect).
- Drowsy with eyes open: consumer headbands were right 31 to 79 % of the time in a review of 46 studies. A dry
  in-ear device reached 93.3 % on a person it had not seen, but in 9 people doing tasks meant to make them drowsy.
- Talking, chewing, swallowing: a forehead headband told them from other face movements with scores above 0.9, mostly
  from muscle, in 10 people following a script. The muscle itself is easy to see here (the jaw rule caught 86 % of
  the loudest muscle seconds); which of the two it was is not.
- Moving: dry wearable EEG gets worse with body movement (36 people). This headband has no movement sensor; the app
  marks moments when three or more electrodes jump at once.
- Meditating against resting against a wandering mind: no reliable signal. Classifiers of mind-wandering reached 0.66
  on a scale where 0.5 is a coin toss, and about 0.88 within one person but 0.70 on new material. So the app asks.
- A 2026 paper built for exactly these four electrode sites reports 94.69 % for "focus", "relaxation", "engagement"
  and "flow", but its labels are lab tasks (eyes closed, eyes open, real and imagined movement); its authors write
  that it is not a measure of real-life states. In plain words it tells eyes closed from open and moving from still.
- Learning from one person's answers: a simple model on about ten numbers, trained on that person's own confirmations,
  is the honest start; work on few-label personalisation changes only the last step of a model with a small number
  of answers.

## Where the data does not support it

- Every limit is a planning value: 3 minutes for "eyes closed, resting", 2 jaw bursts in half a minute for talking
  or chewing, 3 seconds of movement for moving. None was set on a labelled day of yours.
- Eyes closed and drowsy are read against the recording's own first minutes, so a recording that starts with closed
  eyes or already drowsy reads them poorly.
- It is not live: the guesses come from a pass over the finished recording, so nothing is marked while it records.
- The app cannot tell meditating from resting, talking from chewing, or working from reading; a vehicle and cycling
  are not found at all.
- Another electrode layout gets only the guesses that need no back or side electrode (asleep, walking); the page says
  why the others are missing.
- The guesses table is a record, not a model: nothing learns from it yet. That needs about 30 answers of each kind.

## How the app uses this

- The first lane of a recording's page, **What happened**: one state per half minute, the first that applies of no
  signal, asleep or nap (the sleep report), walking or running (the step rhythm), moving, talking or chewing, eyes
  closed and resting (eyes closed, awake, no movement, hardly any jaw muscle, for 3 minutes or more), drowsy. Tap a
  stretch to read where it comes from and how sure it is. The lanes under it are the detail.
- Your own marks and tags keep their own lanes. A guess never becomes a label by itself.
- **Meditating or resting?** When your eyes were closed and you were still for 3 minutes or more by day, the quick
  checks ask once, with the two words, "Something else" and "Not sure". At most one such question a day (the longest
  stretch), never about your usual night, never inside something you marked yourself (meditation, a sound, sleep, a
  nap, a check-in) or tagged. Your word becomes the label. No sound and no session is started.
- So the question is not late, the pass over a recording runs when it stops (and, as before, when the Archive or
  Trends is open). A short stretch is only asked about for a few hours.
- Every guess, the numbers behind it and your answer go into one table on the laptop (`guesses.tsv`) for later.
- Nothing here plays a sound, sets an alarm, gives a cue or uses the microphone.

## Sources

- [Drowsiness from dry in-ear EEG on unseen users (Kaveh 2024, Nat Commun)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11297174/)
- [Talking, chewing and swallowing from a headband's muscle signal (arXiv 2202.00206)](https://arxiv.org/abs/2202.00206)
- [Dry wearable EEG under body motion (WearBCI, arXiv 2604.09649)](https://arxiv.org/abs/2604.09649)
- [Mind-wandering from EEG during videos (Tang and Li 2024)](https://nature.com/articles/s41598-024-58889-9)
- [Mind-wandering within a person and across lectures (Frontiers 2023)](https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2023.1182319/full)
- [Cognitive states from a four-electrode headband, and its limits (Ngo et al. 2026)](https://orbi.uliege.be/bitstream/2268/345428/1/_Phong%20Ngo%20etal-2026-Toward%20Real-Time%20Cognitive%20State%20Sensing%20in%20Everyday%20Work-BME11.pdf)
- [Personalising activity recognition with a few questions (SelfAct, arXiv 2304.09530)](https://arxiv.org/abs/2304.09530)
- [Few-shot personalisation on the device (arXiv 2508.15413)](https://arxiv.org/abs/2508.15413)
- [Dry headband against gel electrodes, same layout (Mikhaylov 2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)

## Libraries and models

- None new: the app's own detectors, sleep report and walking pass (this repository, MIT).

Checked: 2026-11-26
