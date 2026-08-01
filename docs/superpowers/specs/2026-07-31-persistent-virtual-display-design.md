# Persistent Virtual Display — Design Spec

**Date:** 2026-07-31
**Status:** Draft
**References:** [opendisplay](https://github.com/peetzweg/opendisplay) VirtualDisplay.swift, DisplayArrangement.swift

## Problem

1. **Arrangement resets on every apply/reapply/disable/enable.** The virtual display is destroyed and recreated for every operation, giving macOS a new display identity each time. The user's manual arrangement in System Settings is lost.

2. **Unnecessary process restarts.** The app restarts itself for disconnect, reconnect, resolution changes, refresh rate changes, custom scale, and reapply — a 15–20 second disruption each time. This is driven by the belief that CGVirtualDisplay can only be cleaned up by process death. In reality, releasing all ObjC references properly deallocates the display (the old extra-retain bug was fixed — see `VirtualDisplayManager.m:162-167`). The display IS removed from WindowServer on dealloc.

3. **No preset selection memory.** The menu shows no indication of which preset was last selected. Changing presets while HiDPI is off does nothing visible — the selection is silently saved but the user has no feedback.

## Root cause

The current code treats `CGVirtualDisplay` as transient: create → mirror → detect issue → destroy → restart → recreate. In reality, `CGVirtualDisplay` can live for the full process lifetime if you keep a strong reference, AND it can be properly destroyed in-process by releasing all references. opendisplay confirmed both — they create displays once and hold them until the session ends, using `applySettings:` for mode changes and setting `virtualDisplay = nil` to destroy.

## Solution overview

A `CGVirtualDisplay` lives from first Enable until it needs replacement (dimension change) or app quit. All same-dimension operations work on the same display object with the same `CGDirectDisplayID`. Arrangement is actively saved to UserDefaults and restored via `CGConfigureDisplayOrigin` during a 6-second enforcement window after setup, then passively observed — following opendisplay's `manageOrigin()` pattern. The menu gains radio-button preset selection with a unified Enable/Disable toggle.

## Design

### 1. Display lifecycle

The `CGVirtualDisplay` is created on first Enable and replaced only when framebuffer dimensions change. It is never destroyed for same-dimension operations.

| Operation | Current | New |
|---|---|---|
| First enable | create + mirror | create + mirror + save arrangement |
| Re-enable (after Disable, same preset) | N/A (restart path) | if `displayExists` → re-mirror existing. else → create + mirror. |
| Disconnect (G9 unplugged) | confirm → destroy → relaunch → NSApp.terminate | confirm → break mirror (`resetAllMirroring`) → `isActive = false` |
| Reconnect (G9 returns) | fingerprint match → `restorePreset()` → destroy+recreate → mirror | fingerprint match → re-mirror existing display → start arrangement enforcement |
| Reapply HiDPI (menu) | `scheduleRelaunch()` → relaunch → terminate | break mirror + re-mirror (same display) → start arrangement enforcement |
| Resolution change — same framebuffer dims (rare) | `scheduleRelaunch()` → relaunch → terminate | `applyModeToCurrentDisplay:` → re-mirror |
| Resolution change — different framebuffer dims (common) | `scheduleRelaunch()` → relaunch → terminate → recreate | destroy old + create new + mirror → start arrangement enforcement |
| Refresh rate change (while active) | `relaunchApp()` | `applyModeToCurrentDisplay:` with new rate → re-mirror |
| Custom scale apply (while active) | `relaunchApp()` | destroy old + create new + mirror → start arrangement enforcement |
| Disable HiDPI (menu) | `scheduleRelaunch(clearPreset:true)` → relaunch → terminate | break mirror → `isActive = false`, clear auto-restore flag, keep checkmark preset |
| App quit (genuine) | `disableHiDPIForDisconnect` → destroy → terminate | `saveArrangement()` → `destroyDisplay` → terminate |
| Wake from sleep | `assessDisplayStateAfterWake` → `restorePreset` (destroy+recreate) | re-mirror if broken → start arrangement enforcement |
| Clean up phantoms from crashed previous process (manual) | `markCleanupRestart()` → `relaunchApp()` | **restart still required** — orphans from a dead process are unreachable via the private API. `relaunchApp()` retained for this case only. |
| Clean up phantoms from current process (manual) | `markCleanupRestart()` → `relaunchApp()` | `destroyDisplay` → create new with same descriptor → restore arrangement. No restart. |

**On in-process destroy:** The `VirtualDisplayManager` `releaseDisplayObjects` method (VirtualDisplayManager.m:494-531) properly deallocates the `CGVirtualDisplay` when all references are released. The earlier extra-retain bug (documented at VirtualDisplayManager.m:162-167) was fixed — `alloc/init` returns an owned (+1) reference with no extra retain, so releasing it drops the refcount to zero and the display is removed from WindowServer. This has been observed working: destroying and recreating in the same process with the same serial requires a brief retry window (opendisplay retries up to 8 times with 2s delays — see [VirtualDisplay.swift:346-351](https://github.com/peetzweg/opendisplay/blob/main/Mac/VirtualDisplay.swift#L346-L351)), proving the old display IS being removed.

### 2. VirtualDisplayManager changes

#### 2.1 applyModeToCurrentDisplay (new)

```objc
/// Apply new mode settings to the existing display without destroying it.
/// Preserves the CGDirectDisplayID. Returns NO if no display is active.
- (BOOL)applyModeToCurrentDisplayWithWidth:(unsigned int)width
                                    height:(unsigned int)height
                               refreshRate:(double)refreshRate;
```

Implementation:
1. Construct a new `CGVirtualDisplayMode` with the given width/height/refreshRate.
2. Construct a new `CGVirtualDisplaySettings` with the new mode and current `hiDPI` value.
3. Call `[_display applySettings:settings]` to republish the mode list.
4. Call `CGConfigureDisplayWithDisplayMode` (via a `CGDisplayConfigRef` block with `.forSession`) to switch the *active* mode to the new one. `applySettings:` republishes the mode list but does not switch the current mode — both calls are needed (this is what opendisplay does at [VirtualDisplay.swift:108-111](https://github.com/peetzweg/opendisplay/blob/main/Mac/VirtualDisplay.swift#L108-L111)).
5. Replace the retained `_settings` and `_mode` ivars.

#### 2.2 unmirrorAndDeactivate (new)

```objc
/// Break all mirror sets involving our virtual display. Does NOT release
/// the CGVirtualDisplay — it stays alive and its displayID remains valid.
- (void)unmirrorAndDeactivate;
```

Calls `resetAllMirroring()` but does NOT call `releaseDisplayObjects`. The virtual display persists as an independent display in the desktop. It will appear in System Settings → Displays as a connected display (since it is one). This is acceptable behavior — the display keeps its identity and arrangement, and windows placed on it stay where they are. macOS already moves windows from disconnected displays, so the un-mirrored virtual display being "visible" to the system is fine.

#### 2.3 destroyDisplay (existing, scope reduced)

`destroyAllVirtualDisplays` / `releaseDisplayObjects` — called at:
- `applicationWillTerminate`
- Preset switch with different framebuffer dimensions
- Manual "Clean Up Phantom Displays" action (current-process orphans only)
- Reapply when display object is in a bad state (nil/invalid)

#### 2.4 displayExists (new)

```objc
/// Whether a CGVirtualDisplay is currently held (may be mirrored or not).
@property (nonatomic, readonly) BOOL displayExists;
```

Returns `_currentDisplayID != kCGNullDirectDisplay && _display != nil`.

### 3. Arrangement management (new: DisplayArrangementManager)

Adopts opendisplay's `DisplayArrangement.swift` and `manageOrigin()` patterns.

#### 3.1 Save

```swift
struct DisplayArrangementManager {
    static let kArrangementX = "displayArrangementX"
    static let kArrangementY = "displayArrangementY"

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
}
```

**When saved:**
- After successful mirror setup in `performMirror()`
- After `setMainDisplay()` repositions displays, the post-promotion origin is saved
- By a 2-second observer timer while active: if origin differs from last saved, save the new origin (user dragged the display)
- In `applicationWillTerminate` before destroying the display

#### 3.2 Restore — active enforcement window (6 seconds only)

Following opendisplay's `manageOrigin()` at [VirtualDisplay.swift:123-139](https://github.com/peetzweg/opendisplay/blob/main/Mac/VirtualDisplay.swift#L123-L139):

```swift
/// Actively enforce the saved arrangement for the first 6 seconds after
/// setup. macOS applies its own saved arrangement asynchronously during
/// this window, which can be stale or default. This overrides it.
/// After the window closes, switch to passive observation only (the 2s
/// observer timer in 3.1 handles saving user-initiated changes).
static func enforceArrangement(displayID: CGDirectDisplayID, target: CGPoint) -> Bool {
    let origin = CGDisplayBounds(displayID).origin
    guard origin != target else { return false } // already correct

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    CGConfigureDisplayOrigin(config, displayID, Int32(target.x), Int32(target.y))
    // Use .forSession to avoid ColorSync profile persistence I/O that can
    // stall the daemon (matches the repo's existing pattern at
    // VirtualDisplayManager.m:434-436). The arrangement observer saves
    // to UserDefaults separately, so persistence is handled at our level.
    let err = CGCompleteDisplayConfiguration(config, .forSession)

    // WindowServer snaps to nearest valid arrangement — adopt what it settled on
    let settled = CGDisplayBounds(displayID).origin
    UserDefaults.standard.set(Double(settled.x), forKey: kArrangementX)
    UserDefaults.standard.set(Double(settled.y), forKey: kArrangementY)
    return err == .success
}
```

**Enforcement schedule:**
- A `Timer` fires at 200ms intervals for 6 seconds after setup/reconnect/reapply.
- Each tick calls `enforceArrangement` with the saved target.
- After 6 seconds, the timer invalidates itself and a separate 2-second **observation-only** timer begins (saves origin if changed, never re-pins).
- This avoids fighting user drags in System Settings — once the 6s window closes, the user is in control.

#### 3.3 Interaction with "Keep External as Main Display"

When `kKeepPrimaryDisplayKey` is enabled, `setMainDisplay()` repositions all displays so the virtual display sits at (0,0) as the primary. After this repositioning, `DisplayArrangementManager.save()` is called with the new post-promotion origin. The enforcement window then uses that origin as its target, so there is no conflict.

### 4. Mode enforcement (new)

Following opendisplay's `selectHiDPIMode()` pattern at [VirtualDisplay.swift:92-113](https://github.com/peetzweg/opendisplay/blob/main/Mac/VirtualDisplay.swift#L92-L113):

A 2-second repeating `Timer` checks whether the virtual display is in its correct HiDPI mode. macOS can asynchronously flip it to 1x or replace the mode list. The enforcement loop:
1. Enumerates available modes via `CGDisplayCopyAllDisplayModes`.
2. Checks if the HiDPI mode (target width×height @2x) is present and current.
3. If the mode is missing from the list, re-publishes it via `[_display applySettings:]`.
4. If the mode is present but not current, selects it via `CGConfigureDisplayWithDisplayMode`.

This timer runs only while `isActive == true`. It is created on first enable and invalidated on disable/quit.

### 5. Menu redesign

#### 5.1 State machine

| State | Preset selected | HiDPI active | `displayExists` | Menu shows |
|---|---|---|---|---|
| **Fresh** | No | No | No | No checkmark. "Enable HiDPI" grayed out. |
| **Ready** | Yes | No | Maybe (if previously Disabled) | Checkmark on selected preset. "Enable HiDPI" enabled. |
| **Active** | Yes | Yes | Yes | Checkmark on active preset. "Disable HiDPI" shown. "Reapply HiDPI" shown. |

**Launch-time state resolution:**
1. Active mirror detected (`checkCurrentState()` finds virtual display mirrored) → **Active**, restore preset name from current mode.
2. No active mirror, `kLastPresetKey` is set → **Ready**.
3. No active mirror, no `kLastPresetKey` → **Fresh**.

State transitions:

```
Fresh ──(click any preset)──▶ Ready ──(click Enable)──▶ Active
  ▲                             ▲                          │
  │                             │                          │
  └──(click Disable)────────────┴──(click Disable)─────────┘

Active ──(click different preset)──▶ Active (apply immediately)
Active ──(G9 unplugged)───────────▶ Active + wasDisconnected (un-mirror, keep alive)
Active ◀──(G9 plugged back in)──── Active (re-mirror)
```

#### 5.2 Preset click behavior

| Current state | Action |
|---|---|
| Fresh | Save preset to `kLastPresetKey`, set `kAutoRestoreKey = true`, show checkmark, rebuild menu (→ Ready). "Enable HiDPI" becomes clickable. |
| Ready | Move checkmark to new preset, save to `kLastPresetKey`, set `kAutoRestoreKey = true`. Stay in Ready. |
| Active | Save preset to `kLastPresetKey`, move checkmark. If same framebuffer width×height → `applyModeToCurrentDisplay:` + re-mirror. If different framebuffer → destroy old, create new, mirror, start arrangement enforcement. Stay in Active. |
| Any — clicking already-checked preset | No-op. |

**"Same framebuffer" check:** compares `config.width` and `config.height` of the new preset against the current display's `maxPixelsWide`/`maxPixelsHigh`. In practice, every shipped preset has unique width×height (framebuffer = 2× logical), so the common path is destroy+recreate. The `applyModeToCurrentDisplay:` fast path exists for edge cases (custom scale with same framebuffer, future presets).

#### 5.3 Preset checkmark (radio-button behavior)

Exactly one preset across all submenus has `state = .on`. When a preset is selected, `rebuildMenu()` sets `.on` on the item whose `representedObject` matches `kLastPresetKey` and clears all others. Custom scale items do not get checkmarks (they are actions, not state).

If `kLastPresetKey` holds a custom preset key (starts with `"custom-"`), no standard preset item is checked. The Custom Scale item could show a checkmark based on matching the saved custom config — deferred to implementation.

#### 5.4 Enable/Disable toggle

A single menu item whose title and action toggle based on state:

- **Fresh state:** Title = "Enable HiDPI", action = `enableHiDPIAction`. **Disabled (grayed out).**
- **Ready state:** Title = "Enable HiDPI", action = `enableHiDPIAction`. **Enabled.**
- **Active state:** Title = "Disable HiDPI", action = `disableHiDPIAction`. **Enabled.**

`enableHiDPIAction`:
1. If `displayExists` → the display survived from a previous session (or a prior Disable). Just re-mirror it to the current external display. If the saved preset's dimensions differ from the existing display, destroy and recreate.
2. If `!displayExists` → read saved preset from `kLastPresetKey`, create the virtual display, set up mirroring, save arrangement, start mode and arrangement enforcement timers.
3. `isActive = true`, save `kLastPresetKey`, set `kAutoRestoreKey = true`. Transition → Active.

`disableHiDPIAction`:
1. Call `unmirrorAndDeactivate` (break mirror, keep display alive).
2. Stop mode and arrangement enforcement timers.
3. `isActive = false`, `wasDisconnected = false`.
4. **Clear `kAutoRestoreKey`** — prevents auto-restore on next launch. The user explicitly disabled.
5. **Preserve `kLastPresetKey`** — keeps the checkmark on the selected preset.
6. Transition → Ready.

**Key insight:** `kLastPresetKey` (checkmark memory) and `kAutoRestoreKey` (auto-restore trigger) are separate. Disable clears only the latter. `kWasCrashKey` (existing, set by `saveCurrentPreset`) is repurposed to `kAutoRestoreKey` — same semantics, clearer name.

#### 5.5 Reapply HiDPI

Visible only in Active state. Behavior:
1. If `displayExists` and display is healthy → break mirror, re-mirror to same external display, start arrangement enforcement. No destroy.
2. If display is nil or has invalid displayID → recreate from saved preset, mirror, start enforcement.

#### 5.6 Settings submenu items

The following items are preserved and their behavior adjusted:

- **"Keep External as Main Display"** (checkbox): Works as before. After repositioning, save the post-promotion origin via `DisplayArrangementManager.save()` so the enforcement window uses the correct target.
- **"Auto-Apply on Reconnect"** (checkbox): Gates the reconnect path. When on AND fingerprint matches → re-mirror. When off → do nothing on reconnect.
- **"Auto-Restore After Crash"** (checkbox): Gates `kAutoRestoreKey`. When off AND `kAutoRestoreKey` is set → skip auto-restore on launch. This is the existing `kAutoRestoreKey` defaulting to `true`.
- **"Start at Login"**: Unchanged.
- **"Refresh Rate" submenu**: Selecting a rate while Active calls `applyModeToCurrentDisplay:` with the new rate and re-mirrors. No restart. While Ready/Fresh, just saves the preference.
- **"HDR (Beta)"**: Unchanged.
- **"Check for Updates"**: Unchanged.

#### 5.7 Menu layout examples

**Fresh state:**
```
─── Monitor ───
  Samsung G9 57" ▶
  Samsung G9 49" ▶
  34" Ultrawide (3440×1440) ▶
  38" Ultrawide (3840×1600) ▶
  4K (3840×2160) ▶
───
  Enable HiDPI                      (grayed out)
───
  Keep as Main Display            ✓
  HDR (Beta)
───
  Auto-Apply on Reconnect         ✓
  Auto-Restore After Crash        ✓
  Start at Login                  ✓
  Refresh Rate ▶                   60 Hz ✓
───
  Check for Updates…
  About…
  Quit
```

**Ready state** (G9 57" 1.5x selected, HiDPI off):
```
─── Monitor ───
  Samsung G9 57" ▶                  (child has ✓ on 5120×1440)
  Samsung G9 49" ▶
  …
───
  Enable HiDPI                      (enabled)
───
  Keep as Main Display            ✓
  HDR (Beta)
───
  Auto-Apply on Reconnect         ✓
  Auto-Restore After Crash        ✓
  Start at Login                  ✓
  Refresh Rate ▶                   60 Hz ✓
───
  Check for Updates…
  About…
  Quit
```

**Active state** (HiDPI on):
```
─── Monitor ───
  Samsung G9 57" ▶                  (child has ✓ on active preset)
  Samsung G9 49" ▶
  …
───
  Disable HiDPI
  Reapply HiDPI
───
  Keep as Main Display            ✓
  HDR (Beta)
───
  Auto-Apply on Reconnect         ✓
  Auto-Restore After Crash        ✓
  Start at Login                  ✓
  Refresh Rate ▶                   120 Hz ✓
───
  Check for Updates…
  About…
  Quit
```

### 6. Code to remove

| Item | Reason |
|---|---|
| `relaunchApp()` from routine paths | Kept ONLY for "Clean Up Phantom Displays" (crashed-previous-process orphans). Removed from disconnect, reconnect, reapply, resolution change, refresh rate change, custom scale, disable, enable. |
| `cleanupAfterDisconnect()` | Replaced by `unmirrorAndDeactivate` (no destroy). |
| `disableHiDPIForDisconnect()` | Replaced by `unmirrorAndDeactivate`. |
| `scheduleRelaunch()` | Entirely removed. Reapply and disable actions now work in-process. |
| `isCleanupRestart()` / `markCleanupRestart()` / `cleanupMarkerPath` | No more cleanup restarts for current-process operations. |
| `confirmDisconnect()` restart logic | Simplified — confirms the disconnect, then un-mirrors. No restart. |
| `kWasDisconnectedKey` restart logic | Still marks disconnected state for auto-restore gating, but no restart involved. |
| `disableHiDPISync()` restart paths | Replaced by `disableHiDPIAction` (un-mirror, no restart, no preset clear). |
| `applyPreset(_:)` restart branch (lines 2013-2021) | Replaced by in-process apply (same-dim → `applyModeToCurrentDisplay:`, different-dim → destroy+recreate). |
| `applyCustomConfig(_:)` restart branch (lines 1975-1982) | Replaced by in-process destroy+recreate. |
| `setRefreshRate(_:)` restart branch (lines 1898-1909) | Replaced by `applyModeToCurrentDisplay:` with new rate. |
| `restorePreset()` call sites in reconnect paths | Replaced by `reestablishMirrorOnExistingDisplay()` (new method). |
| `quitApp()` clearing the preset | `quitApp()` must preserve `kLastPresetKey` and `kAutoRestoreKey` for auto-restore on relaunch. |

### 7. Code to add

| Item | Location |
|---|---|
| `applyModeToCurrentDisplayWithWidth:height:refreshRate:` | VirtualDisplayManager.m |
| `unmirrorAndDeactivate` | VirtualDisplayManager.m |
| `displayExists` property | VirtualDisplayManager.h |
| `reestablishMirrorOnExistingDisplay(externalID:)` | HiDPIDisplayApp.swift |
| `DisplayArrangementManager` | New file: App/Sources/DisplayArrangementManager.swift |
| Mode enforcement timer | HiDPIDisplayApp.swift (AppDelegate) |
| Arrangement enforcement timer (200ms × 6s) | HiDPIDisplayApp.swift (AppDelegate) |
| Arrangement observation timer (2s steady-state) | HiDPIDisplayApp.swift (AppDelegate) |
| `enableHiDPIAction` | HiDPIDisplayApp.swift |
| `kAutoRestoreKey` (renamed from `kWasCrashKey`) | HiDPIDisplayApp.swift |
| Updated `rebuildMenu()` with checkmark + state logic | HiDPIDisplayApp.swift |
| Updated `applyPreset(_:)` with in-process apply | HiDPIDisplayApp.swift |
| Updated `setRefreshRate(_:)` with in-process mode change | HiDPIDisplayApp.swift |
| Updated `applyCustomConfig(_:)` with in-process apply | HiDPIDisplayApp.swift |
| Updated `quitApp()` to preserve preset | HiDPIDisplayApp.swift |
| Checkmark management in `addPresetItem` | HiDPIDisplayApp.swift |
| Launch-time state resolution in `applicationDidFinishLaunching` | HiDPIDisplayApp.swift |

### 8. Edge cases preserved

All existing protections remain:
- **Display sleep**: `screensAsleep` flag blocks disconnect handling
- **Transient dropouts**: confirm ladder still runs, now just un-mirrors instead of destroying
- **Ghost "unkn" displays**: filtered in `findRealPhysicalMonitor` (vendor `0x756E6B6E`)
- **Orphaned virtual displays from current process**: detected at launch, cleaned up in-process
- **Orphaned virtual displays from crashed previous process**: still require restart (unreachable via private API). Manual "Clean Up Phantom Displays" retains this path.
- **Mirror failure cap**: 3 max retries, now without restart
- **Fingerprint matching**: validates before auto-restore/reconnect
- **Setup generation**: still cancels stale async closures
- **Stale setup guards**: `isSettingUp` / `isRestarting` still protect concurrent operations
- **Mirror failure fallback**: if re-mirror after reconnect fails, destroy and recreate as last resort

### 9. Testing plan

1. **Fresh start → select preset → Enable:** Launch with no preset. Verify Enable grayed. Select preset. Verify checkmark appears, Enable available. Click Enable. Verify virtual display created, mirror active, arrangement saved.

2. **Active → change preset (different dimensions):** With HiDPI active, select a preset with different framebuffer (e.g., 1.5x → 2.0x). Verify old display destroyed, new one created, mirror active, arrangement restored from saved origin.

3. **Active → Disable:** Click Disable. Verify mirror broken, virtual display still in display list, checkmark stays on preset, menu shows Ready state, `kAutoRestoreKey` cleared.

4. **Disable → re-Enable (same preset):** After Disable, click Enable. Verify existing display is re-mirrored (no new display created), mirror active, arrangement restored.

5. **Disconnect → Reconnect:** Unplug G9 while HiDPI active. Verify mirror breaks (no restart). Plug G9 back in. Verify mirror re-establishes on same display, arrangement restored.

6. **Reapply:** With HiDPI active, click Reapply. Verify mirror breaks and re-establishes (no restart, no destroy), arrangement preserved.

7. **Active → change refresh rate:** With HiDPI active, select different refresh rate from Settings submenu. Verify mode applied in-process (no restart), mirror still active.

8. **App quit → relaunch:** Quit app while HiDPI active. Relaunch. Verify auto-restore triggers, arrangement restored from UserDefaults, checkmark on correct preset, HiDPI active.

9. **Disable → quit → relaunch:** Disable HiDPI, quit, relaunch. Verify app launches in Ready state with checkmark on previously selected preset. HiDPI does NOT auto-restore (user explicitly disabled).

10. **Active → change preset (no-op on same):** Click the already-checked preset. Verify no-op.

11. **Display sleep/wake:** Put Mac to sleep while HiDPI active. Wake. Verify mirror re-establishes, arrangement enforcement runs for 6s.

12. **Custom scale → apply:** Use Custom Scale while HiDPI active. Verify old display destroyed, new custom display created, mirror active. While HiDPI off, verify only the preset is saved (checkmark, Ready state).

13. **"Keep as Main Display" + arrangement:** Enable "Keep as Main Display", then arrange displays. Verify the post-promotion origin is saved and restored correctly.
