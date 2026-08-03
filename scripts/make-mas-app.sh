#!/usr/bin/env bash
# Assembles the sandboxed MAS archive and the linker map its receipts read.
#
# This is deliberately separate from scripts/make-app.sh. The two products differ
# in entitlements, in which executable they carry, and in whether a helper is
# bundled, and a single script with a flag would make it easy to ship one
# product's posture inside the other's bundle.
#
# Submission stays deferred by decision 5. This produces and validates an archive;
# it does not upload one.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="${APP_OUT:-$ROOT/.build/Allward-MAS.app}"
MAPS="${MAP_OUT:-$ROOT/.build/mas-maps}"
BUNDLE_ID="ai.allward.Allward.mas"
VERSION="$(sed -n 's/^allwardVersion = "\(.*\)"$/\1/p' "$ROOT/Sources/AllwardCore/Version.swift" 2>/dev/null || true)"
VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"

bash "$ROOT/scripts/build-rust.sh"

mkdir -p "$MAPS"
# The linker map is receipt 3's evidence. Dead stripping can remove a forbidden
# target's code while leaving it in the graph, so the map is what proves what the
# linker was actually given.
swift build -c "$CONFIG" --product allward-mas \
    -Xlinker -map -Xlinker "$MAPS/Allward.map"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/allward-mas" "$APP/Contents/MacOS/Allward"

# No allward-mcp helper. SPEC §15 grants MAS the MCP surface, but the transport
# that reaches it under sandbox is later work, and scripts/mas-isolation.json
# declares a closed artifact set that a stray helper would fail.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ -f "$ROOT/assets/Allward.icns" ]; then
    cp "$ROOT/assets/Allward.icns" "$APP/Contents/Resources/Allward.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Allward</string>
    <key>CFBundleDisplayName</key><string>Allward</string>
    <key>CFBundleExecutable</key><string>Allward</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>Allward</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Allward uses the microphone only while you hold the dictation key, and only to turn your speech into text in the pane you locked.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Allward transcribes push-to-talk dictation on this device. Audio and transcripts never leave your Mac.</string>
</dict>
</plist>
PLIST

# App Sandbox is what makes this the MAS product; network.client is what leaves it
# able to reach a remote host at all. Nothing else is granted: no
# network.server, because it owns no listener; no inherit, because it spawns
# nothing; and no temporary exceptions.
cat > "$APP/Contents/Resources/Allward-MAS.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
ENT

codesign --force --options runtime \
    --entitlements "$APP/Contents/Resources/Allward-MAS.entitlements" \
    --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/codesign: /'
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/verify: /'

echo "built $APP ($VERSION, identity ${IDENTITY})"
echo "linker map $MAPS/Allward.map"
echo
echo "now prove it:"
echo "  python3 scripts/mas-isolation-receipts.py --archive $APP --linker-map $MAPS"
