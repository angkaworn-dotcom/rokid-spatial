import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SpatialController()
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpHotkeys()
        showSettings()

        // Useful while iterating: skips the manual Start click so a rebuild
        // can be launched and inspected in one step. `--source=` picks the
        // capture source by raw value (mirror, virtualDesktop, glassesOnly).
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--source=") }),
           let source = SpatialController.CaptureSource(
               rawValue: String(flag.dropFirst("--source=".count))) {
            controller.source = source
        }
        if CommandLine.arguments.contains("--autostart") {
            controller.start()
        }
    }

    /// There is no Dock icon to click, so opening the app a second time is the
    /// natural way to go looking for its window. Make that work.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        // Leaving the glasses in side-by-side with nothing drawing to them
        // would strand the user with an unreadable display, so this must run
        // even on an abrupt quit — and it must run to completion before the
        // process exits, or the un-mirror watch dies mid-loop and macOS
        // re-mirrors unopposed. Synchronous on purpose; quit takes a few
        // seconds and that is fine.
        controller.shutdownForQuit()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eyeglasses",
            accessibilityDescription: "Rokid Spatial"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Re-centre", action: #selector(recenter), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Emergency Stop", action: #selector(emergencyStop),
                                keyEquivalent: "\u{1b}"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }

        item.menu = menu
        statusItem = item
    }

    // MARK: Hotkeys

    private func setUpHotkeys() {
        // Panic button, registered first so it is the least likely to be
        // missing if anything else goes wrong during setup. It has to work
        // without the user being able to see the screen.
        hotkeys.register(keyCode: kVK_Escape, label: "Emergency stop") { [controller] in
            Task { @MainActor in controller.emergencyStop() }
        }
        hotkeys.register(keyCode: kVK_ANSI_R, label: "Re-centre") { [controller] in
            Task { @MainActor in controller.recenter() }
        }
        hotkeys.register(keyCode: kVK_ANSI_C, label: "Calibrate") { [controller] in
            Task { @MainActor in controller.calibrate() }
        }
        hotkeys.register(keyCode: kVK_ANSI_M, label: "Toggle mode") { [controller] in
            Task { @MainActor in controller.toggleMode() }
        }
        hotkeys.register(keyCode: kVK_ANSI_Equal, label: "Further") { [controller] in
            Task { @MainActor in controller.nudgeDistance(0.25) }
        }
        hotkeys.register(keyCode: kVK_ANSI_Minus, label: "Nearer") { [controller] in
            Task { @MainActor in controller.nudgeDistance(-0.25) }
        }
        hotkeys.register(keyCode: kVK_ANSI_RightBracket, label: "Bigger") { [controller] in
            Task { @MainActor in controller.nudgeSize(0.1) }
        }
        hotkeys.register(keyCode: kVK_ANSI_LeftBracket, label: "Smaller") { [controller] in
            Task { @MainActor in controller.nudgeSize(-0.1) }
        }
        hotkeys.register(keyCode: kVK_UpArrow, label: "Screen up") { [controller] in
            Task { @MainActor in controller.nudgeHeight(0.05) }
        }
        hotkeys.register(keyCode: kVK_DownArrow, label: "Screen down") { [controller] in
            Task { @MainActor in controller.nudgeHeight(-0.05) }
        }
        hotkeys.start()
    }

    // MARK: Actions

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Rokid Spatial"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func recenter() {
        controller.recenter()
    }

    @objc private func emergencyStop() {
        controller.emergencyStop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
