// Turns the raw accelerometer + gyroscope stream into an orientation estimate.
//
// This is a Mahony-style complementary filter: integrate the gyroscope for
// responsiveness, and nudge the result toward the direction gravity says is
// "down" to stop pitch and roll from drifting. Yaw has no such reference —
// the magnetometer reads ~108 µT indoors, well outside Earth's 25–65 µT, so
// trusting it would inject worse error than it removes. Yaw therefore drifts,
// which is precisely why follow mode exists: it re-centres continuously and
// hides the drift, where a world-anchored screen would slowly slide away.
//
// Gyroscope bias is the dominant drift source. At rest the gyro reads about
// 0.0025 rad/s — small, but that is 8.6°/minute if integrated blindly. So we
// continuously re-estimate the bias whenever the glasses are detected to be
// sitting still, and subtract it before integrating.

import Foundation
import simd

public final class OrientationFilter {
    /// Current orientation, device frame → world frame. World +Y is up.
    public private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Running estimate of the gyroscope's zero offset, rad/s.
    public private(set) var gyroBias = SIMD3<Float>(repeating: 0)

    /// True when the glasses look stationary, so bias estimation is running.
    public private(set) var isStationary = false

    /// How hard gravity pulls the estimate back into alignment. Higher is more
    /// stable but lets head-shake bleed into the orientation.
    public var accelGain: Float = 1.0

    /// Time constant for bias adaptation, in seconds. Deliberately long — see
    /// `update(_:)` for why a fast estimator makes drift worse, not better.
    public var biasTimeConstant: Float = 20

    /// Rotation rate below which the glasses count as still, rad/s.
    ///
    /// A worn head is never truly still. Demanding 0.7 °/s sounds rigorous and
    /// simply means the estimator never runs at all, leaving the bias at zero
    /// and the drift completely uncorrected — measurably worse than a sloppy
    /// estimate. 0.03 rad/s is about 1.7 °/s: above head jitter, well below any
    /// deliberate turn.
    public var stationaryThreshold: Float = 0.03

    /// How long the glasses must hold still before bias adaptation resumes.
    public var stationaryDwell: Float = 1.0

    /// How long the glasses have currently been still, in seconds.
    public private(set) var stationaryTime: Float = 0

    /// Seconds of accelerated bias learning still to run.
    private var fastCalibrationRemaining: Float = 0

    /// True while a calibration is in progress.
    public var isCalibrating: Bool { fastCalibrationRemaining > 0 }

    /// Learn the gyroscope bias quickly. The glasses must be put down and left
    /// alone for the duration — this is the only way to get a trustworthy bias,
    /// because passive estimation on a worn head only ever catches brief and
    /// imperfect moments of stillness.
    public func beginCalibration(seconds: Float = 6) {
        fastCalibrationRemaining = seconds
        stationaryTime = 0
    }

    private var lastTimestamp: UInt64?
    private var initialised = false

    /// Orientation captured by `recenter()`; all relative output is measured
    /// against this.
    private var reference = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    public init() {}

    /// Treat wherever the head is pointing right now as straight ahead.
    public func recenter() {
        reference = orientation
    }

    /// Bias-corrected angular velocity from the most recent sample, rad/s.
    public private(set) var angularVelocity = SIMD3<Float>(repeating: 0)

    /// Orientation relative to the last `recenter()`.
    public var relativeOrientation: simd_quatf {
        (reference.inverse * orientation).normalized
    }

    /// Where the head will be `lookAhead` seconds from now, relative to the
    /// last `recenter()`.
    ///
    /// A frame is rendered from an orientation that is already stale by the
    /// time it lights up: sensor latency, a frame of rendering, and a frame of
    /// compositing add up to roughly 20 ms. Through the glasses that reads as
    /// the image smearing behind your head whenever you turn. Extrapolating
    /// forward along the current rotation rate cancels most of it. Too much
    /// look-ahead overshoots and the image jitters, so this stays small.
    public func predictedRelativeOrientation(lookAhead: Float) -> simd_quatf {
        guard lookAhead > 0 else { return relativeOrientation }
        let speed = simd_length(angularVelocity)
        guard speed > 1e-4 else { return relativeOrientation }

        let axis = angularVelocity / speed
        let step = simd_quatf(angle: speed * lookAhead, axis: axis)
        // Body-frame rotation, so it post-multiplies.
        return (reference.inverse * (orientation * step)).normalized
    }

    public func update(_ sample: IMUSample) {
        let accelMagnitude = simd_length(sample.accel)

        // Seed the filter from the first usable gravity reading, so we start
        // upright instead of spending seconds converging from identity.
        if !initialised {
            guard accelMagnitude > 1 else { return }
            orientation = Self.levelling(from: sample.accel)
            reference = orientation
            lastTimestamp = sample.timestamp
            initialised = true
            return
        }

        guard let last = lastTimestamp else { return }
        // Timestamps are nanoseconds; guard against wraparound and stalls.
        let dt = Float(Double(sample.timestamp &- last) / 1_000_000_000)
        lastTimestamp = sample.timestamp
        guard dt > 0, dt < 0.5 else { return }

        // Bias estimation is where drift is won or lost, and the instinct to
        // make it responsive is exactly wrong.
        //
        // A loose stationary threshold with a fast time constant will happily
        // absorb a genuine slow head turn as though it were sensor bias. Stop
        // turning, and the filter now believes the glasses are rotating the
        // other way — so the screen slides off on its own, and the slower you
        // moved, the worse it is. The threshold below is 0.7 °/s, well under
        // any deliberate head movement, and adaptation is spread over 20
        // seconds. Bias changes with temperature over minutes; it never needs
        // to be tracked faster than that.
        isStationary = simd_length(sample.gyro - gyroBias) < stationaryThreshold
            && abs(accelMagnitude - 9.81) < 0.25
        stationaryTime = isStationary ? stationaryTime + dt : 0

        if fastCalibrationRemaining > 0 {
            // Deliberate calibration: converge in about a second, but only
            // while the glasses really are still, so a knock does not poison it.
            if isStationary {
                fastCalibrationRemaining -= dt
                gyroBias += (sample.gyro - gyroBias) * min(1, dt / 1.0)
            }
        } else if stationaryTime > stationaryDwell {
            gyroBias += (sample.gyro - gyroBias) * (dt / biasTimeConstant)
        }

        var omega = sample.gyro - gyroBias

        // Smoothed rotation rate, for motion prediction only. The raw value is
        // far too noisy to extrapolate from: multiplying single-sample noise by
        // a look-ahead interval and reapplying it every frame produces visible
        // high-frequency jitter, which reads as a *worse* picture than the
        // latency it was meant to cancel. A 60 ms time constant keeps genuine
        // head motion while discarding the noise.
        let smoothing = min(1, dt / 0.060)
        angularVelocity += (omega - angularVelocity) * smoothing

        // Gravity correction: compare where we think "up" is against where the
        // accelerometer says it is, and fold the error into the rotation rate.
        // Skipped during hard acceleration, when the reading is not just gravity.
        if abs(accelMagnitude - 9.81) < 1.5 {
            let measuredUp = sample.accel / accelMagnitude
            let expectedUp = orientation.inverse.act(SIMD3<Float>(0, 1, 0))
            omega += simd_cross(measuredUp, expectedUp) * accelGain
        }

        // Quaternion integration: q̇ = ½ q ⊗ ω
        let spin = simd_quatf(ix: omega.x, iy: omega.y, iz: omega.z, r: 0)
        let derivative = orientation * spin
        orientation = simd_quatf(
            ix: orientation.imag.x + 0.5 * derivative.imag.x * dt,
            iy: orientation.imag.y + 0.5 * derivative.imag.y * dt,
            iz: orientation.imag.z + 0.5 * derivative.imag.z * dt,
            r: orientation.real + 0.5 * derivative.real * dt
        ).normalized
    }

    /// Rotation about world up, in degrees, relative to `recenter()`. This is
    /// the one angle gravity lets us define unambiguously, so it is the only
    /// one derived rather than read off the device axes.
    public var yawDegrees: Float {
        let q = relativeOrientation
        let up = SIMD3<Float>(0, 1, 0)
        // Swing-twist decomposition: keep only the component about `up`.
        let projected = simd_dot(q.imag, up) * up
        var twist = simd_quatf(ix: projected.x, iy: projected.y, iz: projected.z, r: q.real)
        if simd_length(twist.imag) < 1e-9 && twist.real == 0 { return 0 }
        twist = twist.normalized
        let angle = 2 * atan2(simd_length(twist.imag) * (simd_dot(twist.imag, up) < 0 ? -1 : 1),
                              twist.real)
        return Self.wrap(angle) * 180 / .pi
    }

    /// An orientation that puts the measured gravity vector along world +Y,
    /// leaving yaw arbitrary. Used only to seed the filter.
    private static func levelling(from accel: SIMD3<Float>) -> simd_quatf {
        let measured = simd_normalize(accel)
        let target = SIMD3<Float>(0, 1, 0)
        let axis = simd_cross(measured, target)
        let axisLength = simd_length(axis)
        if axisLength < 1e-6 {
            // Already aligned, or exactly inverted.
            return simd_dot(measured, target) > 0
                ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                : simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }
        let angle = atan2(axisLength, simd_dot(measured, target))
        return simd_quatf(angle: angle, axis: axis / axisLength).normalized
    }

    private static func wrap(_ radians: Float) -> Float {
        var a = radians
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
