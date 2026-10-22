#!/bin/bash
# One-time setup: gives Scuba a fixed signature, so macOS keeps its
# permissions (Accessibility, Screen Recording) across rebuilds.
# It makes a private "Scuba Local" signing certificate in your login keychain.
# macOS will ask for your password once, to trust it for code signing.
set -e
cd "$(dirname "$0")/.."
NAME="Scuba Local"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "The \"$NAME\" certificate already exists."
else
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/scuba.p12" -passout pass:scuba
  security import "$TMP/scuba.p12" -k "$KC" -P scuba -T /usr/bin/codesign
  echo "Trusting it for code signing (macOS asks for your password)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"
  rm -rf "$TMP"
  echo "Made the \"$NAME\" certificate."
fi

echo "Rebuilding Scuba with it…"
osascript -e 'quit app "Scuba"' 2>/dev/null || true
sleep 1
./build.sh
open build/Scuba.app
echo ""
echo "Done. Grant Accessibility and Screen Recording one last time when asked."
echo "From now on, rebuilds keep them."
