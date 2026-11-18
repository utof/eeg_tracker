"""Re-publish the recorder's live stream as Lab Streaming Layer (LSL) streams, so standard EEG tools can read it.

usage: uv run --no-project --with pylsl python scripts/lsl_bridge.py [--url http://localhost:8765/stream] [--token <t>]

The recorder (scripts/record_night.py) owns the headband's single Bluetooth connection and records to disk; this
bridge is one of any number of consumers of its /stream endpoint. It creates two LSL outlets:
  "BrainBit"          type EEG, 4 channels O1 O2 T3 T4 in microvolts, 250 Hz
  "BrainBit-markers"  type Markers, the text of every page marker
Readers: MNE-LSL (mne_lsl.stream.StreamLSL), OpenViBE, BrainFlow's LSL board, LabRecorder, any pylsl script.
The phone app's recording works too: switch Share on Wi-Fi on there and pass `--url http://<phone-ip>:8765/stream
--token <t>` (or EEG_PHONE_TOKEN).
Runs in its own process, so it may import anything; the recorder itself must stay free of numpy.
"""
import argparse, json, os, socket, time, urllib.request

import pylsl


def outlets(names: list[str], fs: float) -> tuple[pylsl.StreamOutlet, pylsl.StreamOutlet]:
    info = pylsl.StreamInfo("BrainBit", "EEG", len(names), fs, "float32", f"brainbit-{socket.gethostname()}")
    chans = info.desc().append_child("channels")
    for n in names:
        c = chans.append_child("channel"); c.append_child_value("label", n)
        c.append_child_value("unit", "microvolts"); c.append_child_value("type", "EEG")
    info.desc().append_child_value("manufacturer", "BrainBit")
    marks = pylsl.StreamInfo("BrainBit-markers", "Markers", 1, pylsl.IRREGULAR_RATE, "string",
                             f"brainbit-markers-{socket.gethostname()}")
    return pylsl.StreamOutlet(info, chunk_size=25), pylsl.StreamOutlet(marks)


OUT: dict = {}  # the outlets live across reconnects, so LSL readers keep their stream when the recorder restarts


def run(url: str, token: str | None = None) -> None:
    sent = 0; t_report = time.time()
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"} if token else {})
    with urllib.request.urlopen(req, timeout=30) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            ev = json.loads(line[6:])
            if ev.get("hello"):
                if not OUT:
                    OUT["eeg"], OUT["marks"] = outlets(ev["names"], ev["fs"])
                    print(f"LSL outlets up: BrainBit ({len(ev['names'])} ch, {ev['fs']} Hz) and BrainBit-markers", flush=True)
            elif "marker" in ev and OUT:
                OUT["marks"].push_sample([ev["marker"]])
            elif "uv" in ev and OUT:
                OUT["eeg"].push_chunk(ev["uv"]); sent += len(ev["uv"])
            if time.time() - t_report > 30 and OUT:
                print(f"{sent} samples sent; readers connected: {OUT['eeg'].have_consumers()}", flush=True)
                t_report = time.time()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8765/stream")
    ap.add_argument("--token", default=os.environ.get("EEG_PHONE_TOKEN"), help="the phone app's Share on Wi-Fi token")
    a = ap.parse_args()
    while True:  # the recorder restarts itself after Bluetooth drops: reconnect to it
        try:
            run(a.url, a.token)
        except KeyboardInterrupt:
            return
        except Exception as e:
            print(f"stream lost ({e}); retrying in 3 s", flush=True); time.sleep(3)


if __name__ == "__main__":
    main()
