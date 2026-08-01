# Menubar and App Icon — Design Spec

**Date:** 2026-08-01
**Status:** Approved for implementation

## Goal

Give G9 Helper a cohesive, recognizable visual identity while preserving macOS
12+ compatibility and correct light/dark menubar behavior.

The identity has two related but distinct uses:

1. A compact monochrome status-item icon that communicates HiDPI scaling.
2. A color app icon that uses the same core mark and has enough personality to
   be identifiable in Finder and other app-icon contexts.

## Approved visual direction

### Core mark: Split Frame

The shared mark is an abstract rounded square, divided vertically:

- The left field contains two large, sparse pixels.
- The right field contains a 2 by 4 dense pixel field.
- The mark represents a low-to-high-density resolution transformation without
  depicting a display or using text.

The interior geometry is deliberately spacious so the two fields remain
distinct at small sizes. The rounded-square frame creates a memorable
silhouette while avoiding a literal monitor outline.

### Menubar icon

The menubar icon is the Split Frame only. It is monochrome and contains no
state dot or app-icon background.

- Logical canvas: 24 by 24 points.
- Outer frame: a taller rounded square, not a landscape device shape.
- Appearance: set `isTemplate = true` so AppKit supplies the correct color in
  light, dark, selected, and pressed menubar states.
- Accessibility description: `HiDPI Display`.

The current generic `display` SF Symbol is replaced at the existing status
item setup point. A resource-load failure uses the current SF Symbol as a
safe fallback and writes a diagnostic log entry.

### App icon: Midnight Prism / Tangerine

The app icon uses the Split Frame as an enlarged tangerine foreground mark on
the selected Midnight Prism background.

**Background**

- Full square canvas with a deep navy-to-indigo-to-violet gradient.
- Subtle cool radial glow in the upper-right region.
- Two low-opacity diagonal prism planes; they add depth but must remain quiet
  when the icon is small.

**Foreground**

- Tangerine color: `#FF9838`.
- Approximately 13% larger than the original white-mark proposal.
- Centered with a generous safe margin on all sides.
- Soft shadow is permitted in rendered bitmap output to establish separation;
  it must not reduce legibility at 16 and 32 pixels.

The background and mark are separate source layers. The source artwork is
square and has no baked-in outer rounded-corner mask; macOS applies that mask.

## Asset architecture

### Canonical source files

Save editable source assets under `App/Resources/IconSource/`:

| File | Purpose |
|---|---|
| `MenuBarIcon.svg` | 24 by 24 monochrome Split Frame source. |
| `AppIcon-Mark.svg` | 1024 by 1024 equivalent Split Frame foreground source, tangerine by default. |
| `AppIcon-Background.svg` | Midnight Prism background source. |
| `AppIcon-3072.png` | High-resolution, flattened production master for reliable raster exports. |

SVG remains the editable geometry source. The 3072-pixel master is archival
and ensures clean downsampling; it is not a separate macOS runtime slot.

### macOS 12+ compatibility output

The active bundle icon remains `App/Resources/AppIcon.icns`, generated from a
standard `AppIcon.iconset` at every required macOS 1x and 2x rendition:

| Filename | Pixel dimensions |
|---|---:|
| `icon_16x16.png` | 16 by 16 |
| `icon_16x16@2x.png` | 32 by 32 |
| `icon_32x32.png` | 32 by 32 |
| `icon_32x32@2x.png` | 64 by 64 |
| `icon_128x128.png` | 128 by 128 |
| `icon_128x128@2x.png` | 256 by 256 |
| `icon_256x256.png` | 256 by 256 |
| `icon_256x256@2x.png` | 512 by 512 |
| `icon_512x512.png` | 512 by 512 |
| `icon_512x512@2x.png` | 1024 by 1024 |

macOS uses these 1x and 2x icon-set slots. A 3x master is retained for source
quality, not added as an unsupported `.iconset` entry.

### Modern layered-icon preparation

Keep background and foreground layers separately exportable at 1024 by 1024
so they can be imported into Apple Icon Composer for current macOS layered
appearance treatment. The shipped `.icns` remains the compatibility path for
the app's macOS 12+ target.

## Implementation outline

1. Add the canonical SVG source files and an icon-generation script that
   renders from the approved source rather than drawing temporary artwork.
2. Generate and validate all icon-set PNGs, then compile `AppIcon.icns` with
   the project-local Swift ICNS compiler. This avoids the local `iconutil`
   process hang while producing the standard PNG-chunk ICNS container.
3. Ensure `App/build.sh` copies both the ICNS and `MenuBarIcon.svg` into the
   app bundle.
4. Add a focused `MenuBarIcon` image factory that loads the bundled SVG,
   applies the status-item size, sets template mode, and supplies the current
   SF Symbol fallback.
5. Replace only the existing status-item image assignment in
   `HiDPIDisplayApp.swift`.

## Validation

### Automated and structural checks

- Confirm all ten `.iconset` filenames exist before ICNS compilation runs.
- Confirm each PNG has the specified square dimensions and an sRGB profile.
- Confirm the project-local compiler creates `AppIcon.icns` successfully and
  that every required PNG chunk is present.
- Build with `App/build.sh`.
- Confirm the final app bundle contains both `AppIcon.icns` and
  `MenuBarIcon.svg`.

### Visual checks

- Inspect the flattened app icon at 16, 32, 128, 512, and 1024 pixels.
- Confirm the two sparse pixels and dense grid remain distinguishable at 16
  and 32 pixels.
- Verify the foreground remains centered and clear rather than touching the
  system-masked corners.
- Launch the built app in both macOS light and dark appearance and confirm the
  status-item glyph receives the expected automatic template tint.

## Out of scope

- Animated status-item icons.
- Encoding active/inactive state with a colored dot in the glyph.
- Replacing the macOS 12+ `.icns` compatibility asset with a new runtime
  requirement.
- Changing menu behavior, display lifecycle behavior, or app branding text.
