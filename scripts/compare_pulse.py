"""Pulse from the headband (analysis/pulse.py) for one recording, and how it agrees with a watch's heart rate.

  uv run --project analysis python scripts/compare_pulse.py REC [REC2 ...] [--stages SLEEP.json] [--start ISO]
      [--reference FILE] [--reference-tz +03:00] [--out FILE.pulse.json] [--json]

REC: a night's BDF (scripts/to_bdf.py), one recording's `.f32` files (joined on the clock as the phone's Archive joins
them, every channel their header names), or a `.pulse.json` the phone (files/pulse/) or this script wrote.

--stages: the night's `sleep.json` (scripts/score_sleep.py): readings per stage and while asleep; the recording's epochs
  are counted from its first epoch's time (a BDF's start time can be off). --start: the recording's first sample
  instead, as local clock time or with an offset.
--reference: a heart-rate export with times and beats a minute (each format is recognised by its contents):
  - a plain CSV or TSV with a time column (time, timestamp, datetime, date, start, start_time; ISO times, or unix
    seconds or milliseconds) and a rate column (bpm, heart_rate, heartrate, hr, pulse, value);
  - Android Health Connect's "Export data": its zip or the `.db` inside (heart_rate_record_series_table);
  - Mi Fitness's personal-data copy, `..._hlth_center_fitness_data.csv` (Key heart_rate or single_heart_rate, the
    Value's JSON time and bpm);
  - Samsung Health's `com.samsung.shealth.tracker.heart_rate.<stamp>.csv` (per-minute bins from its `jsons/` folder
    when they are beside it, else the rows' own averages);
  - Garmin's FIT files turned into CSV by the FIT SDK's FitCSVTool (record and monitoring messages' heart_rate);
  - Apple Health's `export.xml` (HKQuantityTypeIdentifierHeartRate);
  - Fitbit's Google Takeout `heart_rate-YYYY-MM-DD.json`.
  Times without an offset are the laptop's local clock (the recordings' own) unless --reference-tz says.
--out: the readings as a pulse file, the phone's format (docs/data-format.md "Pulse").

Agreement, over the epochs with a headband reading and a reference value (the median of the reference's samples from
half a minute before the epoch to half a minute after it): n, the bias (headband minus reference), the 95 % limits of
agreement (bias +- 1.96 SD, Bland and Altman), the mean absolute difference and the share within 5 a minute. Reads only;
writes only --out.
"""
from __future__ import annotations

import argparse, csv, io, json, math, re, sqlite3, sys, tempfile, zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
import eeg_detectors as det  # noqa: E402
import pulse as pl  # noqa: E402

FORMAT, VERSION = "eeg-tracker-pulse", 1
LIMIT_UV = 400_000.0  # the joined signal is clipped here, as the phone's join holds it
WITHIN_BPM = 5.0
REF_SLACK_S = 30.0  # a reference sample counts for an epoch from this long before it to this long after it
BPM_RANGE = (20.0, 250.0)  # reference values outside this are placeholders (Mi Fitness writes 0)
FIT_EPOCH = 631065600  # FIT timestamps count seconds from 1989-12-31 00:00:00 UTC

Sample = tuple[float, float]  # (unix seconds, beats a minute)


class ReferenceError(ValueError):
    pass


# ------------------------------------------------------------------------------------------------ the recording


def iso(t: float) -> str:
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def r1(v: float | None) -> float | None:
    return None if v is None or (isinstance(v, float) and math.isnan(v)) else round(float(v), 1)


def pulse_file(rec_id: str, start_unix: float, names: list[str], fs: float, eps: list[pl.Epoch]) -> dict:
    """The pulse file's content (docs/data-format.md "Pulse"): the same fields as the phone's."""
    read = [ep for ep in eps if ep.read]
    bpm = [r1(ep.bpm) if ep.read else None for ep in eps]
    vals = [b for b in bpm if b is not None]
    return dict(
        format=FORMAT, version=VERSION, detector=pl.VERSION, recording=rec_id, start=iso(start_unix),
        start_ms=int(round(start_unix * 1000)), epoch_s=pl.EPOCH_S, channels=names, sample_rate=fs, epochs=len(eps),
        read=len(read), coverage=round(pl.coverage(eps), 4), median_bpm=r1(det.median(vals)) if vals else None,
        codes="".join(ep.code for ep in eps), bpm=bpm,
        conf=[round(ep.conf, 2) if ep.read else None for ep in eps],
        channel=[ep.channel if ep.read else None for ep in eps],
    )


def read_bdf(path: Path) -> tuple[np.ndarray, float, np.ndarray, list[str], float]:
    import mne  # only here

    raw = mne.io.read_raw_bdf(path, preload=True, verbose="error")
    fs = float(raw.info["sfreq"])
    x = np.clip(raw.get_data(units="uV"), -LIMIT_UV, LIMIT_UV)
    miss = np.zeros(x.shape[1], bool)
    for a in raw.annotations:
        if str(a["description"]).startswith("BAD") and a["duration"] > 0:
            lo = round(a["onset"] * fs)
            miss[lo:lo + round(a["duration"] * fs)] = True
    start = raw.info["meas_date"].replace(tzinfo=None).timestamp()  # to_bdf writes local clock time; MNE says UTC
    return x, fs, miss, list(raw.ch_names), start


def read_f32(paths: list[Path]) -> tuple[np.ndarray, float, np.ndarray, list[str], float]:
    import to_bdf  # the laptop's join, the phone's twin (sleep/night_signal.dart)

    h = to_bdf.night_header(paths)
    start, uv, notes = to_bdf.join(paths)
    fs = float(h.sample_rate)
    x = np.clip(np.asarray(uv, dtype=np.float64), -LIMIT_UV, LIMIT_UV).T
    miss = np.zeros(x.shape[1], bool)
    for onset, dur, text in notes:
        if text.startswith("BAD") and dur > 0:
            lo = round(onset * fs)
            miss[lo:lo + round(dur * fs)] = True
    return x, fs, miss, list(h.names), start.timestamp()


def readings(recs: list[Path], start: float | None) -> tuple[dict, list[float | None]]:
    """(the pulse file, bpm per epoch) of a recording given as a BDF, .f32 files or a pulse file."""
    if len(recs) == 1 and recs[0].name.endswith(".pulse.json"):
        d = json.loads(recs[0].read_text())
        if not isinstance(d, dict) or d.get("format") != FORMAT:
            raise SystemExit(f"{recs[0]}: not a pulse file")
        if start is not None:
            d["start_ms"] = int(round(start * 1000))
        return d, [None if b is None else float(b) for b in d["bpm"]]
    if len(recs) == 1 and recs[0].suffix.lower() == ".bdf":
        x, fs, miss, names, t0 = read_bdf(recs[0])
        rec_id = recs[0].stem
    else:
        x, fs, miss, names, t0 = read_f32(sorted(recs))
        rec_id = sorted(recs)[0].name.split(".")[0]
    eps = pl.epochs(x, fs, miss)
    d = pulse_file(rec_id, t0 if start is None else start, names, fs, eps)
    return d, d["bpm"]


# ------------------------------------------------------------------------------------------------- the reference


def _num(v: str | float | int | None) -> float | None:
    try:
        f = float(str(v).strip().strip('"'))
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _ok(bpm: float | None) -> bool:
    return bpm is not None and BPM_RANGE[0] <= bpm <= BPM_RANGE[1]


def parse_time(v: str, tz: timezone | None) -> float | None:
    """Unix seconds of an ISO time (an offset or Z kept; none: tz, or the laptop's local clock), or of a number of unix
    seconds or milliseconds."""
    s = str(v).strip().strip('"')
    if not s:
        return None
    n = _num(s)
    if n is not None:
        return n / 1000 if n > 1e11 else n
    s = s.replace("Z", "+00:00")
    s = re.sub(r" ([+-]\d{2})(\d{2})$", r"\1:\2", s)  # Apple's "2026-01-10 08:00:00 +0100"
    for fmt in (None, "%m/%d/%y %H:%M:%S", "%m/%d/%Y %H:%M:%S", "%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M"):
        try:
            t = datetime.fromisoformat(s) if fmt is None else datetime.strptime(s, fmt)
        except ValueError:
            continue
        if t.tzinfo is None and tz is not None:
            t = t.replace(tzinfo=tz)
        return t.timestamp()
    return None


TIME_COLS = ("time", "timestamp", "datetime", "date_time", "start", "start_time", "starttime", "date", "time_utc")
BPM_COLS = ("bpm", "heart_rate", "heartrate", "heart rate", "hr", "pulse", "value", "beats_per_minute")


def _col(header: list[str], names: Iterable[str]) -> int | None:
    low = [h.strip().strip('"').strip("\ufeff").lower() for h in header]
    for n in names:
        for i, h in enumerate(low):
            if h == n or h.endswith("." + n) or h.split(" (")[0] == n:
                return i
    return None


def generic_rows(text: str, tz: timezone | None) -> list[Sample]:
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        raise ReferenceError("empty file")
    dialect = csv.Sniffer().sniff(lines[0], delimiters=",\t;") if any(d in lines[0] for d in ",\t;") else csv.excel
    rows = list(csv.reader(lines, dialect))
    ti, bi = _col(rows[0], TIME_COLS), _col(rows[0], BPM_COLS)
    if ti is None or bi is None:
        raise ReferenceError(f"no time and heart-rate columns in the header {rows[0]!r} (time: one of {TIME_COLS}; "
                             f"rate: one of {BPM_COLS})")
    out = []
    for r in rows[1:]:
        if max(ti, bi) >= len(r):
            continue
        t, b = parse_time(r[ti], tz), _num(r[bi])
        if t is not None and _ok(b):
            out.append((t, b))
    return out


def mi_fitness(text: str) -> list[Sample]:
    """Mi Fitness's fitness-data copy: Uid,Sid,Key,Time,Value,UpdateTime; heart rate rows' Value is JSON {time, bpm}
    (unix seconds, UTC); some copies wrap each line in another pair of quotes."""
    out = []
    for line in text.splitlines():
        line = line.strip().lstrip("\ufeff")
        row = next(csv.reader([line]), [])
        if len(row) < 5 and line.startswith('"') and line.endswith('"'):  # the line wrapped in quotes once more
            row = next(csv.reader([line[1:-1]]), [])
        if len(row) < 5 or row[2] not in ("heart_rate", "single_heart_rate"):
            continue
        try:
            v = json.loads(row[4])
        except json.JSONDecodeError:
            continue
        t, b = _num(v.get("time")) if isinstance(v, dict) else None, _num(v.get("bpm")) if isinstance(v, dict) else None
        if t is not None and _ok(b):
            out.append((t, b))
    return out


def _samsung_time(s: str) -> float | None:
    """Samsung's `2025-10-22 05:00:00.000`: UTC without a mark."""
    try:
        return datetime.fromisoformat(s.strip()).replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def samsung(path: Path, text: str) -> list[Sample]:
    """Samsung Health's heart-rate CSV: a first line naming the table, the header, rows with a trailing comma. Each
    row's `binning_data` JSON (per-minute bins, epoch ms) is used when found under the folder's `jsons/`."""
    lines = text.lstrip("\ufeff").splitlines()
    rows = list(csv.reader(lines[1:]))
    if not rows:
        return []
    head = rows[0]
    pre = "com.samsung.health.heart_rate."
    idx = {h.strip()[len(pre):] if h.strip().startswith(pre) else h.strip(): i for i, h in enumerate(head)}
    jsons = path.parent / "jsons" / "com.samsung.shealth.tracker.heart_rate"
    out: list[Sample] = []
    for r in rows[1:]:
        def get(name: str) -> str:
            i = idx.get(name)
            return r[i] if i is not None and i < len(r) else ""
        bins = get("binning_data").strip()
        found = list(jsons.glob(f"*/{bins}")) if bins and jsons.is_dir() else []
        if found:
            try:
                for b in json.loads(found[0].read_text()):
                    a, e, v = _num(b.get("start_time")), _num(b.get("end_time")), _num(b.get("heart_rate"))
                    if a is not None and e is not None and _ok(v):
                        out.append(((a + e) / 2000, v))  # type: ignore[arg-type]
                continue
            except (json.JSONDecodeError, AttributeError, TypeError):
                pass
        a, e, v = _samsung_time(get("start_time")), _samsung_time(get("end_time")), _num(get("heart_rate"))
        if a is not None and _ok(v):
            out.append((a if e is None else (a + e) / 2, v))  # type: ignore[arg-type]
    return out


def garmin_fitcsv(text: str) -> list[Sample]:
    """FitCSVTool's CSV: Type,Local Number,Message,Field 1,Value 1,Units 1,...; `record` and `monitoring` data rows'
    heart_rate with their timestamp (FIT seconds) or timestamp_16 after the last full one."""
    out: list[Sample] = []
    last: int | None = None
    for r in csv.reader(text.lstrip("\ufeff").splitlines()):
        if len(r) < 3 or r[0] != "Data":
            continue
        fields = {r[i]: r[i + 1] for i in range(3, len(r) - 1, 3) if r[i]}
        ts = _num(fields.get("timestamp"))
        if ts is not None:
            last = int(ts)
        t: float | None = None
        if ts is not None:
            t = ts + FIT_EPOCH
        elif (t16 := _num(fields.get("timestamp_16"))) is not None and last is not None:
            last = last + ((int(t16) - (last & 0xFFFF)) & 0xFFFF)
            t = last + FIT_EPOCH
        if r[2] in ("record", "monitoring") and t is not None:
            b = _num(fields.get("heart_rate"))
            if _ok(b):
                out.append((t, b))  # type: ignore[arg-type]
    return out


def apple(path: Path) -> list[Sample]:
    out: list[Sample] = []
    for _, el in ElementTree.iterparse(path):
        if el.tag == "Record" and el.get("type") == "HKQuantityTypeIdentifierHeartRate":
            t, b = parse_time(el.get("startDate", ""), None), _num(el.get("value"))
            if t is not None and _ok(b):
                out.append((t, b))  # type: ignore[arg-type]
        el.clear()
    return out


def fitbit(data: list, tz: timezone | None) -> list[Sample]:
    out = []
    for row in data:
        v = row.get("value") if isinstance(row, dict) else None
        t = parse_time(str(row.get("dateTime", "")), tz) if isinstance(row, dict) else None
        b = _num(v.get("bpm")) if isinstance(v, dict) else None
        if t is not None and _ok(b) and not (isinstance(v, dict) and v.get("confidence") == 0):
            out.append((t, b))
    return out


def health_connect(db: Path) -> list[Sample]:
    """Health Connect's export database: heart_rate_record_series_table (epoch_millis UTC, beats_per_minute)."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        cols = {r[1] for r in con.execute("PRAGMA table_info(heart_rate_record_series_table)")}
        if not {"epoch_millis", "beats_per_minute"} <= cols:
            raise ReferenceError(f"{db}: no heart_rate_record_series_table with epoch_millis and beats_per_minute")
        rows = con.execute("SELECT epoch_millis, beats_per_minute FROM heart_rate_record_series_table").fetchall()
    finally:
        con.close()
    return [(t / 1000, float(b)) for t, b in rows if t is not None and _ok(_num(b))]


def read_reference(path: Path, tz: timezone | None = None) -> tuple[str, list[Sample]]:
    """(the format's name, samples sorted by time) of a heart-rate export."""
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as z, tempfile.TemporaryDirectory() as tmp:
            dbs = [n for n in z.namelist() if n.lower().endswith(".db")]
            if not dbs:
                raise ReferenceError(f"{path}: no .db inside (Health Connect's export has one)")
            out = Path(tmp) / "health_connect.db"
            out.write_bytes(z.read(dbs[0]))
            return "Health Connect", sorted(health_connect(out))
    head = path.read_bytes()[:16]
    if head.startswith(b"SQLite format 3"):
        return "Health Connect", sorted(health_connect(path))
    if path.suffix.lower() == ".xml":
        return "Apple Health", sorted(apple(path))
    text = path.read_text(errors="replace")
    first = text.lstrip("\ufeff").split("\n", 1)[0].strip().strip('"')
    if path.suffix.lower() == ".json":
        data = json.loads(text)
        if isinstance(data, list):
            return "Fitbit", sorted(fitbit(data, tz))
        raise ReferenceError(f"{path}: a JSON file that is not a list of Fitbit heart-rate rows")
    if first.startswith("com.samsung.shealth.tracker.heart_rate"):
        return "Samsung Health", sorted(samsung(path, text))
    if first.startswith("Uid,Sid,Key,Time,Value"):
        return "Mi Fitness", sorted(mi_fitness(text))
    if first.startswith("Type,Local Number,Message"):
        return "Garmin (FitCSVTool)", sorted(garmin_fitcsv(text))
    return "CSV/TSV", sorted(generic_rows(text, tz))


# ------------------------------------------------------------------------------------------------- the agreement


def reference_per_epoch(samples: list[Sample], start: float, n: int, epoch_s: float = pl.EPOCH_S) -> list[float | None]:
    """The median of the reference's samples from REF_SLACK_S before each epoch to REF_SLACK_S after it."""
    ts = np.array([t for t, _ in samples])
    out: list[float | None] = []
    for e in range(n):
        a, b = start + e * epoch_s - REF_SLACK_S, start + (e + 1) * epoch_s + REF_SLACK_S
        lo, hi = np.searchsorted(ts, a, "left"), np.searchsorted(ts, b, "left")
        out.append(det.median([samples[i][1] for i in range(lo, hi)]) if hi > lo else None)
    return out


def agreement(head: list[float | None], ref: list[float | None]) -> dict:
    """Bland-Altman agreement of the epochs with both a headband reading and a reference value."""
    pairs = [(h, r) for h, r in zip(head, ref) if h is not None and r is not None]
    with_ref = sum(r is not None for r in ref)
    out: dict = dict(pairs=len(pairs), reference_epochs=with_ref,
                     read_where_reference=round(len(pairs) / with_ref, 4) if with_ref else None)
    if not pairs:
        return out
    d = np.array([h - r for h, r in pairs])
    bias = float(d.mean())
    sd = float(d.std(ddof=1)) if len(d) > 1 else 0.0
    out.update(bias=round(bias, 2), sd=round(sd, 2), loa_low=round(bias - 1.96 * sd, 2),
               loa_high=round(bias + 1.96 * sd, 2), mae=round(float(np.abs(d).mean()), 2),
               within_5=round(float((np.abs(d) <= WITHIN_BPM).mean()), 4),
               headband_median=round(det.median([h for h, _ in pairs]), 1),
               reference_median=round(det.median([r for _, r in pairs]), 1))
    return out


# --------------------------------------------------------------------------------------------------------- main


def stages_of(path: Path) -> tuple[list[str], float]:
    d = json.loads(path.read_text())
    if not isinstance(d, dict) or not isinstance(d.get("epochs"), list):
        raise SystemExit(f"{path}: not a sleep.json")
    return [str(e["anysleep"]) for e in d["epochs"]], datetime.fromisoformat(str(d["start"])).timestamp()


def offset(v: str) -> timezone:
    m = re.fullmatch(r"([+-])(\d{1,2}):?(\d{2})?", v.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"not an offset like +03:00: {v!r}")
    mins = int(m.group(2)) * 60 + int(m.group(3) or 0)
    return timezone(timedelta(minutes=mins if m.group(1) == "+" else -mins))


def report(recs: list[Path], stages_path: Path | None = None, start_iso: str | None = None,
           ref_path: Path | None = None, ref_tz: timezone | None = None) -> dict:
    stages: list[str] | None = None
    start = None
    if stages_path is not None:
        stages, start = stages_of(stages_path)
    if start_iso is not None:
        start = parse_time(start_iso, None)
    pf, bpm = readings(recs, start)
    t0 = pf["start_ms"] / 1000
    codes = pf["codes"]
    out: dict = dict(recording=pf["recording"], start=iso(t0), epochs=pf["epochs"], detector=pf["detector"],
                     read=pf["read"], coverage=pf["coverage"], median_bpm=pf["median_bpm"],
                     why={c: codes.count(c) for c in "rngxmsuo" if codes.count(c)})
    if stages is not None:
        st = stages[:len(bpm)] + ["?"] * max(0, len(bpm) - len(stages))
        out["by_stage"] = {s: dict(epochs=n, read=r, median=r1(m)) for s, (n, r, m) in pl.by_stage(bpm, st).items()}
        a = pl.asleep(bpm, st)
        out["asleep"] = dict(epochs=a.epochs, read=a.read, share=round(a.share, 4), median=r1(a.median),
                             lowest_5_min=r1(a.lowest))
    if ref_path is not None:
        name, samples = read_reference(ref_path, ref_tz)
        out["reference"] = dict(file=ref_path.name, format=name, samples=len(samples),
                                first=iso(samples[0][0]) if samples else None,
                                last=iso(samples[-1][0]) if samples else None)
        ref = reference_per_epoch(samples, t0, len(bpm))
        out["agreement"] = agreement(bpm, ref)
        if stages is not None:
            asleep = [s in pl.ASLEEP for s in st]
            out["agreement_asleep"] = agreement([b if a else None for b, a in zip(bpm, asleep)], ref)
    out["_file"] = pf
    return out


def words(r: dict) -> str:
    lines = [f"{r['recording']} from {r['start']}: {r['epochs']} epochs of 30 s, {r['read']} with a pulse reading "
             f"({100 * r['coverage']:.1f} %), median {r['median_bpm']}/min; {r['detector']}",
             "  no reading: " + ", ".join(f"{k} {v}" for k, v in r["why"].items() if k not in pl.READ)
             + "  (g gap, x no usable channel, m moving, w walking, s steps, u unclear, o odd one out)"]
    for s, v in r.get("by_stage", {}).items():
        if v["epochs"]:
            lines.append(f"  {s:3s} {v['read']:4d} of {v['epochs']:4d} read, median {v['median']}")
    if "asleep" in r:
        a = r["asleep"]
        lines.append(f"  asleep: about {a['median']}/min (read in {100 * a['share']:.0f} % of it); lowest 5 minutes "
                     f"{a['lowest_5_min']}")
    if "reference" in r:
        f = r["reference"]
        lines.append(f"  reference: {f['file']} ({f['format']}), {f['samples']} samples {f['first']} to {f['last']}")
        for k in ("agreement", "agreement_asleep"):
            if k not in r:
                continue
            g = r[k]
            if not g["pairs"]:
                lines.append(f"  {k}: no epoch with both")
                continue
            lines.append(f"  {k}: {g['pairs']} epochs (read in {100 * g['read_where_reference']:.0f} % of the "
                         f"{g['reference_epochs']} with a reference); bias {g['bias']:+.1f}/min, limits "
                         f"{g['loa_low']:+.1f} to {g['loa_high']:+.1f}, mean difference {g['mae']:.1f}, within 5: "
                         f"{100 * g['within_5']:.0f} %")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("recording", nargs="+", type=Path)
    ap.add_argument("--stages", type=Path)
    ap.add_argument("--start")
    ap.add_argument("--reference", type=Path)
    ap.add_argument("--reference-tz", type=offset)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        r = report(a.recording, a.stages, a.start, a.reference, a.reference_tz)
    except ReferenceError as e:
        print(f"reference: {e}", file=sys.stderr)
        return 2
    pf = r.pop("_file")
    if a.out is not None:
        a.out.write_text(json.dumps(pf, separators=(",", ":")) + "\n")
    print(json.dumps(r, indent=1) if a.json else words(r))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
