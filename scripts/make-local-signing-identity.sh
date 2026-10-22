#!/usr/bin/env bash
# Creates "Uncloud Local Signing", a self-signed code-signing certificate in your login keychain, for test builds:
#   scripts/make-dmg.sh --identity "Uncloud Local Signing" --account-mode live
# Builds signed with the same certificate look like the same app to macOS, so the keychain stops asking
# "Uncloud wants to use your confidential information" after every update. It's only trusted on this Mac;
# releases for other people still need a Developer ID. Run it once; it does nothing if the identity exists.
set -euo pipefail
NAME="Uncloud Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi
OPENSSL=/opt/homebrew/opt/openssl@4/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
[ -x "$OPENSSL" ] || { echo "error: needs Homebrew OpenSSL (brew install openssl)" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/cfg" <<CFG
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
CFG
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -config "$WORK/cfg" 2>/dev/null
PASS="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)"
"$OPENSSL" pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Build with: scripts/make-dmg.sh --identity \"$NAME\" --account-mode live"
