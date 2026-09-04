#!/bin/sh
# RAMBar — desinstala tudo (idempotente).
set -euo pipefail

pkill -x RAMBar 2>/dev/null || true
rm -rf "$HOME/Applications/RAMBar.app" "/Applications/RAMBar.app"
rm -f "$HOME/Library/Preferences/com.voce.rambar.plist"
echo "removido."
