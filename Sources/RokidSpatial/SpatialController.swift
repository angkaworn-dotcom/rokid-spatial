// Owns the lifecycle: sensors in, desktop captured, overlay drawn on the glasses.

import Foundation
import AppKit
import MetalKit
import Combine
import RokidKit

@MainActor
final class SpatialController: ObservableObject {
    // MARK: Published state, bound to the settings UI

    @Published var isRunning = false
    @Published var status = "Idle"
    @Published var statusIsError = false
    @Published var sampleRate = 0
    @Published var yaw: Float = 0
    /// Non-nil while a gyro calibration is running.
    @Published var calibrationEndsAt: Date?

    /// Apps whose windows are hidden underneath the overlay on the glasses.
    @Published var strandedApps: [String] = []

    @Published var virtualResolution: VirtualResolution = .r1440x900 { didSet { persist(virtualResolution.rawValue, "virtualResolution") } }

    /// Put the menu bar on the virtual desktop, so the glasses become the
    /// place you work rather than an empty screen off to one side.
    @Published var virtualIsMain = true { didSet { persist(virtualIsMain, "virtualIsMain") } }

    @Published var source: CaptureSource = .mirror { didSet { persist(source.rawValue, "source") } }

    @Published var mode: AnchorMode = .follow { didSet { screen.mode = mode } }
    @Published var distance: Float = 2.5 { didSet { screen.distance = distance; persist(distance, "distance") } }
    @Published var diagonal: Float = 1.5 { didSet { screen.diagonal = diagonal; persist(diagonal, "diagonal") } }
    @Published var height: Float = 0 { didSet { screen.verticalOffset = height; persist(height, "height") } }
    @Published var deadzone: Float = 6 { didSet { screen.deadzoneDegrees = deadzone; persist(deadzone, "deadzone") } }
    @Published var followSpeed: Float = 3.0 { didSet { screen.followSpeed = followSpeed; persist(followSpeed, "followSpeed") } }
    @Published var settleSpeed: Float = 0.7 { didSet { screen.settleSpeed = settleSpeed; persist(settleSpeed, "settleSpeed") } }
    @Published var ipd: Float = 0.063 { didSet { screen.ipd = ipd; persist(ipd, "ipd") } }
    @Published var lookAhead: Float = 0 { didSet { renderer?.lookAhead = lookAhead; persist(lookAhead, "lookAhead") } }
    /// Breezy-style automatic prediction — see `Renderer.autoLookAhead`.
    @Published var autoPrediction = false { didSet { renderer?.autoLookAhead = autoPrediction; persist(autoPrediction, "autoPrediction") } }
    @Published var motionLock: Float = 0 { didSet { screen.motionLock = motionLock; persist(motionLock, "motionLock") } }

    /// Panel pixels per captured pixel across the virtual screen. 1.0 means
    /// the desktop maps one-to-one; below that, detail is being thrown away
    /// before it ever reaches your eye.
    @Published var pixelScale: Float = 0

    // MARK: Machinery

    let filter = OrientationFilter()
    let screen = VirtualScreen()

    /// What the glasses show.
    ///
    /// Mirroring is the obvious thing to want — your actual work, floating in
    /// front of you — and it costs sharpness, because a full-size desktop has
    /// to be squeezed into however many panel pixels the virtual screen spans.
    /// A separate desktop can be sized to fit exactly, so nothing is
    /// downscaled, but it starts empty and windows have to be moved onto it.
    enum CaptureSource: String, CaseIterable, Identifiable {
        case mirror
        case virtualDesktop
        case glassesOnly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mirror: return "Mirror Mac"
            case .virtualDesktop: return "2nd desktop"
            case .glassesOnly: return "Glasses only"
            }
        }

        var detail: String {
            switch self {
            case .mirror:
                return "Shows your MacBook screen. Sharpness depends on its resolution — lower it, or enlarge the virtual screen, if text looks soft."
            case .virtualDesktop:
                return "A second desktop sized to the glasses, so text is never downscaled. It starts empty; move windows onto it."
            case .glassesOnly:
                return "The whole desktop lives in the glasses at panel-native size; the MacBook screen goes dark. One screen — nothing to lose windows on, no display fights."
            }
        }
    }

    /// Resolutions for the virtual desktop. Each is a compromise between how
    /// much fits on screen and how sharp it is: the virtual screen spans a
    /// fixed number of panel pixels, so a wider desktop squeezed into it means
    /// smaller, softer text.
    enum VirtualResolution: String, CaseIterable, Identifiable {
        case r1280x800
        case r1440x900
        case r1600x1000
        case r1920x1200

        var id: String { rawValue }

        var width: Int {
            switch self {
            case .r1280x800: return 1280
            case .r1440x900: return 1440
            case .r1600x1000: return 1600
            case .r1920x1200: return 1920
            }
        }

        var height: Int { width * 5 / 8 }
        var label: String { "\(width)×\(height)" }

        /// Retina backing is worth the pixels once the desktop is small enough
        /// that the virtual screen renders larger than its point size.
        var hiDPI: Bool { self == .r1280x800 || self == .r1440x900 }
    }

    private var imu: RokidIMU?
    private let displays: DisplayManager = {
        let manager = DisplayManager()
        manager.log = { SpatialController.appendLog($0) }
        return manager
    }()
    private let virtualDisplay = VirtualDisplay()
    private let capture = ScreenCapture()
    private var renderer: Renderer?
    private var window: NSWindow?
    private var metalView: MTKView?

    private var samplesThisSecond = 0
    private var rateTimer: Timer?

    /// Re-hides the hardware cursor at 10 Hz while glasses-only mode runs —
    /// any app changing the cursor shape makes it visible again.
    private var cursorTimer: Timer?

    // Health watchdog. The overlay is opaque, full-screen and always on top,
    // so anything that leaves it up while the desktop underneath is unusable
    // traps the user with nothing to click — which is exactly what happened
    // when macOS silently re-mirrored the displays mid-session. Nothing here
    // is optional.
    /// Records when the last captured frame arrived. Written from the capture
    /// queue and read from the main actor, so it lives outside the actor's
    /// isolation with its own lock.
    private final class FrameClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()

        func mark() {
            lock.lock()
            last = Date()
            lock.unlock()
        }

        var secondsSinceLast: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last)
        }
    }

    private let frameClock = FrameClock()
    private var unhealthyTicks = 0
    private var mirrorRecoveryAttempts = 0
    private var watchdogArmsAt = Date.distantPast

    /// True from the moment Start is accepted until the session is running or
    /// has failed. Guards against a second Start racing the first.
    private var isStarting = false

    /// Capture streams die on display reconfigurations that are none of our
    /// doing; count the restart attempts so a genuinely broken stream still
    /// tears the session down instead of looping forever.
    private var captureRestarts = 0

    /// Built-in panel brightness before glasses-only mode dimmed it to zero.
    private var savedBrightness: Float?

    /// The panel always runs 1920×1200 @ 120 Hz (mode 3).
    ///
    /// A 90 Hz side-by-side stereo mode existed and was removed after real
    /// use. The disparity at a 2.5 m screen distance is only about 1.4° —
    /// barely perceptible — while 120 against 90 Hz is obvious the moment
    /// you turn your head, and in glasses-only mode SBS additionally forces
    /// the whole desktop to 3840×1200, halving per-eye sharpness. The stereo
    /// render path (`Renderer.stereo`, `VirtualScreen.ipd`) survives in case
    /// it ever earns its way back; the protocol side stays in PROTOCOL.md.
    static let frameRate = 120

    // MARK: Persistence

    /// Settings survive relaunches. Until they did, every launch silently
    /// reset the capture source to its default — so a user who had chosen
    /// glasses-only mode, quit, reopened and pressed Start got the old
    /// extended-desktop behaviour and reasonably concluded nothing had changed.
    private func persist(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        let d = UserDefaults.standard
        if let v = CaptureSource(rawValue: d.string(forKey: "source") ?? "") { source = v }
        if let v = VirtualResolution(rawValue: d.string(forKey: "virtualResolution") ?? "") {
            virtualResolution = v
        }
        if d.object(forKey: "virtualIsMain") != nil { virtualIsMain = d.bool(forKey: "virtualIsMain") }
        if d.object(forKey: "autoPrediction") != nil { autoPrediction = d.bool(forKey: "autoPrediction") }

        func load(_ key: String, into value: inout Float) {
            if d.object(forKey: key) != nil { value = d.float(forKey: key) }
        }
        load("distance", into: &distance)
        load("diagonal", into: &diagonal)
        load("height", into: &height)
        load("deadzone", into: &deadzone)
        load("followSpeed", into: &followSpeed)
        load("settleSpeed", into: &settleSpeed)
        load("ipd", into: &ipd)
        load("lookAhead", into: &lookAhead)
        load("motionLock", into: &motionLock)

        // Property observers don't fire during init, so the loaded values
        // have to be pushed into the render-side objects by hand.
        screen.mode = mode
        screen.distance = distance
        screen.diagonal = diagonal
        screen.verticalOffset = height
        screen.deadzoneDegrees = deadzone
        screen.followSpeed = followSpeed
        screen.settleSpeed = settleSpeed
        screen.ipd = ipd
        screen.motionLock = motionLock
    }

    // MARK: Lifecycle

    func start() {
        // `isRunning` alone cannot guard this: it only becomes true once the
        // whole multi-second setup finishes, and an impatient second click in
        // that window launched a complete parallel setup whose display
        // reconfiguration killed the first one's capture stream. Seen live.
        guard !isRunning, !isStarting else { return }

        // Check this before touching the displays. Screen Recording consent is
        // bound to the code signature, and an ad-hoc signature changes on every
        // rebuild, so it lapses far more often than you would expect. Finding
        // out only after the displays have been reconfigured leaves the machine
        // half-set-up with nothing drawing to the glasses.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            setStatus("""
                Screen Recording permission is needed. Grant it to RokidSpatial in \
                System Settings → Privacy & Security → Screen Recording, then quit \
                and reopen this app. Re-granting is required after every rebuild.
                """, isError: true)
            return
        }

        isStarting = true

        // The virtual display has to exist before anything else is arranged.
        // Adding a display is itself a reconfiguration, and macOS responds to
        // those by reinstating its remembered arrangement — mirroring included.
        // Creating it after un-mirroring simply undoes the un-mirroring.
        if source == .virtualDesktop {
            setStatus("Creating the virtual desktop…")
            do {
                try virtualDisplay.create(
                    width: virtualResolution.width,
                    height: virtualResolution.height,
                    hiDPI: virtualResolution.hiDPI
                )
            } catch {
                setStatus("\(error)", isError: true)
                isStarting = false
                return
            }
        }

        let displayMode = DisplayMode.highRefreshRate
        setStatus("Switching the glasses to 120 Hz…")

        // Display reconfiguration blocks for a few seconds while the panel
        // renegotiates, so keep it off the main thread.
        Task.detached(priority: .userInitiated) { [displays, source] in
            do {
                if source == .glassesOnly {
                    try displays.prepareGlassesOnly(mode: displayMode)
                } else {
                    // Let macOS enumerate the new display before rearranging.
                    Thread.sleep(forTimeInterval: 2.0)
                    try displays.prepare(mode: displayMode)
                }
            } catch {
                await self.setStatus("\(error)", isError: true)
                await MainActor.run { self.isStarting = false }
                return
            }
            await self.startCaptureAndRender()
        }
    }

    private func startCaptureAndRender() async {
        // Capture the virtual desktop, not the built-in screen. It is sized to
        // what the glasses can resolve, so nothing is downscaled on the way to
        // your eye, and the physical desktop is left completely alone.
        let captureID: CGDirectDisplayID
        switch source {
        case .mirror:
            guard let deskID = displays.deskDisplayID else {
                abort("No desktop display to mirror.")
                return
            }
            captureID = deskID
        case .virtualDesktop:
            guard let id = virtualDisplay.displayID else {
                abort("The virtual display did not report a display ID.")
                return
            }
            captureID = id
        case .glassesOnly:
            // Capture the glasses' own display — the overlay is excluded from
            // the capture per-window, which is what breaks the recursion.
            guard let id = displays.glassesDisplayID else {
                abort("The glasses display disappeared during setup.")
                return
            }
            captureID = id
        }

        if source != .glassesOnly {
            // One mirrored display set: there is nothing to arrange.
            applyArrangement()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let renderer = Renderer(filter: filter, screen: screen) else {
            abort("Could not create the Metal renderer.")
            return
        }
        renderer.stereo = false
        renderer.lookAhead = lookAhead
        renderer.autoLookAhead = autoPrediction
        self.renderer = renderer

        createOverlayWindow(renderer: renderer)
        startIMU()

        capture.onFrame = { [weak self, weak renderer] buffer in
            renderer?.submit(frame: buffer)
            self?.frameClock.mark()
        }
        capture.onStop = { [weak self] error in
            self?.handleCaptureDeath(error)
        }

        do {
            try await capture.start(
                displayID: captureID,
                frameRate: Self.frameRate,
                excludingWindowNumber: source == .glassesOnly ? window?.windowNumber : nil,
                // In glasses-only mode the renderer draws its own cursor;
                // SCK's would be a duplicate whenever the system cursor
                // transiently becomes visible again.
                showsCursor: source != .glassesOnly
            )
        } catch {
            abort("\(error)")
            return
        }

        frameClock.mark()
        unhealthyTicks = 0
        mirrorRecoveryAttempts = 0
        captureRestarts = 0
        // Display reconfiguration ripples for several seconds after startup.
        // Watching during that window produces false alarms and tears down a
        // session that was about to be fine.
        watchdogArmsAt = Date().addingTimeInterval(6)
        isRunning = true
        isStarting = false
        let size = displays.glassesPixelSize
        setStatus(String(format: "Running — %.0f×%.0f @ %d Hz",
                         size.width, size.height, Self.frameRate))
        startRateTimer()

        // Last, after everything is confirmed running: glasses-only mode's
        // screen-off, plus the cursor swap. The hardware cursor is hidden
        // system-wide (nothing gentler removes it — it is composited above
        // every window), which also stops SCK from drawing it; the renderer
        // paints its own sprite at the same position instead, so exactly one
        // cursor exists and it lives on the virtual screen.
        if source == .glassesOnly {
            if let deskID = displays.deskDisplayID {
                savedBrightness = BuiltinBrightness.get(deskID) ?? 0.5
                BuiltinBrightness.set(deskID, to: 0)
            }
            attachRenderedCursor(to: renderer, displayID: captureID)
            SystemCursor.hide()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                SystemCursor.reassertHidden()
            }
        }
    }

    /// Give the renderer everything it needs to draw the cursor itself:
    /// the arrow sprite, its hotspot, and a per-frame position — all as
    /// fractions of the captured display.
    private func attachRenderedCursor(to renderer: Renderer, displayID: CGDirectDisplayID) {
        let cursor = NSCursor.arrow
        let image = cursor.image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let loader = MTKTextureLoader(device: renderer.device)
        guard let texture = try? loader.newTexture(
            cgImage: cgImage,
            options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        ) else { return }

        let bounds = CGDisplayBounds(displayID)
        let displaySize = SIMD2(Float(bounds.width), Float(bounds.height))
        renderer.cursorTexture = texture
        renderer.cursorFraction = SIMD2(Float(image.size.width),
                                        Float(image.size.height)) / displaySize
        renderer.cursorHotspotFraction = SIMD2(Float(cursor.hotSpot.x),
                                               Float(cursor.hotSpot.y)) / displaySize
        renderer.cursorPosition = {
            // CGEvent's location is global, top-left origin — the same space
            // as the captured display's bounds.
            guard let location = CGEvent(source: nil)?.location else { return nil }
            return SIMD2(Float(location.x - bounds.minX) / displaySize.x,
                         Float(location.y - bounds.minY) / displaySize.y)
        }
    }

    /// The layout used while running. Order matters: the glasses' display goes
    /// last, because it is covered by an opaque overlay and any window landing
    /// there vanishes. Called at startup, and again whenever macOS re-applies
    /// its remembered arrangement behind our back — un-mirroring alone is not
    /// enough, because the re-apply also makes the glasses the main display,
    /// which quietly moves the menu bar underneath the overlay.
    private func applyArrangement() {
        guard let deskID = displays.deskDisplayID,
              let glassesID = displays.glassesDisplayID else { return }
        let virtualID = source == .virtualDesktop ? virtualDisplay.displayID : nil
        let main = (virtualIsMain ? virtualID : nil) ?? deskID
        var rest = [virtualID, deskID].compactMap { $0 }.filter { $0 != main }
        rest.append(glassesID)
        try? displays.arrange(main: main, then: rest)
    }

    func stop() {
        guard isRunning || window != nil else { return }
        // Logged because a bare "Idle" after a stop with no error line was,
        // in one debugging session, indistinguishable from a mystery fault.
        // It was the Stop button.
        Self.appendLog("Stop — tearing down")
        Task {
            await capture.stop()
            teardown()
            restoreBrightness()
            isRunning = false
            if source == .glassesOnly {
                // Mirroring stays — it is the desired end state, so there is
                // no enforcement wait and stop is immediate.
                displays.restorePanelOnly()
                setStatus("Idle")
            } else {
                setStatus("Restoring displays…")
                // restore() waits out a panel re-enumeration; keep that off
                // the main thread so the settings window stays responsive.
                await Task.detached(priority: .userInitiated) { [displays] in
                    displays.restore()
                }.value
                setStatus("Idle")
            }
        }
    }

    /// A dead capture stream is not necessarily a dead session. macOS kills
    /// SCStreams whenever the captured display re-enumerates — panel mode
    /// changes, mirror renegotiation, another process fiddling with displays —
    /// and every one of those is survivable by just starting a new stream on
    /// the same display. Only give up when restarting stops helping.
    private func handleCaptureDeath(_ error: Error) {
        guard isRunning else {
            // Died during teardown or before running — nothing to save.
            return
        }
        captureRestarts += 1
        guard captureRestarts <= 3 else {
            setStatus("Capture stopped: \(error.localizedDescription)", isError: true)
            stop()
            return
        }
        Self.appendLog("Capture died (\(error.localizedDescription)) — restart \(captureRestarts)/3")
        Task {
            // Let whatever reconfiguration killed the stream finish settling.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.isRunning else { return }
            let captureID: CGDirectDisplayID?
            switch self.source {
            case .mirror: captureID = self.displays.deskDisplayID
            case .virtualDesktop: captureID = self.virtualDisplay.displayID
            case .glassesOnly: captureID = self.displays.glassesDisplayID
            }
            guard let captureID else { return }  // the watchdog handles this
            do {
                try await self.capture.start(
                    displayID: captureID,
                    frameRate: Self.frameRate,
                    excludingWindowNumber: self.source == .glassesOnly
                        ? self.window?.windowNumber : nil
                )
                self.frameClock.mark()
                Self.appendLog("Capture restarted")
            } catch {
                self.setStatus("Capture could not be restarted: \(error)", isError: true)
                self.stop()
            }
        }
    }

    /// Undo glasses-only mode's screen-off and hidden cursor. Safe to call
    /// from any path — both parts are no-ops unless actually applied.
    private func restoreBrightness() {
        SystemCursor.show()
        guard let savedBrightness else { return }
        if let deskID = displays.deskDisplayID {
            BuiltinBrightness.set(deskID, to: savedBrightness)
        }
        self.savedBrightness = nil
    }

    /// Teardown for app termination.
    ///
    /// The restore is handed to a fresh helper process (this same binary with
    /// `--restore-displays`) rather than run here, for two reasons that were
    /// both hit in practice. First, a quitting process cannot even *see* the
    /// display state it is trying to fix: its Core Graphics snapshot stops
    /// refreshing once the run loop stops processing reconfiguration events,
    /// and it watched a mirrored system report "unmirrored" for eight straight
    /// seconds. Second, macOS re-applies its remembered (mirrored) arrangement
    /// up to ~10 s after the panel-mode change — after this process is gone,
    /// so whoever pushes back has to outlive it. The capture stream is not
    /// stopped explicitly; process exit takes it down.
    func shutdownForQuit() {
        guard isRunning || window != nil else { return }
        Self.appendLog("Quit — tearing down")
        teardown()
        restoreBrightness()
        isRunning = false
        if source == .glassesOnly {
            // Mirroring is the desired end state here: no fight, no helper.
            displays.restorePanelOnly()
            return
        }
        do {
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--restore-displays"]
            try helper.run()
            Self.appendLog("Quit — restore handed to helper pid \(helper.processIdentifier)")
        } catch {
            // No helper — restore here, blind CG state and all. A panel stuck
            // in SBS is worse than a restore that might miss the mirror fight.
            Self.appendLog("Quit — helper failed (\(error)), restoring in-process")
            displays.restore()
        }
    }

    /// Give up after the displays have already been reconfigured. Anything
    /// that bails out past that point has to hand the machine back the way it
    /// found it, or the user is left with a rearranged desktop and no app.
    private func abort(_ message: String) {
        setStatus(message, isError: true)
        teardown()
        restoreBrightness()
        if source == .glassesOnly {
            displays.restorePanelOnly()
        } else {
            displays.restore()
        }
        isRunning = false
        isStarting = false
    }

    private func teardown() {
        // Take the virtual display down first: any windows on it need a real
        // screen to fall back to, and that has to still exist.
        virtualDisplay.destroy()
        cursorTimer?.invalidate()
        cursorTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
        imu?.stop()
        imu = nil
        metalView?.isPaused = true
        metalView?.delegate = nil
        metalView = nil
        window?.orderOut(nil)
        window = nil
        renderer = nil
    }

    // MARK: Pieces

    private func startIMU() {
        let imu = RokidIMU { [weak self] sample in
            guard let self else { return }
            self.filter.update(sample)
            self.samplesThisSecond += 1
        }
        do {
            try imu.start(on: CFRunLoopGetMain())
            self.imu = imu
            // Let the filter settle before treating the current pose as forward.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.recenter()
            }
        } catch {
            setStatus("\(error)", isError: true)
        }
    }

    private func createOverlayWindow(renderer: Renderer) {
        // In a mirror set NSScreen may list the set under either display's ID;
        // if the lookup by the glasses' ID comes up empty, the single visible
        // screen is the right answer by construction.
        var bounds = displays.glassesFrame
        if bounds.isEmpty, source == .glassesOnly, let main = NSScreen.main {
            bounds = main.frame
        }
        NSLog("RokidSpatial: %@", displays.describeGeometry())

        let view = MTKView(frame: CGRect(origin: .zero, size: bounds.size),
                           device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = Self.frameRate
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = renderer
        metalView = view

        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.setFrame(bounds, display: true)
        // Two classes of thing try to draw on top of the overlay, and they
        // need different weapons. The cursor is a hardware plane composited
        // above every window — no level beats it; it is dealt with by hiding
        // the system cursor and rendering our own (see SystemCursor). System
        // HUD windows — the screen-recording indicator, Control Centre
        // panels, volume bezels — are ordinary composited windows above
        // .screenSaver, so in glasses-only mode the overlay sits at the
        // kiosk shielding level to bury their head-locked copies. They stay
        // usable: the captured desktop still contains them, so they appear
        // *on* the virtual screen instead of floating in front of it.
        window.level = source == .glassesOnly
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            : .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.orderFrontRegardless()
        self.window = window
    }

    private func startRateTimer() {
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sampleRate = self.samplesThisSecond
                self.samplesThisSecond = 0
                self.yaw = self.filter.yawDegrees
                // One display in glasses-only mode — nowhere to get stranded.
                self.strandedApps = self.source == .glassesOnly
                    ? [] : self.displays.strandedWindowOwners()
                if let renderer = self.renderer, self.capture.pointWidth > 0 {
                    self.pixelScale = renderer.renderedWidth / Float(self.capture.pointWidth)
                }
                self.healthCheck()
            }
        }
    }

    /// Tear everything down the moment the overlay stops being something the
    /// user can see past.
    ///
    /// macOS can reinstate mirroring on its own, which deactivates the built-in
    /// display and leaves the opaque overlay covering the only screen left.
    /// From inside the glasses that looks like a frozen picture with no way
    /// out, and the only recourse is a hard power-off. Detecting it and
    /// stopping is not a nicety.
    private func healthCheck() {
        guard isRunning, Date() >= watchdogArmsAt else { return }
        var problems: [String] = []

        if let glassesID = displays.glassesDisplayID {
            // In glasses-only mode the mirror set is the *desired* state, not
            // a fault — the desk-display checks below don't apply either,
            // because the built-in is just a (dimmed) mirror of the glasses.
            if source != .glassesOnly, CGDisplayIsInMirrorSet(glassesID) != 0 {
                // Try to undo it before treating it as fatal — macOS often
                // reinstates mirroring transiently while a reconfiguration
                // settles, and recovering beats tearing the session down.
                mirrorRecoveryAttempts += 1
                if mirrorRecoveryAttempts <= 2, displays.reassertUnmirrored() {
                    // The re-apply also made the glasses the main display,
                    // which moved the menu bar underneath the overlay. Put
                    // the layout back too, not just the mirroring.
                    applyArrangement()
                    setStatus("macOS re-enabled mirroring; un-mirrored it again.")
                    unhealthyTicks = 0
                    return
                }
                problems.append("the glasses keep being put back into a mirror set")
            }
            if CGDisplayIsActive(glassesID) == 0 {
                problems.append("the glasses display went inactive")
            }
        } else {
            problems.append("the glasses display disappeared")
        }

        if source != .glassesOnly,
           let deskID = displays.deskDisplayID, CGDisplayIsActive(deskID) == 0 {
            problems.append("the desktop display was switched off")
        }

        let sinceFrame = frameClock.secondsSinceLast
        if sinceFrame > 4 {
            problems.append(String(format: "no captured frames for %.0fs", sinceFrame))
        } else if sinceFrame < 2 {
            // Frames are flowing again — earlier restarts evidently worked,
            // so future deaths get their full retry budget back.
            captureRestarts = 0
        }

        guard !problems.isEmpty else {
            unhealthyTicks = 0
            return
        }

        // A single bad tick can just be a reconfiguration in flight. Two in a
        // row is a fault.
        unhealthyTicks += 1
        guard unhealthyTicks >= 2 else { return }

        setStatus("Stopped automatically — \(problems.joined(separator: "; ")).", isError: true)
        stop()
    }

    /// Panic button. Drops the overlay and restores the displays immediately,
    /// without needing to see anything to click.
    func emergencyStop() {
        NSLog("RokidSpatial: emergency stop")
        teardown()
        restoreBrightness()
        if source == .glassesOnly {
            displays.restorePanelOnly()
        } else {
            displays.restore()
        }
        isRunning = false
        setStatus("Emergency stop — displays restored.", isError: true)
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        status = text
        statusIsError = isError
        if isError { NSLog("RokidSpatial: %@", text) }
        Self.appendLog(isError ? "ERROR " + text : text)
    }

    private static func appendLog(_ line: String) {
        AppLog.append(line)
    }

    // MARK: Actions, also reachable via hotkeys

    func recenter() {
        filter.recenter()
        screen.recenter(head: filter.relativeOrientation)
    }

    /// Learn the gyroscope bias. Worth doing once per session: measured drift
    /// falls from about 3.3 °/min to 0.14 °/min, which is the difference
    /// between an anchored screen visibly sliding away and one that stays put.
    /// The glasses must be left completely still for the duration.
    func calibrate() {
        filter.beginCalibration(seconds: 6)
        calibrationEndsAt = Date().addingTimeInterval(7)
        setStatus("Calibrating — put the glasses down and leave them still…")

        Timer.scheduledTimer(withTimeInterval: 7.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.calibrationEndsAt = nil
                let bias = self.filter.gyroBias * 180 / .pi
                self.setStatus(String(format: "Calibrated — gyro bias %.3f, %.3f, %.3f °/s",
                                      bias.x, bias.y, bias.z))
                self.recenter()
            }
        }
    }

    func toggleMode() {
        mode = (mode == .follow) ? .anchored : .follow
        if mode == .anchored { screen.recenter(head: filter.relativeOrientation) }
    }

    func nudgeDistance(_ delta: Float) { distance += delta }
    func nudgeSize(_ delta: Float) { diagonal += delta }
    func nudgeHeight(_ delta: Float) { height = min(max(height + delta, -2), 2) }

    /// Grow the virtual screen until one captured pixel lands on one panel
    /// pixel. This is the only real cure for soft text: the screen has to be
    /// big enough in your field of view to carry the detail. Making it smaller
    /// or pushing it further away necessarily costs sharpness.
    func fitForSharpness() {
        guard pixelScale > 0.01 else { return }
        diagonal = diagonal / pixelScale
    }
}
