import SwiftUI
import RokidKit

/// Deliberately short.
///
/// An earlier version listed every tuning knob at once and grew to nearly 970
/// points tall — taller than the visible area in the glasses, which put the
/// Start button somewhere you could not reach. Everything needed day to day is
/// now above the fold; the rest lives behind a disclosure, and the whole thing
/// scrolls and is capped so it can never outgrow the screen again.
struct SettingsView: View {
    @ObservedObject var controller: SpatialController
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                essentials
                advanced
                Divider()
                // Last, so Start/Stop is always the bottom-most thing on
                // screen whether or not the disclosure is open.
                actions
            }
            .padding(16)
        }
        // An explicit height is required, not a maximum. A ScrollView has no
        // intrinsic height, so `maxHeight` alone lets the hosting window
        // collapse to nothing — which it duly did, to 28 points.
        .frame(width: 340, height: showAdvanced ? 700 : 560)
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

            if !controller.strandedApps.isEmpty {
                Text("Hidden behind the overlay: \(controller.strandedApps.joined(separator: ", ")). Press Stop, drag them onto the MacBook screen, then Start.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var essentials: some View {
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
            }

            slider("Distance", value: $controller.distance,
                   range: 0.4...12, unit: "m", format: "%.1f")
            slider("Size", value: $controller.diagonal,
                   range: 0.3...8, unit: "m", format: "%.1f")
            slider("Height", value: $controller.height,
                   range: -1.5...1.5, unit: "m", format: "%+.2f")
            Toggle("Curved screen", isOn: $controller.curved)
                .font(.caption)
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
                if controller.sideScreens != .none {
                    slider("Gap", value: $controller.screenGap,
                           range: 0...10, unit: "°", format: "%.0f")
                }
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

    // MARK: Folded away

    private var advanced: some View {
        DisclosureGroup("More", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
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
                    Toggle("Work in the glasses", isOn: $controller.virtualIsMain)
                        .disabled(controller.isRunning)
                }
                if controller.source == .glassesOnly {
                    // Options come from the panel itself, learned on the
                    // first run; applies to all three screens.
                    labelled("Desktop size (all screens)") {
                        Picker("", selection: $controller.desktopSize) {
                            ForEach(controller.desktopSizes, id: \.self) { size in
                                Text(size).tag(size)
                            }
                        }
                        .labelsHidden()
                        .disabled(controller.isRunning)
                    }
                }

                Button("Fit for sharpness") { controller.fitForSharpness() }
                    .disabled(!controller.isRunning)

                Toggle("Double-tap glasses to re-centre", isOn: $controller.doubleTapRecenter)

                if controller.mode == .follow {
                    slider("Deadzone", value: $controller.deadzone,
                           range: 0...45, unit: "°", format: "%.0f")
                    slider("Follow speed", value: $controller.followSpeed,
                           range: 0.5...20, unit: "", format: "%.1f")
                    slider("Settle", value: $controller.settleSpeed,
                           range: 0...5, unit: "", format: "%.2f")
                }

                slider("Stabilizer", value: $controller.steady,
                       range: 0...0.060, unit: "s", format: "%.3f")
                slider("Lock while turning", value: $controller.motionLock,
                       range: 0...1, unit: "", format: "%.2f")
                slider("Prediction", value: $controller.lookAhead,
                       range: 0...0.050, unit: "s", format: "%.3f")

                Text("⌃⌥Esc stop · ⌃⌥R centre · ⌃⌥C calibrate\n⌃⌥- ⌃⌥= distance · ⌃⌥[ ⌃⌥] size · ⌃⌥↑ ⌃⌥↓ height")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.caption)
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
