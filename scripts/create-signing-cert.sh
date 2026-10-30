#!/bin/bash
# Creates a self-signed code-signing identity for Boo and imports it into the
# login keychain. macOS ties privacy grants (Full Disk Access, Documents,
# Automation, ...) to the app's designated requirement; ad-hoc builds pin it to
# the cdhash, which changes every build, so every update re-prompts. A signing
# certificate pins it to the certificate instead, which stays the same.
#
# Usage: scripts/create-signing-cert.sh [name]
# Writes the .p12 and its password to ~/.boo/signing for the CI secrets.
set -euo pipefail

NAME="${1:-Boo Self-Signed}"
OUT="${BOO_SIGNING_DIR:-$HOME/.boo/signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "==> Identity \"$NAME\" already in the keychain"
  if [ ! -f "$OUT/boo-signing.p12" ]; then
    echo "    (no $OUT/boo-signing.p12 to print secrets from; delete the identity to recreate)"
    exit 0
  fi
else
  mkdir -p "$OUT"
  chmod 700 "$OUT"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

  # 20 years: renewing changes the certificate hash, which resets grants once.
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

  PASSWORD="$(openssl rand -hex 24)"
  # OpenSSL 3 needs -legacy for a .p12 that `security import` reads; LibreSSL lacks the flag.
  if ! openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$OUT/boo-signing.p12" -passout "pass:$PASSWORD" 2>/dev/null; then
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
      -name "$NAME" -out "$OUT/boo-signing.p12" -passout "pass:$PASSWORD"
  fi
  printf '%s' "$PASSWORD" > "$OUT/boo-signing.password"
  chmod 600 "$OUT/boo-signing.p12" "$OUT/boo-signing.password"

  security import "$OUT/boo-signing.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  echo "==> Imported \"$NAME\" into the login keychain"
fi

echo
echo "make run now signs with \"$NAME\". For release builds, set the CI secrets:"
echo
echo "  base64 -i \"$OUT/boo-signing.p12\" | gh secret set APPLE_CERTIFICATE_P12_BASE64"
echo "  gh secret set APPLE_CERTIFICATE_PASSWORD < \"$OUT/boo-signing.password\""
echo "  gh secret set SIGNING_IDENTITY --body \"$NAME\""
echo
echo "Keep $OUT backed up: a new certificate resets every user's grants once."
