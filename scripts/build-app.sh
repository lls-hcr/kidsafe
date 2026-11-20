#!/bin/sh
# Construit build/KidSafe.app (app de la barre de menus + CLI intégrée), signature ad hoc.
# Usage : scripts/build-app.sh [--universal]
set -eu
cd "$(dirname "$0")/.."
VERSION="0.1.0"
BUNDLE_ID="app.kidsafe.KidSafe"     # à remplacer par votre identifiant définitif
# Lien du bouton « Soutenir KidSafe » (Buy Me a Coffee, Ko-fi, PayPal, Liberapay…). KIDSAFE_DONATE_URL= (vide) masque le bouton.
DONATE_URL="${KIDSAFE_DONATE_URL-https://github.com/sponsors/lls-hcr}"
# Avis : page GitHub Issues (publique) et adresse e-mail (facultative).
ISSUES_URL="${KIDSAFE_ISSUES_URL-https://github.com/lls-hcr/kidsafe/issues/new}"
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
  mkdir -p "$OUT/$a"; cp "$P/KidSafe" "$P/kidsafe-blocklist" "$OUT/$a/"
  RES="$P/KidSafe_KidSafeCore.bundle"
done
for exe in KidSafe kidsafe-blocklist; do
  lipo -create $(for a in $ARCHS; do printf '%s ' "$OUT/$a/$exe"; done) -output "$OUT/$exe"
done
BIN="$OUT"

APP=build/KidSafe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN/KidSafe" "$APP/Contents/MacOS/KidSafe"
cp "$BIN/kidsafe-blocklist" "$APP/Contents/MacOS/kidsafe-blocklist"
# Ressources dans Contents/Resources (et non à la racine du .app) pour que la signature reste valide.
cp -R "$RES" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KidSafe</string>
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
  <key>KidSafeFeedbackEmail</key><string>$FEEDBACK_EMAIL</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/kidsafe-blocklist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "OK : $APP ($(lipo -archs "$APP/Contents/MacOS/KidSafe"))"
