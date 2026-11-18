# Meditation feedback

## What it does

Planned. During an eyes-closed meditation: sound plus a simple display of settled, restless or drifting toward
sleep. Afterwards: a timeline of the session, the share of settled time, the longest settled stretch, movement and
jaw events, your own rating, and the trend across sessions.

## Evidence for this headband: weak

Stillness, eyes-closed alpha and dozing are measurable here, but meditation headbands helped distress only a
little and did not change the brain signal they trained, and there is no reliable "meditation depth" signal.

## What the research says

- Consumer meditation headbands (Muse in 11 of 16 trials) gave a small drop in distress (g = -0.16, an effect size
  where 0.2 already counts as small) and no
  measurable change in the brain signal they trained. The practice itself seems to do the work.
- Alpha (the 8-12 Hz wave that grows when you close your eyes) rose during sessions with real feedback, with
  replayed feedback and with none at all.
- The best signs of learning, strongest first: a rise across sessions in short blocks without feedback; a rise
  in silent rest from before to after a session; a trend in the feedback blocks; a target that creeps up over
  weeks. Between 10% and 57% of people do not learn, depending on the definition.
- Strategy lists do not help and effortful trying may hurt: people who learn say they "sense" the sound;
  people who do not say they "will it".
- Dozing works in opposite directions: with eyes closed, falling asleep removes alpha; with eyes open, sleepiness
  raises it, so "more alpha is better" can reward dozing.

## Where the data does not support it

- A "meditation depth" or "meditation score": no reliable signal for it exists at these electrode sites.
- That the feedback makes you progress faster than the same practice without it.
- A rising alpha line as proof that you are learning.
- Frontal-midline theta (a 4-8 Hz rhythm at the top front of the head), which feedback raised in meditators in a
  fake-controlled study, sits where this headband has no electrode.

## How the app uses this

- Built on the brain sound's tested core: a silent baseline, 4 blocks of 3 minutes with sound, a short block
  without feedback, then the report.
- Settled: eyes-closed alpha above your line with no muscle, blink or drowsiness flag. Restless: muscle,
  movement or blinks. Drifting: the shared drift-off detector.
- A learning verdict only after 8 sessions (checked again at 12), and only if the trend's 90% range stays above
  zero while muscle and drowsy time did not rise with it. If it stays flat, the app says so.
- The instructions say "just notice", not "try to relax".
- Wording: "a guided eyes-closed practice; practice, not treatment".

## Sources

- [Treves 2025: consumer meditation headbands](https://www.jmir.org/2025/1/e68204)
- [Maaz 2025 preprint: alpha rises in all groups](https://arxiv.org/abs/2509.10046)
- [Weber 2020: who does not learn](https://pmc.ncbi.nlm.nih.gov/articles/PMC7327249/)
- [Su 2021: learning indices](https://www.nature.com/articles/s41598-021-99235-7)
- [CRED-nf checklist](https://pmc.ncbi.nlm.nih.gov/articles/PMC7296848/)
- [Chikhi 2023: strategies](https://doi.org/10.1016/j.biopsycho.2023.108521)
- [Davelaar 2018: sensing vs willing](https://pmc.ncbi.nlm.nih.gov/articles/PMC6206258)
- [Sleepiness and eyes-open alpha (Kaida 2006)](https://data.zhenzhi.com/details/1/905755554)
- [Sleep onset removes alpha (Zhang 2014)](https://personal.ntu.edu.sg/ctguan/Publications/C_2014_ZhangZhuo_IEEE_EMBC.pdf)
- [Frontal-midline theta feedback in meditation (Brandmeyer & Delorme 2020)](https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2020.00246/full)

## Libraries and models

- This project's own feedback core (MIT), shared with the brain sound.
- [MNE-RT](https://github.com/mne-rt-org/mne-rt) (BSD-3): open feedback protocols with no-feedback and sham
  blocks, used as a reference.
- [flutter_soloud](https://github.com/alnitak/flutter_soloud) (MIT): the sound engine for the phone app.

Checked: 2026-11-18
