#!/bin/bash
# Build ReqBuddy.app (release, ad-hoc signed) into mac_app/dist/.
set -euo pipefail
# SwiftUI macros (@State etc.) need the Xcode toolchain, not the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/ReqBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ReqBuddy" "$APP/Contents/MacOS/ReqBuddy"
cp "$BIN/reqcli" dist/reqcli
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ReqBuddy</string>
  <key>CFBundleDisplayName</key><string>ReqBuddy</string>
  <key>CFBundleIdentifier</key><string>local.workbuddy.reqbuddy</string>
  <key>CFBundleExecutable</key><string>ReqBuddy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP  (CLI: $PWD/dist/reqcli)"
