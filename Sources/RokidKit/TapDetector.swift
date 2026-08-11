// Detects the wearer physically tapping the glasses, from the gyro stream.
//
// A finger tap shows up as a sharp spike in rotation rate — far sharper than
// any head movement — so the detector watches the *derivative* of the gyro
// magnitude over a short window. Ported from XRLinuxDriver's multitap.c
// (state machine, thresholds and timings kept as-is; they are tuned against
// real taps on these devices, double-tap-to-recenter being the intended use).

import Foundation
import simd

public final class TapDetector {
    private enum State {
        case idle, rise, fall, pause
    }

    // Thresholds tuned against this hardware (see RESEARCH.md): still wear
    // peaks near 700, vigorous head shakes near 1,800, real taps 4,300+.
    private let detectThreshold: Float = 2500
    /// Second gate: a tap is a linear shock too. Head shakes measured ≤1.5,
    /// taps ≥8 (m/s² change between consecutive samples).
    private let accelGate: Float = 3.0
    private let pauseThreshold: Float = 100
    private let maxTapPeriodMs: UInt64 = 750   // window between tap starts
    private let maxTapDurationMs: UInt64 = 70  // a real tap is very quick
    private let minPauseMs: UInt64 = 10        // required quiet between taps
    /// Much shorter than multitap.c's 25 ms, on purpose. A tap's gyro spike
    /// lasts only a few samples at 440 Hz; a 25 ms window averaged it down to
    /// ~270 °/s² on the real hardware (7× under the threshold) while slow head
    /// motion sat at ~60. A 5 ms window keeps the spike's sharpness, which is
    /// the very thing that distinguishes a tap from a head turn.
    private let windowSeconds: Float = 0.005

    private var buffer: [Float] = []
    private var bufferSize = 0
    private var writeIndex = 0
    private var filled = false
    private var sampleRate: Float

    private var state: State = .idle
    private var tapStartMs: UInt64 = 0
    private var pauseStartMs: UInt64 = 0
    private var tapCount = 0

    /// Diagnostic tap telemetry, called at most once a second: the peak
    /// derivative seen since the last call, against the detect threshold.
    /// Set while tuning; taps that fail to register show up here as peaks
    /// below 2000.
    public var debugLog: ((String) -> Void)?
    private var debugPeak: Float = 0
    private var debugLastLogMs: UInt64 = 0

    public init(sampleRate: Float = 440) {
        self.sampleRate = sampleRate
        bufferSize = max(2, Int(windowSeconds * sampleRate))
        buffer = [Float](repeating: 0, count: bufferSize)
    }

    private var previousAccelMagnitude: Float?
    private var debugAccelPeak: Float = 0

    /// Feed one IMU sample (gyro rad/s, accel m/s²). Returns the completed
    /// tap count when a tap sequence ends, else 0 — e.g. 2 for a double tap,
    /// delivered ~750 ms after the first tap.
    public func update(gyro: SIMD3<Float>, accel: SIMD3<Float> = .zero,
                       timestamp: UInt64) -> Int {
        let timestampMs = timestamp / 1_000_000
        let magnitude = simd_length(gyro) * 180 / .pi  // deg/s

        // A tap is first and foremost a linear shock; the change in accel
        // magnitude between consecutive samples is the second gate.
        let accelMagnitude = simd_length(accel)
        let accelDelta = previousAccelMagnitude.map { abs(accelMagnitude - $0) } ?? 0
        previousAccelMagnitude = accelMagnitude
        if debugLog != nil { debugAccelPeak = max(debugAccelPeak, accelDelta) }

        let oldest = buffer[writeIndex]
        buffer[writeIndex] = magnitude
        writeIndex = (writeIndex + 1) % bufferSize
        if writeIndex == 0 { filled = true }
        guard filled else { return 0 }

        // Rate of change across the window, extrapolated to per-second so the
        // thresholds are independent of buffer size.
        let acceleration = (magnitude - oldest) * sampleRate / Float(bufferSize)

        if let debugLog {
            debugPeak = max(debugPeak, acceleration)
            if timestampMs &- debugLastLogMs > 1000 {
                debugLog(String(format: "gyroDeriv %.0f (threshold %.0f) accelJump %.1f state %@ taps %d",
                                debugPeak, detectThreshold, debugAccelPeak,
                                String(describing: state), tapCount))
                debugPeak = 0
                debugAccelPeak = 0
                debugLastLogMs = timestampMs
            }
        }

        let tapElapsed = timestampMs &- tapStartMs
        if (tapCount > 0 || state != .idle) && tapElapsed > maxTapPeriodMs {
            state = .idle
            let final = tapCount
            tapCount = 0
            return final
        }

        switch state {
        case .idle:
            if acceleration > detectThreshold && accelDelta > accelGate {
                tapStartMs = timestampMs
                state = .rise
            }
        case .rise:
            if acceleration < 0 { state = .fall }
        case .fall:
            if acceleration > 0 {
                if tapElapsed > maxTapDurationMs {
                    // Too slow to be a tap — a head movement.
                    state = .idle
                    tapCount = 0
                } else {
                    tapCount += 1
                    pauseStartMs = timestampMs
                    state = .pause
                }
            }
        case .pause:
            if abs(acceleration) < pauseThreshold {
                if timestampMs &- pauseStartMs > minPauseMs { state = .idle }
            } else {
                pauseStartMs = timestampMs
            }
        }
        return 0
    }
}
