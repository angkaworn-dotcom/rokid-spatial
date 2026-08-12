import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SpatialController()
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var runObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpHotkeys()
        showSettings()

        // SBS runs the working desktop as a brand-new display, so a settings
        // window remembered on the built-in — now parked below and dimmed to
        // zero — is invisible and unreachable; the user's only way out was
        // the emergency hotkey (seen live, first SBS session). Re-show the
        // window once the session is up: showSettings relocates it.
        runObserver = controller.$isRunning.sink { [weak self] running in
            guard running, let self, self.controller.sbsActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showSettings()
            }
        }

        // Useful while iterating: skips the manual Start click so a rebuild
        // can be launched and inspected in one step. `--source=` picks the
        // capture source by raw value (mirror, virtualDesktop, glassesOnly).
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--source=") }),
           let source = SpatialController.CaptureSource(
               rawValue: String(flag.dropFirst("--source=".count))) {
            controller.source = source
        }
        // `--sbs` opts the session into SBS-90, so a rebuild can be launched
        // straight into the mode under test: `--source=glassesOnly --sbs --autostart`.
        if CommandLine.arguments.contains("--sbs") {
            controller.sbs90 = true
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
        // During an SBS session, make sure the window is on the working
        // desktop (the display at the origin — the one the eye sees). Its
        // remembered position may be on the dark parked built-in or under
        // the glasses overlay.
        if controller.sbsActive, controller.isRunning, let window = settingsWindow,
           let target = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
           window.screen !== target {
            var frame = window.frame
            frame.origin = CGPoint(x: target.frame.midX - frame.width / 2,
                                   y: target.frame.midY - frame.height / 2)
            window.setFrame(frame, display: true)
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
