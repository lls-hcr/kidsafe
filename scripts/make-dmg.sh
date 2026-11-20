#!/bin/sh
# Crée build/KidSafe.dmg (app universelle + raccourci Applications + mode d'emploi).
# Le nom ne change pas d'une version à l'autre, pour que le lien
# https://github.com/lls-hcr/kidsafe/releases/latest/download/KidSafe.dmg reste valable.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh --universal
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/KidSafe.app/Contents/Info.plist)"

STAGE=build/dmg
rm -rf "$STAGE" build/KidSafe.dmg
mkdir -p "$STAGE"
ditto build/KidSafe.app "$STAGE/KidSafe.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/Lisez-moi - Read me.txt"

hdiutil create -quiet -volname "KidSafe $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/KidSafe.dmg
rm -rf "$STAGE"
hdiutil verify -quiet build/KidSafe.dmg
echo "OK : build/KidSafe.dmg ($(du -h build/KidSafe.dmg | cut -f1), version $VERSION)"
shasum -a 256 build/KidSafe.dmg
