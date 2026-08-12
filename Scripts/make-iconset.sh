#!/bin/bash
# Turns Resources/AppIcon-1024.png into Resources/AppIcon.icns.
# Run `swift Scripts/make-icon.swift` first if the design changed.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/AppIcon-1024.png"
SET="Resources/AppIcon.iconset"
[ -f "${SRC}" ] || { echo "missing ${SRC} — run: swift Scripts/make-icon.swift"; exit 1; }

rm -rf "${SET}"
mkdir -p "${SET}"
for SIZE in 16 32 128 256 512; do
    sips -z "${SIZE}" "${SIZE}" "${SRC}" --out "${SET}/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "${DOUBLE}" "${DOUBLE}" "${SRC}" --out "${SET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "${SET}" -o "Resources/AppIcon.icns"
rm -rf "${SET}"
echo "wrote Resources/AppIcon.icns"
