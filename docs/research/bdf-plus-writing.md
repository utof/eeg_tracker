# Writing BDF+ (24-bit, BDF+C) files with annotations from Python

## Answer in 5 lines

1. Keep pyedflib 0.1.42 (BSD) for the converter: it is the only one of the three that writes one record at a time (8 h night: 39 MB peak memory, versus 505 MB for edfio).
2. edfio 0.4.18 (Apache-2.0) has written BDF/BDF+C since 0.4.10. MNE 1.13.2 (BSD-3) exports BDF since 1.11 with `export_raw(fmt="bdf")`, and does it through edfio. Both need the whole night in memory.
3. All three wrote a 4-channel 250 Hz BDF+C file that the other two read back correctly: `0xFF BIOSEMI`, `BDF+C`, 1 s records of 250 samples, and a `BDF Annotations` signal.
4. `scripts/to_bdf.py` produces valid files, but it has one real bug and three things to fix. The bug: pyedflib writes a start time with microseconds wrongly (it shifts the start by up to 0.9 s, or silently drops the fraction).
5. The three things: pad the last record with the edge value and add a note, not silent zeros; cut annotation text to 40 characters and check return values; never call `writeSamples` again on a chunk that is not a whole number of seconds (it inserts zeros).

## Evidence

Setup: everything below was run on 2026-11-17 in a venv in the scratch dir with Python 3.13.18, pyedflib 0.1.42, edfio 0.4.18, mne 1.13.2 and numpy 2.5.5. **The spec pages could not be opened.** The network proxy blocked edfplus.info, teuniz.net and biosemi.com (HTTP 403), as well as Wikipedia and web.archive.org. Spec statements are therefore either checked against the reference implementations I read in this session or tagged **[inferred]**. The implementations are EDFlib (vendored in the pyedflib sdist), edfio's source and EDFbrowser's `check_edf_file.c`.

### 1. Libraries: versions, licences, BDF support

| | pyedflib | edfio | MNE-Python |
|---|---|---|---|
| Latest on PyPI | 0.1.42 (uploaded 2025-06-26) | 0.4.18 (2026-10-01) | 1.13.2 (2026-09-11) |
| Licence (LICENSE file) | BSD 3-clause style: Holger Nahrstaedt, Chris Lee-Messer, Teunis van Beelen | Apache 2.0 | BSD-3-Clause, "MNE-Python authors" |
| Writes BDF+ | yes, `FILETYPE_BDFPLUS`, through the C library EDFlib (version 1.17 vendored) | yes, `Bdf`/`BdfSignal`, added in 0.4.10 (2025-10-07) | yes, `mne.export.export_raw(fname, raw, fmt="bdf")`, added in 1.11 (PR #13435). It calls edfio. |
| Can write BDF+D (discontinuous) | no, `BDF+C` is hard-coded | no, only `+C` | no (it uses edfio) |
| Writes one record at a time | yes (`blockWritePhysicalSamples`) | no (whole array) | no |
| Python | wheels cp36 to cp313 (no cp314 wheel) | >=3.9, pure Python | >=3.11 |

- **[verified]** Versions, upload times and licence classifiers come from the PyPI JSON API (`https://pypi.org/pypi/<name>/json`). I opened all three LICENSE files on GitHub. pyedflib's PyPI `license` field is just "BSD"; its LICENSE file is the 3-clause text.
- **[verified]** edfio added BDF in 0.4.10: its CHANGELOG says "Support reading and writing BDF and BDF+C files (#63)".
- **[verified]** MNE added BDF export in 1.11: the `"bdf"` key is absent from `mne/export/_export.py` at tag v1.10.0 and present at v1.11.0, and `doc/changes/v1.11.rst` says "Add support for BDF export in mne.export.export_raw … (#13435)". In 1.13.2, `mne/export/_edf_bdf.py` imports `Bdf, BdfSignal` from edfio, and a missing edfio raises "exporting to EDF". The `export_raw` docstring still lists only EDF under "Supported formats", so the docs are behind the code.
- **[verified]** EDFlib writes only `+C`: `edflib.c` prints the literal `"BDF+C"` in the header writer. It understands `BDF+D` only when reading. edfio sets `f"{self._fmt}+C"`.
- **[verified]** Install weight: the venv holding all three plus numpy/scipy/matplotlib was 288 MB. pyedflib on its own needs only numpy.

### 2. What MNE's BDF export does to your data

All of the following is **[verified]** from the `_edf_bdf.py` source (1.13.2) and the run in section 6:

- Volt channels are scaled to µV. The digital range is a symmetric `(-8388607, 8388607)`, so 0 µV maps exactly to digital 0.
- The default physical range is `"auto"`, the data's min/max per channel type. Pass `physical_range=(-400000, 400000)` for a fixed range.
- Labels longer than 16 characters raise an error.
- The prefilter field is filled from `info` (e.g. `HP:0.0Hz LP:125.0Hz`).
- If the length is not a whole number of records, MNE pads the end with **edge values** and adds a `BAD_ACQ_SKIP` annotation.
- Instantaneous annotations are written with duration `0`, not with the duration field left out.
- When reading back, MNE treats the header's local time as UTC.

### 3. Limits that matter for BrainBit (4 ch, 250 Hz)

- **24-bit digital range.** Valid values are -8388608..8388607. **[verified]** pyedflib's `check_signal_header_correct` enforces this for BDF types; EDFbrowser's checker reports "should be in the range -8388608 to 8388607"; edfio checks it since 0.4.16.
- **Precision depends on the physical range.** One digital step = (pmax - pmin) / (dmax - dmin). For ±400 000 µV (the BrainBit rail that `to_bdf.py` uses) the step is **0.0477 µV**, far below EEG noise, so a ±0.4 V range costs nothing in 24-bit. With 16-bit EDF the same range would give 12.2 µV steps, which is unusable. **[verified]** by computation and measured readback error:
  - edfio and MNE: at most ±0.5 step (0.0238 µV);
  - pyedflib/EDFlib: at most ±1 step (0.0477 µV, mean error 0.008 step over 5000 random samples). EDFlib does not round to the nearest value. This is harmless here.
- **8-character numeric fields.** Physical min/max, digital min/max, samples per record, number of records and record duration are each 8 ASCII characters.
  - **[verified]** pyedflib warns when `str(value)` is longer than 8 characters. The float `-400000.0` is 9 characters and triggers the warning even though nothing is lost. Pass the integer `400_000` instead.
  - **[verified]** edfio rounds to 8 characters: ±0.123456789 is written as `-0.12346`/`0.123457`, i.e. a slightly asymmetric range. Keep physical limits short (integers).
- **Labels are 16 characters.** **[verified]** edfio raises an error for 17 characters. pyedflib 0.1.42 accepted 17 characters without error, so presumably EDFlib truncates; I did not check the bytes. Transducer and prefilter fields are 80 characters, the physical dimension 8.
- **Annotation text length.**
  - **[verified]** EDFlib writes at most `EDFLIB_WRITE_MAX_ANNOTATION_LEN = 40` bytes. A 60-character annotation came back as 40.
  - **[verified]** edfio has no such limit: a 300-character text round-tripped. The annotation signal then grows to 104 samples per record **in every record**, because edfio sizes the channel to the largest record.
- **Annotation channel size and count (pyedflib).**
  - **[verified]** Each annotation signal holds `EDFLIB_ANNOTATION_BYTES = 114` bytes per record (38 samples × 3 bytes), i.e. one timekeeping TAL plus one annotation.
  - At `close()`, EDFlib writes annotations **one per record in the order added** (annotation k goes into record k), not into the record that contains its onset. That is legal, because onsets are absolute.
  - Annotations beyond (number of records × number of annotation signals) are **silently dropped**. Test: 15 annotations into a 10 s file came back as 10; after `set_number_of_annotation_signals(2)` all 15 came back. The maximum is 64 signals.
  - The EDFbrowser manual gives the same budget for its Biosemi converter: duration in seconds × 32.
  - Onset and duration resolution is 100 µs (`round(onset*10000)`).
- **Annotation channel (edfio).** **[verified]** edfio puts each annotation into the record that contains its onset, and sizes the channel to the fullest record (9 samples in the demo).
- **Record duration and samples per record at 250 Hz.**
  - **[verified]** Both libraries pick 1 s by default (pyedflib's `_calculate_record_duration` returns 1.0 for integer rates; edfio uses the lcm of the rates' denominators), giving **250 samples per record**.
  - Record size = 4×250×3 + annotation bytes = 3114 bytes (pyedflib) or 3027 bytes (edfio, demo). That is well under the EDF recommendation of at most 61 440 bytes per record (**[inferred]**: from memory of the EDF spec, which I could not open) and EDFbrowser's hard limit of 10 485 760 bytes (**[verified]** in `check_edf_file.c`).
  - 1 s records also make the 8-character "number of records" field good for 99 999 999 s (about 3 years).
  - If you pick another duration, pyedflib's `setDatarecordDuration` accepts 0.001–60 s.
- **File size.** 3 bytes per sample, plus the header, plus the annotation channel. **[verified]** An 8 h, 4-channel night is **89.7 MB** with pyedflib (3114 bytes/s) and 86.8 MB with edfio. The 65.3 s demo was 207 060 bytes = 1536 + 66×(3000+114).
- **Writing large files and streaming.**
  - **[verified]** pyedflib can stream: call `blockWritePhysicalSamples(buf)` once per record, where `buf` is signal 0's 250 samples, then signal 1's, and so on. Writing a synthetic 8 h night took **0.5 s with 39 MB peak RSS**; edfio, which builds the whole night in memory, needed **505 MB**.
  - **[verified]** `writeSamples()` pads its final partial record with zeros. Calling it repeatedly on chunks that are not a multiple of 250 samples **inserts zeros mid-file**: chunks of 300+300+1900 gave 3000 samples, with zeros at 300..499.
  - **[verified]** If the process dies before `close()`, the header keeps `-1` data records and all annotations are lost, because EDFlib writes them at close. pyedflib then refuses the file ("not EDF(+) or BDF(+) compliant (Number of Datarecords)"). edfio reads it and repairs the count with a warning.
- **Start date before 1985 or after 2084.**
  - **[verified]** The header date field is `dd.mm.yy`, and readers map yy > 84 to 19yy (EDFlib reader).
  - EDFlib accepts years 1970..3000 when writing and still writes `yy`. It wrote `01.06.84` for 1984 and `01.06.85` for 2085, but the recording field holds the 4-digit year, and pyedflib read back the right year.
  - edfio raises `ValueError: EDF only allows dates from 1985 to 2084`.
  - EDFbrowser refuses BDF+ files whose `Startdate` year is before 1985 ("Error, recording startdate is before 1985").
  - **[inferred]** The EDF+ rule, from memory of the spec, is: use the 4-digit year in the recording field, and treat 1985 as the clipping year for `yy`. Irrelevant for live recordings, but it matters if a phone's clock is reset to 1970.
- **Sub-second start time.**
  - **[verified]** pyedflib 0.1.42 has a bug. `setStartdatetime` passes `microsecond*100` to EDFlib's `edf_set_subsecond_starttime`, but that function expects 100 ns units in the range 0..9 999 999 (so `microsecond*10` would be correct).
  - Result: 50 000 µs was written as `+0.5000000` in the first TAL, so edfio reads the start as 23:00:00.500000. 500 000 µs fails the range check, the return value is ignored, and the start becomes 23:00:00.
  - pyedflib's own reader divides by the same wrong factor, so its round trip looks correct, which hides the bug.

### 4. What a minimal correct BDF+ header contains

The byte widths below are **[verified]**: they are edfio's `_header_fields` tables, and the bytes all three libraries produced match them field for field (hexdump in section 6). The meaning of the EDF+ subfields is **[inferred]** from memory of the EDF+ spec (edfplus.info could not be opened), and I checked it against EDFbrowser's checker and the bytes written by EDFlib, edfio and MNE.

**Fixed header (256 bytes, all ASCII, space padded, left aligned)**

| Offset | Bytes | Field | BDF+ content |
|---|---|---|---|
| 0 | 8 | version | byte `0xFF` + `BIOSEMI` (EDF uses `0       `) |
| 8 | 80 | local patient id | `code sex birthdate name [more]`, unknown = `X`. Spaces inside a subfield become `_`. Minimal: `X X X X` |
| 88 | 80 | local recording id | `Startdate dd-MMM-yyyy admincode technician equipment [more]`, e.g. `Startdate 17-NOV-2026 X X BrainBit_Black` |
| 168 | 8 | startdate | `dd.mm.yy` |
| 176 | 8 | starttime | `hh.mm.ss` (local time, no timezone) |
| 184 | 8 | bytes in header | 256 × (ns + 1), i.e. `1536` for 4 EEG signals + 1 annotation signal |
| 192 | 44 | reserved | `BDF+C` (continuous) or `BDF+D` (discontinuous) |
| 236 | 8 | number of data records | `-1` while writing, filled in on close |
| 244 | 8 | record duration (s) | `1` |
| 252 | 4 | ns (number of signals) | `5` (annotation signal included) |

**Per-signal header (ns × 256 bytes, written field by field for all signals: all labels, then all transducers, and so on)**

| Bytes | Field | EEG channel | `BDF Annotations` channel |
|---|---|---|---|
| 16 | label | `O1` | `BDF Annotations ` |
| 80 | transducer type | `dry electrode` | empty (EDFbrowser errors otherwise) |
| 8 | physical dimension | `uV` | empty |
| 8 | physical min | `-400000` | any valid number: EDFlib writes `-1`, edfio `-8388608` |
| 8 | physical max | `400000` | `1` / `8388607` |
| 8 | digital min | `-8388608` | must be `-8388608` (EDFbrowser checks this) |
| 8 | digital max | `8388607` | must be `8388607` |
| 80 | prefiltering | e.g. `HP:0.1Hz LP:100Hz` or empty | empty (EDFbrowser errors otherwise) |
| 8 | samples per record | `250` | 38 (EDFlib) / as needed (edfio) |
| 32 | reserved | empty | empty |

**Data records.** Each record is signal 0's samples, then signal 1's, and so on: 3-byte little-endian two's-complement integers. The annotation signal's "samples" are just raw bytes.

**TAL format** in the annotation signal **[verified]** (bytes taken from the produced files; edfio parses the same grammar):

- Each TAL is `+onset[0x15 duration]0x14 text 0x14` and is followed by `0x00`. Onset is in seconds from the file start and carries a sign; duration is optional.
- The first TAL of **every** record is the timekeeping TAL `+<record start>0x14 0x14 0x00`. Unused bytes are `0x00`.
- Real bytes from the pyedflib file:
  - record 0: `+0\x14\x14\x00+0\x14recording start\x14`
  - record 1: `+1\x14\x14\x00+12.5000\x153\x14gap 3.0s\x14`
- **[inferred]** The spec details beyond these bytes are from memory: text is UTF-8; the timekeeping TAL carries the sub-second start offset; with `+D`, records may have gaps and the timekeeping TAL gives each record's real start.

### 5. Validation tools

- **EDFbrowser.** **[verified]** in its manual (`doc/manual.html` on gitlab.com/Teuniz/EDFbrowser, latest tag v2.16, 2026-11-05): the "EDF(+) and BDF(+) compatibility checker" "checks the data and all the annotations and timestamps". A header check also runs whenever a file is opened. The rules I quoted above come from its `check_edf_file.c`. **I did not run EDFbrowser:** it is not in apt here and teuniz.net is blocked. The menu location (Tools menu) is **[inferred]**.
- **edfio.** `edfio.read_bdf(path)` parses the header, the TALs and the timekeeping, and warns on `-1` records.
- **MNE.** `mne.io.read_raw_bdf(path)` gives `sfreq`, channel names and annotations.
- **pyedflib.** `pyedflib.EdfReader(path)` uses EDFlib's strict reader, which rejects unfinished files.
- All three reread all three files correctly (section 6).

### 6. Runnable demo (it was run, and the output is below)

`write_bdf_demo.py`, run with `venv/bin/python -I write_bdf_demo.py <outdir>`:

```python
"""Write a 4-channel 250 Hz BDF+C file with annotations three ways, read each back, check bytes."""
import sys, warnings
from datetime import datetime, timezone
from pathlib import Path
import numpy as np, pyedflib, edfio, mne

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
FS, NAMES = 250, ["O1", "O2", "T3", "T4"]
N = int(65.3 * FS)                      # 65.3 s: deliberately NOT a whole number of 1 s records
rng = np.random.default_rng(0)
t = np.arange(N) / FS
uv = np.stack([20 * np.sin(2 * np.pi * 10 * t + k) + rng.normal(0, 5, N) for k in range(4)])  # (4, N) uV
LIM = 400_000.0                         # +-0.4 V in uV, the BrainBit rail used by scripts/to_bdf.py
START = datetime(2026, 11, 17, 23, 5, 7)
ANN = [(0.0, -1, "recording start"), (12.5, 3.0, "gap 3.0s"), (40.004, -1, "lights off")]

# 1. pyedflib, streamed one data record (1 s) at a time
p1 = out / "pyedflib.bdf"
w = pyedflib.EdfWriter(str(p1), 4, file_type=pyedflib.FILETYPE_BDFPLUS)
w.setSignalHeaders([dict(label=n, dimension="uV", sample_frequency=FS, physical_min=-LIM, physical_max=LIM,
                         digital_min=-8388608, digital_max=8388607, transducer="dry electrode", prefilter="")
                    for n in NAMES])
w.setStartdatetime(START)
w.setEquipment("BrainBit_Black")
spr = w.get_smp_per_record(0)           # 250
full = N // spr
for r in range(full):                   # constant memory: one record of 4 x 250 doubles at a time
    block = np.ascontiguousarray(uv[:, r * spr:(r + 1) * spr]).ravel()   # signal 0 block, then signal 1 ...
    assert w.blockWritePhysicalSamples(block) == 0
tail = N - full * spr                   # last 0.3 s: pad the final record by repeating the last value
if tail:
    last = np.concatenate([uv[:, full * spr:], np.repeat(uv[:, -1:], spr - tail, axis=1)], axis=1)
    assert w.blockWritePhysicalSamples(np.ascontiguousarray(last).ravel()) == 0
    ANN_P = ANN + [(N / FS, (spr - tail) / FS, "padding")]
else:
    ANN_P = ANN
for onset, dur, text in ANN_P:
    assert w.writeAnnotation(onset, dur, text) == 0
w.close()

# 2. edfio directly (whole recording in memory)
p2 = out / "edfio.bdf"
pad = (-N) % FS
data = np.pad(uv, ((0, 0), (0, pad)), mode="edge")
sigs = [edfio.BdfSignal(data[c], FS, label=NAMES[c], transducer_type="dry electrode", physical_dimension="uV",
                        physical_range=(-LIM, LIM), digital_range=(-8388608, 8388607)) for c in range(4)]
anns = [edfio.EdfAnnotation(o, None if d < 0 else d, s) for o, d, s in ANN] + \
       ([edfio.EdfAnnotation(N / FS, pad / FS, "padding")] if pad else [])
edfio.Bdf(sigs, patient=edfio.Patient(),
          recording=edfio.Recording(startdate=START.date(), equipment_code="BrainBit_Black"),
          starttime=START.time(), annotations=anns).write(p2)

# 3. MNE export (uses edfio underneath)
p3 = out / "mne.bdf"
raw = mne.io.RawArray(uv * 1e-6, mne.create_info(NAMES, FS, "eeg"), verbose="error")
raw.set_meas_date(START.replace(tzinfo=timezone.utc))
raw.set_annotations(mne.Annotations([a[0] for a in ANN], [max(a[1], 0) for a in ANN], [a[2] for a in ANN],
                                    orig_time=raw.info["meas_date"]))
mne.export.export_raw(p3, raw, fmt="bdf", physical_range=(-LIM, LIM), overwrite=True, verbose="error")

# read back and compare
for p in (p1, p2, p3):
    hdr = p.read_bytes()[:256]
    print(p.name, p.stat().st_size, hdr[:8], hdr[192:236].rstrip(), hdr[184:192], hdr[236:244], hdr[244:252], hdr[252:256])
    print("  ", hdr[8:88].rstrip(), "|", hdr[88:168].rstrip(), "|", hdr[168:184])
    with pyedflib.EdfReader(str(p)) as r:
        x = np.stack([r.readSignal(c) for c in range(4)])
        print("  pyedflib:", r.getStartdatetime(), r.getSampleFrequencies(), list(zip(*r.readAnnotations())))
        print(f"  max abs error: {np.max(np.abs(x[:, :N] - uv)):.6f} uV")
    b = edfio.read_bdf(p)
    print("  edfio:", b.reserved, b.labels, b.num_data_records, [(a.onset, a.duration, a.text) for a in b.annotations])
    rr = mne.io.read_raw_bdf(p, verbose="error")
    print("  mne:", rr.info["sfreq"], rr.ch_names, rr.n_times, list(rr.annotations.description))
```

The output, shortened (identical lines merged):

```
pyedflib.bdf 207060 b'\xffBIOSEMI' b'BDF+C' b'1536    ' b'66      ' b'1       ' b'5   '
   X X X X | Startdate 17-NOV-2026 X X BrainBit_Black | 17.11.2623.05.07
  pyedflib: 2026-11-17 23:05:07 [250. 250. 250. 250.] (0.0,-1,'recording start') (12.5,3.0,'gap 3.0s') (40.004,-1,'lights off') (65.3,0.7,'padding')
  max abs error: 0.047683 uV
  edfio: BDF+C ('O1','O2','T3','T4') 66 [same 4 annotations]   mne: 250.0 [...] 16500 [same]
edfio.bdf 201318  (same header fields)   max abs error: 0.023841 uV   all three readers agree
mne.bdf   202506  (recording field 'Startdate 17-NOV-2026 X X X', digital min -8388607,
                   prefilter 'HP:0.0Hz LP:125.0Hz', padding annotation 'BAD_ACQ_SKIP')   max abs error 0.023842 uV
```

Per-signal fields decoded from `pyedflib.bdf`: `O1 … uV -400000 400000 -8388608 8388607 250` and `BDF Annotations  -1 1 -8388608 8388607 38`. The first 32 bytes (`od -A d -t x1z -N 32`):

```
0000000 ff 42 49 4f 53 45 4d 49 58 20 58 20 58 20 58 20  >.BIOSEMIX X X X <
0000016 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20  >                <
```

The whole 256-byte header in `od -c` showed `Startdate 17-NOV-2026 X X BrainBit_Black` at offset 88, `17.11.2623.05.07` at 168, `1536` at 184, `BDF+C` at 192, `66` at 236, `1` at 244 and `5` at 252.

I also ran `edge_cases.py` (sub-second start, 60-character text, 15 annotations in 10 records, chunked `writeSamples`, years 1984/2085, 8-character ranges, rounding), a crash test and an 8 h benchmark. Their outputs are the numbers quoted in section 3. The scripts are in `/tmp/claude-0/-home-user-eeg-tracker/a9aeea07-67bc-507d-952f-acf3d1a49173/scratchpad/bdf/scripts/`.

### 7. Review of `scripts/to_bdf.py` (pyedflib)

**Correct:**

- `FILETYPE_BDFPLUS` with the full 24-bit digital range. **[verified]**
- ±400 000 µV physical range, giving 0.048 µV steps: no meaningful precision loss. **[verified]**
- Labels O1..T4 and `uV` are within the field limits. **[verified]**
- A single `writeSamples` call over the whole night, so no zeros mid-file. **[verified]**
- Gap annotations, whose onsets are in file-sample time and so match the contiguous samples. **[verified]** by reading the code against the `.idx` format described in `record_night.py`.
- The output would pass the header rules quoted from EDFbrowser's checker (**[inferred]**: the demo file has the same structure, but EDFbrowser itself was not run).

**Problems, in order of importance:**

1. **Sub-second start time.** **[verified]** bug. `datetime.fromtimestamp(idx["t"][0])` has microseconds, which hit the pyedflib bug in section 3: the start is either dropped to the whole second or shifted by up to 0.9 s, and the shifted value is invisible to pyedflib's own reader. Fix: `.replace(microsecond=0)` (or round to the nearest second), and if sub-second accuracy matters, note the true offset in an annotation.
2. **Zero-padded final record.** **[verified]** behaviour. The last partial second is padded with physical 0 µV and nothing marks it. Pad with the edge value and add a `padding` annotation, as the demo does; MNE does the same.
3. **Unchecked annotation limits.** **[verified]** limits. `writeAnnotation`'s return value is ignored. Texts over 40 bytes are truncated, and if there are more gap annotations than seconds of recording, the extras are dropped silently. Gap texts are about 10 characters and an 8 h night allows 28 800 annotations, so this is unlikely to bite, but call `set_number_of_annotation_signals()` and assert `== 0` to be safe.
4. **The float range triggers a warning.** **[verified]** `lim = 400_000.0` causes the 9-character physical-min warning on every run. Use the integer `400_000`.
5. **Start time is the arrival time of the first batch** **[inferred]**, not the acquisition time of the first sample, so it is late by the BLE batch latency (probably tens of ms). It is also naive local time; EDF has no timezone, and MNE will label it UTC.
6. **Design note: no wall-clock time after gaps** **[inferred]**. Keeping samples contiguous and marking gaps only with annotations means file time drifts behind wall-clock time by the total missing seconds. A reader sees correct data with shifted times. Neither pyedflib nor edfio can write `BDF+D`, so the alternatives are:
   - fill gaps with flat samples plus a `BAD_gap` annotation (keeps wall-clock alignment), or
   - keep the current approach and also store the cumulative offset in each gap annotation's text.
7. **Memory** **[verified]** from the benchmark. The script loads the whole recording as float64 (about 230 MB for 8 h, plus copies). That is fine on the laptop. For a constant-memory converter, use the per-record `blockWritePhysicalSamples` loop from the demo.

Note on the phone side **[inferred]**: these are Python libraries. If the conversion really runs on the phone when a session closes, the Flutter app needs its own Dart BDF writer, which the header tables above specify byte for byte. The alternative is to ship the raw chunks and run `to_bdf.py` on the laptop.

A suggested minimal patch to `to_bdf.py` (**not run**):

```python
lim = 400_000  # int: fits the 8-char field without a warning
start = datetime.fromtimestamp(idx["t"][0]) if len(idx) else datetime.strptime(src.stem, "%Y-%m-%d-%H%M%S")
w.setStartdatetime(start.replace(microsecond=0))       # avoid pyedflib 0.1.42 subsecond bug
n = len(uv); pad = (-n) % FS
x = np.pad(np.clip(uv, -lim, lim), ((0, pad), (0, 0)), mode="edge")
w.writeSamples([np.ascontiguousarray(x[:, c]) for c in range(4)])
for onset, missing in g:
    assert w.writeAnnotation(onset, -1, f"gap {missing:.1f}s"[:40]) == 0
if pad:
    assert w.writeAnnotation(n / FS, pad / FS, "padding") == 0
```

## Could not verify

- The EDF+ spec (edfplus.info), the BDF+ description (teuniz.net) and the BDF spec (biosemi.com) themselves. The proxy refused them, along with Wikipedia and web.archive.org. Exact spec wording (patient and recording subfields, the 1985 clipping rule, the 61 440-byte record recommendation, UTF-8 in TALs, `+D` semantics) is from memory, checked only against the code and EDFbrowser's checker. Allowing those hosts would let this be checked.
- Running EDFbrowser's compatibility checker on the demo files: it was not installable here, and the policy forbids compiling downloaded code. Its menu location is inferred.
- Whether EDFlib truncates or rejects labels longer than 16 characters (pyedflib accepted one; the bytes were not inspected).
- The size of the BLE batch latency that makes the start time late.
- Whether pyedflib has a release newer than 0.1.42 on GitHub that is not on PyPI (the GitHub releases API call failed).

## Sources (all accessed 2026-11-17)

- PyPI JSON: https://pypi.org/pypi/pyedflib/json , https://pypi.org/pypi/edfio/json , https://pypi.org/pypi/mne/json
- LICENSE files: https://raw.githubusercontent.com/holgern/pyedflib/master/LICENSE , https://raw.githubusercontent.com/the-siesta-group/edfio/main/LICENSE , https://raw.githubusercontent.com/mne-tools/mne-python/main/LICENSE.txt
- pyedflib 0.1.42 sdist (EDFlib `edflib.c`/`edflib.h`, `_pyedflib.pyx`, `edfwriter.py`): https://files.pythonhosted.org/packages/8b/29/5080bc311a9f0f3802fb2919f3a7ff790f1ddbf352b21c282a479b895e10/pyedflib-0.1.42.tar.gz
- edfio 0.4.18 installed source (`edf.py`, `edf_signal.py`, `edf_annotations.py`, `edf_header.py`); changelog: https://raw.githubusercontent.com/the-siesta-group/edfio/main/CHANGELOG.md
- MNE 1.13.2 installed source (`mne/export/_export.py`, `mne/export/_edf_bdf.py`, `mne/utils/docs.py`); https://raw.githubusercontent.com/mne-tools/mne-python/v1.10.0/mne/export/_export.py , https://raw.githubusercontent.com/mne-tools/mne-python/v1.11.0/mne/export/_export.py , https://raw.githubusercontent.com/mne-tools/mne-python/v1.11.0/doc/changes/v1.11.rst
- EDFbrowser: https://gitlab.com/Teuniz/EDFbrowser/-/raw/master/check_edf_file.c , https://gitlab.com/Teuniz/EDFbrowser/-/raw/master/doc/manual.html , tags via https://gitlab.com/api/v4/projects/Teuniz%2FEDFbrowser/repository/tags
- Not reachable (403): https://www.edfplus.info/specs/edfplus.html , https://www.edfplus.info/specs/edf.html , https://www.teuniz.net/edfbrowser/bdfplus%20format%20description.html , https://www.biosemi.com/faq/file_format.htm
