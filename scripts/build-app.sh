#!/bin/sh
# Construit build/KidSafe.app (app de la barre de menus + CLI + Privoxy intégré)
# et build/Uninstall KidSafe.app (désinstalleur fourni dans le .dmg), signature ad hoc.
# Usage : scripts/build-app.sh [--universal]
set -eu
cd "$(dirname "$0")/.."
VERSION="0.3.2"
BUNDLE_ID="app.kidsafe.KidSafe"     # à remplacer par votre identifiant définitif
# Lien du bouton « Soutenir KidSafe » (Buy Me a Coffee, Ko-fi, PayPal, Liberapay…). KIDSAFE_DONATE_URL= (vide) masque le bouton.
DONATE_URL="${KIDSAFE_DONATE_URL-https://github.com/sponsors/lls-hcr}"
# Avis : page GitHub Issues (publique) et adresse e-mail (facultative).
ISSUES_URL="${KIDSAFE_ISSUES_URL-https://github.com/lls-hcr/kidsafe/issues/new}"
# Liens du menu : page du projet et code source.
WEBSITE_URL="${KIDSAFE_WEBSITE_URL-https://mizuki.ch/documentation/kidsafe/}"
SOURCE_URL="${KIDSAFE_SOURCE_URL-https://github.com/lls-hcr/kidsafe}"
# Recherche de nouvelles versions : dernière release GitHub. Vide : fonction masquée.
UPDATE_API="${KIDSAFE_UPDATE_API-https://api.github.com/repos/lls-hcr/kidsafe/releases/latest}"
# Réglages personnels non publiés (ex. KIDSAFE_FEEDBACK_EMAIL) : scripts/local.env, ignoré par git.
[ -f scripts/local.env ] && . scripts/local.env
FEEDBACK_EMAIL="${KIDSAFE_FEEDBACK_EMAIL:-}"

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
  [ -x "$P/KidSafe" ] || { echo "Échec de la compilation ($a)" >&2; exit 1; }
  mkdir -p "$OUT/$a"; cp "$P/KidSafe" "$P/kidsafe-blocklist" "$P/KidSafeUninstaller" "$OUT/$a/"
  RES="$P/KidSafe_KidSafeCore.bundle"
done
for exe in KidSafe kidsafe-blocklist KidSafeUninstaller; do
  lipo -create $(for a in $ARCHS; do printf '%s ' "$OUT/$a/$exe"; done) -output "$OUT/$exe"
done
BIN="$OUT"

# Privoxy compilé depuis ses sources (universel), voir scripts/build-privoxy.sh.
scripts/build-privoxy.sh

APP=build/KidSafe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN/KidSafe" "$APP/Contents/MacOS/KidSafe"
cp "$BIN/kidsafe-blocklist" "$APP/Contents/MacOS/kidsafe-blocklist"
# Ressources dans Contents/Resources (et non à la racine du .app) pour que la signature reste valide.
cp -R "$RES" "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # dessinée par scripts/make-icon.swift
mkdir -p "$APP/Contents/Helpers"
cp build/privoxy/privoxy "$APP/Contents/Helpers/privoxy"
cp -R build/privoxy/conf "$APP/Contents/Resources/privoxy-conf"
cp build/privoxy/VERSION "$APP/Contents/Resources/privoxy-conf/VERSION"
cp build/privoxy/LICENSE-privoxy.txt "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KidSafe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>KidSafe</string>
  <key>CFBundleDisplayName</key><string>KidSafe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>KidSafe</string>
  <key>KidSafeDonateURL</key><string>$DONATE_URL</string>
  <key>KidSafeIssuesURL</key><string>$ISSUES_URL</string>
  <key>KidSafeWebsiteURL</key><string>$WEBSITE_URL</string>
  <key>KidSafeSourceURL</key><string>$SOURCE_URL</string>
  <key>KidSafeUpdateAPI</key><string>$UPDATE_API</string>
  <key>KidSafeFeedbackEmail</key><string>$FEEDBACK_EMAIL</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/privoxy"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/kidsafe-blocklist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "OK : $APP ($(lipo -archs "$APP/Contents/MacOS/KidSafe"), Privoxy $(cat build/privoxy/VERSION))"

# Désinstalleur : nom anglais dans le Finder, « Désinstaller KidSafe » en français.
UNI="build/Uninstall KidSafe.app"
rm -rf "$UNI"
mkdir -p "$UNI/Contents/MacOS" "$UNI/Contents/Resources/fr.lproj" "$UNI/Contents/Resources/en.lproj"
cp "$BIN/KidSafeUninstaller" "$UNI/Contents/MacOS/KidSafeUninstaller"
cp -R "$RES" "$UNI/Contents/Resources/"
cp Resources/AppIcon.icns "$UNI/Contents/Resources/AppIcon.icns"
printf '"CFBundleDisplayName" = "Désinstaller KidSafe";\n"CFBundleName" = "Désinstaller KidSafe";\n' > "$UNI/Contents/Resources/fr.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "Uninstall KidSafe";\n"CFBundleName" = "Uninstall KidSafe";\n' > "$UNI/Contents/Resources/en.lproj/InfoPlist.strings"
cat > "$UNI/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KidSafeUninstaller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Uninstaller</string>
  <key>CFBundleName</key><string>Uninstall KidSafe</string>
  <key>CFBundleDisplayName</key><string>Uninstall KidSafe</string>
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
codesign --force --sign - --timestamp=none "$UNI"
codesign --verify --strict "$UNI" && echo "OK : $UNI"
