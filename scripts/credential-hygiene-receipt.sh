#!/usr/bin/env bash
# Proves that credential-bearing files and artifacts do not contain private-key
# material. A string scan cannot prove absence, but it catches the realistic
# accident of a key being logged or embedded, which is the threat here.
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0
scratch="${ALLWARD_HYGIENE_SCRATCH:-.build-hygiene}"
config="${ALLWARD_HYGIENE_CONFIG:-debug}"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/allward-hygiene.XXXXXX")"
fixture="$fixture_dir/id_rsa"
trap 'rm -rf "$fixture_dir"' EXIT

check_command() {
    local name="$1"
    shift
    if "$@"; then
        printf 'CHECK %s PASS\n' "$name"
    else
        printf 'CHECK %s FAIL\n' "$name"
        status=1
    fi
}

make_fixture() {
    ssh-keygen -q -t rsa -b 2048 -N "" -f "$fixture"
    ssh-keygen -p -m PEM -P "" -N "" -f "$fixture" >/dev/null
}

run_hygiene_tests() {
    ALLWARD_SSH_TEST_PEM_KEY="$fixture" \
        swift test --scratch-path "$scratch" --filter CredentialHygieneTests
}

run_config_hygiene_tests() {
    ALLWARD_SSH_TEST_PEM_KEY="$fixture" \
        swift test --scratch-path "$scratch" --filter HostIdentityHygieneTests
}

fixture_fragments() {
    python3 - "$fixture" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_bytes().splitlines()
body = b"".join(line.strip() for line in lines if not line.startswith(b"-----"))
if len(body) < 64:
    raise SystemExit("fixture PEM body is unexpectedly short")
print(body[:64].decode("ascii"))
print(body[-64:].decode("ascii"))
PY
}

scan_files() {
    local root="$1"
    local include_markers=0
    shift
    if [[ "$1" == "--markers" ]]; then
        include_markers=1
        shift
    fi
    python3 - "$root" "$include_markers" "$@" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
include_markers = sys.argv[2] == "1"
fragments = [fragment.encode("ascii") for fragment in sys.argv[3:]]
markers = [
    b"-----BEGIN RSA PRIVATE KEY-----",
    b"-----BEGIN OPENSSH PRIVATE KEY-----",
    b"-----BEGIN PRIVATE KEY-----",
] if include_markers else []
if not root.exists():
    raise SystemExit(0)
paths = [root] if root.is_file() else root.rglob("*")
for path in paths:
    if not path.is_file():
        continue
    try:
        data = path.read_bytes()
    except OSError as error:
        print(f"unable to read {path}: {error}", file=sys.stderr)
        raise SystemExit(2)
    if any(marker in data for marker in markers) or any(fragment in data for fragment in fragments):
        print(f"private-key material found in {path}", file=sys.stderr)
        raise SystemExit(1)
raise SystemExit(0)
PY
}

find_allward_binaries() {
    local candidate
    for candidate in ".build/$config/allward" .build/*/"$config"/allward; do
        [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
    done
}

find_app_binaries() {
    local candidate
    for candidate in .build/*.app/Contents/MacOS/*; do
        [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
    done
}

scan_built_artifacts() {
    local fragment
    local -a fragments_array=()
    while IFS= read -r fragment; do fragments_array+=("$fragment"); done < <(fixture_fragments)
    local binary
    local found=0
    while IFS= read -r binary; do
        found=1
        scan_files "$binary" "${fragments_array[@]}" || return 1
    done < <(find_allward_binaries)
    while IFS= read -r binary; do
        found=1
        scan_files "$binary" "${fragments_array[@]}" || return 1
    done < <(find_app_binaries)
    [[ "$found" -eq 1 ]]
}

scan_written_files() {
    local fragment
    local -a fragments_array=()
    while IFS= read -r fragment; do fragments_array+=("$fragment"); done < <(fixture_fragments)
    scan_files "$HOME/.config/allward" --markers "${fragments_array[@]}" \
        && scan_files "$HOME/Library/Application Support/Allward" --markers "${fragments_array[@]}"
}

scan_build_tree() {
    local fragment
    local -a fragments_array=()
    while IFS= read -r fragment; do fragments_array+=("$fragment"); done < <(fixture_fragments)
    scan_files ".build" "${fragments_array[@]}"
}

make_fixture
check_command tests.credential-hygiene run_hygiene_tests
check_command tests.host-identity-hygiene run_config_hygiene_tests
check_command files.written-by-allward scan_written_files
check_command artifacts.built scan_built_artifacts
check_command artifacts.build-tree scan_build_tree

exit "$status"
