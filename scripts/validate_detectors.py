"""Score every detector against the truth labels: one row per detector, truth label and period (DECISIONS 820-829).

usage: uv run --project analysis python scripts/validate_detectors.py [--local _local] [--book <local>/data] [--quiet]

The owner (2026-11-20) collects truth labels over months "so future agents and algorithms can judge the detectors".
This runs after each data-book build (scripts/after_pull.py) and only reads: the book's `truth.tsv` and `epochs.tsv.gz`,
the sleep reports (and the `sleep.json` beside a laptop report) and the phone's work sessions in `_local/`. It writes
`<book>/validation.tsv` (docs/data-format.md "validation.tsv") and `<book>/validation.md`, both rebuilt whole each run.
Not analysis/validate_detectors.py (hand checks of the detectors on one BDF): the tests load this file by its path.

Every detector answers per 30 s epoch: yes, no, or not read (a gap, a noisy epoch, before its baseline). For each truth
label it expects yes (`yes`), no (`no`), yes for most of the span (`mostly`: only the share of yes is reported, no false
minutes), or nothing (the label is not compared). An epoch belongs to a truth span when its middle lies inside it; a
moment (start = end) takes the epoch that holds it. Only active truth rows count (a corrected row gives way to its
correction). Where two sources of one detector version cover the same time (a nap scored twice by hand), the first in
the data book's counting order is kept, so no minute counts twice.

  detector     yes means                              from
  anysleep     asleep (N1 N2 N3 R; W is no)           every scored sleep report's stages (its own, or its sleep.json)
  yasa         asleep, by the second opinion          the laptop's sleep.json `yasa`
  drift_off    probably asleep (`s`; `a` `d` are no)  the report's `drift_off.epochs`, from lights off
  talking      2 or more jaw bursts in 30 s           epochs.tsv.gz `jaw` (the Archive's talking rule)
  moving       3 or more seconds of movement in 30 s  epochs.tsv.gz `movement_s` (the Archive's moving rule)
  no_signal    no usable signal (quality `m`)         epochs.tsv.gz `quality`
  eyes_closed  eyes closed                            the phone's work sessions' epochs

The extension point: `DETECTORS` (yes or no per epoch) and `MEASURERS` (a number against `measurement` truth rows, such
as a pulse in bpm against a watch's). The walking detector (feat/walking, `<local>/walking/<id>.walk.json`) and the pulse
detector (feat/pulse) each add one entry; `from_spans` turns a detector's stretches into epochs.
"""
from __future__ import annotations

import argparse, fcntl, json, math, os, sys, time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterable

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(1, str(ROOT / "analysis"))
import data_book as db  # noqa: E402  (the reports in counting order, their stages)
import day_summary as ds  # noqa: E402
import truth  # noqa: E402

VERSION = "validate-v1"  # of the rules below: a change of any of them is a new version
EPOCH_S = 30.0
MIN_PER_EPOCH = EPOCH_S / 60
TALKING_JAW = 2  # app/lib/archive/seen.dart ActivityRule.talkingJaw: jaw bursts in 30 s that read as talking or chewing
MOVING_S = 3  # ActivityRule.movingS: seconds of movement in 30 s that read as moving
YES, NO, UNREAD = 1, 0, -1
COLUMNS = ["detector", "detector_version", "yes_means", "label", "truth_expects", "scope", "label_id", "periods",
           "start", "end", "recording", "truth_source", "truth_confidence", "sources", "epochs", "truth_min", "yes_min",
           "no_min", "not_read_min", "agreement_pct", "false_pos_min", "false_neg_min", "values", "mean_abs_error",
           "mean_error", "unit", "validation_version"]


# ---- what a detector gives ------------------------------------------------------------------------------------------

@dataclass
class Output:
    """One detector's answers from one source (a report, a recording, a session file), one per 30 s epoch."""
    source: str
    version: str
    starts: np.ndarray  # epoch starts, unix seconds
    says: np.ndarray  # YES, NO or UNREAD per epoch


@dataclass
class Values:
    """A measuring detector's numbers from one source: (time, value) pairs, e.g. a pulse estimate every few seconds."""
    source: str
    version: str
    times: np.ndarray
    values: np.ndarray


@dataclass(frozen=True)
class Detector:
    name: str
    yes_means: str
    yes: frozenset[str]
    no: frozenset[str]
    mostly: frozenset[str]
    read: Callable[[Book], Iterable[Output]]

    def expects(self, label: str) -> str | None:
        return "yes" if label in self.yes else "no" if label in self.no else "mostly" if label in self.mostly else None


@dataclass(frozen=True)
class Measurer:
    name: str
    label: str  # the `measurement` label it estimates (`pulse`)
    unit: str  # in the vocabulary's unit (`bpm`)
    within_s: float  # its values this close to a truth reading (or inside its span) are averaged against it
    read: Callable[[Book], Iterable[Values]]


def from_spans(source: str, version: str, start: float, end: float, spans: Iterable[tuple[float, float]],
               unread: Iterable[tuple[float, float]] = ()) -> Output:
    """Epochs from `start` to `end` (unix seconds): yes where over half of the epoch lies in a span, not read where over
    half lies in an `unread` stretch, else no. For detectors that give stretches (walking)."""
    n = max(0, int((end - start) // EPOCH_S))
    starts = start + EPOCH_S * np.arange(n)

    def share(items: Iterable[tuple[float, float]]) -> np.ndarray:
        cover = np.zeros(n)
        for a, b in items:
            cover += np.clip(np.minimum(starts + EPOCH_S, b) - np.maximum(starts, a), 0, None)
        return cover / EPOCH_S
    says = np.where(share(spans) > 0.5, YES, NO).astype(np.int8)
    says[share(unread) > 0.5] = UNREAD
    return Output(source, version, starts, says)


# ---- where the answers come from ------------------------------------------------------------------------------------

@dataclass
class Book:
    """What the readers share: the data folder, the book's folder, and what was read once."""
    local: Path
    out: Path
    _reports: list[tuple[db.Report, list[str] | None, dict | None]] | None = None
    _epochs: object = None
    problems: list[str] = field(default_factory=list)

    def reports(self) -> list[tuple[db.Report, list[str] | None, dict | None]]:
        """Every scored sleep report in the book's counting order, with its stages and its sleep.json (or None)."""
        if self._reports is None:
            hashes = db.Hashes(self.local, self.out / ".cache" / "hashes.json")  # read only: never saved here
            found = db.read_reports(self.local, hashes)
            self._reports = []
            for night in sorted(found):
                for rep in found[night]:
                    if not rep.scored:
                        continue
                    stages = db.stages_of(rep, self.local, hashes)[0]
                    rel = db.sleep_json_of(rep, self.local)
                    sj = db._json(self.local / rel) if rel else None  # noqa: SLF001
                    self._reports.append((rep, stages, sj if isinstance(sj, dict) else None))
        return self._reports

    def epochs(self):  # noqa: ANN201 - a pandas DataFrame (pandas only imported here)
        """epochs.tsv.gz's columns the signal detectors need; None when the book has none."""
        if self._epochs is None:
            import pandas as pd
            p = self.out / "epochs.tsv.gz"
            if not p.is_file():
                return None
            df = pd.read_csv(p, sep="\t", usecols=["recording", "start", "quality", "jaw", "movement_s",
                                                   "signal_version"],
                             dtype={"recording": str, "quality": str, "signal_version": str}, keep_default_na=True)
            df["t"] = _seconds(df["start"])
            self._epochs = df
        return self._epochs


def _seconds(col) -> np.ndarray:  # noqa: ANN001 - a pandas Series of ISO times with offsets
    import pandas as pd
    t = pd.to_datetime(col, utc=True, format="ISO8601")
    return ((t - pd.Timestamp(0, tz="UTC")) / pd.Timedelta(seconds=1)).to_numpy(dtype=float)


def _t(v: object) -> float | None:
    d = ds.parse_time(v)
    return d.timestamp() if d else None


STAGE_SAYS = {"W": NO, "N1": YES, "N2": YES, "N3": YES, "R": YES}


def read_anysleep(book: Book) -> Iterable[Output]:
    for rep, stages, _ in book.reports():
        t0 = _t(rep.data["data_start"])
        if stages and t0 is not None:
            says = np.array([STAGE_SAYS.get(s, UNREAD) for s in stages], np.int8)
            yield Output(rep.rel, str(rep.data.get("model") or "unknown model"), t0 + EPOCH_S * np.arange(len(says)),
                         says)


def read_yasa(book: Book) -> Iterable[Output]:
    for rep, _, sj in book.reports():
        ep = sj.get("epochs") if sj else None
        if not isinstance(ep, list):
            continue
        pairs = [(_t(e.get("t")), e.get("yasa")) for e in ep if isinstance(e, dict) and "yasa" in e]
        pairs = [(t, s) for t, s in pairs if t is not None]
        if pairs:
            cross = rep.data.get("cross_check") if isinstance(rep.data.get("cross_check"), dict) else {}
            yield Output(db.sleep_json_of(rep, book.local) or rep.rel, str(cross.get("model") or "yasa"),
                         np.array([t for t, _ in pairs]), np.array([STAGE_SAYS.get(s, UNREAD) for _, s in pairs],
                                                                   np.int8))


DRIFT_SAYS = {"s": YES, "a": NO, "d": NO}  # `b` (learning its baseline) and `-` (skipped): not read


def read_drift_off(book: Book) -> Iterable[Output]:
    for rep, _, _ in book.reports():
        d = rep.data.get("drift_off")
        t0 = _t(rep.data["data_start"])
        if not (isinstance(d, dict) and isinstance(d.get("epochs"), str) and t0 is not None):
            continue
        lights = d.get("lights_off_s")
        if not isinstance(lights, (int, float)) or isinstance(lights, bool):
            continue
        says = np.array([DRIFT_SAYS.get(c, UNREAD) for c in d["epochs"]], np.int8)
        yield Output(rep.rel, f"drift-off v{d.get('version')} (DECISIONS 88, from {d.get('source') or 'lights off'})",
                     t0 + float(lights) + EPOCH_S * np.arange(len(says)), says)


def _signal(book: Book, rule: str, says_of: Callable[[object], np.ndarray]) -> Iterable[Output]:
    df = book.epochs()
    if df is None or not len(df):
        return
    for (rec, ver), g in df.groupby(["recording", "signal_version"], sort=False, dropna=False):
        g = g.sort_values("t")
        yield Output(f"epochs.tsv.gz {rec}", f"{ver}; {rule}", g["t"].to_numpy(), says_of(g))


def _talking(g) -> np.ndarray:  # noqa: ANN001
    jaw, q = g["jaw"].to_numpy(dtype=float), g["quality"].fillna("").to_numpy()
    return np.where(np.isnan(jaw) | (q == "m") | (q == ""), UNREAD, np.where(jaw >= TALKING_JAW, YES, NO)).astype(np.int8)


def _moving(g) -> np.ndarray:  # noqa: ANN001
    mv, q = g["movement_s"].to_numpy(dtype=float), g["quality"].fillna("").to_numpy()
    return np.where(np.isnan(mv) | (q == "m") | (q == ""), UNREAD, np.where(mv >= MOVING_S, YES, NO)).astype(np.int8)


def _no_signal(g) -> np.ndarray:  # noqa: ANN001
    q = g["quality"].fillna("").to_numpy()
    return np.where(q == "m", YES, np.where((q == "g") | (q == "d"), NO, UNREAD)).astype(np.int8)


def read_talking(book: Book) -> Iterable[Output]:
    return _signal(book, f"talking: {TALKING_JAW}+ jaw bursts in 30 s", _talking)


def read_moving(book: Book) -> Iterable[Output]:
    return _signal(book, f"moving: {MOVING_S}+ s of movement in 30 s", _moving)


def read_no_signal(book: Book) -> Iterable[Output]:
    return _signal(book, "no signal: quality m", _no_signal)


def read_eyes_closed(book: Book) -> Iterable[Output]:
    """The phone's work sessions: `eyes_closed` per epoch; an epoch without alpha (under 10 clean seconds) or in a
    meeting is not read (the work session itself never calls those closed)."""
    for f in sorted((book.local / "phone" / "work-sessions").glob("*.work.json")):
        j = db._json(f)  # noqa: SLF001
        start = ds.parse_time(j.get("start")) if isinstance(j, dict) else None
        if start is None or not isinstance(j.get("epochs"), list):
            continue
        rows = []
        for e in j["epochs"]:
            t = ds._epoch_time(e, start) if isinstance(e, dict) else None  # noqa: SLF001
            if t is None:
                continue
            closed, readable = e.get("eyes_closed") is True, e.get("alpha") is not None and e.get("meeting") is not True
            rows.append((t.timestamp(), YES if closed else NO if readable else UNREAD))
        if rows:
            rows.sort()
            yield Output(f.relative_to(book.local).as_posix(), f"{j.get('app')} v{j.get('version')}",
                         np.array([t for t, _ in rows]), np.array([s for _, s in rows], np.int8))


AWAKE_DOING = frozenset({"awake", "walking", "running", "stairs", "cycling", "exercise", "eating", "drinking_coffee",
                         "drinking_alcohol", "talking", "meeting", "focused_work", "working", "standing"})
SLEEP = dict(yes=frozenset({"asleep"}), no=AWAKE_DOING, mostly=frozenset({"nap"}))
DETECTORS: list[Detector] = [
    Detector("anysleep", "asleep (N1 N2 N3 R)", read=read_anysleep, **SLEEP),
    Detector("yasa", "asleep (N1 N2 N3 R)", read=read_yasa, **SLEEP),
    Detector("drift_off", "probably asleep", read=read_drift_off, **SLEEP),
    Detector("talking", "talking or chewing (jaw)", yes=frozenset({"talking", "eating"}), no=frozenset({"meditating"}),
             mostly=frozenset({"meeting"}), read=read_talking),
    Detector("moving", "moving", yes=frozenset({"walking", "running", "stairs", "exercise"}),
             no=frozenset({"meditating"}), mostly=frozenset(), read=read_moving),
    Detector("no_signal", "no usable signal", yes=frozenset({"headband_off"}), no=frozenset(), mostly=frozenset(),
             read=read_no_signal),
    Detector("eyes_closed", "eyes closed", yes=frozenset({"eyes_closed"}),
             no=frozenset({"focused_work", "working", "meeting", "walking", "running", "cycling"}),
             mostly=frozenset({"meditating"}), read=read_eyes_closed),
]
MEASURERS: list[Measurer] = []  # the pulse detector adds itself here (feat/pulse): Measurer("pulse", "pulse", "bpm", ...)


# ---- comparing ------------------------------------------------------------------------------------------------------

@dataclass
class Timeline:
    """One detector version's answers from every source, sorted, no epoch counted twice."""
    starts: np.ndarray
    says: np.ndarray
    source: np.ndarray  # index into `sources`
    sources: list[str]


def merge(outputs: list[Output]) -> dict[str, Timeline]:
    """Outputs by version, in the order given; an epoch whose middle lies in an earlier source's span is left out."""
    by: dict[str, list[Output]] = defaultdict(list)
    for o in outputs:
        if len(o.starts):
            by[o.version].append(o)
    out = {}
    for ver, outs in by.items():
        covered: list[tuple[float, float]] = []
        parts = []
        for i, o in enumerate(outs):
            mid = o.starts + EPOCH_S / 2
            keep = np.ones(len(mid), bool)
            for a, b in covered:
                keep &= ~((mid >= a) & (mid < b))
            covered.append((float(o.starts.min()), float(o.starts.max()) + EPOCH_S))
            parts.append((o.starts[keep], o.says[keep], np.full(int(keep.sum()), i)))
        starts = np.concatenate([p[0] for p in parts])
        order = np.argsort(starts, kind="stable")
        out[ver] = Timeline(starts[order], np.concatenate([p[1] for p in parts])[order],
                            np.concatenate([p[2] for p in parts])[order], [o.source for o in outs])
    return out


def spans(tl: Timeline, a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """For truth spans [a, b) (unix seconds): the first and past-the-last epoch whose middle lies inside; for a moment
    (a = b) the epoch that holds it."""
    mid = tl.starts + EPOCH_S / 2
    lo, hi = np.searchsorted(mid, a, "left"), np.searchsorted(mid, b, "left")
    k = np.searchsorted(tl.starts, a, "right") - 1
    held = (k >= 0) & (a < tl.starts[np.clip(k, 0, None)] + EPOCH_S) if len(tl.starts) else np.zeros(len(a), bool)
    moment = a == b
    lo = np.where(moment, np.where(held, k, 0), lo)
    hi = np.where(moment, np.where(held, k + 1, 0), hi)
    return lo, hi


def counts(tl: Timeline, lo: np.ndarray, hi: np.ndarray) -> dict[str, np.ndarray]:
    """yes, no and not-read epochs in each [lo, hi), by cumulative sums."""
    out = {}
    for name, v in (("yes", YES), ("no", NO), ("unread", UNREAD)):
        c = np.concatenate([[0], np.cumsum(tl.says == v)])
        out[name] = c[hi] - c[lo]
    return out


def judge(expects: str, yes: int, no: int) -> dict:
    """Agreement and false minutes for one comparison: `yes` truth counts each no as a false no, `no` truth each yes as a
    false yes; `mostly` reports only the share of yes."""
    n = yes + no
    if expects == "mostly":
        return dict(agreement_pct=round(100 * yes / n, 1) if n else None, false_pos_min=None, false_neg_min=None)
    right = yes if expects == "yes" else no
    return dict(agreement_pct=round(100 * right / n, 1) if n else None,
                false_pos_min=yes * MIN_PER_EPOCH if expects == "no" else 0.0,
                false_neg_min=no * MIN_PER_EPOCH if expects == "yes" else 0.0)


@dataclass
class Truth:
    """The active truth rows as arrays (pandas reads truth.tsv)."""
    rows: list[dict[str, str]]
    a: np.ndarray
    b: np.ndarray

    @staticmethod
    def read(path: Path) -> Truth:
        import pandas as pd
        if not path.is_file():
            return Truth([], np.array([]), np.array([]))
        df = pd.read_csv(path, sep="\t", dtype=str, keep_default_na=False)
        df = df[df["active"] == "1"].reset_index(drop=True)
        return Truth(df.to_dict("records"), _seconds(df["start"]), _seconds(df["end"]))


def binary_rows(det: Detector, truth: Truth, outputs: list[Output]) -> list[dict]:
    rows: list[dict] = []
    want = [i for i, r in enumerate(truth.rows) if det.expects(r["label"])]
    if not want:
        return rows
    idx = np.array(want)
    for ver, tl in merge(outputs).items():
        lo, hi = spans(tl, truth.a[idx], truth.b[idx])
        c = counts(tl, lo, hi)
        totals: dict[str, dict] = {}
        for j, i in enumerate(idx):
            yes, no, unread = int(c["yes"][j]), int(c["no"][j]), int(c["unread"][j])
            if yes + no + unread == 0:
                continue
            r = truth.rows[i]
            expects = det.expects(r["label"]) or ""
            used = tl.sources if len(tl.sources) == 1 else sorted({tl.sources[s] for s in tl.source[lo[j]:hi[j]]})
            rows.append(dict(_base(det.name, ver, det.yes_means, r["label"], expects), scope="label",
                             label_id=r["label_id"], periods=1, start=r["start"], end=r["end"],
                             recording=r["recording"], truth_source=r["source"], truth_confidence=r["confidence"],
                             sources=" ".join(used), epochs=yes + no,
                             truth_min=round((truth.b[i] - truth.a[i]) / 60, 1),
                             **_minutes(yes, no, unread), **judge(expects, yes, no)))
            t = totals.setdefault(r["label"], dict(expects=expects, periods=0, yes=0, no=0, unread=0, truth_s=0.0,
                                                   start=r["start"], end=r["end"], ta=truth.a[i], tb=truth.b[i]))
            t["periods"] += 1
            t["yes"] += yes
            t["no"] += no
            t["unread"] += unread
            t["truth_s"] += truth.b[i] - truth.a[i]
            if truth.a[i] < t["ta"]:
                t["ta"], t["start"] = truth.a[i], r["start"]
            if truth.b[i] > t["tb"]:
                t["tb"], t["end"] = truth.b[i], r["end"]
        for label, t in sorted(totals.items()):
            rows.append(dict(_base(det.name, ver, det.yes_means, label, t["expects"]), scope="all", periods=t["periods"],
                             start=t["start"], end=t["end"], epochs=t["yes"] + t["no"],
                             truth_min=round(t["truth_s"] / 60, 1), **_minutes(t["yes"], t["no"], t["unread"]),
                             **judge(t["expects"], t["yes"], t["no"])))
    return rows


def _base(name: str, ver: str, means: str, label: str, expects: str) -> dict:
    return dict(detector=name, detector_version=ver, yes_means=means, label=label, truth_expects=expects,
                validation_version=VERSION)


def _minutes(yes: int, no: int, unread: int) -> dict:
    return dict(yes_min=yes * MIN_PER_EPOCH, no_min=no * MIN_PER_EPOCH, not_read_min=unread * MIN_PER_EPOCH)


def measured_rows(m: Measurer, truth: Truth, values: list[Values]) -> list[dict]:
    """Each truth reading of `m.label` in `m.unit` against the mean of the detector's values within `within_s` of it
    (inside its span, or around a moment): the error is detector minus truth."""
    rows: list[dict] = []
    idx = [i for i, r in enumerate(truth.rows) if r["label"] == m.label and r["unit"] == m.unit and r["value"]]
    by: dict[str, list[Values]] = defaultdict(list)
    for v in values:
        by[v.version].append(v)
    for ver, vs in by.items():
        t = np.concatenate([v.times for v in vs])
        x = np.concatenate([v.values for v in vs])
        order = np.argsort(t, kind="stable")
        t, x = t[order], x[order]
        errs = []
        for i in idx:
            r = truth.rows[i]
            lo = np.searchsorted(t, truth.a[i] - m.within_s, "left")
            hi = np.searchsorted(t, truth.b[i] + m.within_s, "right")
            if hi <= lo:
                continue
            err = float(np.mean(x[lo:hi])) - float(r["value"])
            errs.append(err)
            rows.append(dict(_base(m.name, ver, f"{m.label} in {m.unit}", m.label, "value"), scope="label",
                             label_id=r["label_id"], periods=1, start=r["start"], end=r["end"],
                             recording=r["recording"], truth_source=r["source"], truth_confidence=r["confidence"],
                             sources=" ".join(sorted({v.source for v in vs})), values=int(hi - lo),
                             mean_abs_error=round(abs(err), 2), mean_error=round(err, 2), unit=m.unit))
        if errs:
            e = np.array(errs)
            rows.append(dict(_base(m.name, ver, f"{m.label} in {m.unit}", m.label, "value"), scope="all",
                             periods=len(errs), values=len(errs), mean_abs_error=round(float(np.abs(e).mean()), 2),
                             mean_error=round(float(e.mean()), 2), unit=m.unit))
    return rows


# ---- the run --------------------------------------------------------------------------------------------------------

def validate(local: Path, out: Path, detectors: list[Detector] | None = None, measurers: list[Measurer] | None = None
             ) -> tuple[list[dict], dict]:
    """Every detector's rows, and what the summary needs."""
    book = Book(local, out)
    tr = Truth.read(out / "truth.tsv")
    rows: list[dict] = []
    seen: dict[str, int] = {}
    for det in DETECTORS if detectors is None else detectors:
        try:
            outs = list(det.read(book))
        except (OSError, ValueError, KeyError) as e:
            book.problems.append(f"{det.name}: could not be read ({type(e).__name__}: {e})")
            continue
        seen[det.name] = sum(len(o.starts) for o in outs)
        rows += binary_rows(det, tr, outs)
    for m in MEASURERS if measurers is None else measurers:
        try:
            vals = list(m.read(book))
        except (OSError, ValueError, KeyError) as e:
            book.problems.append(f"{m.name}: could not be read ({type(e).__name__}: {e})")
            continue
        seen[m.name] = sum(len(v.times) for v in vals)
        rows += measured_rows(m, tr, vals)
    covered = {r["label_id"] for r in rows if r.get("label_id")}
    info = dict(truth=len(tr.rows), uncovered=[r for r in tr.rows if r["label_id"] not in covered], seen=seen,
                problems=book.problems)
    return rows, info


def write_tsv(path: Path, rows: list[dict]) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(db.tsv(COLUMNS, rows), encoding="utf-8")
    os.replace(tmp, path)


def _f(v: object) -> str:
    return "" if v is None else db.cell(v)


def summary(rows: list[dict], info: dict, built: str, book_json: dict | None) -> str:
    """validation.md: in words, then the totals, then each truth label."""
    lines = ["# Detectors against the truth labels", "",
             f"Built {built} by `scripts/validate_detectors.py` ({VERSION}) from {info['truth']} active truth labels in "
             "`truth.tsv`. One row per detector, label and period is in `validation.tsv` (docs/data-format.md). "
             "Planning numbers: a truth label's times are as rough as its `confidence` says.", ""]
    totals = [r for r in rows if r["scope"] == "all"]
    if not totals:
        lines += ["No detector's output overlaps a truth label yet.", ""]
    for r in totals:
        lines.append("- " + _sentence(r))
    lines += ["", "## Totals", "",
              "| Detector | Version | Truth label | Expects | Periods | Compared (min) | Agreement | False yes (min) "
              "| False no (min) | Not read (min) |", "|---|---|---|---|---|---|---|---|---|---|"]
    for r in totals:
        lines.append(f"| {r['detector']} | {r['detector_version']} | {r['label']} | {r['truth_expects']} | "
                     f"{r['periods']} | {_f(_cmp_min(r))} | {_pct(r)} | {_f(r.get('false_pos_min'))} | "
                     f"{_f(r.get('false_neg_min'))} | {_f(r.get('not_read_min'))} |")
    lines += ["", "## Each truth label", "",
              "| Label | Truth | Detector | Compared (min) | Agreement | False yes (min) | False no (min) |",
              "|---|---|---|---|---|---|---|"]
    for r in sorted((r for r in rows if r["scope"] == "label"), key=lambda r: (r["start"], r["label_id"],
                                                                               r["detector"])):
        lines.append(f"| {r['label_id']} | {r['label']} {_span(r['start'], r['end'])} | {r['detector']} | "
                     f"{_f(_cmp_min(r))} | {_pct(r)} | {_f(r.get('false_pos_min'))} | {_f(r.get('false_neg_min'))} |")
    lines += ["", "## Not compared", ""]
    if info["uncovered"]:
        lines.append("Truth labels no detector covered (no output in their time, or no detector reads that label):")
        lines += [f"- {r['label_id']} {r['label']} {r['start']} to {r['end']}" for r in info["uncovered"][:50]]
        if len(info["uncovered"]) > 50:
            lines.append(f"- and {len(info['uncovered']) - 50} more")
    else:
        lines.append("Every active truth label was compared.")
    quiet = [n for n in info["seen"] if not any(r["detector"] == n for r in rows)]
    if quiet:
        lines.append("")
        lines.append("Detectors with no truth label in their time yet: " + ", ".join(
            f"{n} ({info['seen'][n]} epochs)" for n in quiet) + ".")
    left = (book_json or {}).get("truth_rejected") or []
    if left:
        lines += ["", "Truth rows left out of `truth.tsv` (they break the schema; `python3 scripts/truth.py check`):"]
        lines += [f"- {t}" for t in left]
    for p in info["problems"]:
        lines.append(f"- PROBLEM: {p}")
    return "\n".join(lines) + "\n"


def _cmp_min(r: dict) -> float | None:
    return None if r.get("epochs") in (None, "") else r["epochs"] * MIN_PER_EPOCH


def _pct(r: dict) -> str:
    if r.get("mean_abs_error") is not None:
        return f"error {r['mean_abs_error']} {r['unit']}"
    return "" if r.get("agreement_pct") is None else f"{_f(r['agreement_pct'])} %" + (
        " yes" if r["truth_expects"] == "mostly" else "")


def _span(a: str, b: str) -> str:
    """`11-20 17:50-22:07`, the end's date only when it is another day."""
    x, y = truth.parse_time(a), truth.parse_time(b)
    if x is None or y is None:
        return f"{a} to {b}"
    return x.strftime("%m-%d %H:%M") + "-" + y.strftime("%H:%M" if y.date() == x.date() else "%m-%d %H:%M")


def _sentence(r: dict) -> str:
    name = f"{r['detector']} ({r['detector_version']})"
    if r["truth_expects"] == "value":
        return (f"{name}: over {r['periods']} {r['label']} readings, off by {r['mean_abs_error']} {r['unit']} on "
                f"average (detector minus truth {r['mean_error']}).")
    m = _f(_cmp_min(r))
    if r["truth_expects"] == "mostly":
        return f"{name}: during {r['label']} ({m} min compared) it said {r['yes_means']} {_f(r['agreement_pct'])} %."
    if r["truth_expects"] == "yes":
        return (f"{name}: during {r['label']} ({m} min compared) it missed {_f(r['false_neg_min'])} min "
                f"({_f(r['agreement_pct'])} % right).")
    return (f"{name}: during {r['label']} ({m} min compared) it falsely said {r['yes_means']} for "
            f"{_f(r['false_pos_min'])} min ({_f(r['agreement_pct'])} % right).")


def run(local: Path, out: Path, now: datetime) -> tuple[list[dict], dict]:
    rows, info = validate(local, out)
    write_tsv(out / "validation.tsv", rows)
    bj = db._json(out / "book.json")  # noqa: SLF001
    md = summary(rows, info, now.isoformat(timespec="seconds"), bj if isinstance(bj, dict) else None)
    tmp = out / "validation.md.tmp"
    tmp.write_text(md, encoding="utf-8")
    os.replace(tmp, out / "validation.md")
    return rows, info


def main(argv: list[str] | None = None, say: Callable[[str], object] = print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=ROOT / "_local", help="the data folder (default: the repo's _local)")
    ap.add_argument("--book", type=Path, help="the data book's folder (default: <local>/data)")
    ap.add_argument("--quiet", action="store_true", help="only the summary line")
    a = ap.parse_args(argv)
    local = a.local.resolve()
    out = (a.book or local / "data").resolve()
    if not (out / "truth.tsv").is_file():
        say(f"no {out / 'truth.tsv'}: build the data book first (scripts/data_book.py)")
        return 1
    t0 = time.time()
    with open(out / ".lock", "a+") as lock:  # the data book's own lock: never read a book half rebuilt
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say("a data book run is going on; nothing to do (the after-pull jobs validate after it)")
            return 0
        rows, info = run(local, out, datetime.now().astimezone())
    if not a.quiet:
        for r in rows:
            if r["scope"] == "all":
                say("  " + _sentence(r))
    say(f"validation {out}: {len(rows)} rows, {info['truth']} active truth labels, {len(info['uncovered'])} not "
        f"compared, {time.time() - t0:.1f} s")
    for p in info["problems"]:
        say(f"PROBLEM: {p}")
    return 1 if info["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
