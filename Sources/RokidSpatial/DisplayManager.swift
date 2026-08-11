// Finds the glasses among the attached displays and gets them into a state we
// can render to: side-by-side mode on, mirroring off.
//
// Mirroring matters more than it sounds. Out of the box the Rokid mirrors the
// built-in display, so if we captured the desktop and drew it to the glasses
// we would be capturing our own output — an infinite regress. Un-mirroring is
// therefore a precondition, not a preference. We record the previous state and
// put it back on quit.

import Foundation
import AppKit
import RokidKit

final class DisplayManager {
    private(set) var glassesDisplayID: CGDirectDisplayID?
    private(set) var deskDisplayID: CGDirectDisplayID?

    /// Diagnostic sink, wired to the controller's file log. Display faults
    /// have twice been reconstructable only by guesswork; never again.
    var log: ((String) -> Void)?

    private var previousMode: DisplayMode?
    private var wasMirroring = false
    private var glassesWereMain = false

    enum SetupError: Error, CustomStringConvertible {
        case glassesNotFound
        case noOtherDisplay
        case configurationFailed(CGError)

        var description: String {
            switch self {
            case .glassesNotFound:
                return "No display named \"Rokid Max\" found. Plug the glasses into a USB-C port that carries video."
            case .noOtherDisplay:
                return "Only the glasses are attached — there is no desktop left to capture."
            case .configurationFailed(let e):
                return "Display reconfiguration failed (CGError \(e.rawValue))."
            }
        }
    }

    /// Matches on the display's user-visible name, which reads "Rokid Max".
    private func findGlasses() -> NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("rokid") }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }

    /// Every display the system knows about, including ones hidden inside a
    /// mirror set — which `NSScreen.screens` does not show.
    private func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// EDID vendor code the glasses report — a far more reliable handle than
    /// the display's user-visible name.
    private static let rokidEDIDVendor: UInt32 = 12372

    private func findGlassesDisplay() -> CGDirectDisplayID? {
        let all = onlineDisplays()
        if let byVendor = all.first(where: { CGDisplayVendorNumber($0) == Self.rokidEDIDVendor }) {
            return byVendor
        }
        // Fall back to "the external one" for firmware that reports differently.
        return all.first { CGDisplayIsBuiltin($0) == 0 }
    }

    private func findDeskDisplay(excluding glasses: CGDirectDisplayID) -> CGDirectDisplayID? {
        let all = onlineDisplays().filter { $0 != glasses }
        return all.first { CGDisplayIsBuiltin($0) != 0 } ?? all.first
    }

    private func waitUntilUnmirrored(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if onlineDisplays().allSatisfy({ CGDisplayIsInMirrorSet($0) == 0 }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Hold mirroring off while macOS settles after a re-enumeration.
    ///
    /// There is no way to make macOS *forget* that this display pair was once
    /// mirrored. `.permanently` does not do it — verified empirically: after a
    /// permanent un-mirror, the next panel-mode change still brought mirroring
    /// straight back, in both directions. And the re-apply does not land at a
    /// fixed moment; it can arrive several seconds after the mode change, so a
    /// single un-mirror is a race we sometimes lose.
    ///
    /// So: keep watching. Every time mirroring flips back on, push it off
    /// again, and only declare victory after `quiet` seconds of continuous
    /// un-mirrored state. Blocks the calling thread — run it off the main one.
    ///
    /// The defaults are sized for the one caller with no second line of
    /// defence: the quit path. A re-enumeration produces up to *two* re-apply
    /// events, and the second has been observed landing 6–10 s after the mode
    /// command — a 3 s quiet window declared victory in between and the
    /// process exited straight into the trap. During startup the running
    /// watchdog picks up anything this misses, so `prepare` passes a shorter
    /// window; on quit there is nobody left to catch a straggler.
    func enforceUnmirrored(timeout: TimeInterval = 30, quiet: TimeInterval = 8) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var quietSince = Date()
        while Date() < deadline {
            let all = onlineDisplays()
            if all.contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
                log?(String(format: "enforce t=%.1f: mirrored (%@), un-mirroring",
                            Date().timeIntervalSince(start),
                            all.map(String.init).joined(separator: ",")))
                do {
                    try configure { config in
                        for id in all {
                            let err = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                            guard err == .success else { return err }
                        }
                        return .success
                    }
                } catch {
                    log?("enforce: un-mirror failed — \(error)")
                }
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quiet {
                log?(String(format: "enforce t=%.1f: quiet for %.0fs, done",
                            Date().timeIntervalSince(start), quiet))
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log?(String(format: "enforce: timed out after %.0fs still fighting", timeout))
    }

    /// Switch the glasses to `mode`, un-mirror everything, and make the desk
    /// display the main one.
    ///
    /// Order matters, and not in the way it first appears. Changing the panel
    /// mode makes the display re-enumerate, and macOS reinstates its remembered
    /// arrangement when that happens — mirroring included. Un-mirroring first
    /// therefore gets silently undone a few seconds later. Mode first, then
    /// mirroring.
    ///
    /// `NSScreen` is deliberately avoided throughout: its screen list is a
    /// main-thread cache, and this runs on a background thread, so it happily
    /// reports a stale arrangement.
    func prepare(mode: DisplayMode) throws {
        previousMode = try? RokidDisplay.currentMode()
        try RokidDisplay.setMode(mode)
        Thread.sleep(forTimeInterval: 3.0)

        wasMirroring = onlineDisplays().contains { CGDisplayIsInMirrorSet($0) != 0 }
        // Short quiet window: the session watchdog reasserts un-mirroring once
        // a second from here on, so a late re-apply is caught either way and
        // startup stays reasonably quick.
        enforceUnmirrored(timeout: 15, quiet: 4)

        guard let glassesID = findGlassesDisplay() else {
            throw SetupError.glassesNotFound
        }
        glassesDisplayID = glassesID

        // Whatever is left that is not the glasses is the desktop we capture.
        guard let desk = findDeskDisplay(excluding: glassesID) else {
            throw SetupError.noOtherDisplay
        }
        deskDisplayID = desk

        // The glasses usually arrive as the main display, which puts the menu
        // bar on the one screen we are about to cover with an opaque overlay.
        // Move it to the desk display first, or the user has nothing to click.
        if CGDisplayIsMain(glassesID) != 0 {
            glassesWereMain = true
            let deskWidth = Int32(CGDisplayPixelsWide(desk))
            try configure { config in
                // The display at the origin is the main one.
                let err = CGConfigureDisplayOrigin(config, desk, 0, 0)
                guard err == .success else { return err }
                return CGConfigureDisplayOrigin(config, glassesID, deskWidth, 0)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Glasses-only mode: the glasses are the one display that matters, and
    /// mirroring is *embraced* instead of fought.
    ///
    /// The whole extended-desktop dance — un-mirror wars, stranded windows,
    /// the pointer wandering onto an invisible screen — exists only because
    /// the captured display and the drawn-on display had to be different. They
    /// don't: ScreenCaptureKit can exclude our overlay from a capture of the
    /// very display it covers (verified empirically). So let macOS mirror the
    /// way it insists on, with the glasses as master so the desktop runs at
    /// panel-native size, and there is exactly one desktop anywhere.
    func prepareGlassesOnly(mode: DisplayMode, desktopSize: (width: Int, height: Int)? = nil) throws {
        previousMode = try? RokidDisplay.currentMode()
        try RokidDisplay.setMode(mode)
        Thread.sleep(forTimeInterval: 3.0)

        guard let glassesID = findGlassesDisplay() else {
            throw SetupError.glassesNotFound
        }
        glassesDisplayID = glassesID
        deskDisplayID = onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }

        // macOS usually re-mirrors on its own within a few seconds of the mode
        // change — its remembered arrangement finally working *for* us. Only
        // step in if it hasn't.
        if CGDisplayIsInMirrorSet(glassesID) == 0, let builtin = deskDisplayID {
            log?("glasses-only: mirroring built-in onto the glasses")
            try configure { config in
                CGConfigureDisplayMirrorOfDisplay(config, builtin, glassesID)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Optionally run the desktop at a scaled resolution: everything gets
        // bigger, the GPU upscales to the panel's native raster. The panel
        // never sees anything but its own timing — this only changes the
        // framebuffer the desktop is drawn into.
        if let desktopSize {
            setDesktopResolution(glassesID, width: desktopSize.width, height: desktopSize.height)
        }
    }

    /// Pick the display mode matching `width`×`height` with the highest
    /// refresh rate. Silently stays native when no such mode exists.
    private func setDesktopResolution(_ display: CGDirectDisplayID, width: Int, height: Int) {
        let current = CGDisplayCopyDisplayMode(display)
        guard current?.width != width || current?.height != height else { return }

        guard let all = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else { return }
        var candidates = all.filter { $0.width == width && $0.height == height }
        if candidates.isEmpty {
            // The panel does not offer that exact size — take the nearest
            // smaller-or-equal 16:10 mode rather than silently staying put.
            let sameShape = all.filter { $0.width * 10 == $0.height * 16 && $0.width <= 1920 }
            let nearest = sameShape.min { abs($0.width - width) < abs($1.width - width) }
            candidates = sameShape.filter { $0.width == nearest?.width }
            guard !candidates.isEmpty else {
                log?("glasses-only: no scaled modes at all; staying native")
                return
            }
            log?("glasses-only: no \(width)×\(height) mode; using nearest \(candidates[0].width)×\(candidates[0].height)")
        }
        guard let best = candidates.max(by: { $0.refreshRate < $1.refreshRate }) else { return }
        log?(String(format: "glasses-only: desktop %d×%d @ %.0f Hz",
                    best.width, best.height, best.refreshRate))
        try? configure { config in
            CGConfigureDisplayWithDisplayMode(config, display, best, nil)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Put `display` immediately to the right of `anchor`, top-aligned — used
    /// for the side screen, so the pointer leaves the main desktop on the same
    /// side the eye sees the second screen.
    func positionToRight(_ display: CGDirectDisplayID, of anchor: CGDirectDisplayID) {
        let width = Int32(CGDisplayPixelsWide(anchor))
        try? configure { config in
            CGConfigureDisplayOrigin(config, display, width, 0)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Mirror image of `positionToRight`.
    func positionToLeft(_ display: CGDirectDisplayID, of anchor: CGDirectDisplayID) {
        let width = Int32(CGDisplayPixelsWide(display))
        try? configure { config in
            CGConfigureDisplayOrigin(config, display, -width, 0)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Restore for glasses-only mode: panel back to 2D, mirroring left exactly
    /// as macOS likes it. With no overlay and no second desktop there is
    /// nothing left that can trap the user, so there is nothing to enforce
    /// and no helper process to spawn.
    func restorePanelOnly() {
        log?("restore(panel-only): setting panel to 2D, leaving mirroring alone")
        try? RokidDisplay.setMode(.sameOnBoth)
    }

    /// Hand the machine back in a state the user can actually work in.
    ///
    /// Note what this deliberately does *not* do: re-enable mirroring. The
    /// glasses typically arrive as the mirror *master*, which deactivates the
    /// built-in display — so faithfully restoring "how we found it" recreates
    /// the exact arrangement that leaves nothing usable to look at. When the
    /// watchdog stops the app *because* mirroring came back, restoring it turns
    /// a single fault into a loop.
    ///
    /// Extended mode is always usable. Mirroring is one click away in System
    /// Settings if the user wants it. Safety wins over fidelity.
    func restore() {
        // Panel mode first — the same ordering rule as `prepare()`, for the
        // same reason. Changing the mode makes the display re-enumerate, and
        // macOS responds by re-applying its remembered arrangement. Arranging
        // *before* the mode change therefore gets silently undone seconds
        // later — which is exactly how a session used to end with mirroring
        // back on and the built-in display dark.
        //
        // Always plain 2D, never whatever mode we found. Side-by-side only
        // makes sense while something is rendering a separate image per eye —
        // without that, the desktop is sliced down the middle and each eye gets
        // half of it, which is disorienting and looks broken. If the glasses
        // were already in SBS when the app started, restoring that state hands
        // the user back exactly that mess.
        log?("restore: setting panel to 2D")
        try? RokidDisplay.setMode(.sameOnBoth)
        Thread.sleep(forTimeInterval: 2.0)

        // macOS will now re-apply its remembered arrangement — mirrored, with
        // the glasses as master — at some point in the next few seconds. Hold
        // the line until it stops.
        enforceUnmirrored()

        // Re-resolve the IDs: re-enumeration can hand out new ones, and the
        // stale IDs would make the arrangement below silently do nothing.
        glassesDisplayID = findGlassesDisplay()
        let builtin = onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }

        // Always hand the menu bar back to the built-in screen. It is the one
        // display the user is guaranteed to be able to see without wearing
        // anything.
        if let builtin {
            let others = [glassesDisplayID].compactMap { $0 }.filter { $0 != builtin }
            do {
                try arrange(main: builtin, then: others)
            } catch {
                log?("restore: arrange failed — \(error)")
            }
        }
        log?("restore: done, mirrored=\(onlineDisplays().contains { CGDisplayIsInMirrorSet($0) != 0 })")
    }

    /// Lay the displays out left to right, with `main` at the origin.
    ///
    /// The display at (0, 0) is the main one, which is where the menu bar lives
    /// and where new windows open. Putting the virtual desktop there is what
    /// turns it from an empty screen off to one side into the place you
    /// actually work.
    ///
    /// The glasses' own display should always come last: it is covered by an
    /// opaque overlay, so any window that lands on it is invisible.
    func arrange(main: CGDirectDisplayID, then others: [CGDirectDisplayID]) throws {
        try configure { config in
            var err = CGConfigureDisplayOrigin(config, main, 0, 0)
            guard err == .success else { return err }

            var x = Int32(CGDisplayPixelsWide(main))
            for id in others {
                // The glasses get pushed down so only a narrow strip of their
                // edge touches the display beside them. macOS lets the pointer
                // cross between displays wherever their edges meet, and a full
                // shared edge means windows drift onto the glasses constantly —
                // where the opaque overlay makes them invisible everywhere at
                // once. A sliver keeps the display reachable without inviting
                // traffic.
                let y: Int32 = (id == glassesDisplayID)
                    ? Int32(CGDisplayPixelsHigh(main)) - 40
                    : 0
                err = CGConfigureDisplayOrigin(config, id, x, y)
                guard err == .success else { return err }
                x += Int32(CGDisplayPixelsWide(id))
            }
            return .success
        }
    }

    /// Windows sitting on the glasses display, where the overlay hides them.
    ///
    /// Their owners appear to have vanished: the window is not on the captured
    /// desktop, so it never reaches the glasses, and on the glasses themselves
    /// it is underneath an opaque overlay. "That app doesn't show up" is the
    /// symptom; this finds the cause.
    func strandedWindowOwners() -> [String] {
        guard let glassesID = glassesDisplayID else { return [] }
        let region = CGDisplayBounds(glassesID)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var owners: [String] = []
        for window in list {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width > 80, height > 80,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  owner != "Rokid Spatial"
            else { continue }

            let centre = CGPoint(x: x + width / 2, y: y + height / 2)
            if region.contains(centre), !owners.contains(owner) {
                owners.append(owner)
            }
        }
        return owners
    }

    /// macOS sometimes reinstates mirroring on its own after a reconfiguration.
    /// Push it back once before giving up — often it is a transient settling
    /// step rather than a permanent decision.
    @discardableResult
    func reassertUnmirrored() -> Bool {
        let all = onlineDisplays()
        guard all.contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) else { return true }
        try? configure { config in
            for id in all {
                let err = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                guard err == .success else { return err }
            }
            return .success
        }
        waitUntilUnmirrored(timeout: 3)
        return onlineDisplays().allSatisfy { CGDisplayIsInMirrorSet($0) == 0 }
    }

    private func configure(_ body: (CGDisplayConfigRef?) -> CGError) throws {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success else { throw SetupError.configurationFailed(err) }

        err = body(config)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw SetupError.configurationFailed(err)
        }

        err = CGCompleteDisplayConfiguration(config, .forSession)
        guard err == .success else { throw SetupError.configurationFailed(err) }
    }

    private var glassesScreen: NSScreen? {
        guard let id = glassesDisplayID else { return nil }
        return NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// Frame of the glasses display in **AppKit** coordinates — origin at the
    /// bottom left, Y increasing upward.
    ///
    /// `CGDisplayBounds` looks like the obvious source here and is wrong: it
    /// uses Core Graphics' flipped space, origin top left. Feeding that to
    /// `NSWindow.setFrame` puts the overlay at the wrong height and leaves part
    /// of the desktop showing through. `NSScreen.frame` is already in the
    /// space `NSWindow` expects.
    var glassesFrame: CGRect {
        glassesScreen?.frame ?? .zero
    }

    /// True pixel dimensions of the glasses display.
    ///
    /// `glassesFrame` is in points, and the backing scale differs by panel
    /// mode — side-by-side reports 2.0, the 120 Hz mode 1.0 — so assuming
    /// either one produces a wrong figure half the time.
    var glassesPixelSize: CGSize {
        guard let screen = glassesScreen else { return .zero }
        return CGSize(width: screen.frame.width * screen.backingScaleFactor,
                      height: screen.frame.height * screen.backingScaleFactor)
    }

    /// Logged at startup — the two coordinate spaces disagreeing is the first
    /// thing to check if the overlay is ever misplaced again.
    func describeGeometry() -> String {
        guard let id = glassesDisplayID else { return "glasses: not found" }
        let cg = CGDisplayBounds(id)
        let appKit = glassesFrame
        let scale = glassesScreen?.backingScaleFactor ?? 1
        return """
        glasses CG bounds \(Int(cg.minX)),\(Int(cg.minY)) \(Int(cg.width))×\(Int(cg.height)) \
        · AppKit frame \(Int(appKit.minX)),\(Int(appKit.minY)) \(Int(appKit.width))×\(Int(appKit.height)) \
        · backing scale \(scale)
        """
    }
}
