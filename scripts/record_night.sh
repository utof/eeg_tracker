#!/usr/bin/env bash
# Records the BrainBit until Ctrl+C; keeps the laptop awake while it runs.
# If the recorder exits with an error (e.g. the stream stalled), a fresh one starts after 5 s.
cd "$(dirname "$0")/.." || exit 1
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
stop=0; trap 'stop=1' INT TERM
while :; do
  systemd-inhibit --what=sleep:idle:handle-lid-switch --why="EEG night recording" \
    uv run --no-project --python 3.12 --with pyneurosdk2==1.0.15 python scripts/record_night.py "$@"
  rc=$?
  [ "$stop" = 1 ] || [ "$rc" = 0 ] && break
  echo "$(date -Is) recorder exited with $rc; starting a fresh one in 5 s"; sleep 5
  [ "$stop" = 1 ] && break
done
