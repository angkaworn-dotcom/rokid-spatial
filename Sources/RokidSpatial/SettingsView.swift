import SwiftUI
import RokidKit

/// Three tabs, one rule: Start/Stop is pinned outside the scroll area, so it
/// is reachable no matter what any tab grows into.
///
/// History that shaped this. An early version listed every knob at once and
/// grew to nearly 970 points — taller than the glasses' visible area, which
/// put the Start button somewhere you could not reach. The disclosure-group
/// version that followed fixed the height but buried everything two clicks
/// deep and interleaved unrelated settings. Tabs give each concern a page:
/// what the screen *is* (Screen), how it treats your body (Comfort), and the
/// numbers most sessions never touch (Tuning).
struct SettingsView: View {
    @ObservedObject var controller: SpatialController

    private enum Tab: String, CaseIterable, Identifiable {
        case screen = "Screen"
        case comfort = "Comfort"
        case tuning = "Tuning"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .screen

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .screen: screenTab
                    case .comfort: comfortTab
                    case .tuning: tuningTab
                    }
                }
                .padding(.top, 2)
                // Keep slider thumbs clear of the scroll bar.
                .padding(.trailing, 2)
            }

            Divider()
            actions
        }
        .padding(14)
        // An explicit height is required, not a maximum. A ScrollView has no
        // intrinsic height, so `maxHeight` alone lets the hosting window
        // collapse to nothing — which it duly did, to 28 points.
        .frame(width: 340, height: 580)
    }

    // MARK: Always visible

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(controller.statusIsError ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.isRunning {
                Text(String(format: "%d Hz · yaw %+.1f° · sharp %.2f× · %d fps (%d slow)",
                            controller.sampleRate, controller.yaw, controller.pixelScale,
                            controller.renderFPS, controller.longFrames))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(controller.pixelScale < 0.95 || controller.longFrames > 6
                                     ? Color.orange : .secondary)
            }

            if controller.lowPowerMode {
                Text("Low Power Mode: content updates reduced to 30 fps to keep head-tracking smooth. For full quality, plug in or set System Settings → Battery → Low Power Mode to Never.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controller.strandedApps.isEmpty {
                Text(WindowRescue.hasPermission
                     ? "Hidden on a covered screen: \(controller.strandedApps.joined(separator: ", ")). Moving them back…"
                     : "Hidden on a covered screen: \(controller.strandedApps.joined(separator: ", ")). Grant Rokid Spatial Accessibility permission (System Settings → Privacy & Security) to move them back automatically, or press Stop to get them back.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(controller.calibrationEndsAt == nil ? "Calibrate" : "Hold still…") {
                controller.calibrate()
            }
            .disabled(!controller.isRunning || controller.calibrationEndsAt != nil)

            Button("Centre") { controller.recenter() }
                .disabled(!controller.isRunning)

            Spacer()

            Button(controller.isRunning ? "Stop" : "Start") {
                controller.isRunning ? controller.stop() : controller.start()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Screen — what is shown, where it hangs

    private var screenTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Show") {
                Picker("", selection: $controller.source) {
                    ForEach(SpatialController.CaptureSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(controller.isRunning)
            }

            labelled("Screen") {
                Picker("", selection: $controller.mode) {
                    ForEach(AnchorMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // A multi-screen wall is anchored by definition.
                .disabled(controller.source == .glassesOnly && controller.sideScreens != .none)
            }
            // Mode-specific feel knobs live directly under the mode picker,
            // so cause and effect sit next to each other.
            if controller.mode == .follow {
                slider("Deadzone", value: $controller.deadzone,
                       range: 0...45, unit: "°", format: "%.0f")
                slider("Follow speed", value: $controller.followSpeed,
                       range: 0.5...20, unit: "", format: "%.1f")
                slider("Settle", value: $controller.settleSpeed,
                       range: 0...5, unit: "", format: "%.2f")
            }
            if controller.mode == .smoothFollow {
                slider("Glide", value: $controller.glideSpeed,
                       range: 0.3...5, unit: "", format: "%.1f")
            }

            slider("Distance", value: $controller.distance,
                   range: 0.4...12, unit: "m", format: "%.1f")
            slider("Size", value: $controller.diagonal,
                   range: 0.3...8, unit: "m", format: "%.1f")
            slider("Height", value: $controller.height,
                   range: -1.5...1.5, unit: "m", format: "%+.2f")
            HStack {
                Toggle("Curved screen", isOn: $controller.curved)
                    .font(.caption)
                Spacer()
                Button("Fit for sharpness") { controller.fitForSharpness() }
                    .font(.caption)
                    .disabled(!controller.isRunning)
            }

            if controller.source == .virtualDesktop {
                labelled("Desktop size") {
                    Picker("", selection: $controller.virtualResolution) {
                        ForEach(SpatialController.VirtualResolution.allCases) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(controller.isRunning)
                }
                if controller.virtualResolution == .r2560x1080 {
                    Text("2560×1080 ultra-wide — one panoramic desktop. Turn on Curved screen so the edges stay the same distance as the centre.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Work in the glasses", isOn: $controller.virtualIsMain)
                    .font(.caption)
                    .disabled(controller.isRunning)
            }

            if controller.source == .glassesOnly {
                labelled("Side screens") {
                    Picker("", selection: $controller.sideScreens) {
                        ForEach(SpatialController.SideScreens.allCases) { sides in
                            Text(sides.label).tag(sides)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(controller.isRunning)
                }
                // Always visible, greyed until side screens are on — a row
                // that only appears after another picker changes is a row
                // nobody finds (asked about live, minutes after shipping).
                labelled("Layout") {
                    Picker("", selection: $controller.sideLayout) {
                        ForEach(SpatialController.SideLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // The SBS variants' wall parks displays above it,
                    // exactly where Stacked would hang a screen.
                    .disabled(controller.isRunning || controller.sbsMode != .off
                              || controller.sideScreens == .none)
                }
                if controller.sideScreens == .none {
                    Text("Layout applies to the side screens — pick Right or L + R above first.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.sideScreens != .none {
                    if controller.sideLayout == .stacked {
                        Text("\"Right\" hangs above the main screen, \"L + R\" adds one below. The pointer leaves through the top and bottom edges.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if controller.sideLayout == .portrait {
                        Text("Side desktops rotate 90° — tall panels for chat, logs, or reading, beside the landscape centre.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    slider("Gap", value: $controller.screenGap,
                           range: 0...10, unit: "°", format: "%.0f")
                }
                labelled("Panel mode") {
                    // 120 Hz is hidden, not gone: WindowServer only holds
                    // it steady in bursts (the direct-scanout research),
                    // and an unsteady 120 reads worse than a rock-solid 60.
                    // The user moved that goal to the Windows port. The
                    // mode itself stays reachable via --sbs=120 for
                    // future research sessions.
                    Picker("", selection: $controller.sbsMode) {
                        ForEach(SpatialController.SBSMode.allCases
                            .filter { $0 != .hz120 }) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(controller.isRunning)
                }
                if controller.sbsMode != .off {
                    Text(controller.sbsMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Comfort — how the session treats your body

    private var comfortTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Ignore head movement") {
                // SpaceWalker's Restrict Tilt/Turn trio. Roll is the daily
                // one: locked, the screen tilts with you on the sofa instead
                // of counter-rotating.
                HStack(spacing: 12) {
                    Toggle("Tilt ↕", isOn: $controller.lockPitch)
                    Toggle("Turn ↔", isOn: $controller.lockYaw)
                    Toggle("Roll ⟳", isOn: $controller.lockRoll)
                }
                .font(.caption)
            }

            slider("Eye care", value: $controller.eyeCare,
                   range: 0...1, unit: "", format: "%.2f")

            Toggle("Head-down peek", isOn: $controller.headDownPeek)
                .font(.caption)
            if controller.headDownPeek {
                slider("Peek angle", value: $controller.peekAngle,
                       range: 10...60, unit: "\u{b0}", format: "%.0f")
            }

            // Smoothing time constant; the added latency is roughly the
            // value itself. The top of the range is deliberately past
            // "sensible" (user request, after maxing the old 0.060):
            // heavy smoothing reads as a softer, slower screen — where
            // the tremor-vs-lag trade sits is for the eyes to decide.
            slider("Stabilizer", value: $controller.steady,
                   range: 0...0.200, unit: "s", format: "%.3f")

            Toggle("Double-tap glasses to re-centre", isOn: $controller.doubleTapRecenter)
                .font(.caption)

            Toggle("Auto-calibrate when set down", isOn: $controller.autoCalibrate)
                .font(.caption)
            Text("Leave the glasses still for a few seconds and the gyro re-learns its drift on its own.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.source != .glassesOnly {
                Toggle("Dim MacBook screen while running", isOn: $controller.dimBuiltin)
                    .font(.caption)
            }
        }
    }

    // MARK: Tuning — numbers most sessions never touch

    private var tuningTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Image-quality pipeline. Sharpen fights the softness bilinear
            // filtering adds while the desktop drifts across sub-pixel
            // offsets (i.e. always, under head tracking); Crisp swaps
            // bilinear for Catmull-Rom, which keeps magnified text tight.
            slider("Sharpen", value: $controller.sharpen,
                   range: 0...1, unit: "", format: "%.2f")
            Toggle("Crisp sampling (Catmull-Rom)", isOn: $controller.crispSampling)
                .font(.caption)
            // Temporal supersampling has no toggle here — rejected by eye
            // at 1:1 (slightly softer than single-frame, twice). The engine
            // stays for mirror-mode research:
            //   defaults write com.rokidspatial.app temporalSS -bool true
            Toggle("Linear-light filtering", isOn: $controller.linearLight)
                .font(.caption)
            if controller.linearLight {
                Text("Colour-correct blending: text edges lose their artificial dark fringe. Cleaner to some eyes, softer to others — judge against Sharpen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Anti-moiré resample", isOn: $controller.antiMoire)
                .font(.caption)
            if controller.antiMoire && controller.crispSampling {
                Text("Anti-moiré wins while both are on.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Adaptive VSync", isOn: $controller.adaptiveVSync)
                .font(.caption)
            if controller.adaptiveVSync {
                Text("Late frames show immediately (may tear) instead of waiting a whole refresh (always stutters). Judge by eye against the slow-frame counter.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Performance HUD", isOn: $controller.metalHUD)
                .font(.caption)
            if controller.metalHUD != controller.metalHUDAtLaunch {
                Text("Takes effect after reopening the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Eye separation for the stereo (SBS) render path. The range
            // is deliberately far wider than anatomical IPD — it is a
            // depth tuning knob: 0 = flat, high = hyperstereo.
            slider("IPD", value: $controller.ipd,
                   range: 0...0.200, unit: "m", format: "%.3f")
            slider("Lock while turning", value: $controller.motionLock,
                   range: 0...1, unit: "", format: "%.2f")
            slider("Prediction", value: $controller.lookAhead,
                   range: 0...0.050, unit: "s", format: "%.3f")

            labelled("Hotkeys") {
                Text("""
                    ⌃⌥Esc stop · ⌃⌥R centre · ⌃⌥C calibrate
                    ⌃⌥M mode (Follow → Smooth → Anchored)
                    ⌃⌥- ⌃⌥= distance · ⌃⌥[ ⌃⌥] size · ⌃⌥↑ ⌃⌥↓ height
                    """)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ label: String, value: Binding<Float>,
                        range: ClosedRange<Float>, unit: String,
                        format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue) + unit)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
