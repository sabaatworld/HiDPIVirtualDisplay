// DisplayArrangementManager.swift
// Saves and restores the virtual display's desktop arrangement.
// Follows opendisplay's manageOrigin() pattern: actively enforce
// the saved origin for a 6-second window after setup (macOS applies
// its own arrangement asynchronously), then passively observe.
//
// Stores both origin and size so a size-changing recreate (preset
// switch) maps the old origin by center, keeping the display on the
// correct side of the desktop (opendisplay DisplayArrangement.swift).

import CoreGraphics
import Foundation

struct DisplayArrangementManager {
    private static let kArrangementX = "displayArrangementX"
    private static let kArrangementY = "displayArrangementY"
    private static let kArrangementW = "displayArrangementWidth"
    private static let kArrangementH = "displayArrangementHeight"

    // MARK: - Save

    /// Save the virtual display's current origin and size to UserDefaults.
    static func save(displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        UserDefaults.standard.set(Double(bounds.origin.x), forKey: kArrangementX)
        UserDefaults.standard.set(Double(bounds.origin.y), forKey: kArrangementY)
        UserDefaults.standard.set(Double(bounds.size.width), forKey: kArrangementW)
        UserDefaults.standard.set(Double(bounds.size.height), forKey: kArrangementH)
    }

    /// Return the saved origin, or nil if never saved.
    static func savedOrigin() -> CGPoint? {
        guard UserDefaults.standard.object(forKey: kArrangementX) != nil else { return nil }
        let x = CGFloat(UserDefaults.standard.double(forKey: kArrangementX))
        let y = CGFloat(UserDefaults.standard.double(forKey: kArrangementY))
        return CGPoint(x: x, y: y)
    }

    /// Return the saved size, or nil if never saved.
    static func savedSize() -> CGSize? {
        guard UserDefaults.standard.object(forKey: kArrangementW) != nil else { return nil }
        let w = CGFloat(UserDefaults.standard.double(forKey: kArrangementW))
        let h = CGFloat(UserDefaults.standard.double(forKey: kArrangementH))
        return CGSize(width: w, height: h)
    }

    /// Return the target origin for a display of the given new size.
    /// If the saved size matches, returns the saved origin verbatim.
    /// If sizes differ (preset switch), maps by center so the display
    /// stays on the same side of the desktop (opendisplay pattern).
    static func targetOrigin(for newSize: CGSize) -> CGPoint? {
        guard let savedOrigin = savedOrigin(), let savedSize = savedSize() else {
            return nil
        }
        if savedSize == newSize {
            return savedOrigin
        }
        // Map by center — keep the display on the same side
        return CGPoint(
            x: savedOrigin.x + (savedSize.width - newSize.width) / 2,
            y: savedOrigin.y + (savedSize.height - newSize.height) / 2
        )
    }

    /// Clear saved arrangement (e.g., user explicitly disabled).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: kArrangementX)
        UserDefaults.standard.removeObject(forKey: kArrangementY)
        UserDefaults.standard.removeObject(forKey: kArrangementW)
        UserDefaults.standard.removeObject(forKey: kArrangementH)
    }

    /// Whether any arrangement has been saved yet.
    static var hasSavedArrangement: Bool {
        UserDefaults.standard.object(forKey: kArrangementX) != nil
    }

    // MARK: - Restore enforcement

    /// Actively enforce the saved arrangement for one tick.
    /// Returns true if an origin change was attempted, false if already correct.
    /// Uses .permanently so macOS's own arrangement record converges to the
    /// user's position (opendisplay pattern — origin moves don't trigger the
    /// ColorSync profile I/O that mode changes do).
    /// WARNING: Does NOT work reliably on mirrored displays (Apple docs: can
    /// remove the display from the mirror set). Call only while standalone.
    static func enforceArrangement(displayID: CGDirectDisplayID, target: CGPoint) -> Bool {
        let origin = CGDisplayBounds(displayID).origin
        guard origin != target else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            NSLog("HiDPI: Arrangement enforce — CGBeginDisplayConfiguration failed for display \(displayID)")
            return false
        }
        let cfgErr = CGConfigureDisplayOrigin(config, displayID, Int32(target.x), Int32(target.y))
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        let settled = CGDisplayBounds(displayID).origin

        // Only persist the settled value if the display actually moved.
        // If WindowServer ignored the move (e.g., display was mirrored),
        // writing the wrong position poisons the saved arrangement.
        if settled != origin {
            UserDefaults.standard.set(Double(settled.x), forKey: kArrangementX)
            UserDefaults.standard.set(Double(settled.y), forKey: kArrangementY)
            NSLog("HiDPI: Arrangement enforce — moved display \(displayID) from (\(Int(origin.x)), \(Int(origin.y))) to (\(Int(settled.x)), \(Int(settled.y))) cfgErr=\(cfgErr) completeErr=\(err)")
        } else {
            NSLog("HiDPI: Arrangement enforce — display \(displayID) did NOT move from (\(Int(origin.x)), \(Int(origin.y))) cfgErr=\(cfgErr) completeErr=\(err)")
        }
        return err == .success
    }
}
