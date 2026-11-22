#!/bin/sh
# Compile Privoxy (universel Apple Silicon + Intel) avec PCRE2 intégré en statique,
# pour l'embarquer dans KidSafe.app : aucune dépendance à Homebrew chez l'utilisateur.
# Résultat : build/privoxy/privoxy (binaire) et build/privoxy/conf/ (fichiers par défaut).
# Outils nécessaires sur la machine de construction : autoconf (brew install autoconf).
set -eu
cd "$(dirname "$0")/.."
PRIVOXY_VERSION=4.2.0
PRIVOXY_SHA=6f91267f81f626c416994db89ab62f4d09246eebf4754b81186e13a18ee9028f
PRIVOXY_URL="https://downloads.sourceforge.net/project/ijbswa/Sources/${PRIVOXY_VERSION}%20%28stable%29/privoxy-${PRIVOXY_VERSION}-stable-src.tar.gz"
PCRE2_VERSION=10.49
PCRE2_SHA=53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2"
MIN_MACOS=14.0

OUT=build/privoxy
WORK=build/privoxy-work
SRC=build/privoxy-src
mkdir -p "$SRC"
[ -n "${FORCE:-}" ] && rm -rf "$OUT"
if [ -x "$OUT/privoxy" ] && [ -f "$OUT/VERSION" ] && [ "$(cat "$OUT/VERSION")" = "$PRIVOXY_VERSION" ]; then
  echo "OK : $OUT déjà construit (Privoxy $PRIVOXY_VERSION)"; exit 0
fi
command -v autoconf >/dev/null || { echo "autoconf manquant : brew install autoconf" >&2; exit 1; }

fetch() {  # url fichier sha256
  [ -f "$2" ] || curl -sSfL --retry 3 -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c - >/dev/null || { echo "Empreinte incorrecte : $2" >&2; rm -f "$2"; exit 1; }
}
fetch "$PRIVOXY_URL" "$SRC/privoxy-$PRIVOXY_VERSION.tar.gz" "$PRIVOXY_SHA"
fetch "$PCRE2_URL" "$SRC/pcre2-$PCRE2_VERSION.tar.bz2" "$PCRE2_SHA"

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT/conf"
JOBS=$(sysctl -n hw.ncpu)
for ARCH in arm64 x86_64; do
  echo "== $ARCH"
  D="$PWD/$WORK/$ARCH"; mkdir -p "$D"
  CC="clang -arch $ARCH -mmacosx-version-min=$MIN_MACOS"
  HOST="$( [ $ARCH = arm64 ] && echo aarch64 || echo x86_64 )-apple-darwin"

  tar -xjf "$SRC/pcre2-$PCRE2_VERSION.tar.bz2" -C "$D"
  ( cd "$D/pcre2-$PCRE2_VERSION" && ./configure -q --host="$HOST" CC="$CC" --prefix="$D/pcre2" \
      --disable-shared --enable-static --disable-pcre2grep-libz --disable-pcre2grep-libbz2 >/dev/null \
    && make -s -j"$JOBS" >/dev/null 2>&1 && make -s install >/dev/null )

  tar -xzf "$SRC/privoxy-$PRIVOXY_VERSION.tar.gz" -C "$D"
  P="$D/privoxy-$PRIVOXY_VERSION-stable"
  ( cd "$P" && autoheader >/dev/null 2>&1 && autoconf >/dev/null 2>&1 \
    && ./configure -q --host="$HOST" CC="$CC" CPPFLAGS="-I$D/pcre2/include" LDFLAGS="-L$D/pcre2/lib" \
         --disable-dynamic-pcre --with-docbook=no --without-openssl --without-mbedtls >/dev/null \
    && make -s -j"$JOBS" >/dev/null 2>&1 )
  [ -x "$P/privoxy" ] || { echo "Échec de la compilation de Privoxy ($ARCH)" >&2; exit 1; }
  cp "$P/privoxy" "$WORK/privoxy-$ARCH"
done

lipo -create "$WORK/privoxy-arm64" "$WORK/privoxy-x86_64" -output "$OUT/privoxy"
P="$WORK/arm64/privoxy-$PRIVOXY_VERSION-stable"
cp "$P"/config "$P"/match-all.action "$P"/default.action "$P"/user.action "$P"/default.filter "$P"/user.filter "$P"/trust "$OUT/conf/"
cp -R "$P/templates" "$OUT/conf/templates"
cp "$P/LICENSE" "$OUT/LICENSE-privoxy.txt" 2>/dev/null || cp "$P/LICENSE.GPLv3" "$OUT/LICENSE-privoxy.txt" 2>/dev/null || true
# Licence BSD de PCRE2, intégrée en statique dans Privoxy : son texte doit accompagner l'app.
for f in "$WORK/arm64/pcre2-$PCRE2_VERSION"/LICENCE*; do [ -f "$f" ] && cp "$f" "$OUT/LICENSE-pcre2.txt" && break; done
echo "$PRIVOXY_VERSION" > "$OUT/VERSION"
rm -rf "$WORK"
echo "OK : $OUT/privoxy ($(lipo -archs "$OUT/privoxy")), Privoxy $PRIVOXY_VERSION + PCRE2 $PCRE2_VERSION"
otool -L "$OUT/privoxy" | tail -n +2
