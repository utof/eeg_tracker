"""Append events in utof_tracker's envelope: eeg_sleep_night (from score_sleep.py's <night>.sleep.json, or a sleep
report), eeg_morning_check (from a <stamp>.morning.json), and with --daily also eeg_day (one per day: every number the
phone's Trends page has, scripts/day_summary.py) and eeg_measure_set (what those numbers are).

usage: export_events.py <night>.sleep.json | <stamp>.morning.json [...] [--root _local/export]
       export_events.py --daily [--local _local] [--root _local/export]     (the daily command, docs/utof-interface.md)
Writes <root>/events/<dev>/eeg-YYYY-MM.jsonl. Same result twice: nothing added. A changed result for a night, a
check-in or a day already exported: a new event whose data.replaces is the newest earlier id. Format:
docs/data-format.md; the contract for utof_tracker: docs/utof-interface.md.
"""
import argparse, hashlib, json, os, secrets
from datetime import datetime, timedelta
from pathlib import Path

MODEL = "anysleep-mid-fusion-3runs@88e13e3"
CROSS = "yasa-0.8.1 O1-T3"
CODE = {"W": "W", "N1": "1", "N2": "2", "N3": "3", "R": "R", "gap": "-"}
ASLEEP = set("123R")
DEVICE = dict(model="BrainBit Black", channels=["O1", "O2", "T3", "T4"])


def zone_name() -> str | None:
    try:
        target = os.readlink("/etc/localtime")
        return target.split("zoneinfo/", 1)[1] if "zoneinfo/" in target else None
    except OSError:
        return None


def device_id(root: Path) -> str:
    f = root / "device_id"
    if not f.exists():
        root.mkdir(parents=True, exist_ok=True); f.write_text(f"eeg-pc-{secrets.token_hex(4)}\n")
    return f.read_text().strip()


def read_events(folder: Path) -> list[dict]:
    out = []
    for f in sorted(folder.glob("eeg-*.jsonl")):
        for line in f.read_text().splitlines(keepends=True):
            if line.endswith("\n"):
                try: out.append(json.loads(line))
                except json.JSONDecodeError: pass
    return out


def _hypnogram_data(hyp: str, t, stage_min: dict, recorded_min: float, model: str, cross: dict | None,
                    confidence) -> tuple[datetime, dict]:
    """The fields of eeg_sleep_night from a hypnogram (one character per 30 s, `W 1 2 3 R -`) whose epoch i starts
    at t(i)."""
    scored = [i for i, c in enumerate(hyp) if c != "-"]
    first, last = scored[0], scored[-1]
    hyp = hyp[first:last + 1]
    sleep = [i for i, c in enumerate(hyp) if c in ASLEEP]
    start = t(first)
    data = dict(
        night_of=(start - timedelta(hours=12)).date().isoformat(),
        start=start.isoformat(timespec="seconds"), end=t(last + 1).isoformat(timespec="seconds"),
        sleep_onset=t(first + sleep[0]).isoformat(timespec="seconds") if sleep else None,
        final_wake=t(first + sleep[-1] + 1).isoformat(timespec="seconds") if sleep else None,
        total_sleep_min=len(sleep) / 2,
        wake_after_onset_min=hyp[sleep[0]:sleep[-1] + 1].count("W") / 2 if sleep else 0.0,
        stage_min=stage_min, recorded_min=recorded_min, gap_min=hyp.count("-") / 2,
        hypnogram=hyp, epoch_s=30, model=model, cross_check=cross,
        confidence=confidence, validated=False, device=DEVICE,
    )
    return start, data


def night_event(res: dict) -> tuple[datetime, dict]:
    """(local start with offset, data) from one score_sleep.py result."""
    ep = res["epochs"]
    hyp = "".join(CODE.get(e["anysleep"], "-") for e in ep)
    if not any(c != "-" for c in hyp):
        raise SystemExit(f"{res['source']}: no scored epochs")
    t = lambda i: datetime.fromisoformat(ep[0]["t"]).astimezone() + timedelta(seconds=30 * i)  # noqa: E731
    s = res["summary"]
    start, data = _hypnogram_data(
        hyp, t, s["stage_min"], s["recorded_min"], MODEL,
        dict(model=CROSS, agreement_5_stage=s.get("agreement_5_stage"),
             agreement_w_nrem_rem=s.get("agreement_w_nrem_rem")),
        s.get("anysleep_mean_confidence"))
    assert len(ep) >= len(data["hypnogram"])
    return start, data


def report_night_event(rep: dict) -> tuple[datetime, dict] | None:
    """(start, data) from a sleep report's `stages` (the phone's, which has no <night>.sleep.json); None when the
    report has no scored epoch. `night_of` is the report's own."""
    hyp = rep.get("stages") if isinstance(rep.get("stages"), str) else ""
    if not any(c in "WR123" for c in hyp):
        return None
    hyp = "".join(c if c in "WR123" else "-" for c in hyp)
    t0 = datetime.fromisoformat(rep["data_start"])
    t = lambda i: t0 + timedelta(seconds=30 * i)  # noqa: E731
    stage_min = {k: hyp.count(c) / 2 for k, c in (("W", "W"), ("N1", "1"), ("N2", "2"), ("N3", "3"), ("R", "R"))}
    conf = [(p.get("confidence"), p.get("asleep_min")) for p in rep.get("periods") or [] if isinstance(p, dict)]
    conf = [(c, w) for c, w in conf if isinstance(c, (int, float)) and isinstance(w, (int, float)) and w > 0]
    confidence = round(sum(c * w for c, w in conf) / sum(w for _, w in conf), 3) if conf else None
    start, data = _hypnogram_data(hyp, t, stage_min, sum(stage_min.values()), str(rep.get("model") or MODEL),
                                  rep.get("cross_check") if isinstance(rep.get("cross_check"), dict) else None,
                                  confidence)
    data["night_of"] = rep["night_of"]
    return start, data


MORNING_KEYS = ("alpha_ec_uv2", "alpha_eo_uv2", "ec_rise", "iaf_hz", "iaf_peak_hz", "alpha_peak_present",
                "aperiodic_slope_ec", "clean_share_ec", "clean_share_eo")


def morning_event(res: dict) -> tuple[datetime, dict]:
    """(local start with offset, data) from one morning_check.py result (or the phone's, which adds the reaction
    test, the day-before habits and the owner's "Was this you?" answer: each only when present)."""
    if "back" not in res:
        raise SystemExit(f"{res.get('source')}: not a morning check-in result")
    start = datetime.fromisoformat(res["start"])
    b = res["back"]
    data = dict(
        date=res["date"], start=res["start"], end=res.get("end"), phase_s=res["phase_s"],
        alpha_ec_uv2=b["alpha_ec_uv2"], alpha_eo_uv2=b["alpha_eo_uv2"], ec_rise=b["ec_rise"], iaf_hz=b["iaf_hz"],
        aperiodic_slope_ec=b["aperiodic_slope_ec"], clean_share=b["clean_share"],
        channels={n: {k: c.get(k) for k in MORNING_KEYS} for n, c in res["channels"].items()},
        ratings=res.get("ratings"),
        setup_visible={k: v["visible"] for k, v in (res.get("setup_test") or {}).items()} or None,
        method=res["version"], validated=False,
        device=res.get("device") or DEVICE,
    )
    if isinstance(res.get("reaction"), dict):
        data["reaction_ms"] = res["reaction"].get("median_ms")
    if isinstance(res.get("habits"), dict):
        data["habits"] = res["habits"]
    if isinstance(res.get("wearer"), dict):
        data["wearer"] = res["wearer"].get("answer")
    return start, data


class Folder:
    """The export folder of this computer (`<root>/events/<dev>/`): appends events, reading what is there once."""

    def __init__(self, root: Path):
        self.dev = device_id(root)
        self.dir = root / "events" / self.dev
        self.dir.mkdir(parents=True, exist_ok=True)
        self.events = read_events(self.dir)
        self.ids = {e.get("id") for e in self.events}

    def add(self, kind: str, ts: datetime, data: dict, key: str, same_as) -> str:
        """Appends one event unless one with the same id (sha1 of `key`) exists. An earlier event of `kind` that
        `same_as` matches is replaced (the newest of them). Returns `unchanged`, `new` or `replaced`."""
        eid = "eeg:" + hashlib.sha1(key.encode()).hexdigest()
        if eid in self.ids:
            return "unchanged"
        same = [e for e in self.events if e.get("type") == kind and same_as(e)]
        if same:
            data["replaces"] = max(same, key=lambda e: (e["ts"], e["seq"]))["id"]
        f = self.dir / f"eeg-{ts:%Y-%m}.jsonl"
        seq = 1
        if f.exists():
            done = [ln for ln in f.read_text().splitlines(keepends=True) if ln.endswith("\n")]
            seq = (json.loads(done[-1])["seq"] + 1) if done else 1
        ev = dict(v=1, id=eid, dev=self.dev, seq=seq, ts=ts.isoformat(timespec="seconds"), tz=zone_name(),
                  type=kind, data=data)
        with open(f, "a", encoding="utf-8") as out:
            out.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.events.append(ev)
        self.ids.add(eid)
        return "replaced" if same else "new"


def add_night(folder: Folder, start: datetime, data: dict, wearer: str | None = None) -> str:
    key = f"{data['start']}|{data['model']}|{data['hypnogram']}"
    if wearer:  # an answer changes the event (old ids, made without one, stay as they were)
        data["wearer"] = wearer
        key += f"|wearer={wearer}"
    return folder.add("eeg_sleep_night", start, data, key,
                      lambda e, d=data: e["data"].get("night_of") == d["night_of"])


def add_morning(folder: Folder, start: datetime, data: dict) -> str:
    key = f"{data['start']}|morning|" + json.dumps(data, sort_keys=True)
    return folder.add("eeg_morning_check", start, data, key, lambda e, d=data: e["data"].get("start") == d["start"])


def export_files(folder: Folder, results: list[Path]) -> None:
    for path in results:
        res = json.loads(path.read_text())
        if path.name.endswith(".morning.json"):
            start, data = morning_event(res)
            done = add_morning(folder, start, data)
            what = f"morning check-in {data['date']}"
        else:
            start, data = night_event(res)
            done = add_night(folder, start, data)
            what = f"night of {data['night_of']}, {data['total_sleep_min']} min asleep"
        print(f"{path.name}: {what}: {'already exported' if done == 'unchanged' else done}"
              f" -> {folder.dir / f'eeg-{start:%Y-%m}.jsonl'}")


def export_daily(folder: Folder, local: Path, now: datetime | None = None) -> dict:
    """Everything eeg_tracker has in `local` (`_local/`): the measure list, a night event per sleep report, a check-in
    event per check-in, a day event per day. Returns counts per type: new, replaced, unchanged."""
    import day_summary as ds  # here: the single-file use above needs nothing of it

    now = now or datetime.now().astimezone()
    counts: dict[str, dict[str, int]] = {}

    def count(kind: str, done: str) -> None:
        counts.setdefault(kind, dict(new=0, replaced=0, unchanged=0))[done] += 1

    m = ds.measure_set()
    count("eeg_measure_set", folder.add("eeg_measure_set", now, m, "measures|" + json.dumps(m, sort_keys=True),
                                        lambda e, v=m["version"]: e["data"].get("version") == v))
    for rep in ds.read_reports(local):
        side = rep["_file"].parent / str(rep.get("sleep_json") or "")
        if rep["_origin"] == "laptop" and rep.get("sleep_json") and side.is_file():
            try:
                start, data = night_event(json.loads(side.read_text()))
            except (SystemExit, ValueError, KeyError, TypeError, IndexError):
                continue  # a damaged or unscored file beside the report: the day numbers still use the report
        else:
            made = report_night_event(rep)
            if made is None:
                continue
            start, data = made
        count("eeg_sleep_night", add_night(folder, start, data, rep["_wearer"]))
    for res in ds.read_mornings(local):
        start, data = morning_event(res)
        count("eeg_morning_check", add_morning(folder, start, data))
    for data in ds.day_events(local, now):
        ts = datetime.fromisoformat(f"{data['day']}T{ds.DAY_START_HOUR:02d}:00:00").astimezone()
        key = f"{data['day']}|eeg_day|" + json.dumps(data, sort_keys=True)
        count("eeg_day", folder.add("eeg_day", ts, data, key, lambda e, d=data["day"]: e["data"].get("day") == d))
    return counts


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="*", type=Path)
    ap.add_argument("--root", type=Path, default=Path("_local/export"))
    ap.add_argument("--daily", action="store_true", help="export every day, night and check-in found in --local")
    ap.add_argument("--local", type=Path, default=Path("_local"), help="the _local/ folder to read (with --daily)")
    a = ap.parse_args()
    if not a.results and not a.daily:
        ap.error("give result files, or --daily")
    folder = Folder(a.root)
    export_files(folder, a.results)
    if a.daily:
        counts = export_daily(folder, a.local)
        for kind, c in counts.items():
            print(f"{kind}: {c['new']} new, {c['replaced']} replaced, {c['unchanged']} unchanged")
        print(f"-> {folder.dir}")


if __name__ == "__main__":
    main()
