#!/usr/bin/env bash
# Fetches AnySleep (MIT code + weights, ~310 MB) at the commit reviewed in docs/research/anysleep.md.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=_local/vendor/AnySleep
[ -d "$dir/.git" ] || git clone https://github.com/dslaborg/AnySleep.git "$dir"
git -C "$dir" checkout -q 88e13e3
echo "AnySleep ready in $dir"
