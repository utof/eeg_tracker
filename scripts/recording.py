"""The recording header, <stamp>.header.json: what a raw <stamp>.f32 holds, for any number of channels.

docs/data-format.md "The recording header": the .f32 record is `<I` + one `<f` per channel (`<I4f`, 20 bytes, for the
BrainBit; `<I8f`, 36 bytes, for 8 channels; `<I16f`, 68 bytes, for 16) and the header names the channels in record
order, their 10-10 sites, the rate, the unit, what the uint32 counts, the device, the layout and the reference.
Owner's rule (2026-11-20): features are made with custom arrangements and numbers of electrodes in mind.

  write(f32, header)   once, when a file set opens and before its first sample (a temporary name, then renamed)
  read(f32)            the header beside a .f32 (plain or packed name); for a file from before the header existed:
                       the .log's format line (the DIY board's), else the BrainBit's O1 O2 T3 T4 at 250 Hz, `<I4f`
  pick(header, names)  the places in the record of the channels a feature needs, by exact name first, else by 10-10
                       site (T3 = T7, T4 = T8, T5 = P7, T6 = P8, any letter case); a recording without one is an
                       error that says which sites are needed and which channels it has, never another channel

A header that is not valid JSON or breaks a rule is a HeaderError that names the file: readers never guess past a
damaged header. Standard library only: the recorder hub imports this and must never import numpy (DECISIONS 3).

`session` (optional) says what kind of session wrote a file set when it is not sleep: `work` for the phone's work
session (DECISIONS 683). Such a set is never a night (night_files.recordings leaves it out); absent, `night` or `nap`:
sleep, as every file before it. `recording` (optional, DECISIONS 882) is the id of the recording the set belongs to: such a
set is never chained by the old 3-hour rule (night_files.py); its spans (spans.py) say what was sleep.
"""
from __future__ import annotations

import json, math, os, re, struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

FORMAT, VERSION = "eeg-tracker-recording", 1
SUFFIX = ".header.json"
MAX_CHANNELS, MAX_NAME = 64, 32
MAX_SITE = 16
UNIT = "V"
XYZ_TOLERANCE = 0.01  # |length - 1| of a direction on the head (the documented ones are rounded to 3 places)
LOG_BYTES = 256 * 1024  # the format line is among a .log's first lines: only this much of it is searched
PACKET_NUMBER, SEQUENCE_NUMBER = "packet number", "board sequence number"
BRAINBIT, DIY_BOARD = "BrainBit", "DIY board"
BRAINBIT_NAMES = ("O1", "O2", "T3", "T4")
SLEEP_SESSIONS = frozenset({"night", "nap"})  # a header's `session` whose file set joins the nights, as one without
BRAINBIT_FS = 250

# the 10-10 sites (and the earlobes and mastoids, which the reference and the bias use), as they are written
SITES = (
    "Nz Fp1 Fpz Fp2 AF7 AF3 AFz AF4 AF8 F9 F7 F5 F3 F1 Fz F2 F4 F6 F8 F10 FT9 FT7 FC5 FC3 FC1 FCz FC2 FC4 FC6 FT8 "
    "FT10 T9 T7 C5 C3 C1 Cz C2 C4 C6 T8 T10 TP9 TP7 CP5 CP3 CP1 CPz CP2 CP4 CP6 TP8 TP10 P9 P7 P5 P3 P1 Pz P2 P4 P6 "
    "P8 P10 PO7 PO3 POz PO4 PO8 O1 Oz O2 Iz A1 A2 M1 M2").split()
OLD_NAMES = {"T3": "T7", "T4": "T8", "T5": "P7", "T6": "P8"}  # the 10-20 names of four 10-10 sites
_SITE = {**{s.lower(): s for s in SITES}, **{old.lower(): new for old, new in OLD_NAMES.items()}}
_LOG_FORMAT = re.compile(r"format \.f32 records <I(\d+)f\b[^\n]*?; (\d+(?:\.\d+)?) Hz")
_LOG_NAMES = re.compile(r", then (.*) in volts")


class RecordingError(ValueError):
    """What a recording holds could not be read, or it does not hold what a feature needs."""


class HeaderError(RecordingError):
    """A header (or a .log's format line) that breaks a rule; the message names the file."""


class MissingChannels(RecordingError):
    """A recording without a site a feature needs; the message names the sites needed and the channels it has."""

    def __init__(self, message: str, missing: tuple[str, ...]) -> None:
        super().__init__(message)
        self.missing = missing


@dataclass(frozen=True)
class Channel:
    name: str  # as the device names it: O1, T3, Ch5
    site: str | None = None  # its 10-10 name when it is one (T3 -> T7)
    xyz: tuple[float, float, float] | None = None  # its direction on the head (right, front, up), unit length


@dataclass(frozen=True)
class Electrode:
    """The reference or the ground (bias)."""
    name: str
    where: str | None = None  # in words
    site: str | None = None


@dataclass(frozen=True)
class Header:
    channels: tuple[Channel, ...]  # in record order
    sample_rate: int | float
    counter: str  # what the record's uint32 is
    device: str | None = None
    layout: str | None = None
    reference: Electrode | None = None
    ground: Electrode | None = None
    made_by: str | None = None
    session: str | None = None  # `work`: a work session's raw EEG, never a night; None: sleep (DECISIONS 683)
    recording: str | None = None  # the id of the recording the set belongs to (Record first, DECISIONS 882); None: old
    unit: str = UNIT
    source: str = field(default="header", compare=False)  # "header" | "log" (its format line) | "default" (BrainBit)

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(c.name for c in self.channels)

    @property
    def n(self) -> int:
        return len(self.channels)

    @property
    def record(self) -> str:
        return record_format(self.n)

    @property
    def record_bytes(self) -> int:
        return record_bytes(self.n)

    @property
    def struct(self) -> struct.Struct:
        return record_struct(self.n)

    @property
    def is_sleep(self) -> bool:
        """The file set joins the nights: no `session`, or `night` / `nap`."""
        return self.session is None or self.session in SLEEP_SESSIONS

    def describe(self) -> str:
        """`DIY board: Ch1 Ch2 ...`: the device (when known) and the channels, for messages."""
        names = " ".join(self.names)
        return f"{self.device}: {names}" if self.device else names


# ---- the record ---------------------------------------------------------------------------------------------------

def record_format(n: int) -> str:
    """`<I4f` for 4 channels: a uint32, then one float32 per channel, little-endian."""
    if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= MAX_CHANNELS:
        raise ValueError(f"a record holds 1 to {MAX_CHANNELS} channels, not {n!r}")
    return f"<I{n}f"


def record_struct(n: int) -> struct.Struct:
    return struct.Struct(record_format(n))


def record_bytes(n: int) -> int:
    return record_struct(n).size


# ---- sites --------------------------------------------------------------------------------------------------------

def site_of(name: str | None) -> str | None:
    """The 10-10 site a name is, old names as the new (`t3` -> `T7`, `oz` -> `Oz`); None when it is not one."""
    return _SITE.get(name.strip().lower()) if isinstance(name, str) else None


# ---- making one ---------------------------------------------------------------------------------------------------

def brainbit(made_by: str | None = None) -> Header:
    """The BrainBit headband's: O1 O2 T3 T4 at 250 Hz, referenced to the forehead."""
    return Header(tuple(Channel(n, site_of(n)) for n in BRAINBIT_NAMES), BRAINBIT_FS, PACKET_NUMBER, device=BRAINBIT,
                  layout=BRAINBIT, reference=Electrode("Ref", "forehead", "Fpz"), ground=None, made_by=made_by)


def diy_board(names: Sequence[str], sample_rate: int | float, layout: str | None = None, reference: str | None = None,
              bias: str | None = None, made_by: str | None = None) -> Header:
    """The DIY ADS1299 board's: its channel names (a site when a name is a 10-10 one) and rate; `reference` and
    `bias` are the montage's words for where those electrodes sit (a site when the words are just a 10-10 name)."""
    return checked(Header(
        tuple(Channel(str(n), site_of(n)) for n in names), sample_rate, SEQUENCE_NUMBER, device=DIY_BOARD, layout=layout,
        reference=None if reference is None else Electrode("Ref", reference, site_of(reference)),
        ground=None if bias is None else Electrode("Bias", bias, site_of(bias)), made_by=made_by), "this header")


def _electrode_json(e: Electrode | None) -> dict | None:
    return None if e is None else {"name": e.name, "where": e.where, "site": e.site}


def to_json(h: Header) -> dict:
    """The header as the JSON object of <stamp>.header.json (optional fields left out when not known)."""
    d: dict = {"format": FORMAT, "version": VERSION}
    if h.device is not None:
        d["device"] = h.device
    if h.layout is not None:
        d["layout"] = h.layout
    d["channels"] = [{"name": c.name, "site": c.site, "xyz": None if c.xyz is None else list(c.xyz)} for c in h.channels]
    d["reference"], d["ground"] = _electrode_json(h.reference), _electrode_json(h.ground)
    d.update(sample_rate=h.sample_rate, unit=h.unit, record=h.record, counter=h.counter)
    if h.made_by is not None:
        d["made_by"] = h.made_by
    if h.session is not None:
        d["session"] = h.session
    if h.recording is not None:
        d["recording"] = h.recording
    return d


# ---- checking one -------------------------------------------------------------------------------------------------

def _fail(where: object, why: str) -> HeaderError:
    return HeaderError(f"{where}: not a valid recording header: {why}")


def _text(d: dict, key: str, where: object, required: bool = False, none_ok: bool = True) -> str | None:
    v = d.get(key)
    if v is None and not required and (none_ok or key not in d):
        return None
    if not isinstance(v, str) or (required and not v):
        raise _fail(where, f"`{key}` must be {'a non-empty ' if required else ''}text, not {v!r}")
    return v


def _site(v: object, what: str, where: object) -> str | None:
    if v is None:
        return None
    if not isinstance(v, str) or not 1 <= len(v) <= MAX_SITE:
        raise _fail(where, f"{what}: `site` must be a 10-10 name or null, not {v!r}")
    return v


def _number(v: object) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _xyz(v: object, what: str, where: object) -> tuple[float, float, float] | None:
    if v is None:
        return None
    if not isinstance(v, list) or len(v) != 3 or not all(_number(x) for x in v):
        raise _fail(where, f"{what}: `xyz` must be three numbers (right, front, up) or null, not {v!r}")
    if abs(math.sqrt(sum(float(x) ** 2 for x in v)) - 1.0) > XYZ_TOLERANCE:
        raise _fail(where, f"{what}: `xyz` must have unit length, not {v!r}")
    return (float(v[0]), float(v[1]), float(v[2]))


def _channels(v: object, where: object) -> tuple[Channel, ...]:
    if not isinstance(v, list) or not 1 <= len(v) <= MAX_CHANNELS:
        raise _fail(where, f"`channels` must list 1 to {MAX_CHANNELS} channels")
    out: list[Channel] = []
    for i, c in enumerate(v):
        what = f"channel {i + 1}"
        if not isinstance(c, dict):
            raise _fail(where, f"{what} must be an object, not {c!r}")
        name = c.get("name")
        if not isinstance(name, str) or not 1 <= len(name) <= MAX_NAME:
            raise _fail(where, f"{what}: `name` must be 1 to {MAX_NAME} characters, not {name!r}")
        if any(name == o.name for o in out):
            raise _fail(where, f"the name {name} is there twice")
        out.append(Channel(name, _site(c.get("site"), what, where), _xyz(c.get("xyz"), what, where)))
    return tuple(out)


def _electrode(d: dict, key: str, where: object) -> Electrode | None:
    v = d.get(key)
    if v is None:
        return None
    if not isinstance(v, dict):
        raise _fail(where, f"`{key}` must be an object or null, not {v!r}")
    name = _text(v, "name", f"{where}: `{key}`", required=True)
    return Electrode(str(name), _text(v, "where", f"{where}: `{key}`"), _site(v.get("site"), f"`{key}`", where))


def _rate(v: object, where: object) -> int | float:
    if not _number(v) or not v > 0:  # type: ignore[operator]
        raise _fail(where, f"`sample_rate` must be a number above 0, not {v!r}")
    return int(v) if float(v) == int(v) else float(v)  # type: ignore[arg-type]


def parse(obj: object, where: object = "header") -> Header:
    """The header in a parsed JSON value; `where` (the file) is named in every error. Unknown fields are ignored."""
    if not isinstance(obj, dict):
        raise _fail(where, "it is not a JSON object")
    if obj.get("format") != FORMAT:
        raise _fail(where, f"`format` must be {FORMAT}, not {obj.get('format')!r}")
    version = obj.get("version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        raise _fail(where, f"`version` must be a whole number from 1, not {version!r}")
    if version > VERSION:
        raise HeaderError(f"{where}: this recording header is version {version}, written by a newer program; "
                          f"this one reads version {VERSION}")
    channels = _channels(obj.get("channels"), where)
    if obj.get("unit") != UNIT:
        raise _fail(where, f"`unit` must be {UNIT} (volts), not {obj.get('unit')!r}")
    if obj.get("record") != record_format(len(channels)):
        raise _fail(where, f"`record` must be {record_format(len(channels))} for its {len(channels)} channels, "
                           f"not {obj.get('record')!r}")
    session = _text(obj, "session", where)
    if session is not None and not (0 < len(session) <= MAX_NAME and session.strip() == session):
        raise _fail(where, f"`session` must be a word of 1 to {MAX_NAME} characters, not {session!r}")
    recording = _text(obj, "recording", where)
    if recording is not None and not 0 < len(recording) <= MAX_NAME:
        raise _fail(where, f"`recording` must be text of 1 to {MAX_NAME} characters, not {recording!r}")
    return Header(channels, _rate(obj.get("sample_rate"), where), str(_text(obj, "counter", where, required=True)),
                  device=_text(obj, "device", where), layout=_text(obj, "layout", where),
                  reference=_electrode(obj, "reference", where), ground=_electrode(obj, "ground", where),
                  made_by=_text(obj, "made_by", where), session=session, recording=recording)


def checked(h: Header, where: object = "header") -> Header:
    """`h` after the rules a file must pass (what write() writes always reads back)."""
    return parse(to_json(h), where)


# ---- files --------------------------------------------------------------------------------------------------------

def _plain(f32: Path | str) -> Path:
    p = Path(f32)
    return p.with_name(p.name[:-3]) if p.name.endswith((".f32.xz", ".f32.gz")) else p


def header_path(f32: Path | str) -> Path:
    """<stamp>.header.json beside <stamp>.f32 (also given as <stamp>.f32.xz or .f32.gz: the header is never packed)."""
    return _plain(f32).with_suffix(SUFFIX)


def write(f32: Path | str, header: Header) -> Path:
    """Write the header of a file set: under a temporary name, then renamed. Never replaces one: a header already
    there that says something else is a FileExistsError (the same one is left as it is)."""
    dst = header_path(f32)
    header = checked(header, dst)
    if dst.exists():
        if read_file(dst) == header:
            return dst
        raise FileExistsError(f"{dst} is already there and says something else: a header is never changed")
    tmp = dst.with_name(f".{dst.name}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(to_json(header), ensure_ascii=False) + "\n")
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, dst)
    return dst


def read_file(path: Path | str) -> Header:
    """A <stamp>.header.json; HeaderError (naming it) when it cannot be read or breaks a rule."""
    path = Path(path)
    try:
        obj = json.loads(path.read_bytes().decode("utf-8"))
    except OSError as e:
        raise HeaderError(f"{path}: the recording header cannot be read: {e}") from e
    except ValueError as e:  # not UTF-8, or not JSON
        raise _fail(path, f"not JSON ({e})") from e
    return parse(obj, path)


def from_log(log: Path | str) -> Header | None:
    """A DIY file set from before the header: its .log's line `format .f32 records <I<n>f: board sequence number,
    then <names> in volts; <fs> Hz` (Ch1..Chn when it does not hold n different names). None without that line."""
    log = Path(log)
    try:
        with open(log, "rb") as f:
            text = f.read(LOG_BYTES).decode("utf-8", "replace")
    except OSError:
        return None
    m = _LOG_FORMAT.search(text)
    if not m:
        return None
    n, fs = int(m.group(1)), float(m.group(2))
    if not 1 <= n <= MAX_CHANNELS or not fs > 0:
        raise HeaderError(f"{log}: its format line says {n} channels at {m.group(2)} Hz: not a recording this reads")
    named = _LOG_NAMES.search(m.group(0))
    names = tuple(named.group(1).split()) if named else ()
    if len(names) != n or len(set(names)) != n or any(len(x) > MAX_NAME for x in names):
        names = tuple(f"Ch{i}" for i in range(1, n + 1))
    return Header(tuple(Channel(x, site_of(x)) for x in names), int(fs) if fs == int(fs) else fs, SEQUENCE_NUMBER,
                  device=DIY_BOARD, source="log")


_DEFAULT = Header(brainbit().channels, BRAINBIT_FS, PACKET_NUMBER, device=BRAINBIT, layout=BRAINBIT,
                  reference=Electrode("Ref", "forehead", "Fpz"), source="default")
_cache: dict[str, tuple[tuple, Header]] = {}


def _stat(p: Path) -> tuple[int, int] | None:
    try:
        st = p.stat()
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


def read(f32: Path | str) -> Header:
    """What <stamp>.f32 holds (give the plain or the packed name; the .f32 itself is not opened): its
    <stamp>.header.json; without one, its .log's format line; without that, the BrainBit's O1 O2 T3 T4, 250 Hz, `<I4f`.
    A header that is there but damaged is a HeaderError, never a guess."""
    plain = _plain(f32)
    hp, lp = plain.with_suffix(SUFFIX), plain.with_suffix(".log")
    hs = _stat(hp)
    ls = None if hs is not None else _stat(lp)
    key = (hs, None if ls is None else (ls[0], ls[1]) if ls[1] <= LOG_BYTES else LOG_BYTES)
    hit = _cache.get(str(plain))
    if hit is not None and hit[0] == key:
        return hit[1]
    h = read_file(hp) if hs is not None else (from_log(lp) or _DEFAULT)
    _cache[str(plain)] = (key, h)
    return h


# ---- channels by name ---------------------------------------------------------------------------------------------

def _find(channels: Sequence[Channel], want: str) -> int | None:
    for i, c in enumerate(channels):
        if c.name == want:
            return i
    site = (site_of(want) or want).lower()
    for i, c in enumerate(channels):
        if c.site is not None and (site_of(c.site) or c.site).lower() == site:
            return i
    return None


def pick(header: Header, wanted: Sequence[str], who: str = "this feature") -> list[int]:
    """Where in the record the `wanted` channels are, in the order asked: by exact name first, else by 10-10 site
    (T7 stands for T3, T8 for T4, P7 for T5, P8 for T6, any letter case). MissingChannels when one is not there:
    `<who> needs O1 O2 T3 T4; this recording (DIY board: Ch1 ... Ch8) has no O2, T3, T4`."""
    found = [_find(header.channels, w) for w in wanted]
    missing = tuple(w for w, i in zip(wanted, found) if i is None)
    if missing:
        raise MissingChannels(f"{who} needs {' '.join(wanted)}; this recording ({header.describe()}) has no "
                              f"{', '.join(missing)}", missing)
    return [i for i in found if i is not None]


def pick_names(names: Sequence[str], wanted: Sequence[str], who: str = "this feature",
               device: str | None = None) -> list[int]:
    """pick() for bare channel names (a BDF's signal labels): each name's site is the 10-10 site it spells."""
    return pick(Header(tuple(Channel(n, site_of(n)) for n in names), BRAINBIT_FS, "", device=device), wanted, who)
