#!/bin/sh
# RAMBar — build single-file, zero deps.
# Uso: ./build.sh [--run]
set -euo pipefail

cd "$(dirname "$0")"

command -v xcrun >/dev/null || { echo "erro: Xcode Command Line Tools ausente (xcode-select --install)"; exit 1; }
command -v swiftc >/dev/null || { echo "erro: swiftc não encontrado"; exit 1; }
SDK="$(xcrun --show-sdk-path)"
echo "SDK: $SDK"
swiftc --version

APP="RAMBar.app"
BIN="$APP/Contents/MacOS/RAMBar"
DEPLOYMENT_TARGET="13.0"

rm -rf "$APP" RAMBar-arm64 RAMBar-x86_64 RAMBar

echo "==> compilando arm64…"
swiftc -Osize -whole-module-optimization \
  -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos13 \
  -sdk "$SDK" \
  main.swift -framework AppKit -o RAMBar-arm64

echo "==> compilando x86_64…"
swiftc -Osize -whole-module-optimization \
  -swift-version 6 -strict-concurrency=complete \
  -target x86_64-apple-macos13 \
  -sdk "$SDK" \
  main.swift -framework AppKit -o RAMBar-x86_64

echo "==> lipo universal…"
lipo -create RAMBar-arm64 RAMBar-x86_64 -output RAMBar
rm -f RAMBar-arm64 RAMBar-x86_64
strip -x RAMBar || true
lipo -archs RAMBar
ls -lh RAMBar

echo "==> montando bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp RAMBar "$BIN"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.voce.rambar</string>
  <key>CFBundleName</key><string>RAMBar</string>
  <key>CFBundleExecutable</key><string>RAMBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> assinatura ad-hoc (roda local; distribuir exige Developer ID)…"
codesign -s - -f "$APP"
codesign -dvv "$APP" 2>&1 | head -8
codesign --verify --deep --strict --verbose=2 "$APP"

echo "OK: $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--run" ]; then
  echo "==> abrindo…"
  open "$APP"
fi
