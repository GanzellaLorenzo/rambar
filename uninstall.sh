#!/bin/sh
# RAMBar — desinstala tudo (idempotente). bootout ANTES do rm (senão relança).
set -euo pipefail
LABEL="com.voce.rambar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x RAMBar 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/RAMBar.app" "/Applications/RAMBar.app"
rm -f "$HOME/Library/Preferences/$LABEL.plist"
echo "removido."
