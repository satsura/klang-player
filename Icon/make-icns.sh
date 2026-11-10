#!/bin/sh
# Renders the icons and builds Icon/AppIcon.icns from variant A.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
xcrun swift render.swift "$TMP"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-a.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon-a.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$TMP/icon-a.png" AppIcon.png
rm -r "$TMP"
echo "Built Icon/AppIcon.icns"
