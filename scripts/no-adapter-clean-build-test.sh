#!/usr/bin/env bash
# Proves the optional-adapter boundary of SPEC §2: no core target may depend on
# `AllwardHerdr`, and a build of the core graph must not produce its module.
#
# A source grep alone is not sufficient, so this also builds the core targets in
# a scratch build directory and asserts the adapter module is absent from the
# resulting artifact set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ADAPTER="AllwardHerdr"
# Every target except the adapter itself and the app shell, which is the one
# place allowed to construct an adapter.
CORE_TARGETS=(
    AllwardCore AllwardDesign AllwardTerminal AllwardProtocol AllwardRooms
    AllwardSurfaces AllwardMultiplexer AllwardConfig AllwardRemote
    AllwardLocalPTY AllwardSSH AllwardLocalPublisherEndpoint AllwardRenderer
    AllwardIntelligence AllwardSpeech AllwardControl AllwardConcierge AllwardMCP
)

status=0

echo "== source import check =="
for target in "${CORE_TARGETS[@]}"; do
    if grep -rqs "^import ${ADAPTER}\$" "Sources/${target}"; then
        echo "FAIL ${target} imports ${ADAPTER}"
        status=1
    fi
done
[ "$status" -eq 0 ] && echo "ok: no core target imports ${ADAPTER}"

echo "== core graph build =="
# SwiftPM honours only the last --target, so each core target is built on its
# own. That is also the stronger claim: every one of them resolves without the
# adapter, not just the union that shares one dependency closure.
SCRATCH="${ALLWARD_NO_ADAPTER_SCRATCH:-.build-no-adapter}"
for target in "${CORE_TARGETS[@]}"; do
    swift build --scratch-path "$SCRATCH" --target "$target" \
        > /tmp/allward-no-adapter.log 2>&1 || {
        echo "FAIL ${target} did not build"
        tail -15 /tmp/allward-no-adapter.log
        exit 1
    }
    MODULES="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/Modules"
    if [ -e "${MODULES}/${ADAPTER}.swiftmodule" ]; then
        echo "FAIL ${target} pulled ${ADAPTER} into the build"
        status=1
        break
    fi
    echo "  ok ${target}"
done
[ "$status" -eq 0 ] && echo "ok: no core target pulls ${ADAPTER} into its build"

exit "$status"
