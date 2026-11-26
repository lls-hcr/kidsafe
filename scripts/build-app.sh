#!/bin/sh
# Construit build/Yamoxy.app (app de la barre de menus + CLI + Privoxy intégré)
# et build/Uninstall Yamoxy.app (désinstalleur fourni dans le .dmg).
# Signature : Developer ID si un certificat « Developer ID Application » est dans le trousseau
# (ou KIDSAFE_SIGN_IDENTITY), sinon ad hoc. KIDSAFE_SIGN_IDENTITY=- force la signature ad hoc.
# Usage : scripts/build-app.sh [--universal]
set -eu
cd "$(dirname "$0")/.."
VERSION="0.9.0"
# Étiquette affichée après la version (« Yamoxy 0.9.0 (beta) ») ; vide pour une version finale.
RELEASE_LABEL="${KIDSAFE_RELEASE_LABEL-beta}"
BUNDLE_ID="app.kidsafe.KidSafe"     # identifiant d'origine (KidSafe), gardé : réglages, ouverture au démarrage, mises à jour
# Lien du bouton « Soutenir Yamoxy » (Buy Me a Coffee, Ko-fi, PayPal, Liberapay…). KIDSAFE_DONATE_URL= (vide) masque le bouton.
DONATE_URL="${KIDSAFE_DONATE_URL-https://github.com/sponsors/lls-hcr}"
# Avis : page GitHub Issues (publique) et adresse e-mail (facultative).
ISSUES_URL="${KIDSAFE_ISSUES_URL-https://github.com/lls-hcr/yamoxy/issues/new}"
# Liens du menu : page du projet et code source.
WEBSITE_URL="${KIDSAFE_WEBSITE_URL-https://mizuki.ch/documentation/yamoxy/}"
SOURCE_URL="${KIDSAFE_SOURCE_URL-https://github.com/lls-hcr/yamoxy}"
# Recherche de nouvelles versions : dernière release GitHub. Vide : fonction masquée.
UPDATE_API="${KIDSAFE_UPDATE_API-https://api.github.com/repos/lls-hcr/yamoxy/releases/latest}"
# Réglages personnels non publiés (ex. KIDSAFE_FEEDBACK_EMAIL) : scripts/local.env, ignoré par git.
[ -f scripts/local.env ] && . scripts/local.env
FEEDBACK_EMAIL="${KIDSAFE_FEEDBACK_EMAIL:-}"

# Identité de signature. Developer ID : « hardened runtime » et horodatage Apple, exigés pour la notarisation.
SIGN_ID="${KIDSAFE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Developer ID Application'; then
  SIGN_ID="Developer ID Application"
fi
[ -n "$SIGN_ID" ] || SIGN_ID="-"
sign() {
  if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - --timestamp=none ${KIDSAFE_HARDENED:+--options runtime} "$@"
  else
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$@"
  fi
}

# Une compilation par architecture, puis fusion avec lipo (la compilation multi-arch
# en une passe passe par un système de build qui échoue avec les seuls Command Line Tools).
ARCHS="$(uname -m)"
[ "${1:-}" = "--universal" ] && ARCHS="arm64 x86_64"
OUT=build/bin; rm -rf "$OUT"; mkdir -p "$OUT"
for a in $ARCHS; do
  if ! swift build -c release --build-system native --triple "$a-apple-macosx14.0" > "$OUT/build-$a.log" 2>&1; then
    grep -E 'error' "$OUT/build-$a.log" | sort -u >&2; echo "Échec de la compilation ($a)" >&2; exit 1
  fi
  P="$(swift build -c release --build-system native --triple "$a-apple-macosx14.0" --show-bin-path 2>/dev/null | tail -1)"
  [ -x "$P/Yamoxy" ] || { echo "Échec de la compilation ($a)" >&2; exit 1; }
  mkdir -p "$OUT/$a"; cp "$P/Yamoxy" "$P/yamoxy-blocklist" "$P/YamoxyUninstaller" "$OUT/$a/"
  RES="$P/KidSafe_KidSafeCore.bundle"
done
for exe in Yamoxy yamoxy-blocklist YamoxyUninstaller; do
  lipo -create $(for a in $ARCHS; do printf '%s ' "$OUT/$a/$exe"; done) -output "$OUT/$exe"
done
BIN="$OUT"

# Privoxy compilé depuis ses sources (universel), voir scripts/build-privoxy.sh.
scripts/build-privoxy.sh

APP=build/Yamoxy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN/Yamoxy" "$APP/Contents/MacOS/Yamoxy"
cp "$BIN/yamoxy-blocklist" "$APP/Contents/MacOS/yamoxy-blocklist"
# Ressources dans Contents/Resources (et non à la racine du .app) pour que la signature reste valide.
cp -R "$RES" "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # dessinée par scripts/make-icon.swift
mkdir -p "$APP/Contents/Helpers"
cp build/privoxy/privoxy "$APP/Contents/Helpers/privoxy"
cp -R build/privoxy/conf "$APP/Contents/Resources/privoxy-conf"
cp build/privoxy/VERSION "$APP/Contents/Resources/privoxy-conf/VERSION"
cp build/privoxy/LICENSE-privoxy.txt "$APP/Contents/Resources/" 2>/dev/null || true
cp build/privoxy/LICENSE-pcre2.txt "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Yamoxy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Yamoxy</string>
  <key>CFBundleDisplayName</key><string>Yamoxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>yamoxy</string><string>kidsafe</string></array>
  </dict></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Yamoxy</string>
  <key>KidSafeDonateURL</key><string>$DONATE_URL</string>
  <key>KidSafeIssuesURL</key><string>$ISSUES_URL</string>
  <key>KidSafeWebsiteURL</key><string>$WEBSITE_URL</string>
  <key>KidSafeSourceURL</key><string>$SOURCE_URL</string>
  <key>KidSafeUpdateAPI</key><string>$UPDATE_API</string>
  <key>KidSafeReleaseLabel</key><string>$RELEASE_LABEL</string>
  <key>KidSafeFeedbackEmail</key><string>$FEEDBACK_EMAIL</string>
</dict>
</plist>
PLIST

# Du plus profond au plus haut : outils intégrés, puis l'app.
sign "$APP/Contents/Helpers/privoxy"
sign "$APP/Contents/MacOS/yamoxy-blocklist"
sign "$APP"
codesign --verify --strict --deep "$APP"
SIGNED_BY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "OK : $APP ($(lipo -archs "$APP/Contents/MacOS/Yamoxy"), Privoxy $(cat build/privoxy/VERSION), signature : ${SIGNED_BY:-ad hoc})"

# Désinstalleur : nom anglais dans le Finder, « Désinstaller Yamoxy » en français.
UNI="build/Uninstall Yamoxy.app"
rm -rf "$UNI"
mkdir -p "$UNI/Contents/MacOS" "$UNI/Contents/Resources/fr.lproj" "$UNI/Contents/Resources/en.lproj"
cp "$BIN/YamoxyUninstaller" "$UNI/Contents/MacOS/YamoxyUninstaller"
cp -R "$RES" "$UNI/Contents/Resources/"
# Le désinstalleur n'a besoin que des traductions : pas des captures ni du guide.
find "$UNI/Contents/Resources/KidSafe_KidSafeCore.bundle" \( -name 'shot-*.png' -o -name 'guide-*.html' \) -delete
cp Resources/AppIcon.icns "$UNI/Contents/Resources/AppIcon.icns"
printf '"CFBundleDisplayName" = "Désinstaller Yamoxy";\n"CFBundleName" = "Désinstaller Yamoxy";\n' > "$UNI/Contents/Resources/fr.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "Uninstall Yamoxy";\n"CFBundleName" = "Uninstall Yamoxy";\n' > "$UNI/Contents/Resources/en.lproj/InfoPlist.strings"
cat > "$UNI/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>YamoxyUninstaller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Uninstaller</string>
  <key>CFBundleName</key><string>Uninstall Yamoxy</string>
  <key>CFBundleDisplayName</key><string>Uninstall Yamoxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
sign "$UNI"
codesign --verify --strict "$UNI" && echo "OK : $UNI"
