# Persistent Virtual Display — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the destroy+restart lifecycle with a persistent `CGVirtualDisplay` that lives for the full app session, add active arrangement management following opendisplay's pattern, and redesign the menu with radio-button preset selection and a unified Enable/Disable toggle.

**Architecture:** `VirtualDisplayManager` gains `applyModeToCurrentDisplay:`, `unmirrorAndDeactivate`, and `displayExists` for in-process operations. A new `DisplayArrangementManager` saves/restores arrangement via `CGConfigureDisplayOrigin` with a 6-second enforcement window. `HiDPIDisplayApp` is refactored to eliminate `relaunchApp()` from all routine paths, replace `scheduleRelaunch()` entirely, and rebuild the menu as a state machine (Fresh → Ready → Active).

**Tech Stack:** Swift 5, AppKit, CoreGraphics (private APIs), Objective-C (MRC for VirtualDisplayManager), build.sh (clang + swiftc, no Xcode project)

## Global Constraints

- No process restarts for routine operations (disconnect, reconnect, resolution change, refresh rate change, reapply, enable, disable)
- `CGVirtualDisplay` persists for the app session; destroyed only at quit or framebuffer dimension change
- Arrangement saved to UserDefaults as (x, y); enforced via `CGConfigureDisplayOrigin` for 6s after setup, then observed passively
- Preset checkmark is radio-button style (single selection across all submenus)
- Enable/Disable is a single toggling menu item
- `kAutoRestoreKey` (renamed from `kWasCrashKey`) controls auto-restore on launch; `kLastPresetKey` controls checkmark
- All existing edge case protections preserved (display sleep, ghost displays, fingerprint matching, setup generation, mirror failure cap)
- Project builds via `App/build.sh`. Add new `.swift` files to `SWIFT_SOURCES` in build.sh.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `App/Sources/VirtualDisplayManager.h` | Modify | Declare `applyModeToCurrentDisplayWithWidth:height:refreshRate:`, `unmirrorAndDeactivate`, `displayExists`, `maxPixelsWide`, `maxPixelsHigh` |
| `App/Sources/VirtualDisplayManager.m` | Modify | Implement new methods; expose maxPixelsWide/High |
| `App/Sources/DisplayArrangementManager.swift` | **Create** | Arrangement save, restore enforcement, observation |
| `App/Sources/HiDPIDisplayApp.swift` | Major modify | State machine, menu, lifecycle, timers, all action methods |
| `App/build.sh` | Modify | Add `Sources/DisplayArrangementManager.swift` to `SWIFT_SOURCES` |

## Verify commands

All "Verify compilation" steps use:
```bash
cd App && bash build.sh 2>&1 | tail -30
```
Expected: "Build complete: build/G9 Helper.app"

---

### Task 1: VirtualDisplayManager — New Methods

**Files:**
- Modify: `App/Sources/VirtualDisplayManager.h:60-65` (insert after `unmirrorAndDeactivate` declaration area)
- Modify: `App/Sources/VirtualDisplayManager.m:480-531` (insert after `destroyVirtualDisplay:`)

**Interfaces:**
- Produces: `- (BOOL)applyModeToCurrentDisplayWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;`
- Produces: `- (void)unmirrorAndDeactivate;`
- Produces: `@property (nonatomic, readonly) BOOL displayExists;`
- Produces: `@property (nonatomic, readonly) unsigned int maxPixelsWide;`
- Produces: `@property (nonatomic, readonly) unsigned int maxPixelsHigh;`

- [ ] **Step 1: Add declarations to VirtualDisplayManager.h**

Insert after line 68 (`destroyAllVirtualDisplays` declaration):

```objc
/// Whether a CGVirtualDisplay is currently held (may be mirrored or not).
@property (nonatomic, readonly) BOOL displayExists;

/// The framebuffer dimensions of the currently-held display.
/// Reads from the descriptor (which reflects what was requested at creation),
/// not the current mode (which macOS can flip to 1x asynchronously).
@property (nonatomic, readonly) unsigned int maxPixelsWide;
@property (nonatomic, readonly) unsigned int maxPixelsHigh;

/// Apply new mode settings to the existing display without destroying it.
/// Preserves the CGDirectDisplayID. Returns NO if no display is active.
- (BOOL)applyModeToCurrentDisplayWithWidth:(unsigned int)width
                                    height:(unsigned int)height
                               refreshRate:(double)refreshRate;

/// Break all mirror sets involving our virtual display. Does NOT release
/// the CGVirtualDisplay — it stays alive and its displayID remains valid.
- (void)unmirrorAndDeactivate;
```

- [ ] **Step 2: Add displayExists + maxPixelsWide/High getters to VirtualDisplayManager.m**

Insert after line 137 (`currentDisplayID` getter):

```objc
- (BOOL)displayExists {
    return _currentDisplayID != kCGNullDirectDisplay && _display != nil;
}

- (unsigned int)maxPixelsWide {
    return _descriptor ? _descriptor.maxPixelsWide : 0;
}

- (unsigned int)maxPixelsHigh {
    return _descriptor ? _descriptor.maxPixelsHigh : 0;
}
```

- [ ] **Step 3: Add unmirrorAndDeactivate to VirtualDisplayManager.m**

Insert after line 492 (end of `destroyAllVirtualDisplays`):

```objc
- (void)unmirrorAndDeactivate {
    NSLog(@"VDM: unmirrorAndDeactivate called — breaking mirrors, keeping display alive");
    [self resetAllMirroring];
    // Deliberately do NOT call releaseDisplayObjects.
    // The CGVirtualDisplay stays alive so its displayID remains valid.
    NSLog(@"VDM: unmirrorAndDeactivate complete — display %u still held", _currentDisplayID);
}
```

- [ ] **Step 4: Add applyModeToCurrentDisplayWithWidth:height:refreshRate: to VirtualDisplayManager.m**

Insert after the new `unmirrorAndDeactivate`:

```objc
- (BOOL)applyModeToCurrentDisplayWithWidth:(unsigned int)width
                                    height:(unsigned int)height
                               refreshRate:(double)refreshRate {
    if (!_display || _currentDisplayID == kCGNullDirectDisplay) {
        NSLog(@"VDM: applyModeToCurrentDisplay — no active display");
        return NO;
    }

    unsigned int modeWidth = _settings.hiDPI ? width / 2 : width;
    unsigned int modeHeight = _settings.hiDPI ? height / 2 : height;

    CGVirtualDisplayMode *newMode = [[CGVirtualDisplayMode alloc] initWithWidth:modeWidth
                                                                         height:modeHeight
                                                                    refreshRate:refreshRate];
    if (!newMode) {
        NSLog(@"VDM: ERROR — failed to create new mode");
        return NO;
    }

    // Build new settings with the new mode, preserving HiDPI
    CGVirtualDisplaySettings *newSettings = [[CGVirtualDisplaySettings alloc] init];
    newSettings.hiDPI = _settings.hiDPI;
    NSArray *newModesArray = [[NSArray alloc] initWithObjects:newMode count:1];
    newSettings.modes = newModesArray;

    NSLog(@"VDM: applyModeToCurrentDisplay — applying %ux%u @ %.1f Hz to display %u",
          modeWidth, modeHeight, refreshRate, _currentDisplayID);

    // Step 1: Republish the mode list
    BOOL applied = [_display applySettings:newSettings];
    if (!applied) {
        NSLog(@"VDM: ERROR — applySettings failed");
        [newMode release];
        [newSettings release];
        [newModesArray release];
        return NO;
    }

    // Step 2: Switch the active mode (applySettings republishes but doesn't switch).
    // Track whether we found and switched to the target mode.
    BOOL modeSwitched = NO;
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
        NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(_currentDisplayID, (__bridge CFDictionaryRef)opts);
        if (modes) {
            CFIndex count = CFArrayGetCount(modes);
            for (CFIndex i = 0; i < count; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                if (CGDisplayModeGetWidth(mode) == modeWidth &&
                    CGDisplayModeGetHeight(mode) == modeHeight &&
                    fabs(CGDisplayModeGetRefreshRate(mode) - refreshRate) < 0.5) {
                    CGConfigureDisplayWithDisplayMode(config, _currentDisplayID, mode, NULL);
                    modeSwitched = YES;
                    break;
                }
            }
            CFRelease(modes);
        }
        if (modeSwitched) {
            CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            NSLog(@"VDM: Mode switch result: %d", err);
        } else {
            // No matching mode found — cancel the empty config
            CGCancelDisplayConfiguration(config);
            NSLog(@"VDM: WARNING — mode %ux%u @ %.1f Hz not found in display's mode list",
                  modeWidth, modeHeight, refreshRate);
        }
    }

    // Replace retained ivars
    if (_mode) [_mode release];
    _mode = newMode;  // already +1 from alloc/init
    if (_settings) [_settings release];
    _settings = newSettings;  // already +1 from alloc/init
    if (_modesArray) [_modesArray release];
    _modesArray = newModesArray;  // already +1 from alloc/init

    NSLog(@"VDM: applyModeToCurrentDisplay complete — display %u now %ux%u @ %.1f Hz",
          _currentDisplayID, modeWidth, modeHeight, refreshRate);
    return YES;
}
```

- [ ] **Step 5: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 2: DisplayArrangementManager — New File

**Files:**
- Create: `App/Sources/DisplayArrangementManager.swift`

**Interfaces:**
- Produces: `DisplayArrangementManager.save(displayID:)`
- Produces: `DisplayArrangementManager.savedOrigin() -> CGPoint?`
- Produces: `DisplayArrangementManager.enforceArrangement(displayID:target:) -> Bool`

- [ ] **Step 1: Create the file**

```swift
// DisplayArrangementManager.swift
// Saves and restores the virtual display's desktop arrangement.
// Follows opendisplay's manageOrigin() pattern: actively enforce
// the saved origin for a 6-second window after setup (macOS applies
// its own arrangement asynchronously), then passively observe.

import CoreGraphics
import Foundation

struct DisplayArrangementManager {
    private static let kArrangementX = "displayArrangementX"
    private static let kArrangementY = "displayArrangementY"

    // MARK: - Save

    /// Save the virtual display's current origin to UserDefaults.
    static func save(displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        UserDefaults.standard.set(Double(bounds.origin.x), forKey: kArrangementX)
        UserDefaults.standard.set(Double(bounds.origin.y), forKey: kArrangementY)
    }

    /// Return the saved origin, or nil if never saved.
    static func savedOrigin() -> CGPoint? {
        guard UserDefaults.standard.object(forKey: kArrangementX) != nil else { return nil }
        let x = CGFloat(UserDefaults.standard.double(forKey: kArrangementX))
        let y = CGFloat(UserDefaults.standard.double(forKey: kArrangementY))
        return CGPoint(x: x, y: y)
    }

    /// Clear saved arrangement (e.g., user explicitly disabled).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: kArrangementX)
        UserDefaults.standard.removeObject(forKey: kArrangementY)
    }

    // MARK: - Restore enforcement

    /// Actively enforce the saved arrangement for one tick.
    /// Returns true if an origin change was attempted, false if already correct.
    /// Uses .forSession to avoid ColorSync profile persistence I/O.
    static func enforceArrangement(displayID: CGDirectDisplayID, target: CGPoint) -> Bool {
        let origin = CGDisplayBounds(displayID).origin
        guard origin != target else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayOrigin(config, displayID, Int32(target.x), Int32(target.y))
        let err = CGCompleteDisplayConfiguration(config, .forSession)

        // WindowServer snaps to nearest valid arrangement — adopt what it settled on
        let settled = CGDisplayBounds(displayID).origin
        UserDefaults.standard.set(Double(settled.x), forKey: kArrangementX)
        UserDefaults.standard.set(Double(settled.y), forKey: kArrangementY)
        return err == .success
    }
}
```

- [ ] **Step 2: Add file to build.sh**

Edit `App/build.sh` line 16, change:
```bash
SWIFT_SOURCES="Sources/HiDPIDisplayApp.swift"
```
To:
```bash
SWIFT_SOURCES="Sources/HiDPIDisplayApp.swift Sources/DisplayArrangementManager.swift"
```

- [ ] **Step 3: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 3: State Variables — Rename kWasCrashKey, Add Timer Properties

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:662-716`

**Interfaces:**
- Consumes: `DisplayArrangementManager` (from Task 2)
- Produces: `kAutoRestoreKey` (was `kWasCrashKey`), `modeEnforcementTimer`, `arrangementEnforcementTimer`, `arrangementObserverTimer`, `lastSavedOrigin`

- [ ] **Step 1: Replace kWasCrashKey with kAutoRestoreKey, add timer properties**

At line 668-669, replace:
```swift
    private let kLastPresetKey = "lastActivePreset"
    private let kWasCrashKey = "wasRunningWhenCrashed"
    private let kAutoRestoreKey = "autoRestoreOnCrash"
```

With:
```swift
    private let kLastPresetKey = "lastActivePreset"
    private let kAutoRestoreKey = "wasRunningWhenCrashed"  // renamed: controls auto-restore on launch
```

Note: the key string stays `"wasRunningWhenCrashed"` for backward compatibility with existing UserDefaults. The old `kAutoRestoreKey` (key `"autoRestoreOnCrash"`, line 670) and `kAutoApplyOnConnectKey` (line 671) are unchanged.

- [ ] **Step 2: Add timer properties + stopEnforcementTimers stub after line 710 (screenWakeObserver)**

```swift
    // Enforcement timers (new)
    private var modeEnforcementTimer: Timer?       // 2s — re-asserts HiDPI mode
    private var arrangementEnforcementTimer: Timer? // 200ms × 6s — pin arrangement
    private var arrangementObserverTimer: Timer?    // 2s — observe user drags
    private var lastSavedOrigin: CGPoint?           // last origin written to UserDefaults

    /// Stop all enforcement/observer timers. Full implementation in Task 11.
    /// Declared here so Tasks 7 and 9 can call it (compilation dependency).
    func stopEnforcementTimers() {
        modeEnforcementTimer?.invalidate()
        modeEnforcementTimer = nil
        arrangementEnforcementTimer?.invalidate()
        arrangementEnforcementTimer = nil
        arrangementObserverTimer?.invalidate()
        arrangementObserverTimer = nil
    }
```

- [ ] **Step 3: Update all references to kWasCrashKey**

Replace every occurrence of `kWasCrashKey` with `kAutoRestoreKey` in HiDPIDisplayApp.swift:
- Line 669: declaration (done above)
- Line 1346: `checkAndRestoreFromCrash()` reads it
- Line 1475: `saveCurrentPreset()` writes it
- Line 1481: `clearSavedPreset()` writes it

```bash
sed -i '' 's/kWasCrashKey/kAutoRestoreKey/g' App/Sources/HiDPIDisplayApp.swift
```

- [ ] **Step 4: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 4: saveCurrentPreset / clearSavedPreset — Separate Checkmark from Auto-Restore

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1473-1483`

- [ ] **Step 1: Update saveCurrentPreset to not set auto-restore**

Replace lines 1473-1477:
```swift
    func saveCurrentPreset(_ presetName: String) {
        UserDefaults.standard.set(presetName, forKey: kLastPresetKey)
        UserDefaults.standard.set(true, forKey: kAutoRestoreKey)
        debugLog("Saved preset for crash recovery: \(presetName)")
    }
```

Note: unchanged from current — it already sets both. The change is in `clearSavedPreset` and the new `disableHiDPIAction`.

- [ ] **Step 2: Add saveCheckmarkPreset helper (new)**

Insert after `clearSavedPreset` (line 1483):

```swift
    /// Save the preset for menu checkmark only — does NOT enable auto-restore.
    /// Used when user selects a preset while HiDPI is off (Ready state).
    func saveCheckmarkPreset(_ presetName: String) {
        UserDefaults.standard.set(presetName, forKey: kLastPresetKey)
        debugLog("Saved checkmark preset: \(presetName)")
    }
```

- [ ] **Step 3: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 5: Launch-Time State Resolution

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:718-800` (applicationDidFinishLaunching)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1485-1499` (cleanupStaleState)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1514-1539` (checkCurrentState)

- [ ] **Step 1: Update cleanupStaleState — don't destroy displays from this process**

Replace lines 1485-1499:

```swift
    func cleanupStaleState() {
        debugLog("Cleaning up stale display state...")
        let manager = VirtualDisplayManager.shared()

        let hasExternalDisplay = findExternalDisplay() != nil
        debugLog("External display connected: \(hasExternalDisplay)")

        // Only reset mirroring — do NOT destroy virtual displays that survived
        // from a previous session of THIS process (they're still valid).
        // Orphans from a DIFFERENT (crashed) process are handled before we
        // get here by the relaunch guard in applicationDidFinishLaunching.
        if manager.displayExists {
            debugLog("Virtual display \(manager.currentDisplayID) survived from previous session — un-mirroring")
            manager.resetAllMirroring()
        } else {
            // No live display — just clean up any leftover mirror configs
            manager.resetAllMirroring()
        }

        debugLog("Stale state cleanup complete")
    }
```

- [ ] **Step 2: Update checkCurrentState — detect active mirror and set state**

Replace lines 1514-1539:

```swift
    func checkCurrentState() {
        currentVirtualID = 0
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            let mirrorOf = CGDisplayMirrorsDisplay(displayID)
            if mirrorOf != kCGNullDirectDisplay {
                guard CGDisplayVendorNumber(mirrorOf) == 0x1234 else { continue }
                currentVirtualID = mirrorOf
                if let mode = CGDisplayCopyDisplayMode(mirrorOf) {
                    let width = mode.width
                    let height = mode.height
                    currentPresetName = "\(width)x\(height)"
                    isActive = true
                    CGDisplayModeRelease(mode)
                    debugLog("Found existing mirror: \(displayID) mirrors \(mirrorOf) at \(width)x\(height)")
                }
                break
            }
        }

        // Also check if VirtualDisplayManager already holds a display
        // (survived from a previous run of this process)
        let manager = VirtualDisplayManager.shared()
        if !isActive && manager.displayExists {
            currentVirtualID = manager.currentDisplayID
            debugLog("Found existing virtual display (un-mirrored): \(currentVirtualID)")
        }

        debugLog("Launch state: isActive=\(isActive), displayExists=\(manager.displayExists), preset=\(currentPresetName)")
    }
```

- [ ] **Step 3: Update applicationDidFinishLaunching — resolve launch state**

Replace lines 775-782 (from `checkCurrentState()` through `rebuildMenu()`):

```swift
        // Check for existing virtual display and mirror state
        checkCurrentState()

        // Resolve launch state for menu:
        // 1. Active mirror found → Active (restore preset name from current mode)
        // 2. No mirror, kLastPresetKey set → Ready
        // 3. No mirror, no kLastPresetKey → Fresh
        if isActive && currentPresetName.isEmpty,
           let savedPreset = UserDefaults.standard.string(forKey: kLastPresetKey) {
            currentPresetName = savedPreset
        }

        // Check if we should auto-restore after crash or disconnect restart
        checkAndRestoreFromCrash()

        // Build menu with correct initial state
        rebuildMenu()
```

- [ ] **Step 4: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 6: rebuildMenu — Checkmarks and State Logic

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1541-1795` (rebuildMenu)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1931-1936` (addPresetItem)

- [ ] **Step 1: Update addPresetItem to accept checkmark state**

Replace lines 1931-1936:

```swift
    func addPresetItem(to menu: NSMenu, preset: String, title: String, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset
        item.state = checked ? .on : .off
        menu.addItem(item)
    }
```

- [ ] **Step 2: Determine which preset is checked**

Add a helper computed property at line 662 area:

```swift
    /// The preset key that should show a checkmark (from kLastPresetKey).
    private var checkedPresetKey: String? {
        guard let preset = UserDefaults.standard.string(forKey: kLastPresetKey),
              !preset.isEmpty else { return nil }
        return preset
    }
```

- [ ] **Step 3: Rewrite rebuildMenu header section with state logic**

Replace lines 1541-1565 (the header portion of rebuildMenu):

```swift
    func rebuildMenu() {
        let menu = NSMenu()
        let hasPreset = checkedPresetKey != nil

        // Determine state for menu layout
        // Fresh: no preset selected, no HiDPI active
        // Ready: preset selected, HiDPI not active
        // Active: HiDPI active

        // Status header
        if isActive {
            let statusItem = NSMenuItem(title: "Active: \(currentPresetName)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())

            let disableItem = NSMenuItem(title: "Disable HiDPI", action: #selector(disableHiDPIAction), keyEquivalent: "")
            disableItem.target = self
            menu.addItem(disableItem)

            let reapplyItem = NSMenuItem(title: "Reapply HiDPI", action: #selector(reapplyHiDPIAction), keyEquivalent: "")
            reapplyItem.target = self
            menu.addItem(reapplyItem)

            menu.addItem(NSMenuItem.separator())
        } else if hasPreset {
            let statusItem = NSMenuItem(title: "Ready — select Enable to start", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())

            let enableItem = NSMenuItem(title: "Enable HiDPI", action: #selector(enableHiDPIAction), keyEquivalent: "")
            enableItem.target = self
            menu.addItem(enableItem)

            menu.addItem(NSMenuItem.separator())
        } else {
            let statusItem = NSMenuItem(title: "Select a preset below", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())

            let enableItem = NSMenuItem(title: "Enable HiDPI", action: nil, keyEquivalent: "")
            enableItem.isEnabled = false
            menu.addItem(enableItem)

            menu.addItem(NSMenuItem.separator())
        }
```

- [ ] **Step 4: Update preset submenu construction to pass checkmark**

For each `addPresetItem` call in rebuildMenu, pass `checked:` based on whether the preset key matches `checkedPresetKey`. Pattern (apply to all submenus):

```swift
        let g9Menu = NSMenu()
        let checkedPreset = checkedPresetKey
        addPresetItem(to: g9Menu, preset: "g9-57-6144x1728", title: "6144×1728 (1.25x) - More Space", checked: checkedPreset == "g9-57-6144x1728")
        addPresetItem(to: g9Menu, preset: "g9-57-5908x1662", title: "5908×1662 (1.3x)", checked: checkedPreset == "g9-57-5908x1662")
        addPresetItem(to: g9Menu, preset: "g9-57-5632x1584", title: "5632×1584 (1.36x)", checked: checkedPreset == "g9-57-5632x1584")
        addPresetItem(to: g9Menu, preset: "g9-57-5486x1543", title: "5486×1543 (1.4x)", checked: checkedPreset == "g9-57-5486x1543")
        addPresetItem(to: g9Menu, preset: "g9-57-5297x1490", title: "5297×1490 (1.45x)", checked: checkedPreset == "g9-57-5297x1490")
        addPresetItem(to: g9Menu, preset: "g9-57-5120x1440", title: "5120×1440 (1.5x) ★ Recommended", checked: checkedPreset == "g9-57-5120x1440")
        addPresetItem(to: g9Menu, preset: "g9-57-4800x1350", title: "4800×1350 (1.6x)", checked: checkedPreset == "g9-57-4800x1350")
        addPresetItem(to: g9Menu, preset: "g9-57-4389x1234", title: "4389×1234 (1.75x)", checked: checkedPreset == "g9-57-4389x1234")
        addPresetItem(to: g9Menu, preset: "g9-57-3840x1080", title: "3840×1080 (2.0x) - Larger Text", checked: checkedPreset == "g9-57-3840x1080")
        addCustomScaleItem(to: g9Menu, nativeWidth: 7680, nativeHeight: 2160, ppi: 140)
```

Apply the same `checked:` pattern to all other submenus (g49Menu, uwMenu, uw38Menu, k4Menu).

- [ ] **Step 5: Build and verify**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 7: enableHiDPIAction + Updated disableHiDPIAction + reapplyHiDPIAction

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:2450-2476` (reapplyHiDPIAction + disableHiDPIAction area)
- Create: `App/Sources/HiDPIDisplayApp.swift` — new `enableHiDPIAction` (insert before reapplyHiDPIAction)

- [ ] **Step 1: Add enableHiDPIAction**

Insert before `reapplyHiDPIAction` (line 2450):

```swift
    @objc func enableHiDPIAction() {
        debugLog("enableHiDPIAction called, isRestarting=\(isRestarting)")
        guard !isRestarting, !isSettingUp else {
            debugLog("enableHiDPIAction: blocked (restarting or setting up)")
            return
        }
        guard let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
              !presetName.isEmpty else {
            debugLog("enableHiDPIAction: no preset selected")
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
            debugLog("enableHiDPIAction: unknown preset \(presetName)")
            return
        }

        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration
        StatusWindowController.shared.show(message: "Enabling HiDPI...")

        let manager = VirtualDisplayManager.shared()

        if manager.displayExists {
            // Display survived from a previous session or prior Disable.
            // If dimensions match, just re-mirror. Otherwise destroy + recreate.
            let currentW = manager.maxPixelsWide
            let currentH = manager.maxPixelsHigh
            if currentW == config.width && currentH == config.height {
                debugLog("enableHiDPIAction: reusing existing display \(manager.currentDisplayID)")
                saveCurrentPreset(presetName)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    autoreleasepool {
                        self?.reestablishMirrorOnExistingDisplay(generation: generation)
                    }
                }
                return
            }
            debugLog("enableHiDPIAction: dimensions changed (\(currentW)x\(currentH) → \(config.width)x\(config.height)), recreating")
            manager.destroyAllVirtualDisplays()
            currentVirtualID = 0
        }

        // Create fresh display
        saveCurrentPreset(presetName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            autoreleasepool {
                self?.createVirtualDisplayAsync(config: config, generation: generation)
            }
        }
    }
```

Note: `manager.maxPixelsWide`/`maxPixelsHigh` were added in Task 1 Step 2 — they read from the descriptor, which is stable regardless of what active mode macOS selected.

- [ ] **Step 2: Add reestablishMirrorOnExistingDisplay**

Insert after the helpers above:

```swift
    /// Re-mirror an existing virtual display to the current external display.
    /// Used after Disable→Enable (same preset) and on reconnect.
    /// Preserves currentPresetName across the call — performMirror overwrites it
    /// from config, but during re-mirror the config is unknown (we're just re-
    /// attaching the existing display). Restore from kLastPresetKey after.
    func reestablishMirrorOnExistingDisplay(generation: Int) {
        guard generation == setupGeneration else {
            debugLog("Stale reestablishMirror, aborting")
            return
        }
        guard let externalID = findExternalDisplay() else {
            debugLog("reestablishMirrorOnExistingDisplay: no external display found")
            isSettingUp = false
            StatusWindowController.shared.hide()
            return
        }
        let manager = VirtualDisplayManager.shared()
        let virtualID = manager.currentDisplayID
        guard virtualID != kCGNullDirectDisplay else {
            debugLog("reestablishMirrorOnExistingDisplay: no virtual display — recreating from preset")
            // Mirror-failure fallback: spec §8. Destroy and recreate as last resort.
            manager.destroyAllVirtualDisplays()
            currentVirtualID = 0
            if let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
               !presetName.isEmpty {
                restorePreset(presetName)
            }
            return
        }

        debugLog("Reestablishing mirror: \(virtualID) -> \(externalID)")
        currentVirtualID = virtualID
        targetExternalDisplayID = externalID
        // Save the name before performMirror overwrites it
        let savedName = currentPresetName

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            autoreleasepool {
                // Use a dummy config — performMirror will set currentPresetName
                // from config.logicalWidth/logicalHeight, which would show "0x0".
                // We restore the saved name afterward in the success path.
                self?.performMirror(virtualID: virtualID, externalID: externalID,
                                    config: PresetConfig(name: "", width: manager.maxPixelsWide,
                                                         height: manager.maxPixelsHigh,
                                                         logicalWidth: manager.maxPixelsWide / 2,
                                                         logicalHeight: manager.maxPixelsHigh / 2,
                                                         ppi: 140, hiDPI: true),
                                    generation: generation)
            }
        }
    }
```

- [ ] **Step 3: Replace disableHiDPIAction**

Replace lines 2465-2476 (`disableHiDPIAction`) and the old `disableHiDPISync()` at 2046:

```swift
    @objc func disableHiDPIAction() {
        debugLog("disableHiDPIAction called")
        guard !isRestarting, !isSettingUp else { return }

        setupGeneration += 1
        isSettingUp = false
        let manager = VirtualDisplayManager.shared()

        // Break mirror, keep display alive
        manager.unmirrorAndDeactivate()

        // Stop enforcement timers
        stopEnforcementTimers()

        // Clear active state
        currentVirtualID = 0
        targetExternalDisplayID = 0
        isActive = false
        wasDisconnected = false
        currentPresetName = ""

        // Clear auto-restore (user explicitly disabled)
        UserDefaults.standard.set(false, forKey: kAutoRestoreKey)
        UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)

        // Preserve kLastPresetKey for checkmark
        debugLog("HiDPI disabled (preset checkmark preserved, auto-restore cleared)")
        rebuildMenu()
    }
```

- [ ] **Step 4: Replace reapplyHiDPIAction**

Replace lines 2450-2463:

```swift
    @objc func reapplyHiDPIAction() {
        debugLog("reapplyHiDPIAction called, isRestarting=\(isRestarting), isActive=\(isActive)")
        guard !isRestarting, !isSettingUp else {
            debugLog("reapplyHiDPIAction: blocked")
            return
        }
        guard isActive || VirtualDisplayManager.shared().displayExists else {
            debugLog("reapplyHiDPIAction: no active display, nothing to reapply")
            rebuildMenu()
            return
        }

        let manager = VirtualDisplayManager.shared()

        if manager.displayExists && manager.currentDisplayID != kCGNullDirectDisplay {
            // Healthy display: break mirror and re-establish
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            StatusWindowController.shared.show(message: "Reapplying HiDPI...")
            manager.resetAllMirroring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                autoreleasepool {
                    self?.reestablishMirrorOnExistingDisplay(generation: generation)
                }
            }
        } else {
            // Bad state: recreate from saved preset
            guard let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
                  !presetName.isEmpty else {
                debugLog("reapplyHiDPIAction: no saved preset to restore from")
                return
            }
            debugLog("reapplyHiDPIAction: display in bad state, recreating from preset \(presetName)")
            manager.destroyAllVirtualDisplays()
            currentVirtualID = 0
            restorePreset(presetName)
        }
    }
```

- [ ] **Step 5: Remove disableHiDPISync**

Remove the entire `disableHiDPISync()` function at lines 2046-2072. It's been replaced by `disableHiDPIAction` above.

- [ ] **Step 6: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 8: Updated applyPreset, applyCustomConfig, setRefreshRate

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1997-2043` (applyPreset)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1957-1995` (applyCustomConfig)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1889-1909` (setRefreshRate)

- [ ] **Step 1: Rewrite applyPreset — no restart, in-process apply**

Replace lines 1997-2043:

```swift
    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let presetName = sender.representedObject as? String else { return }

        // No-op if already checked
        if presetName == checkedPresetKey && isActive {
            debugLog("applyPreset: \(presetName) already active, no-op")
            return
        }

        debugLog(">>> Applying preset: \(presetName)")

        guard let config = presetConfigs[presetName] else {
            debugLog("ERROR: Unknown preset \(presetName)")
            return
        }

        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)

        if isActive || VirtualDisplayManager.shared().displayExists {
            // Active or display exists — apply in-process
            let manager = VirtualDisplayManager.shared()

            // Check if backing dimensions differ from existing display
            let currentW = manager.maxPixelsWide
            let currentH = manager.maxPixelsHigh

            if currentW == config.width && currentH == config.height && manager.displayExists {
                // Same framebuffer: applyModeToCurrentDisplay + re-mirror
                debugLog("Same framebuffer (\(config.width)x\(config.height)), applying mode in-process")
                let rate = getDisplayRefreshRate(findExternalDisplay() ?? 0)
                manager.applyModeToCurrentDisplay(withWidth: config.width, height: config.height, refreshRate: rate)
                saveCurrentPreset(presetName)
                currentPresetName = "\(config.logicalWidth)x\(config.logicalHeight)"
                // Re-mirror to apply the mode change
                if let externalID = findExternalDisplay() {
                    targetExternalDisplayID = externalID
                    currentVirtualID = manager.currentDisplayID
                    manager.resetAllMirroring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        autoreleasepool {
                            self?.performMirror(virtualID: manager.currentDisplayID, externalID: externalID,
                                                config: config, generation: self?.setupGeneration ?? 0)
                        }
                    }
                }
                rebuildMenu()
            } else {
                // Different framebuffer: destroy old, create new
                debugLog("Different framebuffer (\(currentW)x\(currentH) → \(config.width)x\(config.height)), recreating")
                manager.destroyAllVirtualDisplays()
                currentVirtualID = 0
                isActive = false
                isSettingUp = true
                setupGeneration += 1
                let generation = setupGeneration
                saveCurrentPreset(presetName)
                StatusWindowController.shared.show(message: "Switching to \(config.logicalWidth)x\(config.logicalHeight)...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    autoreleasepool {
                        self?.createVirtualDisplayAsync(config: config, generation: generation)
                    }
                }
            }
        } else {
            // Fresh or Ready state — just save the checkmark
            saveCheckmarkPreset(presetName)
            rebuildMenu()
            debugLog("Preset \(presetName) selected (checkmark only)")
        }
    }
```

- [ ] **Step 2: Rewrite applyCustomConfig — no restart**

Replace lines 1957-1995:

```swift
    func applyCustomConfig(_ config: PresetConfig) {
        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
        let presetKey = "custom-\(config.logicalWidth)x\(config.logicalHeight)"
        let customDict: [String: Any] = [
            "name": config.name,
            "width": config.width,
            "height": config.height,
            "logicalWidth": config.logicalWidth,
            "logicalHeight": config.logicalHeight,
            "ppi": config.ppi,
            "hiDPI": config.hiDPI
        ]
        UserDefaults.standard.set(customDict, forKey: "customPresetConfig")

        if isActive || VirtualDisplayManager.shared().displayExists {
            // Active: destroy old, create new in-process
            debugLog("Active display exists, recreating with custom config in-process")
            let manager = VirtualDisplayManager.shared()
            manager.destroyAllVirtualDisplays()
            currentVirtualID = 0
            isActive = false
            isSettingUp = true
            setupGeneration += 1
            let generation = setupGeneration
            saveCurrentPreset(presetKey)
            StatusWindowController.shared.show(message: "Switching to custom scale...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                autoreleasepool {
                    self?.createVirtualDisplayAsync(config: config, generation: generation)
                }
            }
        } else {
            // Ready/Fresh: just save the checkmark
            saveCheckmarkPreset(presetKey)
            rebuildMenu()
            debugLog("Custom config saved (checkmark only)")
        }
    }
```

- [ ] **Step 3: Rewrite setRefreshRate — no restart**

Replace lines 1889-1909:

```swift
    @objc func setRefreshRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? NSNumber else { return }
        let oldRate = UserDefaults.standard.double(forKey: kRefreshRateKey)
        UserDefaults.standard.set(rate.doubleValue, forKey: kRefreshRateKey)
        debugLog("Refresh rate set to: \(rate.doubleValue == 0 ? "Auto" : "\(rate.doubleValue) Hz")")

        if isActive && oldRate != rate.doubleValue {
            debugLog("Active display present, applying refresh rate in-process")
            let manager = VirtualDisplayManager.shared()
            if manager.displayExists {
                let effectiveRate = rate.doubleValue == 0 ? getDisplayRefreshRate(manager.currentDisplayID) : rate.doubleValue
                let currentW = manager.maxPixelsWide
                let currentH = manager.maxPixelsHigh
                manager.applyModeToCurrentDisplay(withWidth: currentW, height: currentH, refreshRate: effectiveRate)
                // Re-mirror to apply
                if let externalID = findExternalDisplay() {
                    manager.resetAllMirroring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        autoreleasepool {
                            self?.performMirror(virtualID: manager.currentDisplayID, externalID: externalID,
                                                config: PresetConfig(name: "", width: currentW, height: currentH,
                                                                     logicalWidth: currentW/2, logicalHeight: currentH/2,
                                                                     ppi: 140, hiDPI: true),
                                                generation: self?.setupGeneration ?? 0)
                        }
                    }
                }
            }
        }
        rebuildMenu()
    }
```

- [ ] **Step 4: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 9: Disconnect/Reconnect Paths — No Restart

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:880-935` (periodicDisplayCheck)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1062-1133` (handleDisplayConfigurationChange)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1206-1273` (scheduleDisconnectConfirmation, confirmDisconnect, cleanupAfterDisconnect)

- [ ] **Step 1: Remove cleanupAfterDisconnect, simplify confirmDisconnect**

Remove `cleanupAfterDisconnect()` entirely (lines 1252-1273). Replace `confirmDisconnect` (lines 1217-1250):

```swift
    private func confirmDisconnect(attempt: Int) {
        let delay: Double = 4.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            // Abort if we're setting up, restarting, or screens are asleep
            if self.isSettingUp || self.isRestarting || self.screensAsleep {
                self.disconnectConfirmationPending = false
                return
            }

            // Check if monitor is back
            if let realMonitor = self.findRealPhysicalMonitor() {
                self.disconnectConfirmationPending = false
                debugLog("Disconnect confirmation: monitor \(realMonitor) reappeared (transient dropout)")
                if self.isActive {
                    // Mirror may have been severed by the transient dropout — repair it
                    self.ensureMirrorIntact()
                }
                // If mirror was severed and unrecoverable, reestablish from scratch
                if !self.isActive || self.wasDisconnected {
                    DispatchQueue.main.async { [weak self] in
                        self?.setupGeneration += 1
                        self?.isSettingUp = true
                        self?.reestablishMirrorOnExistingDisplay(generation: self?.setupGeneration ?? 0)
                    }
                }
                return
            }

            if attempt < 3 {
                debugLog("Disconnect attempt \(attempt)/3 — retrying in \(delay)s")
                self.confirmDisconnect(attempt: attempt + 1)
            } else {
                // Confirmed disconnect — just un-mirror, keep display alive
                debugLog(">>> Disconnect confirmed — un-mirroring virtual display")
                self.disconnectConfirmationPending = false
                self.wasDisconnected = true
                UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
                UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)

                let manager = VirtualDisplayManager.shared()
                manager.unmirrorAndDeactivate()
                self.isActive = false
                self.stopEnforcementTimers()
                self.rebuildMenu()
            }
        }
    }
```

- [ ] **Step 2: Update scheduleDisconnectConfirmation**

Replace lines 1206-1215:

```swift
    func scheduleDisconnectConfirmation() {
        if disconnectConfirmationPending { return }
        if isSettingUp || isRestarting { return }
        if screensAsleep { return }  // Panel dark = not an unplug
        disconnectConfirmationPending = true
        debugLog("Scheduling disconnect confirmation...")
        confirmDisconnect(attempt: 1)
    }
```

- [ ] **Step 3: Update periodicDisplayCheck — Case 1 (disconnect)**

Replace the disconnect case in `periodicDisplayCheck()` (lines 897-911):

```swift
            if isActive && realMonitor == nil {
                if screensAsleep || isSettingUp || isRestarting { return }
                if !disconnectConfirmationPending {
                    scheduleDisconnectConfirmation()
                }
                return
            }
```

- [ ] **Step 4: Update periodicDisplayCheck — Case 2 (reconnect)**

Replace the reconnect case (lines 914-934):

```swift
            // Case 2: Reconnect — was disconnected, monitor returned
            if !isActive && wasDisconnected && realMonitor != nil {
                guard failCount < maxMirrorRetries else { return }
                guard UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey) else {
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

- [ ] **Step 5: Update handleDisplayConfigurationChange — Case 1 and 2**

Apply the same pattern changes to `handleDisplayConfigurationChange()` (lines 1072-1133):
- Case 1 (disconnect): just schedule confirmation, no restart
- Case 2 (reconnect): call `reestablishMirrorOnExistingDisplay` instead of `restorePreset`

```swift
            // Case 1
            if isActive && currentVirtualID != 0 {
                let realMonitor = findRealPhysicalMonitor()
                if realMonitor == nil {
                    scheduleDisconnectConfirmation()
                    return
                }
                // Monitor present — ensure mirror is intact
                ensureMirrorIntact()
                return
            }
            
            // Case 2: Reconnect
            if !isActive && wasDisconnected {
                guard let _ = findRealPhysicalMonitor() else { return }
                guard UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey) else { return }
                guard connectedMonitorMatchesSavedPreset() else { return }
                debugLog("Display reconfiguration: monitor reconnected, reestablishing mirror")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                isSettingUp = true
                setupGeneration += 1
                let generation = setupGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    autoreleasepool {
                        self?.reestablishMirrorOnExistingDisplay(generation: generation)
                    }
                }
                return
            }
```

- [ ] **Step 6: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 10: Wake from Sleep Paths

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:937-1008` (handleWakeFromSleep, assessDisplayStateAfterWake)

- [ ] **Step 1: Update handleWakeFromSleep**

Replace lines 937-963:

```swift
    func handleWakeFromSleep() {
        debugLog(">>> System woke from sleep")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            guard !self.isSettingUp, !self.isRestarting else {
                debugLog("Skipping wake assessment — already setting up or restarting")
                return
            }

            let manager = VirtualDisplayManager.shared()

            // Mirror survived sleep intact
            if self.isActive && manager.displayExists {
                if let ext = self.findExternalDisplay(),
                   CGDisplayMirrorsDisplay(ext) == self.currentVirtualID {
                    debugLog("Mirror survived wake intact — touching nothing")
                    return
                }
                // Virtual is alive but mirror severed — reattach
                debugLog("Mirror severed during sleep — reestablishing")
                self.isSettingUp = true
                self.setupGeneration += 1
                let gen = self.setupGeneration
                self.reestablishMirrorOnExistingDisplay(generation: gen)
                return
            }

            // wasDisconnected — try to restore if monitor is back
            if self.wasDisconnected, let _ = self.findRealPhysicalMonitor() {
                if self.connectedMonitorMatchesSavedPreset() {
                    self.wasDisconnected = false
                    UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                    self.isSettingUp = true
                    self.setupGeneration += 1
                    let gen = self.setupGeneration
                    self.reestablishMirrorOnExistingDisplay(generation: gen)
                }
                return
            }

            // No virtual display at all — restore from preset
            if !manager.displayExists,
               let preset = UserDefaults.standard.string(forKey: kLastPresetKey),
               !preset.isEmpty,
               UserDefaults.standard.bool(forKey: kAutoRestoreKey) {
                self.assessDisplayStateAfterWake(preset: preset, attempt: 1, generation: self.setupGeneration)
            }
        }
    }
```

- [ ] **Step 2: Update assessDisplayStateAfterWake to use restorePreset (which now works in-process)**

The function at lines 970-1008 will work as-is since `restorePreset` now operates in-process (updated in Task 12). No changes needed beyond the existing retry logic.

- [ ] **Step 3: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 11: Mode Enforcement + Arrangement Timers + performMirror Update

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:2173-2240` (performMirror — add arrangement save)
- Modify: `App/Sources/HiDPIDisplayApp.swift:2106-2171` (createVirtualDisplayAsync — add timer start)

- [ ] **Step 1: Add timer management methods**

Insert after line 716 (screensAsleep var):

```swift
    // MARK: - Enforcement Timers

    func startEnforcementTimers(virtualID: CGDirectDisplayID) {
        stopEnforcementTimers()

        // --- Arrangement enforcement: 200ms × 6 seconds ---
        guard let savedOrigin = DisplayArrangementManager.savedOrigin() else {
            // No saved arrangement — start observing only
            startArrangementObserver(virtualID: virtualID)
            return
        }

        let deadline = Date().addingTimeInterval(6.0)
        arrangementEnforcementTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if Date() > deadline {
                timer.invalidate()
                self.arrangementEnforcementTimer = nil
                // Switch to passive observation
                self.startArrangementObserver(virtualID: virtualID)
                debugLog("Arrangement enforcement window closed — switching to observation")
                return
            }
            let changed = DisplayArrangementManager.enforceArrangement(displayID: virtualID, target: savedOrigin)
            if changed {
                self.lastSavedOrigin = savedOrigin
            }
        }

        // --- Mode enforcement: 2s repeating ---
        modeEnforcementTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isActive else { return }
            self.enforceHiDPIMode()
        }
    }

    func startArrangementObserver(virtualID: CGDirectDisplayID) {
        arrangementObserverTimer?.invalidate()
        lastSavedOrigin = DisplayArrangementManager.savedOrigin()
        arrangementObserverTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isActive else { return }
            let origin = CGDisplayBounds(virtualID).origin
            if origin != self.lastSavedOrigin {
                DisplayArrangementManager.save(displayID: virtualID)
                self.lastSavedOrigin = origin
            }
        }
    }

    /// NOTE: stopEnforcementTimers() is already defined in Task 3 as a stub.
    /// This full implementation replaces it. The Task 3 stub is functionally
    /// identical — it already invalidates all three timers.

    /// Enforce the HiDPI mode on the virtual display. Called by the 2s timer.
    /// Follows opendisplay's selectHiDPIMode() pattern.
    func enforceHiDPIMode() {
        let manager = VirtualDisplayManager.shared()
        guard manager.displayExists else { return }
        let displayID = manager.currentDisplayID

        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(displayID, opts) else { return }
        let modes = modeList as [AnyObject]
        // Note: CGDisplayCopyAllDisplayModes returns a CFArray; modes are
        // CGDisplayModeRefs owned by the array, not individually retained.
        // We must release the array but not the individual modes.

        // Find the HiDPI mode: pixelWidth == 2 * width
        guard let currentMode = CGDisplayCopyDisplayMode(displayID) else {
            // Can't read current mode — re-apply settings to republish
            if let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
               let config = presetConfigs[presetName] {
                let rate = getDisplayRefreshRate(findExternalDisplay() ?? 0)
                manager.applyModeToCurrentDisplay(withWidth: config.width, height: config.height, refreshRate: rate)
            }
            return
        }
        defer { CGDisplayModeRelease(currentMode) }

        let curW = CGDisplayModeGetWidth(currentMode)
        let curPW = CGDisplayModeGetPixelWidth(currentMode)

        // Already in a HiDPI mode (pixelWidth == 2 * width): nothing to do
        if curPW == curW * 2 { return }

        // Find and select a HiDPI mode
        for case let mode as CGDisplayMode in modes {
            if CGDisplayModeGetPixelWidth(mode) == CGDisplayModeGetWidth(mode) * 2 {
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success else { continue }
                CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
                CGCompleteDisplayConfiguration(config, .forSession)
                debugLog("Mode enforcement: re-selected HiDPI mode \(CGDisplayModeGetWidth(mode))x\(CGDisplayModeGetHeight(mode))@2x")
                return
            }
        }
        // Note: CGDisplayCopyAllDisplayModes modes are owned by the CFArray
        // and don't need individual release — the array release handles them.

        // No HiDPI mode found — re-publish via applySettings
        debugLog("Mode enforcement: no @2x mode found, re-publishing")
        if let presetName = UserDefaults.standard.string(forKey: kLastPresetKey),
           let config = presetConfigs[presetName] {
            let rate = getDisplayRefreshRate(findExternalDisplay() ?? 0)
            manager.applyModeToCurrentDisplay(withWidth: config.width, height: config.height, refreshRate: rate)
        }
    }
```

- [ ] **Step 2: Update performMirror — save arrangement on success**

At line 2190-2198 (after `if success {`), add arrangement save + timer start:

```swift
        if success {
            isActive = true
            currentPresetName = "\(config.logicalWidth)x\(config.logicalHeight)"
            targetExternalDisplayID = externalID
            UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
            saveMonitorFingerprint(externalID)
            StatusWindowController.shared.updateStatus("HiDPI enabled: \(config.logicalWidth)x\(config.logicalHeight)")
            debugLog(">>> HiDPI setup complete, monitoring for disconnect")

            // Save arrangement and start enforcement timers
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                DisplayArrangementManager.save(displayID: virtualID)
                self.startEnforcementTimers(virtualID: virtualID)
                // Re-save after setMainDisplay may have moved things
                if UserDefaults.standard.bool(forKey: self.kKeepPrimaryDisplayKey) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        DisplayArrangementManager.save(displayID: virtualID)
                    }
                }
            }
```

- [ ] **Step 3: Update performMirror — update failure to not restart**

At the failure path (lines 2210-2232), replace `relaunchApp()` logic with in-process retry:

```swift
        } else {
            debugLog("Mirror failed, cleaning up...")
            manager.destroyVirtualDisplay(virtualID)
            currentVirtualID = 0
            isActive = false
            currentPresetName = ""

            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey) + 1
            UserDefaults.standard.set(failCount, forKey: kMirrorFailureCountKey)

            if failCount < maxMirrorRetries {
                wasDisconnected = true
                UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
                debugLog("Mirror failure \(failCount)/\(maxMirrorRetries), will retry when monitor is ready")
                StatusWindowController.shared.updateStatus("Waiting for display...")
            } else {
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                debugLog("Mirror failed \(failCount) times, stopping auto-retry. Use menu to apply manually.")
                StatusWindowController.shared.updateStatus("Setup failed — apply manually from menu")
            }
        }
```

- [ ] **Step 4: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 12: setMainDisplay, quitApp, applicationWillTerminate, checkAndRestoreFromCrash, restorePreset

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift:1823-1875` (setMainDisplay)
- Modify: `App/Sources/HiDPIDisplayApp.swift:2477-2481` (quitApp)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1502-1512` (applicationWillTerminate)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1345-1413` (checkAndRestoreFromCrash)
- Modify: `App/Sources/HiDPIDisplayApp.swift:1415-1471` (restorePreset)

- [ ] **Step 1: Update setMainDisplay — save post-promotion arrangement**

After the display configuration completes in `setMainDisplay` (around line 1864), add:

```swift
            // Save arrangement after primary display promotion
            if ok, VirtualDisplayManager.shared().displayExists {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    DisplayArrangementManager.save(displayID: VirtualDisplayManager.shared().currentDisplayID)
                }
            }
```

- [ ] **Step 2: Update quitApp — preserve preset, don't clear**

Replace lines 2477-2481:

```swift
    @objc func quitApp() {
        debugLog("Quit requested by user")
        // Save arrangement before quitting
        let manager = VirtualDisplayManager.shared()
        if manager.displayExists {
            DisplayArrangementManager.save(displayID: manager.currentDisplayID)
        }
        // Preserve kLastPresetKey and kAutoRestoreKey for next launch
        // (disableHiDPIAction already cleared kAutoRestoreKey if user explicitly disabled)
        NSApp.terminate(nil)
    }
```

- [ ] **Step 3: Update applicationWillTerminate — save arrangement, stop timers, destroy display**

Replace lines 1502-1512:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        debugLog("App terminating - cleaning up...")

        stopDisplayChangeMonitoring()
        stopEnforcementTimers()

        let manager = VirtualDisplayManager.shared()
        if manager.displayExists {
            DisplayArrangementManager.save(displayID: manager.currentDisplayID)
        }

        manager.resetAllMirroring()
        manager.destroyAllVirtualDisplays()

        debugLog("Cleanup complete, terminating")
    }
```

- [ ] **Step 4: Update checkAndRestoreFromCrash — use kAutoRestoreKey**

The existing code already uses `kWasCrashKey` (now `kAutoRestoreKey` from Task 3). The only change needed is on the reconnect guard — after a Disable, `kAutoRestoreKey` is cleared so this function won't auto-restore:

Replace the `wasDisconnected` guard (lines 1361-1364):

```swift
        // If we restarted after disconnect (not explicit disable), wait for monitor
        if wasDisconnected {
            debugLog("Restarted after disconnect — waiting for monitor reconnection")
            return
        }

        // If user explicitly disabled, don't auto-restore
        if !UserDefaults.standard.bool(forKey: kAutoRestoreKey) {
            debugLog("Auto-restore disabled by user — skipping")
            return
        }
```

- [ ] **Step 5: Update restorePreset — no restart, in-process**

Replace lines 1415-1471:

```swift
    func restorePreset(_ presetName: String) {
        let migratedName = migratePresetName(presetName)
        let config: PresetConfig

        if let standard = presetConfigs[migratedName] {
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
            debugLog("ERROR: Unknown preset for restore: \(presetName)")
            isSettingUp = false
            return
        }

        if migratedName != presetName {
            debugLog("Migrated preset name: \(presetName) -> \(migratedName)")
            saveCurrentPreset(migratedName)
        }

        debugLog(">>> Auto-restoring preset: \(presetName)")

        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration

        StatusWindowController.shared.show(message: "Restoring display configuration...")

        let manager = VirtualDisplayManager.shared()
        manager.resetAllMirroring()
        if manager.displayExists {
            manager.destroyAllVirtualDisplays()
        }
        currentVirtualID = 0
        isActive = false
        currentPresetName = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            autoreleasepool {
                self?.createVirtualDisplayAsync(config: config, generation: generation)
            }
        }

        saveCurrentPreset(presetName)
    }
```

- [ ] **Step 6: Verify compilation**

```bash
cd App && bash build.sh 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"

---

### Task 13: Remove Dead Code

**Files:**
- Modify: `App/Sources/HiDPIDisplayApp.swift`

- [ ] **Step 1: Remove scheduleRelaunch**

Remove the entire `scheduleRelaunch(message:clearPreset:)` function (currently at lines 2437-2448). This function was used by `reapplyHiDPIAction`, `disableHiDPIAction`, and other actions to trigger restarts — all those callers now work in-process.

Note: `relaunchApp()` itself is **kept** — it's still used by the crashed-previous-process orphan detection path.

- [ ] **Step 2: Remove relaunchApp callers from routine paths**

Verify `relaunchApp()` is only called from:
1. `cleanUpDisplays()` (line 2407-2431) — for crashed-previous-process orphans. **Keep.** Also keep its `markCleanupRestart()` call (line 2428).
2. The orphaned-display guard in `applicationDidFinishLaunching` (line 771). **Keep.**
3. `scheduleRelaunch()` — **removed** (the function itself is gone).

Remove any remaining references to `scheduleRelaunch()` in action methods. The `relaunchApp()` function itself stays — it's still needed for the two remaining call sites above.

- [ ] **Step 3: Keep isCleanupRestart, markCleanupRestart, cleanupMarkerPath for crashed-previous-process path**

The cleanup marker and restart-loop guard are still needed for the crashed-previous-process orphan path (the only remaining `relaunchApp()` caller). **Do NOT remove** `cleanupMarkerPath`, `isCleanupRestart()`, or `markCleanupRestart()`. The launch guard stays:

```swift
        if hasOrphanedVirtualDisplay() && !isCleanupRestart() {
            debugLog("Orphaned virtual displays detected from previous crash, restarting to clean up...")
            markCleanupRestart()
            relaunchApp()
            return
        }
```

Also keep `markCleanupRestart()` call in `cleanUpDisplays()` (line 2428).

- [ ] **Step 4: Remove disableHiDPIForDisconnect**

Remove the entire `disableHiDPIForDisconnect()` function (lines 1315-1335). It's replaced by the logic in `applicationWillTerminate`.

- [ ] **Step 5: Clean up removed code references**

Search for any remaining references to `scheduleRelaunch`, `cleanupAfterDisconnect`, `disableHiDPIForDisconnect`, `isCleanupRestart`, `markCleanupRestart`, `cleanupMarkerPath`, `disableHiDPISync` and remove them all.

```bash
grep -n "scheduleRelaunch\|cleanupAfterDisconnect\|disableHiDPIForDisconnect\|isCleanupRestart\|markCleanupRestart\|cleanupMarkerPath\|disableHiDPISync" App/Sources/HiDPIDisplayApp.swift
```

Expected: no results (or only in comments).

- [ ] **Step 6: Verify compilation and full build**

```bash
cd App && xcodebuild -project HiDPIVirtualDisplay.xcodeproj -scheme HiDPIVirtualDisplay build 2>&1 | tail -30
```

Expected: "Build complete: build/G9 Helper.app"
