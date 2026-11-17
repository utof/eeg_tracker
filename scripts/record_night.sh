#!/usr/bin/env bash
# Records the BrainBit until Ctrl+C; keeps the laptop awake while it runs.
cd "$(dirname "$0")/.." || exit 1
export LD_LIBRARY_PATH="$HOME/.local/lib/neurosdk2"
exec systemd-inhibit --what=sleep:idle:handle-lid-switch --why="EEG night recording" \
  uv run --no-project --python 3.12 --with pyneurosdk2==1.0.15 python scripts/record_night.py "$@"
