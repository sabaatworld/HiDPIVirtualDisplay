# Fix Teardown Mirror Break — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the physical panel's mirror and stop enforcement timers *before* destroying the virtual display on disconnect and disable, so `isActive = false` never coexists with a still-active HiDPI mirror or ghost display.

**Architecture:** The menu item "Reapply HiDPI" is rendered only while `isActive == true` (`rebuildMenu`). "HiDPI stopped" means the virtual display is destroyed **and** the panel's mirror to it is broken. `destroyAllVirtualDisplays()` only releases this process's `CGVirtualDisplay` (`releaseDisplayObjects`); it does **not** revert `CGConfigureDisplayMirrorOfDisplay`, so the mirror must be broken explicitly via `resetAllMirroring()` before destroying. Two teardown paths — `confirmDisconnect` (disconnect) and `toggleHiDPIEnabled` disable (uncheck) — were writing `isActive = false` without the explicit mirror break. This fixes both.

**Tech Stack:** Swift 5, AppKit, CoreGraphics, Objective-C (no ARC) `VirtualDisplayManager`. Build via `App/build.sh`.

## Global Constraints

- No process restarts for routine operations (disconnect / reconnect / toggle / reapply); `relaunchApp()` is reserved for orphan cleanup only.
- Mirror must be broken (`resetAllMirroring()`) **before** destroying the virtual display, matching `applicationWillTerminate` (`App/Sources/HiDPIDisplayApp.swift:1694-1695`).
- `isActive = false` must never be written while a display/mirror can still survive.
- Universal binary (arm64 + x86_64); target macOS 13+.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `App/Sources/HiDPIDisplayApp.swift` | Modify (2 hunks) | Teardown ordering in `confirmDisconnect` and `toggleHiDPIEnabled` |

---

### Task 1: Break mirror before destroy in `confirmDisconnect`

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1422-1426`

**Interfaces:**
- Consumes: `VirtualDisplayManager.shared().resetAllMirroring()` and `.destroyAllVirtualDisplays()` (existing, `App/Sources/VirtualDisplayManager.m:501-660`).
- Produces: no new symbols — reorders two existing calls.

**Context:** `resetAllMirroring()` (`VirtualDisplayManager.m:637-660`) iterates `CGGetOnlineDisplayList` and calls `stopMirroringForDisplay:` on every mirror set involving a vendor `0x1234` display, in- or out-of-process. It is a safe no-op when the monitor is already unplugged (nothing to iterate). `destroyAllVirtualDisplays()` releases `_display` but does not touch the WindowServer mirror relationship.

- [ ] **Step 1: Add `resetAllMirroring()` before `destroyAllVirtualDisplays()`**

Replace this block (currently lines 1422-1426):

```swift
                let manager = VirtualDisplayManager.shared()
                manager.destroyAllVirtualDisplays()
                self.isActive = false
                self.stopEnforcementTimers()
                self.rebuildMenu()
```

With:

```swift
                let manager = VirtualDisplayManager.shared()
                manager.resetAllMirroring()
                manager.destroyAllVirtualDisplays()
                self.isActive = false
                self.stopEnforcementTimers()
                self.rebuildMenu()
```

- [ ] **Step 2: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: `Build complete: build/G9 Helper.app`

- [ ] **Step 3: Verify behavior (disconnect path)**

1. Launch: `open "App/build/G9 Helper.app"`, confirm HiDPI is active (log line `>>> HiDPI setup complete`).
2. Unplug the G9, wait for `>>> Disconnect confirmed — destroying virtual display` in `/tmp/g9helper.log`.
3. Confirm the log now shows `resetAllMirroring` **immediately before** `destroyAllVirtualDisplays` for this teardown.
4. In **System Settings ▸ Displays**, confirm no ghost virtual display remains.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/HiDPIDisplayApp.swift
git commit -m "fix: break mirror before destroying virtual display on disconnect"
```

---

### Task 2: Unconditional mirror break + timer stop in `toggleHiDPIEnabled` disable

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:2690-2696`

**Interfaces:**
- Consumes: `stopEnforcementTimers()` (defined `App/Sources/HiDPIDisplayApp.swift:725`), `VirtualDisplayManager.shared().resetAllMirroring()`, `.displayExists`, `.destroyAllVirtualDisplays()`.
- Produces: no new symbols — restructures the disable teardown.

**Context:** The disable branch previously called `destroyAllVirtualDisplays()` only when `displayExists == true`, and never broke the mirror. When the display is owned by a crashed prior process (`displayExists == false`), the destroy was skipped and the mirror left in place while `isActive` was cleared. `stopEnforcementTimers()` was also inside the guard, so a disconnected-state teardown could leave the 2s `modeEnforcementTimer` running.

- [ ] **Step 1: Restructure the disable teardown**

Replace this block (currently lines 2690-2696):

```swift
            let manager = VirtualDisplayManager.shared()
            if manager.displayExists {
                stopEnforcementTimers()
                manager.destroyAllVirtualDisplays()
            }
```

With:

```swift
            let manager = VirtualDisplayManager.shared()
            stopEnforcementTimers()
            manager.resetAllMirroring()
            if manager.displayExists {
                manager.destroyAllVirtualDisplays()
            }
```

`resetAllMirroring()` now runs unconditionally (breaking any mirror involving a vendor `0x1234` display, in- or out-of-process); `destroyAllVirtualDisplays()` remains guarded by `displayExists` since it can only release this process's object.

- [ ] **Step 2: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: `Build complete: build/G9 Helper.app`

- [ ] **Step 3: Verify behavior (toggle path)**

1. With HiDPI active, uncheck **Enable HiDPI** in the menu.
2. Confirm the G9 reverts to native (no HiDPI picture) and the menu shows a checked preset with **Enable HiDPI** (not **Reapply HiDPI**).
3. Confirm the log shows `resetAllMirroring` before `destroyAllVirtualDisplays`.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/HiDPIDisplayApp.swift
git commit -m "fix: break mirror and stop timers unconditionally on disable"
```

---

## Rejected approach (do not reintroduce)

An earlier pass added a `relaunchApp()` branch in `restorePreset` to reclaim an out-of-process orphan display. Code review rejected it: the cleanup marker is consumed at launch (`isCleanupRestart()` in `applicationDidFinishLaunching`), then `checkAndRestoreFromCrash` re-arms and re-triggers `restorePreset` on every launch, so a persistent orphan would cause an **unbounded relaunch loop**. `restorePreset` already breaks the mirror via `resetAllMirroring()` (`App/Sources/HiDPIDisplayApp.swift:1624`), and foreign-orphan cleanup is handled once, loop-guarded, at launch — so mid-session relaunch adds risk with no value.
