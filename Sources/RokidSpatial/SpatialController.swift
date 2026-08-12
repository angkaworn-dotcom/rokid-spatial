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
    /// Rendered frames in the last second, and how many overshot the 120 Hz
    /// deadline — the stutter metric.
    @Published var renderFPS = 0
    @Published var longFrames = 0
    /// Non-nil while a gyro calibration is running.
    @Published var calibrationEndsAt: Date?

    /// Apps whose windows are hidden underneath the overlay on the glasses.
    @Published var strandedApps: [String] = []

    @Published var virtualResolution: VirtualResolution = .r1440x900 { didSet { persist(virtualResolution.rawValue, "virtualResolution") } }

    /// Put the menu bar on the virtual desktop, so the glasses become the
    /// place you work rather than an empty screen off to one side.
    @Published var virtualIsMain = true { didSet { persist(virtualIsMain, "virtualIsMain") } }

    @Published var source: CaptureSource = .mirror { didSet { persist(source.rawValue, "source") } }

    @Published var mode: AnchorMode = .follow {
        didSet {
            if mode == .follow, source == .glassesOnly, sideScreens != .none {
                mode = .anchored
                return
            }
            screen.mode = mode
        }
    }
    @Published var distance: Float = 2.5 { didSet { screen.distance = distance; persist(distance, "distance") } }
    @Published var diagonal: Float = 1.5 { didSet { screen.diagonal = diagonal; persist(diagonal, "diagonal") } }
    @Published var height: Float = 0 { didSet { screen.verticalOffset = height; persist(height, "height") } }
    @Published var curved = false { didSet { screen.curved = curved; persist(curved, "curved") } }
    /// Glasses-only: extra virtual desktops rendered as screens hanging next
    /// to the main one, triple-monitor style. Side screens are always created
    /// at the main desktop's resolution, so the three screens match exactly.
    /// With more than one screen the wall only makes sense anchored in
    /// space — follow mode would drag all three around with your head.
    @Published var sideScreens: SideScreens = .none {
        didSet {
            persist(sideScreens.rawValue, "sideScreens")
            if sideScreens != .none, mode == .follow { mode = .anchored }
        }
    }

    enum SideScreens: String, CaseIterable, Identifiable {
        case none
        case right
        case leftRight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None"
            case .right: return "Right"
            case .leftRight: return "L + R"
            }
        }

        /// Renderer/display indices to bring up: 0 = right, 1 = left.
        var indices: [Int] {
            switch self {
            case .none: return []
            case .right: return [0]
            case .leftRight: return [0, 1]
            }
        }
    }
    @Published var deadzone: Float = 6 { didSet { screen.deadzoneDegrees = deadzone; persist(deadzone, "deadzone") } }
    @Published var followSpeed: Float = 3.0 { didSet { screen.followSpeed = followSpeed; persist(followSpeed, "followSpeed") } }
    @Published var settleSpeed: Float = 0.7 { didSet { screen.settleSpeed = settleSpeed; persist(settleSpeed, "settleSpeed") } }
    @Published var ipd: Float = 0.063 { didSet { screen.ipd = ipd; persist(ipd, "ipd") } }
    @Published var lookAhead: Float = 0 { didSet { renderer?.lookAhead = lookAhead; persist(lookAhead, "lookAhead") } }
    /// Anti-shake: display-pose smoothing time constant, seconds.
    @Published var steady: Float = 0.015 { didSet { renderer?.steady = steady; persist(steady, "steady") } }
    /// 4-tap supersampling against the faint grey moiré bands that appear
    /// whenever the head moves and the desktop's pixel rows beat against the
    /// panel raster. Live-switchable so the difference can be judged by eye.
    @Published var antiMoire = false { didSet { renderer?.antiMoire = antiMoire; persist(antiMoire, "antiMoire") } }
    /// Glasses panel variants beyond the default 60 Hz 2D: stereo SBS at 60
    /// or 90 (per-eye rendering with the IPD offset onto a separate working
    /// virtual display), and plain 120 Hz (mode 3, no stereo — the glasses'
    /// own 1920×1200 desktop captured directly). All of them run
    /// *standalone*: no mirror set may touch the glasses or the sides, or
    /// macOS harmonizes flips down to 60. Grey-line note (2026-08-12): the
    /// faint scroll-ghost is the panel's own in every mode; 120's earlier
    /// "obvious lines" verdict predates that finding and mixed in frame
    /// duplication — it is being re-tested fairly here.
    enum SBSMode: String, CaseIterable, Identifiable {
        case off
        case sbs60
        case sbs90
        case hz120

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .sbs60: return "SBS 60"
            case .sbs90: return "SBS 90"
            case .hz120: return "120 Hz"
            }
        }

        var isStereo: Bool { self == .sbs60 || self == .sbs90 }

        /// The panel mode carrying this variant.
        var panelMode: DisplayMode {
            switch self {
            case .off: return .sameOnBoth
            case .sbs60: return .stereo
            case .sbs90: return .highRefreshRateSBS
            case .hz120: return .highRefreshRate
            }
        }

        var frameRate: Int {
            switch self {
            case .off, .sbs60: return 60
            case .sbs90: return 90
            case .hz120: return 120
            }
        }

        /// Working-desktop (and side-screen) size for the stereo variants:
        /// matches the per-eye raster.
        var desktopSize: (width: Int, height: Int) {
            self == .sbs90 ? (1920, 1200) : (1920, 1080)
        }

        var detail: String {
            switch self {
            case .off:
                return ""
            case .sbs60:
                return "Stereo depth at 60 Hz. The MacBook desktop merges into the working one, so windows opened before Start follow you in. IPD slider under More."
            case .sbs90:
                return "Stereo depth at 90 Hz (the Station 2 mode) — smoothest motion with depth. Windows opened before Start stay on the hidden MacBook desktop until Stop."
            case .hz120:
                return "1920×1200 @ 120 Hz, no stereo — maximum motion clarity. Windows opened before Start stay on the hidden MacBook desktop until Stop."
            }
        }
    }

    @Published var sbsMode: SBSMode = .off { didSet { persist(sbsMode.rawValue, "sbsMode") } }

    /// True when the session runs (or would run) one of the standalone
    /// variants — no mirror allowed (SBS-60 excepts exactly one pair), wall
    /// layout with parked displays, re-mirror on stop.
    var standaloneActive: Bool { source == .glassesOnly && sbsMode != .off }

    /// True for the stereo variants: per-eye rendering off a separate
    /// working virtual display. 120 Hz is standalone but not stereo.
    var stereoActive: Bool { standaloneActive && sbsMode.isStereo }
    @Published var motionLock: Float = 0 { didSet { screen.motionLock = motionLock; persist(motionLock, "motionLock") } }
    /// Angular gap between neighbouring screens, degrees. Zero makes the
    /// three screens one continuous wall.
    @Published var screenGap: Float = 3 { didSet { renderer?.sideGap = screenGap * .pi / 180; persist(screenGap, "screenGap") } }
    /// Physically tap the glasses twice to re-centre — hands never leave the
    /// keyboard, eyes never leave the glasses. Detection is a sharp spike in
    /// the gyro's derivative (ported from XRLinuxDriver's multitap).
    @Published var doubleTapRecenter = false { didSet { tapEnabled.set(doubleTapRecenter); persist(doubleTapRecenter, "doubleTapRecenter") } }

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
    /// Index 0 = right side screen, 1 = left.
    private let sideDisplays = [VirtualDisplay(), VirtualDisplay()]
    private let sideCaptures = [ScreenCapture(), ScreenCapture()]
    private var renderer: Renderer?
    private var window: NSWindow?
    private var metalView: MTKView?

    private let sampleCounter = Counter()
    private let tapEnabled = Flag()
    private let imuLoop = RunLoopHandle()
    private var rateTimer: Timer?
    private var pacingWindow: [(drawn: Int, long: Int)] = []

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

    /// Keeps App Nap and timer coalescing away from the render pipeline for
    /// the whole session — frame pacing is the product.
    private var activityToken: NSObjectProtocol?

    /// True while a wall-layout fix is running; the check is per-second and
    /// the fix takes longer than a second.
    private var layoutFixInFlight = false

    /// Set when the Mac goes to sleep mid-session: the session is stopped
    /// cleanly before sleep and started again once the glasses re-enumerate
    /// after wake. Without this the watchdog saw the sleeping capture stream
    /// as a fault and tore the session down for good.
    private var resumeOnWake = false

    /// 60 Hz mode-0 is the daily driver: clean image, 1:1 pacing. The
    /// standalone opt-ins run their panel's own rate — 60/90 for the SBS
    /// variants, 120 for mode 3.
    private var frameRate: Int { source == .glassesOnly ? sbsMode.frameRate : 60 }

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
        if d.object(forKey: "doubleTapRecenter") != nil { doubleTapRecenter = d.bool(forKey: "doubleTapRecenter") }
        if d.object(forKey: "curved") != nil { curved = d.bool(forKey: "curved") }
        if d.object(forKey: "antiMoire") != nil { antiMoire = d.bool(forKey: "antiMoire") }
        if let v = SBSMode(rawValue: d.string(forKey: "sbsMode") ?? "") {
            sbsMode = v
        } else if d.bool(forKey: "sbs90") {
            // The short-lived Bool this picker replaced, same day.
            sbsMode = .sbs90
        }
        if let v = SideScreens(rawValue: d.string(forKey: "sideScreens") ?? "") {
            sideScreens = v
        }

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
        load("steady", into: &steady)
        load("motionLock", into: &motionLock)
        load("screenGap", into: &screenGap)

        // Property observers don't fire during init, so the loaded values
        // have to be pushed into the render-side objects by hand.
        screen.mode = mode
        screen.distance = distance
        screen.diagonal = diagonal
        screen.verticalOffset = height
        screen.curved = curved
        screen.deadzoneDegrees = deadzone
        screen.followSpeed = followSpeed
        screen.settleSpeed = settleSpeed
        screen.ipd = ipd
        screen.motionLock = motionLock

        // Sleep/wake: willSleep is delivered on the main queue before the
        // machine actually sleeps, so the teardown starts while everything
        // is still awake to be torn down.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    // MARK: Sleep/wake

    /// Stop cleanly before the machine sleeps. A full stop-and-restart reuses
    /// every hardened setup path (mode re-assertion, mirror handling, capture
    /// auto-restart) instead of trying to keep a session alive across a power
    /// cycle that may change display IDs and revert panel modes.
    private func systemWillSleep() {
        guard isRunning || isStarting else { return }
        Self.appendLog("Sleep — suspending the session, will restart on wake")
        resumeOnWake = true
        stop()
    }

    private func systemDidWake() {
        guard resumeOnWake else { return }
        resumeOnWake = false
        Self.appendLog("Wake — waiting for the glasses display")
        setStatus("Waking — waiting for the glasses…")
        Task {
            // Wait for the pre-sleep teardown to finish and the glasses to
            // re-enumerate; both take a few seconds after wake.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if !self.isRunning, !self.isStarting, self.displays.glassesArePresent { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !self.isRunning, !self.isStarting else { return }
            guard self.displays.glassesArePresent else {
                self.setStatus("Glasses not detected after wake — press Start once they are connected.",
                               isError: true)
                return
            }
            // Let the display enumeration settle before reconfiguring it.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            Self.appendLog("Wake — glasses are back, restarting")
            self.start()
        }
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
        // The stereo variants' working desktop obeys the same rule: create
        // first, fight once. (120 Hz captures the glasses' own desktop and
        // needs no extra display.)
        if source == .virtualDesktop || stereoActive {
            setStatus(stereoActive ? "Creating the \(frameRate) Hz working desktop…"
                                   : "Creating the virtual desktop…")
            do {
                if stereoActive {
                    // The size matches the per-eye panel raster exactly, and
                    // the rate matches the panel: a slower virtual display in
                    // the set drags the whole composition down (measured
                    // 2026-08-12).
                    let size = sbsMode.desktopSize
                    try virtualDisplay.create(width: size.width, height: size.height,
                                              hiDPI: false,
                                              refreshRate: Double(frameRate))
                } else {
                    try virtualDisplay.create(
                        width: virtualResolution.width,
                        height: virtualResolution.height,
                        hiDPI: virtualResolution.hiDPI
                    )
                }
            } catch {
                setStatus("\(error)", isError: true)
                isStarting = false
                return
            }
        }

        let displayMode: DisplayMode = standaloneActive ? sbsMode.panelMode : .sameOnBoth
        setStatus(standaloneActive ? "Switching the glasses to \(sbsMode.label)…"
                                   : "Switching the glasses to 60 Hz…")

        // Display reconfiguration blocks for a few seconds while the panel
        // renegotiates, so keep it off the main thread.
        // Applied to the glasses display after the panel settles; the
        // requested size falls back to the nearest one the panel offers.
        Task.detached(priority: .userInitiated) { [displays, source, standaloneActive] in
            do {
                if standaloneActive {
                    try displays.prepareStandalone(mode: displayMode)
                } else if source == .glassesOnly {
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
        if stereoActive {
            // The SBS panel modes' own desktops are wide slivers (1920×600
            // or ×540 points) and unusable as a workspace; the user works on
            // the matching-rate virtual display and the overlay projects it
            // once per eye. (120 Hz has a real 1920×1200 desktop and falls
            // through to the glasses-capture path below.)
            guard let id = virtualDisplay.displayID else {
                abort("The working desktop did not report a display ID.")
                return
            }
            captureID = id
        } else {
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
                // Capture the glasses' own display — the overlay is excluded
                // from the capture per-window, which breaks the recursion.
                guard let id = displays.glassesDisplayID else {
                    abort("The glasses display disappeared during setup.")
                    return
                }
                captureID = id
            }
        }

        if source != .glassesOnly {
            // One mirrored display set: there is nothing to arrange.
            applyArrangement()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } else {
            // Side displays are created at exactly the main desktop's
            // effective size, so all screens match and windows keep their
            // size when dragged across. Failure never ends the session.
            // Stereo: sides match the working desktop, not the glasses' wide
            // sliver. All virtual displays run at the panel's rate — a slower
            // member drags composition down even unmirrored. (120 Hz and
            // plain glasses-only both use the glasses' real desktop size.)
            let effective = stereoActive ? sbsMode.desktopSize
                                         : displays.glassesDesktopSize
            for index in sideScreens.indices {
                do {
                    // Match the panel's rate: a 60 Hz virtual display in the
                    // set drags the whole composition back down to ~60-90
                    // (measured; 120 came back the moment both sides went).
                    try sideDisplays[index].create(
                        width: effective.width, height: effective.height,
                        hiDPI: false, refreshRate: Double(frameRate),
                        identity: UInt32(2 + index)
                    )
                } catch {
                    Self.appendLog("side screen \(index) unavailable: \(error)")
                }
            }
            // Let the window server enumerate them before capture, then push
            // the main desktop's size back — creating displays makes macOS
            // re-apply the mode it remembers, undoing the chosen size.
            if !sideScreens.indices.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await Task.detached { [displays] in
                    displays.reapplyDesktopSize()
                }.value
            }
        }

        guard let renderer = Renderer(filter: filter, screen: screen) else {
            abort("Could not create the Metal renderer.")
            return
        }
        // SBS: the framebuffer holds both eyes across its width; the stereo
        // path renders per-eye viewports with ±ipd/2 offsets.
        renderer.stereo = stereoActive
        renderer.lookAhead = lookAhead
        renderer.steady = steady
        renderer.antiMoire = antiMoire
        renderer.targetFPS = frameRate
        renderer.sideGap = screenGap * .pi / 180
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
                frameRate: frameRate,
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
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Realtime XR rendering")
        isRunning = true
        isStarting = false
        let size = displays.glassesPixelSize
        setStatus(String(format: "Running — %.0f×%.0f @ %d Hz",
                         size.width, size.height, frameRate))
        startRateTimer()

        // Last, after everything is confirmed running: glasses-only mode's
        // screen-off, plus the cursor swap. The hardware cursor is hidden
        // system-wide (nothing gentler removes it — it is composited above
        // every window), which also stops SCK from drawing it; the renderer
        // paints its own sprite at the same position instead, so exactly one
        // cursor exists and it lives on the virtual screen.
        if source == .glassesOnly {
            // SBS-60 keeps the built-in lit: it mirrors the working desktop,
            // so the laptop shows exactly what the glasses show — take the
            // glasses off and the work is still in front of you. Dimming it
            // made everything vanish from the physical screen the moment the
            // desktops merged (user hit the emergency stop over it, live).
            // The other variants park it dark as before.
            if sbsMode != .sbs60, let deskID = displays.deskDisplayID {
                savedBrightness = BuiltinBrightness.get(deskID) ?? 0.5
                BuiltinBrightness.set(deskID, to: 0)
            }

            if standaloneActive {
                // The standalone wall in one batched reconfiguration: the
                // main desktop centred at the origin (the working virtual
                // display for stereo, the glasses themselves for 120 Hz),
                // sides flush left/right, the rest parked below. And no
                // mirror touching the glasses or sides — that would
                // harmonize the flip rate straight back down to 60.
                let sides = sideScreens.indices.compactMap { index -> (id: CGDirectDisplayID, isRight: Bool)? in
                    guard let id = sideDisplays[index].displayID else { return nil }
                    return (id, index == 0)
                }
                let parked = standaloneParked(excluding: captureID)
                let mergeBuiltin = sbsMode == .sbs60
                await Task.detached { [displays] in
                    // Creating the sides invites a remembered-arrangement
                    // re-apply, and the mirror it brings back is not
                    // necessarily onto the glasses (seen live: built-in
                    // mirrored onto the left side). Clear every mirror
                    // first — a mirrored display cannot be repositioned,
                    // so the layout fix would loop forever against it.
                    _ = displays.reassertUnmirrored()
                    displays.fixWallLayout(main: captureID, sides: sides, parked: parked)
                    if mergeBuiltin {
                        // SBS-60's stranded-window fix: the built-in joins
                        // the *working desktop's* mirror set, so its desktop
                        // — and every window open before Start — merges into
                        // the one the glasses show ("แอพหาย", seen live).
                        // Only at 60: a 60 Hz member would drag the 90/120
                        // variants' content rate down.
                        _ = displays.mirrorBuiltinOntoWorking(captureID)
                    }
                }.value
            } else {
                // Side screens, for those whose displays came up: right sits
                // to the right of the main desktop and left to the left, so
                // the pointer leaves on the side the eye sees the screen.
                // Position everything first, then re-assert the main
                // desktop's size — every reconfiguration invites macOS to
                // revert it.
                for index in sideScreens.indices {
                    guard let sideID = sideDisplays[index].displayID else { continue }
                    if index == 0 {
                        displays.positionToRight(sideID, of: captureID)
                    } else {
                        displays.positionToLeft(sideID, of: captureID)
                    }
                }
                if !sideScreens.indices.isEmpty {
                    await Task.detached { [displays] in
                        displays.reapplyDesktopSize()
                    }.value
                }
                // Creating and positioning the side displays invites macOS to
                // re-apply its remembered (unmirrored) arrangement; put the
                // built-in back into the mirror set before capture starts.
                _ = displays.reassertGlassesOnlyMirror()
            }
            for index in sideScreens.indices {
                guard let sideID = sideDisplays[index].displayID else { continue }
                let sideCapture = sideCaptures[index]
                sideCapture.onFrame = { [weak renderer] buffer in
                    renderer?.submitSide(index, frame: buffer)
                }
                sideCapture.onStop = { error in
                    // Losing a side screen is cosmetic; never end the
                    // session over it.
                    Self.appendLog("side \(index) capture stopped: \(error.localizedDescription)")
                }
                do {
                    // Mostly-static content; half rate is plenty and keeps
                    // the window server's capture work away from the main
                    // screen's 60 fps floor.
                    try await sideCapture.start(displayID: sideID, frameRate: 30,
                                                showsCursor: false)
                    renderer.sideActive[index] = true
                } catch {
                    Self.appendLog("side \(index) capture failed to start: \(error)")
                }
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

        let imageSize = SIMD2(Float(image.size.width), Float(image.size.height))
        let hotspot = SIMD2(Float(cursor.hotSpot.x), Float(cursor.hotSpot.y))
        func fractions(of bounds: CGRect) -> (size: SIMD2<Float>, hotspot: SIMD2<Float>) {
            let display = SIMD2(Float(bounds.width), Float(bounds.height))
            return (imageSize / display, hotspot / display)
        }

        let mainBounds = CGDisplayBounds(displayID)
        renderer.cursorTexture = texture
        (renderer.cursorFraction[0], renderer.cursorHotspotFraction[0]) = fractions(of: mainBounds)

        // Surface n+1 is side screen n (0 right, 1 left).
        var sideBounds: [CGRect?] = [nil, nil]
        for index in sideScreens.indices {
            guard let id = sideDisplays[index].displayID else { continue }
            let bounds = CGDisplayBounds(id)
            sideBounds[index] = bounds
            (renderer.cursorFraction[index + 1],
             renderer.cursorHotspotFraction[index + 1]) = fractions(of: bounds)
        }

        // Asking the window server for the pointer is an IPC round-trip;
        // doing it on the render thread put that jitter inside the frame
        // deadline. A dedicated poller keeps the freshest location in a
        // locked box the render closure just reads.
        let poller = mousePoller
        poller.start()
        renderer.cursorPosition = {
            // CGEvent's location is global, top-left origin — the same space
            // as the displays' bounds.
            guard let location = poller.location else { return nil }
            func uv(in bounds: CGRect) -> SIMD2<Float> {
                SIMD2(Float((location.x - bounds.minX) / bounds.width),
                      Float((location.y - bounds.minY) / bounds.height))
            }
            if mainBounds.contains(location) { return (0, uv(in: mainBounds)) }
            for (index, bounds) in sideBounds.enumerated() {
                if let bounds, bounds.contains(location) { return (index + 1, uv(in: bounds)) }
            }
            return nil
        }
    }

    /// Polls the global pointer position at ~120 Hz on its own queue and
    /// caches it for the render thread. One poll per frame still happens —
    /// just no longer *on* the frame.
    private final class MousePoller: @unchecked Sendable {
        private let lock = NSLock()
        private var current: CGPoint?
        private var timer: DispatchSourceTimer?

        var location: CGPoint? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func start() {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "mouse-poller", qos: .userInteractive))
            source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let location = CGEvent(source: nil)?.location
                self.lock.lock()
                self.current = location
                self.lock.unlock()
            }
            source.resume()
            timer = source
        }

        func stop() {
            timer?.cancel()
            timer = nil
        }
    }

    private let mousePoller = MousePoller()

    /// Displays a standalone session parks below the wall: the glasses'
    /// sliver desktop (stereo variants only — at 120 Hz the glasses ARE the
    /// wall's main) and the built-in — except in SBS-60, where the built-in
    /// is a mirror slave of the working desktop and has no place of its own.
    private func standaloneParked(excluding mainID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        [displays.glassesDisplayID,
         sbsMode == .sbs60 ? nil : displays.deskDisplayID]
            .compactMap { $0 }.filter { $0 != mainID }
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
            for sideCapture in sideCaptures { await sideCapture.stop() }
            teardown()
            restoreBrightness()
            isRunning = false
            if source == .glassesOnly {
                // Mirroring stays — it is the desired end state, so there is
                // no enforcement wait and stop is immediate. The standalone
                // experiment re-mirrors first to land in the same state.
                displays.restorePanelOnly(remirror: standaloneActive)
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
            case .glassesOnly:
                captureID = self.stereoActive ? self.virtualDisplay.displayID
                                              : self.displays.glassesDisplayID
            }
            guard let captureID else { return }  // the watchdog handles this
            do {
                try await self.capture.start(
                    displayID: captureID,
                    frameRate: self.frameRate,
                    excludingWindowNumber: self.source == .glassesOnly
                        ? self.window?.windowNumber : nil,
                    showsCursor: self.source != .glassesOnly
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
            displays.restorePanelOnly(remirror: standaloneActive)
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
            displays.restorePanelOnly(remirror: standaloneActive)
        } else {
            displays.restore()
        }
        isRunning = false
        isStarting = false
    }

    private func teardown() {
        // Take the virtual displays down first: any windows on them need a
        // real screen to fall back to, and that has to still exist.
        virtualDisplay.destroy()
        sideDisplays.forEach { $0.destroy() }
        cursorTimer?.invalidate()
        cursorTimer = nil
        mousePoller.stop()
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        activityToken = nil
        rateTimer?.invalidate()
        rateTimer = nil
        if let loop = imuLoop.get(), let imu {
            // Stop the device on the thread it is scheduled on, then let the
            // run loop wind down and end the thread.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                imu.stop()
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(loop)
        } else {
            imu?.stop()
        }
        imu = nil
        renderer?.stopRenderLoop()
        metalView?.isPaused = true
        metalView?.delegate = nil
        metalView = nil
        window?.orderOut(nil)
        window = nil
        renderer = nil
    }

    // MARK: Pieces

    private func startIMU() {
        let tapDetector = TapDetector(sampleRate: 440)
        // For threshold tuning, set `tapDetector.debugLog` here — one line a
        // second of peak-vs-threshold telemetry. The values in RESEARCH.md
        // were measured that way.
        // Everything the callback touches is thread-safe: the filter locks
        // internally, the counter and flag are locked boxes, and re-centre
        // hops back to the main actor.
        let filter = self.filter
        let counter = self.sampleCounter
        let tapEnabled = self.tapEnabled
        let imu = RokidIMU { [weak self] sample in
            filter.update(sample)
            counter.increment()
            if tapEnabled.get(),
               tapDetector.update(gyro: sample.gyro, accel: sample.accel,
                                  timestamp: sample.timestamp) == 2 {
                NSLog("RokidSpatial: double-tap — recentring")
                DispatchQueue.main.async { self?.recenter() }
            }
        }

        // A dedicated thread for the 440 Hz HID stream. On the main run loop
        // those callbacks competed with the renderer's 8.3 ms deadline; here
        // they cost the main thread nothing.
        let imuLoop = self.imuLoop
        let thread = Thread { [weak self] in
            do {
                try imu.start(on: CFRunLoopGetCurrent())
            } catch {
                DispatchQueue.main.async { self?.setStatus("\(error)", isError: true) }
                return
            }
            imuLoop.set(CFRunLoopGetCurrent())
            CFRunLoopRun()
        }
        thread.name = "imu"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.imu = imu

        // Let the filter settle before treating the current pose as forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.recenter()
        }
    }

    /// Thread-safe IMU sample counter — incremented on the IMU thread, read
    /// once a second on the main thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func take() -> Int {
            lock.lock()
            defer { value = 0; lock.unlock() }
            return value
        }
    }

    /// Thread-safe mirror of a settings flag, readable from the IMU thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Hands the IMU thread's run loop back to the main thread for teardown.
    private final class RunLoopHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var loop: CFRunLoop?
        func set(_ newLoop: CFRunLoop) { lock.lock(); loop = newLoop; lock.unlock() }
        func get() -> CFRunLoop? { lock.lock(); defer { lock.unlock() }; return loop }
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
        view.preferredFramesPerSecond = frameRate
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

        // Rendering runs on a dedicated thread paced by the glasses display —
        // see Renderer.startRenderLoop for the two problems this solves.
        if let glassesID = displays.glassesDisplayID {
            renderer.startRenderLoop(displayID: glassesID, view: view)
        }
    }

    private func startRateTimer() {
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sampleRate = self.sampleCounter.take()
                self.yaw = self.filter.yawDegrees
                if let renderer = self.renderer {
                    let stats = renderer.takeFrameStats()
                    self.renderFPS = stats.drawn
                    self.longFrames = stats.long
                    // One log line every 10 s — enough history to compare
                    // pacing before and after pipeline changes.
                    self.pacingWindow.append(stats)
                    if self.pacingWindow.count >= 10 {
                        let drawn = self.pacingWindow.map(\.drawn).reduce(0, +)
                        let long = self.pacingWindow.map(\.long).reduce(0, +)
                        Self.appendLog("pacing: \(drawn / 10) fps avg, \(long) slow frames in 10 s")
                        self.pacingWindow.removeAll()
                    }
                }
                // Plain glasses-only has one display — nowhere to get
                // stranded. The 90/120 standalone variants park the built-in
                // dark, and windows left there are invisible; list their
                // owners. (SBS-60 merges that desktop away instead.)
                self.strandedApps = {
                    if self.source != .glassesOnly {
                        return self.displays.strandedWindowOwners()
                    }
                    if self.standaloneActive, self.sbsMode != .sbs60,
                       let desk = self.displays.deskDisplayID {
                        return self.displays.strandedWindowOwners(on: desk)
                    }
                    return []
                }()
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
            // Modes that must stay unmirrored (extended sources, the
            // standalone variants) treat an unexpected mirror as a fault to
            // undo; plain glasses-only treats the mirror as the desired
            // state. SBS-60 allows exactly one pair — built-in as slave of
            // the working desktop (the stranded-window fix); anything else
            // harmonizes the flip rate or pins a display the wall needs.
            let allowedMaster = sbsMode == .sbs60 ? virtualDisplay.displayID : nil
            if source != .glassesOnly || standaloneActive,
               standaloneActive ? displays.unexpectedMirror(allowedMaster: allowedMaster)
                                : CGDisplayIsInMirrorSet(glassesID) != 0 {
                // Try to undo it before treating it as fatal — macOS often
                // reinstates mirroring transiently while a reconfiguration
                // settles, and recovering beats tearing the session down.
                mirrorRecoveryAttempts += 1
                if mirrorRecoveryAttempts <= 2, displays.reassertUnmirrored() {
                    // Blanket un-mirroring also removed SBS-60's wanted
                    // pair; put it straight back.
                    if let allowedMaster {
                        _ = displays.mirrorBuiltinOntoWorking(allowedMaster)
                    }
                    // The re-apply also scrambled the arrangement. The
                    // standalone wall is put back by the layout check below
                    // on the next tick; the extended sources fix theirs here.
                    if !standaloneActive { applyArrangement() }
                    setStatus("macOS re-enabled mirroring; un-mirrored it again.")
                    unhealthyTicks = 0
                    return
                }
                problems.append("the glasses keep being put back into a mirror set")
            }
            if CGDisplayIsActive(glassesID) == 0 {
                problems.append("the glasses display went inactive")
            }
            // The inverse fight: plain glasses-only *wants* the built-in
            // mirrored (dark, no second desktop), and macOS keeps re-applying
            // the unmirrored arrangement it remembered from the standalone
            // experiments. Capped so a truly stubborn window server cannot
            // make this loop forever. Never in the standalone variants.
            if source == .glassesOnly, !standaloneActive, mirrorRecoveryAttempts <= 4,
               displays.reassertGlassesOnlyMirror() {
                mirrorRecoveryAttempts += 1
                // The re-mirror is itself a reconfiguration; let it settle
                // before judging health again.
                unhealthyTicks = 0
                return
            }
            // SBS-60's merge mirror can fall out on a remembered re-apply,
            // resurfacing the built-in as its own desktop and re-stranding
            // windows there. Put it back, capped like the other fights.
            if let allowedMaster, mirrorRecoveryAttempts <= 4,
               displays.mirrorBuiltinOntoWorking(allowedMaster) {
                mirrorRecoveryAttempts += 1
                unhealthyTicks = 0
                return
            }
            // The main screen stays at the centre of the wall. When macOS
            // re-applies a remembered arrangement that scatters the displays,
            // put them back and re-derive the cursor mapping, whose display
            // bounds were captured at attach time. In SBS the wall's main is
            // the working desktop, and the glasses + built-in park below it.
            if source == .glassesOnly, !layoutFixInFlight {
                let sides = sideScreens.indices.compactMap { index -> (id: CGDirectDisplayID, isRight: Bool)? in
                    guard let id = sideDisplays[index].displayID else { return nil }
                    return (id, index == 0)
                }
                let mainID = stereoActive ? virtualDisplay.displayID : glassesID
                let parked = standaloneActive
                    ? (mainID.map { standaloneParked(excluding: $0) } ?? [])
                    : []
                if let mainID,
                   displays.wallLayoutIsBroken(main: mainID, sides: sides, parked: parked) {
                    layoutFixInFlight = true
                    Self.appendLog("layout: the wall drifted — recentring the main screen")
                    Task {
                        await Task.detached { [displays] in
                            displays.fixWallLayout(main: mainID, sides: sides, parked: parked)
                        }.value
                        if let renderer = self.renderer {
                            self.attachRenderedCursor(to: renderer, displayID: mainID)
                        }
                        self.layoutFixInFlight = false
                    }
                    unhealthyTicks = 0
                    return
                }
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
            displays.restorePanelOnly(remirror: standaloneActive)
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
