#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT}/build/G9 Helper.app"

(
  cd "${ROOT}"
  bash build.sh
)

test -f "${APP_BUNDLE}/Contents/Resources/MenuBarIcon.svg"
rg -q 'button\.image = MenuBarIcon\.make\(\)' "${ROOT}/Sources/HiDPIDisplayApp.swift"
rg -q 'static func make\(\) -> NSImage' "${ROOT}/Sources/MenuBarIcon.swift"
