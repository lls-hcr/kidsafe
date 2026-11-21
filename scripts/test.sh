#!/bin/sh
# Lance les tests avec les seuls Command Line Tools (sans Xcode complet).
set -e
# --no-parallel : certains tests changent la langue (réglage global).
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$F/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test --build-system native -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" --no-parallel "$@"
fi
exec swift test --no-parallel "$@"
