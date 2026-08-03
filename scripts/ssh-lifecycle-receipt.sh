#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required=(ALLWARD_SSH_TEST_HOST ALLWARD_SSH_TEST_USER ALLWARD_SSH_TEST_KEY)
missing=()
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
done
if ((${#missing[@]} > 0)); then
    printf 'Set %s before running live cells (for example: ALLWARD_SSH_TEST_HOST=... ALLWARD_SSH_TEST_USER=... ALLWARD_SSH_TEST_KEY=...).\n' \
        "${required[*]}"
fi

scratch="${ALLWARD_SSH_LIFECYCLE_SCRATCH:-.build-ssh-lifecycle}"
tests=(
    "connect:testConnectCellReportsConnecting"
    "authenticate:testAuthenticateCellReportsAuthenticating"
    "live-remote-pty:testLiveRemotePTYCarriesInputAndOutput"
    "control:testControlCellPublishesPTYResize"
    "exit-code:testExitCodeCellReportsNonZeroStatus"
    "trust:testTrustCellRefusesHostKey"
    "cancel:testCancelCellCancelsAnInFlightOpen"
    "close:testCloseCellReportsExplicitClosedStateWithoutFailure"
    "disconnect:testDisconnectCellReportsRemoteExitWithoutFailure"
    "forward:testForwardCellIsExplicitlyUnproven"
    "reconnect:testReconnectCellIsExplicitlyUnproven"
    "generation-fence:testGenerationFenceCellIsExplicitlyUnproven"
)

pass_count=0
skip_count=0
fail_count=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for entry in "${tests[@]}"; do
    cell="${entry%%:*}"
    test_name="${entry#*:}"
    : >"$tmp"
    status=0
    swift test --scratch-path "$scratch" --filter "AllwardSSHTests.SSHLifecycleTests/$test_name" \
        >"$tmp" 2>&1 || status=$?
    output="$(cat "$tmp")"
    if [[ "$output" == *"skipped"* || "$output" == *"Skipped"* ]]; then
        result=SKIP
        ((skip_count += 1))
        reason=""
        while IFS= read -r line; do
            case "$line" in
                *"Test skipped - "*) reason="${line#*Test skipped - }" ;;
            esac
        done <<<"$output"
        if [[ -n "$reason" ]]; then
            printf 'CELL %s %s %s\n' "$cell" "$result" "$reason"
        else
            printf 'CELL %s %s\n' "$cell" "$result"
        fi
    elif ((status == 0)); then
        result=PASS
        ((pass_count += 1))
        printf 'CELL %s %s\n' "$cell" "$result"
    else
        result=FAIL
        ((fail_count += 1))
        printf 'CELL %s %s\n' "$cell" "$result"
        printf '%s\n' "$output" >&2
    fi
done

printf 'SUMMARY PASS=%d SKIP=%d FAIL=%d\n' "$pass_count" "$skip_count" "$fail_count"
((fail_count == 0))
