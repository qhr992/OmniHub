#!/bin/bash
# Creates a local, self-signed code-signing identity in its own keychain.
#
# Why: an ad-hoc signature is identified by the binary's hash, so every
# rebuild looks like a brand-new app to macOS and the Screen Recording /
# Accessibility grants stop applying. Signing with a fixed certificate keeps
# the app's identity ("com.local.omnihub" + this certificate) stable, so the
# permissions are granted once.
#
# The keychain lives under Application Support and holds nothing but this
# throwaway certificate; its password is not a secret.
set -euo pipefail

DIR="$HOME/Library/Application Support/OmniHub-signing"
KC="$DIR/omnihub-signing.keychain-db"
PW="omnihub-local"
NAME="OmniHub Local Signing"

mkdir -p "$DIR"
# A keychain left without its certificate (an import that failed earlier)
# would make every build fall back to ad-hoc: start it over.
if [ -f "$KC" ]; then
  security unlock-keychain -p "$PW" "$KC" 2>/dev/null || true
  if ! security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
    echo "setup-signing: $KC has no certificate, recreating it" >&2
    security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
  fi
fi
if [ ! -f "$KC" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$PW" -name "$NAME" >/dev/null 2>&1
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$PW" "$KC"
  if ! security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null; then
    echo "setup-signing: importing the certificate failed" >&2
    exit 1
  fi
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null 2>&1 || true
fi

# codesign only finds identities in keychains on the user's search list.
CURRENT="$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')"
if ! grep -qxF "$KC" <<<"$CURRENT"; then
  LIST=()
  while IFS= read -r line; do [ -n "$line" ] && LIST+=("$line"); done <<<"$CURRENT"
  security list-keychains -d user -s "${LIST[@]}" "$KC"
fi

security unlock-keychain -p "$PW" "$KC"
security find-identity -p codesigning "$KC" | awk -v n="$NAME" '$0 ~ n {print $2; exit}'
