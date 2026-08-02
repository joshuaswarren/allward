#!/usr/bin/env bash
# Builds rust/allward-ssh into a static archive SwiftPM can link.
#
# SwiftPM cannot build Rust, so this runs first and stages the archive at a fixed
# path that Package.swift names. Run it before `swift build` whenever the Rust
# source changed; the archive is not committed.
#
# The toolchain is pinned to stable on purpose. Inheriting whatever `rustup
# default` happens to be would make a release depend on a nightly, which is a
# reproducibility trap rather than a preference.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/rust/allward-ssh"
STAGE="$ROOT/.build-rust/lib"
CONFIG="${RUST_CONFIG:-release}"
TOOLCHAIN="${ALLWARD_RUST_TOOLCHAIN:-stable}"

# Universal by default so one archive serves both architectures; set
# ALLWARD_RUST_TARGETS to narrow it while iterating.
TARGETS="${ALLWARD_RUST_TARGETS:-aarch64-apple-darwin}"

command -v cargo > /dev/null || {
    echo "cargo is not on PATH. Install Rust: https://rustup.rs" >&2
    exit 1
}

mkdir -p "$STAGE"
archives=()
for target in $TARGETS; do
    rustup target list --installed | grep -qx "$target" || {
        echo "rust target $target is not installed: rustup target add $target" >&2
        exit 1
    }
    ( cd "$CRATE" && cargo "+$TOOLCHAIN" build --"$CONFIG" --target "$target" )
    archives+=("$CRATE/target/$target/$CONFIG/liballward_ssh.a")
done

if [ "${#archives[@]}" -gt 1 ]; then
    lipo -create "${archives[@]}" -output "$STAGE/liballward_ssh.a"
else
    cp "${archives[0]}" "$STAGE/liballward_ssh.a"
fi

echo "staged $STAGE/liballward_ssh.a ($(wc -c < "$STAGE/liballward_ssh.a") bytes, $TARGETS)"
