#!/usr/bin/env bash
# Build, sandbox, and run the capability probe in fixtures/mas-sandbox-probe.
#
# The probe only measures anything when the kernel has actually applied App
# Sandbox, and that needs a signed bundle carrying the entitlement. So this
# assembles a minimal .app, signs it ad hoc with com.apple.security.app-sandbox,
# and runs the binary from inside it. The probe's first line reports whether the
# sandbox took effect; if it says NOT SANDBOXED, the run is void.
#
# Signing identity comes from ALLWARD_PROBE_IDENTITY and defaults to ad-hoc.
# Ad-hoc has no team identifier, and the Keychain probe needs one to reach its
# own access group, so an ad-hoc run reports Keychain as unproven rather than
# unavailable. Pass a real identity to settle it:
#
#   security find-identity -v -p codesigning
#   ALLWARD_PROBE_IDENTITY="Apple Development: ..." bash fixtures/mas-sandbox-probe/run.sh
#
# No identity is hard-coded here. A team identifier is not repository content.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/.build-sandbox-probe}"
APP="$OUT/AllwardSandboxProbe.app"
IDENTITY="${ALLWARD_PROBE_IDENTITY:--}"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -O \
    -o "$APP/Contents/MacOS/AllwardSandboxProbe" \
    "$ROOT/fixtures/mas-sandbox-probe/main.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AllwardSandboxProbe</string>
    <key>CFBundleExecutable</key><string>AllwardSandboxProbe</string>
    <key>CFBundleIdentifier</key><string>ai.allward.sandbox-probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST

cat > "$OUT/probe.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENT

if ! codesign --force --options runtime \
    --entitlements "$OUT/probe.entitlements" --sign "$IDENTITY" "$APP" \
    > "$OUT/codesign.log" 2>&1; then
    sed 's/^/codesign: /' "$OUT/codesign.log"
    if grep -q errSecInternalComponent "$OUT/codesign.log"; then
        cat <<'WHY'

codesign could not reach the signing key. Over SSH the login keychain is locked,
and the private key needs it open. Unlock it in that same shell first:

    security unlock-keychain ~/Library/Keychains/login.keychain-db

Then re-run. Ad-hoc signing works without any of this, but reports Keychain as
unproven rather than measured, because ad-hoc has no team identifier.
WHY
    fi
    exit 1
fi
echo "signed with: ${IDENTITY}"

echo "entitlements as signed:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null |
    tr '<' '\n' | grep -o 'com\.apple\.security\.[a-z.-]*' | sort -u | sed 's/^/  /'
echo

"$APP/Contents/MacOS/AllwardSandboxProbe"
