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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
# App icon: Resources/AppIcon.png (1024², already shaped and transparent) -> AppIcon.icns.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP  (CLI: $PWD/dist/reqcli)"

# Install a real copy (Spotlight and Launchpad skip symlinked apps). NO_INSTALL=1 to skip.
if [ -z "${NO_INSTALL:-}" ]; then
    DEST="${INSTALL_DIR:-$HOME/Applications}"
    mkdir -p "$DEST"
    if pgrep -xq ReqBuddy; then
        osascript -e 'quit app "ReqBuddy"' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq ReqBuddy || break; sleep 0.5; done
        RELAUNCH=1
    fi
    rm -rf "$DEST/ReqBuddy.app"
    cp -R "$APP" "$DEST/"
    mdimport "$DEST/ReqBuddy.app" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/ReqBuddy.app" 2>/dev/null || true
    echo "Installed $DEST/ReqBuddy.app (⌘Space → ReqBuddy)"
    [ -n "${RELAUNCH:-}" ] && open "$DEST/ReqBuddy.app"
fi
