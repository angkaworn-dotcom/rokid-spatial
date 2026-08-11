#!/bin/bash
# Create a local self-signed code-signing identity, once.
#
# Why this exists: an ad-hoc signature's designated requirement is the code's
# own hash, so every rebuild produces what macOS considers a different app and
# Screen Recording consent has to be granted all over again. Signing with a
# certificate changes the requirement to bundle identifier + certificate, both
# of which survive rebuilds, so the permission is granted once and stays.
#
# What this touches: it adds one private key and one certificate to your login
# keychain. Access is restricted to /usr/bin/codesign — not to all
# applications. Nothing leaves the machine; the certificate is self-signed and
# is not trusted for anything beyond signing this project locally.
#
# To undo:
#   security delete-identity -c "RokidSpatial Dev" ~/Library/Keychains/login.keychain-db

set -euo pipefail

IDENTITY="RokidSpatial Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if security find-certificate -c "${IDENTITY}" >/dev/null 2>&1; then
    echo "'${IDENTITY}' already exists — nothing to do."
    exit 0
fi

echo "› generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=${IDENTITY}/O=RokidSpatial/C=TH" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Apple's Security framework cannot verify the MAC on a PKCS#12 written by
# OpenSSL 3 with its modern defaults — the import fails with "MAC verification
# failed (wrong password?)", which is misleading, as the password is fine. The
# system LibreSSL writes a container macOS accepts.
echo "› packaging with the system LibreSSL for macOS compatibility"
/usr/bin/openssl pkcs12 -export \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -out "${WORK}/identity.p12" \
    -passout pass:rokidspatial -name "${IDENTITY}" 2>/dev/null

echo "› importing into the login keychain, codesign-only access"
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" \
    -P rokidspatial -T /usr/bin/codesign

HASH="$(security find-certificate -c "${IDENTITY}" -Z 2>/dev/null \
        | awk '/SHA-1 hash:/ {print $3; exit}')"

echo
echo "done — identity '${IDENTITY}' (SHA-1 ${HASH})"
echo
echo "It will show as untrusted in 'security find-identity -v', which is"
echo "expected and does not matter: codesign signs with it regardless, and the"
echo "designated requirement it produces is what TCC remembers."
echo
echo "Next: ./Scripts/make-app.sh, then grant Screen Recording once."
