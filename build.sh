#!/bin/sh
# Builds KlangPlayer.app (with the widget extension) into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release

APP="$HOME/Applications/KlangPlayer.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/KlangPlayer "$APP/Contents/MacOS/KlangPlayer"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Widget extension: SwiftPM can't build .appex bundles, so compile it directly.
WIDGET="$APP/Contents/PlugIns/KlangWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
xcrun swiftc -O -parse-as-library -application-extension \
    -target "$(uname -m)-apple-macos14.0" \
    -module-name KlangWidget Widget/*.swift \
    -o "$WIDGET/Contents/MacOS/KlangWidget"
cp Widget/Info.plist "$WIDGET/Contents/Info.plist"
mkdir -p "$WIDGET/Contents/Resources"
cp -R Resources/*.lproj "$WIDGET/Contents/Resources/"

codesign --force --sign - --entitlements Widget/KlangWidget.entitlements "$WIDGET"
codesign --force --sign - "$APP"
# Let the system pick up the (re)built widget.
pluginkit -a "$WIDGET" 2>/dev/null || true
echo "Built $APP"
