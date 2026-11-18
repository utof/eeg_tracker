# The build-it-yourself helmet

## What it does

Planned. A home-built EEG helmet with 8, later 16, electrodes. Planned layout: a reference on the mid-forehead,
both mastoids (the bones behind the ears) recorded as ordinary channels, and an 8-site core of M1 M2 F7 F8 Fz C3
C4 Pz. The app learns any layout from a short setup task.

## Evidence for this helmet: some

Each site has evidence for its own job, but nobody has tested this exact mix; the layout is a planning
assumption.

## What the research says

- A shared reference at the mid-forehead (Fpz) and recording both mastoids works better for sleep: lying on one
  side spoils one side of a headband, and a mastoid reference you lie on would spoil every channel.
- The reference and bias electrodes need gel or hydrogel, not dry pins: a dry mastoid reference lost a whole night
  in a home study, and a bad forehead contact spoils every channel.
- Distance matters more than exact position: layouts with a long side-to-side channel plus an eye channel reached
  near-lab sleep agreement (0.76-0.80), while forehead-only bands topped out at 0.37-0.45.
- Forehead muscle tracked chin muscle closely during sleep (median correlation 0.98), so a chin electrode is
  optional.
- Back-of-head electrodes scored worse in a 2025 headband, possibly from pillow contact, so the 8-site layout uses
  Pz (top-back) instead of O1/O2.
- Fz (top front) earns its place for meditation: feedback there raised frontal-midline theta in a study with a
  fake-feedback control.

## Where the data does not support it

- Nobody has tested this exact 8- or 16-electrode layout.
- Frontal "mood asymmetry" (left vs right forehead): only 13 of 270 re-analyses linked it to depression.
- Sixteen channels are still too few for some standard cleaning methods or a true average reference.
- Nothing here allows connecting electrodes to a person: the hardware's own safety checks come first.

## How the app uses this

- Each tracker learns its channels from a 1-2 minute eyes-closed and eyes-open setup task; positions are optional,
  and it re-calibrates when the electrodes move. Each helmet layout gets a version number.
- A later 16-site layout keeps O1, O2, T7 and T8 (the headband's sites), so months of headband data carry over.
- The board keeps its own data format, which has error checks and a 32-bit sample counter.
- Planned checks: compare the helmet with the headband on your own nights at the shared sites, and add a
  top-of-head motion sensor.

## Sources

- [Dreem headband layout lessons (Debellemaniere 2018)](https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2018.00088/pdf)
- [Ngo 2013](https://www.inb.uni-luebeck.de/fileadmin/files/PUBPDFS/NgMaBoMo13.pdf)
- [Leach 2020: dry mastoid reference](https://www.frontiersin.org/articles/10.3389/fnins.2020.00586/full)
- [Ear-to-ear and mastoid layouts (Mikkelsen 2022)](https://ar5iv.labs.arxiv.org/html/2104.04567)
- [Forehead vs chin muscle (Levendowski 2018)](https://dovepress.com/comparison-of-emg-power-during-sleep-from-the-submental-and-frontalis--peer-reviewed-article-NSS)
- [Dry 8-site band (Wang et al. 2025)](https://europepmc.org/article/PMC/PMC12561290)
- [Frontal-midline theta feedback (Brandmeyer & Delorme 2020)](https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2020.00246/full)
- [Frontal asymmetry reanalysis (Kolodziej 2021)](https://elifesciences.org/articles/60595)
- [Referencing with few electrodes](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5859052/)

## Libraries and models

- [pyRiemann](https://pypi.org/project/pyriemann/) (BSD-3): methods that cope with changing electrode sets.
- [MNE spatial filters (SSD)](https://mne.tools/dev/auto_examples/decoding/ssd_spatial_filters.html) (BSD-3):
  learn the best channel mix from a short setup task.
- Open hardware to learn from: [OpenBCI Ultracortex Mark IV](https://docs.openbci.com/AddOns/Headwear/MarkIV/)
  (GPL-3.0) and [Cerelog ESP-EEG](https://github.com/Cerelog-ESP-EEG/ESP-EEG) (firmware MIT, hardware
  CC BY-NC-SA).

Checked: 2026-11-18
