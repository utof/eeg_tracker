#!/usr/bin/env python3
"""How did a night recorded by the phone app go? A plain verdict on the recorder and the top 3 things to fix.

usage: phone_night_check.py [NIGHT] [--data DIR] [--source auto|phone|laptop] [--compare LAPTOP_NIGHT] [--no-signal]

NIGHT is the evening date (YYYY-MM-DD), as scripts/night_files.py groups recordings: a night started on the evening
of 2026-11-19 is night 2026-11-19. Without NIGHT: the newest night the phone recorded (else the newest night).

DIR (default: `_local/` of this checkout) holds `recordings/` with the raw files (`<stamp>.f32 .idx .log`,
docs/data-format.md) and the phone's sleep reports in `phone/nights/` (where scripts/import_phone.py puts an export);
the phone's `eeg-export` folder itself, or a bare recordings folder, works too. Phone and laptop recordings may share
the folder: each recording is told apart by its log (the phone writes `phone battery` lines, the laptop "Ctrl+C to
stop"), and a night is made of one source's recordings only. `--source laptop` checks a laptop night the same way.

For that night it reads every gap in the data (from the `.idx` arrival times) with the log's reason for it, the
packet counter in the `.f32` (lost samples per hour), the sample rate, drops and reconnect tries, restarts of the app
by Android, when the phone was off Wi-Fi (Share on Wi-Fi cannot reach the laptop then), the phone and headband
batteries, contact, the phone's sleep report with its dream sleep check (analysis/rem_check.py, the words the phone
shows) and, when numpy is there (as under `uv run --project analysis`), flat, railed and 50 Hz hum per channel; for a
report from before the check, the eye movements are then measured from the recordings here. `--compare` puts a
laptop night's numbers next to it. Standard library only, apart from that optional numpy part. It only reads files.

A recording may hold any number of channels: what each `.f32` holds (channels, rate, what its counter counts) comes
from its `<stamp>.header.json` (scripts/recording.py), for files from before the header from the `.log`'s format line
(the DIY board's), else it is the BrainBit's O1 O2 T3 T4 at 250 Hz. The signal table has one column per channel of
the night's first recording; recordings of the same night that hold other channels are counted and named.

The thresholds of the verdict are planning values (DECISIONS row 320), not measured limits.
"""
from __future__ import annotations

import argparse, bisect, lzma, re, statistics, struct, sys, zlib
from array import array
from dataclasses import dataclass, field
from datetime import datetime
from operator import sub
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import night_files as nf  # noqa: E402  (standard library only)
import packed  # noqa: E402  (a recording packed after a day, <stamp>.f32.xz, reads as the plain one)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "analysis"))
import rem_check as rc  # noqa: E402  (the dream sleep check; standard library only but its detector)
import recording  # noqa: E402  (what a .f32 holds: its header; standard library only)
import battery  # noqa: E402  the headband gauge's stuck values and the charge by wear time (one rule)

FS = 250  # the BrainBit's rate; a run's own is Run.fs
REC = 20  # one `<I4f` record in a BrainBit .f32; a run's own record size is Run.rec
IDX = struct.Struct("<dQ")
CHUNK = 65536  # records read at a time
MIN_GAP_S = 0.5  # as scripts/to_bdf.py: more than this between batches is a gap
LIST_GAP_S = 30  # gaps listed one by one
SHOW_GAPS = 12
SHORT_DROP_S = 5  # a break inside one file shorter than this is a hiccup, not a drop
WRAP, MAX_JUMP = 2048, 1024  # the packet counter rules of app/lib/recorder/packets.dart
CHANNELS = ("O1", "O2", "T3", "T4")  # the BrainBit's; a run's own are Run.names
ROOT = Path(__file__).resolve().parent.parent

# The verdict (planning values, DECISIONS row 320)
MIN_NIGHT_H = 2.0  # under this much signal a night is too short to judge
BAD_COVER = 0.80  # under this share of the span recorded: not trustworthy
GAPS_MISSING_MIN = 10  # more missing than this, or a gap longer than the next line: usable, with gaps
GAPS_LONGEST_S = 300
RATE_TOL = 0.01  # samples per second within 1 % of 250
LOST_BAD, LOST_SOME = 0.01, 0.001  # share of samples lost to counter jumps
LATE_S = 10  # data held back longer than this (nothing lost) is worth fixing
TAIL_S = 30 * 60  # this long without data before Stop, with the app trying, is a gap worth fixing
SLOW_BACK_S = 60
# Signal and contact: the project's own rules
FLAT_UV, RAIL_UV = 1.4, 390_000.0  # analysis/eeg_detectors.py: raw range in a second under 1.4 uV = flat
HUM_SOME, HUM_HIGH = 20, 200  # scripts/live_page.html: power at 49-51 Hz against 30-45 Hz
GOOD_OHMS, FAIR_OHMS = 1e6, 2.5e6  # app/lib/recorder/contact.dart (row 51, planning values)
BAD_SHARE = 0.10  # a channel flat or railed this share of the night is worth fixing
WIFI_OFF_S = 120  # Wi-Fi off this long while sharing is worth fixing (a planning value)
# The phone's own cost (DECISIONS 767): the first hour after unplugging (the gauge holds 100 % with a flat charge
# counter) and the hours the screen was on are left out; a log without screen lines (before 2026-11-20) counts an
# hour drawing this much as the screen on (a lit screen alone is about 200 mA at minimum brightness: planning value)
UNPLUG_SKIP_S = 3600
FULL_PHONE_PCT = 99  # a night that starts unplugged at this level was just unplugged
SCREEN_MA = 200.0
PHONE_GAP_S = 600  # phone battery readings further apart than this are not joined into a stretch
LOW_BAND_PCT = 20  # the headband's charge (by wear time) under this: charge it before the next night
PHONE_COST_RULE = (f"phone-cost-v1: no first {UNPLUG_SKIP_S // 60} min after unplugging, no screen-on hours "
                   f"(without screen lines: {SCREEN_MA:g} mA or more)")

# ---- the log --------------------------------------------------------------------------------------------------------
# Every line the recorders write. P = the phone app (app/lib/recorder/night_recorder.dart, battery.dart,
# packets.dart), O = our own connection's notes (app/lib/headband/own/, scripts/record_ble.py), L = the laptop
# (scripts/record_night.py, recorder_hub.py). A line that matches no rule is counted and shown, so a new kind of
# line is noticed.
_COUNTS = (r"(?P<n>\d+) samples, missing (?P<missing>\d+) in (?P<gaps>\d+) gaps, repeated (?P<rep>\d+), "
           r"longest gap (?P<longest>\d+) samples")
RULES = [(k, re.compile(p)) for k, p in [
    ("connected", r"connected (?P<name>.+?) (?P<addr>\S+) serial (?P<serial>.*?) battery (?P<bat>\S+)%"
                  r"(?: signal (?P<signal>.+))?"),  # P L O
    ("phone_settings", r"phone android (?P<rest>.*)"),  # P
    ("phone_battery", r"phone battery (?P<pct>\S+)% charge (?P<uah>\S+) uAh current (?P<ua>\S+) uA "
                      r"(?P<plug>unplugged|plugged \S+) temp (?P<temp>\S+) C"),  # P
    ("battery_summary", r"phone battery summary: (?P<text>.*)"),  # P
    ("contact", r"contact ohms (?P<ohms>.*)"),  # P L O
    ("contact_none", r"contact check: no resistance data(?: arrived)?|contact re-check: no resistance data arrived"),
    ("contact_failed", r"contact check failed: (?P<err>.*)"),  # P L
    ("contact_recheck", r"contact re-check asked(?P<rest>.*)"),  # L
    ("live_page", r"live check page on port \d+"),  # L
    ("info", r"(?:sdk library|features|commands|parameters)(?: unavailable:)? .*"),  # L
    ("rec_started", r"recording started, \d+(?:\.\d+)? Hz(?P<laptop>, Ctrl\+C to stop)?"),  # P L
    ("samples", r"samples (?P<n>\d+) \(\+(?P<got>-?\d+)\)(?: battery (?P<bat>\S+)%)?"),  # P L
    ("stall", r"no data, state (?P<state>\S+); (?:restarting stream \(try \d+\)|reconnecting)"),  # P L
    ("stream_restarted", r"stream restarted(?:, battery \S+%)?"),  # P L
    ("stream_restart_failed", r"stream restart failed: .*"),  # P L
    ("still_no_data", r"still no data; (?P<what>reconnecting|exiting so record_night\.sh starts a fresh recorder)"),
    ("mending", r"no data; the headband is mending the link itself \(check \d+\)"),  # P with our own connection
    ("out_of_range", r"headband out of range; (?:saving|leaving it without SDK calls)"),  # P
    ("laptop_drop", r"headband (?P<state>\S+); saving and exiting so record_night\.sh starts a fresh recorder"),  # L
    ("packets_end", r"end of night, packets: " + _COUNTS),  # P: Stop was pressed
    ("packets", r"packets: " + _COUNTS),  # P
    ("total", r"total samples (?P<n>\d+), (?P<min>[\d.]+) min"),  # P L
    ("drop", r"drop \((?P<why>[^)]*)\); last data (?P<last>.+); reconnecting"),  # P
    ("stopped", r"stopped, battery (?P<bat>\S+)%"),  # P L
    ("stop_failed", r"stop failed: .*"),  # P L
    # P. From the reconnect ladder on (DECISIONS 940) a try that is not an ordinary one names its road after the
    # way: `(direct to AA:.., safety try)`, `(scan, opened app)`
    ("try", r"reconnect try (?P<n>\d+) \((?P<how>direct to [^),]*|scan)(?:, (?P<road>[^)]*))?\): "
            r"(?P<result>connected after|not found after|failed after|no answer for) (?P<s>[\d.]+) s(?P<rest>.*)"),
    # P: the connection in use cannot reach the night's headband directly (the switch moved from our own connection
    # to the SDK during the night, DECISIONS 398): the same try scans at once; its own "reconnect try" line follows
    ("try_rescan", r"reconnect try (?P<n>\d+) \((?P<how>direct to [^),]*)(?:, (?P<road>[^)]*))?\): (?P<why>.*); "
                   r"scanning instead"),
    # P. The ladder adds how long the headband was away and which road brought it back
    ("reconnected", r"reconnected \((?P<how>direct|scan|waiting connect), try (?P<n>\d+)\) after a drop "
                    r"\((?P<why>[^)]*)\); previous run (?P<prev>[^,;]+), last data (?P<last>[^,;]+)"
                    r"(?:, (?P<ago>[\d.]+) s ago)?(?:; (?:waited (?P<waited>[^;]+); )?back by: (?P<by>.+))?"),
    # P: the reconnect ladder's stage C (app/lib/headband/reconnect_ladder.dart): the waiting connect and its fallback
    ("ladder", r"headband away .*: the 60 s tries stop; .*|the waiting connect failed \(.*\); .*|"
               r"the waiting connect could not be opened \(.*\)|"
               r"the headband showed up on the waiting connect \(step \d+\)"),
    ("reconnected_same", r"reconnected after (?P<s>[\d.]+) s away \((?:try (?P<n>\d+)|as the signal was stopped)\), "
                         r"battery (?P<bat>\S+)%; same files"),  # O
    # O: the link came back without a drop this object saw (it closed while no signal ran, e.g. the contact check)
    ("reconnected_same", r"reconnected \((?:try (?P<n>\d+)|as the signal was stopped)\) after the link closed while "
                         r"the signal was off, battery (?P<bat>\S+)%; same files"),  # O
    ("reconnected_old", r"reconnected(?:, battery (?P<bat>\S+)%)?"),  # L (before 2026-11-18)
    ("reconnect_failed_old", r"reconnect failed: .*"),  # L
    ("lost_own", r"headband lost: (?P<err>.*?); (?:trying again in (?P<pause>[\d.]+) s \(try (?P<n>\d+)\)|"
                 r"still away after (?P<away>\d+) s, handing over to the app's reconnect)"),  # O phone
    # O phone: lost while the run's signal was being stopped (Stop, or the recorder ending the run): no drop of its own
    ("lost_own_stopped", r"headband lost: (?P<err>.*?); no further tries: the signal was stopped"),
    ("lost_ble", r"headband lost or not found: (?P<err>.*); trying again in (?P<pause>[\d.]+) s \(try (?P<n>\d+)\)"),
    ("own_counter", r"lost (?P<n>\d+) samples in (?P<gaps>\d+) gaps \(packet counter jumps\)"),  # O
    ("own_stall", r"no signal for (?P<s>\d+) s: sending the start command again"),  # O
    ("own_failed", r"(?:own connection|driver) stopped unexpectedly: .*"),  # O
    ("own_info", r"driver own Bluetooth LE .*|layout .*|mode .* \(command \d+\)|status .*|"
                 r"own Bluetooth driver; headband address .*|(?:no known address: )?scanning up to .*|"
                 r"the link carries .*|\S+ callback failed: .*|signal\+resistance \(command 5\) gave no signal .*|"
                 r"link timing: interval [\d.]+ ms, latency \d+, timeout [\d.]+ s"),
    ("service_restart", r"service restarted by Android after the app process ended"),  # P
    ("prev_exit", r"previous process ended: (?P<when>\S+) (?P<reason>\S+) status (?P<status>-?\d+) "
                  r"importance (?P<imp>-?\d+)(?: \((?P<desc>.*)\))?"),  # P (Android's ApplicationExitInfo)
    ("direct_off", r"the previous process ended during a direct connection; scans only for the rest of the night"),
    ("stuck", r"(?P<closing>closing: )?SDK call \"(?P<what>[^\"]*)\" stuck for (?P<s>\d+) s(?P<rest>.*)"),  # P
    ("laptop_stuck", r"main loop stuck(?: in an SDK call)? for (?P<s>\d+) s; saved, exiting so record_night\.sh "
                     r"starts a fresh one"),  # L
    ("answered_out", r".+ \S+ answered but reports out of range; left alone"),  # P
    ("start_failed", r"start failed \(\d+/\d+\): .*"),  # P L
    ("no_start", r"the signal would not start; reconnecting"),  # P
    ("error", r"unexpected error: .*"),  # P
    # P: an IO or store error ends one run, never the night (DECISIONS 390): storage full, a broken night store
    ("error", r"the run ended on an unexpected error: .*; the night goes on|could not save the newest data: .*|"
              r"could not save the night state: .*; the recording goes on"),
    # P: the phone's Wi-Fi on every change and every 30 minutes (app/lib/recorder/wifi_watch.dart, DECISIONS 611): on
    # it or not, link speed, signal and band, which network the default route uses, the screen, Doze ("idle") and the
    # app's Wi-Fi lock. The network's name is never written.
    ("wifi", r"wifi (?P<state>connected|not connected|off)(?:, (?P<mbps>\d+) Mbps)?(?:, (?P<dbm>-?\d+) dBm)?"
             r"(?:, (?P<ghz>[\d.]+) GHz)?; default route (?P<route>[^;]+); screen (?P<screen>on|off|\?); "
             r"idle (?P<idle>yes|no|\?); lock (?P<lock>held|not held)"),
    ("wifi_unreadable", r"wifi unreadable: (?P<err>.*)"),  # P
    # P: a headband-lost notice was shown (lost, back, battery nearly empty, a try by hand; DECISIONS 857, 943)
    ("notice", r"notice: (?P<text>.*)"),
    # P: the night's live helpers and their markers (the drift-off detector and hands-free, rows 182 and 247; the
    # smart alarm, 230-236; the lucid cues, 300-309; their one sleep model, 330) and Share on Wi-Fi (220-229). Their
    # problems (a helper stopped, or could not start or ring) are listed under "helpers"; the rest is information.
    ("helper", r"(?P<text>(?:drift-off(?: detector)?|hands-free(?: on)?|smart alarm(?: and lucid cues)?|"
               r"lucid cues?|live sleep model|sharing on Wi-Fi)[ :,;(].*|lights off)"),
]]
HELPER_PROBLEM = re.compile(r"\bstopped(?: by an error)?: |could not")
PHONE_ONLY = {"phone_settings", "phone_battery", "battery_summary", "try", "reconnected", "ladder", "notice", "service_restart",
              "prev_exit", "direct_off", "drop", "packets", "packets_end", "stuck", "out_of_range", "answered_out",
              "no_start", "error", "mending", "try_rescan", "lost_own_stopped", "wifi", "wifi_unreadable"}
LAPTOP_ONLY = {"live_page", "info", "laptop_drop", "laptop_stuck", "contact_recheck", "reconnected_old",
               "reconnect_failed_old", "lost_ble"}
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?) (.*)$")
MAC = re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")


@dataclass
class Event:
    t: float
    kind: str
    g: dict
    stem: str


def parse_line(msg: str) -> tuple[str, dict] | None:
    for kind, rx in RULES:
        m = rx.fullmatch(msg)
        if m:
            return kind, {k: v for k, v in m.groupdict().items() if v is not None}
    return None


def parse_log(text: str, stem: str) -> tuple[list[Event], list[str]]:
    events, unknown = [], []
    for line in text.splitlines():
        if not line.strip():
            continue
        m = STAMP.match(line)
        hit = parse_line(m.group(2)) if m else None
        if not m or hit is None:
            unknown.append(line)
            continue
        try:
            t = datetime.fromisoformat(m.group(1)).timestamp()
        except ValueError:
            unknown.append(line)
            continue
        events.append(Event(t, hit[0], hit[1], stem))
    return events, unknown


def scrub(line: str) -> str:
    """A log line as it may be shown: no Bluetooth address, no serial number."""
    return re.sub(r"serial \S+", "serial <serial>", MAC.sub("<address>", line))


# ---- one recorder run: <stamp>.f32 + .idx + .log ---------------------------------------------------------------------
@dataclass
class Run:
    stem: str
    folder: Path
    start: float
    samples: int
    events: list[Event]
    unknown: list[str]
    source: str = "unknown"
    _idx: tuple[array, array] | None = None
    rec: int = REC  # bytes of one record (the run's header)
    fs: float = FS  # samples a second
    names: tuple[str, ...] = CHANNELS  # the channels in record order
    counter: str = recording.PACKET_NUMBER  # what the record's uint32 counts

    @property
    def path(self) -> Path:
        """The .f32 by its plain name, also when it is packed (packed.open_raw opens either)."""
        return self.folder / f"{self.stem}.f32"

    def has(self, *kinds: str) -> bool:
        return any(e.kind in kinds for e in self.events)

    @property
    def closed(self) -> bool:
        """The run wrote its closing lines (a run whose process died mid-way did not)."""
        return self.has("total", "stuck", "laptop_stuck")

    def idx(self) -> tuple[array, array]:
        """Arrival times and first-sample indices of the batches, for rows that point inside the .f32."""
        if self._idx is None:
            times, firsts = array("d"), array("Q")
            try:
                raw = (self.folder / f"{self.stem}.idx").read_bytes()
            except OSError:
                raw = b""
            last = -1
            for t, i in IDX.iter_unpack(raw[: len(raw) // IDX.size * IDX.size]):
                if last < i < self.samples:  # an index row can outlive a crash that lost its samples
                    times.append(t)
                    firsts.append(i)
                    last = i
            self._idx = (times, firsts)
        return self._idx


def source_of(events: list[Event]) -> str:
    for e in events:
        if e.kind in PHONE_ONLY or (e.kind == "rec_started" and "laptop" not in e.g):
            return "phone"
        if e.kind in LAPTOP_ONLY or (e.kind == "rec_started" and "laptop" in e.g):
            return "laptop"
        if e.kind == "connected" and e.g.get("signal", "").startswith("unknown"):
            return "phone"
    return "unknown"


def load_runs(folder: Path) -> list[Run]:
    stems = {p.stem for p in packed.raw_files(folder)} | {p.stem for p in folder.glob("*.log")}
    runs = []
    for stem in stems:
        start = nf.stamp_time(Path(stem))
        if start is None:
            continue
        try:
            text = (folder / f"{stem}.log").read_text(errors="replace")
        except OSError:
            text = ""
        head = recording.read(folder / f"{stem}.f32")  # a damaged header: an error naming it (main says it)
        if not head.is_sleep:
            continue  # a work session's raw EEG is no run of a night (DECISIONS 683)
        try:
            samples = packed.size(folder / f"{stem}.f32") // head.record_bytes
        except OSError:
            samples = 0
        events, unknown = parse_log(text, stem)
        runs.append(Run(stem, folder, start, samples, events, unknown, source_of(events), rec=head.record_bytes,
                        fs=float(head.sample_rate), names=head.names, counter=head.counter))
    runs.sort(key=lambda r: (r.start, r.stem))
    known = [r for r in runs if r.source != "unknown"]
    for r in runs:  # an empty or unreadable log: the source of the nearest run in time
        if r.source == "unknown" and known:
            r.source = min(known, key=lambda k: abs(k.start - r.start)).source
    return runs


# ---- nights ----------------------------------------------------------------------------------------------------------
def nights_of(runs: list[Run], recs: dict[str, nf.Rec], source: str) -> list[nf.Night]:
    return nf.nights([recs[r.stem] for r in runs if r.source == source and r.stem in recs])


def night_runs(runs: list[Run], nights: list[nf.Night], night: nf.Night, source: str) -> list[Run]:
    """The night's recordings and, from the same source, the runs without samples in its time (their logs hold
    reconnect tries and failed starts)."""
    names = {r.path.name for r in night.recs}
    later = [n.start for n in nights if n.start > night.start]
    limit = min(later) if later else night.end + nf.CHAIN_GAP_S
    return [r for r in runs if r.source == source and (
        r.path.name in names or (r.samples == 0 and night.start - 60 <= r.start < limit))]


def pick(runs: list[Run], recs: dict[str, nf.Rec], name: str | None, source: str) -> tuple[str, nf.Night, list[Run]]:
    order = ("phone", "laptop") if source == "auto" else (source,)
    for src in order:
        ns = nights_of(runs, recs, src)
        hits = [n for n in ns if n.name == name] if name else ns[-1:]
        if hits:
            return src, hits[0], night_runs(runs, ns, hits[0], src)
    have = [f"{n.name} ({src}, {len(n.recs)} recordings)" for src in ("phone", "laptop")
            for n in nights_of(runs, recs, src)]
    what = f"night {name}" if name else "night"
    raise LookupError(f"no {what} from the {' or '.join(order)} here; nights: {', '.join(have) or 'none'}")


# ---- the timeline: stretches of unbroken data and the breaks between them --------------------------------------------
@dataclass
class Stretch:
    t0: float  # first sample (arrival of its batch minus the batch's length)
    t1: float  # arrival of the last batch
    run: Run
    i0: int
    i1: int
    ta: float = 0.0  # arrival and first index of the first and the last batch, for the sample rate
    ia: int = 0
    tb: float = 0.0
    ib: int = 0


def stretches(run: Run) -> list[Stretch]:
    if run.samples == 0:
        return []
    times, firsts = run.idx()
    if not times:
        return [Stretch(run.start, run.start + run.samples / run.fs, run, 0, run.samples)]
    out: list[Stretch] = []
    n = len(times)
    s = 0
    t0_s = times[0] - ((firsts[1] if n > 1 else run.samples) - firsts[0]) / run.fs
    for k in range(1, n):
        end = firsts[k + 1] if k + 1 < n else run.samples
        t0 = times[k] - (end - firsts[k]) / run.fs
        if t0 - times[k - 1] > MIN_GAP_S:
            out.append(Stretch(t0_s, times[k - 1], run, firsts[s], firsts[k], times[s], firsts[s], times[k - 1],
                               firsts[k - 1]))
            s, t0_s = k, t0
    out.append(Stretch(t0_s, times[-1], run, firsts[s], run.samples, times[s], firsts[s], times[-1], firsts[-1]))
    if firsts[0] > 0:  # samples before the first index row join the first stretch
        out[0].t0 -= firsts[0] / run.fs
        out[0].i0 = 0
    return out


@dataclass
class Break:
    t0: float  # last data before
    t1: float  # first data after
    a: Run
    b: Run
    late: bool = False  # inside one file, the counter went on by one and the held-back data came in a burst
    paused: bool = False  # inside one file, the counter went on by one but no burst: the headband sent nothing
    cat: str = ""
    text: str = ""

    @property
    def inside(self) -> bool:
        return self.a is self.b

    @property
    def length(self) -> float:
        return self.t1 - self.t0


# ---- the packet counter ---------------------------------------------------------------------------------------------
def jump(prev: int, cur: int, counter: str = recording.PACKET_NUMBER) -> tuple[str, int]:
    """One step of the packet counter: ("ok" | "lost" | "repeat" | "restart", samples lost). The rules of
    app/lib/recorder/packets.dart, plus: a counter that falls back from beyond 2047 starts again (BrainBit's SDK
    sends the last batch of the previous connection first, then counts from 8), which loses nothing.
    Any other counter (the DIY board's sequence number) is a plain uint32: every step forward past 1 is that many
    frames missing, a step back is a restart."""
    if counter != recording.PACKET_NUMBER:
        step = (cur - prev) % 2**32
        return ("ok", 0) if step == 1 else ("repeat", 0) if step == 0 else ("lost", step - 1) if step < 2**31 else (
            "restart", 0)
    raw = cur - prev
    if raw == 1:
        return "ok", 0
    if 1 < raw <= MAX_JUMP:
        return "lost", raw - 1
    if raw <= 0 and prev < WRAP and cur < WRAP:
        step = raw % WRAP
        if step == 1:
            return "ok", 0
        if 1 < step <= MAX_JUMP:
            return "lost", step - 1
    return ("repeat", 0) if raw == 0 else ("restart", 0)


@dataclass
class Packets:
    lost: int = 0
    jumps: int = 0
    longest: int = 0
    repeats: int = 0
    restarts: int = 0
    per_hour: dict = field(default_factory=dict)  # local hour start (unix) -> samples lost


def _packs(b: bytes, rec: int = REC) -> array:
    """The counters of whole records of `rec` bytes (the first uint32 of each)."""
    a = array("I")
    a.frombytes(b)
    if sys.byteorder == "big":
        a.byteswap()
    return a[0::rec // 4]


_unpacked: dict[str, bytes] = {}


def unpacked(run: Run) -> bytes | None:
    """A packed run's samples, unpacked once (a packed file cannot jump to a record without unpacking up to it); None
    for a plain one."""
    d = packed.on_disk(run.path)
    if d is None or not packed.is_packed(d):
        return None
    if str(d) not in _unpacked:
        _unpacked[str(d)] = packed.read_bytes(d)
    return _unpacked[str(d)]


def pack_at(run: Run, j: int) -> int | None:
    try:
        data = unpacked(run)
        if data is not None:
            b = data[j * run.rec:j * run.rec + 4]
        else:
            with open(run.path, "rb") as f:
                f.seek(j * run.rec)
                b = f.read(4)
    except (OSError, lzma.LZMAError, zlib.error, EOFError):
        return None
    return struct.unpack("<I", b)[0] if len(b) == 4 else None


def burst(run: Run, i0: int) -> bool:
    """True when the batches from sample i0 on brought over a second of samples within half a second: data that
    Android held back and then delivered at once (a stream that only paused brings 125 samples in that time)."""
    times, firsts = run.idx()
    k = bisect.bisect_left(firsts, i0)
    if k >= len(firsts) or firsts[k] != i0:
        return False
    z = bisect.bisect_right(times, times[k] + 0.5, lo=k)
    end = firsts[z] if z < len(firsts) else run.samples
    return end - i0 >= run.fs


def scan_packets(run: Run, cuts: set[int], out: Packets) -> None:
    """Counter jumps inside unbroken stretches. A jump at a break belongs to the gap, not to lost packets; a jump
    after the run's first batch is BrainBit's SDK sending the previous connection's last batch again before it
    counts from the start (seen in every laptop run of 2026-11-18), so it is a restart, not a loss."""
    times, firsts = run.idx()
    first_batch = firsts[1] if len(firsts) > 1 and firsts[0] == 0 else None
    prev, base = None, 0
    try:
        f = packed.open_raw(run.path)
    except OSError:
        return
    with f:
        while b := f.read(CHUNK * run.rec):
            packs = _packs(b[: len(b) // run.rec * run.rec], run.rec)
            if not packs:
                break
            seq = ([prev] if prev is not None else []) + packs.tolist()
            start = base - (1 if prev is not None else 0)  # index of seq[0]
            steps = list(map(sub, seq[1:], seq[:-1]))
            if steps.count(1) != len(steps):
                for k, d in enumerate(steps):
                    if d == 1:
                        continue
                    j = start + k + 1
                    if j in cuts:
                        continue
                    kind, n = ("restart", 0) if j == first_batch else jump(seq[k], seq[k + 1], run.counter)
                    if kind == "lost":
                        out.lost += n
                        out.jumps += 1
                        out.longest = max(out.longest, n)
                        t = times[max(0, bisect.bisect_right(firsts, j) - 1)] if times else run.start + j / run.fs
                        h = hour_of(t)
                        out.per_hour[h] = out.per_hour.get(h, 0) + n
                    elif kind == "repeat":
                        out.repeats += 1
                    elif kind == "restart":
                        out.restarts += 1
            prev = seq[-1]
            base += len(packs)


def hour_of(t: float) -> float:
    return datetime.fromtimestamp(t).replace(minute=0, second=0, microsecond=0).timestamp()


# ---- why a break happened --------------------------------------------------------------------------------------------
DROP_CATS = {"drop", "stuck", "android", "killed", "unknown"}
# lines the app adds to a closed run's log
NOTES = {"try", "try_rescan", "ladder", "notice", "answered_out", "packets_end", "battery_summary"}


def _tries(evs: list[Event]) -> str:
    tries = [e for e in evs if e.kind == "try"]
    if not tries:
        return ""
    direct = sum(e.g["how"] != "scan" for e in tries)
    return f"{len(tries)} {'try' if len(tries) == 1 else 'tries'} ({direct} direct, {len(tries) - direct} scan)"


def explain(br: Break, evs: list[Event], empty_runs: int) -> None:
    """Sets the break's category and its reason in plain words, from the log lines around it."""
    if br.late:
        br.cat, br.text = "late", "the data arrived late in a burst (nothing lost)"
        return
    kinds = {e.kind for e in evs}
    parts: list[str] = []
    cat = ""
    stuck = [e for e in evs if e.kind in ("stuck", "laptop_stuck") or (e.kind == "try" and
                                                                      e.g["result"] == "no answer for")]
    if stuck:
        cat = "stuck"
        what = next((e.g["what"] for e in stuck if "what" in e.g), "an SDK call")
        parts.append(f'Bluetooth stuck ("{what}" gave no answer)')
    drop = next((e for e in evs if e.kind == "drop"), None)
    if drop:
        cat = cat or "drop"
        parts.append(f"drop ({drop.g['why']})")
    elif "laptop_drop" in kinds or "out_of_range" in kinds:
        cat = cat or "drop"
        parts.append("drop (out of range)")
    elif "still_no_data" in kinds:
        cat = cat or "drop"
        parts.append("drop (no data)")
    elif kinds & {"lost_own", "lost_ble"}:
        cat = cat or "drop"
        parts.append("headband lost")
    elif kinds & {"stall", "own_stall"}:
        cat = cat or "drop"
        parts.append("stall (no data, stream restarted)")
    elif "mending" in kinds:
        cat = cat or "drop"
        parts.append("stall (no data; the headband mended the link itself)")
    if "service_restart" in kinds:
        exits = sorted({e.g["reason"] for e in evs if e.kind == "prev_exit"})
        why = f" (the process ended: {', '.join(exits)})" if exits else ""
        parts.append(("the app restarted itself" if stuck else "Android restarted the service") + why)
        cat = cat or "android"
    elif not br.inside and not br.a.closed and not stuck:
        cat = "killed"
        parts.append("the app ended without a word (killed?)" if br.a.source == "phone"
                     else "the recorder ended without its closing lines")
    if not cat and not br.inside:
        if br.a.has("packets_end") or (br.a.source == "laptop" and br.a.has("stopped")):
            cat = "by_hand"
            parts.append("stopped by hand, started again")
        elif any(e.kind == "contact_recheck" and "exiting" in e.g.get("rest", "") for e in evs):
            cat = "planned"
            parts.append("contact re-check (a planned restart)")
    if br.paused:
        parts.append("the packet numbers went on without a skip (the headband paused)")
    tries = _tries(evs)
    if tries:
        parts.append(tries)
    if empty_runs:
        parts.append(f"{empty_runs} {'start' if empty_runs == 1 else 'starts'} without data")
    back = next((e for e in evs if e.kind == "reconnected"), None)
    if back:
        road = back.g.get("by", "")
        ordinary = road in ("", "quick try", "minute try", back.g["how"])
        parts.append(f"back by {back.g['how']}, try {back.g['n']}" + ("" if ordinary else f" ({road})"))
    if not cat:
        cat = "unknown"
        parts.append("no log line explains it")
    br.cat, br.text = cat, "; ".join(parts)


# ---- the night's numbers ---------------------------------------------------------------------------------------------
def _num(s: str | None) -> float | None:
    try:
        return float(s) if s is not None else None
    except ValueError:
        return None


def _pct(s: str | None) -> int | None:
    return int(s) if s is not None and s.isdigit() else None


def parse_ohms(text: str) -> dict[str, float | None]:
    out: dict[str, float | None] = {}
    for part in text.split():
        k, _, v = part.partition("=")
        if k and v:  # any channel name: the recording's own
            out[k] = float("inf") if v == "inf" else _num(v)
    return out


def contact_word(v: float | None) -> str:
    if v is None or v != v or v < 0 or v == float("inf"):
        return "none"
    return "good" if v <= GOOD_OHMS else "fair" if v <= FAIR_OHMS else "poor"


def ohms_text(v: float | None) -> str:
    if v is None:
        return "no reading"
    if v == float("inf"):
        return "off (inf)"
    return f"{v / 1e3:.0f} kΩ" if v < 1e6 else f"{v / 1e6:.1f} MΩ"


def settings_of(rest: str) -> dict[str, str]:
    """`34, battery-opt exempt yes, background restricted no, ...` (the line after "phone android") as a dict."""
    parts = rest.split(", ")
    out = {"android": parts[0]}
    for p in parts[1:]:
        k, _, v = p.rpartition(" ")
        out[k or p] = v
    return out


def screen_spans(evs: list[Event]) -> list[tuple[float, float]] | None:
    """When the phone's screen was on, from its Wi-Fi lines (each says the screen's state at that moment): from a line
    saying on to the next line, or the last event; None when the log has no screen lines (an app from before
    2026-11-20)."""
    lines = [e for e in evs if e.kind == "wifi" and e.g.get("screen") in ("on", "off")]
    if not lines:
        return None
    end = max(e.t for e in evs)
    spans = []
    for a, b in zip(lines, lines[1:] + [None]):
        if a.g["screen"] == "on":
            spans.append((a.t, b.t if b is not None else end))
    return spans


def phone_cost(pts: list[tuple], screen: list[tuple[float, float]] | None) -> dict | None:
    """The phone's own cost over its steady hours (DECISIONS 767): `pts` (time, %, uAh, plugged, |current| uA) a minute
    apart. Left out: readings while plugged, the first hour after unplugging (the night's first reading counts as
    unplugging when it is unplugged at 99 % or more), and every clock hour with the screen on (by the Wi-Fi lines'
    screen state; without them, an hour drawing SCREEN_MA or more on average). None with no steady hour left."""
    unplugged_at: float | None = None
    keep: dict[float, list[tuple[float, float, float, float | None]]] = {}  # clock hour -> (s, mAh, %, mA)
    skipped_unplug = 0.0
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        if a[3] or b[3]:
            unplugged_at = None
            continue
        if i == 0 and a[1] is not None and a[1] >= FULL_PHONE_PCT:
            unplugged_at = a[0]
        if unplugged_at is None and i > 0 and pts[i - 1][3]:
            unplugged_at = a[0]
        dt = b[0] - a[0]
        if dt <= 0 or dt > PHONE_GAP_S or a[2] is None or b[2] is None:
            continue
        if unplugged_at is not None and a[0] < unplugged_at + UNPLUG_SKIP_S:
            skipped_unplug += dt
            continue
        ma = (a[4] + b[4]) / 2000 if a[4] is not None and b[4] is not None else None
        pct = (a[1] - b[1]) if a[1] is not None and b[1] is not None else 0.0
        keep.setdefault(hour_of(a[0]), []).append((dt, (a[2] - b[2]) / 1000, pct, ma))
    hours_on = set()
    for h, parts in keep.items():
        if screen is not None:
            if any(x < h + 3600 and y > h for x, y in screen):
                hours_on.add(h)
        elif _mean_ma(parts) is not None and _mean_ma(parts) >= SCREEN_MA:
            hours_on.add(h)
    steady = [p for h, parts in keep.items() if h not in hours_on for p in parts]
    secs = sum(p[0] for p in steady)
    if secs < 20 * 60:
        return None
    return dict(mah_per_hour=sum(p[1] for p in steady) / secs * 3600, per_hour=sum(p[2] for p in steady) / secs * 3600,
                ma=_mean_ma(steady), hours=secs / 3600, unplug_skipped_h=skipped_unplug / 3600,
                screen_hours=len(hours_on), screen="logged" if screen is not None else "guessed from the current")


def _mean_ma(parts: list[tuple[float, float, float, float | None]]) -> float | None:
    """The time-weighted mean current (mA) of the stretches that have one."""
    known = [(dt, ma) for dt, _, _, ma in parts if ma is not None]
    secs = sum(dt for dt, _ in known)
    return sum(dt * ma for dt, ma in known) / secs if secs else None


def band_numbers(evs: list[Event]) -> dict | None:
    """The headband's gauge by battery.py's one rule (DECISIONS 766): its readings, the stuck values left out, the
    first and last believable ones, and the charge at the last reading by wear time (an estimate)."""
    band = sorted((e.t, v) for e in evs if e.kind in ("connected", "samples", "stopped")
                  and (v := _pct(e.g.get("bat"))) is not None)
    if not band:
        return None
    stuck = battery.stuck_values(band)
    good = [(t, v) for t, v in band if v not in stuck]
    b: dict = dict(readings=len(band), stuck=len(band) - len(good), stuck_at=sorted({v for _, v in band if v in stuck}),
                   first=None, last=None, first_t=None, last_t=None, low=None, per_hour=None, charged=False,
                   estimate=battery.wear_estimate(band, band[-1][0]))
    if good:
        hours = (good[-1][0] - good[0][0]) / 3600
        charged = any(v > u + 3 for (_, u), (_, v) in zip(good, good[1:]))  # a rise: charged in between
        b.update(first=good[0][1], last=good[-1][1], first_t=good[0][0], last_t=good[-1][0],
                 low=min(v for _, v in good), charged=charged,
                 per_hour=(good[0][1] - good[-1][1]) / hours if hours * 60 >= 20 and not charged else None)
    return b


def battery_numbers(evs: list[Event]) -> dict:
    phone = [e for e in evs if e.kind == "phone_battery"]
    out: dict = {"phone": None, "band": band_numbers(evs), "summary": None}
    pts = [(e.t, _pct(e.g["pct"]), _num(e.g["uah"]), e.g["plug"] != "unplugged", _num(e.g["temp"]),
            abs(v) if (v := _num(e.g["ua"])) is not None else None) for e in phone]
    with_pct = [p for p in pts if p[1] is not None]
    if with_pct:
        a, z = with_pct[0], with_pct[-1]
        hours = (z[0] - a[0]) / 3600
        charge = [p for p in pts if p[2] is not None]
        mah = (charge[0][2] - charge[-1][2]) / 1000 if len(charge) > 1 else None
        temps = [p[4] for p in pts if p[4] is not None]
        out["phone"] = dict(first=a[1], last=z[1], hours=hours, readings=len(pts),
                            per_hour=(a[1] - z[1]) / hours if hours * 60 >= 20 else None,
                            mah_per_hour=mah / hours if mah is not None and hours * 60 >= 20 else None,
                            plugged=any(p[3] for p in pts),
                            temp=(min(temps), max(temps)) if temps else None,
                            steady=phone_cost([(p[0], p[1], p[2], p[3], p[5]) for p in pts], screen_spans(evs)))
    summ = [e for e in evs if e.kind == "battery_summary"]
    if summ:
        out["summary"] = summ[-1].g["text"]
    return out


def contact_numbers(evs: list[Event], runs: list[Run]) -> dict:
    """The start = the reading of the first run that recorded 10+ minutes (the laptop measures at every fresh
    recorder, also during tests with the headband off), else the first reading; later = the ones after it."""
    readings = [(e.t, parse_ohms(e.g["ohms"]), e.stem) for e in evs if e.kind == "contact"]
    failed = [e for e in evs if e.kind in ("contact_failed", "contact_none")]
    long = {r.stem for r in runs if r.samples >= 10 * 60 * r.fs}
    k = next((i for i, x in enumerate(readings) if x[2] in long), 0)
    return dict(start=readings[k][:2] if readings else None, later=[x[:2] for x in readings[k + 1:]],
                failed=len(failed))


WIFI_WORD = {"not connected": "not connected", "off": "switched off"}


def wifi_numbers(evs: list[Event]) -> dict | None:
    """The phone's Wi-Fi through the night, from its Wi-Fi lines: each stretch off it (from the first line that says so
    to the next that says connected; None when still off at the last line) with what the first line said, the
    signal, and whether sharing was on. None for a night of an app without these lines."""
    lines = [e for e in evs if e.kind == "wifi"]
    if not lines:
        return None
    off: list[tuple[float, float | None, str]] = []
    went: tuple[float, str] | None = None
    for e in lines:
        if e.g["state"] == "connected":
            if went is not None:
                off.append((went[0], e.t, went[1]))
                went = None
        elif went is None:
            went = (e.t, f"{WIFI_WORD[e.g['state']]}, screen {e.g['screen']}, default route {e.g['route']}")
    if went is not None:
        off.append((went[0], None, went[1]))
    dbm = [int(e.g["dbm"]) for e in lines if "dbm" in e.g]
    return dict(lines=len(lines), off=off, dbm=(min(dbm), max(dbm)) if dbm else None,
                unreadable=sum(e.kind == "wifi_unreadable" for e in evs),
                shared=any(e.kind == "helper" and e.g["text"].startswith("sharing on Wi-Fi on") for e in evs))


def find_report(report_dirs: list[Path], name: str, source: str) -> tuple[Path, dict] | None:
    for d in report_dirs:
        p = d / f"{name}.report.json"
        r = nf.read_json(p)
        if r is not None and (r.get("source") == "phone") == (source == "phone"):
            return p, r
    return None


def report_numbers(found: tuple[Path, dict] | None, runs: list[Run]) -> dict | None:
    if found is None:
        return None
    path, r = found
    total = r.get("total") if isinstance(r.get("total"), dict) else {}
    extras = r.get("extras") if isinstance(r.get("extras"), dict) else None
    night = extras.get("night") if extras and isinstance(extras.get("night"), dict) else None
    inputs = {i.get("file") for i in r.get("inputs") or [] if isinstance(i, dict)}
    files = {x.path.name for x in runs if x.samples > 0}
    return dict(file=path.name, scored=bool(r.get("scored")), scoring_s=_num(str(r.get("scoring_s"))),
                asleep_min=total.get("asleep_min"), periods=total.get("periods"),
                recorded_min=total.get("recorded_min"), missing_min=total.get("missing_min"),
                quality=night, covers=len(files & inputs), of=len(files), phone=r.get("source") == "phone",
                rem=rc.check_of_report(r), rem_eye_here=False, raw=r)


def measure_eye(rep: dict, runs: list[Run]) -> tuple[dict | None, str | None]:
    """For a report from before the dream sleep check: its check with the eye movements measured here from the
    night's recordings (the files the report lists, joined as the phone joins them); (None, why) when that cannot be
    done (no numpy, another start, no eye pair)."""
    try:
        import to_bdf  # noqa: PLC0415  (numpy, pyedflib)
        import night_extras as nx  # noqa: PLC0415
    except ImportError as e:
        return None, f"eye movements not measured here ({e.name} not found: run under `uv run --project analysis`)"
    done = {i.get("file") for i in rep.get("inputs") or [] if isinstance(i, dict)}
    paths = [x.path for x in runs if x.path.name in done and x.samples > 0]
    if not paths:
        return None, "eye movements not measured here: the report's recordings are not in this folder"
    head = to_bdf.night_header(paths)
    pair = rc.eye_pair(head)
    if pair is None:
        eye = rc.eye_not(rc.NO_PAIR)
    else:
        start, uv, notes = to_bdf.join(paths)
        if start.isoformat() != datetime.fromisoformat(rep["data_start"]).replace(tzinfo=None).isoformat():
            return None, f"eye movements not measured here: the recordings start at {start:%H:%M:%S}, the report at " \
                         f"{rep['data_start'][11:19]}"
        lim = nx.LIMIT_UV
        left, right = (uv[:, k].clip(-lim, lim) for k in (pair.left, pair.right))
        eye = rc.eye_measured(pair.label, rc.eye_epochs(left, right, nx.missing_mask(len(uv), notes),
                                                        int(round(head.sample_rate))))
    stages = rc.stages_of(rep.get("stages"))
    if stages is None:
        return None, "eye movements not measured here: the report has no stages"
    return rc.night_check(stages, rc.periods_of(rep), rc.decode_probs(rep.get("probs")), eye), None


def signal_numbers(runs: list[Run]) -> dict | None:
    """Flat and railed seconds and the 50 Hz hum per channel of the night's first recording; None without numpy.
    One minute at a time. Recordings that hold other channels (or another rate) are left out and named in `other`."""
    try:
        import numpy as np
    except ImportError:
        return None
    if not runs:
        return None
    names, fs = runs[0].names, int(round(runs[0].fs))
    n_ch = len(names)
    dt = np.dtype([("pack", "<u4"), ("v", "<f4", (n_ch,))])
    flat, railed = np.zeros(n_ch, int), np.zeros(n_ch, int)
    hums: list[list[float]] = [[] for _ in names]
    seconds = 0
    win = 4 * fs
    hann = np.hanning(win)
    freqs = np.fft.rfftfreq(win, 1 / fs)
    mains, ref = (freqs >= 49) & (freqs < 51), (freqs >= 30) & (freqs < 45)
    other: dict[str, int] = {}
    for run in runs:
        if run.names != names or int(round(run.fs)) != fs:
            what = " ".join(run.names) + ("" if int(round(run.fs)) == fs else f" at {run.fs:g} Hz")
            other[what] = other.get(what, 0) + 1
            continue
        if run.samples < fs:
            continue
        data = unpacked(run)
        mm = (np.frombuffer(data, dtype=dt, count=run.samples) if data is not None
              else np.memmap(run.path, dtype=dt, mode="r", shape=(run.samples,)))
        for a in range(0, run.samples - fs + 1, 60 * fs):
            v = np.asarray(mm["v"][a:a + 60 * fs], dtype=np.float64) * 1e6
            whole = len(v) // fs * fs
            s = v[:whole].reshape(-1, fs, n_ch)
            seconds += s.shape[0]
            flat += (np.ptp(s, axis=1) < FLAT_UV).sum(axis=0)
            railed += (np.abs(s).max(axis=1) >= RAIL_UV).sum(axis=0)
            if len(v) >= win:
                x = v[:win] - v[:win].mean(axis=0)
                p = np.abs(np.fft.rfft(x * hann[:, None], axis=0)) ** 2
                for c in range(n_ch):
                    den = p[ref, c].mean()
                    if den > 1e-12:
                        hums[c].append(float(p[mains, c].mean() / den))
        del mm
    if not seconds:
        return None
    return dict(seconds=seconds, flat=flat.tolist(), railed=railed.tolist(),
                hum=[statistics.median(h) if h else None for h in hums],
                hum_high=[sum(x > HUM_HIGH for x in h) / len(h) if h else None for h in hums],
                other=[f"{what} ({plural(k, 'recording')})" for what, k in other.items()])


def analyse(runs: list[Run], source: str, name: str, report_dirs: list[Path], signal: bool = True) -> dict:
    data_runs = [r for r in runs if r.samples > 0]
    st = sorted((s for r in data_runs for s in stretches(r)), key=lambda s: s.t0)
    evs = sorted((e for r in runs for e in r.events), key=lambda e: e.t)
    times = [e.t for e in evs]
    s: dict = dict(name=name, source=source, runs=len(runs), data_runs=len(data_runs), lines=sum(
        len(r.events) + len(r.unknown) for r in runs), unknown=[scrub(u) for r in runs for u in r.unknown])
    if not st:
        s.update(empty=True)
        return s
    # breaks
    breaks = []
    segs = [[st[0].ta, st[0].ia, st[0].tb, st[0].ib]]  # for the rate: stretches joined across held-back data
    for a, b in zip(st, st[1:]):
        br = Break(a.t1, b.t0, a.run, b.run)
        if br.inside:
            p0, p1 = pack_at(a.run, b.i0 - 1), pack_at(a.run, b.i0)
            if p0 is not None and p1 is not None and jump(p0, p1, a.run.counter) == ("ok", 0):
                br.late = burst(a.run, b.i0)
                br.paused = not br.late
        if br.late or (br.inside and br.length <= MIN_GAP_S):
            segs[-1][2:] = [b.tb, b.ib]
        else:
            segs.append([b.ta, b.ia, b.tb, b.ib])
        if br.length > MIN_GAP_S:
            lo, hi = bisect.bisect_left(times, br.t0 - 2), bisect.bisect_right(times, br.t1 + 5)
            empty = sum(1 for r in runs if r.samples == 0 and br.t0 - 2 <= r.start <= br.t1)
            explain(br, evs[lo:hi], empty)
            breaks.append(br)
    # packets
    pk = Packets()
    for r in data_runs:
        cuts = {x.i0 for x in st if x.run is r and x.i0 > 0}
        scan_packets(r, cuts, pk)
    # rate over unbroken data of a minute or more (data held back and then sent in a burst is unbroken)
    long = [(tb - ta, ib - ia) for ta, ia, tb, ib in segs if tb - ta >= 60 and ib > ia]
    rate = sum(n for _, n in long) / sum(t for t, _ in long) if long else None
    tens = [n / t for t, n in long if t >= 600]
    samples = sum(r.samples for r in data_runs)
    signal_s = sum(r.samples / r.fs for r in data_runs)
    span = st[-1].t1 - st[0].t0
    # signal minutes per clock hour
    per_hour: dict[float, float] = {}
    for x in st:
        t = x.t0
        while t < x.t1:
            h = hour_of(t)
            end = min(x.t1, h + 3600)
            per_hour[h] = per_hour.get(h, 0.0) + end - t
            t = end
    drops = [b for b in breaks if b.cat in DROP_CATS and (not b.inside or b.length >= SHORT_DROP_S)]
    hiccups = [b for b in breaks if b.cat in DROP_CATS and b.inside and b.length < SHORT_DROP_S]
    late = [b for b in breaks if b.cat == "late"]
    tries = [e for e in evs if e.kind == "try"]
    s.update(
        empty=False, start=st[0].t0, end=st[-1].t1, span_s=span, samples=samples, signal_s=signal_s,
        channels=data_runs[0].names, fs=data_runs[0].fs,  # of the night's first recording (the signal table's)
        missing_s=max(0.0, span - signal_s), breaks=breaks, drops=drops, hiccups=hiccups, late=late,
        per_hour={h: v / 60 for h, v in sorted(per_hour.items())}, packets=pk, rate=rate,
        rate_range=(min(tens), max(tens)) if tens else None, rate_s=sum(t for t, _ in long),
        tries=dict(direct=sum(e.g["how"] != "scan" for e in tries), scan=sum(e.g["how"] == "scan" for e in tries),
                   direct_ok=sum(e.g["how"] != "scan" and e.g["result"] == "connected after" for e in tries),
                   scan_ok=sum(e.g["how"] == "scan" and e.g["result"] == "connected after" for e in tries)),
        stuck=[e for e in evs if e.kind in ("stuck", "laptop_stuck")],
        restarts=[e for e in evs if e.kind == "service_restart"],
        exits=[e for e in evs if e.kind == "prev_exit"],
        direct_off=any(e.kind == "direct_off" for e in evs),
        helpers=[(e.t, scrub(e.g["text"])) for e in evs if e.kind == "helper" and HELPER_PROBLEM.search(e.g["text"])],
        killed=[r for r in runs if not r.closed and r.events and r is not runs[-1]],
        last_closed=runs[-1].closed,
        last_line=evs[-1].t if evs else st[-1].t1,
        stop=next((e.t for e in reversed(evs) if e.kind == "packets_end"), None),
        tail=_tail(st[-1], evs),
        laptop_stop=next((e.t for e in reversed(evs) if e.kind == "stopped"), None) if source == "laptop" else None,
        app_packets=next((e.g for e in reversed(evs) if e.kind in ("packets_end", "packets")), None),
        settings=next((settings_of(e.g["rest"]) for e in reversed(evs) if e.kind == "phone_settings"), None),
        battery=battery_numbers(evs), contact=contact_numbers(evs, runs), wifi=wifi_numbers(evs),
        rssi=[e.g["signal"] for e in evs if e.kind == "connected" and "signal" in e.g],
        report=report_numbers(find_report(report_dirs, name, source), runs),
        signal=signal_numbers(data_runs) if signal else None, signal_tried=signal,
    )
    r = s["report"]
    if r is not None and r["rem"] is not None and r["rem"].get("eye") is None:
        if signal:
            full, why = measure_eye(r["raw"], data_runs)
            if full is not None:
                r.update(rem=full, rem_eye_here=True)
            else:
                r["rem_why"] = why
        else:
            r["rem_why"] = "eye movements not measured here (--no-signal)"
    judge(s)
    return s


def _tail(last: Stretch, evs: list[Event]) -> Break | None:
    """The time between the last data and Stop (or the last log line) when the app was still trying: not part of
    the span (the owner may have taken the headband off before pressing Stop), but said."""
    after = [e for e in evs if e.t >= last.t1 - 2]
    if not after or after[-1].t - last.t1 <= LIST_GAP_S:
        return None
    br = Break(last.t1, after[-1].t, last.run, last.run)
    explain(br, after, 0)
    br.text = br.text.replace("; no log line explains it", "").replace("no log line explains it", "")
    return br


# ---- the verdict -----------------------------------------------------------------------------------------------------
def dur(sec: float) -> str:
    if sec < 90:
        return f"{sec:.0f} s"
    if sec < 5400:
        return f"{sec / 60:.1f} min"
    return f"{sec / 3600:.1f} h"


def plural(n: int, word: str, many: str | None = None) -> str:
    return f"{n} {word if n == 1 else many or word + 's'}"


def hm(t: float) -> str:
    return datetime.fromtimestamp(t).strftime("%H:%M")


def hms(t: float) -> str:
    return datetime.fromtimestamp(t).strftime("%H:%M:%S")


def _risky(settings: dict | None) -> list[str]:
    if not settings:
        return []
    bad = []
    if settings.get("battery-opt exempt") == "no":
        bad.append("the app is not exempt from battery optimisation")
    if settings.get("background restricted") == "yes":
        bad.append("background use is restricted")
    if settings.get("power save") == "yes":
        bad.append("battery saver was on")
    bucket = settings.get("standby bucket", "")
    if bucket.isdigit() and int(bucket) >= 40:
        bad.append(f"Android put the app in a rare-use group (standby bucket {bucket})")
    if settings.get("notifications") == "no":
        bad.append("notifications are off (the recording notice is hidden)")
    return bad


def judge(s: dict) -> None:
    """Verdict and the issues, each (score, text, effect): effect "bad" = not trustworthy, "gaps" = usable with gaps,
    None = worth fixing but not about the recorder (contact, hum, batteries)."""
    issues: list[tuple[int, str, str | None]] = []
    phone = s["source"] == "phone"
    who = "the app" if phone else "the recorder"
    signal_h, span = s["signal_s"] / 3600, s["span_s"]
    cover = s["signal_s"] / span if span > 0 else 1.0
    if signal_h < MIN_NIGHT_H:
        issues.append((100, f"Only {signal_h:.1f} h of signal: too short to judge the recorder; record a whole night.",
                       "bad"))
    if cover < BAD_COVER:
        issues.append((90, f"{100 - cover * 100:.0f} % of the night is missing ({dur(s['missing_s'])}).", "bad"))
    if s["rate"] is not None and abs(s["rate"] / s["fs"] - 1) > RATE_TOL:
        issues.append((85, f"Samples arrive at {s['rate']:.1f} a second, not {s['fs']:g}: the clock or the batches are off.",
                       "bad"))
    lost = s["packets"].lost / max(1, s["samples"] + s["packets"].lost)
    if lost > LOST_SOME:
        issues.append((80 if lost > LOST_BAD else 45, f"Bluetooth lost {lost * 100:.2f} % of the samples "
                       f"({s['packets'].jumps} counter jumps): keep the phone closer to the headband.",
                       "bad" if lost > LOST_BAD else "gaps"))
    if phone and s["stop"] is None:
        tail = s["tail"]
        if tail is not None and tail.length > 120:
            issues.append((88, f"The data stopped at {hm(s['end'])}; the app was still trying until "
                           f"{hm(tail.t1)} and there is no Stop line: the headband never came back "
                           f"({tail.text or 'no reason logged'}).", "bad"))
        elif not s["last_closed"]:
            issues.append((88, f"The recorder stopped by itself at {hm(s['end'])} and did not come back (no Stop in "
                           "the log): Android ended the app, or the phone switched off. Turn on Autostart and "
                           "battery saver 'No restrictions' for EEG Tracker.", "bad"))
        else:
            issues.append((48, f"The log has no Stop line (its last line is at {hm(s['last_line'])}): press Stop in "
                           "the morning before exporting.", "gaps"))
    tail = s["tail"]
    if phone and s["stop"] is not None and tail is not None and tail.length > TAIL_S and tail.cat != "unknown":
        issues.append((58, f"No data for the last {dur(tail.length)} before Stop (from {hm(tail.t0)}: {tail.text}). "
                       "If the headband was still on, keep the phone closer; if not, press Stop when you take it off.",
                       "gaps"))
    exits = sorted({e.g["reason"] for e in s["exits"]})
    if s["restarts"] or s["killed"]:
        n = max(len(s["restarts"]), len(s["killed"]))
        why = f" ({', '.join(exits)})" if exits else ""
        if phone:
            text = (f"Android ended the app {plural(n, 'time')}{why}: on the Xiaomi turn on "
                    "Autostart, set battery saver to 'No restrictions' for EEG Tracker and lock it in Recents.")
        else:
            text = (f"The laptop recorder died {plural(n, 'time')} without its closing lines (record_night.sh "
                    "started a fresh one each time).")
        issues.append((70, text, "gaps"))
    if s["stuck"]:
        what = sorted({e.g.get("what", "the main loop") for e in s["stuck"]})
        issues.append((65, f"Bluetooth got stuck {plural(len(s['stuck']), 'time')} "
                       f"({', '.join(what)}); {who} restarted itself each time. If it repeats, switch to our own "
                       "connection after the probe (Headband connection page).", "gaps"))
    drops = s["drops"]
    cost = sum(b.length for b in drops) + sum(b.length for b in s["hiccups"])  # gaps stopped by hand not counted
    worst = max(drops, key=lambda b: b.length, default=None)
    if cost / 60 > GAPS_MISSING_MIN or (worst and worst.length > GAPS_LONGEST_S):
        where = f"; the longest {dur(worst.length)} at {hm(worst.t0)}, {worst.text.split(';')[0]}" if worst else ""
        backs = [b.length for b in drops]
        slow = (f"; getting the headband back took a median of {dur(statistics.median(backs))}"
                if backs and statistics.median(backs) > SLOW_BACK_S else "")
        issues.append((60, f"{plural(len(drops), 'drop')} cost {dur(cost)}{where}{slow}. Keep the "
                       f"{'phone' if phone else 'laptop'} within about a metre of the headband, nothing in between.",
                       "gaps"))
    late = max((b.length for b in s["late"]), default=0)
    if late > LATE_S:
        issues.append((50, f"Android held the data back {plural(len(s['late']), 'time')} (longest {dur(late)}; "
                       "nothing was lost, but the times are wrong there): check the battery exemption.", "gaps"))
    risky = _risky(s["settings"])
    if risky:
        issues.append((55, "Phone settings: " + "; ".join(risky) + ". Fix them before the next night.", None))
    _setup_issues(s, issues)
    effects = {e for _, _, e in issues}
    s["verdict"] = ("Not trustworthy yet" if "bad" in effects else "Usable, with gaps" if "gaps" in effects
                    else "Good night for the recorder")
    s["fixes"] = [t for _, t, _ in sorted(issues, key=lambda i: -i[0])[:3]]


def band_issue(band: dict | None) -> str | None:
    """What to say about the headband's charge, or None. Never a stuck gauge value as its level (the false "ended at
    6 %" of 2026-11-19): the charge by wear time when a full reading is known, else a believable low reading."""
    if not band:
        return None
    est = band["estimate"]
    if est is not None:
        if est["pct"] >= LOW_BAND_PCT:
            return None
        if est["hours"] > 0 and est["full"] - battery.DRAIN_PER_H * est["hours"] < 0:
            return (f"The headband streamed {est['hours']:.1f} h after its {est['full']} % reading, longer than the "
                    f"estimate of {battery.DRAIN_PER_H:g} %/h allows (so it drained under "
                    f"{est['full'] / est['hours']:.1f} %/h): it is probably nearly empty. Charge it before the next "
                    "night.")
        return (f"The headband streamed {est['hours']:.1f} h after its {est['full']} % reading: about {est['pct']} % "
                f"left by wear time (an estimate; the gauge is not reliable while it streams). Charge it before the "
                "next night.")
    if band["last"] is not None and band["last"] < LOW_BAND_PCT:
        return f"The headband's gauge last read {band['last']} %: charge it before the next night."
    return None


def _setup_issues(s: dict, issues: list) -> None:
    c = s["contact"]
    if c["start"] is None:
        issues.append((38, "No contact reading at the start of the night: let the contact check finish before "
                       "lying down.", None))
    else:
        bad = [f"{ch} {ohms_text(v)}" for ch, v in c["start"][1].items() if contact_word(v) in ("poor", "none")]
        if bad:
            issues.append((40, f"Contact at the start was poor or missing on {', '.join(bad)}: moisten and seat "
                           "those electrodes before Start.", None))
    sig = s["signal"]
    if sig:
        for ch, f, r in zip(s["channels"], sig["flat"], sig["railed"]):
            if (f + r) / sig["seconds"] > BAD_SHARE:
                issues.append((42, f"{ch} was flat or at the rail for {dur(f + r)} "
                               f"({(f + r) / sig['seconds'] * 100:.0f} % of the night): that electrode lost the skin.",
                               None))
        high = [ch for ch, h in zip(s["channels"], sig["hum"]) if h is not None and h > HUM_HIGH]
        if high:
            issues.append((35, f"Strong 50 Hz hum on {', '.join(high)}: keep chargers and mains cables away from the "
                           "bed.", None))
    band_fix = band_issue(s["battery"]["band"])
    if band_fix:
        issues.append((30, band_fix, None))
    ph = s["battery"]["phone"]
    rate = ph and (ph["steady"]["per_hour"] if ph["steady"] else ph["per_hour"])
    if ph and not ph["plugged"] and rate is not None and rate > 5:
        issues.append((32, f"The phone used {rate:.1f} % an hour (about {rate * 8:.0f} % for 8 hours"
                       f"{', screen off' if ph['steady'] else ''}): charge it overnight.", None))
    w = s["wifi"]
    if s["source"] == "phone" and w and w["shared"]:
        long = [(a, b) for a, b, _ in w["off"] if (b or s["last_line"]) - a >= WIFI_OFF_S]
        if long:
            when = "; ".join(f"from {hm(a)} to {hm(b)}" if b else f"from {hm(a)} until the end" for a, b in long)
            issues.append((33, f"Wi-Fi was off {when} while sharing was on, so the laptop could not mirror the night "
                           "then (nothing is lost: the night is on the phone). Check the phone's Wi-Fi sleep settings "
                           "(app/README.md, Share on Wi-Fi).", None))
    if s["unknown"]:
        issues.append((25, f"{len(s['unknown'])} log lines this check does not know (first: "
                       f"'{s['unknown'][0][:90]}'): teach scripts/phone_night_check.py.", None))
    if s["source"] == "phone" and s["report"] is None:
        issues.append((20, "No phone sleep report for this night: open the night on the phone so it scores, then "
                       "export again.", None))


# ---- the text --------------------------------------------------------------------------------------------------------
def _per_hour(values: dict[float, float], fmt: str) -> list[str]:
    cells = [f"{datetime.fromtimestamp(h):%H}h {fmt.format(v)}" for h, v in values.items()]
    return ["  ".join(cells[i:i + 10]) for i in range(0, len(cells), 10)]


def render(s: dict) -> str:
    src = "Phone" if s["source"] == "phone" else "Laptop"
    if s.get("empty"):
        return f"{src} night of {s['name']}: {s['runs']} recordings, no samples at all."
    out = [f"{src} night of {s['name']} (evening date): {s['data_runs']} recordings with data, "
           f"{hm(s['start'])} to {hm(s['end'])}", ""]
    cover = s["signal_s"] / s["span_s"] * 100 if s["span_s"] else 100
    deaths = max(len(s["restarts"]), len(s["killed"]))
    who = plural(deaths, "restart") + " by Android" if s["source"] == "phone" else plural(deaths, "recorder death")
    out.append(f"Verdict: {s['verdict']} ({s['signal_s'] / 3600:.1f} of {s['span_s'] / 3600:.1f} h recorded, "
               f"{cover:.0f} %; {plural(len(s['drops']), 'drop')}; {who})")
    out.append("Fix first:" if s["fixes"] else "Nothing to fix from this night.")
    out += [f"  {i}. {t}" for i, t in enumerate(s["fixes"], 1)]
    out += ["", "Time"]
    out.append(f"  span          {hms(s['start'])} to {hms(s['end'])}, {dur(s['span_s'])}")
    out.append(f"  signal        {s['signal_s'] / 3600:.2f} h; missing {s['missing_s'] / 60:.1f} min")
    out += [f"  {'per hour' if i == 0 else '':14}{line}" for i, line in
            enumerate(_per_hour(s["per_hour"], "{:.0f}"))]
    listed = [b for b in s["breaks"] if b.cat != "late" and b.length > LIST_GAP_S]
    out.append(f"  gaps > 30 s   {len(listed)}")
    shown = sorted(sorted(listed, key=lambda b: -b.length)[:SHOW_GAPS], key=lambda b: b.t0)
    out += [f"    {hms(b.t0)}  {dur(b.length):>8}  {b.text}" for b in shown]
    if len(listed) > len(shown):
        rest = [b for b in listed if b not in shown]
        out.append(f"    and {len(rest)} shorter ones, {dur(sum(b.length for b in rest))} in all")
    if s["tail"] is not None:
        t = s["tail"]
        until = "Stop" if s["stop"] is not None else "the last log line"
        out.append(f"  after data    {dur(t.length)} from {hm(t.t0)} until {until}" + (f": {t.text}" if t.text else ""))
    short = [b for b in s["breaks"] if b.cat != "late" and b.length <= LIST_GAP_S]
    if short or s["late"]:
        bits = []
        if short:
            bits.append(f"{len(short)} under 30 s ({dur(sum(b.length for b in short))} in all)")
        if s["late"]:
            longest = max(b.length for b in s["late"])
            bits.append(f"data held back {plural(len(s['late']), 'time')}, longest {dur(longest)} (nothing lost)")
        out.append(f"  short gaps    {'; '.join(bits)}")
    if s["rate"] is not None:
        rng = f"; stretches over 10 min {s['rate_range'][0]:.2f} to {s['rate_range'][1]:.2f}" if s["rate_range"] else ""
        out.append(f"  rate          {s['rate']:.2f} samples/s (should be {s['fs']:g}) over {dur(s['rate_s'])} of unbroken "
                   f"data{rng}")
    pk = s["packets"]
    out += ["", "Packets"]
    share = pk.lost / max(1, s["samples"] + pk.lost) * 100
    out.append(f"  lost          {pk.lost} samples in {pk.jumps} counter jumps ({share:.3f} %), longest {pk.longest}"
               + (f"; repeated {pk.repeats}" if pk.repeats else ""))
    if pk.per_hour:
        out += [f"  {'per hour' if i == 0 else '':14}{line}" for i, line in
                enumerate(_per_hour({h: pk.per_hour.get(h, 0) for h in s["per_hour"]}, "{:.0f}"))]
    if s["app_packets"]:
        a = s["app_packets"]
        out.append(f"  app's count   missing {a['missing']} in {a['gaps']} gaps, repeated {a['rep']}, longest gap "
                   f"{a['longest']} (its own line; it may count the SDK's leftover first batch of a connection)")
    out += ["", "Drops and reconnects"]
    backs = [b.length for b in s["drops"]]
    kinds: dict[str, int] = {}
    for b in s["drops"]:
        k = b.text.split(";")[0]
        kinds[k] = kinds.get(k, 0) + 1
    out.append(f"  drops         {len(s['drops'])}" + (
        f": back after a median of {dur(statistics.median(backs))}, worst {dur(max(backs))}" if backs else ""))
    out += [f"                {n} x {k}" for k, n in sorted(kinds.items(), key=lambda kv: -kv[1])[:5]]
    if s["hiccups"]:
        out.append(f"  hiccups       {len(s['hiccups'])} pauses under {SHORT_DROP_S} s inside a file")
    t = s["tries"]
    if t["direct"] or t["scan"]:
        out.append(f"  tries         direct {t['direct']} (connected {t['direct_ok']}), scan {t['scan']} "
                   f"(connected {t['scan_ok']})")
    out.append("  stuck         " + (", ".join(f"{hm(e.t)} {e.g.get('what', 'main loop')}" for e in s["stuck"])
                                    if s["stuck"] else 'none (the "Bluetooth stuck" path was not taken)'))
    if s["rssi"]:
        dbm = [int(m.group(1)) for x in s["rssi"] if (m := re.match(r"(-?\d+) dBm", x))]
        out.append(f"  signal        {len(s['rssi'])} connections" + (
            f"; at the scan median {statistics.median(dbm):.0f} dBm, weakest {min(dbm)} dBm" if dbm else
            "; none through a scan, so no strength"))
    out += ["", "Android" if s["source"] == "phone" else "Recorder"]
    if s["source"] == "phone":
        out.append("  restarts      " + (", ".join(hm(e.t) for e in s["restarts"]) + " by Android" if s["restarts"]
                                       else "none by Android"))
        for e in s["exits"]:
            desc = f" ({e.g['desc']})" if e.g.get("desc") else ""
            out.append(f"    process ended {e.g['when'][11:19]} {e.g['reason']}{desc}")
        if s["direct_off"]:
            out.append("  direct        off after a restart during a direct connection (scans only)")
        out.append("  Wi-Fi         " + wifi_text(s))
    else:
        out.append(f"  runs          {s['runs']} recorder runs ({s['data_runs']} with data)")
    if s["killed"]:
        died = [hm(max(e.t for e in r.events if e.kind not in NOTES) if any(e.kind not in NOTES for e in r.events)
                    else r.start) for r in s["killed"]]
        out.append("  died          " + ", ".join(died[:8]) + (f" and {len(died) - 8} more" if len(died) > 8 else "")
                   + " (a run ended without its closing lines)")
    if s["settings"]:
        out.append("  settings      " + ", ".join(f"{k} {v}" for k, v in s["settings"].items()))
    if s["source"] == "phone":
        out.append("  stop          " + (f"Stop pressed at {hm(s['stop'])}" if s["stop"] else
                                         "no Stop line in the log"))
    elif s["laptop_stop"]:
        out.append(f"  stop          last 'stopped' line at {hm(s['laptop_stop'])}")
    if s["helpers"]:
        more = len(s["helpers"]) - 3
        out.append("  helpers       " + "; ".join(f"{hm(t)} {text[:90]}" for t, text in s["helpers"][:3])
                   + (f"; and {more} more" if more > 0 else ""))
    out += ["", "Battery"]
    ph, band = s["battery"]["phone"], s["battery"]["band"]
    if ph:
        rate = f"{ph['per_hour']:.1f} %/h" if ph["per_hour"] is not None else "too short for a rate"
        mah = f", {ph['mah_per_hour']:.0f} mAh/h" if ph["mah_per_hour"] is not None else ""
        lo, hi = ph["temp"] or (None, None)
        temp = "" if lo is None else f", {lo:.0f} °C" if round(lo) == round(hi) else f", {lo:.0f}-{hi:.0f} °C"
        plug = "charger connected at some point" if ph["plugged"] else "unplugged"
        out.append(f"  phone         {ph['first']} % to {ph['last']} % in {ph['hours']:.1f} h ({rate}{mah}), {plug}"
                   f"{temp}; {ph['readings']} readings")
        out.append("  phone's cost  " + phone_cost_text(ph["steady"]))
    elif s["source"] == "phone":
        out.append("  phone         no phone battery lines")
    if s["battery"]["summary"]:
        out.append(f"  app's summary {s['battery']['summary']}")
    if band:
        out.append("  headband      " + band_text(band))
    c = s["contact"]
    out += ["", "Contact" + (f" at the start ({hm(c['start'][0])})" if c["start"] else "")]
    if c["start"]:
        out.append("  " + "   ".join(f"{ch} {ohms_text(c['start'][1].get(ch))} {contact_word(c['start'][1].get(ch))}"
                                     for ch in s["channels"]))
    else:
        out.append("  no reading" + (f" ({c['failed']} failed checks)" if c["failed"] else ""))
    if c["later"]:
        t, last = c["later"][-1]
        out.append(f"  later         {len(c['later'])} readings; last at {hm(t)}: "
                   + "  ".join(f"{ch} {ohms_text(last.get(ch))}" for ch in s["channels"]))
    out += _render_signal(s)
    out += _render_report(s)
    unk = s["unknown"]
    out += ["", f"Log: {s['lines']} lines read, " + (f"{len(unk)} not understood, e.g. '{unk[0][:100]}'" if unk
                                                       else "all understood.")]
    return "\n".join(out)


def phone_cost_text(st: dict | None) -> str:
    """`62 mAh/h (1.3 %/h, 61 mA) over 8.1 steady hours; left out: ...`: the phone's own cost (DECISIONS 767)."""
    if st is None:
        return "under 20 steady minutes (charging, the first hour after unplugging or the screen on)"
    left = [f"the first {st['unplug_skipped_h']:.1f} h after unplugging"] if st["unplug_skipped_h"] else []
    if st["screen_hours"]:
        how = "the screen on" if st["screen"] == "logged" else f"over {SCREEN_MA:.0f} mA, the screen likely on"
        left.append(f"{plural(st['screen_hours'], 'hour')} with {how}")
    ma = f", {st['ma']:.0f} mA" if st["ma"] is not None else ""
    return (f"{st['mah_per_hour']:.0f} mAh/h ({st['per_hour']:.1f} %/h{ma}) over {st['hours']:.1f} "
            f"steady hours" + (f"; left out: {', '.join(left)}" if left else ""))


def band_text(band: dict) -> str:
    """The headband's gauge in words: believable readings, the stuck values left out, the charge by wear time."""
    if band["first"] is None:
        head = f"only the gauge's stuck values ({band['readings']} readings)"
    elif band["first_t"] == band["last_t"]:
        head = f"gauge {band['first']} % at {hm(band['first_t'])} (the only believable reading)"
    else:
        rate = f", {band['per_hour']:.1f} %/h" if band["per_hour"] is not None else ""
        rate += ", charged in between" if band["charged"] else ""
        head = f"{band['first']} % to {band['last']} % (lowest {band['low']} %){rate}"
    if band["stuck"]:
        head += (f"; {band['stuck']} stuck readings left out (stuck at "
                 f"{', '.join(f'{v} %' for v in band['stuck_at'])})")
    est = band["estimate"]
    if est is not None:
        head += (f"; about {est['pct']} % at the end by wear time (an estimate: {est['hours']:.1f} h streamed since "
                 f"the {est['full']} % reading at {hm(est['since'])}, {battery.DRAIN_PER_H:g} %/h)")
    return head


def wifi_text(s: dict) -> str:
    """`off from 03:25 to 07:40 (not connected, screen off, default route cell)`, or `connected all night (...)`."""
    w = s["wifi"]
    if w is None:
        return "not logged (an app from before 2026-11-20)"
    failed = f"; {plural(w['unreadable'], 'reading')} failed" if w["unreadable"] else ""
    if not w["off"]:
        sig = f"; signal {w['dbm'][0]} to {w['dbm'][1]} dBm" if w["dbm"] else ""
        return f"connected all night ({plural(w['lines'], 'line')}{sig}{failed})"
    return "; ".join(f"off from {hm(a)} to {hm(b)} ({what})" if b is not None else
                     f"off from {hm(a)} until the end ({hm(s['last_line'])}; {what})" for a, b, what in w["off"]) + failed


def _render_signal(s: dict) -> list[str]:
    sig = s["signal"]
    if not sig:
        why = "numpy not found: run under `uv run --project analysis`" if s["signal_tried"] else "--no-signal"
        return ["", f"Signal: skipped ({why})"]
    out = ["", "Signal        " + "".join(f"{ch:>10}" for ch in s["channels"])]
    out.append("  flat min    " + "".join(f"{v / 60:>10.1f}" for v in sig["flat"]))
    out.append("  railed min  " + "".join(f"{v / 60:>10.1f}" for v in sig["railed"]))
    out.append("  50 Hz hum   " + "".join(f"{hum_word(h):>10}" for h in sig["hum"]))
    out.append(f"  (hum: power at 49-51 Hz against 30-45 Hz, median of one 4 s window a minute; "
               f"over {HUM_SOME} some, over {HUM_HIGH} high, as the live page)")
    if sig.get("other"):
        out.append(f"  recordings of this night that hold other channels, not in this table: {'; '.join(sig['other'])}")
    return out


def hum_word(h: float | None) -> str:
    """`low 4`, `some 25`, `high >999`; `-` for a channel with nothing to compare (flat)."""
    if h is None:
        return "-"
    return f"{'high' if h > HUM_HIGH else 'some' if h > HUM_SOME else 'low'} {f'{h:.0f}' if h < 1000 else '>999'}"


def _render_report(s: dict) -> list[str]:
    r = s["report"]
    whose = "phone's" if s["source"] == "phone" else "laptop's"
    if r is None:
        return ["", f"The {whose} sleep report: none found"]
    out = ["", f"The {whose} sleep report ({r['file']})"]
    if not r["scored"]:
        out.append("  not scored (under 5 minutes recorded)")
    else:
        out.append(f"  asleep {(r['asleep_min'] or 0) / 60:.1f} h in {r['periods']} "
                   f"{'period' if r['periods'] == 1 else 'periods'}; {r['missing_min']} min missing of "
                   f"{r['recorded_min']} min")
    if r["scoring_s"] is not None:
        sec = round(r["scoring_s"])
        took = f"{sec} s" if sec < 120 else f"{round(sec / 60)} min"
        out.append(f"  scored {'on this phone' if r['phone'] else 'on the laptop'} in {took}; it covers {r['covers']} "
                   f"of the {r['of']} recordings")
    q = r["quality"]
    if q:
        out.append(f"  quality: good {q.get('good_min')} min, degraded {q.get('degraded_min')} min, missing "
                   f"{q.get('missing_min')} min")
    return out + _render_rem(r)


def _render_rem(r: dict) -> list[str]:
    """The dream sleep check in the phone's words, then its numbers (DECISIONS 740-749)."""
    c = r.get("rem")
    if c is None:
        return [] if not r["scored"] else ["", "Dream sleep check: not possible (the report has no stages: an older "
                                           "laptop report)"]
    lines = rc.check_lines(c)
    if r.get("rem_eye_here"):
        lines = [x for x in lines if not x.startswith("This report is older than the check")]
    out = ["", "Dream sleep check" + (" (eye movements measured here from the recordings; the report predates them)"
                                      if r.get("rem_eye_here") else "")]
    out += [f"  {x}" for x in lines]
    if r.get("rem_why"):
        out.append(f"  ({r['rem_why']})")
    if c.get("rem_prob_min") is None and c.get("asleep_min"):
        out.append("  (the scorer's likelihood is not in this report: it was scored before 2026-11-20; score it again)")
    nums = [f"REM {c['rem_min']} of {c['asleep_min']} min asleep",
            f"first REM {c['first_rem_min']} min after sleep onset" if c.get("first_rem_min") is not None else None,
            f"thirds {' / '.join(str(t) for t in c['thirds_rem_min'])} min" if c.get("thirds_rem_min") else None,
            f"REM likelihood {c['rem_prob_min']} min" if c.get("rem_prob_min") is not None else None]
    out.append("  numbers: " + "; ".join(n for n in nums if n))
    e = c.get("eye")
    if e and e.get("pair"):
        dense = ", ".join(f"{k} {v}" for k, v in (e.get("dense_share") or {}).items())
        out.append(f"  eye movements ({e['pair']}): {e['measured_min']} min of sleep measured; share in REM "
                   f"{e['in_rem_share']} (REM is {e['rem_epoch_share']} of it); seconds a minute in REM "
                   f"{e['rem_per_min']}, in other sleep {e['other_per_min']}; epochs with {rc.DENSE_S}+ s by stage: "
                   f"{dense}")
    return out


def render_compare(a: dict, b: dict) -> str:
    def col(s: dict) -> dict[str, str]:
        if s.get("empty"):
            return {}
        pk, sig, band = s["packets"], s["signal"], s["battery"]["band"]
        backs = [x.length for x in s["drops"]]
        c = s["contact"]["start"]
        return {
            "span": dur(s["span_s"]),
            "signal": f"{s['signal_s'] / 3600:.1f} h ({s['signal_s'] / s['span_s'] * 100:.0f} %)",
            "missing": f"{s['missing_s'] / 60:.0f} min",
            "gaps over 30 s": str(sum(1 for x in s["breaks"] if x.cat != "late" and x.length > LIST_GAP_S)),
            "drops": str(len(s["drops"])),
            "back after (median)": dur(statistics.median(backs)) if backs else "-",
            "back after (worst)": dur(max(backs)) if backs else "-",
            "restarts or deaths": str(max(len(s["restarts"]), len(s["killed"]))),
            "Bluetooth stuck": str(len(s["stuck"])),
            "lost samples": f"{pk.lost / max(1, s['samples'] + pk.lost) * 100:.3f} %",
            "samples/s": f"{s['rate']:.2f}" if s["rate"] else "-",
            "headband battery": (f"{band['first']} -> {band['last']} %" if band and band["first"] is not None
                                 else "stuck gauge" if band else "-"),
            "contact at start, kΩ": " ".join(f"{v / 1e3:.0f}" if v not in (None, float("inf")) else "-"
                                             for v in (c[1].get(ch) for ch in s["channels"])) if c else "-",
            "flat+railed min": " ".join(f"{(f + r) / 60:.0f}" for f, r in zip(sig["flat"], sig["railed"]))
            if sig else "-",
            "50 Hz hum": " ".join(hum_word(h).split()[0] for h in sig["hum"]) if sig else "-",
            "verdict": s["verdict"],
        }
    ca, cb = col(a), col(b)
    ha, hb = f"{a['source']} {a['name']}", f"{b['source']} {b['name']}"
    w = max([len(ha)] + [len(v) for v in ca.values()]) + 3
    rows = [f"Next to the {b['source']} night of {b['name']}", f"  {'':22}{ha:<{w}}{hb}"]
    rows += [f"  {k:22}{ca.get(k, '-'):<{w}}{cb.get(k, '-')}" for k in dict.fromkeys(list(ca) + list(cb))]
    return "\n".join(rows)


# ---- the command -----------------------------------------------------------------------------------------------------
def folders(data: Path) -> tuple[Path, list[Path]]:
    """The recordings folder and where sleep reports may be: `_local/` (phone/nights, nights), the phone's
    `eeg-export/` (nights) or a bare recordings folder (its parent's)."""
    rec = data / "recordings" if (data / "recordings").is_dir() else data
    base = data if rec != data else data.parent
    return rec, [base / "phone" / "nights", base / "nights"]


def check(data: Path, name: str | None, source: str = "auto", signal: bool = True) -> dict:
    rec_dir, report_dirs = folders(data)
    runs = load_runs(rec_dir)
    recs = {r.path.stem: r for r in nf.recordings(rec_dir)}
    src, night, chosen = pick(runs, recs, name, source)
    return analyse(chosen, src, night.name, report_dirs, signal)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("night", nargs="?", help="evening date YYYY-MM-DD (default: the newest phone night)")
    ap.add_argument("--data", type=Path, default=ROOT / "_local",
                    help="_local/, the phone's eeg-export folder or a recordings folder (default: %(default)s)")
    ap.add_argument("--source", choices=("auto", "phone", "laptop"), default="auto",
                    help="whose recordings make the night (auto: the phone's if it recorded that night)")
    ap.add_argument("--compare", metavar="LAPTOP_NIGHT", help="a laptop night's evening date to put beside it")
    ap.add_argument("--no-signal", action="store_true", help="skip the flat / railed / hum numbers")
    a = ap.parse_args(argv)
    if a.night and not nf.DATE.match(a.night):
        ap.error(f"night must be an evening date like 2026-11-19, not {a.night}")
    try:
        s = check(a.data, a.night, a.source, not a.no_signal)
    except (LookupError, recording.RecordingError) as e:
        print(e, file=sys.stderr)
        return 2
    print(render(s))
    if a.compare:
        try:
            other = check(a.data, a.compare, "laptop", not a.no_signal)
        except (LookupError, recording.RecordingError) as e:
            print(f"\nNo comparison: {e}")
        else:
            print("\n" + render_compare(s, other))
    return 0


if __name__ == "__main__":
    sys.exit(main())
