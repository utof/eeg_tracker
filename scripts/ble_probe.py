"""The probe of our own Bluetooth driver on the owner's BrainBit Black: about 4 minutes of steps, 15 with setup.

It checks on the real headband what docs/own-ble-driver.md lists as TO VERIFY: the service UUID, the
characteristics, the status bytes, the signal packet (size, counter, 250 Hz, scale), the channel order (eyes
closed: alpha shows on the two back electrodes; lifting one electrode at a time names each slot), command 2 (stop),
4 (resistance, and its order), 5 (signal + resistance together) and whether the signal starts again after
resistance (it did not with BrainBit's SDK, DECISIONS 17).

Everything goes to _local/probe/<stamp>/: gatt.txt (services, characteristics and properties, every readable
value), raw.txt (every notification as one hex line: seconds since start, phase, characteristic, bytes, hex),
decoded.csv (signal per sample in wire order: raw counts), probe.log, summary.txt and summary.json.

usage (stop the recorder first: the headband keeps one connection):
  uv run --no-project --python 3.12 --with bleak==3.1.0 python scripts/ble_probe.py
  options: --address AA:BB:..  (default: from the recordings' logs; scans by name only without one)
           --no-head           headband not worn: protocol steps only, no prompts (about 1.5 min)
           --pair              pair first (hold the button 4 s until it blinks fast); never unpairs anything
           --no-voice          print the prompts only (by default they are also spoken with spd-say)
           --sdk-ref _local/recordings/<stamp>.f32   compare the noise level with an SDK recording (rough scale check)
No headband: PYTHONPATH=tests/fake_bleak python3 scripts/ble_probe.py --no-head --out /tmp/probe --recorder-port 0
Standard library + bleak only.
"""
import argparse, asyncio, cmath, collections, json, math, os, shutil, struct, subprocess, sys, time, urllib.request
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import brainbit_ble as bb  # noqa: E402
import packed  # noqa: E402
import recording  # noqa: E402

LIFT_S, REST_S = 4.0, 3.0
WHERE = {"O1": "LEFT BACK", "O2": "RIGHT BACK", "T3": "LEFT TEMPLE", "T4": "RIGHT TEMPLE"}


def say(text: str, voice: bool) -> None:
    """Print and, with prompts on, speak (eyes are closed for some steps)."""
    print(f"\n>>> {text}", flush=True)
    if voice and shutil.which("spd-say"):
        subprocess.Popen(["spd-say", "-w", text], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif voice:
        print("\a", end="", flush=True)


class ProbeDriver(bb.BrainBitBLE):
    """The driver, plus a full GATT dump and a raw logger on every other notifying characteristic."""

    def __init__(self, *a, raw_out=None, **kw) -> None:  # noqa: ANN001, ANN002, ANN003
        super().__init__(*a, **kw)
        self.gatt: list[str] = []; self.raw_out = raw_out

    async def _setup(self, client, address: str) -> bb.DeviceInfo:  # noqa: ANN001
        self.gatt = await dump_gatt(client)
        info = await super()._setup(client, address)
        mine = {bb.char_uuid(self.service, n) for n in (bb.STATUS_CHAR, bb.SIGNAL_CHAR, bb.RESIST_CHAR)}
        for s in client.services:
            for c in s.characteristics:
                u = str(c.uuid).lower()
                if u in mine or not {"notify", "indicate"} & set(c.properties):
                    continue
                try:
                    await self._ble(client.start_notify(c, lambda ch, d: self.raw_out(str(ch.uuid).lower(), bytes(d),
                                                                                         time.time())), f"subscribe {u}")
                    self.gatt.append(f"also subscribed to {u}")
                except bb.HeadbandError as e:
                    self.gatt.append(f"could not subscribe to {u}: {e}")
        return info


async def dump_gatt(client) -> list[str]:  # noqa: ANN001
    lines = [f"bleak mtu_size {getattr(client, 'mtu_size', '?')} (always 23 on BlueZ; see each write size + 3)"]
    for s in client.services:
        lines.append(f"service {s.uuid} {getattr(s, 'description', '')}")
        for c in s.characteristics:
            line = (f"  char {c.uuid} [{','.join(c.properties)}] handle {getattr(c, 'handle', '?')} "
                    f"write size {getattr(c, 'max_write_without_response_size', '?')}")
            if "read" in c.properties:
                try:
                    v = bytes(await asyncio.wait_for(client.read_gatt_char(c), 5))
                    text = v.decode("utf-8", "replace") if all(32 <= b < 127 for b in v) else ""
                    line += f" = {v.hex()} {text!r}" if text else f" = {v.hex()}"
                except Exception as e:  # noqa: BLE001 (a read that needs pairing is a finding, not a failure)
                    line += f" read failed: {type(e).__name__}: {e}"
            lines.append(line)
            for d in getattr(c, "descriptors", []):
                lines.append(f"    descriptor {d.uuid} handle {getattr(d, 'handle', '?')}")
    return lines


# ---- analysis (pure Python) ---------------------------------------------------------------------------------
def stats(values: list[float]) -> dict:
    n = len(values)
    if n < 2:
        return dict(n=n)
    m = sum(values) / n
    dev = sorted(v - m for v in values)
    diff = [values[i + 1] - values[i] for i in range(n - 1)]
    sd = math.sqrt(sum(d * d for d in dev) / (n - 1))
    dsd = math.sqrt(sum(d * d for d in diff) / len(diff))
    return dict(n=n, mean=m, sd=sd, p1=dev[int(0.01 * (n - 1))], p99=dev[int(0.99 * (n - 1))], diff_rms=dsd)


def band_power(x: list[float], lo: float = 8.0, hi: float = 13.0, fs: int = bb.FS) -> float:
    """Mean power in lo-hi Hz over 2 s Hann windows with half overlap (x in µV, result in µV²)."""
    w = 2 * fs
    if len(x) < w:
        return float("nan")
    hann = [0.5 - 0.5 * math.cos(2 * math.pi * k / (w - 1)) for k in range(w)]
    freqs = [lo + 0.5 * j for j in range(int((hi - lo) / 0.5) + 1)]
    tw = [[cmath.exp(-2j * math.pi * f * k / fs) for k in range(w)] for f in freqs]
    out = []
    for s in range(0, len(x) - w + 1, w // 2):
        seg = x[s:s + w]; m = sum(seg) / w
        seg = [(v - m) * h for v, h in zip(seg, hann)]
        out.append(sum(abs(sum(a * b for a, b in zip(seg, t))) ** 2 for t in tw) / (w * w))
    return sum(out) / len(out)


class Probe:
    def __init__(self, folder: Path, layout: bb.Layout, voice: bool) -> None:
        self.folder, self.layout, self.voice = folder, layout, voice
        self.t0 = time.time(); self.phase = "connect"
        self.drv: bb.BrainBitBLE | None = None; self.time_scale = 1.0
        self.phases: list[tuple[str, float, float]] = []
        self.signal: list[tuple[float, str, bb.Packet]] = []  # (time, phase, packet)
        self.resist: list[tuple[float, str, bytes]] = []
        self.other: collections.Counter = collections.Counter()  # (phase, uuid, length) of every notification
        self.status: list[tuple[str, bb.Status]] = []
        self.raw = open(folder / "raw.txt", "w"); self.logf = open(folder / "probe.log", "a")

    def log(self, msg: str) -> None:
        line = f"{datetime.now().isoformat(timespec='milliseconds')} {msg}"
        print(line, flush=True); self.logf.write(line + "\n"); self.logf.flush()

    def on_raw(self, uuid: str, data: bytes, now: float) -> None:
        self.raw.write(f"{now - self.t0:.3f} {self.phase} {uuid[:8]} {len(data)} {data.hex()}\n")
        self.other[(self.phase, uuid[:8], len(data))] += 1
        if uuid[:8] == "7e400005":
            self.resist.append((now, self.phase, data))

    def on_samples(self, pkt: bb.Packet, now: float, _gap: int) -> None:
        self.signal.append((now, self.phase, pkt))

    async def step(self, name: str, seconds: float, text: str | None = None) -> None:
        """One timed step; a dropped link ends the probe with what it has (HeadbandLost)."""
        self.phase = name
        if text:
            say(text, self.voice)
        t = time.time()
        lost = await bb._wait(self.drv._lost, seconds * self.time_scale) if self.drv and self.drv._lost else False
        self.phases.append((name, t, time.time()))
        if lost:
            raise bb.HeadbandLost(f"link dropped ({self.drv._lost_reason})")

    def packets(self, name: str, skip: float = 0.0) -> list[bb.Packet]:
        spans = [(a + skip, b) for n, a, b in self.phases if n == name]
        return [p for t, _ph, p in self.signal if any(a <= t < b for a, b in spans)]

    def slot_series(self, name: str, skip: float = 0.5) -> list[list[float]]:
        """µV per wire slot (scale per the layout's gain) for one phase."""
        scale = self.layout.volts_per_count * 1e6
        out: list[list[float]] = [[], [], [], []]
        for p in self.packets(name, skip):
            for c in p.counts:
                for j in range(4):
                    out[j].append(c[j] * scale)
        return out

    def signal_check(self, name: str) -> dict:
        pk = self.packets(name, 0.0)
        spans = [(a, b) for n, a, b in self.phases if n == name]
        dur = sum(b - a for a, b in spans) or float("nan")
        steps = collections.Counter((pk[i + 1].counter - pk[i].counter) % bb.COUNTER_MOD for i in range(len(pk) - 1))
        lost = sum(max(0, bb.counter_gap((pk[i].counter + len(pk[i].samples)) % bb.COUNTER_MOD, pk[i + 1].counter))
                   for i in range(len(pk) - 1))
        n_samples = sum(len(p.samples) for p in pk)
        series = self.slot_series(name)
        return dict(packets=len(pk), samples=n_samples, seconds=round(dur, 2),
                    samples_per_s=round(n_samples / dur, 1) if pk else 0, packets_per_s=round(len(pk) / dur, 2),
                    sizes=dict(collections.Counter(4 + 13 * len(p.samples) for p in pk)),
                    counter_steps=dict(steps.most_common(5)), lost_samples=lost,
                    first_counters=[p.counter for p in pk[:3]],
                    markers=dict(collections.Counter(m for p in pk for m in p.markers).most_common(5)),
                    slots_uv={self.layout.order[j]: {k: round(v, 2) for k, v in stats(series[j]).items()}
                              for j in range(4)})

    def lift_slots(self, prefix: str, rest: str, value) -> dict:  # noqa: ANN001
        """For each lift step, the wire slot whose measure (value(phase) -> 4 numbers) rose most over rest."""
        base = value(rest)
        out = {}
        for name in bb.NAMES:
            v = value(f"{prefix}{name}")
            if not v or not base or any(b is None for b in base) or any(x is None for x in v):
                continue
            ratios = [x / b if b else float("inf") for x, b in zip(v, base)]
            j = max(range(4), key=lambda i: ratios[i])
            out[name] = dict(slot=j, ratio=round(ratios[j], 2), ratios=[round(r, 2) for r in ratios])
        return out

    def resist_values(self, name: str, skip: float = 1.0) -> list[float] | None:
        spans = [(a + skip, b) for n, a, b in self.phases if n == name]
        rows = [struct.unpack_from("<4I", d, 4) for t, _ph, d in self.resist
                if len(d) >= 20 and any(a <= t < b for a, b in spans)]
        if not rows:
            return None
        return [sorted(r[j] for r in rows)[len(rows) // 2] for j in range(4)]

    def counts_in(self, name: str, uuid8: str) -> int:
        return sum(v for (ph, u, _n), v in self.other.items() if ph == name and u == uuid8)


def order_from(lifts: dict) -> str | None:
    """'O2,T3,T4,O1' if the four lifts named four different slots."""
    if len(lifts) != 4 or len({v["slot"] for v in lifts.values()}) != 4:
        return None
    slots = {v["slot"]: name for name, v in lifts.items()}
    return ",".join(slots[j] for j in range(4))


def sdk_reference(path: Path, seconds: float = 60.0) -> dict:
    """Noise level (RMS of sample-to-sample steps, µV) per channel in the middle of an SDK recording: its O1 O2 T3
    T4, found by name in the recording's header (scripts/recording.py; a file from before the header is the
    BrainBit's `<I4f`)."""
    head = recording.read(path)
    where = recording.pick(head, bb.NAMES, "the scale check")
    rec = head.struct
    data = packed.read_bytes(path); n = len(data) // rec.size  # plain, or packed after a day (.f32.xz)
    k = int(seconds * head.sample_rate); start = max(0, n // 2 - k // 2)
    cols: list[list[float]] = [[], [], [], []]
    for i in range(start, min(n, start + k)):
        r = rec.unpack_from(data, rec.size * i)
        for j, c in enumerate(where):
            cols[j].append(r[1 + c] * 1e6)
    return {name: {k2: round(v, 2) for k2, v in stats(cols[j]).items()} for j, name in enumerate(bb.NAMES)}


async def run_probe(a: argparse.Namespace) -> int:
    folder = Path(a.out) / datetime.now().strftime("%Y-%m-%d-%H%M%S"); folder.mkdir(parents=True, exist_ok=True)
    layout = bb.Layout(bb.parse_order(a.order), bb.parse_order(a.resist_order), a.gain)
    voice = not (a.no_head or a.no_voice)
    pr = Probe(folder, layout, voice)
    address = a.address or os.environ.get("BRAINBIT_ADDRESS") or bb.known_address(Path(a.recordings))
    drv = ProbeDriver(address, layout=layout, pair=a.pair, log=pr.log, raw_out=pr.on_raw, scan_s=a.scan_s,
                      stall_s=1e9)  # the probe watches stalls itself; the driver must not resend commands
    drv.on_raw, drv.on_samples = pr.on_raw, pr.on_samples
    pr.drv, pr.time_scale = drv, a.time_scale
    drv.on_status = lambda st: pr.status.append((pr.phase, st))
    pr.log(f"probe folder {folder}; address {address or 'unknown: scanning by name'}; layout {layout.describe()}")
    summary: dict = dict(started=datetime.now().isoformat(timespec="seconds"), address=address, layout=layout.describe(),
                         head=not a.no_head, steps={})
    try:
        info = await drv.connect()
        (folder / "gatt.txt").write_text("\n".join(drv.gatt) + "\n")
        summary.update(address=info.address, name=info.name, service=info.service, device=info.info, mtu=info.mtu,
                       status_at_connect=info.status.text() if info.status else None)
        pr.log(f"connected {info.name} {info.address}; service {info.service}; {info.info}; "
               f"status {info.status.text() if info.status else '?'}")
        if not a.no_head:
            say("Put the headband on, electrodes on the skin, sit still and relaxed. Press Enter when ready.", False)
            await asyncio.to_thread(input)
        await drv.command(bb.CMD_SIGNAL)
        await pr.step("signal", 30, None if a.no_head else "Signal for 30 seconds: sit still, eyes open, relax.")
        if not a.no_head:
            await pr.step("eyes_closed", 20, "Close your eyes now, for 20 seconds. Relax.")
            await pr.step("eyes_open", 20, "Open your eyes. Look at one spot for 20 seconds.")
            for name in bb.NAMES:
                await pr.step("rest", REST_S, f"Next: {WHERE[name]} electrode, {name}.")
                await pr.step(f"lift_{name}", LIFT_S, f"Lift the {WHERE[name]} electrode off the skin now.")
            await pr.step("rest", REST_S, "Let it go. Thank you.")
        await drv.command(bb.CMD_IDLE)
        await pr.step("idle_after_signal", 3, None)
        await drv.command(bb.CMD_RESIST)
        await pr.step("resist", 12, None if a.no_head else "Contact check for 12 seconds: sit still.")
        if not a.no_head:
            for name in bb.NAMES:
                await pr.step("resist_rest", REST_S, f"Next: {WHERE[name]} electrode, {name}.")
                await pr.step(f"resist_lift_{name}", LIFT_S, f"Lift the {WHERE[name]} electrode off the skin now.")
            await pr.step("resist_rest", REST_S, "Let it go.")
        await drv.command(bb.CMD_IDLE)
        await pr.step("idle_after_resist", 2, None)
        await drv.command(bb.CMD_SIGNAL_RESIST)
        await pr.step("signal_resist", 20, None if a.no_head else "Signal and contact together, 20 seconds: sit still.")
        await drv.command(bb.CMD_IDLE)
        await pr.step("idle_after_signal_resist", 2, None)
        await drv.command(bb.CMD_SIGNAL)
        await pr.step("signal_again", 8, None)
        try:
            summary["status_at_end"] = (await drv.read_status()).text()
        except bb.HeadbandError as e:
            summary["status_at_end"] = f"read failed: {e}"
        rc = 0
    except bb.HeadbandError as e:
        pr.log(f"STOPPED in step {pr.phase}: {e}")
        summary["error"] = f"{pr.phase}: {e}"; rc = 1
        if drv.gatt:
            (folder / "gatt.txt").write_text("\n".join(drv.gatt) + "\n")
    finally:
        await drv.close(idle=True)
    say("Done. You can take the headband off.", voice and rc == 0)
    write_results(pr, summary, a)
    pr.raw.close(); pr.logf.close()
    print(f"\nEverything is in {folder}/ (summary.txt first).")
    return rc


def write_results(pr: Probe, summary: dict, a: argparse.Namespace) -> None:
    st = summary["steps"]
    for name in ("signal", "eyes_closed", "eyes_open", "signal_resist", "signal_again"):
        if any(n == name for n, _a, _b in pr.phases):
            st[name] = pr.signal_check(name)
            st[name]["resist_packets"] = pr.counts_in(name, "7e400005")
    for name in ("idle_after_signal", "idle_after_resist", "idle_after_signal_resist"):
        if any(n == name for n, _a, _b in pr.phases):
            st[name] = dict(signal_packets_after_1s=len(pr.packets(name, 1.0)), resist_packets=pr.counts_in(name, "7e400005"))
    if any(n == "resist" for n, _a, _b in pr.phases):
        sizes = collections.Counter(len(d) for _t, ph, d in pr.resist if ph == "resist")
        med = pr.resist_values("resist")
        st["resist"] = dict(packets=sum(sizes.values()), sizes=dict(sizes), signal_packets=len(pr.packets("resist", 1.0)),
                            median_ohms_wire_order=med,
                            decoded=({n: v for n, v in zip(pr.layout.resist_order, med)} if med else None))
    status_by_phase = collections.defaultdict(set)
    for ph, s in pr.status:
        status_by_phase[ph].add(s.raw.hex())
    summary["status_raw_by_step"] = {k: sorted(v) for k, v in status_by_phase.items()}
    summary["other_notifications"] = [dict(step=ph, char=u, bytes=n, count=c) for (ph, u, n), c in sorted(pr.other.items())]
    verdict = {}
    if "signal" in st:
        s = st["signal"]
        verdict["rate_250"] = 235 <= s["samples_per_s"] <= 265
        verdict["packet_108_bytes"] = list(s["sizes"]) == [108]
        verdict["counter_counts_samples"] = list(s["counter_steps"])[:1] == [8]
        verdict["no_lost_samples"] = s["lost_samples"] == 0
    if "eyes_closed" in st and "eyes_open" in st:
        ec, eo = pr.slot_series("eyes_closed"), pr.slot_series("eyes_open")
        rise = [band_power(ec[j]) / band_power(eo[j]) if band_power(eo[j]) else float("nan") for j in range(4)]
        top = sorted(range(4), key=lambda j: -rise[j] if rise[j] == rise[j] else 0)[:2]
        summary["alpha_rise_by_wire_slot"] = {f"slot{j} ({pr.layout.order[j]})": round(r, 2) for j, r in enumerate(rise)}
        verdict["alpha_on_assumed_back_slots"] = {pr.layout.order[j] for j in top} == {"O1", "O2"}
    if not a.no_head:
        lifts = pr.lift_slots("lift_", "signal", lambda n: [stats(x).get("diff_rms") for x in pr.slot_series(n)])
        summary["signal_lifts"] = lifts
        found = order_from(lifts)
        summary["suggested_order"] = found
        verdict["order_matches_default"] = found == ",".join(pr.layout.order) if found else None
        rl = pr.lift_slots("resist_lift_", "resist", pr.resist_values)
        summary["resist_lifts"] = rl
        rfound = order_from(rl)
        summary["suggested_resist_order"] = rfound
        verdict["resist_order_matches_default"] = rfound == ",".join(pr.layout.resist_order) if rfound else None
    if "idle_after_signal" in st:
        verdict["command2_stops_signal"] = st["idle_after_signal"]["signal_packets_after_1s"] == 0
    if "resist" in st:
        verdict["command4_gives_resistance"] = st["resist"]["packets"] > 0
    if "signal_resist" in st:
        sr = st["signal_resist"]
        verdict["command5_signal"] = sr["samples_per_s"] > 200
        verdict["command5_resistance"] = sr["resist_packets"] > 0
    if "signal_again" in st:
        verdict["signal_restarts_after_resistance"] = st["signal_again"]["samples_per_s"] > 200
    summary["verdict"] = verdict
    if a.sdk_ref:
        try:
            ref = sdk_reference(Path(a.sdk_ref))
            ours = st.get("signal", {}).get("slots_uv", {})
            summary["sdk_reference"] = dict(file=str(a.sdk_ref), sdk=ref, ratio_diff_rms={
                n: round(ours[n]["diff_rms"] / ref[n]["diff_rms"], 2) for n in bb.NAMES
                if n in ours and ours[n].get("diff_rms") and ref[n].get("diff_rms")})
        except (OSError, KeyError, ZeroDivisionError, struct.error, recording.RecordingError) as e:
            summary["sdk_reference"] = f"failed: {e}"
    (pr.folder / "summary.json").write_text(json.dumps(summary, indent=1, default=str) + "\n")
    with open(pr.folder / "decoded.csv", "w") as f:
        f.write("t,step,counter,k,marker," + ",".join(f"slot{j}_{pr.layout.order[j]}" for j in range(4)) + "\n")
        for t, ph, p in pr.signal:
            for k, (m, c) in enumerate(zip(p.markers, p.counts)):
                f.write(f"{t - pr.t0:.3f},{ph},{p.counter},{k},{m},{c[0]},{c[1]},{c[2]},{c[3]}\n")
    text = summary_text(summary)
    (pr.folder / "summary.txt").write_text(text)
    print("\n" + text)


def summary_text(s: dict) -> str:
    v = s.get("verdict", {})
    yes = lambda k: {True: "yes", False: "NO", None: "not settled"}[v[k]] if k in v else "not run"  # noqa: E731
    lines = [f"BrainBit Black probe {s['started']}  {s.get('name', '?')} {s.get('address')}",
             f"service {s.get('service')}  device {s.get('device')}  mtu {s.get('mtu')}",
             f"status at connect: {s.get('status_at_connect')}  at end: {s.get('status_at_end')}",
             f"assumed layout: {s['layout']}"]
    if s.get("error"):
        lines.append(f"STOPPED EARLY: {s['error']}")
    sig = s["steps"].get("signal")
    if sig:
        lines += [f"signal (command 3): {sig['samples_per_s']} samples/s, {sig['packets_per_s']} packets/s, sizes "
                  f"{sig['sizes']}, counter steps {sig['counter_steps']}, lost {sig['lost_samples']}, markers {sig['markers']}"]
        for name, x in sig["slots_uv"].items():
            if "sd" in x:
                lines.append(f"  slot {name}: DC {x['mean'] / 1e6:+.4f} V  sd {x['sd']:.1f} uV  p1..p99 {x['p1']:.0f}..{x['p99']:.0f} uV"
                             f"  step rms {x['diff_rms']:.2f} uV")
    lines += [
        f"250 Hz: {yes('rate_250')}   108-byte packets: {yes('packet_108_bytes')}   counter counts samples (+8): "
        f"{yes('counter_counts_samples')}   no lost samples: {yes('no_lost_samples')}",
        f"alpha rise by slot (eyes closed / open): {s.get('alpha_rise_by_wire_slot', 'not run')}  "
        f"-> back electrodes where assumed: {yes('alpha_on_assumed_back_slots')}",
        f"signal order from the lifts: {s.get('suggested_order') or 'not settled'}  (matches the default: {yes('order_matches_default')})",
        f"resistance order from the lifts: {s.get('suggested_resist_order') or 'not settled'}  "
        f"(matches the default: {yes('resist_order_matches_default')})",
        f"command 2 stops the signal: {yes('command2_stops_signal')}   command 4 gives resistance: "
        f"{yes('command4_gives_resistance')}  {s['steps'].get('resist', {}).get('decoded')}",
        f"command 5: signal {yes('command5_signal')}, resistance {yes('command5_resistance')}   "
        f"signal starts again after resistance: {yes('signal_restarts_after_resistance')}"]
    if isinstance(s.get("sdk_reference"), dict):
        lines.append(f"noise vs the SDK recording (ours / SDK, about 1 if the gain is right, 2 or 0.5 if not): "
                     f"{s['sdk_reference']['ratio_diff_rms']}")
    lines.append("other notifications: " + "; ".join(f"{o['step']} {o['char']} {o['bytes']} B x{o['count']}"
                                                     for o in s.get("other_notifications", [])[:40]))
    return "\n".join(lines) + "\n"


def recorder_running(port: int) -> bool:
    if not port:
        return False
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/state", timeout=1) as r:
            return json.loads(r.read()).get("age", 99) < 30
    except (OSError, ValueError):
        return False


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--address")
    ap.add_argument("--out", default="_local/probe")
    ap.add_argument("--recordings", default="_local/recordings", help="where to find the address in the logs")
    ap.add_argument("--no-head", action="store_true", help="headband not worn: protocol steps only, no prompts")
    ap.add_argument("--pair", action="store_true")
    ap.add_argument("--no-voice", action="store_true", help="print the prompts only (no speech, no bell)")
    ap.add_argument("--sdk-ref", help="an SDK .f32 of the same headband, worn, for a rough scale check")
    ap.add_argument("--order", default=",".join(bb.SIGNAL_ORDER))
    ap.add_argument("--resist-order", default=",".join(bb.RESIST_ORDER))
    ap.add_argument("--gain", type=int, default=bb.GAIN)
    ap.add_argument("--scan-s", type=float, default=30.0)
    ap.add_argument("--recorder-port", type=int, default=8765, help="refuse to run while a recorder streams here; 0 = skip")
    ap.add_argument("--time-scale", type=float, default=1.0, help=argparse.SUPPRESS)  # tests: shorter steps
    a = ap.parse_args()
    if recorder_running(a.recorder_port):
        raise SystemExit(f"a recorder is streaming on port {a.recorder_port}: stop it first (the headband keeps one "
                         "connection), then run the probe again")
    raise SystemExit(asyncio.run(run_probe(a)))


if __name__ == "__main__":
    main()
