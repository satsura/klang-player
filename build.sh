#!/bin/sh
# Builds KlangPlayer.app into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/KlangPlayer.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/KlangPlayer "$APP/Contents/MacOS/KlangPlayer"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
