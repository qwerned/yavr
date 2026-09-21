#!/bin/zsh
# Сборка YAVR.app со стабильной локальной подписью YAVR Dev Signing.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift package resolve
python3 scripts/prepare-resource-bundles.py
swift build --build-system native -c "$CONFIG"

APP="dist/YAVR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/YAVR" "$APP/Contents/MacOS/YAVR"
# Include resource bundles from WhisperKit's tokenizer dependencies as well.
for bundle in YAVR_YAVR.bundle swift-transformers_Hub.bundle swift-crypto_Crypto.bundle; do
    cp -R ".build/$CONFIG/$bundle" "$APP/Contents/Resources/"
done
cp "design/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>YAVR</string>
    <key>CFBundleIdentifier</key>
    <string>com.yavr.app</string>
    <key>CFBundleName</key>
    <string>YAVR</string>
    <key>CFBundleDisplayName</key>
    <string>YAVR</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.6</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>YAVR записывает голос только во время диктовки, распознавание идёт целиком на этом Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Использует FluidAudio (Apache 2.0), NVIDIA Parakeet TDT 0.6b v3 (CC-BY-4.0), WhisperKit и OpenAI Whisper (MIT).</string>
</dict>
</plist>
PLIST

# Подпись. Самоподписанная identity «YAVR Dev Signing» (scripts/make-signing-cert.sh)
# нужна только при частых пересборках: у ad-hoc подписи меняется хеш, и macOS
# считает каждую сборку новым приложением — разрешения (микрофон, Универсальный
# доступ) приходится выдавать заново. Разрешения в любом случае выдаются самому
# YAVR: bundle id, имя и подпись принадлежат этому приложению и ничему больше.
SIGN_ID="YAVR Dev Signing"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    echo "Нужен сертификат $SIGN_ID: запустите ./scripts/make-signing-cert.sh"
    exit 1
fi
echo "Подпись: $SIGN_ID"
codesign --force --options runtime \
    --entitlements "scripts/yavr.entitlements" \
    --sign "$SIGN_ID" "$APP"

"$APP/Contents/MacOS/YAVR" --check-installation
codesign --verify --deep --strict "$APP"
echo "Готово: $APP"
