import AppKit
import RokidKit

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

// Debug probe: switch the panel to a numbered mode (see DisplayMode), wait
// for enumeration, print every desktop mode macOS then offers, and exit.
// `--panel-mode=4` was added to scope the Station-2-style 90 Hz SBS route.
if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--panel-mode=") }),
   let raw = UInt16(arg.dropFirst("--panel-mode=".count)),
   let mode = DisplayMode(rawValue: raw) {
    do {
        let previous = try RokidDisplay.currentMode()
        print("current mode: \(previous), switching to \(mode)")
        _ = try RokidDisplay.setMode(mode)
        Thread.sleep(forTimeInterval: 5)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids where CGDisplayVendorNumber(id) == 12372 {
            let current = CGDisplayCopyDisplayMode(id)
            print("glasses display \(id): current \(current?.width ?? 0)×\(current?.height ?? 0) " +
                  "@ \(current?.refreshRate ?? 0) px \(current?.pixelWidth ?? 0)×\(current?.pixelHeight ?? 0)")
            for m in (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? [] {
                print(String(format: "  %d×%d @ %.0f Hz  px %d×%d%@",
                             m.width, m.height, m.refreshRate, m.pixelWidth, m.pixelHeight,
                             m.isUsableForDesktopGUI() ? "" : "  (not desktop-usable)"))
            }
        }
        print("restoring mode \(previous)")
        _ = try RokidDisplay.setMode(previous)
    } catch {
        print("panel-mode probe failed: \(error)")
    }
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
