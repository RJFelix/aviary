#!/usr/bin/env bash
# Create — or repair — the stable code-signing identity Aviary is built with.
#
# Safe to run repeatedly. It creates what is missing and fixes what is wrong, which matters
# because the two halves fail independently and the second one fails *silently*.
#
# WHY THIS EXISTS
#
# `codesign --sign -` (ad-hoc) produces no certificate, so macOS has nothing stable to
# identify the app by and derives its designated requirement from the code itself:
#
#     # designated => cdhash H"65480ad2c9b405e95d5a884ae24486ebb69ebd96"
#
# TCC stores that requirement alongside every permission you grant. Rebuild the app and the
# cdhash changes, the requirement stops matching, and macOS correctly concludes it has never
# seen this app before — so Screen Recording is asked for again, on every single build. System
# Settings still lists Aviary with its switch on, because the row is keyed by bundle identifier
# while the grant behind it is bound to a build that no longer exists. Nothing there can be
# toggled to fix it.
#
# With a certificate the requirement becomes identity-based instead:
#
#     # designated => identifier "works.duckbill.aviary" and certificate root = H"..."
#
# which survives every rebuild. One grant, once.
#
# WHAT THIS DOES TO YOUR MACHINE
#
#   1. Generates a self-signed certificate and key (2048-bit RSA, 10 years) whose only extended
#      key usage is code signing. Not a CA, cannot issue other certificates, not trusted for
#      TLS or anything on the network.
#   2. Imports both into your **login** keychain, authorised for /usr/bin/codesign.
#   3. Marks it trusted for code signing in your **user** trust settings — not the system
#      domain, so no sudo.
#   4. Adds codesign to the key's **partition list**. This is the step that is easy to miss and
#      the one that hurts: without it `codesign` does not fail, it blocks on a GUI password
#      dialog. Every build. And an unattended build — the workshop reload starts one — hangs
#      instead of failing, leaving a half-written `.cstemp` in the bundle that makes every
#      later signing attempt fail with "invalid or unsupported format for signature".
#      It needs your login-keychain password, which is why this script has to ask.
#
# Reversing it: delete "Aviary Local Signing" in Keychain Access. `bundle-app.sh` then falls
# back to ad-hoc and the re-prompting returns.
#
# Usage: scripts/make-signing-cert.sh
set -euo pipefail

NAME="Aviary Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- 1-3: the identity itself, if it is not already there ----------------------------------

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> '$NAME' already exists and is trusted for code signing."
else
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

    echo "==> Trusting it for code signing"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

    if ! security find-identity -v -p codesigning | grep -qF "$NAME"; then
        echo "The identity imported but is not valid for code signing." >&2
        echo "Open Keychain Access, find '$NAME', set 'Code Signing' to 'Always Trust'." >&2
        exit 1
    fi
fi
security find-identity -v -p codesigning | grep -F "$NAME"

# --- 4: the partition list ------------------------------------------------------------------

# Attempted every run, not only on creation. An identity can be perfectly valid here and still
# demand a dialog for every signature — which looks completely healthy and hangs the next
# build. `-A` on the import above is not a substitute: that ACL predates partition lists and
# macOS consults both.
signs_without_prompting() {
    cp /usr/bin/true "$WORK/probe"
    ( codesign --force --sign "$NAME" --identifier works.duckbill.probe "$WORK/probe" \
        >/dev/null 2>&1 ) &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge 40 ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 0.25
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null || return 1
    codesign -d -r- "$WORK/probe" 2>&1 | grep -q "certificate"
}

echo "==> Checking whether signing needs a dialog"
if signs_without_prompting; then
    echo "    It does not. Nothing to authorise."
else
    echo "    It does. Authorising codesign to use the key."
    echo "    This needs your login-keychain password — the one you log in with."
    printf "    Password: "
    read -rs KEYCHAIN_PASSWORD
    echo ""
    if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
        unset KEYCHAIN_PASSWORD
        echo "    FAILED — wrong password, or the keychain is locked." >&2
        echo "    Alternatively: run a build, and when the dialog appears choose" >&2
        echo "    'Always Allow' rather than 'Allow'." >&2
        exit 1
    fi
    unset KEYCHAIN_PASSWORD
    echo "==> Re-checking"
    if signs_without_prompting; then
        echo "    Signs with no prompt now, and names the certificate."
    else
        echo "    Still blocking. If a dialog is on screen, answer it with 'Always Allow'." >&2
        exit 1
    fi
fi

echo ""
echo "Done. Now rebuild and clear the stale grant:"
echo "    just build"
echo "    tccutil reset ScreenCapture works.duckbill.aviary"
echo ""
echo "Aviary will ask for Screen Recording once more — that grant will stick."
