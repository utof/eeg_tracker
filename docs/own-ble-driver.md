# Our own headband connection (BrainBit Black, no BrainBit SDK)

A small Bluetooth driver of our own for the laptop (Python + bleak 3.1.0), and a recorder built on it, so night
recordings no longer depend on BrainBit's NeuroSDK2. On Linux the SDK unpairs every Bluetooth device when it
scans (DECISIONS 84), crashes when the headband drops out of range, cannot measure contact while streaming, and
needs a whole new process after every drop (DECISIONS 17). The driver does none of that. The phone app has the
same driver in Dart behind a switch (the last section, "On the phone"); BrainBit's SDK stays its default.

**Status (2026-11-19): built and tested on a fake headband only, on the laptop and on the phone.** Nobody has
connected it to the real BrainBit yet. Both recorders still use the SDK by default until the probe has passed.

## The files

| File | What it does |
|---|---|
| `scripts/brainbit_ble.py` | The driver: finds the headband (known address first, a name scan only without one), connects, reads device information and battery, starts the signal, decodes packets into samples (packet number, O1 O2 T3 T4 in volts), reconnects by itself after a drop |
| `scripts/record_ble.py` | The recorder on the driver: the same files and the same pages as `record_night.py`, but one process all night |
| `scripts/recorder_hub.py` | Files and live pages, shared by both recorders (moved out of `record_night.py`, unchanged in behaviour) |
| `scripts/ble_probe.py` | The probe for the real headband (below) |
| `tests/fake_bleak/` | A fake headband for tests and demos: speaks the protocol as described here, with drops and lost packets on request |

## What it does differently from the SDK recorder

- **No restarts.** A Bluetooth drop is handled inside the process: it reconnects to the same address, waiting 1,
  2, 5, 10, 20, then 30 s between tries. The pages stay up and show "reconnecting". The night stays in one set of
  files; the missing time shows in the `.idx` arrival times, so `to_bdf.py` marks it `BAD_gap` as before.
- **No unpairing.** It only scans, connects to and disconnects from the headband, and reads, writes and listens
  to it. It never calls BlueZ `RemoveDevice` or bleak's `unpair()` (a test checks the code for it).
- **Contact without a restart.** "Re-check contact" switches to resistance for 6 s and back to the signal. With
  `--signal-resist` (command 5, if the probe shows it works) contact is measured all night alongside the signal.
- **Lost packets are counted.** The headband numbers its samples; a jump is logged as "lost N samples in M gaps".
- **A stall** (no signal for 5 s) gets the start command again; after 10 s it counts as a drop and reconnects.
- Same files (`docs/data-format.md`): `.f32`, `.idx`, `.log` (the same lines, plus the driver, the assumed channel
  order and gain, and "reconnected after N s"), `.markers.jsonl`. Sleep reports, the morning check-in, `to_bdf.py`
  and the LSL bridge work unchanged. `/state` gained `contact_t` (when contact was last measured), which the
  morning page uses to know the in-process check is done.

## What is verified and what is not

Verified means checked on the owner's headband through BrainBit's SDK, or read in a primary source. Everything else
is marked **TO VERIFY** in `scripts/brainbit_ble.py`.

| Fact | Source | State |
|---|---|---|
| Name "BB Black", 250 Hz, 8 samples per batch, packet number = sample count (passed 2.6 million) | our SDK recordings | verified |
| Service `7e400001-b534-f393-68a9-e50e24dcca9?`; characteristics …02 status, …03 command, …04 signal | Neiry's MIT `web_sdk_neiry` 1.1.5 | read in the source; last digit (7 or 9) TO VERIFY (found by pattern, so either works) |
| Commands: 1 power down, 2 stop, 3 signal, 4 resistance | the same package | read in the source; not yet sent to our headband |
| Command 5 = signal + resistance | NeuroSDK2's header lists mode 5 "SignalResist" | TO VERIFY |
| Status bytes: battery, command error, state | the same package | TO VERIFY |
| Signal packet: 4-byte counter, then 8 x (marker byte + 4 x 24-bit) = 108 bytes | package framing + one hobby script | TO VERIFY (byte order, sign) |
| Channel order on the wire: O2 T3 T4 O1 | one hobby script for the Black (a Headband script says T3 T4 O1 O2) | TO VERIFY |
| Volts per count: 2.4 V / (gain 6 x 2^23) = 0.0477 µV | gain 6 matches the vendor's ±0.4 V range; one script assumed gain 12 | TO VERIFY |
| Resistance on …05: counter + 4 x uint32 ohms, same order | hobby scripts | TO VERIFY |
| Pairing | the SDK said "PairingRequired: False" for our headband; the vendor says the Black needs pairing once per computer | TO VERIFY |

Constants come from the MIT package and our own observations only; no code was copied. BrainBit's binaries were
never decompiled (DECISIONS 68).

## The probe (about 15 minutes with setup)

Stop the recorder first: the headband keeps one Bluetooth connection.

```bash
uv run --no-project --python 3.12 --with bleak==3.1.0 python scripts/ble_probe.py
```

1. It connects (the address comes from the recordings' logs) and saves the full list of services and
   characteristics with every readable value.
2. "Put the headband on … press Enter." Then it speaks each step (`--no-voice` to only print them):
   30 s sitting still; eyes **closed** 20 s, eyes **open** 20 s (alpha should rise on the two back electrodes);
   then lift each electrode off the skin for 4 s when asked: left back, right back, left temple, right temple
   (this names each channel's slot).
3. Without your help: stop (2), resistance (4) with the same four lifts, signal + resistance (5), and signal again
   (3) to see whether the signal comes back after resistance.
4. Results in `_local/probe/<time>/`: `summary.txt` first (yes / NO for each check, the suggested channel orders),
   `raw.txt` (every packet as hex), `decoded.csv`, `gatt.txt`, `summary.json`.

Options: `--no-head` (headband lying on the desk: protocol steps only, about 1.5 min), `--pair` (if it asks for
pairing: hold the button 4 s until it blinks fast first), `--sdk-ref _local/recordings/<an SDK recording>.f32`
(compares the noise level: a ratio near 2 or 0.5 means the gain is wrong).

**If anything fails:** `summary.txt` says where. Most fixes are flags, no code change: `--order`, `--resist-order`
and `--gain` on both the probe and the recorder. Then change the defaults in `scripts/brainbit_ble.py`.

## Recording with it

After the probe passes:

```bash
DRIVER=ble scripts/record_night.sh                     # same pages on port 8765
DRIVER=ble scripts/record_night.sh --signal-resist     # if command 5 worked: contact all night
```

Without a headband: `PYTHONPATH=tests/fake_bleak python3 scripts/record_ble.py --port 8799 --out /tmp/rec`
(the fake can drop out: `FAKE_BLE_DROP_AFTER=20 FAKE_BLE_DROP_FOR=5`).

Next after a good probe: one night with `DRIVER=ble`, a check against the SDK on the same session (BlueZ may let
both listen at once; otherwise two back-to-back recordings), then making the driver the default.

## On the phone (the app, behind a switch)

The app has the same driver in Dart (DECISIONS 210-219). BrainBit's SDK stays the default; the setting
"Use our own connection (test)" is off until the probe has passed on the real headband.

| File (`app/lib/`) | What it does |
|---|---|
| `headband/own/protocol.dart` | Every constant and byte layout, in one place, each unverified one marked TO VERIFY: the probe's result changes this file only |
| `headband/own/driver.dart` | The driver: a port of `scripts/brainbit_ble.py`, method for method |
| `headband/own/transport.dart`, `universal_transport.dart` | The little the driver needs from Bluetooth, and the one file that uses the plugin (`universal_ble` 3.3.0, BSD-3) |
| `headband/own/own_headband.dart` | The driver behind the app's one headband interface, so the night recorder and every session use it as they use the SDK |
| `headband/finder.dart` | The switch: BrainBit's SDK, or our own connection |
| `headband/own/probe.dart`, `controller.dart`, `ui/own_ble_*.dart` | The probe and the "Headband connection" page |
| `headband/own/settings.dart` | `files/own-ble/settings.json`: the switch, the headband last reached, the channel order the probe found |

**Same parser, checked.** `app/test/fixtures/own_ble_vectors.json` is made by the Python parser from the Python fake
headband's packets and hand-built edge cases (`python3 app/test/fixtures/make_own_ble_vectors.py`). The Dart
parser must give exactly the same samples, counts, ohms and status (`app/test/own_ble_protocol_test.dart`), and
`analysis/tests/test_own_ble_vectors.py` fails when the file no longer matches the Python side.

**What it does differently from the SDK in the app**

- **A drop is mended inside the connection**: it reconnects to the same address after 1, 2, 5, 10, 20, 30 s and the
  night stays in one file set (the hole shows in the `.idx` times). Only when the headband has been away for 30 s
  does the app's usual reconnect take over (a new file set, as with the SDK), still without a scan.
- **No process restarts**: no call can block for ever, so the "Bluetooth stuck, restarting" path is never needed.
- **Lost packets, drops and reconnects are written into the night's `.log`**, with the driver, the assumed channel
  order and the packet size the phone got.
- **Contact**: checked once at the start as before; with "Measure contact all night" (only offered when the probe
  saw command 5 work) a `contact ohms` line every minute.
- **It can never unpair anything**: the code has no such call, and a test checks that.

**The probe on the phone** (night screen, Headband, "Headband connection", "Run the probe"): the same steps as
above with written instructions and tones, about 5 minutes with the headband on (or 1½ on the desk: connection
steps only, not a full pass). It ends with a plain verdict and one sentence per check. The result is kept in the
app (`files/own-ble/probe/<time>/`: `summary.txt` first) and leaves with Export data; `scripts/import_phone.py`
puts it in `_local/phone/own-ble/probe/<time>/`. If the lifts find another channel order than assumed, the app
uses the one it found. If the headband asks for pairing, the page says how and offers "Pair first".

**Only the phone and the real headband can settle**: everything marked TO VERIFY above, and for Android: whether
the phone reaches the headband's address without a scan first, whether it gets packets of 111 bytes or more,
whether pairing is needed, how drops behave with the screen off on HyperOS, and what a night costs the battery.
The first thing to look at in the first night's `.log`: the `driver own Bluetooth LE ...` line (the recorder's
service used our connection) and the `mtu` it names.

**Tests without a headband**: a fake headband in Dart (`app/test/own_ble/fake_headband.dart`: drops, lost packets,
a stalled stream, resistance, command 5, pairing) runs the driver, a whole night through the recorder, a meditation,
the shared link of the dream catcher and the sound sessions, and the probe (`app/test/own_ble_*_test.dart`).
