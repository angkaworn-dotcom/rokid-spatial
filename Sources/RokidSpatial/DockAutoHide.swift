// Keeps the Dock auto-hidden while a glasses session runs.
//
// This is a cursor fix, not a space optimisation. Measured (2026-08-14):
// the hardware cursor cannot be hidden while it hovers the visible Dock —
// every weapon tried (CGDisplayHideCursor at any rate, CGSHideCursor,
// CGSObscureCursor, cursor scale re-asserted at 20 Hz) reads visible
// 120/120 samples there, while every other pixel of the screen, including
// the menu bar and the Dock-free bottom corners, reads 0/120. The Dock's
// tile strip force-shows the cursor, full stop — which the user saw as a
// second, head-locked cursor whenever the pointer crossed the bottom of
// the screen.
//
// With the Dock auto-hidden the strip is ordinary desktop (measured clean),
// and the real cursor only appears in the moment the user deliberately
// summons the Dock — the one moment a head-locked cursor is also standing
// exactly where they are looking.
//
// The user's own setting is respected: if they already auto-hide, nothing
// is touched. The forced state is flagged in UserDefaults so a crash can't
// strand it — launch, quit, and the display-restore helper all restore.

import Foundation

enum DockAutoHide {
    private static let flagKey = "dockAutohideForced"

    static func engage() {
        guard current() != "1" else { return }  // their own choice — leave it
        write(autohide: true)
        UserDefaults.standard.set(true, forKey: flagKey)
        killDock()
        AppLog.append("dock: auto-hide engaged for the session (cursor fix)")
    }

    static func restore() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        write(autohide: false)
        UserDefaults.standard.removeObject(forKey: flagKey)
        killDock()
        AppLog.append("dock: auto-hide restored")
    }

    private static func current() -> String {
        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        read.arguments = ["read", "com.apple.dock", "autohide"]
        let pipe = Pipe()
        read.standardOutput = pipe
        read.standardError = Pipe()
        guard (try? read.run()) != nil else { return "" }
        read.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func write(autohide: Bool) {
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.dock", "autohide",
                           "-bool", autohide ? "true" : "false"]
        try? write.run()
        write.waitUntilExit()
    }

    private static func killDock() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}
