# Fix Wake/Restart HiDPI Auto-Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix HiDPI not auto-restoring when the laptop wakes from sleep (lid closed, monitor still connected) or when the app restarts while the monitor is connected. The checkmark state and auto-detection must survive app restarts.

**Architecture:** Three changes to `checkAndRestoreFromCrash` (stop blocking when monitor is already connected), `periodicDisplayCheck` (auto-restore checkmark on reconnect), and orphaned display handling (reduce disruptive restarts). All in `HiDPIDisplayApp.swift`.

**Tech Stack:** Swift 5, AppKit, CoreGraphics. Build via `App/build.sh`.

## Global Constraints

- `kHiDPIEnabledKey` (checkmark) must survive app restarts when the user clearly had HiDPI active
- `checkAndRestoreFromCrash` must NOT return early when monitor IS connected — proceed with restore
- `periodicDisplayCheck` must auto-recover the checkmark from `wasDisconnected` context
- Orphaned displays from crashed previous processes must not trigger repeated restart loops
- No new UserDefaults keys needed — reuse existing state
- All existing edge cases preserved (fingerprint matching, mirror failure cap, setup generation)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `App/Sources/HiDPIDisplayApp.swift` | Modify 3 functions | `checkAndRestoreFromCrash`, `periodicDisplayCheck`, `hasOrphanedVirtualDisplay` |

---

### Task 1: Fix `checkAndRestoreFromCrash` — Stop Blocking on `wasDisconnected` When Monitor Is Present

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1451-1455`

**Interfaces:**
- Consumes: `findExternalDisplay()`, `connectedMonitorMatchesSavedPreset()`, `kHiDPIEnabledKey`, `kWasDisconnectedKey`, `kAutoRestoreKey`
- Produces: `restorePreset(_:)` (existing) or `reestablishMirrorOnExistingDisplay(generation:)` (existing)

**The bug:** Line 1452 returns immediately when `wasDisconnected == true`, regardless of whether the monitor is connected RIGHT NOW. On a restart while the monitor is connected, the app waits forever for a "reconnect" that already happened. Meanwhile, `periodicDisplayCheck` hits the `kHiDPIEnabledKey == false` guard and also skips.

**The fix:** If `wasDisconnected && monitor IS connected && fingerprint matches`, don't return early. Instead, clear `wasDisconnected`, set `kHiDPIEnabledKey = true`, and proceed to restore. This intentionally runs before the `kAutoRestoreKey` guard — when the monitor is already connected and the fingerprint matches, the user's previous HiDPI intent trumps the "Auto-Restore After Crash" setting.

- [ ] **Step 1: Replace the wasDisconnected early-return block**

Replace lines 1451-1455:
```swift
        // If we restarted after disconnect (not explicit disable), wait for monitor
        if wasDisconnected {
            debugLog("Restarted after disconnect — waiting for monitor reconnection")
            return
        }
```

With:
```swift
        // If we restarted after disconnect AND the monitor is still/missing:
        // - Monitor absent → wait for reconnect (periodicCheck/handleDisplayConfig will fire)
        // - Monitor present + fingerprint matches → restore now (the "reconnect" already happened)
        if wasDisconnected {
            if findExternalDisplay() != nil,
               connectedMonitorMatchesSavedPreset() {
                debugLog("Restarted after disconnect but monitor is already connected — restoring now")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                // Restore the checkmark — user clearly wanted HiDPI before the restart
                UserDefaults.standard.set(true, forKey: kHiDPIEnabledKey)
                // Restore with the saved preset
                if let lastPreset = UserDefaults.standard.string(forKey: kLastPresetKey),
                   !lastPreset.isEmpty {
                    isSettingUp = true
                    setupGeneration += 1
                    let generation = setupGeneration
                    if VirtualDisplayManager.shared().displayExists {
                        // Display survived the restart — just re-mirror it
                        debugLog("Display exists from previous session, re-mirroring")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self = self, generation == self.setupGeneration else { return }
                            self.reestablishMirrorOnExistingDisplay(generation: generation)
                        }
                    } else {
                        // No display — create fresh
                        debugLog("No existing display, restoring preset \(lastPreset)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self = self, generation == self.setupGeneration else { return }
                            self.restorePreset(lastPreset)
                        }
                    }
                }
                return
            }
            debugLog("Restarted after disconnect — waiting for monitor reconnection")
            return
        }
```

- [ ] **Step 2: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

---

### Task 2: Fix `periodicDisplayCheck` Case 2 — Auto-Recover Checkmark from `wasDisconnected`

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1039-1064`

**The bug:** Case 2 requires `kHiDPIEnabledKey == true` at line 1043. After an app restart, this key is `false` (default). The checkmark was on before the restart but didn't persist. The periodic check finds the monitor connected and `wasDisconnected == true` but skips because the checkmark is off.

**The fix:** Before the `kHiDPIEnabledKey` guard, auto-recover it: if `wasDisconnected` is true and the monitor matches, the user clearly intended HiDPI. Set the checkmark to true.

- [ ] **Step 1: Add auto-recovery before the kHiDPIEnabledKey guard**

Replace lines 1039-1064:

```swift
        // Case 2: Reconnect — was disconnected, monitor returned
        if !isActive && wasDisconnected && realMonitor != nil {
            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey)
            guard failCount < maxMirrorRetries else { return }
            guard UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) else {
                debugLog("Auto-apply disabled — skipping reconnect")
                return
            }
            if !connectedMonitorMatchesSavedPreset() {
                debugLog("Monitor mismatch — skipping auto-restore on reconnect")
                return
            }
            debugLog("Monitor reconnected, reestablishing mirror")
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            StatusWindowController.shared.show(message: "Reconnecting...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                autoreleasepool {
                    self?.reestablishMirrorOnExistingDisplay(generation: generation)
                }
            }
            return
        }
```

With:

```swift
        // Case 2: Reconnect — was disconnected, monitor returned
        if !isActive && wasDisconnected && realMonitor != nil {
            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey)
            guard failCount < maxMirrorRetries else { return }
            // Auto-recover checkmark: if wasDisconnected is true and the monitor
            // matches, the user clearly had HiDPI enabled before. The checkmark
            // state may have been lost across an app restart while the monitor
            // was connected (kHiDPIEnabledKey defaults to false).
            if !UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) {
                if connectedMonitorMatchesSavedPreset() {
                    debugLog("Auto-recovering checkmark — wasDisconnected + monitor match")
                    UserDefaults.standard.set(true, forKey: kHiDPIEnabledKey)
                } else {
                    debugLog("Checkmark off, monitor mismatch — skipping reconnect")
                    return
                }
            }
            if !connectedMonitorMatchesSavedPreset() {
                debugLog("Monitor mismatch — skipping auto-restore on reconnect")
                return
            }
            debugLog("Monitor reconnected, reestablishing mirror")
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            StatusWindowController.shared.show(message: "Reconnecting...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                autoreleasepool {
                    self?.reestablishMirrorOnExistingDisplay(generation: generation)
                }
            }
            return
        }
```

- [ ] **Step 2: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

---

### Task 3: Add `kHiDPIEnabledKey` Recovery to `handleDisplayConfigurationChange` Case 2 + `handleWakeFromSleep`

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1242-1275` (`handleDisplayConfigurationChange` Case 2)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1080` (`handleWakeFromSleep` guard)

**Same bug as Task 2,** in two more paths. The display-change notification handler and the wake-from-sleep handler both gate on `kHiDPIEnabledKey` and skip when it's false.

- [ ] **Step 1: Full replacement for `handleDisplayConfigurationChange` Case 2**

Replace lines 1242-1267:

```swift
        // Case 2: Reconnect
        if !isActive && wasDisconnected {
            guard let _ = findRealPhysicalMonitor() else { return }
            // Auto-recover checkmark if wasDisconnected and monitor matches
            if !UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) {
                if connectedMonitorMatchesSavedPreset() {
                    debugLog("DisplayChange: auto-recovering checkmark")
                    UserDefaults.standard.set(true, forKey: kHiDPIEnabledKey)
                } else {
                    debugLog("DisplayChange: checkmark off, monitor mismatch — skipping")
                    return
                }
            }
            guard connectedMonitorMatchesSavedPreset() else { return }
            debugLog("Display reconfiguration: monitor reconnected, reestablishing mirror")
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, generation == self.setupGeneration else { return }
                autoreleasepool {
                    self.reestablishMirrorOnExistingDisplay(generation: generation)
                }
            }
            return
        }
```

- [ ] **Step 2: Fix `handleWakeFromSleep` checkmark guard**

Replace lines 1080-1083:

```swift
            guard UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) else {
                debugLog("Wake: HiDPI disabled — skipping restore")
                return
            }
```

With:

```swift
            // If wasDisconnected and monitor matches, auto-recover checkmark
            if !UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) {
                if self.wasDisconnected, let _ = self.findRealPhysicalMonitor(),
                   self.connectedMonitorMatchesSavedPreset() {
                    debugLog("Wake: auto-recovering checkmark")
                    UserDefaults.standard.set(true, forKey: kHiDPIEnabledKey)
                } else {
                    debugLog("Wake: HiDPI disabled — skipping restore")
                    return
                }
            }
```

- [ ] **Step 3: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

---

### Task 4: Reduce Orphaned Display Restart Noise

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:910-920` (the orphan guard in `applicationDidFinishLaunching`)

**The bug:** Orphaned virtual display 39 persisted through multiple cleanup restarts because it was from a crashed previous process. Each restart triggers another restart. The cleanup marker prevents infinite loops but the user experience is bad — the app restarts twice on every launch while an orphan exists.

**The fix:** If a cleanup restart was JUST performed (marker exists), skip the orphan check and continue with normal launch. The orphan is unreachable via the private API and will persist until the next system reboot.

- [ ] **Step 1: Improve the orphan guard with a logged warning**

Replace the orphan guard block (around lines 910-920):

```swift
        // If orphaned virtual displays exist from a previous crash and this
        // isn't already a cleanup restart, terminate and relaunch so macOS
        // reclaims the displays (we can't destroy cross-process displays via API)
        if hasOrphanedVirtualDisplay() && !isCleanupRestart() {
            debugLog("Orphaned virtual displays detected from previous crash, restarting to clean up...")
            markCleanupRestart()
            relaunchApp()
            return
        }
```

With:

```swift
        // If orphaned virtual displays exist from a previous crash and this
        // isn't already a cleanup restart, terminate and relaunch so macOS
        // reclaims the displays (we can't destroy cross-process displays via API).
        if hasOrphanedVirtualDisplay() {
            if !isCleanupRestart() {
                debugLog("Orphaned virtual displays detected from previous crash, restarting to clean up...")
                // Only restart once — if the orphan persists after the restart,
                // it's from a different process and we can't clean it. Log and
                // continue normally instead of looping.
                markCleanupRestart()
                relaunchApp()
                return
            } else {
                debugLog("Orphaned virtual displays persist after cleanup restart — ignoring (from crashed previous process)")
            }
        }
```

- [ ] **Step 2: Verify build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

---

### Task 5: Final Build + Log Verification

- [ ] **Step 1: Full build**

Run: `cd App && bash build.sh 2>&1 | tail -5`
Expected: "Build complete: build/G9 Helper.app"

- [ ] **Step 2: Restart app and check log**

```bash
pkill -x HiDPIDisplay 2>/dev/null
sleep 1
open "build/G9 Helper.app"
sleep 3
grep "Restarted after disconnect\|auto-recovering\|Auto-recover\|orphaned" /tmp/g9helper.log | tail -10
```

- [ ] **Step 3: Verify the scenario**

When the app launches with `wasDisconnected=true` and the G9 connected:
- Expected log: `"Restarted after disconnect but monitor is already connected — restoring now"` (Task 1)
- HiDPI should be active within ~5 seconds of launch

When the laptop wakes from sleep (lid closed, G9 connected):
- Expected log: `"Auto-recovering checkmark — wasDisconnected + monitor match"` (Task 2 or 3)
- HiDPI should auto-restore

When an orphaned display from a crashed process persists:
- Expected log: `"Orphaned virtual displays persist after cleanup restart — ignoring"`
- App should NOT restart — it continues normally, even if HiDPI can't activate (orphan blocks creation with same serial)
