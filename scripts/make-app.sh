#!/bin/zsh
# Сборка Vox.app из SPM-билда. Подпись ad-hoc (для раздачи без Developer ID).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="dist/YAVR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/Vox" "$APP/Contents/MacOS/Vox"
cp -R ".build/$CONFIG/Vox_Vox.bundle" "$APP/Contents/Resources/"
cp "design/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Vox</string>
    <key>CFBundleIdentifier</key>
    <string>com.denissobolev.vox</string>
    <key>CFBundleName</key>
    <string>YAVR</string>
    <key>CFBundleDisplayName</key>
    <string>YAVR</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>YAVR записывает голос только во время диктовки, распознавание идёт целиком на этом Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Использует FluidAudio (Apache 2.0) и NVIDIA Parakeet TDT 0.6b v3 (CC-BY-4.0).</string>
</dict>
</plist>
PLIST

# Подпись: стабильная identity «Vox Dev Signing» (TCC-разрешения переживают
# пересборки), fallback на ad-hoc, если сертификата нет (чужая машина).
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Vox Dev Signing"; then
    SIGN_ID="Vox Dev Signing"
fi
echo "Подпись: $SIGN_ID"
codesign --force --options runtime \
    --entitlements "scripts/vox.entitlements" \
    --sign "$SIGN_ID" "$APP"

echo "Готово: $APP"
