# Sound for states (binaural beats, isochronic tones, pulsed noise)

## What it does

Pick a state (fall asleep, relax, focus, break, wake up) and a kind of sound. If the headband is recording, the
page first measures a quiet minute, then shows what your brain does during the sound. A "no beat" option at the
same loudness lets you compare.

## Evidence for this headband: weak

The hearing part of the brain reliably follows a pulse, but no kind of sound has strong evidence that it moves
your whole brain into a chosen state.

## What the research says

- Binaural beats (a slightly different tone in each ear) exist only inside the brainstem and need stereo
  headphones. Isochronic tones (a tone switched on and off) and pulsed noise carry the pulse in the sound itself
  and work on a speaker.
- The hearing area's echo of a pulse is stronger for pulses in the sound than for binaural beats, yet in a
  16-person study people felt no more relaxed with either.
- Of 14 binaural-beat EEG studies, 5 support brain-wave "entrainment" (the brain falling into step), 8 contradict
  it and 1 is mixed; none showed it in the focus (beta) range.
- Nature sounds lowered stress by a medium amount across 36 publications (g = -0.60; g is an effect
  size where about 0.2 is small, 0.5 medium and 0.8 large), helping stressed people
  most and slightly bothering people already relaxed.
- Pink noise (a soft, rain-like hiss) for falling asleep was positive in 9 of 11 small studies, but reviewers
  rate the evidence weak or very low.
- White or pink noise helps people with ADHD a little (g = 0.25) and slightly hurts everyone else (about -0.21).
  Focus music pulsed 16 times a second rests on one company-run paper with a borderline result.

## Where the data does not support it

- "Puts your brain into alpha / theta / delta", "boosts memory", "treats insomnia, anxiety or ADHD", "clinically
  proven", "40 Hz for brain health": none is supported, and the app never says them.
- An audit of about 7,000 online binaural tracks found only 7.5% delivered what listeners expected.
- No direct sound study exists for short breaks or for waking up.
- The two trials claiming beats add something to music are industry-linked, and one had no music-only group.
- The sound can fake its own result: the brain's echo shows up at the pulse rate, and a tone leaking from earbuds
  can land in the alpha band of the recording (a 240 Hz tone shows as 10 Hz at 250 samples a second).
- Finding which sound works for you takes about 3-6 weeks of daily sessions per state; a 2-minute difference in
  time to fall asleep is barely detectable in a month.

## How the app uses this

- Presets: Fall asleep (a beat sliding from 10 to 3 Hz over 30 min, long fades), Relax (10 Hz), Focus (16 Hz
  pulsed noise), Break (10 to 8 Hz, 5 min, eyes closed), Wake up (10 to 18 Hz), and No beat (compare).
- Every kind of sound is scaled to the same loudness, so "beat or no beat" is not "louder or quieter".
- Tone pitch is limited to 150, 200, 300 or 400 Hz: no tone between 220 and 280 Hz, which would fold into the
  brain-wave bands at 250 samples a second.
- Soft pulse edges (about 12 ms), slow fades in and out (45 s in and 90 s out for sleep), no hard stops.
- A quiet minute first, when the headband is recording. The readout compares alpha and slow waves with that
  minute and leaves out the beat rate ± 1 Hz, because the brain's echo of the beat would otherwise count as
  "more alpha".
- Each session's settings go into the recording as markers, for later comparison.
- Planned: calm sound beds (nature, pink or brown noise, music you like) as the default with beats as optional
  extras; the sleep preset stopping itself once you fall asleep; a rating after each session; a personal
  comparison over weeks.
- Keep the volume low, never while driving, and prefer a speaker to earbuds overnight.

## Sources

- [Binaural beats review, 14 studies (Ingendoh 2023)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10198548/)
- [Orozco Perez 2020: monaural vs binaural echo](https://www.eneuro.org/content/7/2/ENEURO.0232-19.2020)
- [Nature sounds review summary (Buxton 2021)](https://carleton.ca/biology/2021/prof-rachel-buxtons-research-finds-nature-sounds-can-alleviate-stress-improve-mood-and-enhance-cognitive-performance/)
- [Gould van Praag 2017: natural sounds and stress](https://pmc.ncbi.nlm.nih.gov/articles/PMC5366899)
- [Pink noise for sleep (Capezuti 2022)](https://pubmed.ncbi.nlm.nih.gov/34964434)
- [Noise as a sleep aid (Riedy 2021)](https://www.em-consulte.com/article/1421191/article/noise-as-a-sleep-aid-a-systematic-review)
- [Noise and attention (Nigg 2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11283987/)
- [Brain.fm pulsed music (Woods 2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11499863/)
- [ICWSM 2025 audit of online binaural tracks](https://ojs.aaai.org/index.php/ICWSM/article/view/35806)
- [Alarm sounds and grogginess (McFarlane 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC6986749)
- [Mallik and Russo 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8906590)
- [Venkatesan 2025](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2025.1539823/full)
- [Audio leaking into EEG (Campbell et al.)](https://pmc.ncbi.nlm.nih.gov/articles/PMC3214253)
- [Thompson sampling in practice (Meier 2023)](https://arxiv.org/abs/2309.14156)
- [WHO-ITU safe listening standard](https://www.who.int/publications-detail/safe-listening-devices-and-systems-a-who-itu-standard)

## Libraries and models

- No outside library in the page: the browser's built-in Web Audio makes every sound.
- [flutter_soloud](https://github.com/alnitak/flutter_soloud) (MIT): the sound engine for the phone app.
- [Ambio](https://github.com/jaimebg/Ambio) (CC0 sound recordings): a source of nature sounds that may be shipped.
- [SBaGenX](https://github.com/lm7137/SBaGenX) and the other open beat generators are GPL: ideas only, no code
  copied.

Checked: 2026-11-18
