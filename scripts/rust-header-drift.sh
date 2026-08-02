#!/usr/bin/env bash
# Proves Sources/CAllwardSSH/include/allward_ssh.h still matches rust/allward-ssh.
#
# The header is generated, committed, and reviewed. Nothing stops a Rust signature
# changing without the header following, and an ABI mismatch corrupts memory
# instead of failing to compile, so this regenerates and diffs.
#
# `--write` updates the committed header, which is the only way it should change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/rust/allward-ssh"
HEADER="$ROOT/Sources/CAllwardSSH/include/allward_ssh.h"
WRITE="${1:-}"

command -v cbindgen > /dev/null || {
    echo "cbindgen is not on PATH. Install it: cargo install cbindgen" >&2
    exit 1
}

generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT
# cbindgen resolves `cargo metadata` from its working directory, so it runs inside
# the crate. Its stderr is not suppressed: hiding it once already turned a real
# failure into a silent no-op.
( cd "$CRATE" && cbindgen --config cbindgen.toml --crate allward-ssh --output "$generated" )

if [ "$WRITE" = "--write" ]; then
    mkdir -p "$(dirname "$HEADER")"
    cp "$generated" "$HEADER"
    echo "wrote $HEADER"
    exit 0
fi

if [ ! -f "$HEADER" ]; then
    echo "FAIL $HEADER does not exist. Generate it: bash scripts/rust-header-drift.sh --write" >&2
    exit 1
fi

if diff -u "$HEADER" "$generated"; then
    echo "ok: the committed C header matches rust/allward-ssh"
else
    echo "FAIL the committed header no longer matches the Rust source." >&2
    echo "     Review the diff above, then: bash scripts/rust-header-drift.sh --write" >&2
    exit 1
fi
