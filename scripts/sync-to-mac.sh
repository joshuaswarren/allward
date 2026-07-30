#!/usr/bin/env bash
# Mirror the working tree to the macOS build host. Build artifacts stay on the
# Mac; sources stay authored here.
set -euo pipefail
HOST="${ALLWARD_BUILD_HOST:-macstudio}"
DEST="${ALLWARD_BUILD_DIR:-src/allward-build}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "mkdir -p '$DEST'"
rsync -a --delete \
  --exclude '.git/' --exclude '.build/' --exclude 'artifacts/' --exclude '*.app/' \
  "$SRC"/ "$HOST:$DEST"/
