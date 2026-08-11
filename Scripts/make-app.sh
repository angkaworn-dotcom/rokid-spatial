#!/bin/bash
# Wraps the built executable in a .app bundle.
#
# This is not cosmetic. macOS attaches Screen Recording consent to a stable
# code identity, and a loose binary run from a terminal inherits the
# terminal's identity instead of having its own — so permission would have to
# be granted to the terminal, and would silently follow whichever terminal you
# happened to use. A signed bundle gets its own entry in System Settings.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="RokidSpatial"
BUNDLE=".build/${APP_NAME}.app"

echo "› building"
swift build -c release --product "${APP_NAME}"

echo "› assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Rokid Spatial</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>com.rokidspatial.app</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Sign with the local self-signed identity if it is present.
#
# This is not cosmetic either. An ad-hoc signature's designated requirement is
# the code's own hash:
#     designated => cdhash H"cab9ac88..."
# which changes with every build, so macOS sees a brand new app each time and
# Screen Recording consent has to be granted again. Signing with a certificate
# gives a requirement of:
#     designated => identifier "com.rokidspatial.app" and certificate root = H"..."
# Both halves survive a rebuild, so the permission sticks.
#
# Create the identity once with Scripts/make-signing-cert.sh.
IDENTITY="RokidSpatial Dev"
if security find-certificate -c "${IDENTITY}" >/dev/null 2>&1; then
    echo "› signing as '${IDENTITY}'"
    SIGN_AS="${IDENTITY}"
else
    echo "› signing ad-hoc — no '${IDENTITY}' identity found"
    echo "  (Screen Recording permission will lapse on every rebuild;"
    echo "   run Scripts/make-signing-cert.sh to fix that)"
    SIGN_AS="-"
fi
codesign --force --sign "${SIGN_AS}" --timestamp=none "${BUNDLE}"

# Install to a stable path. Screen Recording consent is keyed on both the
# bundle path and the code signature, and `.build` is deleted and recreated by
# every build — so running from there produces a fresh identity each time and
# a Privacy pane slowly filling with dead duplicate entries.
INSTALLED="${HOME}/Applications/${APP_NAME}.app"
echo "› installing to ${INSTALLED}"
mkdir -p "${HOME}/Applications"
rm -rf "${INSTALLED}"
cp -R "${BUNDLE}" "${INSTALLED}"
codesign --force --sign "${SIGN_AS}" --timestamp=none "${INSTALLED}"

echo
echo "installed ${INSTALLED}"
echo "run it with:  open ${INSTALLED}"

if [ "${SIGN_AS}" = "-" ]; then
    echo
    echo "If macOS asks for Screen Recording permission again after a rebuild:"
    echo "  tccutil reset ScreenCapture com.rokidspatial.app"
fi
