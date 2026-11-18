"""Append eeg_sleep_night events (utof_tracker's event envelope) from score_sleep.py results.

usage: export_events.py <night>.sleep.json [...] [--root _local/export]
Writes <root>/events/<dev>/eeg-YYYY-MM.jsonl. Same result twice: nothing added. A changed result for a night
already exported: a new event whose data.replaces is the newest earlier id. Format: docs/data-format.md.
"""
import argparse, hashlib, json, os, secrets
from datetime import datetime, timedelta
from pathlib import Path

MODEL = "anysleep-mid-fusion-3runs@88e13e3"
CROSS = "yasa-0.8.1 O1-T3"
CODE = {"W": "W", "N1": "1", "N2": "2", "N3": "3", "R": "R", "gap": "-"}
ASLEEP = set("123R")


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


def night_event(res: dict) -> tuple[datetime, dict]:
    """(local start with offset, data) from one score_sleep.py result."""
    ep = res["epochs"]; n = len(ep)
    hyp = "".join(CODE.get(e["anysleep"], "-") for e in ep)
    scored = [i for i, c in enumerate(hyp) if c != "-"]
    if not scored:
        raise SystemExit(f"{res['source']}: no scored epochs")
    t = lambda i: datetime.fromisoformat(ep[0]["t"]).astimezone() + timedelta(seconds=30 * i)  # noqa: E731
    first, last = scored[0], scored[-1]
    hyp = hyp[first:last + 1]
    sleep = [i for i, c in enumerate(hyp) if c in ASLEEP]
    s = res["summary"]; start = t(first)
    data = dict(
        night_of=(start - timedelta(hours=12)).date().isoformat(),
        start=start.isoformat(timespec="seconds"), end=t(last + 1).isoformat(timespec="seconds"),
        sleep_onset=t(first + sleep[0]).isoformat(timespec="seconds") if sleep else None,
        final_wake=t(first + sleep[-1] + 1).isoformat(timespec="seconds") if sleep else None,
        total_sleep_min=len(sleep) / 2,
        wake_after_onset_min=hyp[sleep[0]:sleep[-1] + 1].count("W") / 2 if sleep else 0.0,
        stage_min=s["stage_min"], recorded_min=s["recorded_min"], gap_min=hyp.count("-") / 2,
        hypnogram=hyp, epoch_s=30, model=MODEL,
        cross_check=dict(model=CROSS, agreement_5_stage=s.get("agreement_5_stage"),
                         agreement_w_nrem_rem=s.get("agreement_w_nrem_rem")),
        confidence=s.get("anysleep_mean_confidence"), validated=False,
        device=dict(model="BrainBit Black", channels=["O1", "O2", "T3", "T4"]),
    )
    assert n >= len(hyp)
    return start, data


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="+", type=Path)
    ap.add_argument("--root", type=Path, default=Path("_local/export"))
    a = ap.parse_args()
    dev = device_id(a.root); folder = a.root / "events" / dev; folder.mkdir(parents=True, exist_ok=True)
    for path in a.results:
        start, data = night_event(json.loads(path.read_text()))
        key = f"{data['start']}|{MODEL}|{data['hypnogram']}"
        eid = "eeg:" + hashlib.sha1(key.encode()).hexdigest()
        old = [e for e in read_events(folder) if e.get("type") == "eeg_sleep_night"]
        if any(e["id"] == eid for e in old):
            print(f"{path.name}: already exported ({eid[:16]}…)"); continue
        same = [e for e in old if e["data"].get("night_of") == data["night_of"]]
        if same:
            data["replaces"] = max(same, key=lambda e: (e["ts"], e["seq"]))["id"]
        f = folder / f"eeg-{start:%Y-%m}.jsonl"
        seq = 1
        if f.exists():
            done = [ln for ln in f.read_text().splitlines(keepends=True) if ln.endswith("\n")]
            seq = (json.loads(done[-1])["seq"] + 1) if done else 1
        ev = dict(v=1, id=eid, dev=dev, seq=seq, ts=data["start"], tz=zone_name(), type="eeg_sleep_night", data=data)
        with open(f, "a", encoding="utf-8") as out:
            out.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
        print(f"{path.name}: night of {data['night_of']}, {data['total_sleep_min']} min asleep -> {f}")


if __name__ == "__main__":
    main()
