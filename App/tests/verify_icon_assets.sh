#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${ROOT}/Resources/IconSource"
ICONSET_DIR="${ROOT}/Resources/AppIcon.iconset"

for path in \
  "${SOURCE_DIR}/MenuBarIcon.svg" \
  "${SOURCE_DIR}/AppIcon-Mark.svg" \
  "${SOURCE_DIR}/AppIcon-Background.svg" \
  "${SOURCE_DIR}/AppIcon.svg" \
  "${SOURCE_DIR}/AppIcon-3072.png" \
  "${ROOT}/Resources/MenuBarIcon.svg" \
  "${ROOT}/Resources/AppIcon.icns"; do
  test -f "${path}"
done

while IFS=':' read -r name pixels; do
  file="${ICONSET_DIR}/${name}"
  test -f "${file}"
  dimensions="$(sips -g pixelWidth -g pixelHeight "${file}")"
  printf '%s\n' "${dimensions}" | rg -q "pixelWidth: ${pixels}"
  printf '%s\n' "${dimensions}" | rg -q "pixelHeight: ${pixels}"
  sips -g profile "${file}" | rg -q 'sRGB IEC61966-2.1'
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
