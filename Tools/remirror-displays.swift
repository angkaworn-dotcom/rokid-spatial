// remirror-displays — put the glasses back to mirroring the built-in screen.
//
// The last step of a rescue that nothing else does. Killing the app gives the
// screen back and `rokid-display-mode set 0` gives the glasses a sane picture,
// but the arrangement is still whatever macOS remembers — and what it
// remembers is an extended desktop. You end up with the glasses and the
// built-in display showing different things, which is exactly the state you
// were trying to escape, and no software left running to fix it.
//
// So: find the built-in display, find the first real external one (skipping
// our own virtual display, vendor 0x3456 — mirroring *that* would be
// meaningless), and make the external a mirror of the built-in.
//
// .permanently rather than .forSession on purpose: this is the arrangement we
// want macOS to remember, so the next re-enumeration re-applies something
// sensible instead of the extended layout that caused the trouble.
//
// Exits 0 whenever it did not fail — including the one-display no-op case, so
// a rescue script can call it blind without checking anything.
//
// Build:
//   swiftc -O -o .build/remirror-displays Tools/remirror-displays.swift

import CoreGraphics
import Foundation

// Vendor ID of the virtual display the app creates; see VirtualDisplay.swift.
let virtualVendorID: UInt32 = 0x3456

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

let ids = onlineDisplays()
if ids.isEmpty {
    print("remirror: no displays reported — nothing to do")
    exit(0)
}

guard let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    print("remirror: no built-in display found — nothing to mirror to")
    exit(0)
}

let external = ids.first { id in
    id != builtin
        && CGDisplayIsBuiltin(id) == 0
        && CGDisplayVendorNumber(id) != virtualVendorID
}

guard let external else {
    print("remirror: only the built-in display is present — nothing to do")
    exit(0)
}

if CGDisplayMirrorsDisplay(external) == builtin {
    print("remirror: display \(external) already mirrors built-in \(builtin) — nothing to do")
    exit(0)
}

var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else {
    print("remirror: could not begin a display configuration")
    exit(1)
}
CGConfigureDisplayMirrorOfDisplay(config, external, builtin)
let err = CGCompleteDisplayConfiguration(config, .permanently)
if err == .success {
    print("remirror: display \(external) now mirrors built-in \(builtin)")
    exit(0)
} else {
    print("remirror: mirroring failed (CGError \(err.rawValue))")
    exit(1)
}
