# YASA sleep staging on one BrainBit back-of-head channel

Researched 2026-11-17. Code below was run in a scratch venv (Python 3.13.18, yasa 0.8.1, mne 1.13.2,
lightgbm 4.7.0, scikit-learn 1.9.1, numpy 2.5.5, antropy 0.2.3, pyEDFlib 0.1.42).

## Answer in 5 lines

1. YASA 0.8.1 (25 Oct 2026, BSD-3-Clause) stages sleep from one EEG channel: `yasa.SleepStaging(raw, eeg_name="O1-T3").predict()`.
2. Pass an MNE Raw; YASA resamples 250 Hz to 100 Hz itself and reads the data in µV through MNE, so the units in the BDF header must be right.
3. With only `eeg_name` it loads `clf_eeg_lgb_0.5.0.joblib`, a LightGBM model trained in 2021 on central channels (C4-M1 / C3-M2) from about 3,000 NSRR nights.
4. The paper reports 85.1% median accuracy (kappa 0.78) for EEG-only on central PSG channels; no one has published YASA on occipital or O1-T3 channels.
5. Expect roughly 60-75% five-stage accuracy (kappa about 0.45-0.65) on the BrainBit (inferred). Wake/sleep and N3 will be better than that, N1 and REM worse. Check it against our own scored nights before trusting it.

## Evidence

### Version and licence

- **[verified]** Latest PyPI release is **0.8.1**, files uploaded 2026-10-25; `license_expression` = `BSD-3-Clause`;
  `requires_python >=3.11`; requires `lightgbm>=4.6`, `scikit-learn>=1.6.1`, `mne>=1.10`, `antropy>=0.1.9`,
  `numpy>=2.2.2`, `pandas>=2.3`, `pooch>=1.8`. Source: https://pypi.org/pypi/yasa/json
- **[verified]** The LICENSE file on GitHub is the BSD 3-Clause License, "Copyright (c) 2018, Raphael Vallat". It allows MIT-app
  use and redistribution if we keep the notice and do not use his name for endorsement.
  https://raw.githubusercontent.com/raphaelvallat/yasa/master/LICENSE (the installed wheel ships the same text in
  `yasa-0.8.1.dist-info/licenses/`).
- **[verified]** Changelog: 0.8.0 (Oct 2026) **removed `SleepStaging.predict_proba`**. Probabilities are now in `hyp.proba`.
  The same release dropped the old 0.4.0 classifiers and requires Python ≥ 3.11. 0.8.1 fixed a pandas 3.1 warning in
  SleepStaging. https://raw.githubusercontent.com/raphaelvallat/yasa/master/docs/changelog.rst

### The exact API in 0.8.1 (read from the installed `yasa/staging.py`)

- **[verified]** Constructor: `SleepStaging(raw, eeg_name, *, eog_name=None, emg_name=None, metadata=None)`.
  `raw` must be an `mne.io.BaseRaw`. `eeg_name` must be a channel name that already exists in `raw`, so derive bipolar channels
  first. `metadata` is optional, e.g. `{"age": 35, "male": 1}`.
- **[verified]** Sampling rate: asserts `sfreq > 80`. If `sfreq != 100` it calls `raw.resample(100, npad="auto")`, so 250 Hz
  is fine as-is. It raises an error under 30 s of data and logs a warning under 5 min.
- **[verified] Units:** `raw_pick.get_data(units=dict(eeg="uV", ...))`. YASA asks MNE for µV, and MNE stores volts
  internally. So: (a) BrainBit NeuroSDK2 delivers **volts** (README of `neurosdk2` 1.0.21 on pub.dev: "The values come in
  volts", `o1 … double, value of O1 channel in V`). (b) Our `scripts/to_bdf.py` multiplies by 1e6 and writes
  `dimension="uV"`, so `mne.io.read_raw_bdf` scales it back to volts correctly. (c) If you build a `RawArray` by hand, give it
  **volts**. Giving it µV makes YASA see values a million times too large. In my test that changed the hypnogram (see the run output below).
  The FAQ says a bare numpy array would have to be µV, but SleepStaging accepts only Raw.
  https://raw.githubusercontent.com/raphaelvallat/yasa/master/docs/faq.rst
- **[verified]** Do not filter or z-score beforehand (docstring: "Do NOT transform … or filter the signal"). YASA band-passes
  0.4-30 Hz internally, so the big DC offset of the Fpz-referenced BrainBit signal does no harm. My BDF test had a 50 mV offset.
- **[verified]** Features: per 30-s epoch it computes std, IQR, skew, kurtosis, zero crossings, Hjorth, band powers (0.4-1, 1-4,
  4-8, 8-12, 12-16 and 16-30 Hz), ratios (delta/theta, delta/sigma, delta/beta, alpha/theta), absolute 0.4-30 Hz power, permutation
  entropy, Higuchi and Petrosian fractal dimensions. Each also gets a 7.5-min centred triangular smoothing and a 2-min past mean,
  both robust-scaled (5-95 %) **within the recording**. It adds `time_hour` and `time_norm`. EEG-only gives 65 features.
  `get_features()` returns this DataFrame.
- **[verified]** Classifier choice (`_load_model`): the name is built as `clf_eeg` + `+eog` + `+emg` + `+demo` (if metadata). The highest
  version file `<name>_lgb_*.joblib` in `yasa/classifiers/` is loaded. With only `eeg_name` → **`clf_eeg_lgb_0.5.0.joblib`**
  (the run log confirms this). The wheel ships 8 classifiers, all version 0.5.0 (about 3.4 MB each).
- **[verified]** Model contents (inspected with joblib): `lightgbm.sklearn.LGBMClassifier`, booster format `version=v4`,
  400 trees, classes `N1 N2 N3 R W`, class weights `{N1: 2.2, N2: 1, N3: 1.2, R: 1.4, W: 1}`. Loading it under scikit-learn
  1.9.1 emits **`InconsistentVersionWarning: Trying to unpickle estimator LabelEncoder from version 0.24.2`**. YASA's own
  pyproject silences it in tests ("The pre-trained classifiers bundled with YASA were pickled with an older scikit-learn").
  Predictions ran fine with lightgbm 4.7.0. Pin versions in our requirements anyway (yasa==0.8.1, lightgbm, scikit-learn),
  because a future scikit-learn could break the unpickling.
  https://raw.githubusercontent.com/raphaelvallat/yasa/master/pyproject.toml
- **[verified]** `predict(path_to_model="auto")` returns a `yasa.Hypnogram`. Use `hyp.hypno` for the stages as strings (WAKE/N1/N2/N3/REM),
  `hyp.proba` for a DataFrame of per-epoch probabilities, and `hyp.as_int()` for 0-4 codes. Per-epoch confidence is `hyp.proba.max(axis=1)`. If the Raw has
  `meas_date`, the hypnogram is timestamped. You can pass your own LightGBM model through `path_to_model`. Its
  `feature_name_` must match the features exactly.
- **[verified]** Docstring warnings: the model was trained only on full nights (naps need checking), on PSG, and
  "sub-optimal PSG system and/or referencing" needs full manual inspection. N1 is the weakest stage.

### What the classifier was trained on

- **[verified]** The yasa_classifier README lists the NSRR training datasets **CCSHS, CFS, CHAT, HomePAP, MESA, MrOS, SHHS**. Testing set 1 =
  NSRR, testing set 2 = DREEM (DOD-H/DOD-O, PSG with consensus of 5 scorers).
  https://raw.githubusercontent.com/raphaelvallat/yasa_classifier/master/README.md
- **[verified]** The docstring says "~3000 nights" and recommends a central electrode: "C4-M1, C3-M2" or "C4-Fpz".
- **[inferred]** The paper's training used a single central EEG (C4-M1 or C3-M2), left EOG and chin EMG, according to the docstring and
  the GitHub issue #40 reply ("only a single EEG channel is supported, preferentially C4-M1 or C3-M2") as quoted in a search snippet.
  I could not open the paper itself (blocked here).

### Published accuracy (Vallat & Walker 2021, eLife 10:e70092)

All **[inferred]**: these come from web-search snippets of the eLife/PMC text. Those hosts were blocked, so I could not open them.
- 585 testing nights, full model: median accuracy **87.46%**, kappa **0.819**, MCC 0.821.
- **EEG-only: median accuracy 85.12%, kappa 0.782.** EEG + EOG: 86.92%, kappa 0.809.
- Dreem consensus sets: 86.6% in healthy adults and 84.3% (kappa about 0.77) in OSA patients. Not different from individual human scorers.
- The FAQ (verified) says "~85% against expert consensus" and "should not replace human scoring".

### Evidence from sites other than C3/C4

- **[verified, my own run, small]** On YASA's old sample files (from the v0.4.0 tag on GitHub) I used the EEG-only classifier, one
  channel at a time, against the human hypnogram (script `run_sites.py` below):
  - 6-h night, 720 epochs, reference unknown: C4 acc 0.733 / kappa 0.623; C3 0.728 / 0.613; F4 0.742 / 0.634;
    Pz 0.707 / 0.586; P4 0.706 / 0.589; P3-P4 bipolar 0.689 / 0.576. Sleep/wake accuracy was 0.87-0.91 everywhere.
    Per-stage F1 (W, N1, N2, N3, REM): C4 0.39/0.05/0.76/0.88/0.74; Pz 0.38/0.04/0.74/0.86/0.69; P3-P4 0.45/0.08/0.76/0.89/0.63.
    Parietal costs only 2-4 accuracy points on this night, and **REM suffers most** in the bipolar derivation.
  - 49-min nap (sub-02, 98 epochs, no REM): C3 0.847 / 0.780; F3 0.816 / 0.740; **O1 0.735 / 0.628; O2 0.694 / 0.581;
    O1-O2 bipolar 0.592 / 0.446**; C4 0.673 / 0.546. Sleep/wake 0.95-0.97 for O1/O2/O1-O2.
  - These are one person per file with wet PSG electrodes, so they say nothing statistical. Occipital lost about 0.15 kappa against C3,
    and the short O1-O2 bipolar lost more.
- **[inferred]** No published validation of YASA on occipital channels, ear-EEG, Muse or BrainBit turned up (searched 2026-11-17).
- **[inferred]** Frontal wearable evidence, from search snippets:
  - Parry & Briganti 2026 (medRxiv preprint) ran YASA vs Dreamento on ZMax F7-Fpz at home, n=100. 10% of recordings failed outright.
    In degraded recordings kappa was 0.330 (YASA) vs 0.414. Up to 0.84 was reported in good subjects. The authors say "channel topology is the
    primary limiting factor".
  - Salfi et al. 2025/2026 (bioRxiv, J Sleep Res) ran ZMax fronto-mastoid with YASA as one of four models. The ensemble reached 88.8% /
    kappa 0.84. YASA alone was the weakest of the four. I could not see its own numbers; one snippet's "85.12% / 0.78" looks like
    the eLife figure, so I did not use it.
- **[inferred]** Non-YASA single-channel literature: Sleep-EDF Pz-Oz models score a few points below Fpz-Cz. In-ear EEG reaches
  about 74% / kappa 0.61 at home (review arXiv 2510.07960).

### BrainBit montage

- **[verified]** NeuroSDK2 (Flutter `neurosdk2` 1.0.21): 4 channels O1, O2, T3, T4 at 250 Hz, values in volts; the channel-id
  enum includes `fpZ`. https://pub.dev/api/archives/neurosdk2-1.0.21.tar.gz (README.md, lib/)
- **[inferred]** The BrainBit Developer Zone (from a search snippet, site blocked here) says "FpZ – reference electrode, GND – common electrode",
  both on the forehead. It recommends the bipolar pairs **O1-T3 and O2-T4** when blinks are not needed. So the raw O1 is really
  O1-Fpz, a long front-to-back derivation. It picks up eye movements and frontal slow waves, which may help REM and N3 (much as YASA's
  C4-Fpz option does), but also blinks and frontal muscle artefacts.

### Which channel to feed YASA (inferred)

- **O1 or O2 as recorded (= O*-Fpz)** is the first choice. It is long-range, closest in spirit to the "C4-Fpz" the docstring allows, and it
  keeps eye-movement and frontal delta content that EEG-only YASA otherwise lacks. Then try **O1-T3** (BrainBit's own suggestion: less
  eye artefact, less signal). Avoid **O1-O2** (short distance, low amplitude, worst in my nap test).
- Choose the better contact per night. Do not average O1 and O2 blindly.
- Expected accuracy (**inferred**): central PSG EEG-only gives about 85% / 0.78. Each step away costs accuracy: occipital site (about −0.1 to −0.15
  kappa on my nap), dry electrodes at home with movement (about −0.1 or more; ZMax degraded nights reached 0.33), and different absolute power
  (only partly offset by YASA's per-night robust scaling). Put together, a realistic five-stage figure for a good BrainBit night is
  **60-75% accuracy, kappa about 0.45-0.65**, with **sleep/wake about 85-90%**. N3 should be reasonable, REM will often be confused
  with N1/Wake, and N1 will be near useless. Bad-contact nights will be much worse. Use `hyp.proba` and check signal quality first.

### Code (run 2026-11-17)

Minimal call on a synthetic 1-h, 250 Hz single channel (abridged from `run_min.py`; the full script was run, and this abridged form uses the same calls):

```python
import logging, mne, numpy as np, yasa
logging.getLogger("yasa").setLevel(logging.INFO)          # logs which classifier file is used
sf = 250.0; n = int(3600 * sf); rng = np.random.default_rng(0)
sig_uv = 30 * rng.standard_normal(n)                      # (run used pink noise + alpha + slow waves)
raw = mne.io.RawArray(sig_uv[None] * 1e-6,                # MNE wants VOLTS
                      mne.create_info(["O1-T3"], sf, ["eeg"]))
sls = yasa.SleepStaging(raw, eeg_name="O1-T3")            # EEG only -> clf_eeg_lgb_0.5.0.joblib
feat = sls.get_features()                                 # (120 epochs, 65 features)
hyp = sls.predict()                                       # yasa.Hypnogram
print(hyp.hypno.value_counts(), hyp.proba.head(), hyp.proba.max(axis=1).mean(), hyp.as_int().head())
```

Output (excerpt):
```
yasa 0.8.1 mne 1.13.2
INFO | Using pre-trained classifier: .../yasa/classifiers/clf_eeg_lgb_0.5.0.joblib
InconsistentVersionWarning: Trying to unpickle estimator LabelEncoder from version 0.24.2 when using version 1.9.1 ...
<SleepStaging | 1 x 360000 samples (60.0 minutes), 100.0 Hz>
features: (120, 65)
Hypnogram {'WAKE': 79, 'N1': 16, 'REM': 15, 'N2': 9, 'N3': 1}
same signal but units wrong (uV put in a volts slot): {'WAKE': 82, 'REM': 23, 'N1': 15, 'N2': 0, 'N3': 0}
```
(The stages are meaningless; the signal is synthetic. The point is that the calls work, and that wrong units change the output.) It took about 11 s on CPU for 1 h.

Project pipeline: a BDF+ written exactly like `scripts/to_bdf.py`, read back and staged (`run_bdf.py`, run):

```python
import mne, yasa
raw = mne.io.read_raw_bdf("night.bdf", preload=True)      # header says uV -> MNE scales to V
raw = mne.set_bipolar_reference(raw, anode=["O1", "O2", "O1"], cathode=["T3", "T4", "O2"],
                                 ch_name=["O1-T3", "O2-T4", "O1-O2"], drop_refs=False)
for ch in ["O1", "O1-T3", "O2-T4", "O1-O2"]:
    hyp = yasa.SleepStaging(raw, eeg_name=ch).predict()   # optionally metadata=dict(age=.., male=..)
    hyp.hypno.to_csv(f"hypno_{ch}.csv")
    conf = hyp.proba.max(axis=1)                          # flag epochs < ~0.5 as low confidence
```
It ran on a synthetic 1-h 4-channel BDF with a 50 mV common offset. All derivations staged without error, and white noise was scored as mostly WAKE.

The per-site comparison script (`run_sites.py`) loads `data_full_6hrs_100Hz_9channels.npz` (µV, multiplied by 1e-6 into a RawArray)
and `sub-02_mne_raw.fif` with their hypnograms from `raw.githubusercontent.com/raphaelvallat/yasa/v0.4.0/notebooks/`. It scores each
channel with `accuracy_score`, `cohen_kappa_score` and `f1_score` from scikit-learn. Scratch copies of all three scripts:
`/tmp/claude-0/-home-user-eeg-tracker/a9aeea07-67bc-507d-952f-acf3d1a49173/scratchpad/yasa/` (not kept in the repo).

## Could not verify

- The eLife / PMC / bioRxiv full text: elifesciences.org, PMC, bioRxiv and medRxiv were all blocked by this session's network. The accuracy numbers come from search
  snippets: 87.46% / 0.819; EEG-only 85.12% / 0.782; 86.6% and 84.3% on Dreem.
- The exact training derivations per NSRR cohort, and whether any training nights used non-central EEG.
- YASA's own numbers in the ZMax ensemble paper (Salfi et al.) and the full methods of Parry & Briganti 2026.
- The BrainBit Developer Zone page on the Fpz reference and GND placement (sdk.brainbit.com blocked; known only from a search snippet).
- GitHub issue #40 text (github.com HTML blocked; only a search snippet).
- Any study of YASA on occipital, ear-EEG, Muse or BrainBit data. None was found.
- The reference montage of YASA's 9-channel sample night.

## Sources (all accessed 2026-11-17)

- PyPI JSON: https://pypi.org/pypi/yasa/json
- LICENSE: https://raw.githubusercontent.com/raphaelvallat/yasa/master/LICENSE
- Changelog: https://raw.githubusercontent.com/raphaelvallat/yasa/master/docs/changelog.rst
- FAQ: https://raw.githubusercontent.com/raphaelvallat/yasa/master/docs/faq.rst
- pyproject: https://raw.githubusercontent.com/raphaelvallat/yasa/master/pyproject.toml
- Source read from the installed wheel: `yasa/staging.py`, `yasa/__init__.py`, `yasa/classifiers/*.joblib` (yasa-0.8.1-py3-none-any.whl)
- Training code / datasets: https://raw.githubusercontent.com/raphaelvallat/yasa_classifier/master/README.md
- Sample data and hypnograms: https://raw.githubusercontent.com/raphaelvallat/yasa/v0.4.0/notebooks/ (data_full_6hrs_100Hz_9channels.npz, data_full_6hrs_100Hz_hypno_30s.txt, sub-02_mne_raw.fif, sub-02_hypno_30s.txt, 14_automatic_sleep_staging.ipynb)
- Vallat & Walker 2021, eLife 10:e70092: https://elifesciences.org/articles/70092 (via search snippets only)
- Parry & Briganti 2026 medRxiv: https://www.medrxiv.org/content/10.64898/2026.06.01.26354591v1.full.pdf (snippets only)
- Salfi et al., ensemble on ZMax: https://www.biorxiv.org/content/10.1101/2025.07.21.665164v1.full ; https://onlinelibrary.wiley.com/doi/10.1111/jsr.70282 (snippets only)
- Wearable sleep-staging review: https://arxiv.org/pdf/2510.07960 (snippets only)
- YASA issue #40: https://www.github.com/raphaelvallat/yasa/issues/40 (snippet only)
- BrainBit NeuroSDK2 Flutter package 1.0.21: https://pub.dev/api/archives/neurosdk2-1.0.21.tar.gz
- BrainBit Developer Zone: https://sdk.brainbit.com/sdk2_bb/ (snippet only)
