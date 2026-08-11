// Hides the hardware cursor system-wide while glasses-only mode runs.
//
// In that mode the window server composites the cursor above our overlay —
// a head-locked cursor floating in the glasses — and no window level beats
// it: on Apple Silicon the cursor is a hardware plane that is always on top.
// The only way to remove it is to actually hide the cursor, and hiding it
// also stops ScreenCaptureKit from drawing it into captured frames, so the
// renderer paints its own sprite instead (see Renderer.cursorTexture).
//
// CGDisplayHideCursor alone is ignored for apps that are not frontmost, which
// a menu-bar accessory practically never is; the private connection property
// "SetsCursorInBackground" lifts that restriction. The hide counter is scoped
// to this process's window-server connection, so a crash brings the cursor
// back on its own — no rescue path needed.

import CoreGraphics
import Darwin

enum SystemCursor {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetConnectionProperty =
        @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
    private typealias CursorVisible = @convention(c) () -> Bool

    /// One-time setup; harmless if the private symbols ever vanish — hiding
    /// then simply only works while our own app is frontmost.
    private static let canHideInBackground: Bool = {
        guard let mainSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty")
        else { return false }
        let connection = unsafeBitCast(mainSym, to: MainConnectionID.self)()
        let set = unsafeBitCast(setSym, to: SetConnectionProperty.self)
        return set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    /// Removed from the SDK but alive in the framework.
    private static let visibleFunction: CursorVisible? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible")
        else { return nil }
        return unsafeBitCast(sym, to: CursorVisible.self)
    }()

    static var isVisible: Bool { visibleFunction?() ?? false }

    /// Hide/show calls are a per-connection counter, not a flag: every hide
    /// needs a matching show, so show() drains the count.
    private(set) static var hideCount = 0

    static func hide() {
        guard hideCount == 0 else { return }
        _ = canHideInBackground
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Hiding once is not enough: whenever any app sets a new cursor shape —
    /// hovering text, a window edge, a link — the window server makes the
    /// cursor visible again. Call this frequently while the overlay is up.
    static func reassertHidden() {
        guard hideCount > 0, isVisible else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    static func show() {
        while hideCount > 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            hideCount -= 1
        }
    }
}
