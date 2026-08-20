# Fix Ghost Display After Confirmed Disconnect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a CONFIRMED physical disconnect, destroy the virtual display instead of keeping it alive. This prevents macOS from seeing a ghost extra display when the G9 was unplugged during sleep.

**Architecture:** One-line change in `confirmDisconnect`: replace `unmirrorAndDeactivate()` with `destroyAllVirtualDisplays()`. All reconnect paths already handle a missing display by falling through to `restorePreset()`. The `unmirrorAndDeactivate` method is also cleaned up in `toggleHiDPIEnabled` where it was redundantly called before an immediate `destroyAllVirtualDisplays`.

**Tech Stack:** Swift 5, AppKit, CoreGraphics. Build via `App/build.sh`.

## Research: Reconnect path safety verification

`reestablishMirrorOnExistingDisplay` (line 2788) handles missing display:
```swift
guard virtualID != kCGNullDirectDisplay else {
    // recreating from preset
    restorePreset(presetName)
    return
}
```

All reconnect callers route through this method:
| Caller | What happens after destroy |
|---|---|
| `periodicDisplayCheck` Case 2 (line 1048) | `reestablishMirrorOnExistingDisplay` → display missing → `restorePreset` |
| `handleDisplayConfigurationChange` Case 2 (line 1267) | Same path |
| `handleWakeFromSleep` mirror severed (line 1121) | Same path |
| `handleWakeFromSleep` wasDisconnected (line 1133) | Same path |
| `checkAndRestoreFromCrash` restart (line 1507) | Falls through `displayExists == false` → `restorePreset` |

`restorePreset` (line 1585) handles the recreate: stops timers, destroys any leftover display, creates new one. Arrangement is saved in `DisplayArrangementManager` and restored after mirror setup.

## Global Constraints

- No process restart — display is destroyed and recreated in-process
- Arrangement must survive the destroy/recreate cycle (saved in `DisplayArrangementManager`)
- `wasDisconnected` flag preserved so reconnect paths fire when monitor returns
- `unmirrorAndDeactivate` usage cleaned up

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `App/Sources/HiDPIDisplayApp.swift` | Modify 2 lines | `confirmDisconnect`, `toggleHiDPIEnabled` disable path |

---

### Task 1: Destroy Display on Confirmed Disconnect

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1421`

**Interfaces:**
- Consumes: `VirtualDisplayManager.shared().destroyAllVirtualDisplays()` (existing)
- Produces: Same `wasDisconnected`/`kWasDisconnectedKey` state as before — reconnect paths are already correct

- [ ] **Step 1: Replace `unmirrorAndDeactivate` with `destroyAllVirtualDisplays`**

Replace line 1421:
```swift
                manager.unmirrorAndDeactivate()
```
With:
```swift
                manager.destroyAllVirtualDisplays()
```

And update the comment on line 1413 from "just un-mirror, keep display alive" to:
```swift
                // Confirmed disconnect — destroy the display so macOS
                // doesn't see a ghost extra display. The reconnect paths
                // will recreate it via restorePreset when the monitor returns.
```

- [ ] **Step 2: Clean up redundant `unmirrorAndDeactivate` in `toggleHiDPIEnabled`**

In the disable branch (line 2690), `unmirrorAndDeactivate()` is called immediately before `destroyAllVirtualDisplays()`. Remove the redundant call. Replace lines 2689-2692:
```swift
            if manager.displayExists {
                manager.unmirrorAndDeactivate()
                stopEnforcementTimers()
                manager.destroyAllVirtualDisplays()
            }
```
With:
```swift
            if manager.displayExists {
                stopEnforcementTimers()
                manager.destroyAllVirtualDisplays()
            }
```

- [ ] **Step 3: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

- [ ] **Step 4: Verify `unmirrorAndDeactivate` is no longer called**

Run: `grep -n "unmirrorAndDeactivate" App/Sources/HiDPIDisplayApp.swift`
Expected: no results.
