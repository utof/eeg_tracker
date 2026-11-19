"""The live routes' JSON of the laptop recorder (scripts/recorder_hub.py) against app/test/fixtures/share_api.json, the
same list the phone app's Share on Wi-Fi server is tested against (app/test/share_server_test.dart): if a route's
fields change here, the phone must follow."""
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from recorder_hub import Hub  # noqa: E402

SHAPES = json.loads((ROOT / "app" / "test" / "fixtures" / "share_api.json").read_text())


def test_the_laptop_recorders_routes_have_the_listed_fields(tmp_path):
    hub = Hub(tmp_path / "recordings")
    hub.open_files("2026-11-19-030000")
    hub.serve(0)
    base = f"http://127.0.0.1:{hub.server.server_address[1]}"
    try:
        hub.add_batch([(i, i * 1e-6, 2e-6, -1e-6, 0.0) for i in range(1250)], now=1763500000.0)
        hub.set_contact(dict(O1=4e5, O2=1.5e6, T3=float("inf"), T4=float("inf")))
        state = json.load(urllib.request.urlopen(f"{base}/state"))
        assert list(state) == SHAPES["state_keys"]
        assert state["names"] == SHAPES["names"] and state["fs"] == SHAPES["fs"]
        assert [len(c) for c in state["data"]] == [SHAPES["fs"] * SHAPES["state_seconds"]] * 4
        assert state["data"][0][0] == -499.5 and state["data"][0][-1] == 499.5  # as the phone's test expects
        assert state["contact"] == dict(O1=400000, O2=1500000, T3=None, T4=None)

        stream = urllib.request.urlopen(f"{base}/stream", timeout=5)
        events = []

        def read() -> dict:
            while True:
                line = stream.readline().decode().strip()
                if line.startswith("data: "):
                    events.append(json.loads(line[6:]))
                    return events[-1]

        assert set(read()) == set(SHAPES["hello_keys"]) and events[0]["next_i"] == 1250
        hub.add_batch([(0, 10e-6, 2e-6, -1e-6, 0.0), (1, 11e-6, 2e-6, -1e-6, 0.0)], now=1763500000.1004)
        assert read() == dict(i=1250, t=1763500000.1, uv=[[10.0, 2.0, -1.0, 0.0], [11.0, 2.0, -1.0, 0.0]])
        assert set(events[1]) == set(SHAPES["batch_keys"])
        req = urllib.request.Request(f"{base}/marker", data=b"  eyes closed start \n", method="POST")
        assert urllib.request.urlopen(req).read() == b"ok"
        marker = read()
        assert set(marker) == set(SHAPES["marker_keys"]) and marker["marker"] == "eyes closed start"
        stream.close()
        hub.markf.flush()
        line = json.loads((tmp_path / "recordings" / "2026-11-19-030000.markers.jsonl").read_text().splitlines()[0])
        assert list(line) == SHAPES["marker_file_keys"]
    finally:
        hub.server.shutdown(); hub.server.server_close(); hub.finish(); hub.close()
