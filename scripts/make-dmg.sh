#!/bin/sh
# Crée build/KidSafe.dmg : KidSafe (Privoxy intégré), désinstalleur, raccourci Applications, mode d'emploi.
# Le nom ne change pas d'une version à l'autre, pour que le lien
# https://github.com/lls-hcr/kidsafe/releases/latest/download/KidSafe.dmg reste valable.
#
# Avec un certificat Developer ID dans le trousseau, l'app et le .dmg sont aussi notarisés par Apple
# puis « agrafés » : plus d'avertissement à l'ouverture. Profil notarytool : KIDSAFE_NOTARY_PROFILE (kidsafe-notary).
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh --universal
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/KidSafe.app/Contents/Info.plist)"
[ -f scripts/local.env ] && . scripts/local.env
PROFILE="${KIDSAFE_NOTARY_PROFILE:-kidsafe-notary}"
TEAM="$(codesign -dvv build/KidSafe.app 2>&1 | sed -n 's/^TeamIdentifier=//p')"
SIGNED=no; [ -n "$TEAM" ] && [ "$TEAM" != "not set" ] && SIGNED=yes

# Envoie un fichier à Apple et attend le verdict (quelques minutes en général).
notarize() {
  echo "Notarisation de $(basename "$1")…"
  OUTPUT="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)" || true
  echo "$OUTPUT" | grep -q "status: Accepted" && return 0
  echo "$OUTPUT" >&2
  ID="$(echo "$OUTPUT" | sed -n 's/^ *id: //p' | head -1)"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
  echo "Notarisation refusée : voir le rapport ci-dessus." >&2; exit 1
}

if [ "$SIGNED" = yes ]; then
  # 1. Les deux apps, envoyées ensemble dans un zip, puis agrafées (ticket utilisable hors ligne).
  Z=build/notarize; rm -rf "$Z"; mkdir -p "$Z/apps"
  ditto build/KidSafe.app "$Z/apps/KidSafe.app"; ditto "build/Uninstall KidSafe.app" "$Z/apps/Uninstall KidSafe.app"
  ditto -c -k --sequesterRsrc "$Z/apps" "$Z/apps.zip"
  notarize "$Z/apps.zip"
  xcrun stapler staple -q build/KidSafe.app
  xcrun stapler staple -q "build/Uninstall KidSafe.app"
  rm -rf "$Z"
fi

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

if [ "$SIGNED" = yes ]; then
  # 2. Le .dmg lui-même : signé, notarisé, agrafé. Puis contrôle final par Gatekeeper.
  codesign --force --sign "${KIDSAFE_SIGN_IDENTITY:-Developer ID Application}" --timestamp build/KidSafe.dmg
  notarize build/KidSafe.dmg
  xcrun stapler staple -q build/KidSafe.dmg
  spctl --assess --type open --context context:primary-signature build/KidSafe.dmg
  spctl --assess --type execute build/KidSafe.app
  echo "Signé et notarisé (équipe $TEAM)."
else
  echo "Signature ad hoc : macOS affichera l'avertissement « Ouvrir quand même »."
fi
echo "OK : build/KidSafe.dmg ($(du -h build/KidSafe.dmg | cut -f1), version $VERSION)"
shasum -a 256 build/KidSafe.dmg
