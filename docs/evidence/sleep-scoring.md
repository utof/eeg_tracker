# Sleep scoring (the night chart)

## What it does

The morning after, two sleep models read the night's file and label every 30 seconds as awake, light, deep or
dream (REM) sleep. The result is a chart of the night (a hypnogram) plus sleep onset, time asleep and wake-ups.

## Evidence for this headband: some

Similar dry headbands, each with its own model, matched lab scoring for sleep timing and for wake, dream and non-dream
sleep. This headband has never been checked against a lab recording, the five-stage detail (light and deep sleep) is
weak, and **dream sleep (REM) may be under-counted until it is checked**: on two phone nights it came out at 7-10 % of
sleep, against a usual 20-25 %.

## What the research says

- AnySleep, the main model, accepts any set of electrodes (it learned from 19,909 nights). On lab recordings it
  scores about 0.68 with one channel and 0.73 with four (macro-F1: a 0-1 score averaged over the stages).
- The closest dry headbands set the range. Dreem reached kappa 0.748 (kappa: agreement beyond chance, 0 to 1),
  while human experts agree with each other at 0.798. Muse-S reached 0.76. At home, dry ZMax nights averaged
  0.45 and 10% of nights failed.
- A fair target here is kappa 0.6-0.75 on nights with good contact, with light sleep (N1, the drowsy first
  stage) staying poor.
- Big pretrained "brain foundation models" lost or tied on every test on headbands like this one; on two-channel
  sleep data, plain hand-made measures tied the big models.
- Retraining a model on lab nights reshaped to look like the device added 0.058 kappa in an ear-EEG study, and
  one labelled night per person added 2-4.5 accuracy points.

## Where the data does not support it

- **Dream sleep may be under-counted.** On the owner's first two phone nights the model scored 7 % and 10 % of sleep
  as dream sleep; young adults usually have about 20-25 %, and headbands checked against lab sleep studies miss it by
  only about 2 minutes on average (limits about -16 to +19 minutes). The same model found 29-33 % on two earlier
  nights, so the headband can show it. The model was never trained on these dry side and back electrodes, and on one
  night nine changes to its input that need no training all gave the same or less dream sleep. Side-to-side eye
  movements, a sign of dream sleep, crowded into the "light sleep" right next to its dream-sleep blocks, so those
  blocks look cut short. Wearing new equipment can also really shorten and delay dream sleep, so some nights may truly
  have little. Until a lab night or another check settles it, read dream-sleep minutes as a trend between your own
  nights, not as the true amount.
- Nobody has scored sleep from a BrainBit next to a lab sleep study. Until that is done, the chart is a first
  guess.
- Light sleep (N1) is missed by every headband. Dry electrodes may record extra slow waves, which can push light
  sleep into "deep", so treat deep-sleep minutes with care.
- Walking fooled the model: on an awake evening with a 2-hour walk it called 24 minutes sleep, nearly all of them
  during the walk, because steps shake the headband in slow waves. The app now finds walking by its step rhythm and
  counts those half minutes as awake (half a minute of false sleep was left; a nap and three nights lost nothing),
  and the report says how many minutes it changed. Other shaking (a bus, a bike) is not caught this way.
- When the two models agree, that shows they are consistent, not that they are right.
- YASA was trained on a top-of-head channel; back and side electrodes are outside its training.
- AnySleep looks about 7 minutes forward and back, so the night's chart is scored afterwards. Read live, 2 minutes
  behind the newest data (the nap coach does this), it agreed with its own full-night scoring on most of one
  recorded night, a little less at the live edge.

## How the app uses this

- AnySleep (three runs averaged, all four channels, plus a filter that removes slow drift) is the main model; YASA on
  the O1-T3 pair is the second opinion on the laptop. Where they disagree, the chart shows low confidence.
- The phone scores the night itself after you press Stop, with the same three AnySleep runs made smaller for
  the phone; on a test stretch of a recorded night they gave the same stage as on the laptop for every 30
  seconds. The phone goes through the night about an hour at a time to save memory, and twice: first it learns how
  much to trust each electrode over the whole night, then it scores each hour that way. On the three recorded
  nights that gave the laptop's stage for every thirty seconds (hour by hour alone had changed about 3 in 100).
  The phone has no second opinion.
- A 30-second stretch missing more than 5 seconds of data is not scored: missing data never becomes "awake" or
  "deep".
- While the night still records, **Sleep so far** scores it up to 2 minutes ago, one 64-minute stretch at a time
  with 8 minutes on either side, each scored once and kept. AnySleep weighs everything it is given together, so these
  stretches can differ a little from the report after Stop, which scores the whole night at once; the page says so.
  On one recorded night (6 hours, on the laptop's stand-in for a phone) 96 in 100 of the 30-second stretches got the
  same stage as the report, and the totals were within a minute or two. In a recording you started with Record, it
  counts only the sleep you marked, from the moment you pressed Sleep; with none marked it says so and scores nothing.
- Noise is shown, not hidden: the report says how much of your sleep the model read through a noisy signal
  (movement, jaw muscle or a loose electrode) or with no usable electrode, and a Signal line under the chart marks
  where. Nobody has tested how well the model copes with that noise on this headband, so treat those stretches with
  care. On the first recorded night 13 % of the sleep was noisy and 3 % had no usable electrode.
- An upgrade (AnySleep fine-tuned on public nights reshaped to this headband's channels) is adopted only if it
  adds at least 0.03 kappa on nights it has not seen.
- **Dream sleep check** in each night's report, to judge any later change to the scoring (it measures, it changes no
  stage): the dream-sleep share against the usual 20-25 %, the time from falling asleep to the first dream sleep
  (usually 1-2 hours), dream sleep in the last third of the night against the first (usually most comes late), the
  model's own dream-sleep likelihood added up against the minutes it scored (if they match, a different cut-off would
  not add dream sleep), and side-to-side eye movements from the two electrodes nearest the eyes (T3 minus T4 here):
  how many fall in dream sleep and how often they come in dream sleep against other sleep. The eye-movement rule is
  a first guess, not checked against eye electrodes: a second counts when the left-right difference swings more than
  40 µV with the two sides moving in opposite directions. On the night of 2026-11-19: dream sleep 43 min (10 %), the
  first after 2 h 29 min, 27 min in the last third and 13 min in the first; the likelihood added up to 38 min; 20 %
  of the eye movements fell in dream sleep, which was 10 % of the sleep, about 10 seconds a minute with eye movements
  in dream sleep against about 5 in other sleep. The report keeps the model's probabilities for every 30 seconds, so
  a later scoring change can be checked on old nights too.
- Big foundation models only in a later side-by-side test; none is used now.

## Sources

- [AnySleep preprint](https://arxiv.org/html/2512.14461v1)
- [Dreem dry headband vs experts (Arnal 2020)](https://www.ebi.ac.uk/europepmc/webservices/rest/PMC7751170/fullTextXML)
- [Muse-S sleep study (Lanthier 2026)](https://espace2.etsmtl.ca/33349/1/Lina-JM-2026-33349.pdf)
- [ZMax home nights](https://www.medrxiv.org/content/10.64898/2026.06.01.26354591v1)
- [BrainCodes: tiny model beat big ones on the 4-electrode Muse](https://arxiv.org/html/2610.29320v1)
- [Zare 2026: two-channel sleep, hand-made measures tie big models](https://arxiv.org/html/2607.24519v3)
- [Lebiecka-Johansen 2025: adapting sleep models to ear-EEG](https://ece.au.dk/fileadmin/ece/Center/Ear-eeg/News_files/EMBC2025papers/LebieckaJohansen2025_BenefitsOfDifferentStrategiesToAdaptSleepScoringModelsFromScalpToEarEEG.pdf)
- [Mikhaylov 2024: dry electrodes record extra slow power](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)
- [Wang 2025: dry 8-site band, light sleep missed](https://europepmc.org/article/PMC/PMC12561290)
- [SLEEPYLAND: model agreement vs accuracy](https://arxiv.org/html/2506.08574v2)
- [Markov, Elgendi and Menon 2025: 43 headband studies against lab sleep, dream sleep missed by about 2 minutes](https://www.ebi.ac.uk/europepmc/webservices/rest/PMC13055050/fullTextXML)
- [Ohayon 2004: how much dream sleep is usual at each age](https://pubmed.ncbi.nlm.nih.gov/15586779/)
- [Earable: side electrodes catch side-to-side eye movements almost as well as gel electrodes](https://arxiv.org/abs/2211.02592)
- [First nights with equipment: less and later dream sleep](https://pmc.ncbi.nlm.nih.gov/articles/PMC8027063)
- [YASA's eye-movement detector, the idea behind the rule here](https://yasa-sleep.org/generated/yasa.rem_detect.html)

## Libraries and models

- [AnySleep](https://github.com/dslaborg/AnySleep) (MIT; code and weights): the main sleep model.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.28 (MIT) through
  [flutter_onnxruntime](https://github.com/masicai/flutter_onnxruntime) 1.9.0 (MIT): runs AnySleep on the phone.
- [YASA](https://github.com/raphaelvallat/yasa) 0.8.1 (BSD-3): the second opinion.
- [MNE](https://pypi.org/project/mne/) (BSD-3): reads and filters the recording.
- [pyedflib](https://github.com/holgern/pyedflib/blob/master/LICENSE) (BSD-3): reads and writes BDF+ files.

Checked: 2026-11-20
