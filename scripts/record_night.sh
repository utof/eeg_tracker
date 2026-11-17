#!/usr/bin/env bash
# Records the BrainBit until Ctrl+C; keeps the laptop awake while it runs.
# If the recorder exits with an error (e.g. the stream stalled), a fresh one starts after 5 s.
cd "$(dirname "$0")/.." || exit 1
export LD_LIBRARY_PATH="$HOME/.local/lib/neurosdk2"
stop=0; trap 'stop=1' INT TERM
while :; do
  systemd-inhibit --what=sleep:idle:handle-lid-switch --why="EEG night recording" \
    uv run --no-project --python 3.12 --with pyneurosdk2==1.0.15 python scripts/record_night.py "$@"
  rc=$?
  [ "$stop" = 1 ] || [ "$rc" = 0 ] && break
  echo "$(date -Is) recorder exited with $rc; starting a fresh one in 5 s"; sleep 5
  [ "$stop" = 1 ] && break
done
