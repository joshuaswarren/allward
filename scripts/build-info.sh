#!/usr/bin/env bash
# Emits the build provenance the About panel shows, as KEY=value lines.
#
# Two sources, in this order:
#
#   1. A real git repository in the tree. That is a fresh clone or a Mac working
#      directly on the checkout.
#   2. `.allward-build-info`, which `scripts/sync-to-mac.sh` stamps immediately
#      before it copies the tree. The build host has no `.git`, because the sync
#      excludes it, so without this stamp a synced build could report nothing.
#
# Neither available is not an error. It prints `unknown` and the About panel says
# so, which is better than inventing a commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/.allward-build-info"

commit="unknown"
dirty="false"
source="unknown"

if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    commit="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    # Untracked files are deliberately ignored: a stray note beside the source did
    # not change what was compiled, and treating it as dirty would make every
    # build look modified.
    if ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
        dirty="true"
    fi
    source="git"
elif [ -f "$STAMP" ]; then
    # shellcheck disable=SC1090
    . "$STAMP"
    commit="${ALLWARD_BUILD_COMMIT:-unknown}"
    dirty="${ALLWARD_BUILD_DIRTY:-false}"
    source="synced"
fi

echo "ALLWARD_BUILD_COMMIT=$commit"
echo "ALLWARD_BUILD_DIRTY=$dirty"
echo "ALLWARD_BUILD_SOURCE=$source"
echo "ALLWARD_BUILD_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# `write_stamp` is how the sync script records provenance for a tree that will
# arrive without a `.git`.
if [ "${1:-}" = "--write-stamp" ]; then
    {
        echo "# Written by scripts/build-info.sh. Not committed: it describes one"
        echo "# transfer of this tree, not the tree itself."
        echo "ALLWARD_BUILD_COMMIT=$commit"
        echo "ALLWARD_BUILD_DIRTY=$dirty"
    } > "$STAMP"
fi
