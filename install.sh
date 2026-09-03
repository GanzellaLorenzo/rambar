#!/bin/sh
# RAMBar — instala em ~/Applications e abre.
# Login automático (robusto no Sequoia, sem plist manual):
#   System Settings > General > Login Items > + > RAMBar
# (launchctl bootstrap/load falha com erro 5 em sessões sem domínio gui;
#  Login Items via Settings usa o SMAppService moderno e é o caminho oficial.)
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="RAMBar.app"
DEST="$HOME/Applications/RAMBar.app"

[ -d "$APP_SRC" ] || { echo "erro: rode ./build.sh primeiro"; exit 1; }
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP_SRC" "$DEST"
codesign -s - -f "$DEST" >/dev/null 2>&1 || true

open "$DEST"
echo "instalado e aberto: $DEST"
echo "para iniciar no login: System Settings > General > Login Items > + > RAMBar"
