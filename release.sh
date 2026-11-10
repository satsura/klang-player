#!/bin/sh
# Builds a universal app, packs it into a DMG and publishes a GitHub release.
#   ./release.sh 1.1.0
set -e
cd "$(dirname "$0")"
VERSION="$1"
[ -n "$VERSION" ] || { echo "usage: ./release.sh <version>"; exit 1; }

swift test
rm -rf dist
# Version goes into both Info.plist files of the build (not the source ones).
./build.sh --universal dist
for p in dist/KlangPlayer.app/Contents/Info.plist dist/KlangPlayer.app/Contents/PlugIns/KlangWidget.appex/Contents/Info.plist; do
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$p"
    plutil -replace CFBundleVersion -string "$VERSION" "$p"
done
codesign --force --sign - --entitlements Widget/KlangWidget.entitlements dist/KlangPlayer.app/Contents/PlugIns/KlangWidget.appex
codesign --force --sign - dist/KlangPlayer.app

STAGE=$(mktemp -d)
cp -R dist/KlangPlayer.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/KlangPlayer-$VERSION.dmg"
hdiutil create -volname "Klang Player $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -r "$STAGE"
echo "Created $DMG"

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" --title "Klang Player $VERSION" --notes-file - <<EOF
Universal build (Apple Silicon and Intel), macOS 14 or later.

The app is not notarized. On first launch right-click it and choose Open,
or run: xattr -dr com.apple.quarantine /Applications/KlangPlayer.app
EOF
