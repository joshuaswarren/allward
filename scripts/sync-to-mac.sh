#!/usr/bin/env bash
# Mirror the working tree to the macOS build host. Build artifacts stay on the
# Mac; sources stay authored here.
set -euo pipefail
HOST="${ALLWARD_BUILD_HOST:-macstudio}"
DEST="${ALLWARD_BUILD_DIR:-src/allward-build}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The sync excludes `.git`, so the build host cannot work out which commit it is
# holding. Stamp it here, from the tree actually being copied, so the About panel
# on a test build names the right revision.
bash "$SRC/scripts/build-info.sh" --write-stamp > /dev/null
ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "mkdir -p '$DEST'"
rsync -a --delete \
  --exclude '.git/' --exclude '.build*/' --exclude 'artifacts/' --exclude '*.app/' \
  "$SRC"/ "$HOST:$DEST"/
