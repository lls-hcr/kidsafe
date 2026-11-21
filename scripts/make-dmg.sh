#!/bin/sh
# Crée build/KidSafe.dmg : KidSafe (Privoxy intégré), désinstalleur, raccourci Applications, mode d'emploi.
# Le nom ne change pas d'une version à l'autre, pour que le lien
# https://github.com/lls-hcr/kidsafe/releases/latest/download/KidSafe.dmg reste valable.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh --universal
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/KidSafe.app/Contents/Info.plist)"

# Mise en page soignée avec dmgbuild (Python, installé dans build/venv) : fond, icônes placées,
# KidSafe et Applications au premier plan, désinstalleur et mode d'emploi discrets en bas.
[ -x build/venv/bin/dmgbuild ] || { python3 -m venv build/venv && build/venv/bin/pip install -q dmgbuild; }
mkdir -p build/dmg-bg
swift scripts/make-dmg-background.swift build/dmg-bg/bg.png 1 >/dev/null 2>&1
swift scripts/make-dmg-background.swift build/dmg-bg/bg@2x.png 2 >/dev/null 2>&1
tiffutil -cathidpicheck build/dmg-bg/bg.png build/dmg-bg/bg@2x.png -out build/dmg-bg/background.tiff >/dev/null
STAGE=build/dmg; rm -rf "$STAGE" build/KidSafe.dmg; mkdir -p "$STAGE"
cp scripts/dmg-readme.txt "$STAGE/Lisez-moi - Read me.txt"
build/venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app=build/KidSafe.app -D "uninstaller=build/Uninstall KidSafe.app" \
  -D "readme=$STAGE/Lisez-moi - Read me.txt" -D background=build/dmg-bg/background.tiff \
  "KidSafe $VERSION" build/KidSafe.dmg >/dev/null
rm -rf "$STAGE"
hdiutil verify -quiet build/KidSafe.dmg
echo "OK : build/KidSafe.dmg ($(du -h build/KidSafe.dmg | cut -f1), version $VERSION)"
shasum -a 256 build/KidSafe.dmg
