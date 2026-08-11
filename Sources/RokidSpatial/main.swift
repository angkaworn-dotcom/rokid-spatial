import AppKit

// Display-restore helper mode, spawned by the app as it quits.
//
// The restore cannot run inside the quitting process: its Core Graphics
// display state is a snapshot that only refreshes when the run loop processes
// reconfiguration events, and during `applicationWillTerminate` the run loop
// is done processing anything. The dying app watched an already-mirrored
// system report "unmirrored" for eight straight seconds — verified against an
// outside observer that saw mirroring the whole time. A fresh process has a
// fresh connection, sees the truth, and outlives the app.
if CommandLine.arguments.contains("--restore-displays") {
    AppLog.append("helper: restoring displays")
    let displays = DisplayManager()
    displays.log = { AppLog.append("helper: " + $0) }
    displays.restore()
    exit(0)
}

let application = NSApplication.shared
// Top-level code is not main-actor isolated here, but it does run on the main
// thread, which is what AppDelegate's isolation actually requires.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// Menu-bar app: no Dock icon, no application menu.
application.setActivationPolicy(.accessory)
application.run()
