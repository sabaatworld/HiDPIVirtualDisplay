#!/bin/bash
# Generate the G9 Helper app icon from the approved Split Frame SVG artwork.

set -euo pipefail

SOURCE_DIR="Resources/IconSource"
ICONSET_DIR="Resources/AppIcon.iconset"
RESOURCES_DIR="Resources"
MASTER="${SOURCE_DIR}/AppIcon-3072.png"
ICON_MODULE_CACHE_DIR="build/.icon-module-cache"
SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

render_png() {
    local source="$1"
    local pixels="$2"
    local destination="$3"
    rsvg-convert --width "${pixels}" --height "${pixels}" "${source}" --output "${destination}"
    sips --matchTo "${SRGB_PROFILE}" "${destination}" --out "${destination}" >/dev/null
}

test -f "${SOURCE_DIR}/AppIcon.svg"
test -f "${SOURCE_DIR}/MenuBarIcon.svg"

mkdir -p "${ICONSET_DIR}"
mkdir -p "${ICON_MODULE_CACHE_DIR}"

render_png "${SOURCE_DIR}/AppIcon.svg" 3072 "${MASTER}"
cp "${SOURCE_DIR}/MenuBarIcon.svg" "${RESOURCES_DIR}/MenuBarIcon.svg"

while IFS=':' read -r name pixels; do
    render_png "${SOURCE_DIR}/AppIcon.svg" "${pixels}" "${ICONSET_DIR}/${name}"
done <<'SIZES'
icon_16x16.png:16
icon_16x16@2x.png:32
icon_32x32.png:32
icon_32x32@2x.png:64
icon_128x128.png:128
icon_128x128@2x.png:256
icon_256x256.png:256
icon_256x256@2x.png:512
icon_512x512.png:512
icon_512x512@2x.png:1024
SIZES

bash tests/verify_icon_assets.sh
CLANG_MODULE_CACHE_PATH="${PWD}/${ICON_MODULE_CACHE_DIR}" \
SWIFT_MODULECACHE_PATH="${PWD}/${ICON_MODULE_CACHE_DIR}" \
swift Scripts/compile_icns.swift "${ICONSET_DIR}" "${RESOURCES_DIR}/AppIcon.icns"

echo "Icon assets created in ${RESOURCES_DIR}/"
