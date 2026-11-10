#!/bin/sh
# Builds KlangPlayer.app (with the widget extension).
#   ./build.sh                 → ~/Applications/KlangPlayer.app, this Mac's architecture
#   ./build.sh --universal DIR → DIR/KlangPlayer.app, Apple Silicon + Intel
set -e
cd "$(dirname "$0")"

DEST="$HOME/Applications"
UNIVERSAL=0
if [ "$1" = "--universal" ]; then UNIVERSAL=1; DEST="${2:-dist}"; fi

APP="$DEST/KlangPlayer.app"
WIDGET="$APP/Contents/PlugIns/KlangWidget.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS" "$WIDGET/Contents/Resources"

if [ $UNIVERSAL = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/KlangPlayer" "$APP/Contents/MacOS/KlangPlayer"
else
    swift build -c release
    cp .build/release/KlangPlayer "$APP/Contents/MacOS/KlangPlayer"
fi
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Widget extension: SwiftPM can't build .appex bundles, so compile it directly.
widget() {
    xcrun swiftc -O -parse-as-library -application-extension \
        -target "$1-apple-macos14.0" -module-name KlangWidget Widget/*.swift -o "$2"
}
if [ $UNIVERSAL = 1 ]; then
    TMP=$(mktemp -d)
    widget arm64 "$TMP/w-arm64"
    widget x86_64 "$TMP/w-x86_64"
    lipo -create "$TMP/w-arm64" "$TMP/w-x86_64" -output "$WIDGET/Contents/MacOS/KlangWidget"
    rm -r "$TMP"
else
    widget "$(uname -m)" "$WIDGET/Contents/MacOS/KlangWidget"
fi
cp Widget/Info.plist "$WIDGET/Contents/Info.plist"
cp -R Resources/*.lproj "$WIDGET/Contents/Resources/"

codesign --force --sign - --entitlements Widget/KlangWidget.entitlements "$WIDGET"
codesign --force --sign - "$APP"
if [ $UNIVERSAL = 0 ]; then
    # Let the system pick up the (re)built widget.
    pluginkit -a "$WIDGET" 2>/dev/null || true
fi
echo "Built $APP"
