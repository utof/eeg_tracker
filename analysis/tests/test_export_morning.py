"""eeg_morning_check events from scripts/export_events.py."""
import json

import export_events as ex

RES = dict(version="morning-v1", source="x.f32", start="2026-11-18T07:00:00+03:00", end="2026-11-18T07:04:10+03:00",
           date="2026-11-18", phase_s=dict(eyes_closed=120.0, eyes_open=120.0),
           channels={n: dict(alpha_ec_uv2=50.0, alpha_eo_uv2=8.0, ec_rise=6.25, iaf_hz=9.9, iaf_peak_hz=10.0,
                             alpha_peak_present=True, aperiodic_slope_ec=-1.4, clean_share_ec=0.9,
                             clean_share_eo=0.8, clean_s_ec=100.0) for n in ("O1", "O2")},
           back=dict(alpha_ec_uv2=50.0, alpha_eo_uv2=8.0, ec_rise=6.25, iaf_hz=9.9, aperiodic_slope_ec=-1.4,
                     clean_share=0.85),
           ratings=dict(kss=6, mood=3, tension=2),
           setup_test=dict(blink=dict(visible=True, best=3.1), clench=dict(visible=False, best=1.2)))


def run(monkeypatch, tmp_path, *files):
    monkeypatch.setattr("sys.argv", ["export_events.py", *map(str, files), "--root", str(tmp_path / "exp")])
    ex.main()
    return [json.loads(x) for f in (tmp_path / "exp" / "events").glob("*/*.jsonl") for x in f.read_text().splitlines()]


def test_morning_event(tmp_path, monkeypatch):
    f = tmp_path / "2026-11-18-070000.morning.json"
    f.write_text(json.dumps(RES))
    ev = run(monkeypatch, tmp_path, f)
    assert len(ev) == 1
    e = ev[0]
    assert e["type"] == "eeg_morning_check" and e["v"] == 1 and e["id"].startswith("eeg:") and e["seq"] == 1
    assert e["ts"] == RES["start"]
    d = e["data"]
    assert d["ec_rise"] == 6.25 and d["iaf_hz"] == 9.9 and d["ratings"] == {"kss": 6, "mood": 3, "tension": 2}
    assert d["setup_visible"] == {"blink": True, "clench": False}
    assert d["validated"] is False and d["method"] == "morning-v1"
    assert "clean_s_ec" not in d["channels"]["O1"]
    assert run(monkeypatch, tmp_path, f) == ev  # same result twice: nothing added
    RES2 = dict(RES, back=dict(RES["back"], iaf_hz=9.7))
    f.write_text(json.dumps(RES2))
    ev = run(monkeypatch, tmp_path, f)
    assert len(ev) == 2 and ev[1]["data"]["replaces"] == ev[0]["id"] and ev[1]["seq"] == 2
