// Reports which Space a given display is currently showing.
//
// Why polling instead of a notification: NSWorkspace.activeSpaceDidChange-
// Notification is the documented way to hear about Space transitions, but
// measured live (2026-08-15) it never fires when a video enters native
// fullscreen on a *virtual* display we capture — the very transition that
// freezes our SCStream (see bounceCaptureForSpaceChange()). The window
// server does move that display to a new Space; it just doesn't tell us.
// So the 1 Hz watchdog asks directly, once a second, and compares.
//
// The two functions below are private CoreGraphics/SkyLight API — no Apple
// header declares them, but they are exported from the shared cache and
// resolve through CoreGraphics at link time (verified on macOS 26.6). Same
// private-API caveats as CGVirtualDisplayPrivate.h: they may change or
// vanish in any macOS release. Nothing here is load-bearing — a space id of
// 0 (symbol refusing, unknown display, no UUID) means "don't know", and the
// caller must treat that as "nothing to do" rather than as a change.

import Foundation
import CoreGraphics
import ColorSync

// MARK: Private CoreGraphics / SkyLight Space API

/// The window server connection for this process.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// The id of the Space currently displayed on the managed display named by
/// its UUID string. Returns 0 for a display it does not know.
@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ displayUUID: CFString) -> UInt64

enum SpaceWatch {
    /// The Space id currently shown on `displayID`, or 0 when it cannot be
    /// determined. Callers must ignore 0 rather than treat it as a change.
    static func currentSpaceID(forDisplay displayID: CGDirectDisplayID) -> UInt64 {
        guard displayID != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid) else { return 0 }
        return CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), uuidString)
    }
}
