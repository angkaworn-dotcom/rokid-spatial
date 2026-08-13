// Per-axis head-tracking locks (idea from VITURE's SpaceWalker: "Restrict
// Sideways Tilt / Forward-Backward Tilt / Left-Right Turn").
//
// Locking an axis removes that component from the head pose the renderer
// uses, so the screen stops reacting to it — a roll-locked screen tilts
// *with* your head instead of counter-rotating, which is what you want when
// slouching into a sofa corner or lying on one side. Platform-free on
// purpose, like the rest of RokidKit: the Windows port gets this for free.

import Foundation
import simd

public struct AxisLocks: Equatable, Sendable {
    /// Ignore forward/backward tilt (looking up or down).
    public var pitch = false
    /// Ignore left/right turn.
    public var yaw = false
    /// Ignore sideways tilt — the one that matters lying down.
    public var roll = false

    public init() {}

    public var isActive: Bool { pitch || yaw || roll }

    /// Strip the locked components out of a relative head orientation.
    ///
    /// The pose is decomposed yaw → pitch → roll (world-Y turn, then tilt,
    /// then twist about the view axis) and recomposed with the locked terms
    /// replaced by identity. The decomposition degenerates at pitch ±90°,
    /// where yaw and roll become the same axis — irrelevant in practice,
    /// because nobody works with their nose pointing at the ceiling.
    public func apply(_ q: simd_quatf) -> simd_quatf {
        guard isActive else { return q }

        let forward = q.act(SIMD3<Float>(0, 0, -1))
        let yawAngle = atan2(-forward.x, -forward.z)
        let pitchAngle = asin(max(-1, min(1, forward.y)))
        let qYaw = simd_quatf(angle: yawAngle, axis: SIMD3<Float>(0, 1, 0))
        let qPitch = simd_quatf(angle: pitchAngle, axis: SIMD3<Float>(1, 0, 0))
        // Whatever rotation remains after yaw and pitch is the roll twist.
        let qRoll = (qYaw * qPitch).inverse * q

        var result = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        if !yaw { result = qYaw }
        if !pitch { result = result * qPitch }
        if !roll { result = result * qRoll }
        return result.normalized
    }
}
