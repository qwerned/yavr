#!/bin/zsh
# Одноразовое создание самоподписанного сертификата «YAVR Dev Signing»
# в связке ключей. Нужен только тем, кто пересобирает YAVR: даёт стабильную
# подпись, чтобы macOS не считала каждую сборку новым приложением и не просила
# заново выдать разрешения. При первом использовании codesign macOS спросит
# доступ к ключу — нажать «Разрешить всегда».
set -euo pipefail

NAME="YAVR Dev Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Сертификат «$NAME» уже существует."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" << 'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = YAVR Dev Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"

openssl pkcs12 -export -out "$TMP/yavr.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:yavrdev

security import "$TMP/yavr.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P yavrdev \
    -T /usr/bin/codesign

# Trust only code signing in the current user's trust store.
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo "Импортирован. Проверка:"
security find-identity -v -p codesigning | grep "$NAME" || {
    echo "ВНИМАНИЕ: identity не видна (возможно, нужно доверие к сертификату)."
    exit 1
}
