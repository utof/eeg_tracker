"""End to end: the real recorder with the fake headband, markers posted like morning.html?short=1 does.

The fake's back channels carry strong 10 Hz alpha for the first 60 s of signal and weak alpha for the next 60 s,
so markers at 1-59 s (eyes closed) and 61-119 s (eyes open) must give a large eyes-closed rise and ~10 Hz.
About 2.5 minutes. Skip with: pytest -m "not slow".
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

import morning_check as mc

ROOT = Path(__file__).resolve().parents[2]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def post(port: int, name: str, body: str = "") -> None:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/{name}", data=body.encode(), method="POST")
    assert urllib.request.urlopen(req, timeout=5).read() == b"ok"


@pytest.mark.slow
def test_morning_check_on_fake_headband(tmp_path, monkeypatch, capsys):
    port = free_port()
    env = dict(os.environ, PYTHONPATH=str(ROOT / "tests" / "fake_neurosdk"), FAKE_BRAINBIT_SEED="7")
    log = open(tmp_path / "recorder.out", "w")
    # the recorder must run without numpy: use the system python, not this environment's
    proc = subprocess.Popen(["python3", str(ROOT / "scripts" / "record_night.py"), "--port", str(port),
                             "--out", str(tmp_path), "--seconds", "135"], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        # the recorder writes .idx only every 10 s; /state shows samples as soon as they arrive
        deadline = time.time() + 40; t0 = None
        while time.time() < deadline and t0 is None:
            try:
                st = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/state", timeout=2).read())
                if st["data"][0]:
                    t0 = time.time() - len(st["data"][0]) / 250 - 0.05  # minus about half a batch of delivery delay
            except OSError:
                pass
            time.sleep(0.02)
        assert t0, (tmp_path / "recorder.out").read_text()
        # the page fetches these too; check they answer
        page = urllib.request.urlopen(f"http://127.0.0.1:{port}/morning.html", timeout=5).read()
        assert b"Morning check-in" in page and b"morning.js" in page
        assert b"export function" in urllib.request.urlopen(f"http://127.0.0.1:{port}/morning-core.js", timeout=5).read()
        plan = [(0.5, "morning:start"), (1, "morning:eyes_closed:start"), (59, "morning:eyes_closed:end"),
                (61, "morning:eyes_open:start"), (119, "morning:eyes_open:end"),
                (121, 'morning:ratings {"kss":5,"mood":3,"tension":2}'), (121.5, "morning:end")]
        for at, text in plan:
            time.sleep(max(0.0, t0 + at - time.time()))
            post(port, "marker", text)
        state = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/state", timeout=5).read())
        assert state["names"] == ["O1", "O2", "T3", "T4"] and len(state["data"][0]) == 1000
        proc.wait(timeout=60)
    finally:
        if proc.poll() is None:
            proc.terminate(); proc.wait(timeout=10)
        log.close()
    monkeypatch.setattr("sys.argv", ["morning_check.py", str(tmp_path)])
    mc.main()
    out = capsys.readouterr().out
    sys.stdout.write(out)
    res = json.loads(next(tmp_path.glob("*.morning.json")).read_text())
    for ch in ("O1", "O2"):
        c = res["channels"][ch]
        assert c["ec_rise"] > 5, c  # the fake: (25/6)^2 ~ 17 before noise
        assert abs(c["iaf_hz"] - 10) < 0.3, c
        assert c["clean_share_ec"] > 0.6 and c["clean_share_eo"] > 0.6, c
    assert res["back"]["ec_rise"] > 5
    assert res["ratings"] == {"kss": 5, "mood": 3, "tension": 2}
    assert 57 < res["phase_s"]["eyes_closed"] < 59 and 57 < res["phase_s"]["eyes_open"] < 59, res["phase_s"]
    m = [json.loads(x) for x in next(tmp_path.glob("*.markers.jsonl")).read_text().splitlines()]
    assert m[1]["i"] < 500 and 14000 < m[2]["i"] < 15000, m  # aligned with the fake's 60 s switch
    assert "Eyes-closed rise" in out
