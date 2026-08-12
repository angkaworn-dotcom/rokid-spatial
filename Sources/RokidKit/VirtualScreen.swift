// Where the virtual screen sits, and how it reacts to head movement.
//
// This is the piece that decides whether wearing the glasses feels natural or
// strange, and it is deliberately free of any platform framework — only simd —
// so a Windows port can reuse it as-is.
//
// The two modes exist because 3DoF tracking forces a trade-off. Yaw drifts at
// roughly 3.3 °/min (see PROTOCOL.md), so a screen pinned to the room slides
// about 33° off-centre in ten minutes. Follow mode sidesteps this entirely:
// because the anchor is continuously pulled back toward wherever you are
// looking, accumulated drift is absorbed rather than accumulated. It is the
// sane default. Anchored mode is the honest one — it genuinely holds the
// screen in the room — and it is the one that needs re-centring.

import Foundation
import simd

public enum AnchorMode: String, CaseIterable, Sendable {
    /// The screen trails the head, with a deadzone so small movements do nothing.
    case follow
    /// The screen stays fixed in the room.
    case anchored

    public var label: String {
        switch self {
        case .follow: return "Follow"
        case .anchored: return "Anchored"
        }
    }
}

public final class VirtualScreen {
    // MARK: Tunables

    public var mode: AnchorMode = .follow

    /// Distance from the eyes to the virtual screen, in metres. Note that the
    /// glasses' optics fix *focus* at ~6 m no matter what this says; this
    /// changes apparent position and stereo disparity, not accommodation.
    public var distance: Float = 2.5 {
        didSet { distance = min(max(distance, 0.4), 12.0) }
    }

    /// How quickly the screen eases back to dead ahead while the head is
    /// inside the deadzone. Without this the screen parks wherever the
    /// deadzone left it and never returns to centre.
    public var settleSpeed: Float = 0.7 {
        didSet { settleSpeed = min(max(settleSpeed, 0), 5) }
    }

    /// Diagonal size of the virtual screen in metres.
    public var diagonal: Float = 1.5 {
        didSet { diagonal = min(max(diagonal, 0.3), 8.0) }
    }

    /// Vertical position of the screen in metres — positive raises it.
    /// Applied in the anchor's frame, so the screen keeps this height
    /// relative to your line of sight in both follow and anchored modes.
    public var verticalOffset: Float = 0 {
        didSet { verticalOffset = min(max(verticalOffset, -2.0), 2.0) }
    }

    /// Bend the screen into a cylinder arc of radius `distance`, so every
    /// point of it sits the same distance from the eye. Flat screens read
    /// fine at modest sizes; past a couple of metres wide the edges of a flat
    /// screen are markedly further away than the centre and visibly skewed,
    /// which is exactly what curving fixes. Same idea as breezy-desktop's
    /// `curved_display`.
    public var curved = false

    /// How far the head can turn before the screen starts to follow, degrees.
    ///
    /// Keep this well under the vertical field of view, which is only about
    /// 27.7°. A deadzone of 12° lets the screen park nearly half a screen-height
    /// off centre, and a screen sized to fill the view then clips at the edge.
    public var deadzoneDegrees: Float = 6 {
        didSet { deadzoneDegrees = min(max(deadzoneDegrees, 0), 45) }
    }

    /// How quickly the screen catches up once outside the deadzone. Roughly
    /// "fraction of the remaining gap closed per second".
    public var followSpeed: Float = 3.0 {
        didSet { followSpeed = min(max(followSpeed, 0.5), 20) }
    }

    /// How strongly the screen locks to the head during fast rotation, 0–1.
    ///
    /// This exists to kill motion blur, and the reasoning is worth keeping.
    /// The panel holds each frame lit for its whole duration, so smear is
    /// (how fast the image crosses your retina) × (how long the frame is lit).
    /// Refresh rate fixes the second term. This fixes the first.
    ///
    /// A world-anchored screen is the worst case: turn your head and the image
    /// sweeps across the panel, your eye tracks it, and the retinal image moves
    /// at the full rotation rate. A head-locked screen is the best case — the
    /// image never moves on the panel, so your eye never moves relative to it,
    /// and there is almost nothing to smear. But head-locked is exactly the
    /// rigid, unnatural feel worth avoiding the rest of the time.
    ///
    /// So: lock while turning, release when still. Nobody reads during a fast
    /// head turn, and by the time you stop the screen has eased back.
    ///
    /// Off by default. The theory above is sound and the result was reported as
    /// less smooth than leaving it alone — the screen being pulled around during
    /// a turn is itself something you notice, and it turns out to bother people
    /// more than the smear it removes. Available to turn up and judge directly.
    public var motionLock: Float = 0 {
        didSet { motionLock = min(max(motionLock, 0), 1) }
    }

    /// Rotation rate at which `motionLock` reaches full strength, degrees/s.
    public var motionLockFullSpeed: Float = 60

    /// Interpupillary distance in metres, used for stereo separation.
    public var ipd: Float = 0.063 {
        // Far wider than anatomical IPD (54–74 mm) on purpose: this offset is
        // a *depth tuning knob* against the panel's fixed SBS optics, not a
        // measurement of the user's face. 0 renders flat — a useful reference
        // point — and large values give hyperstereo (the screen reads nearer
        // and more solid). Widened twice on user request during the first
        // SBS sessions; beyond ~150 mm fusion may break into double vision,
        // but the user's eyes are the judge here, not the clamp.
        didSet { ipd = min(max(ipd, 0), 0.200) }
    }

    // MARK: State

    /// Orientation the screen currently hangs at, in world space.
    public private(set) var anchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Where the screen is actually drawn: `anchor`, plus a temporary pull
    /// toward the head while turning. Decays back to `anchor` when still.
    public private(set) var displayAnchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    public init() {}

    /// Snap the screen to directly ahead of where the head is pointing now.
    public func recenter(head: simd_quatf) {
        anchor = head
        displayAnchor = head
    }

    /// Advance the anchor toward the head, according to the current mode.
    ///
    /// `rotationRate` is the current head rotation in rad/s; pass 0 if unknown.
    public func update(head: simd_quatf, dt: Float, rotationRate: Float = 0) {
        guard dt > 0, dt < 0.5 else { return }

        // Blur suppression, applied at render time only.
        //
        // Crucially this does *not* move `anchor`. Dragging the real anchor
        // would mean a world-anchored screen never returns to where it was
        // pinned after a fast turn, quietly degrading anchored mode into
        // follow mode. Instead the offset lives in `displayAnchor` and decays
        // back to nothing as the head slows.
        let fullSpeed = max(motionLockFullSpeed * .pi / 180, 0.01)
        let intensity = motionLock > 0
            ? min(1, rotationRate / fullSpeed) * motionLock
            : 0

        guard mode == .follow else {
            // Anchored still gets blur suppression, just no anchor movement.
            displayAnchor = intensity > 0.001
                ? simd_slerp(anchor, head, intensity).normalized
                : anchor
            return
        }

        // Angular gap between where the screen is and where we are looking.
        let delta = (anchor.inverse * head).normalized
        let gap = 2 * acos(min(max(abs(delta.real), -1), 1))
        let deadzone = deadzoneDegrees * .pi / 180

        if gap > deadzone {
            // Aim for the orientation that leaves the head exactly at the edge
            // of the deadzone, then ease toward it. The result is a screen that
            // hangs back while you glance around and swings over when you
            // actually turn.
            let targetFraction = (gap - deadzone) / gap
            let target = simd_slerp(anchor, head, targetFraction)
            anchor = simd_slerp(anchor, target, min(1, followSpeed * dt)).normalized
        } else if gap > 1e-4 {
            // Inside the deadzone, drift gently back to centred. This is what
            // stops the screen from sitting permanently off to one side after
            // a glance, and it quietly absorbs yaw drift too.
            anchor = simd_slerp(anchor, head, min(1, settleSpeed * dt)).normalized
        }

        displayAnchor = intensity > 0.001
            ? simd_slerp(anchor, head, intensity).normalized
            : anchor
    }

    // MARK: Geometry

    /// Physical size of the virtual screen in metres, for a given aspect ratio.
    public func size(aspect: Float) -> SIMD2<Float> {
        let height = diagonal / (1 + aspect * aspect).squareRoot()
        return SIMD2(height * aspect, height)
    }

    /// A point on the screen surface in the anchor's local frame, for texture
    /// coordinates `u` (0 left → 1 right) and `v` (0 top → 1 bottom).
    ///
    /// Flat, the screen is a plane `distance` metres along -Z. Curved, it is
    /// an arc of a cylinder of radius `distance` centred on the viewer, with
    /// the arc length equal to the flat width so apparent size is preserved.
    ///
    /// Device axes were measured as X = pitch (right), Y = yaw (up),
    /// Z = roll (forward/back); with a right-handed frame and Y up, the
    /// viewing direction is -Z.
    public func surfacePoint(u: Float, v: Float, aspect: Float) -> SIMD3<Float> {
        let extent = size(aspect: aspect)
        let y = (0.5 - v) * extent.y + verticalOffset
        if curved {
            let angle = (u - 0.5) * extent.x / distance
            return SIMD3(distance * sin(angle), y, -distance * cos(angle))
        }
        return SIMD3((u - 0.5) * extent.x, y, -distance)
    }

    /// Rotation-only model transform; the surface geometry itself comes from
    /// `surfacePoint(u:v:aspect:)`.
    public func anchorRotation() -> simd_float4x4 {
        simd_float4x4(displayAnchor)
    }

    /// View matrix for one eye: undo the head rotation, then step sideways by
    /// half the IPD. Passing 0 for `eyeOffset` gives the monocular view.
    public func viewMatrix(head: simd_quatf, eyeOffset: Float) -> simd_float4x4 {
        let rotation = simd_float4x4(head.inverse.normalized)
        return simd_float4x4(translation: SIMD3(-eyeOffset, 0, 0)) * rotation
    }
}

// MARK: - Matrix helpers

extension simd_float4x4 {
    public init(diagonal d: SIMD4<Float>) {
        self.init(
            SIMD4(d.x, 0, 0, 0),
            SIMD4(0, d.y, 0, 0),
            SIMD4(0, 0, d.z, 0),
            SIMD4(0, 0, 0, d.w)
        )
    }

    public init(translation t: SIMD3<Float>) {
        self.init(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }

    /// Right-handed perspective projection mapping depth to [0, 1] for Metal.
    public static func perspective(
        fovYRadians: Float, aspect: Float, near: Float, far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        )
    }
}
