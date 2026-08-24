#!/usr/bin/env bash
# Create the stable code-signing identity Aviary is built with.
#
# WHY THIS EXISTS
#
# `codesign --sign -` (ad-hoc) produces no certificate, so macOS has nothing stable to
# identify the app by and derives its designated requirement from the *code itself*:
#
#     # designated => cdhash H"65480ad2c9b405e95d5a884ae24486ebb69ebd96"
#
# TCC stores that requirement alongside every permission you grant. Rebuild the app and the
# cdhash changes, the stored requirement stops matching, and macOS correctly concludes it has
# never seen this app before — so Screen Recording is asked for again, on every single build.
# System Settings still lists Aviary with its switch on, because the row is keyed by bundle
# identifier while the grant behind it is bound to a build that no longer exists. Nothing there
# can be toggled to fix it.
#
# With a certificate, the requirement becomes identity-based instead:
#
#     # designated => identifier "works.duckbill.aviary" and certificate leaf = H"..."
#
# which survives every rebuild. One grant, once.
#
# WHAT THIS DOES TO YOUR MACHINE
#
#   1. Generates a self-signed certificate and private key (2048-bit RSA, 10 years) whose only
#      extended key usage is code signing. It can sign code and nothing else — it is not a CA,
#      cannot issue other certificates, and is not trusted for TLS or anything on the network.
#   2. Imports both into your **login** keychain, authorised for /usr/bin/codesign.
#   3. Marks it trusted for code signing in your **user** trust settings — not the system
#      domain, so this needs no sudo. macOS will ask for your login password once.
#
# Reversing it: delete "Aviary Local Signing" in Keychain Access. `bundle-app.sh` then falls
# back to ad-hoc signing and the re-prompting returns.
#
# Usage: scripts/make-signing-cert.sh
set -euo pipefail

NAME="Aviary Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> '$NAME' already exists and is valid for code signing. Nothing to do."
    security find-identity -v -p codesigning | grep -F "$NAME"
    exit 0
fi

# The private key lives in this directory for a few seconds. Removed on every exit path,
# including failure — a code-signing key left in /tmp is worse than no signing at all.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=Duckbill/C=US" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# Apple's Security framework cannot read OpenSSL 3's default PKCS#12 encryption
# (AES-256-CBC / SHA-256): the import fails with "MAC verification failed during PKCS12
# import (wrong password?)", which reads like a typo and is not one. The legacy algorithms
# below are what `security import` understands.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -passout "pass:$PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into your login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -A

# Without this, every signing run pops a "codesign wants to use your confidential
# information" dialog — the key is in the keychain but no tool is on its partition list.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    echo "    (could not set the partition list; codesign may prompt for your password)"

echo "==> Trusting it for code signing (macOS will ask for your login password)"
# User domain, not system: no sudo, and the setting applies to you alone. `-p codeSign`
# narrows the trust to exactly one purpose — this certificate is not trusted for TLS,
# S/MIME, or anything else.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> Verifying"
if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    security find-identity -v -p codesigning | grep -F "$NAME"
    echo ""
    echo "Done. Now rebuild and clear the stale grant:"
    echo "    just build"
    echo "    tccutil reset ScreenCapture works.duckbill.aviary"
    echo ""
    echo "Aviary will ask for Screen Recording once more — that grant will stick."
else
    echo "The identity imported but is not valid for code signing yet." >&2
    echo "Open Keychain Access, find '$NAME', and set 'Code Signing' to 'Always Trust'." >&2
    exit 1
fi
