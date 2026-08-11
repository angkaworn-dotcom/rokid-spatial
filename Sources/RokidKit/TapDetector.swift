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

    // Thresholds are in deg/s per second — the units multitap.c uses.
    private let detectThreshold: Float = 2000
    private let pauseThreshold: Float = 100
    private let maxTapPeriodMs: UInt64 = 750   // window between tap starts
    private let maxTapDurationMs: UInt64 = 70  // a real tap is very quick
    private let minPauseMs: UInt64 = 10        // required quiet between taps
    private let windowSeconds: Float = 0.025

    private var buffer: [Float] = []
    private var bufferSize = 0
    private var writeIndex = 0
    private var filled = false
    private var sampleRate: Float

    private var state: State = .idle
    private var tapStartMs: UInt64 = 0
    private var pauseStartMs: UInt64 = 0
    private var tapCount = 0

    public init(sampleRate: Float = 440) {
        self.sampleRate = sampleRate
        bufferSize = max(2, Int(windowSeconds * sampleRate))
        buffer = [Float](repeating: 0, count: bufferSize)
    }

    /// Feed one gyro sample (rad/s, bias-corrected or not — taps dwarf bias).
    /// Returns the completed tap count when a tap sequence ends, else 0 —
    /// e.g. 2 for a double tap, delivered ~750 ms after the first tap.
    public func update(gyro: SIMD3<Float>, timestamp: UInt64) -> Int {
        let timestampMs = timestamp / 1_000_000
        let magnitude = simd_length(gyro) * 180 / .pi  // deg/s

        let oldest = buffer[writeIndex]
        buffer[writeIndex] = magnitude
        writeIndex = (writeIndex + 1) % bufferSize
        if writeIndex == 0 { filled = true }
        guard filled else { return 0 }

        // Rate of change across the window, extrapolated to per-second so the
        // thresholds are independent of buffer size.
        let acceleration = (magnitude - oldest) * sampleRate / Float(bufferSize)

        let tapElapsed = timestampMs &- tapStartMs
        if (tapCount > 0 || state != .idle) && tapElapsed > maxTapPeriodMs {
            state = .idle
            let final = tapCount
            tapCount = 0
            return final
        }

        switch state {
        case .idle:
            if acceleration > detectThreshold {
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
