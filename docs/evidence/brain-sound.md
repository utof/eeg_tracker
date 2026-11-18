# Brain sound (alpha-driven sound and bells)

## What it does

Rain and a low drone that follow the alpha rhythm at the back of your head (the 8-12 Hz wave that grows when you
close your eyes and settle). When alpha rises above your own line, the rain softens and the drone warms; stay
there a few seconds and a bell rings. A tight jaw, a blink or drifting toward sleep pauses the bells.

## Evidence for this headband: weak

The headband measures alpha well, but in careful trials sound that follows your brain has rarely beaten sound
that follows a recording (fake feedback), so the benefit of the feedback itself is weak.

## What the research says

- Real neurofeedback (sound or pictures that follow your brain) usually ties with fake feedback for ADHD,
  insomnia and anxiety, even when people really learn to move the trained signal. Both groups get better, so the
  quiet practice itself seems to be what helps.
- Alpha rises over a session with fake feedback and with no feedback at all, so a rising line is not learning.
- Delay matters: in the one direct test, 0.24 s from brain to sound trained best and 0.74 s left no lasting
  effect. It has not been repeated by another group.
- A target that tightens slowly between blocks did better than one reset every 30 seconds, which did no better
  than placebo.
- Muscle is the classic false reward: in one study half the people trained to raise a fast brain rhythm raised
  their muscle tension instead.
- Pooled over 16 trials in healthy people, alpha feedback improved working memory by a medium amount (effect size 0.56), but
  trials with a fake-feedback control often found no difference.

## Where the data does not support it

- No study shows that the brain-linked sound, rather than sitting quietly with your eyes closed, is what helps.
  It is not a treatment for anxiety, sleep problems or anything else.
- The bell count is not a score of how calm you are.
- Bluetooth headphones add about 0.15-0.5 s, which loses the speed that training mode is built for.
- About 0.2-0.25 s from brain to ear with wired headphones or a speaker is an estimate until it is measured on
  your phone and headphones.
- No study compares rain, tones and music as feedback sounds; the "noise clears as alpha rises" design rests on a
  study of 10 people.
- None of the thresholds below has been tested on a real head with this headband yet: they are planning values.

## How the app uses this

- Silent calibration: 30 s eyes open, then 60 s eyes closed. It finds your alpha peak; alpha is measured at your
  peak ± 2 Hz.
- Your line is the level your eyes-closed alpha exceeds about 65% of the time. It is held still for 3-minute
  blocks; after a block above it over 80% of the time it rises a little, under 50% it falls a little.
- A bell needs at least 3 s above the line within the last 4 s and no gate in those 4 s; then at least 5 s
  (training) or 15 s (relax) until the next, and never more than 6 a minute.
- Gates: jaw or neck muscle over about twice its resting level; a blink; drifting toward sleep (slow theta waves
  rising against alpha, the alpha peak slowing by 1 Hz, or alpha falling under half its starting level). Any gate
  means no bells and a neutral sound, and the moment does not count.
- Training mode answers in about 0.3 s (use wired headphones or the speaker); relax mode glides over about 1 s,
  rings more rarely and is fine with Bluetooth.
- Every session is logged and can be replayed exactly; this is the base of the replay check.
- The page says it plainly: a relaxing tool, not a treatment.

## Sources

- [Wang 2026: ADHD, double-blind](https://europepmc.org/articles/PMC13745793)
- [Westwood 2025 meta-analysis](https://pubmed.ncbi.nlm.nih.gov/39661381/)
- [Schabus 2017: insomnia, real vs placebo training](https://pmc.ncbi.nlm.nih.gov/articles/PMC5382955/)
- [Maaz 2026: alpha rises with any feedback](https://doi.org/10.1111/psyp.70285)
- [Maaz 2025 preprint: double-blind follow-up](https://arxiv.org/abs/2509.10046)
- [Belinskaia 2020: feedback delay test](https://publications.hse.ru/mirror/pubs/share/direct/424296808.pdf)
- [Dhindsa 2018: slow tightening](https://experts.mcmaster.ca/scholarly-works/1614032)
- [Lansbergen 2011: fast auto-threshold failed](https://pmc.ncbi.nlm.nih.gov/articles/PMC3051071)
- [Paluch 2017: muscle mistaken for brain](https://www.frontiersin.org/articles/10.3389/fnhum.2017.00119/full)
- [Yeh 2021 meta-analysis](https://www.frontiersin.org/articles/10.3389/fnhum.2020.562360/full)
- [Thibault & Raz 2017: why both groups improve](https://pubmed.ncbi.nlm.nih.gov/29016171/)
- [Takabatake 2021: noise over music that clears](https://pmc.ncbi.nlm.nih.gov/articles/PMC8553721)
- [SoundGuys: Bluetooth delay on Android](https://www.soundguys.com/android-bluetooth-latency-22732/)

## Libraries and models

- No outside library in the page: the browser's built-in Web Audio makes the sound; the feedback core is this
  project's own code (MIT).
- [flutter_soloud](https://github.com/alnitak/flutter_soloud) (MIT): the sound engine for the phone app.
- [Oboe](https://github.com/google/oboe) (Apache-2.0): Android's low-delay audio library.
- [MNE-RT](https://github.com/mne-rt-org/mne-rt) (BSD-3): open neurofeedback protocols, used as a reference.

Checked: 2026-11-18
