"""Record the owner's DIY ADS1299 board (eeg_ads1299_lab's bench firmware, E9 frames; scripts/diy_board.py) until
Ctrl+C, into the same files and live pages as the BrainBit recorders (scripts/recorder_hub.py, docs/data-format.md).

usage: DRIVER=diy scripts/record_night.sh [--serial /dev/ttyUSB0 | --udp 9000] [--montage FILE | --montage O1,O2,..]
       uv run --no-project --python 3.12 --with pyserial==3.5 python scripts/record_diy.py [same options]
No board: PYTHONPATH=tests/fake_diy python3 scripts/record_diy.py --serial /dev/fake-diy --port 8799 --out /tmp/diy

Answer the board's prompts (R, V, then T or N) in a serial terminal first and close it; this program never writes
to the board (docs/diy-board.md). One process all night: a USB drop is retried once a second in-process (the gap
shows in the .idx arrival times); a board restart or a changed mode starts a new set of files, never joined
silently to the old capture (eeg_ads1299_lab docs/PROTOCOL.md). Missing frames are counted in the .log, never
filled in. Files go to _local/recordings-diy by default, away from the BrainBit nights: the sleep and morning tools
read O1 O2 T3 T4 only. Standard library only (+ pyserial for the serial route).
"""
import argparse, json, os, re, signal, sys, threading, time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find the modules beside this file even under `python3 -I`
import diy_board as db  # noqa: E402
import recording  # noqa: E402
from recorder_hub import Hub  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MADE_BY = "eeg_tracker scripts/record_diy.py"
DEFAULT_MONTAGE = Path(__file__).resolve().parent / "montages" / "diy-breadboard-4.json"
NAME_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,16}$")
RETRY_S = 1.0  # a USB port that is not there fails at once; looking every second costs nothing
STALL_S = 5.0
REPORT_S = 10.0
BATCH_S = 0.04  # read about 10 frames at a time: one .idx row per batch, like the BrainBit's 8-sample packets
MODE_STATUS = {"test": "recording: board test signal, not EEG", "short": "recording: board inputs shorted, not EEG",
               "synthetic": "recording: synthetic data, not EEG"}


@dataclass(frozen=True)
class Montage:
    names: tuple[str, ...]
    label: str
    reference: str = "not given"
    bias: str = "not given"


def load_montage(arg: str | None) -> Montage:
    """--montage: a JSON file with "channels" (and optional "reference", "bias"), or names separated by commas;
    None = the breadboard's planned electrodes (scripts/montages/diy-breadboard-4.json)."""
    if arg is None or arg.endswith(".json") or Path(arg).is_file():
        path = DEFAULT_MONTAGE if arg is None else Path(arg)
        spec = json.loads(path.read_text())
        names = spec.get("channels") if isinstance(spec, dict) else None
        if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
            raise ValueError(f"{path}: needs \"channels\": a list of names")
        label = str(path.resolve().relative_to(ROOT)) if path.resolve().is_relative_to(ROOT) else str(path)
        m = Montage(tuple(n.strip() for n in names), label, str(spec.get("reference", "not given")),
                    str(spec.get("bias", "not given")))
    else:
        m = Montage(tuple(n.strip() for n in arg.split(",")), "from --montage")
    bad = [n for n in m.names if not NAME_RE.match(n)]
    if bad or not 1 <= len(m.names) <= 8 or len(set(m.names)) != len(m.names):
        raise ValueError(f"montage names must be 1-8 different names of up to 16 letters, digits, _ . -; got {m.names}")
    return m


def channel_names(names: tuple[str, ...], n: int) -> tuple[tuple[str, ...], str | None]:
    """The montage's names when they match the board's channel count, else Ch1..ChN and why."""
    if len(names) == n:
        return names, None
    return tuple(f"Ch{i}" for i in range(1, n + 1)), (
        f"the montage names {len(names)} channels but the board sends {n}: using Ch1..Ch{n}; "
        f"pass --montage with {n} names")


def header_for(montage: Montage, names: tuple[str, ...], fs: int, mismatch: bool) -> recording.Header:
    """The file set's <stamp>.header.json (scripts/recording.py): the channels the .f32 holds, the layout they come
    from (the montage; "DIY board" when its names did not fit and the channels are Ch1..ChN), and the montage's words
    for where the reference and the bias sit (a plan)."""
    said = lambda text: None if text == "not given" else text  # noqa: E731
    return recording.diy_board(names, fs, layout=recording.DIY_BOARD if mismatch else montage.label,
                               reference=said(montage.reference), bias=said(montage.bias), made_by=MADE_BY)


def timestamped(msg: str) -> str:
    from datetime import datetime
    return f"{datetime.now().isoformat(timespec='milliseconds')} {msg}"


class Recording:
    """Glue between the board's frames and the hub; everything runs in the main loop's thread."""

    def __init__(self, hub: Hub, montage: Montage, vref: float, port: int, seconds: float) -> None:
        self.hub, self.montage, self.vref, self.port, self.seconds = hub, montage, vref, port, seconds
        self.tracker = db.Tracker()
        self.link_desc = "?"
        self.senders_seen = 0
        self.early: list[str] = []  # log lines before a file set is open, written into it when it opens
        self.prev_stamp: str | None = None; self.prev_reason = ""
        self.started: float | None = None  # first frame of the run (--seconds counts from here)
        self.last_frame_t: float | None = None; self.stalled = False
        self.halted = False
        self.lost_at: float | None = None
        self.lead_off: tuple[int, int] | None = None
        self.gaps = self.gap_lost = self.gap_board = self.bad = self.skipped = 0  # since the last count lines
        self.counted = dict(duplicates=0, stale=0, timing_anomalies=0)

    # ---- log -------------------------------------------------------------------------------------------------
    def note(self, msg: str) -> None:
        """A log line; before the first file set opens it waits in memory for it."""
        if self.hub.logf is not None:
            self.hub.log(msg)
        else:
            line = timestamped(msg); print(line, flush=True)
            self.early.append(line); del self.early[:-50]

    def flush_counts(self) -> None:
        """The count lines, when anything happened since the last ones."""
        if self.gaps:
            self.hub.log(f"lost {self.gap_lost} samples in {self.gaps} gaps (board missed {self.gap_board}, "
                         f"link lost {self.gap_lost - self.gap_board})")
        if self.bad or self.skipped:
            self.hub.log(f"bad frames {self.bad}, bytes skipped {self.skipped} (CRC or framing; includes board text)")
        tr = self.tracker
        dup, late, clock = (tr.duplicates - self.counted["duplicates"], tr.stale - self.counted["stale"],
                            tr.timing_anomalies - self.counted["timing_anomalies"])
        if dup or late:
            self.hub.log(f"repeated {dup}, late {late} frames dropped")
        if clock:
            self.hub.log(f"device clock off the sample rate at {clock} frames")
        self.counted = dict(duplicates=tr.duplicates, stale=tr.stale, timing_anomalies=tr.timing_anomalies)
        self.gaps = self.gap_lost = self.gap_board = self.bad = self.skipped = 0

    # ---- link ------------------------------------------------------------------------------------------------
    def on_open(self, link: db.SerialLink | db.UdpLink, tries: int) -> None:
        self.link_desc = link.describe()
        if self.lost_at is None:
            self.note(f"board link open: {self.link_desc}")
        else:
            self.note(f"board link back after {time.time() - self.lost_at:.0f} s (try {tries + 1})")
        self.lost_at = None
        self.hub.live["status"] = "board link open, waiting for data"

    def on_lost(self, err: Exception, tries: int) -> None:
        if self.lost_at is None:
            self.lost_at = time.time()
        self.hub.live["status"] = "reconnecting" if self.started else "waiting for the board"
        if tries in (1, 10, 60) or tries % 600 == 0:  # a board left unplugged all night: a few lines, not thousands
            self.note(f"board link lost or not found: {err}; trying again every {RETRY_S:.0f} s (try {tries})")

    # ---- what the board sends --------------------------------------------------------------------------------
    def on_lines(self, lines: list[str]) -> None:
        for line in lines:
            kind = db.text_kind(line)
            self.note(f"board says: {line}")
            if kind in ("banner", "prompt"):
                if self.hub.data is not None:
                    self.end_set("its start-up text")
                self.tracker.reset()
                self.hub.live["status"] = ("board waiting at its prompt: answer it in a serial terminal "
                                           "(this recorder never types)")
            elif kind == "halted":
                self.halted = True
                self.hub.live["status"] = "board halted: " + line.split(":", 1)[-1].strip()

    def on_input(self, reader: db.Reader, frames: list[db.Frame], lines: list[str], now: float) -> None:
        """One poll of the link: firmware text, new UDP senders, the damage counts, then the frames."""
        self.on_lines(lines)
        for _ in reader.take_senders():  # counted, never named: a log line carries no network address
            self.senders_seen += 1
            self.note("datagrams from the board on the Wi-Fi" if self.senders_seen == 1
                      else f"datagrams from sender number {self.senders_seen}")
            if self.senders_seen > 1:
                self.note("more than one sender on this port: is another board or program sending here?")
        bad, skipped = reader.take_counts()
        self.bad += bad; self.skipped += skipped
        self.on_frames(frames, now)

    def on_frames(self, frames: list[db.Frame], now: float) -> None:
        rows: list[tuple] = []
        for f in frames:
            prev = self.tracker.last
            step = self.tracker.observe(f)
            if step.kind in ("duplicate", "stale"):
                continue
            if step.kind in ("restart", "config") and self.hub.data is not None:
                self._add(rows, now); rows = []
                self.end_set(self.restart_reason(prev, f) if step.kind == "restart" else
                             f"configuration changed from {self.config_text(prev)} to {self.config_text(f)}")
            if self.hub.data is None:
                self._add(rows, now); rows = []
                self.begin(f)
            if step.lost:
                self.gaps += 1; self.gap_lost += step.lost; self.gap_board += step.board_missed
            if (f.lead_off_p, f.lead_off_n) != self.lead_off:
                self.lead_off = (f.lead_off_p, f.lead_off_n)
                if any(self.lead_off):
                    self.hub.log(f"status lead-off bits P={f.lead_off_p:#04x} N={f.lead_off_n:#04x} (lead-off "
                                 "detection is off in the bench firmware: not a contact reading)")
            rows.append((f.seq, *f.volts(self.vref)))
        self._add(rows, now)
        if rows:
            if self.stalled:
                self.hub.log(f"data again after {now - (self.last_frame_t or now):.0f} s")
            self.last_frame_t = now; self.stalled = False; self.halted = False
            self.hub.live["status"] = MODE_STATUS.get(self.tracker.last.mode, "recording")

    def _add(self, rows: list[tuple], now: float) -> None:
        if rows:
            self.hub.add_batch(rows, now)

    @staticmethod
    def config_text(f: db.Frame) -> str:
        return f"{f.channels} ch {f.fs} Hz gain {f.gain} {f.mode}"

    @staticmethod
    def restart_reason(prev: db.Frame, f: db.Frame) -> str:
        if (f.seq - prev.seq) % db.U32 >= db.U32 // 2:
            return f"sequence went back from {prev.seq} to {f.seq}"
        return f"device clock went back from {prev.time_us} to {f.time_us} us"

    # ---- file sets -------------------------------------------------------------------------------------------
    def begin(self, f: db.Frame) -> None:
        """The first frame of a capture: files, and the lines that say what is in them."""
        hub = self.hub
        names, mismatch = channel_names(self.montage.names, f.channels)
        hub.configure(names, f.fs, header_for(self.montage, names, f.fs, mismatch is not None))
        hub.open_files()
        hub.log_lines(self.early); self.early = []
        if self.prev_stamp:
            hub.log(f"continues {self.prev_stamp} after a board restart ({self.prev_reason})")
        hub.log(f"driver DIY board (scripts/record_diy.py): eeg_ads1299_lab bench firmware, E9 protocol version 1; "
                f"link {self.link_desc}")
        if mismatch:
            hub.log(mismatch)
        hub.log(f"channels {' '.join(names)} (montage {self.montage.label}: reference {self.montage.reference}; "
                f"bias {self.montage.bias})")
        hub.log(f"board {f.channels} channels, {f.fs} Hz, gain {f.gain}, vref {self.vref:g} V (assumed, --vref; "
                f"volts = counts x vref / (gain x 2^23) = {db.volts_per_count(f.gain, self.vref) * 1e6:.5f} uV per count)")
        hub.log(f"format .f32 records <I{f.channels}f: board sequence number, then {' '.join(names)} in volts; {f.fs} Hz")
        hub.log(f"mode {f.mode_text} (flags {f.flags:#04x})")
        if self.started is None:
            if self.port:
                hub.log(f"live check page on port {self.port}")
            hub.log(f"recording started, {f.fs} Hz, Ctrl+C to stop")
            self.started = time.time()
        hub.last_report = time.time()
        self.lead_off = None

    def end_set(self, reason: str) -> None:
        self.hub.write_pending()
        self.hub.log(f"board restarted ({reason}): this file set ends here")
        self.flush_counts()
        self.prev_stamp = self.hub.end_file_set(); self.prev_reason = reason
        self.counted = dict(duplicates=self.tracker.duplicates, stale=self.tracker.stale,
                            timing_anomalies=self.tracker.timing_anomalies)

    # ---- once a second ---------------------------------------------------------------------------------------
    def tick(self, now: float, stopping: threading.Event) -> None:
        hub = self.hub
        if hub.want_contact.is_set():
            hub.want_contact.clear()
            self.note("contact check asked: this board does not measure contact (lead-off detection is off in the "
                      "bench firmware)")
        if self.seconds and self.started and now - self.started >= self.seconds:
            stopping.set()
        if hub.data is None:
            return
        hub.write_pending()
        if self.last_frame_t and not self.stalled and now - self.last_frame_t >= STALL_S:
            self.stalled = True
            hub.log(f"no data from the board for {STALL_S:.0f} s (halted, unplugged, restarted or at a prompt?)")
            if not self.halted and self.lost_at is None:
                hub.live["status"] = "no data from the board"
        if now - hub.last_report >= REPORT_S:
            hub.sync(); hub.report(); self.flush_counts()

    def stop(self) -> None:
        hub = self.hub
        if hub.data is not None:
            hub.write_pending(); self.flush_counts(); hub.report()
            hub.finish(); hub.log("stopped")
        hub.close()


def make_link(a: argparse.Namespace) -> db.SerialLink | db.UdpLink:
    if a.udp:
        host, _, port = a.udp.rpartition(":")
        return db.UdpLink(host or "0.0.0.0", int(port))
    path = a.serial or os.environ.get("DIY_SERIAL")
    if not path:
        ports = db.find_serial_ports()
        if not ports:
            raise db.BoardLost("no USB serial port yet (/dev/ttyUSB*, /dev/ttyACM*): is the DevKit plugged in?")
        path = ports[0]
    return db.SerialLink(path, a.baud)


def run(hub: Hub, rec: Recording, a: argparse.Namespace, stopping: threading.Event) -> int:
    beat = [time.time()]

    def watchdog() -> None:  # last resort if the main loop stops turning (no known case)
        while True:
            time.sleep(5)
            if time.time() - beat[0] > 60:
                try:
                    if hub.data is not None:
                        hub.emergency_save()
                    hub.log("main loop stuck for 60 s; saved, exiting so record_night.sh starts a fresh one")
                finally:
                    os._exit(3)
    threading.Thread(target=watchdog, daemon=True).start()
    link = reader = None; tries = 0; next_try = 0.0; last_tick = 0.0
    while not stopping.is_set():
        now = time.time(); beat[0] = now
        if reader is None and now >= next_try:
            try:
                link = make_link(a); link.open(); reader = db.Reader(link)
                rec.on_open(link, tries); tries = 0
            except db.BoardLost as e:
                tries += 1; next_try = now + RETRY_S; rec.on_lost(e, tries)
            except RuntimeError as e:  # pyserial missing: a set-up error, not a drop
                hub.log(str(e)); rec.stop(); return 2
        if reader is not None:
            try:
                frames, lines = reader.poll()
            except db.BoardLost as e:
                link.close(); reader = None; tries = 1; next_try = now + RETRY_S; rec.on_lost(e, tries)
            else:
                rec.on_input(reader, frames, lines, time.time())
                if frames:
                    stopping.wait(BATCH_S)
        else:
            stopping.wait(0.05)
        if now - last_tick >= 1:
            rec.tick(now, stopping); last_tick = now
    if link is not None:
        link.close()
    rec.stop()
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default="_local/recordings-diy", help="kept apart from the BrainBit's _local/recordings")
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C (counts from the first frame)")
    ap.add_argument("--port", type=int, default=8765, help="live check page; 0 = off")
    ap.add_argument("--serial", help="USB serial port (default: DIY_SERIAL, else the only /dev/ttyUSB* or ttyACM*)")
    ap.add_argument("--baud", type=int, default=db.BAUD)
    ap.add_argument("--udp", help="[HOST:]PORT: the Wi-Fi route instead of serial (the firmware sends to port 9000)")
    ap.add_argument("--vref", type=float, default=db.DEFAULT_VREF, help="reference volts for counts -> volts (4.5 V "
                    "internal reference); must match the real board")
    ap.add_argument("--montage", help="JSON file or comma-separated names (default: scripts/montages/diy-breadboard-4.json)")
    a = ap.parse_args()
    if a.udp and a.serial:
        ap.error("--serial or --udp, not both")
    if a.udp and not a.udp.rpartition(":")[2].isdigit():
        ap.error("--udp takes [HOST:]PORT, e.g. 9000 or 0.0.0.0:9000")
    if not 0 < a.vref <= 5.25:
        ap.error("--vref must be above 0 and at most 5.25 V")
    if not (a.udp or a.serial or os.environ.get("DIY_SERIAL")) and len(db.find_serial_ports()) > 1:
        ap.error(f"several serial ports ({' '.join(db.find_serial_ports())}): pass --serial")
    try:
        montage = load_montage(a.montage)
    except (OSError, ValueError) as e:
        ap.error(f"--montage: {e}")
    hub = Hub(Path(a.out), names=montage.names, reports=False)
    hub.live.update(status="waiting for the board", battery="?", battery_note="no battery reading from this board")
    rec = Recording(hub, montage, a.vref, a.port, a.seconds)
    stopping = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    if a.port:
        hub.serve(a.port)  # up at once and all night: the pages say "waiting" / "reconnecting" by themselves
    rec.note(f"DIY board recorder; files in {a.out}; montage {montage.label}")
    raise SystemExit(run(hub, rec, a, stopping))


if __name__ == "__main__":
    main()
