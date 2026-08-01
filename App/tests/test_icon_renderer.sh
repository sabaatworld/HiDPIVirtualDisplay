#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

test -x "${ROOT}/create-icon.sh"

(
  cd "${ROOT}"
  bash create-icon.sh
  bash tests/verify_icon_assets.sh
  python3 tests/verify_icns_container.py
)
