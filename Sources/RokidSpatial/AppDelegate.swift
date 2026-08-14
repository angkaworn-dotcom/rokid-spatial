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
    private var settingsRescueTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpHotkeys()
        showSettings()

        // Standalone sessions swap the desktop out from under the settings
        // window, leaving it on a hidden display — unreachable, and the
        // user's only way out was the emergency hotkey (seen live). One
        // early fix is not enough either: macOS re-applies remembered
        // arrangements for many seconds after startup and threw the window
        // back onto the glasses' sliver (also seen live). Retry on a
        // schedule; each attempt acts only if the window is misplaced.
        runObserver = controller.$isRunning.sink { [weak self] running in
            guard let self else { return }
            self.settingsRescueTimer?.invalidate()
            self.settingsRescueTimer = nil
            guard running else { return }
            if self.controller.source == .glassesOnly {
                for delay in [1.0, 5.0, 10.0, 20.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.relocateSettingsIfNeeded()
                    }
                }
            }
            // The fixed retries end at 20 s, and macOS has re-applied
            // remembered arrangements later than that (seen live: the
            // settings window rode the built-in into its parked spot and
            // "wouldn't open"). A standing rescue closes the gap — but only
            // off desktops the user cannot see, so a window deliberately
            // parked on a side screen stays where they put it.
            self.settingsRescueTimer = Timer.scheduledTimer(withTimeInterval: 5,
                                                            repeats: true) { _ in
                Task { @MainActor [weak self] in
                    self?.rescueSettingsFromHiddenDesktop()
                }
            }
        }

        // Useful while iterating: skips the manual Start click so a rebuild
        // can be launched and inspected in one step. `--source=` picks the
        // capture source by raw value (mirror, glassesOnly).
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--source=") }),
           let source = SpatialController.CaptureSource(
               rawValue: String(flag.dropFirst("--source=".count))) {
            controller.source = source
        }
        // `--sbs` (90 Hz), `--sbs=60`, or `--sbs=120` (mode 3, not actually
        // SBS — the flag name stays for muscle memory) opts the session into
        // a standalone variant, so a rebuild can be launched straight into
        // the mode under test: `--source=glassesOnly --sbs=60 --autostart`.
        if CommandLine.arguments.contains("--sbs") {
            controller.sbsMode = .sbs90
        } else if CommandLine.arguments.contains("--sbs=60") {
            controller.sbsMode = .sbs60
        } else if CommandLine.arguments.contains("--sbs=120") {
            controller.sbsMode = .hz120
        }
        // `--ultrawide` opts a plain glasses-only session into the 21:9
        // working desktop: `--source=glassesOnly --ultrawide --autostart`.
        if CommandLine.arguments.contains("--ultrawide") {
            controller.ultraWide = true
        }
        // `--hud` overlays the Metal Performance HUD on the glasses layer —
        // the Direct-vs-Composited readout the direct-scanout work steers by.
        if CommandLine.arguments.contains("--hud") {
            controller.metalHUD = true
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
        relocateSettingsIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// During a glasses-only session (any variant), make sure the settings
    /// window sits on the wall's main desktop (the display at the origin —
    /// the one the eye sees straight ahead). macOS's arrangement shuffles
    /// leave it on side screens (a head-turn away, which reads as "the
    /// window won't open") or on hidden desktops in the standalone variants.
    private func relocateSettingsIfNeeded() {
        guard controller.isRunning, controller.source == .glassesOnly,
              let window = settingsWindow,
              let target = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
              window.screen !== target else { return }
        var frame = window.frame
        frame.origin = CGPoint(x: target.frame.midX - frame.width / 2,
                               y: target.frame.midY - frame.height / 2)
        window.setFrame(frame, display: true)
        window.orderFront(nil)
    }

    /// Pull the settings window back to the wall's main desktop when it is
    /// sitting on a desktop the user cannot see. Runs on a standing timer for
    /// the whole session; acts only in that one unreachable case.
    private func rescueSettingsFromHiddenDesktop() {
        let hidden = controller.hiddenDisplayIDs()
        guard !hidden.isEmpty,
              let window = settingsWindow, window.isVisible,
              let screen = window.screen,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              hidden.contains(CGDirectDisplayID(truncating: number)),
              let target = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        else { return }
        var frame = window.frame
        frame.origin = CGPoint(x: target.frame.midX - frame.width / 2,
                               y: target.frame.midY - frame.height / 2)
        window.setFrame(frame, display: true)
        window.orderFront(nil)
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
