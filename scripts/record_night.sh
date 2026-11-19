#!/usr/bin/env bash
# Records the BrainBit (or, with DRIVER=diy, the DIY board) until Ctrl+C; keeps the laptop awake while it runs.
# If the recorder exits with an error (e.g. the stream stalled), a fresh one starts after 5 s.
# DRIVER=ble uses our own Bluetooth driver (scripts/record_ble.py, docs/own-ble-driver.md): no BrainBit SDK, drops
# handled in-process. The default stays BrainBit's SDK (scripts/record_night.py) until the probe has passed.
# DRIVER=diy records the DIY ADS1299 board (scripts/record_diy.py, docs/diy-board.md) into _local/recordings-diy.
# Exit code 2 (wrong options, missing pyserial) stops the loop instead of retrying the same mistake every 5 s.
cd "$(dirname "$0")/.." || exit 1
if [ "${DRIVER:-sdk}" = ble ]; then
  RUN=(uv run --no-project --python 3.12 --with bleak==3.1.0 python scripts/record_ble.py)
elif [ "${DRIVER:-sdk}" = diy ]; then
  RUN=(uv run --no-project --python 3.12 --with pyserial==3.5 python scripts/record_diy.py)
else
  export LD_LIBRARY_PATH="$HOME/.local/lib/neurosdk2"
  # NeuroSDK2 on Linux asks BlueZ to remove EVERY known Bluetooth device each time it starts a scan (it unpaired the
  # owner's keyboard, 2026-11-18; DECISIONS 84). A locally patched copy with that one call disabled lives in
  # _local/vendor/neurosdk2-patched (private, never committed); without it, refuse to start unless ALLOW_UNPAIR=1.
  if [ -f _local/vendor/neurosdk2-patched/libneurosdk2.so ]; then
    export LD_LIBRARY_PATH="$PWD/_local/vendor/neurosdk2-patched:$LD_LIBRARY_PATH"
  elif [ "${ALLOW_UNPAIR:-0}" != 1 ]; then
    echo "NeuroSDK2 would unpair all Bluetooth devices on this laptop at every start (DECISIONS 84)."
    echo "Make the patched copy (see DECISIONS 84) or run with ALLOW_UNPAIR=1 to accept that."; exit 1
  fi
  RUN=(uv run --no-project --python 3.12 --with pyneurosdk2==1.0.15 python scripts/record_night.py)
fi
stop=0; trap 'stop=1' INT TERM
while :; do
  systemd-inhibit --what=sleep:idle:handle-lid-switch --why="EEG night recording" "${RUN[@]}" "$@"
  rc=$?
  [ "$stop" = 1 ] || [ "$rc" = 0 ] || [ "$rc" = 2 ] && break
  echo "$(date -Is) recorder exited with $rc; starting a fresh one in 5 s"; sleep 5
  [ "$stop" = 1 ] && break
done
