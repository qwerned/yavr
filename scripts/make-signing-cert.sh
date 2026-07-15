#!/bin/zsh
# Одноразовое создание самоподписанного сертификата «Vox Dev Signing»
# в связке ключей. Даёт стабильную идентичность подписи: TCC-разрешения
# переживают пересборки. При первом использовании codesign macOS спросит
# доступ к ключу — нажать «Разрешить всегда».
set -euo pipefail

NAME="Vox Dev Signing"

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
CN = Vox Dev Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"

openssl pkcs12 -export -out "$TMP/vox.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:voxdev

security import "$TMP/vox.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P voxdev \
    -T /usr/bin/codesign

echo "Импортирован. Проверка:"
security find-identity -v -p codesigning | grep "$NAME" || {
    echo "ВНИМАНИЕ: identity не видна (возможно, нужно доверие к сертификату)."
    exit 1
}
