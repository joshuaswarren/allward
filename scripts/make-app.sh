#!/usr/bin/env bash
# Assemble Allward.app from the SwiftPM build products.
#
# SwiftPM builds plain executables; macOS needs a bundle with an Info.plist for
# window activation, TCC identity, and Launch Services. Keeping the bundle here
# rather than in an Xcode project keeps the build one scriptable command.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="${APP_OUT:-$ROOT/.build/Allward.app}"
BUNDLE_ID="ai.allward.Allward"
VERSION="$(sed -n 's/^allwardVersion = "\(.*\)"$/\1/p' "$ROOT/Sources/AllwardCore/Version.swift" 2>/dev/null || true)"
VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product allward
swift build -c "$CONFIG" --product allward-mcp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/allward" "$APP/Contents/MacOS/Allward"
cp "$BUILD_DIR/allward-mcp" "$APP/Contents/MacOS/allward-mcp"

# SwiftPM emits resource bundles beside the binary; the app must carry them.
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
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Resources/Allward.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.automation.apple-events</key><false/>
</dict>
</plist>
ENT

codesign --force --deep --options runtime \
    --entitlements "$APP/Contents/Resources/Allward.entitlements" \
    --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/codesign: /'

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/verify: /'
echo "built $APP ($VERSION, identity ${IDENTITY})"
