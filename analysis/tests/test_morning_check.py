"""Unit tests for scripts/morning_check.py on synthetic signals (no headband needed).

Run: uv run --project analysis --with pytest pytest analysis/tests
"""
import json
from datetime import datetime
import struct

import numpy as np
import pytest

import morning_check as mc

FS = 250
rng = np.random.default_rng(1)


def pink(n: int, uv: float = 5.0, exponent: float = 1.0) -> np.ndarray:
    """Noise with power ~ 1/f^exponent, scaled to the given spread."""
    spec = rng.normal(size=n // 2 + 1) + 1j * rng.normal(size=n // 2 + 1)
    f = np.fft.rfftfreq(n, 1 / FS); f[0] = f[1]
    x = np.fft.irfft(spec / f ** (exponent / 2), n)
    return x / x.std() * uv


def alpha(n: int, hz: float, uv: float) -> np.ndarray:
    t = np.arange(n) / FS
    return uv * np.sin(2 * np.pi * hz * t + rng.uniform(0, 6))


def test_alpha_frequency_and_rise():
    n = 60 * FS
    ec = pink(n) + alpha(n, 9.5, 20)
    eo = pink(n) + alpha(n, 9.5, 4)
    r = mc.channel_measures(ec, eo)
    assert r["alpha_peak_present"]
    assert abs(r["iaf_hz"] - 9.5) < 0.3
    assert abs(r["iaf_peak_hz"] - 9.5) < 0.3
    assert r["ec_rise"] > 10
    assert r["clean_share_ec"] == 1.0


def test_lower_alpha_frequency_is_seen():
    n = 60 * FS
    fast = mc.channel_measures(pink(n) + alpha(n, 10.5, 15), None)
    slow = mc.channel_measures(pink(n) + alpha(n, 8.8, 15), None)
    assert slow["iaf_hz"] < fast["iaf_hz"] - 1.0


def test_no_alpha_no_frequency():
    r = mc.channel_measures(pink(60 * FS), pink(60 * FS))
    assert not r["alpha_peak_present"] and r["iaf_hz"] is None
    assert 0.5 < r["ec_rise"] < 2


@pytest.mark.parametrize("exponent", [1.0, 2.0])
def test_aperiodic_slope(exponent):
    r = mc.channel_measures(pink(60 * FS, exponent=exponent), None)
    assert abs(r["aperiodic_slope_ec"] + exponent) < 0.25


def test_artefacts_rejected_and_counted():
    n = 60 * FS
    x = pink(n) + alpha(n, 10, 15)
    x[10 * FS : 10 * FS + 50] += 400  # a big jump, like a moved electrode
    x[30 * FS : 34 * FS] = 0.0  # flat: lost contact
    segs, keep = mc.clean_segments(x)
    assert len(keep) == 30
    assert not keep[5] and not keep[15] and not keep[16]
    assert keep.sum() >= 25
    r = mc.channel_measures(x, None)
    assert 0.8 < r["clean_share_ec"] < 1.0
    assert abs(r["iaf_hz"] - 10) < 0.3


def test_too_little_clean_data_gives_empty_values():
    r = mc.channel_measures(pink(10 * FS), None)
    assert r["alpha_ec_uv2"] is None and r["iaf_hz"] is None


def test_back_summary_geometric_mean():
    ch = {"O1": dict(alpha_ec_uv2=4.0, alpha_eo_uv2=1.0, ec_rise=4.0, iaf_hz=10.0, aperiodic_slope_ec=-1.0,
                     clean_share_ec=1.0, clean_share_eo=0.5),
          "O2": dict(alpha_ec_uv2=16.0, alpha_eo_uv2=1.0, ec_rise=16.0, iaf_hz=None, aperiodic_slope_ec=-2.0,
                     clean_share_ec=1.0, clean_share_eo=0.5)}
    b = mc.back_summary(ch)
    assert b["alpha_ec_uv2"] == 8.0 and b["ec_rise"] == 8.0
    assert b["iaf_hz"] == 10.0 and b["aperiodic_slope_ec"] == -1.5 and b["clean_share"] == 0.75


def test_sessions_take_latest_complete_and_skip_aborted():
    m = lambda t, i, text: dict(t=t, i=i, text=text)  # noqa: E731
    marks = [m(1, 0, "morning:start"), m(2, 10, "morning:eyes_closed:start"), m(3, 20, "morning:eyes_closed:end"),
             m(4, 20, "morning:eyes_open:start"), m(5, 30, "morning:eyes_open:end"),
             m(6, 30, 'morning:ratings {"kss":7,"mood":2,"tension":4}'), m(7, 31, "morning:end"),
             m(8, 40, "morning:start"), m(9, 41, "morning:eyes_closed:start"), m(10, 42, "morning:abort"),
             m(11, 50, "setup:start"), m(12, 51, "setup:blink")]
    ss = mc.sessions(marks, "morning")
    assert len(ss) == 2
    assert mc.morning_windows(ss[1]) is None
    w = mc.morning_windows(ss[0])
    assert w["win"]["eyes_closed"][:2] == (10, 20) and w["win"]["eyes_open"][:2] == (20, 30)
    assert w["ratings"] == {"kss": 7, "mood": 2, "tension": 4}
    assert len(mc.sessions(marks, "setup")) == 1


def write_recording(path, uv, marks):
    """A .f32 / .idx / .markers.jsonl set like record_night.py writes (volts in the file)."""
    with open(path, "wb") as f:
        for k, row in enumerate(uv):
            f.write(struct.pack("<I4f", k % 65536, *(row * 1e-6)))
    with open(path.with_suffix(".idx"), "wb") as f:
        for k in range(0, len(uv), 25):
            f.write(struct.pack("<dQ", 1.7e9 + (k + 25) / FS, k))
    path.with_suffix(".markers.jsonl").write_text("".join(json.dumps(m) + "\n" for m in marks))


def test_end_to_end_with_history(tmp_path, monkeypatch, capsys):
    n = 130 * FS
    uv = np.column_stack([pink(n) for _ in range(4)])
    for c in (0, 1):
        uv[: 65 * FS, c] += alpha(65 * FS, 10.0, 20)
        uv[65 * FS :, c] += alpha(n - 65 * FS, 10.0, 4)
    t0 = datetime(2026, 11, 18, 6, 59, 58).timestamp()  # eyes closed starts 07:00:00 local
    marks = [dict(t=t0 + s, i=int(s * FS), text=x) for s, x in
             [(1, "morning:start"), (2, "morning:eyes_closed:start"), (62, "morning:eyes_closed:end"),
              (66, "morning:eyes_open:start"), (126, "morning:eyes_open:end"),
              (128, 'morning:ratings {"kss":5,"mood":3,"tension":2}'), (128.5, "morning:end")]]
    write_recording(tmp_path / "2026-11-18-070000.f32", uv, marks)
    for d in range(3):  # earlier check-ins in the same folder
        (tmp_path / f"2026-11-1{d}-070000.morning.json").write_text(json.dumps(
            dict(start=f"2026-11-1{d}T07:00:00+00:00", back=dict(alpha_ec_uv2=100.0 + d, ec_rise=5.0, iaf_hz=9.8),
                 ratings=dict(kss=4))))
    monkeypatch.setattr("sys.argv", ["morning_check.py", str(tmp_path)])
    mc.main()
    out = capsys.readouterr().out
    res = json.loads((tmp_path / "2026-11-18-070000.morning.json").read_text())
    assert res["back"]["ec_rise"] > 10
    assert abs(res["back"]["iaf_hz"] - 10) < 0.3
    assert res["ratings"] == {"kss": 5, "mood": 3, "tension": 2}
    assert res["phase_s"] == {"eyes_closed": 60.0, "eyes_open": 60.0}
    assert "your last 3" in out and "only 3 earlier" in out


def test_setup_test_snr():
    n = 120 * FS
    uv = np.column_stack([pink(n, 3) for _ in range(4)])
    t = np.arange(n) / FS
    marks = []
    for k in range(20):  # blinks 0.3 s after each cue
        cue = 3 + 3 * k; marks.append(dict(t=cue, i=int(cue * FS), text="setup:blink"))
        uv[:, 0] += 60 * np.exp(-(((t - cue - 0.3) / 0.08) ** 2))
    for k in range(10):  # glances: T3-T4 step of +-40 µV held 1.5 s
        cue = 64 + 4 * k; side = "right" if k % 2 else "left"; sign = -1 if k % 2 else 1
        marks.append(dict(t=cue, i=int(cue * FS), text=f"setup:glance:{side}"))
        held = (t >= cue + 0.25) & (t < cue + 1.5)
        uv[held, 2] += sign * 20; uv[held, 3] -= sign * 20
    for k in range(5):  # clenches: 2 s of strong muscle noise at T3/T4
        a = 106 + 6 * k if 106 + 6 * k + 6 < 120 else None
        if a is None:
            break
        marks += [dict(t=a, i=a * FS, text="setup:clench:start"), dict(t=a + 2, i=(a + 2) * FS, text="setup:clench:end")]
        uv[a * FS : (a + 2) * FS, 2:] += rng.normal(0, 30, size=(2 * FS, 2))
    r = mc.setup_test(uv, marks)
    assert r["blink"]["visible"] and r["blink"]["snr"]["O1"] > 2
    assert r["glance"]["visible"] and r["glance"]["left_uv"] > 0 > r["glance"]["right_uv"]
    assert r["clench"]["visible"] and r["clench"]["n"] >= 2
    # nothing there -> not visible
    quiet = mc.setup_test(np.column_stack([pink(n, 3) for _ in range(4)]), marks)
    assert not quiet["blink"]["visible"] and not quiet["glance"]["visible"] and not quiet["clench"]["visible"]
