#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/build/TokenBar.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
VERSION="${TOKENBAR_VERSION:-0.1.0}"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS"
cp "$ROOT/.build/release/TokenBar" "$MACOS/TokenBar"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TokenBar</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.santipandal.tokenbar</string>
    <key>CFBundleName</key>
    <string>TokenBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "$APP_DIR"
