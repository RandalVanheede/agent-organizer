#!/bin/sh
# Creates and trusts a self-signed code-signing identity named
# "Agent Organizer Dev" in the login keychain (idempotent). Needed so the
# app's signature is stable across rebuilds — macOS refuses notifications
# to ad-hoc-signed apps and forgets permissions when the signature changes.
# You may be asked for your login password once (trust settings).
set -eu
NAME="Agent Organizer Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already present and valid."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME/O=Agent Organizer" \
  -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature" -addext "basicConstraints=CA:false" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:ao -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:ao -name "$NAME"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P ao -T /usr/bin/codesign -T /usr/bin/security -A
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "Identity ready. Rebuild with: make bundle"
