# Menubar and App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generic menubar display symbol and existing G9 app icon with the approved Split Frame assets while retaining macOS 12+ compatibility.

**Architecture:** Editable SVG source files under `App/Resources/IconSource/` define the approved Split Frame and Midnight Prism/Tangerine artwork. `App/create-icon.sh` renders the flattened source into macOS's required 1x/2x icon-set slots, validates them, and invokes the project-local Swift ICNS compiler to produce `AppIcon.icns`. A focused Swift `MenuBarIcon` factory loads the bundled SVG as a template image and falls back safely to the current SF Symbol.

**Tech Stack:** Swift/AppKit, SVG, macOS `sips`, project-local Swift ICNS compiler, shell validation, `App/build.sh`.

## Global Constraints

- Support macOS 12.0 and later; keep `AppIcon.icns` as the active bundle app icon.
- Do not add unsupported 3x `.iconset` entries; retain a 3072 by 3072 master source for production quality.
- Keep the source app-icon canvas square and unmasked; macOS supplies the final rounded-corner mask.
- Use `#FF9838` for the enlarged Tangerine Split Frame foreground.
- The menubar glyph must be template-tinted by AppKit and work in light, dark, selected, and pressed states.
- Add `.superpowers/` to `.gitignore`.
- Do not stage or commit any files.

---

## File Structure

| Path | Responsibility |
|---|---|
| `.gitignore` | Excludes visual-companion scratch files. |
| `App/Resources/IconSource/MenuBarIcon.svg` | Editable 24 by 24 monochrome Split Frame. |
| `App/Resources/IconSource/AppIcon-Mark.svg` | Editable 1024 by 1024 Tangerine foreground. |
| `App/Resources/IconSource/AppIcon-Background.svg` | Editable 1024 by 1024 Midnight Prism background. |
| `App/Resources/IconSource/AppIcon.svg` | Flattened 1024 by 1024 composition source. |
| `App/Resources/IconSource/AppIcon-3072.png` | Raster production master generated from `AppIcon.svg`. |
| `App/Resources/MenuBarIcon.svg` | Bundled menubar asset copied from the canonical source. |
| `App/Resources/AppIcon.icns` | Generated macOS application icon. |
| `App/create-icon.sh` | Renders and validates the icon outputs. |
| `App/Scripts/compile_icns.swift` | Packs standard PNG chunks into the ICNS container without relying on the locally hanging `iconutil` process. |
| `App/Sources/MenuBarIcon.swift` | Loads the SVG template image and provides a fallback. |
| `App/Sources/HiDPIDisplayApp.swift` | Uses `MenuBarIcon.make()` for the status item. |
| `App/build.sh` | Compiles the factory and copies the menubar SVG into the bundle. |
| `App/tests/verify_icon_assets.sh` | Validates source/output files and icon-set dimensions. |

## Task 1: Ignore companion artifacts and establish the icon validator

**Files:**
- Modify: `.gitignore`
- Create: `App/tests/verify_icon_assets.sh`

**Interfaces:**
- Consumes: `App/Resources/IconSource/`, `App/Resources/AppIcon.iconset/`, and `App/Resources/AppIcon.icns`.
- Produces: exit status 0 only when every canonical source and macOS compatibility rendition is present and correctly sized.

- [ ] **Step 1: Add a failing validator**

Create `App/tests/verify_icon_assets.sh` as an executable shell script that starts with:

```bash
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
```

Run: `bash App/tests/verify_icon_assets.sh`

Expected: failure because the source assets and icon set do not yet exist.

- [ ] **Step 2: Add the ignore rule**

Append this exact line below the temporary-file rules in `.gitignore`:

```gitignore
.superpowers/
```

Run: `git check-ignore -q .superpowers/brainstorm/example.html`

Expected: exit status 0.

## Task 2: Add the approved SVG source artwork and generate every macOS app-icon rendition

**Files:**
- Create: `App/Resources/IconSource/MenuBarIcon.svg`
- Create: `App/Resources/IconSource/AppIcon-Mark.svg`
- Create: `App/Resources/IconSource/AppIcon-Background.svg`
- Create: `App/Resources/IconSource/AppIcon.svg`
- Modify: `App/create-icon.sh`
- Create: `App/Resources/IconSource/AppIcon-3072.png`
- Create: `App/Resources/AppIcon.iconset/*`
- Modify: `App/Resources/AppIcon.icns`
- Modify: `App/tests/verify_icon_assets.sh`

**Interfaces:**
- Consumes: the canonical SVG sources.
- Produces: `AppIcon-3072.png`, the ten standard icon-set PNG files, `AppIcon.icns`, and `App/Resources/MenuBarIcon.svg`.

- [ ] **Step 1: Extend the validator with exact rendition checks**

Add this table-driven loop to `verify_icon_assets.sh` after the canonical-file checks:

```bash
while IFS=':' read -r name pixels; do
  file="${ICONSET_DIR}/${name}"
  test -f "${file}"
  dimensions="$(sips -g pixelWidth -g pixelHeight "${file}")"
  printf '%s\n' "${dimensions}" | rg -q "pixelWidth: ${pixels}"
  printf '%s\n' "${dimensions}" | rg -q "pixelHeight: ${pixels}"
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
```

Run: `bash App/tests/verify_icon_assets.sh`

Expected: still fails before generation.

- [ ] **Step 2: Add the four canonical SVG sources**

Use a 24 by 24 viewBox for `MenuBarIcon.svg`; use a 1024 by 1024 viewBox for the three app-icon SVGs. Draw the approved enlarged Split Frame with:

```svg
<rect x="210" y="210" width="604" height="604" rx="150"/>
<path d="M452 238v548"/>
```

Use left-field dot centers `(331, 408)` and `(331, 616)` with radius 39. Use right-field dot centers `(566|680, 349|467|585|703)` with radius 31. Color the app-icon foreground `#FF9838`. Build the background from the approved navy/indigo/violet gradient, cool upper-right glow, and two quiet diagonal planes. `AppIcon.svg` combines the approved background and foreground exactly; it is the flattened production source.

- [ ] **Step 3: Replace the temporary Swift drawing in `App/create-icon.sh` with deterministic SVG rendering**

Define these variables at the top of the script:

```bash
SOURCE_DIR="Resources/IconSource"
ICONSET_DIR="Resources/AppIcon.iconset"
RESOURCES_DIR="Resources"
MASTER="${SOURCE_DIR}/AppIcon-3072.png"
```

Render `AppIcon.svg` to the master and each icon-set output using `sips`:

```bash
sips -z 3072 3072 "${SOURCE_DIR}/AppIcon.svg" --out "${MASTER}"
sips -z "${pixels}" "${pixels}" "${SOURCE_DIR}/AppIcon.svg" --out "${ICONSET_DIR}/${name}"
```

Render/copy `MenuBarIcon.svg` to `Resources/MenuBarIcon.svg`, run
`bash tests/verify_icon_assets.sh`, then compile standard `icp4`, `icp5`,
`icp6`, `ic07`, `ic08`, `ic09`, and `ic10` PNG chunks with the local Swift
compiler:

```bash
swift Scripts/compile_icns.swift "${ICONSET_DIR}" "${RESOURCES_DIR}/AppIcon.icns"
```

Run: `cd App && ./create-icon.sh && bash tests/verify_icon_assets.sh`

Expected: exit status 0 and a valid `Resources/AppIcon.icns` whose PNG chunks
match the generated icon-set files.

## Task 3: Load the menubar SVG as a template image

**Files:**
- Create: `App/Sources/MenuBarIcon.swift`
- Modify: `App/Sources/HiDPIDisplayApp.swift:867-871`
- Modify: `App/build.sh`

**Interfaces:**
- Produces: `MenuBarIcon.make() -> NSImage`.
- Consumes: `Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")`.

- [ ] **Step 1: Build the app before the change**

Run: `cd App && ./build.sh`

Expected: success using the current system-symbol status image.

- [ ] **Step 2: Implement the image factory**

Create `MenuBarIcon.swift`:

```swift
import AppKit

enum MenuBarIcon {
    static func make() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        NSLog("HiDPI: bundled MenuBarIcon.svg could not be loaded; using display symbol")
        let fallback = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI Display")!
        fallback.isTemplate = true
        return fallback
    }
}
```

Replace the status-item assignment with:

```swift
button.image = MenuBarIcon.make()
button.image?.accessibilityDescription = "HiDPI Display"
```

Add `Sources/MenuBarIcon.swift` to `SWIFT_SOURCES` and copy
`Resources/MenuBarIcon.svg` into `${RESOURCES}` alongside `AppIcon.icns`.

- [ ] **Step 3: Build and inspect the bundle**

Run:

```bash
cd App && ./create-icon.sh && ./build.sh
test -f "build/G9 Helper.app/Contents/Resources/MenuBarIcon.svg"
test -f "build/G9 Helper.app/Contents/Resources/AppIcon.icns"
codesign --verify --strict --verbose=2 "build/G9 Helper.app"
```

Expected: all commands exit 0.

## Task 4: Verify asset quality and runtime-safe behavior

**Files:**
- Modify: `App/tests/verify_icon_assets.sh` only if validation exposes a missing explicit check.

**Interfaces:**
- Consumes: built app and generated asset files from Tasks 2 and 3.
- Produces: verification evidence; no new runtime interfaces.

- [ ] **Step 1: Run structural validation**

Run: `cd App && bash tests/verify_icon_assets.sh && sips -g pixelWidth -g pixelHeight Resources/IconSource/AppIcon-3072.png`

Expected: the validator exits 0 and the master reports 3072 by 3072 pixels.

- [ ] **Step 2: Inspect app-icon outputs at critical sizes**

Render or view the generated 16, 32, 128, 512, and 1024 pixel PNGs. Confirm the outer frame, divider, two sparse dots, and 2 by 4 dense field remain identifiable; confirm the foreground does not approach the system-masked corners.

- [ ] **Step 3: Verify light/dark menubar template behavior**

Launch the built bundle and inspect the status item once in Light appearance and once in Dark appearance. In both cases, confirm that the SVG mark receives the system menubar tint rather than its source color and remains legible.

- [ ] **Step 4: Confirm repository hygiene**

Run: `git status --short`

Expected: `.superpowers/` is absent from status, the design/plan docs and intentionally changed implementation files remain unstaged, and no commit is created.
