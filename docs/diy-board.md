# The DIY ADS1299 board on the laptop and the phone

A host driver and recorder for the owner's self-built ADS1299 board (hardware, firmware and build guides in the
sibling repo [eeg_ads1299_lab](https://github.com/utof/eeg_ads1299_lab)), so the board records into the same files,
live pages and LSL bridge as the BrainBit the day it is assembled (DECISIONS rows 5 and 350-359, ROADMAP row 13), and
the phone app that records it over Wi-Fi (below, "On the phone"; DECISIONS rows 360-369).

**Status (2026-11-19): built and tested on a fake board only.** The board is not assembled yet. The frame format is
checked byte for byte against the firmware's own framing code; everything about the real board is marked
**TO VERIFY** below.

> **Safety.** This software never authorises connecting the board to a body, powering it, or changing any of its
> safety gates; those are the hardware's rules (eeg_ads1299_lab `docs/BREADBOARD_S3_BRINGUP.md`, section 1 and the
> gates in the firmware). The recorder only reads: it never writes a byte to the serial port and never sends a
> datagram. The bench firmware today has **no electrode mode**: it records only the chip's internal test signal
> (`T`) or its shorted inputs (`N`), so nothing it records is EEG, whatever the channel names say. An electrode mode
> is a separate firmware change the owner must ask for in eeg_ads1299_lab, after bring-up steps 1-10 pass.

## The protocol in one paragraph

The board's ESP32 wraps every ADS1299 conversion (250 a second) in one "E9" frame of 25 + 3 x channels bytes (37
for the 4-channel chip, 49 for the 8-channel one): the letters `E9`, version 1, channel count, mode flags (1 test
signal, 2 inputs shorted, 4 synthetic, 8 "the board has missed a conversion"), gain (24), rate, a 32-bit sequence
number (data-ready pulses since the board started), the board's microsecond clock, a running count of conversions
the board itself missed, the chip's own 24-bit status word (lead-off bits, unused while lead-off detection is off),
the channel values (signed 24-bit, big endian) and a CRC-16/CCITT-FALSE over everything before it. Volts =
counts x VREF / (gain x 2^23), with VREF = 4.5 V (the chip's internal reference; not in the frame, so `--vref`).
The frames go over USB serial at 460800 baud (the DevKit's UART socket, mixed with the firmware's text: banner,
prompts, `HALTED` lines) or, if built with Wi-Fi, one frame per UDP datagram to the laptop's port 9000. No
Bluetooth. Source: eeg_ads1299_lab `docs/PROTOCOL.md` and `firmware/esp32_ads1299_bench/portable_core.h`.

## The files

| File | What it does |
|---|---|
| `scripts/diy_board.py` | The driver: frame decoder (CRC, length, fields, status prefix), a stream decoder that finds frames among text and damage and keeps the firmware's text lines, the sequence tracker (gaps, repeats, late frames, restarts), the serial and UDP links. Standard library; pyserial only when a serial link opens |
| `scripts/record_diy.py` | The recorder on it, through `scripts/recorder_hub.py`: the same files and pages as the BrainBit recorders |
| `scripts/montages/diy-breadboard-4.json` | The default channel names: the breadboard's planned O1 O2 Fz Fp1, reference and bias on the earlobes |
| `tests/fake_diy/` | A fake board: a fake `serial` module and a UDP sender that speak the protocol, with corrupt frames, lost frames, board overruns, garbage, USB drops, restarts and a halt on request; `golden/` holds frames made by the firmware's own code |
| `analysis/tests/test_diy_board.py`, `tests/web/live-page.test.mjs` | The tests (below) |

## How to record from the board

1. Build and bring up the board with eeg_ads1299_lab's card (`docs/BREADBOARD_S3_BRINGUP.md`), all its safety rules
   and steps in order. Note in its step 4 whether opening the port restarted your DevKit.
2. Answer the board's prompts yourself in a serial terminal: `R` (after measuring AVDD and 3V3), `V` (after VCAP1),
   then `T` or `N`. Close the terminal (Ctrl+]). The recorder never types these: they are your confirmations of
   measurements, not commands a program may send.
3. Record (the launcher adds pyserial 3.5; the files go to `_local/recordings-diy/`):

   ```bash
   DRIVER=diy scripts/record_night.sh                         # the only /dev/ttyUSB* or /dev/ttyACM*
   DRIVER=diy scripts/record_night.sh --serial /dev/ttyUSB0   # or DIY_SERIAL=/dev/ttyUSB0
   DRIVER=diy scripts/record_night.sh --udp 9000              # Wi-Fi route (allow UDP 9000 in the firewall)
   DRIVER=diy scripts/record_night.sh --montage O1,O2,Fz,Fp1  # or a JSON file like scripts/montages/*.json
   ```

   The live check page is on port 8765 as usual; `scripts/lsl_bridge.py` works unchanged (its stream is still
   called "BrainBit", with the board's channel names and count). Start the bridge once the recorder has its first
   frame: the names are fixed then, and a bridge started earlier keeps the montage's count even if the board sends
   another (the 8-channel chip); restart the bridge after such a change.
4. If your DevKit restarts when the port opens (step 1), the serial route cannot work after the prompts: use the
   Wi-Fi route. A restarted board shows up in the log as `board says: ...` lines and the page says "board waiting
   at its prompt"; stop the recorder (Ctrl+C), answer the prompts in the terminal, start the recorder again.

No board: `PYTHONPATH=tests/fake_diy python3 scripts/record_diy.py --serial /dev/fake-diy --port 8799 --out /tmp/diy`
(environment variables in `tests/fake_diy/fake_board.py` add damage, drops and restarts), or
`python3 tests/fake_diy/fake_board.py --udp 127.0.0.1:9000` beside `record_diy.py --udp 9000`.

## What the recorder does

- **Same files** (`docs/data-format.md`, "Raw recording (DIY board)"): `.f32` records are the board's sequence
  number, then one float32 in volts per channel (`<I4f` for 4 channels, exactly the BrainBit record; `<I8f` for 8);
  `.idx`, `.log`, `.markers.jsonl` as for the BrainBit. The `.log` says the channel names, rate, gain, VREF, record
  layout and mode.
- **Same pages**: `/state` and `/stream` keep their keys; `names` and the rows of `data` follow the board's
  channels. The live page draws one row per channel and says "contact not measured" (the board has no contact
  measurement while lead-off detection is off). The sleep and morning report routes answer with an error: they
  score BrainBit's O1 O2 T3 T4 only.
- **Nothing filled in.** Missing frames are counted, never invented: "lost N samples in M gaps (board missed X, link
  lost Y)" every 10 s and at the end (board = its own overrun counter; link = damaged or lost on the way). Damaged
  frames and skipped bytes, repeated and late datagrams are counted too.
- **Drops in-process.** A vanished USB port is tried again every second; the pages stay up and say "reconnecting";
  if the board kept running, the same files go on and the gap shows in the `.idx` times (`to_bdf.py` would mark it
  `BAD_gap`). It never reopens a working port because data stopped (reopening can restart a DevKit).
- **A restart is a new capture.** The board's start-up text, a sequence that jumps back, or a changed mode or channel
  count ends the file set ("this file set ends here") and the next frame starts a new one ("continues ... after a
  board restart"), never joined silently to the old one (PROTOCOL.md, host behaviour). A `HALTED` line is logged and
  shown on the page.

## What changes for other montages

The BrainBit's tools assume O1 O2 T3 T4: `to_bdf.py` (names the channels O1 O2 T3 T4 and reads 4-channel records
only), `score_sleep.py`, `sleep_report.py` / `night_files.py`, `morning_check.py`, the detectors, the sound pages
(they refuse any other names) and the eyes page (it reads the first two channels as O1 and O2; the default DIY
montage starts with O1 O2, so it lines up). That is why the board records into its own folder and its hub refuses
the reports. Making them work for any positions is DECISIONS row 4 ("calibration for any electrode positions"),
after the helmet exists.

## On the phone

The phone app (`app/`, branch `feat/app-diy-board`) records the board over **Wi-Fi only**: the firmware's UDP route,
one E9 frame per datagram to the phone's port 9000. USB OTG serial to the phone is not built (it would need a USB
host plugin and the DevKit's bridge driver; the laptop has the USB route). The app only listens: there is no send call
in `app/lib/headband/diy/`, and a test keeps it so.

- **Switch.** Night screen, Headband section, **Headband connection**: **Headband: BrainBit / DIY board (test)**, off by
  default (`files/diy-board/settings.json`), locked while a night records or a session runs. The page states the
  safety rule (the app only listens; nothing in it makes the board safe for a body or power or changes its gates),
  shows this phone's Wi-Fi address for the firmware's `UDP_HOST`, and holds the channel names (four, CH1 to CH4;
  default O1 O2 Fz Fp1, as on the laptop).
- **The night.** The recorder's service builds the board's finder itself (`app/lib/headband/diy/night.dart`): one UDP
  listener all night on every IPv4 interface (alone when it can be, else shared with address reuse, said in the log:
  the emulator's OpenThread simulator holds port 9000 on a multicast address), a Wi-Fi lock while it records (shared
  with Share on Wi-Fi), and the
  app's night recorder unchanged in its rules (one file set per run, `.log` lines, markers, Lights off as a marker,
  the phone's alarm). The board object (`board.dart`) holds one capture; the decoder (`e9.dart`) is a line-for-line
  port of `scripts/diy_board.py` and both are pinned to the same results by `app/test/fixtures/diy_vectors.json`
  (made by the Python driver from the firmware's golden frames, the fake board and damaged frames;
  `analysis/tests/test_diy_vectors.py` fails when it is stale).
- **Files.** `files/recordings-diy/<stamp>.f32 .idx .log .markers.jsonl`, byte for byte the laptop's DIY layout
  (`<I4f`: the board's sequence number, then CH1-CH4 in volts); about 10 frames per `.idx` row (the laptop's 40 ms).
  The `.log` names the driver, the link and every sender, the channels, scaling (vref 4.5 V assumed), format and mode
  ("not EEG"). Export data takes the folder; `scripts/import_phone.py` files it under `_local/recordings-diy/`.
- **Same rules as the laptop**: missing frames counted ("lost N samples in M gaps (board missed X, link lost Y)" every
  10 s), never filled in; damaged, repeated and late datagrams counted and dropped; a restart (sequence far back, clock
  back) or a new mode, channel count, gain or rate ends the file set ("board restarted (...): this file set ends here")
  and the next one starts with the new capture ("a new capture: board restarted (...)"), never joined silently.
- **Differences from the laptop.** A run also ends after 40 s without frames (the phone recorder's rule for every
  headband) and the next frames start a new file set, where the laptop keeps one set through a USB drop. Frames that
  arrive while no file set is open (between two sets) are kept, up to 10 s, and go into the next one. Datagrams from
  outside the local network are ignored and counted. The 8-channel chip is refused in words (the phone keeps the
  BrainBit's 20-byte record; the owner's chip is the ADS1299-4). No contact check, no battery lines.
- **Refused with the board** (DECISIONS row 358's reason): the sleep report (the board's nights are never in
  `files/recordings/`, and the Sleep section says so), the morning check-in and every session (their finder refuses in
  words: "The DIY board (test) is chosen as the headband. This needs the BrainBit: it reads O1 O2 T3 T4."), the
  drift-off detector, hands-free and the smart alarm's sleep model (the recorder never gives them the board's
  samples and logs that they are off; the phone's alarm still rings). Share on Wi-Fi's live pages carry the board's
  channel names.
- **Night screen.** "Recording the board's test signal. It is not EEG."; the Headband block shows each channel's
  swing over the last second in µV (the test square: about 3750), "Test signal, not EEG", the sender and lost samples.

The owner's steps are in `app/README.md`, "The DIY board". TO VERIFY on the real board, beyond the laptop's list: the
board's datagrams reaching the phone with the screen off (HyperOS, the Wi-Fi lock), the Wi-Fi loss rate over a night,
and whether Android starts the night's service with Bluetooth never allowed on HyperOS (the app declares
`CHANGE_WIFI_STATE` for that; on the API 36 emulator, with Bluetooth's permissions revoked, the night started and
recorded: 600 frames sent inside the emulator to its Wi-Fi address, all 600 in the file, in order; app/README.md,
emulator step 9).

## Verified and TO VERIFY

| Fact | Source | State |
|---|---|---|
| Frame layout, CRC, sign, byte order | the firmware's `portable_core.h` built on this laptop (`tests/fake_diy/golden/make_golden.cpp`): 4 golden frames, one byte for byte the lab's own native test | verified (in software) |
| Volts = counts x VREF / (gain x 2^23); 83886 counts = the 1.875 mV test square | ADS1299 datasheet SBAS499C eq. 8 and p.47, via the lab's card | verified (arithmetic) |
| Serial 460800 baud on UART0, binary frames after the prompts, text before them and on `HALTED` | the sketch | read in the source; TO VERIFY on the board |
| Opening the port does not restart the DevKit | pyserial's defaults, as miniterm opens it; the lab card's step 4 tests it | TO VERIFY per DevKit |
| The firmware emits only 250 Hz, gain 24, flags 1 or 2 (+8) | the sketch | read in the source |
| The status word's lead-off bits stay 0 with lead-off detection off | not checked | TO VERIFY (logged when non-zero) |
| No frames lost at 460800 baud in a whole night | not measured (the firmware's own text: "a conservative starter") | TO VERIFY |
| The Wi-Fi route: one datagram per frame, its loss rate | the sketch; no measurement | TO VERIFY |
| `--vref 4.5` matches the real reference | the card's step 8 measures VREFP 4.45-4.55 V | TO VERIFY with the meter; the test signal cancels it |
| O1 O2 Fz Fp1 on CH1-CH4 | the lab's breadboard guide review (finding BB-23); its committed card names only O1 | a plan; no electrode mode yet |

## Tests

Phone: `flutter test test/diy_e9_test.dart test/diy_board_test.dart test/diy_night_test.dart test/diy_switch_test.dart
test/diy_screens_test.dart` (in `app/`): the decoder against the Python one on the shared vectors (every frame case,
every single-bit flip, five byte streams chunk by chunk, seven tracker sequences, bit for bit); the board object on the
fake board (damage, gaps, repeats, late datagrams, restarts, a new mode, the 8-channel chip, foreign senders, a dead
socket) and on a real UDP socket; whole nights through the night recorder (its folder, layout and lines, no contact
check, no detectors, three file sets for a restart and a new mode, holes left as holes); the switch, the refusals, the
export; the pages rendered at 393 dp, 100 and 130 % text. Python: `analysis/tests/test_diy_vectors.py`.

Laptop:

`uv run --project analysis --with pytest pytest -q analysis/tests/test_diy_board.py` (about 15 s): the golden frames
decode; every single-bit flip, wrong length, wrong field and missing 0xC status prefix is refused; volts by hand;
a byte stream with a cut frame, text, garbage, a fake header and a damaged frame in random chunks gives exactly the
good frames and the two text lines; endless garbage keeps the buffers small; the tracker's gaps, repeats, late
frames, restarts, configuration changes and the uint32 wrap; montages; the hub's BrainBit defaults unchanged and
any channel count; the report routes refused; no write or send call in the driver or recorder. End to end, five
recorders on the fake board side by side: damage (files, counts, scaling, pages' keys, a marker, no byte written to
the board), a USB drop (one file set, gap in `.idx`), a restart (two file sets), a halt, and the Wi-Fi route with
an 8-channel chip (Ch1..Ch8, repeated and late datagrams dropped). One more runs the recorder with the real pyserial
3.5 on a pseudo-terminal and checks that nothing came back to the board's side. `node --test
tests/web/live-page.test.mjs`: the live page draws the board's channel rows.
