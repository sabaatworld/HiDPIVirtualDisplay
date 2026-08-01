# Checkmark "Enable HiDPI" — Implementation Plan

**Goal:** Replace the Enable/Disable HiDPI button pair with a single persistent checkmark menu item. Checking it means "I want HiDPI — make it happen whenever possible." Unchecking tears everything down and prevents auto-restore.

**Files:** `App/Sources/HiDPIDisplayApp.swift` only

---

### Task 1: Add `kHiDPIEnabledKey` + Replace Action Methods

**Step 1: Add the key (after line 670)**

```swift
    private let kHiDPIEnabledKey = "hiDPIEnabled"  // persistent checkmark
```

**Step 2: Replace `enableHiDPIAction` and `disableHiDPIAction` with `toggleHiDPIEnabled`**

Remove `enableHiDPIAction` (lines 2606-2670) and `disableHiDPIAction` (lines 2763-2791). 

Insert:

```swift
    @objc func toggleHiDPIEnabled(_ sender: NSMenuItem) {
        let currentlyEnabled = UserDefaults.standard.bool(forKey: kHiDPIEnabledKey)
        if currentlyEnabled {
            // Unchecking — tear down if active, prevent auto-restore.
            // Clear flags unconditionally (covers the disconnected-state edge
            // case where the display was already torn down but flags linger).
            debugLog("toggleHiDPIEnabled: disabling")
            UserDefaults.standard.set(false, forKey: kHiDPIEnabledKey)
            setupGeneration += 1
            isSettingUp = false
            let manager = VirtualDisplayManager.shared()
            if manager.displayExists {
                manager.unmirrorAndDeactivate()
                stopEnforcementTimers()
                manager.destroyAllVirtualDisplays()
            }
            currentVirtualID = 0
            targetExternalDisplayID = 0
            isActive = false
            wasDisconnected = false
            currentPresetName = ""
            UserDefaults.standard.set(false, forKey: kAutoRestoreKey)
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            rebuildMenu()
        } else {
            // Checking — enable immediately if monitor present, arm and wait if not
            debugLog("toggleHiDPIEnabled: enabling")
            UserDefaults.standard.set(true, forKey: kHiDPIEnabledKey)
            guard let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
                  !presetName.isEmpty else {
                rebuildMenu()
                return
            }
            // Resolve config
            let config: PresetConfig
            if let standard = presetConfigs[presetName] {
                config = standard
            } else if presetName.hasPrefix("custom-"),
                      let dict = UserDefaults.standard.dictionary(forKey: "customPresetConfig"),
                      let name = dict["name"] as? String,
                      let width = (dict["width"] as? NSNumber)?.uint32Value,
                      let height = (dict["height"] as? NSNumber)?.uint32Value,
                      let logicalWidth = (dict["logicalWidth"] as? NSNumber)?.uint32Value,
                      let logicalHeight = (dict["logicalHeight"] as? NSNumber)?.uint32Value,
                      let ppi = (dict["ppi"] as? NSNumber)?.uint32Value,
                      let hiDPI = dict["hiDPI"] as? Bool {
                config = PresetConfig(name: name, width: width, height: height, logicalWidth: logicalWidth, logicalHeight: logicalHeight, ppi: ppi, hiDPI: hiDPI)
            } else {
                rebuildMenu()
                return
            }
            UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            StatusWindowController.shared.show(message: "Enabling HiDPI...")
            let manager = VirtualDisplayManager.shared()
            if manager.displayExists {
                let currentW = manager.maxPixelsWide
                let currentH = manager.maxPixelsHigh
                if currentW == config.width && currentH == config.height {
                    debugLog("toggleHiDPIEnabled: reusing existing display \(manager.currentDisplayID)")
                    saveCurrentPreset(presetName)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        autoreleasepool {
                            self?.reestablishMirrorOnExistingDisplay(generation: generation)
                        }
                    }
                    return
                }
                debugLog("toggleHiDPIEnabled: dimensions changed, recreating")
                manager.destroyAllVirtualDisplays()
                currentVirtualID = 0
            }
            saveCurrentPreset(presetName)
            // Arm reconnect: if createVirtualDisplayAsync fails (no monitor),
            // wasDisconnected stays true so periodicDisplayCheck/handleDisplay-
            // ConfigurationChange will auto-connect when the monitor appears.
            wasDisconnected = true
            UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                autoreleasepool {
                    self?.createVirtualDisplayAsync(config: config, generation: generation)
                }
            }
        }
    }
```

Remove any `#selector(enableHiDPIAction)` or `#selector(disableHiDPIAction)` references left over — they're now dead.

---

### Task 2: Update `rebuildMenu()` Header

Replace the entire header section (lines 1677-1715, from "Status header" through the Fresh separator):

```swift
        // Status header + Enable HiDPI checkmark
        let hiDPIEnabled = UserDefaults.standard.bool(forKey: kHiDPIEnabledKey)
        let enableItem = NSMenuItem(title: "Enable HiDPI", action: #selector(toggleHiDPIEnabled(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = hiDPIEnabled ? .on : .off
        enableItem.isEnabled = hasPreset || isActive  // grayed in Fresh state
        menu.addItem(enableItem)

        if isActive {
            let reapplyItem = NSMenuItem(title: "Reapply HiDPI", action: #selector(reapplyHiDPIAction), keyEquivalent: "")
            reapplyItem.target = self
            menu.addItem(reapplyItem)
        }

        menu.addItem(NSMenuItem.separator())
```

---

### Task 3: Remove `kAutoApplyOnConnectKey` and `toggleAutoApply`

**Step 1:** Delete line 670 (`kAutoApplyOnConnectKey` declaration).

**Step 2:** Delete `toggleAutoApply` method (lines 1905-1908).

**Step 3:** Remove "Auto-Apply on Reconnect" from settings submenu (lines 1806-1809) in `rebuildMenu()`.

**Step 4:** Delete the `kAutoApplyOnConnectKey` default initialization in `checkAndRestoreFromCrash()` (lines 1458-1459).

**Step 5:** Replace all `kAutoApplyOnConnectKey` reads in reconnect paths with `kHiDPIEnabledKey`:
- Line 1058 (`periodicDisplayCheck` Case 2)
- Line 1254 (`handleDisplayConfigurationChange` Case 2)

---

### Task 4: Update `checkAndRestoreFromCrash()`

The auto-restore guard (line 1464) already checks `kAutoRestoreKey` after the `wasDisconnected` guard. Add `kHiDPIEnabledKey` check:

```swift
        // If user explicitly disabled HiDPI, don't auto-restore
        if !UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) {
            debugLog("HiDPI disabled by user — skipping auto-restore")
            return
        }
```

This goes before the `kAutoRestoreKey` check — if the checkmark is off, never auto-restore regardless of crash state.

---

### Task 5: Update `quitApp()` and `applicationWillTerminate()`

`quitApp()` (lines 2833-2839): no change needed — it already preserves keys and calls `NSApp.terminate`.

`applicationWillTerminate()`: no change needed.

---

### Task 6: Add `kHiDPIEnabledKey` Gate to `handleWakeFromSleep`

Wrap both restore paths in `handleWakeFromSleep()` with a `kHiDPIEnabledKey` guard. Defense-in-depth: if the checkmark is off, never restore on wake, even if stale flags linger.

In the wake handler (around line 1111), add at the top of the DispatchQueue block:

```swift
            // If user explicitly disabled HiDPI, don't restore on wake
            guard UserDefaults.standard.bool(forKey: kHiDPIEnabledKey) else {
                debugLog("Wake: HiDPI disabled — skipping restore")
                return
            }
```

This gates the wasDisconnected reconnect branch AND the no-display preset-restore branch.

### Task 7: Build + Verify + Dead Reference Check

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 7: Search for Dead References

```bash
grep -n "enableHiDPIAction\|disableHiDPIAction\|kAutoApplyOnConnectKey\|toggleAutoApply" App/Sources/HiDPIDisplayApp.swift
```

Expected: no results (or only in comments).
