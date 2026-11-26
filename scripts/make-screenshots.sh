#!/bin/sh
# Régénère les captures d'écran du guide (FR et EN) avec des données de démonstration.
# L'app dessine ses propres vues hors écran : aucun réglage réel n'est touché, aucun Privoxy lancé.
# Résultat : Sources/KidSafeCore/Resources/shot-<langue>-<nom>.png (puis reconstruire l'app).
# Une vraie capture de l'app (shot-<langue>-<nom>.jpg, fenêtre complète) a priorité : la version générée n'est pas écrite.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh >/dev/null
TMP="$(mktemp -d)"
for L in fr en; do
  open -W -n --env KIDSAFE_SCREENSHOTS="$TMP/$L" --env KIDSAFE_LANG=$L --env KIDSAFE_SUPPORT_DIR="$TMP/support" \
       --env KIDSAFE_DEFAULTS_SUITE=app.kidsafe.screenshots build/Yamoxy.app
  for f in "$TMP/$L"/*.png; do
    out="Sources/KidSafeCore/Resources/shot-$L-$(basename "$f")"
    [ -f "${out%.png}.jpg" ] && continue
    # 1400 px maximum : net, sans alourdir le guide (jamais agrandie : sips -Z agrandit aussi).
    max=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {if ($2 > m) m = $2} END {print m}')
    if [ "$max" -gt 1400 ]; then sips -Z 1400 "$f" --out "$out" >/dev/null; else cp "$f" "$out"; fi
  done
done
defaults delete app.kidsafe.screenshots 2>/dev/null || true
rm -f ~/Library/Preferences/app.kidsafe.screenshots.plist
rm -rf "$TMP"
ls -la Sources/KidSafeCore/Resources/shot-*.* | awk '{s+=$5} END {printf "OK : %d captures, %.1f Mo\n", NR, s/1048576}'
