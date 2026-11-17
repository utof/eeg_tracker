# AnySleep: sleep staging from any EEG/EOG channels

Researched 2026-11-17. Repository read at commit `88e13e3` (2026-11-11).

## Answer in 5 lines

1. AnySleep is real and public: code and trained weights are at github.com/dslaborg/AnySleep; the paper is arXiv 2512.14461 (Dec 2025), now in npj Digital Medicine 9:829 (2026).
2. Code and weights are both MIT: the weights (`models/*.pth`, about 12 MB each) are in the same repo under its single MIT `LICENSE`, so we can use them in an MIT app.
3. To run it: Python 3.11, PyTorch, MNE; load the BDF, resample to 128 Hz, clip at 20 x IQR, robust-scale each channel, feed a `(1, time, channels)` tensor; a CPU is enough for one night (the model is ~12 MB).
4. Output is 5 logits per 30 s epoch (Wake, N1, N2, N3, REM), or finer if you ask for several predictions per epoch; the example saves them as a `.npy` file.
5. Mean macro-F1 is about 0.68 with one channel, rising to about 0.73 with four, and about 0.80 with full PSG. None of the training data used dry electrodes or a BrainBit-style reference, so expect lower scores for us. We have to check it against our own nights.

## Evidence

### Repository, paper and licence

- **[verified]** Repo `https://github.com/dslaborg/AnySleep` (cloned; GitHub web/API pages were not reachable from this session, `git clone` was). README cites: Grieger N., Raskob J., Mehrkanoon S., Bialonski S. "AnySleep: a channel-agnostic deep learning system for high-resolution sleep staging in multi-center cohorts", *npj Digit. Med.* 9, 829 (2026), doi:10.1038/s41746-026-03406-7 (BibTeX month: October 2026).
- **[inferred]** arXiv preprint 2512.14461, submitted 16 Dec 2025. Source: search-result snippets only. arxiv.org and nature.com were blocked from this session, so I could not open the paper.
- **[verified]** `LICENSE` is the plain MIT text, "Copyright (c) 2026 dslaborg". README: "This project is released under the MIT License."
- **[verified]** Weights ship inside the repo in `models/`: `anysleep-run{1,2,3}.pth` (mid fusion, the main model, 12.8 MB each), `anysleep-early-fusion-run*.pth`, `anysleep-late-fusion-run*.pth`, `usleep-run*.pth`. There is no separate weights licence, model card or extra terms file. **[inferred]** The repo MIT licence therefore covers the weights. The training data come from NSRR and other datasets that have their own data-use agreements. Those agreements bind the data, not the weights, but a cautious reader may want to check them.
- **[verified]** Results archive (sweep logs, predictions): Zenodo doi:10.5281/zenodo.23764134 (zenodo.org itself was blocked here).
- **[verified]** Hosted web app: SomnoBot, somnobot.fh-aachen.de (named in README; the page itself was not opened).

### Install

**[verified]** These steps are in the README; I did not run them:

```bash
git clone https://github.com/dslaborg/AnySleep.git && cd AnySleep
mamba create -n anysleep python=3.11 && mamba activate anysleep
pip install -r requirements.freeze.txt   # pins torch==2.15.0, mne==1.13.2, numpy==2.4.6, scipy==1.17.1, scikit-learn==1.9.1
# if torch cannot see the GPU: install torch from pytorch.org, then pip install -r requirements.txt
```

For inference alone, the needs are `torch numpy scipy scikit-learn mne` (plus `matplotlib` for the example's plot). Hydra and h5py are only needed for training and evaluation. **[verified]** from the imports of `examples/predict_edf_file_logits_plain.py` and `examples/anysleep_no_hydra.py`.

### Input the model expects (read from code)

- **[verified]** The sampling rate must be **128 Hz**. `AnySleep.__init__` hard-codes `sampling_rate = 128` and `epoch_length = 3840`. The example resamples with `scipy.signal.resample_poly(data, 128, sfreq, axis=1)`; 250 → 128 Hz becomes `resample_poly(x, 64, 125)`.
- **[verified]** No band-pass filtering is applied. Preprocessing is:
  1. per channel, clip to ±20 × IQR (the example code clips around 0, not around the median);
  2. `sklearn.preprocessing.RobustScaler` on each channel (subtract the median, divide by the IQR).
- **[verified]** Because of the robust scaling, the units do not matter (V or µV): the line converting to microvolts is commented out.
- **[verified]** Tensor shape is `(batch, time, channels)`. The docstring: "Time should be divisible by (3840 / sleep_stage_frequency)". The example script does **not** crop, so crop to whole 30 s epochs yourself.
- **[verified]** Channel names and types are not given to the model. Each channel runs through the shared encoder separately, and attention blocks (softmax over channels) merge them. Any count from 1 upward works.
- **[verified]** Training and test configs used referenced derivations, including O1/O2 and T3/T4. For example, `config/exp002/run.md` evaluates MASS with `O1-CLE, O2-CLE, T3-CLE, T4-CLE, ... T3-LER, T4-LER` and DOD with `F4-O2, F3-O1`.
- **[inferred]** Occipital and temporal sites are therefore "seen" positions, but always as wet PSG electrodes against a mastoid or ear reference. BrainBit's dry electrodes and its own reference are new to the model.
- **[verified]** Weights load with `torch.load(path, map_location="cpu", weights_only=True)`, which is safe loading with no pickle code execution.

### Output

- **[verified]** `model(x)` returns logits of shape `(batch, epochs, 5)`, in class order **0 Wake, 1 N1, 2 N2, 3 N3, 4 REM**. The example writes `prediction_<file>.npy` containing `(1, epochs, 5)` and plots a hypnogram with softmax probabilities.
- **[verified]** `sleep_stage_frequency` (1, 2, 4, … 3840) gives several predictions per 30 s epoch. 3840 means one prediction per sample.
- **[verified]** The repo's `predict-30s-from-high-freq.py` combines fine-grained predictions back into 30 s labels by hard or soft voting.

### Hardware

- **[inferred]** The model is about 12.8 MB of weights (around 3M parameters), a U-Sleep-style 1-D CNN of depth 12. A whole night at 128 Hz with 4 channels is about 14.7 M samples. On a CPU that should take seconds to about a minute and a few GB of RAM at most; a 6 GB GPU should be enough.
  The paper says compute grows linearly with channel count, where U-Sleep grows quadratically (search-result summary, not opened).
  Not measured: torch could not be installed in this session (download.pytorch.org was blocked, and the PyPI wheel brings in gigabytes of CUDA libraries). If GPU memory runs out, cut the night into pieces of a few hours, padded with about 5 minutes of context, and run `device="cpu"`.

### Reported accuracy per channel configuration

All numbers below are **[verified]** from the outputs saved in the repo's notebooks (`scripts/final-figures/*.ipynb`), not from the paper text, which I could not open.

- **Number of channels.** Mean macro-F1 over all datasets and channel combinations (`fig_s2.ipynb`):

  | Channels | Macro-F1 |
  |---|---|
  | 1 | 0.684 |
  | 2 | 0.713 |
  | 3 | 0.726 |
  | 4 | 0.732 |
  | 5 | 0.736 |
  | 9 | 0.740 |
  | 18 | ~0.745 |

  Channels unseen in training scored the same as seen ones: 0.684 vs 0.684 with 1 channel, 0.734 vs 0.732 with 4.
- **Fixed "full" configuration, mid-fusion AnySleep** (`table_1.ipynb`, Table 1):
  - mean macro-F1 0.812 on the 13 training-cohort test sets;
  - 0.777 on the external datasets (DOD-H 0.83, DOD-O 0.79, ISRUC 0.74–0.78, MASS 0.74/0.80, SVUH 0.74);
  - U-Sleep scored 0.799 / 0.768 on the same sets.
- **Per stage** (`table_s1_s2-fig_s1.ipynb`, in-distribution means):

  | Stage | F1 |
  |---|---|
  | Wake | 0.94 |
  | N1 | 0.55 |
  | N2 | 0.87 |
  | N3 | 0.79 |
  | REM | 0.90 |

  Mean Cohen's kappa 0.83. External sets: kappa about 0.66–0.80.
- **Night totals vs experts** (Table S4a): total sleep time −0:06 ± 0:19 (Spearman 0.97); REM −0:07 ± 0:13 (0.93); N1 underestimated by 15 min (0.50).
- **[inferred]** Single occipital channel: "macro-F1 0.710", and "0.760 for the best two-channel pairs". This comes from a search-engine summary of the paper; I could not see which dataset or averaging it uses.
- No wearable, dry-electrode or BrainBit validation appears anywhere in the repo. DOD-O/DOD-H and MASS are clinical PSG. **[verified]** from the dataset lists in the notebooks and configs.

### Known issues / caveats

- **[verified]**
  - The example script uses `mne.io.read_raw_edf`. For BDF use `mne.io.read_raw_bdf` or `mne.io.read_raw`.
  - It does not crop to whole epochs.
  - Its `device="cuda"` default fails on CPU-only machines.
  - The README warns that the frozen requirements may not find your GPU.
- **[verified]** The repo is a research codebase (Hydra configs, HDF5 data format from the companion `dslaborg/Sleep-Datasets` repo). There is no pip package and no CLI.
- **[could not verify]** The GitHub issue tracker: the GitHub web and API were blocked for this repository in this session.
- **[inferred]** Things to watch on BrainBit data:
  - The dry-electrode signal is noisier. The 20 × IQR clipping guards against rare spikes, but long stretches of lost contact (rail at ±0.4 V) will skew the robust scaling. Mask or zero those stretches, or drop that channel for the night, using the contact-quality flags from `to_bdf.py`.
  - T3/T4 pick up jaw muscle (EMG), which may actually help with Wake and REM.

### Minimal example for a 4-channel BrainBit BDF (not run)

Save as `predict_brainbit.py` inside `AnySleep/examples/`, so that `anysleep_no_hydra` is importable:

```python
"""AnySleep on a BrainBit BDF/EDF (O1 O2 T3 T4, 250 Hz). Not run: torch was unavailable in the research session."""
import sys
import numpy as np, torch, mne
from scipy.signal import resample_poly
from sklearn.preprocessing import RobustScaler
from anysleep_no_hydra import AnySleep

path = sys.argv[1]
raw = mne.io.read_raw(path, preload=True)            # read_raw_bdf / read_raw_edf picked from the extension
raw.pick(["O1", "O2", "T3", "T4"])                    # any subset works, e.g. ["O1"] alone
x = raw.get_data()                                    # (4, n) in volts; units do not matter after scaling
fs = int(raw.info["sfreq"])                           # 250
x = resample_poly(x, 128, fs, axis=1)                 # -> 128 Hz (scipy reduces 128/250 to 64/125)
for c in range(x.shape[0]):                           # clip at 20 x IQR, as in the repo
    iqr = np.subtract(*np.percentile(x[c], [75, 25]))
    x[c] = np.clip(x[c], -20 * iqr, 20 * iqr)
x = RobustScaler().fit_transform(x.T).T
n_ep = x.shape[1] // 3840
x = x[:, : n_ep * 3840]                               # whole 30 s epochs only

device = "cuda" if torch.cuda.is_available() else "cpu"
model = AnySleep(path="../models/anysleep-run1.pth", sleep_stage_frequency=1).eval().to(device)
with torch.no_grad():
    logits = model(torch.from_numpy(x.T.copy()).float().unsqueeze(0).to(device))[0].cpu().numpy()
prob = torch.softmax(torch.from_numpy(logits), dim=1).numpy()   # (epochs, 5): Wake N1 N2 N3 REM
stages = np.array(["W", "N1", "N2", "N3", "R"])[prob.argmax(1)]
np.savez("anysleep_out.npz", logits=logits, prob=prob)
print(n_ep, "epochs;", {s: int((stages == s).sum()) for s in ["W", "N1", "N2", "N3", "R"]})
```

To cross-check, run all three `anysleep-run{1,2,3}.pth` and average the probabilities. Where they disagree, show low confidence (DECISIONS.md row 8).

## Could not verify

- The paper text itself: arxiv.org and nature.com were blocked. The single-occipital 0.710 figure, the dataset list as written in the paper, the authors' stated limitations and the cost claims come from search snippets only.
- The GitHub issue tracker, so known open bugs are unknown.
- The actual runtime and memory on CPU or a 6 GB GPU: I could not install torch here.
- Licence terms on the Zenodo archive (zenodo.org blocked); it holds logs and predictions, not the weights.
- Which reference BrainBit uses for O1/O2/T3/T4. It matters for how close our signals are to the training montages.

## Sources (accessed 2026-11-17)

- https://github.com/dslaborg/AnySleep: README, LICENSE, `examples/predict_edf_file_logits_plain.py`, `examples/anysleep_no_hydra.py`, `config/exp002/run.md`, `scripts/final-figures/{table_1,table_s1_s2-fig_s1,fig_s2,table_s4a}.ipynb` (git clone, commit 88e13e3)
- https://doi.org/10.1038/s41746-026-03406-7 (cited in README; not opened)
- https://arxiv.org/abs/2512.14461 (search results only)
- https://doi.org/10.5281/zenodo.23764134 (cited in README; not opened)
- https://somnobot.fh-aachen.de (cited in README; not opened)
