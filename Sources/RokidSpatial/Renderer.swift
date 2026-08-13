// Draws the captured desktop as a quad floating in space, once per eye.
//
// Shaders are compiled from source at runtime rather than from a .metal file,
// which means the project builds with only the Command Line Tools installed —
// the offline `metal` compiler ships with full Xcode and is not required here.

import Foundation
import Metal
import MetalKit
import CoreVideo
import simd
import RokidKit

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Vertices arrive as float4 pairs: position (xyz, 1) then UV in (x, y).
// Real 3D positions rather than a flat local quad, because the screen
// surface may be curved — geometry is built CPU-side per frame.
vertex VertexOut vertexMain(uint vid [[vertex_id]],
                            const device float4 *vertices [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]])
{
    VertexOut out;
    out.position = uniforms.mvp * float4(vertices[vid * 2].xyz, 1.0);
    out.uv = vertices[vid * 2 + 1].xy;
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> tex [[texture(0)]],
                             constant float4 &tint [[buffer(0)]])
{
    // No mip filtering, deliberately. Mipmapping trades sharpness for reduced
    // aliasing, and sharpness is the scarcer resource here: the desktop is
    // already being minified onto fewer panel pixels than it has points, so
    // any further softening is immediately visible as blurred text.
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    return float4(tex.sample(smp, in.uv).rgb * tint.rgb * tint.a, 1.0);
}

// Anti-moiré variant: a 4-tap rotated-grid supersample, taps spread across
// this pixel's texture footprint via screen-space UV gradients. At ~1:1
// scale plain bilinear makes the desktop's pixel rows beat against the
// panel raster whenever the head moves — faint grey bands that crawl with
// sub-pixel sampling phase. Averaging four offset taps flattens the beat
// at the cost of a slight softening.
fragment float4 fragmentSmooth(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]],
                               constant float4 &tint [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float3 c = tex.sample(smp, in.uv + 0.125*dx + 0.375*dy).rgb
             + tex.sample(smp, in.uv - 0.375*dx + 0.125*dy).rgb
             + tex.sample(smp, in.uv - 0.125*dx - 0.375*dy).rgb
             + tex.sample(smp, in.uv + 0.375*dx - 0.125*dy).rgb;
    return float4(c * 0.25 * tint.rgb * tint.a, 1.0);
}

// The cursor sprite keeps its alpha — it is blended over the desktop quad.
fragment float4 fragmentCursor(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]],
                               constant float4 &tint [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float4 c = tex.sample(smp, in.uv);
    return float4(c.rgb * tint.rgb * tint.a, c.a * tint.a);
}
"""

final class Renderer: NSObject, MTKViewDelegate {
    /// Diagonal field of view of the Rokid Max optics.
    private static let diagonalFOV: Float = 50 * .pi / 180

    /// Vertical slices in the screen mesh. Enough that a fully curved wide
    /// screen renders smoothly; irrelevant to flat screens.
    private static let meshColumns = 64
    private static let meshVertexCount = (meshColumns + 1) * 2

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let smoothPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState

    /// Selects the anti-moiré fragment path; flippable live from settings.
    var antiMoire = false

    /// Head-down peek (idea borrowed from VITURE's SpaceWalker): as the head
    /// pitches down toward the keyboard the whole render fades to black, and
    /// black on a birdbath panel is see-through — so looking down shows the
    /// real desk, looking back up brings the screen back. The fade runs over
    /// an angle range rather than a switch, and the pose it reads is already
    /// steady-smoothed, so there is nothing to debounce.
    var headDownPeek = false
    /// Pitch (degrees) where the fade begins; fully dark 20 degrees later.
    /// User-tunable — how deep a "glance at the keyboard" is depends on
    /// posture and screen height.
    var peekAngle: Float = 35

    /// Eye-care warmth, 0 (off) to 1: pulls blue (and a little green) out of
    /// every fragment, Night-Shift style, but inside our own pipeline — so
    /// it applies in every mode and costs nothing extra.
    var eyeCare: Float = 0

    /// The frame-duration budget a draw is judged against, matching the
    /// panel's configured refresh rate.
    var targetFPS = 120
    private let vertexBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?

    // The cursor drawn by us, for glasses-only mode. The system cursor is
    // hidden there — the window server composites it above the overlay as a
    // second head-locked cursor, and hiding it also stops ScreenCaptureKit
    // from drawing it into captured frames — so this renderer paints its own
    // sprite at the same spot on the virtual screen. All coordinates are
    // fractions of the captured display so the shader stays resolution-blind.

    /// Current cursor sprite; nil disables cursor drawing entirely (other
    /// modes). Swapped from the main thread whenever the system cursor
    /// changes shape (resize arrows, I-beam, pointing hand) and read on the
    /// render thread — hence the lock and the one-shot snapshot in draw.
    private var cursorTexture: MTLTexture?
    private let cursorLock = NSLock()
    /// Cursor image size as a fraction of each captured display (index 0 is
    /// the main screen, then the side screens — point sizes differ).
    private var cursorFraction = [SIMD2<Float>](repeating: .zero, count: 3)
    /// Hotspot offset within the image, as a fraction of each display.
    private var cursorHotspotFraction = [SIMD2<Float>](repeating: .zero, count: 3)

    /// Swap the drawn cursor: sprite, its per-surface size and hotspot.
    func setCursorSprite(texture: MTLTexture?,
                         fraction: [SIMD2<Float>],
                         hotspot: [SIMD2<Float>]) {
        cursorLock.lock()
        cursorTexture = texture
        cursorFraction = fraction
        cursorHotspotFraction = hotspot
        cursorLock.unlock()
    }

    /// Angular position of each active side screen this frame (radians,
    /// nil = inactive), published by draw so the shake-warp can ask which
    /// screen the head is aimed at. Guarded by cursorLock.
    private var lastAzimuths: [Float?] = [nil, nil]

    /// Which surface the head is looking at: 0 main, 1 right side, 2 left.
    /// A side wins when the gaze is angularly closer to it than to centre.
    func lookedSurface(yawRadians: Float) -> Int {
        cursorLock.lock(); defer { cursorLock.unlock() }
        for (index, azimuth) in lastAzimuths.enumerated() {
            guard let azimuth else { continue }
            if abs(yawRadians - azimuth) < abs(yawRadians) { return index + 1 }
        }
        return 0
    }

    /// Called each frame; returns which surface the cursor is on (0 main,
    /// 1 right side, 2 left side) and its UV (0…1, top-left origin), or nil
    /// to skip drawing.
    var cursorPosition: (() -> (surface: Int, uv: SIMD2<Float>)?)?

    // MARK: Side screens

    /// Side screens hang left and right of the main one at the same distance,
    /// sharing the anchor — turn your head and they are simply there, like
    /// extra monitors. Each is fed by its own capture stream.
    /// Index 0 = right, 1 = left; set true once its capture is running.
    var sideActive = [false, false]
    /// Angular gap between neighbouring screens, radians. Zero butts the
    /// screens together into one long wall — best combined with curvature.
    var sideGap: Float = 0.05

    private let filter: OrientationFilter
    private let screen: VirtualScreen

    /// Latest captured frames, handed over from the capture queues.
    private var pendingFrame: CVPixelBuffer?
    private var pendingSideFrames: [CVPixelBuffer?] = [nil, nil]
    private var frameLock = NSLock()
    private var currentTexture: CVMetalTexture?
    private var currentSideTextures: [CVMetalTexture?] = [nil, nil]
    private let sideVertexBuffers: [MTLBuffer]

    private var lastDrawTime = CFAbsoluteTimeGetCurrent()

    /// Frame-pacing counters, read and reset once a second by the status
    /// display. A "long" frame overshot the 120 Hz deadline by half a frame —
    /// exactly the hiccups that read as stutter in the glasses. Written on
    /// the render thread, read from the main thread, hence the lock.
    private let statsLock = NSLock()
    private var framesDrawn = 0
    private var longFrames = 0

    func takeFrameStats() -> (drawn: Int, long: Int) {
        statsLock.lock()
        defer { framesDrawn = 0; longFrames = 0; statsLock.unlock() }
        return (framesDrawn, longFrames)
    }

    // MARK: Render loop

    /// Rendering runs on CVDisplayLink's dedicated thread, paced by the
    /// *glasses* display. Two separate problems made the default main-thread
    /// MTKView loop deliver only 40–65 fps of a 120 fps target: the main
    /// thread is busy (UI, timers, IMU at 440 Hz all compete with an 8.3 ms
    /// deadline), and in a mirror set the view's implicit pacing can latch
    /// onto the 60 Hz built-in member instead of the 120 Hz panel.
    private var displayLink: CVDisplayLink?
    private weak var linkedView: MTKView?

    func startRenderLoop(displayID: CGDirectDisplayID, view: MTKView) {
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        linkedView = view

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &link) == kCVReturnSuccess,
              let link else {
            // No link, no dedicated thread — fall back to MTKView's own loop.
            view.isPaused = false
            return
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            // MTKView supports manual drawing from a non-main thread when
            // paused with setNeedsDisplay disabled — which is this.
            self?.linkedView?.draw()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopRenderLoop() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
        linkedView = nil
    }

    deinit { stopRenderLoop() }

    /// Set false to fall back to a single centred view, e.g. if SBS is off.
    var stereo = true

    /// Seconds of head-motion prediction. Off by default: prediction fights
    /// latency but amplifies gyroscope noise, and on this hardware the noise
    /// was the more noticeable of the two.
    var lookAhead: Float = 0

    /// Display-side pose smoothing time constant, seconds. Rendering at a
    /// full 120 fps faithfully reproduces the filter's sub-degree tremor —
    /// which the old 45 fps loop had been accidentally hiding — so the pose
    /// used for drawing is eased over the last couple of frames. ~15 ms of
    /// added latency is imperceptible; the shimmer it removes is not.
    var steady: Float = 0.015
    private var steadyHead: simd_quatf?

    /// Pixel dimensions of the most recent captured frame.
    private(set) var contentSize = SIMD2<Float>(0, 0)

    /// How many panel pixels the virtual screen currently spans horizontally.
    private(set) var renderedWidth: Float = 0

    init?(filter: OrientationFilter, screen: VirtualScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.filter = filter
        self.screen = screen

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            descriptor.fragmentFunction = library.makeFunction(name: "fragmentSmooth")
            smoothPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            // Same vertex path, alpha-blended fragment for the cursor sprite.
            // CGImage-sourced textures are premultiplied, hence .one.
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentCursor")
            let blend = descriptor.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .one
            blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Renderer: shader compilation failed — \(error)")
            return nil
        }

        // The screen mesh: a triangle strip of vertical slices, rebuilt each
        // frame because size, distance and curvature are all live-adjustable.
        // Flat screens waste the columns; curved ones need them.
        let meshLength = MemoryLayout<SIMD4<Float>>.stride * Self.meshVertexCount * 2
        guard let buffer = device.makeBuffer(length: meshLength, options: .storageModeShared),
              let sideRight = device.makeBuffer(length: meshLength, options: .storageModeShared),
              let sideLeft = device.makeBuffer(length: meshLength, options: .storageModeShared)
        else { return nil }
        vertexBuffer = buffer
        sideVertexBuffers = [sideRight, sideLeft]

        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Hand a freshly captured frame to the renderer. Safe to call from any queue.
    func submit(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    /// Same, for a side screen's capture stream (0 right, 1 left).
    func submitSide(_ index: Int, frame: CVPixelBuffer) {
        frameLock.lock()
        pendingSideFrames[index] = frame
        frameLock.unlock()
    }

    /// Rotate `point` about the anchor's vertical axis — how the side screen
    /// swings away from the main one.
    private static func rotateY(_ point: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(point.x * c + point.z * s, point.y, -point.x * s + point.z * c)
    }

    /// Fill a mesh buffer with the screen surface, optionally swung by
    /// `azimuth` radians about the vertical axis.
    private func fillMesh(_ buffer: MTLBuffer, aspect: Float, azimuth: Float) {
        let mesh = buffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: Self.meshVertexCount * 2)
        for column in 0...Self.meshColumns {
            let u = Float(column) / Float(Self.meshColumns)
            var bottom = screen.surfacePoint(u: u, v: 1, aspect: aspect)
            var top = screen.surfacePoint(u: u, v: 0, aspect: aspect)
            if azimuth != 0 {
                bottom = Self.rotateY(bottom, azimuth)
                top = Self.rotateY(top, azimuth)
            }
            let base = column * 4
            mesh[base + 0] = SIMD4(bottom.x, bottom.y, bottom.z, 1)
            mesh[base + 1] = SIMD4(u, 1, 0, 0)
            mesh[base + 2] = SIMD4(top.x, top.y, top.z, 1)
            mesh[base + 3] = SIMD4(u, 0, 0, 0)
        }
    }

    /// How far a side screen's centre swings from the main screen's, radians
    /// about the vertical axis. The caller applies the sign for left/right.
    private func sideAzimuthMagnitude(mainAspect: Float, sideAspect: Float) -> Float {
        let mainHalf = screen.size(aspect: mainAspect).x / (2 * screen.distance)
        let sideHalf = screen.size(aspect: sideAspect).x / (2 * screen.distance)
        return mainHalf + sideHalf + sideGap
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastDrawTime)
        lastDrawTime = now
        statsLock.lock()
        framesDrawn += 1
        if dt > 1.5 / Float(targetFPS) { longFrames += 1 }
        statsLock.unlock()

        var head = filter.predictedRelativeOrientation(lookAhead: lookAhead)
        if steady > 0.0005, dt > 0, dt < 0.5, let previous = steadyHead {
            head = simd_slerp(previous, head, min(1, dt / steady)).normalized
        }
        steadyHead = head
        screen.update(head: head, dt: dt,
                      rotationRate: simd_length(filter.angularVelocity))

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let texture = prepareTexture(commandBuffer: commandBuffer)

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Head-down peek: fade everything toward black between the start and
        // full angles. Black is what makes the optics see-through, so this
        // must multiply every fragment — desktop, sides, cursor alike.
        var dim: Float = 1
        if headDownPeek {
            let forward = head.act(SIMD3<Float>(0, 0, -1))
            let pitchDown = asin(max(-1, min(1, -forward.y)))
            let start = peekAngle * .pi / 180
            dim = 1 - simd_smoothstep(start, start + 20 * .pi / 180, pitchDown)
        }
        // rgb = per-channel gains (eye-care warmth), a = overall dim (peek).
        var tint = SIMD4<Float>(1, 1 - 0.18 * eyeCare, 1 - 0.38 * eyeCare, dim)
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

        if let texture {
            let width = Double(view.drawableSize.width)
            let height = Double(view.drawableSize.height)
            // In SBS the framebuffer holds both eyes across its width, so each
            // eye's viewport is half as wide but keeps the full aspect ratio.
            let eyeWidth = stereo ? width / 2 : width
            let aspect = Float(eyeWidth / height)

            let contentAspect = Float(texture.width) / Float(texture.height)
            let model = screen.anchorRotation()

            // Rebuild the screen surfaces: alternating bottom/top vertices
            // per column form one triangle strip across each (possibly
            // curved) surface, positions in the anchor's local frame.
            fillMesh(vertexBuffer, aspect: contentAspect, azimuth: 0)

            // Prepare whichever side screens are live this frame. Right hangs
            // at a negative azimuth, left at a positive one.
            var sideRender: [(index: Int, texture: MTLTexture, aspect: Float, azimuth: Float)] = []
            for index in 0..<sideActive.count where sideActive[index] {
                guard let sideTexture = prepareSideTexture(index) else { continue }
                let aspect = Float(sideTexture.width) / Float(sideTexture.height)
                let magnitude = sideAzimuthMagnitude(mainAspect: contentAspect, sideAspect: aspect)
                let azimuth = index == 0 ? -magnitude : magnitude
                fillMesh(sideVertexBuffers[index], aspect: aspect, azimuth: azimuth)
                sideRender.append((index, sideTexture, aspect, azimuth))
            }
            cursorLock.lock()
            lastAzimuths = [nil, nil]
            for side in sideRender { lastAzimuths[side.index] = side.azimuth }
            cursorLock.unlock()

            // Convert the quoted diagonal FOV into the vertical one Metal wants.
            let diagonalTangent = tan(Self.diagonalFOV / 2)
            let verticalTangent = diagonalTangent / (1 + aspect * aspect).squareRoot()
            let fovY = 2 * atan(verticalTangent)
            let projection = simd_float4x4.perspective(
                fovYRadians: fovY, aspect: aspect, near: 0.05, far: 100
            )

            // How many panel pixels the virtual screen actually spans. Compared
            // against the captured width, this is the sharpness budget: below
            // 1.0 the desktop is being squeezed into fewer pixels than it has,
            // and no amount of filtering can put the detail back.
            let extent = screen.size(aspect: contentAspect)
            renderedWidth = Float(eyeWidth) * extent.x
                / (screen.distance * 2 * tan(fovY / 2) * aspect)

            // The cursor quad sits on whichever surface the mouse is on, at
            // its fractional position — its corners go through the same
            // surface mapping, so it follows curvature and the side swing.
            cursorLock.lock()
            let sprite = cursorTexture
            let spriteFractions = cursorFraction
            let spriteHotspots = cursorHotspotFraction
            cursorLock.unlock()
            var cursorVertices: [SIMD4<Float>]?
            if let position = cursorPosition?(), sprite != nil {
                // On a side surface, the cursor needs that side's geometry;
                // skip drawing entirely if that side is not rendering.
                let side = position.surface > 0
                    ? sideRender.first(where: { $0.index == position.surface - 1 })
                    : nil
                if position.surface == 0 || side != nil {
                    let fraction = spriteFractions[position.surface]
                    let hotspot = spriteHotspots[position.surface]
                    let aspect = side?.aspect ?? contentAspect
                    let u0 = position.uv.x - hotspot.x
                    let v0 = position.uv.y - hotspot.y
                    let u1 = u0 + fraction.x
                    let v1 = v0 + fraction.y
                    // Nudged toward the viewer so it never z-fights the screen.
                    cursorVertices = [
                        (u0, v1, SIMD2<Float>(0, 1)),
                        (u1, v1, SIMD2<Float>(1, 1)),
                        (u0, v0, SIMD2<Float>(0, 0)),
                        (u1, v0, SIMD2<Float>(1, 0)),
                    ].flatMap { (u, v, uv) -> [SIMD4<Float>] in
                        var p = screen.surfacePoint(u: u, v: v, aspect: aspect)
                        if let side { p = Self.rotateY(p, side.azimuth) }
                        p *= 0.995
                        return [SIMD4(p.x, p.y, p.z, 1), SIMD4(uv.x, uv.y, 0, 0)]
                    }
                }
            }

            let eyes: [(offset: Float, originX: Double)] = stereo
                ? [(-screen.ipd / 2, 0), (screen.ipd / 2, eyeWidth)]
                : [(0, 0)]

            for eye in eyes {
                encoder.setViewport(MTLViewport(
                    originX: eye.originX, originY: 0,
                    width: eyeWidth, height: height,
                    znear: 0, zfar: 1
                ))
                let view = screen.viewMatrix(head: head, eyeOffset: eye.offset)
                var uniforms = projection * view * model
                encoder.setVertexBytes(&uniforms,
                                       length: MemoryLayout<simd_float4x4>.size,
                                       index: 1)

                encoder.setRenderPipelineState(antiMoire ? smoothPipeline : pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: Self.meshVertexCount)

                for side in sideRender {
                    encoder.setVertexBuffer(sideVertexBuffers[side.index], offset: 0, index: 0)
                    encoder.setFragmentTexture(side.texture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                           vertexCount: Self.meshVertexCount)
                }

                if let cursorVertices, let sprite {
                    encoder.setRenderPipelineState(cursorPipeline)
                    encoder.setVertexBytes(cursorVertices,
                                           length: MemoryLayout<SIMD4<Float>>.stride * cursorVertices.count,
                                           index: 0)
                    encoder.setFragmentTexture(sprite, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Wrap the most recent captured pixel buffer as a Metal texture.
    ///
    /// The `CVMetalTexture` is retained until the next frame replaces it, which
    /// keeps the underlying IOSurface alive for as long as the GPU is reading
    /// from it. If no new frame has arrived, the previous one is redrawn — the
    /// head has still moved, so the geometry needs updating even when the
    /// desktop is idle.
    private func prepareTexture(commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        frameLock.lock()
        let frame = pendingFrame
        frameLock.unlock()

        let previous = currentTexture.flatMap { CVMetalTextureGetTexture($0) }
        guard let frame, let textureCache else { return previous }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil,
            .bgra8Unorm, width, height, 0, &wrapped
        )
        guard status == kCVReturnSuccess,
              let wrapped,
              let source = CVMetalTextureGetTexture(wrapped)
        else { return previous }
        currentTexture = wrapped

        contentSize = SIMD2(Float(width), Float(height))
        return source
    }

    /// Side-screen counterpart of `prepareTexture`.
    private func prepareSideTexture(_ index: Int) -> MTLTexture? {
        frameLock.lock()
        let frame = pendingSideFrames[index]
        frameLock.unlock()

        let previous = currentSideTextures[index].flatMap { CVMetalTextureGetTexture($0) }
        guard let frame, let textureCache else { return previous }

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &wrapped
        )
        guard status == kCVReturnSuccess,
              let wrapped,
              let source = CVMetalTextureGetTexture(wrapped)
        else { return previous }
        currentSideTextures[index] = wrapped
        return source
    }
}
